-- Bridge between Neovim and Banjo backend via WebSocket
local ws_client = require("banjo.websocket.client")
local panel = require("banjo.panel")
local ui_prompt = require("banjo.ui.prompt")

local M = {}

-- Debug logging
local function lua_debug(msg)
    if not vim.g.banjo_debug then
        return
    end
    local ok, _ = pcall(function()
        local line = os.date("%H:%M:%S ") .. msg
        vim.fn.writefile({line}, "/tmp/banjo-lua-debug.log", "a")
    end)
    _ = ok
end

-- Per-tab bridge b.state (indexed by tabpage handle)
local bridges = {}

-- Notify user when a background tab needs attention
local function notify_background(tabid, message, level)
    local current_tab = vim.api.nvim_get_current_tabpage()
    if current_tab ~= tabid then
        local tabnr = vim.api.nvim_tabpage_get_number(tabid)
        vim.notify(string.format("[Tab %d] %s", tabnr, message), level or vim.log.levels.INFO)
    end
end

-- Per-tab bridge b.state accessor
local function get_bridge()
    local tabid = vim.api.nvim_get_current_tabpage()
    if not bridges[tabid] then
        bridges[tabid] = {
            tabid = tabid,
            client = nil,
            job_id = nil,
            mcp_port = nil,
            last_selection = nil,
            autocmd_group = nil,
            state = {
                engine = "claude",
                model = nil,
                mode = "default",
                session_id = nil,
                connected = false,
                session_active = false,
                session_start_time = nil,
            },
            reconnect = {
                attempt = 0,
                max_delay_ms = 30000,
                base_delay_ms = 1000,
                timer = nil,
                enabled = true,
                binary_path = nil,
                cwd = nil,
            },
            preserved = {
                input_text = nil,
                permission_mode = nil,
                engine = nil,
                model = nil,
            },
            -- ACP protocol state
            acp = {
                next_id = 1,
                pending_requests = {}, -- id -> callback
            },
        }
        -- Wire up bidirectional reference per tab
        panel.set_bridge(M)
    end
    return bridges[tabid]
end

function M.start(binary_path, cwd)
    lua_debug("[bridge] M.start called")
    local b = get_bridge()
    if b.client and ws_client.is_connected(b.client) then
        lua_debug("[bridge] already connected, returning")
        return
    end
    lua_debug("[bridge] starting binary: " .. binary_path)

    -- Save for reconnection
    b.reconnect.binary_path = binary_path
    b.reconnect.cwd = cwd
    b.reconnect.enabled = true

    local my_tabid = b.tabid
    b.autocmd_group = vim.api.nvim_create_augroup("BanjoEvents_" .. my_tabid, { clear = true })

    -- Spawn the binary to get the WebSocket port
    b.job_id = vim.fn.jobstart({ binary_path, "--daemon" }, {
        cwd = cwd,
        stdout_buffered = false,
        on_stdout = vim.schedule_wrap(function(_, data)
            M._on_stdout(data, my_tabid)
        end),
        on_stderr = vim.schedule_wrap(function(_, data)
            M._on_stderr(data, my_tabid)
        end),
        on_exit = vim.schedule_wrap(function(_, code)
            M._on_exit(code, my_tabid)
        end),
    })

    if b.job_id <= 0 then
        vim.notify("Banjo: Failed to start binary", vim.log.levels.ERROR)
        return
    end

    -- Track selection changes
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = b.autocmd_group,
        callback = function()
            -- Only track if we're in the correct tab
            if vim.api.nvim_get_current_tabpage() ~= my_tabid then
                return
            end
            local mode = vim.fn.mode()
            if mode == "v" or mode == "V" or mode == "\22" then
                local my_b = bridges[my_tabid]
                if my_b then
                    my_b.last_selection = M._capture_selection()
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd("ModeChanged", {
        group = b.autocmd_group,
        pattern = "[vV\22]*:*",
        callback = function()
            -- Only track if we're in the correct tab
            if vim.api.nvim_get_current_tabpage() ~= my_tabid then
                return
            end
            local my_b = bridges[my_tabid]
            if my_b then
                my_b.last_selection = M._capture_selection()
            end
        end,
    })

    -- Graceful shutdown on Vim exit
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = b.autocmd_group,
        callback = function()
            -- Save history before exit
            local history = require("banjo.history")
            history.save()

            -- Stop reconnection and close cleanly for THIS tab
            local my_b = bridges[my_tabid]
            if my_b then
                my_b.reconnect.enabled = false
                if my_b.reconnect.timer then
                    my_b.reconnect.timer:stop()
                    my_b.reconnect.timer:close()
                    my_b.reconnect.timer = nil
                end
                if my_b.client then
                    ws_client.close(my_b.client)
                    my_b.client = nil
                end
                if my_b.job_id then
                    vim.fn.jobstop(my_b.job_id)
                    my_b.job_id = nil
                end
            end
        end,
    })
end

function M.stop()
    local b = get_bridge()
    -- Disable reconnection
    b.reconnect.enabled = false
    if b.reconnect.timer then
        b.reconnect.timer:stop()
        b.reconnect.timer:close()
        b.reconnect.timer = nil
    end

    if b.client then
        ws_client.close(b.client)
        b.client = nil
    end

    if b.job_id then
        vim.fn.jobstop(b.job_id)
        b.job_id = nil
    end

    b.mcp_port = nil

    if b.autocmd_group then
        vim.api.nvim_del_augroup_by_id(b.autocmd_group)
        b.autocmd_group = nil
    end
    b.state.connected = false
    b.state.session_id = nil
    b.state.models = {}
    b.state.model = nil
    b.state.session_active = false
    b.state.session_start_time = nil
end

function M.is_running()
    local b = get_bridge()
    return b.client ~= nil and ws_client.is_connected(b.client) and b.state.connected
end

function M.get_mcp_port()
    local b = get_bridge()
    return b.mcp_port
end

-- Process stdout from binary (only used for initial ready notification)
-- Note: vim.fn.jobstart sends data as array of lines (newlines stripped)
function M._on_stdout(data, tabid)
    lua_debug("[bridge] _on_stdout called")
    local b = bridges[tabid]
    if not b then return end
    for _, line in ipairs(data) do
        if line ~= "" then
            lua_debug("[bridge] stdout line: " .. line:sub(1, 100))
            local ok, msg = pcall(vim.json.decode, line)
            if ok and msg.method == "ready" and msg.params and msg.params.mcp_port then
                lua_debug("[bridge] got ready notification, port=" .. tostring(msg.params.mcp_port))
                b.mcp_port = msg.params.mcp_port
                M._connect_websocket(b.mcp_port, tabid)
            elseif not ok then
                vim.notify("Banjo: Failed to parse stdout: " .. line, vim.log.levels.ERROR)
            end
        end
    end
end

-- Process stderr from binary (debug/error output)
-- Only show ERROR and WARN level logs to avoid flooding notifications
function M._on_stderr(data, tabid)
    local b = bridges[tabid]
    if not b then return end
    for _, line in ipairs(data) do
        if line ~= "" then
            lua_debug("[bridge] stderr: " .. line)
            -- Only notify for ERROR/WARN level (check for level prefix after timestamp)
            if line:match("%[ERROR%]") then
                vim.notify("Banjo: " .. line, vim.log.levels.ERROR)
            elseif line:match("%[WARN%]") then
                vim.notify("Banjo: " .. line, vim.log.levels.WARN)
            end
            -- DEBUG/INFO/TRACE go to /tmp/banjo-lua-debug.log only
        end
    end
end

function M._connect_websocket(port, tabid)
    lua_debug("[bridge] _connect_websocket: port=" .. tostring(port))
    local b = bridges[tabid]
    if not b then return end
    local my_tabid = tabid
    b.client = ws_client.new({
        on_message = function(message)
            vim.schedule(function()
                local ok, msg = pcall(vim.json.decode, message)
                if ok then
                    M._handle_message(msg, my_tabid)
                else
                    vim.notify("Banjo: Failed to parse WebSocket message", vim.log.levels.ERROR)
                    local my_b = bridges[my_tabid]
                    if my_b and vim.api.nvim_tabpage_is_valid(my_tabid) then
                        -- Switch to correct tab for panel operations
                        local current_tab = vim.api.nvim_get_current_tabpage()
                        local need_switch = current_tab ~= my_tabid
                        if need_switch then
                            vim.api.nvim_set_current_tabpage(my_tabid)
                        end

                        panel.append_status("Error: Invalid message from backend")

                        -- Restore original tab
                        if need_switch and vim.api.nvim_tabpage_is_valid(current_tab) then
                            vim.api.nvim_set_current_tabpage(current_tab)
                        end
                    end
                end
            end)
        end,
        on_connect = function()
            vim.schedule(function()
                local my_b = bridges[my_tabid]
                if not my_b or not vim.api.nvim_tabpage_is_valid(my_tabid) then return end
                my_b.state.connected = false
                my_b.state.session_id = nil
                my_b.state.models = {}
                my_b.state.model = nil
                -- Reset reconnection state on successful connect
                my_b.reconnect.attempt = 0
                lua_debug("[bridge] on_connect: sending ACP initialize")

                -- Send ACP initialize request
                M._send_request(my_tabid, "initialize", {
                    protocolVersion = 1,
                    clientCapabilities = vim.empty_dict(),
                    clientInfo = { name = "banjo-nvim", version = "0.1.0" },
                }, function(result, err)
                    if err then
                        vim.notify("Banjo: Initialize failed: " .. (err.message or "unknown"), vim.log.levels.ERROR)
                        return
                    end
                    lua_debug("[bridge] initialize response received, sending session/new")

                    -- Store agent info
                    if result and result.agentInfo then
                        my_b.state.version = result.agentInfo.version
                    end

                    -- Create new session
                    M._send_request(my_tabid, "session/new", {
                        cwd = my_b.reconnect.cwd or vim.fn.getcwd(),
                    }, function(sess_result, sess_err)
                        if sess_err then
                            vim.notify("Banjo: Session creation failed: " .. (sess_err.message or "unknown"), vim.log.levels.ERROR)
                            return
                        end
                        lua_debug("[bridge] session/new response: " .. vim.json.encode(sess_result or {}))

                        if sess_result then
                            my_b.state.session_id = sess_result.sessionId
                            if sess_result.modes then
                                my_b.state.mode = sess_result.modes.currentModeId or my_b.state.mode
                            end
                            if sess_result.models then
                                my_b.state.models = sess_result.models.availableModels or {}
                                my_b.state.model = sess_result.models.currentModelId or my_b.state.model
                            end
                        end

                        vim.notify("Banjo: Connected", vim.log.levels.INFO)
                        my_b.state.connected = true

                        -- Switch to correct tab for panel operations
                        local current_tab = vim.api.nvim_get_current_tabpage()
                        local need_switch = current_tab ~= my_tabid
                        if need_switch and vim.api.nvim_tabpage_is_valid(my_tabid) then
                            vim.api.nvim_set_current_tabpage(my_tabid)
                        end

                        panel._update_status()

                        -- Restore preserved input if any
                        if my_b.preserved.input_text and my_b.preserved.input_text ~= "" then
                            panel.set_input_text(my_b.preserved.input_text)
                            my_b.preserved.input_text = nil
                        end

                        -- Restore permission mode if previously set
                        if my_b.preserved.permission_mode then
                            M.set_permission_mode(my_b.preserved.permission_mode)
                        end
                        if my_b.preserved.engine then
                            M.set_engine(my_b.preserved.engine)
                        end
                        if my_b.preserved.model then
                            M.set_model(my_b.preserved.model)
                        end

                        if need_switch and vim.api.nvim_tabpage_is_valid(current_tab) then
                            vim.api.nvim_set_current_tabpage(current_tab)
                        end
                    end)
                end)
            end)
        end,
        on_disconnect = function(code, reason)
            vim.schedule(function()
                vim.notify("Banjo: Disconnected (" .. code .. ")", vim.log.levels.WARN)
                local my_b = bridges[my_tabid]
                if my_b then
                    my_b.client = nil
                    my_b.state.connected = false
                    my_b.state.session_id = nil
                    my_b.state.models = {}
                    my_b.state.model = nil
                    my_b.state.session_active = false
                    my_b.state.session_start_time = nil
                    -- Switch to correct tab for panel operations
                    local current_tab = vim.api.nvim_get_current_tabpage()
                    local need_switch = current_tab ~= my_tabid
                    if need_switch and vim.api.nvim_tabpage_is_valid(my_tabid) then
                        vim.api.nvim_set_current_tabpage(my_tabid)
                    end

                    panel._update_status()

                    -- Restore original tab
                    if need_switch and vim.api.nvim_tabpage_is_valid(current_tab) then
                        vim.api.nvim_set_current_tabpage(current_tab)
                    end
                end
                -- WebSocket reconnection is handled by process restart
            end)
        end,
        on_error = function(err)
            vim.schedule(function()
                vim.notify("Banjo: " .. err, vim.log.levels.ERROR)
                if bridges[my_tabid] and vim.api.nvim_tabpage_is_valid(my_tabid) then
                    -- Switch to correct tab for panel operations
                    local current_tab = vim.api.nvim_get_current_tabpage()
                    local need_switch = current_tab ~= my_tabid
                    if need_switch then
                        vim.api.nvim_set_current_tabpage(my_tabid)
                    end

                    panel._update_status()

                    -- Restore original tab
                    if need_switch and vim.api.nvim_tabpage_is_valid(current_tab) then
                        vim.api.nvim_set_current_tabpage(current_tab)
                    end
                end
            end)
        end,
    })

    ws_client.connect(b.client, "127.0.0.1", port, "/acp")
end

function M._on_exit(code, tabid)
    local b = bridges[tabid]
    if not b then return end
    b.job_id = nil
    b.mcp_port = nil
    if b.client then
        ws_client.close(b.client)
        b.client = nil
    end

    -- Save session before clearing state
    if b.state.session_id and b.state.session_active then
        local sessions = require("banjo.sessions")
        sessions.save(b.state.session_id, {
            history = panel.get_history_entries(),
            input_text = panel.get_input_text(),
            timestamp = os.time(),
        })
    end

    -- Clear session b.state on disconnect
    b.state.connected = false
    b.state.session_active = false
    b.state.session_start_time = nil
    b.state.session_id = nil
    b.state.models = {}
    b.state.model = nil

    if code ~= 0 then
        vim.notify("Banjo: Process exited with code " .. code, vim.log.levels.WARN)
    end

    -- Schedule reconnection if enabled
    if b.reconnect.enabled and b.reconnect.binary_path then
        -- Preserve current input text
        local current_input = panel.get_input_text()
        if current_input and current_input ~= "" then
            b.preserved.input_text = current_input
        end

        -- Calculate delay with exponential backoff
        local delay_ms = math.min(
            b.reconnect.base_delay_ms * math.pow(2, b.reconnect.attempt),
            b.reconnect.max_delay_ms
        )
        b.reconnect.attempt = b.reconnect.attempt + 1

        vim.notify(string.format("Banjo: Reconnecting in %.1fs (attempt %d)", delay_ms / 1000, b.reconnect.attempt), vim.log.levels.INFO)

        -- Schedule reconnection
        local my_tabid = b.tabid
        b.reconnect.timer = vim.loop.new_timer()
        if b.reconnect.timer then
            b.reconnect.timer:start(delay_ms, 0, vim.schedule_wrap(function()
                local my_b = bridges[my_tabid]
                if not my_b then return end
                if my_b.reconnect.timer then
                    my_b.reconnect.timer:close()
                    my_b.reconnect.timer = nil
                end
                if my_b.reconnect.enabled and my_b.reconnect.binary_path then
                    -- Validate tab still exists before switching
                    if not vim.api.nvim_tabpage_is_valid(my_tabid) then
                        return
                    end
                    -- Switch to the correct tab before starting
                    local current_tab = vim.api.nvim_get_current_tabpage()
                    if current_tab ~= my_tabid then
                        vim.api.nvim_set_current_tabpage(my_tabid)
                    end
                    M.start(my_b.reconnect.binary_path, my_b.reconnect.cwd)
                end
            end))
        end
    end
end

function M._handle_message(msg, tabid)
    tabid = tabid or vim.api.nvim_get_current_tabpage()
    local b = bridges[tabid]
    if not b then return end

    -- Handle JSON-RPC response (has result or error, no method)
    if msg.result ~= nil or msg.error ~= nil then
        M._handle_response(msg, tabid)
        return
    end

    local method = msg.method
    if not method then return end

    -- Handle JSON-RPC request (has method and id) - server asking us something
    if msg.id ~= nil then
        M._handle_request(msg, tabid)
        return
    end

    -- Handle JSON-RPC notification (has method, no id)
    M._handle_notification(msg, tabid)
end

-- Handle responses to our requests
function M._handle_response(msg, tabid)
    local b = bridges[tabid]
    if not b then return end

    local id = msg.id
    if id == nil then return end

    local callback = b.acp.pending_requests[id]
    if callback then
        b.acp.pending_requests[id] = nil
        callback(msg.result, msg.error)
    end
end

-- Handle requests from server (e.g., permission requests)
function M._handle_request(msg, tabid)
    local b = bridges[tabid]
    if not b then return end

    local method = msg.method
    lua_debug("_handle_request: " .. method .. " id=" .. tostring(msg.id))

    -- Switch to correct tab for UI operations
    local current_tab = vim.api.nvim_get_current_tabpage()
    local need_switch = current_tab ~= tabid
    if need_switch and vim.api.nvim_tabpage_is_valid(tabid) then
        vim.api.nvim_set_current_tabpage(tabid)
    end

    if method == "session/request_permission" then
        M._handle_acp_permission_request(msg, tabid)
    else
        -- Unknown request - send error response
        M._send_response(tabid, msg.id, nil, { code = -32601, message = "Method not found" })
    end

    if need_switch and vim.api.nvim_tabpage_is_valid(current_tab) then
        vim.api.nvim_set_current_tabpage(current_tab)
    end
end

-- Handle ACP permission request
function M._handle_acp_permission_request(msg, tabid)
    local params = msg.params or {}
    local tool_call = params.toolCall or {}
    local options = params.options or {}

    local title = tool_call.title or "Unknown tool"
    local raw_input = tool_call.rawInput

    notify_background(tabid, "Banjo: Permission needed for " .. title, vim.log.levels.WARN)

    ui_prompt.permission({
        tool_name = title,
        tool_input = raw_input and vim.json.encode(raw_input) or nil,
        options = options,
        on_action = function(decision, option_id)
            local outcome
            if decision == "allow" or decision == "allow_always" then
                outcome = { outcome = "selected", optionId = option_id or "allow_once" }
            else
                outcome = { outcome = "cancelled" }
            end
            M._send_response(tabid, msg.id, { outcome = outcome }, nil)
        end,
    })
end

-- Handle notifications from server
function M._handle_notification(msg, tabid)
    local b = bridges[tabid]
    if not b then return end

    local method = msg.method
    local params = msg.params or {}

    -- Switch to correct tab for panel operations
    local current_tab = vim.api.nvim_get_current_tabpage()
    local need_switch = current_tab ~= tabid
    if need_switch and vim.api.nvim_tabpage_is_valid(tabid) then
        vim.api.nvim_set_current_tabpage(tabid)
    end

    if method == "session/update" then
        M._handle_session_update(params, tabid)
    elseif method == "session/end" then
        b.state.session_active = false
        b.state.session_start_time = nil
        panel._update_status()
        panel._stop_session_timer()
        notify_background(tabid, "Banjo: Task complete", vim.log.levels.INFO)
    -- Legacy protocol support (for backward compat during transition)
    elseif method == "session_start" then
        b.state.session_active = true
        b.state.session_start_time = vim.loop.now()
        panel._start_session_timer()
    elseif method == "session_end" then
        b.state.session_active = false
        b.state.session_start_time = nil
        panel._update_status()
        panel._stop_session_timer()
    elseif method == "stream_start" then
        local engine = params.engine or "claude"
        panel.start_stream(engine)
    elseif method == "stream_chunk" then
        panel.append(params.text or "", params.is_thought)
    elseif method == "stream_end" then
        panel.end_stream()
        notify_background(tabid, "Banjo: Task complete", vim.log.levels.INFO)
    elseif method == "tool_call" then
        panel.show_tool_call(params.id, params.name or "?", params.label or "", params.input)
    elseif method == "tool_result" then
        panel.show_tool_result(params.id, params.status)
    elseif method == "tool_request" then
        M._handle_tool_request(params)
    elseif method == "approval_request" then
        M._show_approval_prompt(params)
    elseif method == "permission_request" then
        M._show_permission_prompt(params)
    elseif method == "error_msg" then
        local message = params.message or "Unknown error"
        vim.notify("Banjo: " .. message, vim.log.levels.ERROR)
        notify_background(tabid, "Banjo: Error - " .. message, vim.log.levels.ERROR)
    elseif method == "status" then
        local text = params.text or ""
        vim.notify("Banjo: " .. text, vim.log.levels.INFO)
    elseif method == "debug_info" then
        b.debug_info = params
    elseif method == "state" then
        b.state.engine = params.engine or b.state.engine
        b.state.model = params.model
        b.state.mode = params.mode or b.state.mode
        b.state.session_id = params.session_id
        b.state.connected = params.connected or false
        b.state.models = params.models or {}
        b.state.version = params.version
        panel._update_status()
    end

    if need_switch and vim.api.nvim_tabpage_is_valid(current_tab) then
        vim.api.nvim_set_current_tabpage(current_tab)
    end
end

-- Handle ACP session/update notification
function M._handle_session_update(params, tabid)
    local b = bridges[tabid]
    if not b then return end

    local update = params.update or {}
    local update_type = update.sessionUpdate

    if update_type == "agent_message_chunk" then
        -- Text streaming
        local content = update.content or {}
        local text = content.text or ""
        if text ~= "" then
            -- Start stream if not already
            if not b.state.session_active then
                b.state.session_active = true
                b.state.session_start_time = vim.loop.now()
                panel.start_stream(b.state.engine)
                panel._start_session_timer()
            end
            panel.append(text, false)
        end
    elseif update_type == "agent_thought_chunk" then
        -- Thought streaming
        local content = update.content or {}
        local text = content.text or ""
        if text ~= "" then
            if not b.state.session_active then
                b.state.session_active = true
                b.state.session_start_time = vim.loop.now()
                panel.start_stream(b.state.engine)
                panel._start_session_timer()
            end
            panel.append(text, true)
        end
    elseif update_type == "tool_call" then
        -- Tool invocation
        local tool_id = update.toolCallId or ""
        local title = update.title or "?"
        local kind = update.kind or "other"
        local raw_input = update.rawInput
        panel.show_tool_call(tool_id, title, title, raw_input and vim.json.encode(raw_input) or nil)
    elseif update_type == "tool_call_update" then
        -- Tool result
        local tool_id = update.toolCallId or ""
        local status = update.status or "completed"
        panel.show_tool_result(tool_id, status)
    elseif update_type == "current_mode_update" then
        -- Permission mode changed
        b.state.mode = update.currentModeId or b.state.mode
        panel._update_status()
    elseif update_type == "current_model_update" then
        -- Model changed
        b.state.model = update.currentModelId or b.state.model
        panel._update_status()
    end
end

-- Approval prompt handling
function M._show_approval_prompt(params)
    local b = get_bridge()
    local my_tabid = b.tabid
    local id = params.id or "unknown"

    ui_prompt.approval({
        tool_name = params.tool_name or "unknown",
        risk_level = params.risk_level or "medium",
        arguments = params.arguments,
        on_action = function(decision)
            local my_b = bridges[my_tabid]
            if my_b and my_b.client and ws_client.is_connected(my_b.client) then
                local response = {
                    jsonrpc = "2.0",
                    method = "approval_response",
                    params = { id = id, decision = decision },
                }
                ws_client.send(my_b.client, vim.json.encode(response))
            end
        end,
    })
end

-- Permission prompt handling (Claude Code)
function M._show_permission_prompt(params)
    local b = get_bridge()
    local my_tabid = b.tabid
    local id = params.id or "unknown"

    ui_prompt.permission({
        tool_name = params.tool_name or "unknown",
        tool_input = params.tool_input,
        on_action = function(decision)
            local my_b = bridges[my_tabid]
            if my_b and my_b.client and ws_client.is_connected(my_b.client) then
                local response = {
                    jsonrpc = "2.0",
                    method = "permission_response",
                    params = { id = id, decision = decision },
                }
                ws_client.send(my_b.client, vim.json.encode(response))
            end
        end,
    })
end

function M.get_state()
    local b = get_bridge()
    return vim.tbl_extend("force", b.state, {
        reconnect_attempt = b.reconnect.attempt,
    })
end

function M.get_debug_info()
    local b = get_bridge()
    b.debug_info = nil
    local params = {}
    if b.state.session_id then
        params.sessionId = b.state.session_id
    end
    M._send_notification("get_debug_info", params)
    -- Wait for response (up to 1s)
    local start = vim.loop.now()
    while not b.debug_info and (vim.loop.now() - start) < 1000 do
        vim.wait(50, function() return b.debug_info ~= nil end, 50)
        vim.loop.run("nowait")
    end
    return b.debug_info
end

function M.set_engine(engine)
    local b = get_bridge()
    b.preserved.engine = engine
    if not b.state.session_id then
        b.state.engine = engine
        panel._update_status()
        return
    end
    -- ACP uses session/set_config_option for engine
    M._send_notification("session/set_config_option", {
        sessionId = b.state.session_id,
        configId = "route",
        value = engine,
    })
    b.state.engine = engine
    panel._update_status()
end

function M.set_model(model)
    local b = get_bridge()
    b.preserved.model = model
    if not b.state.session_id then
        b.state.model = model
        panel._update_status()
        return
    end
    -- ACP uses session/set_model
    M._send_notification("session/set_model", {
        sessionId = b.state.session_id,
        modelId = model,
    })
    b.state.model = model
    panel._update_status()
end

function M.set_permission_mode(mode)
    local b = get_bridge()
    b.preserved.permission_mode = mode
    if not b.state.session_id then
        b.state.mode = mode
        panel._update_status()
        return
    end
    -- ACP uses session/set_mode
    M._send_notification("session/set_mode", {
        sessionId = b.state.session_id,
        modeId = mode,
    })
    b.state.mode = mode
    panel._update_status()
end

function M.request_state()
    -- In ACP, state is obtained from session/new response
    -- No explicit get_state; update status from current state
    panel._update_status()
end

function M._handle_tool_request(params)
    -- NOTE: Assumes _handle_message has already switched to correct tab context
    local b = get_bridge()
    if not params then return end

    local tool = params.tool
    local correlation_id = params.correlation_id

    local result, err
    if tool == "getCurrentSelection" or tool == "getLatestSelection" then
        result = M._get_current_selection()
    elseif tool == "getOpenEditors" then
        result = M._get_open_editors()
    elseif tool == "getDiagnostics" then
        result = M._get_diagnostics()
    elseif tool == "checkDocumentDirty" then
        local file = params.arguments and params.arguments.filePath
        result = M._check_dirty(file)
    elseif tool == "saveDocument" then
        local file = params.arguments and params.arguments.filePath
        result = M._save_document(file)
    elseif tool == "openDiff" then
        result = M._open_diff(params.arguments)
    elseif tool == "closeDiff" or tool == "closeAllDiffTabs" then
        result = M._close_diff()
    else
        err = "Unknown tool: " .. (tool or "nil")
    end

    M._send_tool_response(correlation_id, result, err)
end

function M._capture_selection()
    local b = get_bridge()
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")

    if start_pos[2] > end_pos[2] or (start_pos[2] == end_pos[2] and start_pos[3] > end_pos[3]) then
        start_pos, end_pos = end_pos, start_pos
    end

    local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
    if #lines == 0 then return nil end

    if #lines == 1 then
        lines[1] = lines[1]:sub(start_pos[3], end_pos[3])
    else
        lines[1] = lines[1]:sub(start_pos[3])
        lines[#lines] = lines[#lines]:sub(1, end_pos[3])
    end

    return {
        content = table.concat(lines, "\n"),
        file = vim.api.nvim_buf_get_name(0),
        range = {
            start_line = start_pos[2],
            start_col = start_pos[3],
            end_line = end_pos[2],
            end_col = end_pos[3],
        },
    }
end

function M._get_current_selection()
    local b = get_bridge()
    if b.last_selection and b.last_selection.content and b.last_selection.content ~= "" then
        return {
            text = b.last_selection.content,
            file = b.last_selection.file or "",
            range = b.last_selection.range,
        }
    end
    return { text = "", file = vim.api.nvim_buf_get_name(0) }
end

function M._get_open_editors()
    local b = get_bridge()
    local editors = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then
                table.insert(editors, {
                    path = name,
                    isActive = buf == vim.api.nvim_get_current_buf(),
                })
            end
        end
    end
    return editors
end

function M._get_diagnostics()
    local b = get_bridge()
    local diagnostics = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            local buf_diags = vim.diagnostic.get(buf)
            local file = vim.api.nvim_buf_get_name(buf)
            for _, d in ipairs(buf_diags) do
                table.insert(diagnostics, {
                    file = file,
                    line = d.lnum + 1,
                    column = d.col + 1,
                    message = d.message,
                    severity = d.severity,
                })
            end
        end
    end
    return diagnostics
end

function M._check_dirty(file)
    local b = get_bridge()
    if not file then
        return { isDirty = false }
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == file then
            return { isDirty = vim.bo[buf].modified }
        end
    end
    return { isDirty = false }
end

function M._save_document(file)
    local b = get_bridge()
    if not file then
        return { success = false, error = "No file specified" }
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == file then
            local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
                vim.cmd("write")
            end)
            if ok then
                return { success = true }
            else
                return { success = false, error = tostring(err) }
            end
        end
    end
    return { success = false, error = "File not found in buffers" }
end

function M._open_diff(args)
    local b = get_bridge()
    if not args or not args.oldContent or not args.newContent then
        return { success = false, error = "Missing diff content" }
    end

    local old_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(old_buf, 0, -1, false, vim.split(args.oldContent, "\n"))
    vim.api.nvim_buf_set_name(old_buf, "banjo://diff/old")

    local new_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, vim.split(args.newContent, "\n"))
    vim.api.nvim_buf_set_name(new_buf, "banjo://diff/new")

    vim.cmd("tabnew")
    vim.api.nvim_set_current_buf(old_buf)
    vim.cmd("diffthis")
    vim.cmd("vsplit")
    vim.api.nvim_set_current_buf(new_buf)
    vim.cmd("diffthis")

    return { success = true }
end

function M._close_diff()
    local b = get_bridge()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(buf)
        if name:match("^banjo://diff/") then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    end
    vim.cmd("diffoff!")
    return { success = true }
end

function M._send_tool_response(correlation_id, result, err)
    local b = get_bridge()
    if not b.client or not ws_client.is_connected(b.client) then
        return
    end

    local response = {
        jsonrpc = "2.0",
        method = "tool_response",
        params = {
            correlation_id = correlation_id,
        },
    }

    if err then
        response.params.error = err
    else
        response.params.result = vim.json.encode(result)
    end

    ws_client.send(b.client, vim.json.encode(response))
end

-- Send ACP request (with id, expects response)
function M._send_request(tabid, method, params, callback)
    local b = bridges[tabid]
    if not b then return end
    if not b.client or not ws_client.is_connected(b.client) then
        lua_debug("_send_request: not connected")
        return
    end

    local id = b.acp.next_id
    b.acp.next_id = b.acp.next_id + 1

    if callback then
        b.acp.pending_requests[id] = callback
    end

    local msg = vim.json.encode({
        jsonrpc = "2.0",
        id = id,
        method = method,
        params = params,
    })
    lua_debug("_send_request: " .. method .. " id=" .. tostring(id))
    ws_client.send(b.client, msg)
end

-- Send ACP response (for requests from server like permission)
function M._send_response(tabid, id, result, err)
    local b = bridges[tabid]
    if not b then return end
    if not b.client or not ws_client.is_connected(b.client) then
        return
    end

    local msg
    if err then
        msg = vim.json.encode({
            jsonrpc = "2.0",
            id = id,
            error = err,
        })
    else
        msg = vim.json.encode({
            jsonrpc = "2.0",
            id = id,
            result = result,
        })
    end
    lua_debug("_send_response: id=" .. tostring(id))
    ws_client.send(b.client, msg)
end

function M._send_notification(method, params)
    lua_debug("_send_notification: " .. method)
    local b = get_bridge()
    if not b.client then
        lua_debug("  no client!")
        return
    end
    if not ws_client.is_connected(b.client) then
        lua_debug("  not connected, state=" .. tostring(b.client.state))
        return
    end

    local msg = vim.json.encode({
        jsonrpc = "2.0",
        method = method,
        params = params,
    })
    lua_debug("  sending: " .. msg:sub(1, 100))
    ws_client.send(b.client, msg)
    lua_debug("  sent!")
end

function M.send_prompt(text, files)
    local b = get_bridge()
    if not b.client or not ws_client.is_connected(b.client) then
        vim.notify("Banjo: Not connected", vim.log.levels.WARN)
        return
    end
    if not b.state.session_id then
        vim.notify("Banjo: No active session", vim.log.levels.WARN)
        return
    end

    -- Build ACP prompt request
    local params = {
        sessionId = b.state.session_id,
        prompt = {
            content = {
                { type = "text", text = text },
            },
        },
    }

    -- Add file references if provided
    if files and #files > 0 then
        for _, file in ipairs(files) do
            table.insert(params.prompt.content, {
                type = "text",
                text = "File: " .. file.path .. (file.content and ("\n```\n" .. file.content .. "\n```") or ""),
            })
        end
    end

    M._send_notification("session/prompt", params)
end

function M.cancel()
    local b = get_bridge()
    -- Clear session state
    b.state.session_active = false
    b.state.session_start_time = nil

    if b.state.session_id then
        M._send_notification("session/cancel", { sessionId = b.state.session_id })
    end
end

function M.toggle_nudge()
    -- Nudge is not part of ACP protocol - keep as notification for now
    M._send_notification("nudge_toggle", {})
end

-- Expose internals for testing
M._handle_message = M._handle_message
M._send_tool_response = M._send_tool_response
M._get_current_selection = M._get_current_selection
M._get_open_editors = M._get_open_editors
M._get_diagnostics = M._get_diagnostics
M._check_dirty = M._check_dirty
M._connect_websocket = M._connect_websocket
M._on_stdout = M._on_stdout
M._on_exit = M._on_exit

-- Cleanup a single bridge by tabid
local function cleanup_bridge(tabid)
    local old_b = bridges[tabid]
    if not old_b then return end

    if old_b.reconnect.timer then
        pcall(old_b.reconnect.timer.stop, old_b.reconnect.timer)
        pcall(old_b.reconnect.timer.close, old_b.reconnect.timer)
    end
    if old_b.client then
        pcall(ws_client.close, old_b.client)
    end
    if old_b.job_id then
        pcall(vim.fn.jobstop, old_b.job_id)
    end
    if old_b.autocmd_group then
        pcall(vim.api.nvim_del_augroup_by_id, old_b.autocmd_group)
    end
    bridges[tabid] = nil
    pcall(panel.cleanup_tab, tabid)
end

-- Global TabClosed autocmd (registered once at module load)
-- Note: ev.match is tab NUMBER (display position), NOT tabpage handle.
-- We must iterate and cleanup any bridges whose handles are no longer valid.
vim.api.nvim_create_autocmd("TabClosed", {
    callback = function()
        local valid_tabs = {}
        for _, handle in ipairs(vim.api.nvim_list_tabpages()) do
            valid_tabs[handle] = true
        end
        for tabid, _ in pairs(bridges) do
            if not valid_tabs[tabid] then
                cleanup_bridge(tabid)
            end
        end
    end,
})

return M
