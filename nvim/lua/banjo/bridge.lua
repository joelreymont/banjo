-- Bridge between Neovim and Banjo backend via WebSocket
local ws_client = require("banjo.websocket.client")
local panel = require("banjo.panel")

local M = {}

-- Wire up bidirectional reference
panel.set_bridge(M)

local client = nil
local job_id = nil  -- Process handle for cleanup
local mcp_port = nil
local last_selection = nil
local autocmd_group = nil

-- Current state from backend
local state = {
    engine = "claude",
    model = nil,
    mode = "Default",
    session_id = nil,
    connected = false,
    session_active = false,
    session_start_time = nil,
}

-- Reconnection state
local reconnect = {
    attempt = 0,
    max_delay_ms = 30000,
    base_delay_ms = 1000,
    timer = nil,
    enabled = true,
    binary_path = nil,
    cwd = nil,
}

-- State preservation across reconnects
local preserved = {
    input_text = nil,
}

function M.start(binary_path, cwd)
    if client and ws_client.is_connected(client) then
        return
    end

    -- Save for reconnection
    reconnect.binary_path = binary_path
    reconnect.cwd = cwd
    reconnect.enabled = true

    autocmd_group = vim.api.nvim_create_augroup("BanjoEvents", { clear = true })

    -- Spawn the binary to get the WebSocket port
    job_id = vim.fn.jobstart({ binary_path, "--nvim" }, {
        cwd = cwd,
        stdout_buffered = false,
        on_stdout = function(_, data)
            M._on_stdout(data)
        end,
        on_exit = function(_, code)
            M._on_exit(code)
        end,
    })

    if job_id <= 0 then
        vim.notify("Banjo: Failed to start binary", vim.log.levels.ERROR)
        return
    end

    -- Track selection changes
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = autocmd_group,
        callback = function()
            local mode = vim.fn.mode()
            if mode == "v" or mode == "V" or mode == "\22" then
                last_selection = M._capture_selection()
            end
        end,
    })

    vim.api.nvim_create_autocmd("ModeChanged", {
        group = autocmd_group,
        pattern = "[vV\22]*:*",
        callback = function()
            last_selection = M._capture_selection()
        end,
    })

    -- Graceful shutdown on Vim exit
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = autocmd_group,
        callback = function()
            -- Save history before exit
            local history = require("banjo.history")
            history.save()

            -- Stop reconnection and close cleanly
            M.stop()
        end,
    })
end

function M.stop()
    -- Disable reconnection
    reconnect.enabled = false
    if reconnect.timer then
        reconnect.timer:stop()
        reconnect.timer:close()
        reconnect.timer = nil
    end

    if client then
        ws_client.close(client)
        client = nil
    end

    if job_id then
        vim.fn.jobstop(job_id)
        job_id = nil
    end

    mcp_port = nil

    if autocmd_group then
        vim.api.nvim_del_augroup_by_id(autocmd_group)
        autocmd_group = nil
    end
end

function M.is_running()
    return client ~= nil and ws_client.is_connected(client)
end

function M.get_mcp_port()
    return mcp_port
end

-- Process stdout from binary (only used for initial ready notification)
-- Note: vim.fn.jobstart sends data as array of lines (newlines stripped)
function M._on_stdout(data)
    for _, line in ipairs(data) do
        if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok and msg.method == "ready" and msg.params and msg.params.mcp_port then
                mcp_port = msg.params.mcp_port
                M._connect_websocket(mcp_port)
            elseif not ok then
                vim.notify("Banjo: Failed to parse stdout: " .. line, vim.log.levels.ERROR)
            end
        end
    end
end

function M._connect_websocket(port)
    client = ws_client.new({
        on_message = function(message)
            local ok, msg = pcall(vim.json.decode, message)
            if ok then
                M._handle_message(msg)
            else
                vim.notify("Banjo: Failed to parse WebSocket message", vim.log.levels.ERROR)
                panel.append_status("Error: Invalid message from backend")
            end
        end,
        on_connect = function()
            -- Reset reconnection state on successful connect
            reconnect.attempt = 0
            vim.notify("Banjo: Connected", vim.log.levels.INFO)
            panel._update_status()

            -- Restore preserved input if any
            if preserved.input_text and preserved.input_text ~= "" then
                panel.set_input_text(preserved.input_text)
                preserved.input_text = nil
            end
        end,
        on_disconnect = function(code, reason)
            vim.notify("Banjo: Disconnected (" .. code .. ")", vim.log.levels.WARN)
            client = nil
            panel._update_status()
            -- WebSocket reconnection is handled by process restart
        end,
        on_error = function(err)
            vim.notify("Banjo: " .. err, vim.log.levels.ERROR)
            panel._update_status()
        end,
    })

    ws_client.connect(client, "127.0.0.1", port, "/nvim")
end

function M._on_exit(code)
    job_id = nil
    mcp_port = nil
    if client then
        ws_client.close(client)
        client = nil
    end

    -- Clear session state on disconnect
    state.session_active = false
    state.session_start_time = nil

    if code ~= 0 then
        vim.notify("Banjo: Process exited with code " .. code, vim.log.levels.WARN)
    end

    -- Schedule reconnection if enabled
    if reconnect.enabled and reconnect.binary_path then
        -- Preserve current input text
        local current_input = panel.get_input_text()
        if current_input and current_input ~= "" then
            preserved.input_text = current_input
        end

        -- Calculate delay with exponential backoff
        local delay_ms = math.min(
            reconnect.base_delay_ms * math.pow(2, reconnect.attempt),
            reconnect.max_delay_ms
        )
        reconnect.attempt = reconnect.attempt + 1

        vim.notify(string.format("Banjo: Reconnecting in %.1fs (attempt %d)", delay_ms / 1000, reconnect.attempt), vim.log.levels.INFO)

        -- Schedule reconnection
        reconnect.timer = vim.loop.new_timer()
        if reconnect.timer then
            reconnect.timer:start(delay_ms, 0, vim.schedule_wrap(function()
                if reconnect.timer then
                    reconnect.timer:close()
                    reconnect.timer = nil
                end
                if reconnect.enabled and reconnect.binary_path then
                    M.start(reconnect.binary_path, reconnect.cwd)
                end
            end))
        end
    end
end

function M._handle_message(msg)
    local method = msg.method
    if not method then
        -- JSON-RPC response, not notification
        return
    end

    if method == "stream_start" then
        local engine = msg.params and msg.params.engine or "claude"
        panel.start_stream(engine)
    elseif method == "stream_chunk" then
        local text = msg.params and msg.params.text or ""
        local is_thought = msg.params and msg.params.is_thought
        panel.append(text, is_thought)
    elseif method == "stream_end" then
        panel.end_stream()
    elseif method == "tool_call" then
        local name = msg.params and msg.params.name or "?"
        local label = msg.params and msg.params.label or ""
        panel.show_tool_call(name, label)
    elseif method == "tool_result" then
        local id = msg.params and msg.params.id
        local status = msg.params and msg.params.status
        panel.show_tool_result(id, status)
    elseif method == "tool_request" then
        M._handle_tool_request(msg.params)
    elseif method == "error_msg" then
        local message = msg.params and msg.params.message or "Unknown error"
        vim.notify("Banjo: " .. message, vim.log.levels.ERROR)
    elseif method == "status" then
        local text = msg.params and msg.params.text or ""
        vim.notify("Banjo: " .. text, vim.log.levels.INFO)
    elseif method == "state" then
        if msg.params then
            state.engine = msg.params.engine or state.engine
            state.model = msg.params.model
            state.mode = msg.params.mode or state.mode
            state.session_id = msg.params.session_id
            state.connected = msg.params.connected or false
            panel._update_status()
        end
    elseif method == "session_id" then
        if msg.params then
            state.session_id = msg.params.session_id
            panel._update_status()
        end
    elseif method == "approval_request" then
        if msg.params then
            M._show_approval_prompt(msg.params)
        end
    end
end

-- Approval prompt handling
function M._show_approval_prompt(params)
    local id = params.id or "unknown"
    local tool_name = params.tool_name or "unknown"
    local risk_level = params.risk_level or "medium"
    local arguments = params.arguments

    -- Build prompt message
    local lines = {
        "╭─────────────────────────────────────────╮",
        "│         APPROVAL REQUIRED               │",
        "├─────────────────────────────────────────┤",
        string.format("│ Tool: %-33s │", tool_name),
        string.format("│ Risk: %-33s │", risk_level),
        "├─────────────────────────────────────────┤",
    }

    if arguments then
        local arg_preview = arguments:sub(1, 60)
        if #arguments > 60 then
            arg_preview = arg_preview .. "..."
        end
        table.insert(lines, string.format("│ Args: %-33s │", arg_preview))
        table.insert(lines, "├─────────────────────────────────────────┤")
    end

    table.insert(lines, "│  [y] Approve    [n] Decline             │")
    table.insert(lines, "╰─────────────────────────────────────────╯")

    -- Create floating window
    local width = 45
    local height = #lines
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "none",
    })

    -- Highlight based on risk
    local hl = "Normal"
    if risk_level == "high" then
        hl = "DiagnosticError"
    elseif risk_level == "medium" then
        hl = "DiagnosticWarn"
    end
    vim.api.nvim_set_option_value("winhl", "Normal:" .. hl, { win = win })

    -- Set up keymaps
    local function close_and_respond(decision)
        vim.api.nvim_win_close(win, true)
        vim.api.nvim_buf_delete(buf, { force = true })
        M._send_notification("approval_response", { id = id, decision = decision })
    end

    vim.keymap.set("n", "y", function() close_and_respond("approve") end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "Y", function() close_and_respond("approve") end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "n", function() close_and_respond("decline") end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "N", function() close_and_respond("decline") end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "<Esc>", function() close_and_respond("decline") end, { buffer = buf, nowait = true })
    vim.keymap.set("n", "q", function() close_and_respond("decline") end, { buffer = buf, nowait = true })
end

function M.get_state()
    return vim.tbl_extend("force", state, {
        reconnect_attempt = reconnect.attempt,
    })
end

function M.set_engine(engine)
    M._send_notification("set_engine", { engine = engine })
end

function M.set_model(model)
    M._send_notification("set_model", { model = model })
end

function M.set_permission_mode(mode)
    M._send_notification("set_permission_mode", { mode = mode })
end

function M.request_state()
    M._send_notification("get_state", {})
end

function M._handle_tool_request(params)
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
    if last_selection and last_selection.content and last_selection.content ~= "" then
        return {
            text = last_selection.content,
            file = last_selection.file or "",
            range = last_selection.range,
        }
    end
    return { text = "", file = vim.api.nvim_buf_get_name(0) }
end

function M._get_open_editors()
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
    if not client or not ws_client.is_connected(client) then
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

    ws_client.send(client, vim.json.encode(response))
end

function M._send_notification(method, params)
    if not client or not ws_client.is_connected(client) then
        return
    end

    local msg = vim.json.encode({
        jsonrpc = "2.0",
        method = method,
        params = params,
    })
    ws_client.send(client, msg)
end

function M.send_prompt(text, files)
    if not client or not ws_client.is_connected(client) then
        vim.notify("Banjo: Not connected", vim.log.levels.WARN)
        return
    end

    local params = { text = text }
    if files then
        params.files = files
    end
    params.cwd = vim.fn.getcwd()

    M._send_notification("prompt", params)
end

function M.cancel()
    -- Clear session state
    state.session_active = false
    state.session_start_time = nil

    M._send_notification("cancel", {})
end

function M.toggle_nudge()
    M._send_notification("nudge_toggle", {})
end

-- Expose internals for testing
M._handle_message = M._handle_message
M._send_tool_response = M._send_tool_response
M._get_current_selection = M._get_current_selection
M._get_open_editors = M._get_open_editors
M._get_diagnostics = M._get_diagnostics
M._check_dirty = M._check_dirty

return M
