-- Banjo bridge: spawn and communicate with banjo binary via stdio
local M = {}

local job_id = nil
local pending_requests = {}
local request_id = 0
local stdout_buffer = ""
local mcp_port = nil

-- Selection tracking for getLatestSelection
local last_selection = nil
local autocmd_group = nil

local panel = nil -- lazy loaded

local function get_panel()
    if not panel then
        panel = require("banjo.panel")
    end
    return panel
end

function M.start(binary_path, cwd)
    if job_id then
        return
    end

    autocmd_group = vim.api.nvim_create_augroup("BanjoEvents", { clear = true })

    job_id = vim.fn.jobstart({ binary_path, "--nvim" }, {
        cwd = cwd,
        stdin = "pipe",
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

    -- Track visual mode exit to capture final selection
    vim.api.nvim_create_autocmd("ModeChanged", {
        group = autocmd_group,
        pattern = "[vV\22]*:*",
        callback = function()
            last_selection = M._capture_selection()
            -- Send selection change to Zig
            if last_selection and job_id then
                M._send_notification("selection_changed", last_selection)
            end
        end,
    })
end

function M.stop()
    if autocmd_group then
        vim.api.nvim_del_augroup_by_id(autocmd_group)
        autocmd_group = nil
    end
    if job_id then
        vim.fn.jobstop(job_id)
        job_id = nil
    end
    stdout_buffer = ""
    pending_requests = {}
    mcp_port = nil
end

function M.is_running()
    return job_id ~= nil and job_id > 0
end

function M.get_mcp_port()
    return mcp_port
end

function M._on_stdout(data)
    for _, chunk in ipairs(data) do
        stdout_buffer = stdout_buffer .. chunk
    end

    while true do
        local newline_pos = stdout_buffer:find("\n")
        if not newline_pos then
            break
        end

        local line = stdout_buffer:sub(1, newline_pos - 1)
        stdout_buffer = stdout_buffer:sub(newline_pos + 1)

        if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok then
                vim.schedule(function()
                    M._handle_message(msg)
                end)
            else
                vim.notify("Banjo: Invalid JSON: " .. line:sub(1, 100), vim.log.levels.WARN)
            end
        end
    end
end

function M._on_exit(code)
    job_id = nil
    mcp_port = nil
    if code ~= 0 then
        vim.notify("Banjo: Process exited with code " .. code, vim.log.levels.WARN)
    end
end

function M._handle_message(msg)
    if msg.method then
        -- Notification or request from Zig
        if msg.method == "ready" then
            if msg.params and msg.params.mcp_port then
                mcp_port = msg.params.mcp_port
                vim.notify("Banjo: MCP server on port " .. mcp_port, vim.log.levels.INFO)
            end
        elseif msg.method == "stream_chunk" then
            get_panel().append(msg.params.text, msg.params.is_thought)
        elseif msg.method == "stream_start" then
            get_panel().start_stream(msg.params.engine)
        elseif msg.method == "stream_end" then
            get_panel().end_stream()
        elseif msg.method == "tool_request" then
            M._handle_tool_request(msg)
        elseif msg.method == "tool_call" then
            get_panel().tool_call(msg.params)
        elseif msg.method == "tool_result" then
            get_panel().tool_result(msg.params)
        elseif msg.method == "status" then
            vim.notify("Banjo: " .. msg.params.text, vim.log.levels.INFO)
        elseif msg.method == "error_msg" then
            vim.notify("Banjo: " .. msg.params.message, vim.log.levels.ERROR)
        elseif msg.method == "session_id" then
            -- Store session IDs if needed
        end
    elseif msg.id and pending_requests[msg.id] then
        -- Response to our request
        pending_requests[msg.id](msg.result, msg.error)
        pending_requests[msg.id] = nil
    end
end

function M._handle_tool_request(msg)
    local tool = msg.params.tool
    local args = msg.params.arguments or {}
    local result, err

    if tool == "getCurrentSelection" then
        result = M._get_current_selection()
    elseif tool == "getLatestSelection" then
        result = last_selection or { text = "", file = "", range = nil }
    elseif tool == "getOpenEditors" then
        result = M._get_open_editors()
    elseif tool == "openFile" then
        result, err = M._open_file(args)
    elseif tool == "openDiff" then
        result, err = M._open_diff(args)
    elseif tool == "getDiagnostics" then
        result = M._get_diagnostics(args.uri)
    elseif tool == "checkDocumentDirty" then
        result = M._check_dirty(args.filePath)
    elseif tool == "saveDocument" then
        result, err = M._save_document(args.filePath)
    elseif tool == "close_tab" then
        result, err = M._close_tab(args.filePath)
    elseif tool == "closeAllDiffTabs" then
        result = M._close_all_diff_tabs()
    else
        err = "Unknown tool: " .. tool
    end

    M._send_tool_response(msg.params.correlation_id, result, err)
end

function M._capture_selection()
    local mode = vim.fn.mode()
    if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
        -- Not in visual mode, use marks if available
        local start_pos = vim.fn.getpos("'<")
        local end_pos = vim.fn.getpos("'>")
        if start_pos[2] == 0 then
            return nil
        end
        local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
        if #lines == 0 then
            return nil
        end
        return {
            text = table.concat(lines, "\n"),
            file = vim.api.nvim_buf_get_name(0),
            range = {
                start_line = start_pos[2],
                start_col = start_pos[3],
                end_line = end_pos[2],
                end_col = end_pos[3],
            },
        }
    end

    -- In visual mode
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    if start_pos[2] > end_pos[2] or (start_pos[2] == end_pos[2] and start_pos[3] > end_pos[3]) then
        start_pos, end_pos = end_pos, start_pos
    end

    local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)
    return {
        text = table.concat(lines, "\n"),
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
    local selection = M._capture_selection()
    if selection then
        return selection
    end
    return { text = "", file = vim.api.nvim_buf_get_name(0), range = nil }
end

function M._get_open_editors()
    local editors = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then
                table.insert(editors, {
                    filePath = name,
                    isActive = buf == vim.api.nvim_get_current_buf(),
                    isDirty = vim.bo[buf].modified,
                })
            end
        end
    end
    return editors
end

function M._open_file(args)
    local path = args.filePath
    if not path then
        return nil, "filePath required"
    end

    vim.cmd("edit " .. vim.fn.fnameescape(path))

    if args.startLine then
        vim.api.nvim_win_set_cursor(0, { args.startLine, 0 })
    end

    return { success = true }
end

function M._open_diff(args)
    local old_path = args.old_file_path
    local new_contents = args.new_file_contents

    if not old_path or not new_contents then
        return nil, "old_file_path and new_file_contents required"
    end

    -- Create temp file for new contents
    local temp_path = vim.fn.tempname()
    local f = io.open(temp_path, "w")
    if f then
        f:write(new_contents)
        f:close()
    end

    -- Open diff view
    vim.cmd("edit " .. vim.fn.fnameescape(old_path))
    vim.cmd("diffthis")
    vim.cmd("vsplit " .. vim.fn.fnameescape(temp_path))
    vim.cmd("diffthis")

    return { success = true }
end

function M._get_diagnostics(uri)
    local bufnr = 0
    if uri then
        bufnr = vim.uri_to_bufnr(uri)
    end

    local diagnostics = vim.diagnostic.get(bufnr)
    local result = {}

    for _, d in ipairs(diagnostics) do
        table.insert(result, {
            message = d.message,
            severity = d.severity,
            range = {
                start = { line = d.lnum, character = d.col },
                ["end"] = { line = d.end_lnum or d.lnum, character = d.end_col or d.col },
            },
        })
    end

    return result
end

function M._check_dirty(path)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == path then
            return { isDirty = vim.bo[buf].modified }
        end
    end
    return { isDirty = false }
end

function M._save_document(path)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == path then
            vim.api.nvim_buf_call(buf, function()
                vim.cmd("write")
            end)
            return { success = true }
        end
    end
    return nil, "Buffer not found"
end

function M._close_tab(path)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == path then
            vim.api.nvim_buf_delete(buf, { force = false })
            return { success = true }
        end
    end
    return nil, "Buffer not found"
end

function M._close_all_diff_tabs()
    vim.cmd("diffoff!")
    return { success = true }
end

function M._send_tool_response(correlation_id, result, err)
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

    local msg = vim.json.encode(response)
    vim.fn.chansend(job_id, msg .. "\n")
end

function M._send_notification(method, params)
    if not job_id then
        return
    end

    local msg = vim.json.encode({
        jsonrpc = "2.0",
        method = method,
        params = params,
    })
    vim.fn.chansend(job_id, msg .. "\n")
end

function M.send_prompt(text, files)
    if not job_id then
        vim.notify("Banjo: Not running", vim.log.levels.WARN)
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
    M._send_notification("cancel", {})
end

function M.toggle_nudge()
    M._send_notification("nudge_toggle", {})
end

return M
