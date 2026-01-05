-- Banjo panel: Chat UI with output section and input field
local M = {}

-- Buffer and window state
local output_buf = nil
local input_buf = nil
local output_win = nil
local input_win = nil
local ns_id = vim.api.nvim_create_namespace("banjo")
local ns_tools = vim.api.nvim_create_namespace("banjo_tools")
local ns_links = vim.api.nvim_create_namespace("banjo_links")

-- Streaming state
local is_streaming = false
local current_engine = nil
local pending_scroll = false

-- Tool tracking for in-place updates
local tool_extmarks = {}

-- Thought block tracking
local thought_blocks = {}
local thought_buffer = nil
local thought_start_line = nil

-- Code fence tracking
local code_blocks = {}
local code_buffer = nil
local code_start_line = nil
local code_lang = nil

-- History navigation state
local history_offset = 0
local history_temp_input = ""

-- Auto-scroll state
local last_manual_scroll_time = 0

-- Session duration update timer
local session_timer = nil

-- Bridge reference (set via set_bridge)
local bridge = nil

local config = {
    width = 80,
    position = "right",
    input_height = 3,
    title = " Banjo ",
}

function M.setup(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})

    -- Load history from disk
    local history = require("banjo.history")
    history.load()
end

function M.set_bridge(b)
    bridge = b
end

-- Output buffer

local function create_output_buffer()
    if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
        return output_buf
    end

    output_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = output_buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = output_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = output_buf })
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = output_buf })
    vim.api.nvim_set_option_value("modifiable", true, { buf = output_buf })
    vim.api.nvim_buf_set_name(output_buf, "Banjo")

    return output_buf
end

-- Input buffer

local function create_input_buffer()
    if input_buf and vim.api.nvim_buf_is_valid(input_buf) then
        return input_buf
    end

    input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = input_buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = input_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = input_buf })
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = input_buf })
    vim.api.nvim_buf_set_name(input_buf, "BanjoInput")

    -- Set initial prompt indicator
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

    return input_buf
end

local function setup_input_keymaps()
    if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then
        return
    end

    -- Enter to submit
    vim.keymap.set("i", "<CR>", function()
        M.submit_input()
    end, { buffer = input_buf, noremap = true })

    vim.keymap.set("n", "<CR>", function()
        M.submit_input()
    end, { buffer = input_buf, noremap = true })

    -- Shift-Enter for literal newline in insert mode
    vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = input_buf, noremap = true })

    -- Tab for command completion
    vim.keymap.set("i", "<Tab>", function()
        local text = M.get_input_text()
        if not vim.startswith(text, "/") then
            return "<Tab>"
        end

        local commands = require("banjo.commands")
        local parsed = commands.parse(text)

        if parsed and parsed.args == "" then
            -- Complete command name
            local prefix = parsed.cmd
            local all_cmds = commands.list_commands()
            local matches = {}

            for _, cmd in ipairs(all_cmds) do
                if vim.startswith(cmd, prefix) then
                    table.insert(matches, cmd)
                end
            end

            if #matches == 1 then
                -- Single match: complete it
                M.set_input_text("/" .. matches[1] .. " ")
            elseif #matches > 1 then
                -- Multiple matches: show them
                M.append_status("Available: " .. table.concat(matches, ", "))
            end
        end

        return ""
    end, { buffer = input_buf, noremap = true, expr = true })

    -- Ctrl-C to cancel
    vim.keymap.set({ "n", "i" }, "<C-c>", function()
        if bridge then
            bridge.cancel()
            M.append_status("Cancelled")
        end
    end, { buffer = input_buf, noremap = true })

    -- Escape to leave insert mode and focus output
    vim.keymap.set("i", "<Esc>", function()
        vim.cmd("stopinsert")
        if output_win and vim.api.nvim_win_is_valid(output_win) then
            vim.api.nvim_set_current_win(output_win)
        end
    end, { buffer = input_buf, noremap = true })

    -- Up/Down for history navigation
    vim.keymap.set({ "n", "i" }, "<Up>", function()
        local history = require("banjo.history")

        -- First Up press: save current input
        if history_offset == 0 then
            history_temp_input = M.get_input_text()
        end

        -- Navigate back in history
        if history_offset < history.size() then
            history_offset = history_offset + 1
            local entry = history.get(history_offset - 1)
            if entry then
                M.set_input_text(entry)
            end
        end
    end, { buffer = input_buf, noremap = true })

    vim.keymap.set({ "n", "i" }, "<Down>", function()
        local history = require("banjo.history")

        if history_offset == 0 then
            return
        end

        -- Navigate forward in history
        history_offset = history_offset - 1

        if history_offset == 0 then
            -- Restore temp input
            M.set_input_text(history_temp_input)
        else
            local entry = history.get(history_offset - 1)
            if entry then
                M.set_input_text(entry)
            end
        end
    end, { buffer = input_buf, noremap = true })
end

local function setup_output_keymaps()
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        return
    end

    -- Track manual scrolling
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = output_buf,
        callback = function()
            last_manual_scroll_time = vim.loop.now()
        end,
    })

    -- 'i' to focus input
    vim.keymap.set("n", "i", function()
        if input_win and vim.api.nvim_win_is_valid(input_win) then
            vim.api.nvim_set_current_win(input_win)
            vim.cmd("startinsert!")
        end
    end, { buffer = output_buf, noremap = true })

    -- 'q' to close panel
    vim.keymap.set("n", "q", function()
        M.close()
    end, { buffer = output_buf, noremap = true })

    -- 'z' to toggle fold at cursor
    vim.keymap.set("n", "z", "za", { buffer = output_buf, noremap = true })

    -- <CR> or gf to jump to file path under cursor
    local function jump_to_file()
        local cursor = vim.api.nvim_win_get_cursor(output_win)
        local line_num = cursor[1] - 1
        local col = cursor[2]

        local line_text = vim.api.nvim_buf_get_lines(output_buf, line_num, line_num + 1, false)[1]
        if not line_text then
            return
        end

        -- Pattern matches: path/to/file.ext:123
        local pattern = "([%w_/.%-]+%.[%w]+):(%d+)"
        local s, e, file_path, line_number = string.find(line_text, pattern)

        -- Find the match under cursor
        while s do
            if col >= s - 1 and col < e then
                -- Cursor is on this match
                vim.cmd(string.format("edit +%s %s", line_number, file_path))
                return
            end
            s, e, file_path, line_number = string.find(line_text, pattern, e + 1)
        end
    end

    vim.keymap.set("n", "<CR>", jump_to_file, { buffer = output_buf, noremap = true })
    vim.keymap.set("n", "gf", jump_to_file, { buffer = output_buf, noremap = true })
end

-- Window creation

local function create_panel()
    if output_win and vim.api.nvim_win_is_valid(output_win) then
        return
    end

    create_output_buffer()
    create_input_buffer()

    -- Create main split for the panel
    local cmd = config.position == "left" and "topleft" or "botright"
    vim.cmd(cmd .. " " .. config.width .. "vsplit")
    local panel_win = vim.api.nvim_get_current_win()

    -- Set output buffer in the main window
    vim.api.nvim_win_set_buf(panel_win, output_buf)
    output_win = panel_win

    -- Output window options
    vim.api.nvim_set_option_value("wrap", true, { win = output_win })
    vim.api.nvim_set_option_value("linebreak", true, { win = output_win })
    vim.api.nvim_set_option_value("number", false, { win = output_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = output_win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = output_win })
    vim.api.nvim_set_option_value("winfixwidth", true, { win = output_win })
    vim.api.nvim_set_option_value("cursorline", false, { win = output_win })

    -- Create horizontal split for input at bottom
    vim.cmd("belowright " .. config.input_height .. "split")
    input_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(input_win, input_buf)

    -- Input window options
    vim.api.nvim_set_option_value("wrap", true, { win = input_win })
    vim.api.nvim_set_option_value("linebreak", true, { win = input_win })
    vim.api.nvim_set_option_value("number", false, { win = input_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = input_win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = input_win })
    vim.api.nvim_set_option_value("winfixheight", true, { win = input_win })
    vim.api.nvim_set_option_value("winfixwidth", true, { win = input_win })

    -- Status line in output window
    vim.api.nvim_set_option_value("winbar", M._build_status(), { win = output_win })

    -- Setup keymaps
    setup_input_keymaps()
    setup_output_keymaps()

    -- Return focus to previous window
    vim.cmd("wincmd p")
    vim.cmd("wincmd p")
end

-- Public API

function M.open()
    create_panel()
end

function M.close()
    if input_win and vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_close(input_win, true)
        input_win = nil
    end

    if output_win and vim.api.nvim_win_is_valid(output_win) then
        vim.api.nvim_win_close(output_win, true)
        output_win = nil
    end
end

function M.toggle()
    if M.is_open() then
        M.close()
    else
        M.open()
    end
end

function M.is_open()
    return output_win ~= nil and vim.api.nvim_win_is_valid(output_win)
end

function M.focus_input()
    if input_win and vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_set_current_win(input_win)
        vim.cmd("startinsert!")
    end
end

function M.focus_output()
    if output_win and vim.api.nvim_win_is_valid(output_win) then
        vim.api.nvim_set_current_win(output_win)
    end
end

-- Input handling

function M.submit_input()
    if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    text = vim.trim(text)

    if text == "" then
        return
    end

    -- Add to history and reset navigation
    local history = require("banjo.history")
    history.add(text)
    history_offset = 0
    history_temp_input = ""

    -- Clear input
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })

    -- Check if it's a slash command
    local commands = require("banjo.commands")
    local parsed = commands.parse(text)

    if parsed then
        -- Try to dispatch locally
        local handled = commands.dispatch(parsed.cmd, parsed.args, {
            bridge = bridge,
            panel = M,
        })

        if handled then
            return
        end

        -- If not handled locally, forward to backend
        -- (backend commands like /help from Claude CLI)
    end

    -- Display user message in output
    M.append_user_message(text)

    -- Send to backend
    if bridge then
        bridge.send_prompt(text)
    else
        M.append_status("Not connected")
    end
end

function M.get_input_text()
    if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then
        return ""
    end
    local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
    return table.concat(lines, "\n")
end

function M.set_input_text(text)
    if not input_buf or not vim.api.nvim_buf_is_valid(input_buf) then
        return
    end
    local lines = vim.split(text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, lines)
end

-- Output handling

function M.clear()
    if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
        vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, {})
    end
    tool_extmarks = {}
end

function M.append_user_message(text)
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        create_output_buffer()
    end

    local lines = vim.split(text, "\n", { plain = true })
    local formatted = { "" }
    for _, line in ipairs(lines) do
        table.insert(formatted, line)
    end
    table.insert(formatted, "")

    local line_count = vim.api.nvim_buf_line_count(output_buf)
    local start_line = line_count
    vim.api.nvim_buf_set_lines(output_buf, line_count, line_count, false, formatted)

    -- Highlight user input with distinct color (String highlight)
    for i = start_line + 1, start_line + #lines do
        vim.api.nvim_buf_add_highlight(output_buf, ns_id, "String", i, 0, -1)
    end

    M._scroll_to_bottom()
end

function M.start_stream(engine)
    is_streaming = true
    current_engine = engine or "claude"

    create_output_buffer()
    create_panel()

    M._update_status()
    M._scroll_to_bottom()
end

function M.end_stream()
    is_streaming = false
    current_engine = nil

    if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
        local line_count = vim.api.nvim_buf_line_count(output_buf)
        vim.api.nvim_buf_set_lines(output_buf, line_count, line_count, false, { "" })
    end

    M._update_status()
end

function M.append(text, is_thought)
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        create_output_buffer()
    end

    if not text or text == "" then
        return
    end

    -- Accumulate text for thought block detection
    thought_buffer = (thought_buffer or "") .. text

    -- Check for <think> tag
    local think_start = thought_buffer:find("<think>")
    if think_start and not thought_start_line then
        local line_count = vim.api.nvim_buf_line_count(output_buf)
        thought_start_line = line_count - 1
        -- Reset buffer after detecting opening tag to prevent memory leak
        thought_buffer = ""
    end

    -- Check for </think> tag
    local think_end = thought_buffer:find("</think>")
    if think_end and thought_start_line then
        local line_count = vim.api.nvim_buf_line_count(output_buf)
        local end_line = line_count

        table.insert(thought_blocks, {
            start_line = thought_start_line,
            end_line = end_line,
        })

        -- Create fold for this thought block (collapsed by default)
        vim.api.nvim_buf_call(output_buf, function()
            -- Enable folding in buffer
            vim.opt_local.foldmethod = "manual"
            vim.opt_local.foldenable = true

            -- Create fold
            vim.cmd(string.format("%d,%dfold", thought_start_line + 1, end_line))

            -- Close the fold
            vim.cmd(string.format("%dfoldclose", thought_start_line + 1))
        end)

        thought_start_line = nil
        thought_buffer = nil
    end

    -- Accumulate text for code fence detection
    code_buffer = (code_buffer or "") .. text

    -- Check for opening fence: ```lang
    if not code_start_line then
        local fence_start, fence_end, lang = code_buffer:find("```([%w]*)")
        if fence_start then
            local line_count = vim.api.nvim_buf_line_count(output_buf)
            code_start_line = line_count - 1
            code_lang = lang ~= "" and lang or nil
            -- Reset buffer after detecting opening tag to prevent memory leak
            code_buffer = ""
        end
    else
        -- Check for closing fence: ```
        local fence_end = code_buffer:find("```", 4)
        if fence_end then
            local line_count = vim.api.nvim_buf_line_count(output_buf)
            local end_line = line_count

            table.insert(code_blocks, {
                start_line = code_start_line,
                end_line = end_line,
                lang = code_lang,
            })

            -- Apply syntax highlighting if language is specified
            if code_lang then
                M._highlight_code_block(code_start_line, end_line, code_lang)
            end

            code_start_line = nil
            code_lang = nil
            code_buffer = nil
        end
    end

    local lines = vim.split(text, "\n", { plain = true })
    local line_count = vim.api.nvim_buf_line_count(output_buf)
    local last_line = vim.api.nvim_buf_get_lines(output_buf, line_count - 1, line_count, false)[1] or ""

    -- Append first line to last line
    if #lines > 0 then
        vim.api.nvim_buf_set_lines(output_buf, line_count - 1, line_count, false, { last_line .. lines[1] })
    end

    -- Append remaining lines
    if #lines > 1 then
        vim.api.nvim_buf_set_lines(output_buf, line_count, line_count, false, vim.list_slice(lines, 2))
    end

    -- Highlight thoughts
    if is_thought then
        local start_line = line_count - 1
        local end_line = vim.api.nvim_buf_line_count(output_buf)
        for i = start_line, end_line - 1 do
            vim.api.nvim_buf_add_highlight(output_buf, ns_id, "Comment", i, 0, -1)
        end
    end

    -- Detect and mark markdown headers
    M._mark_markdown_headers(line_count - 1, vim.api.nvim_buf_line_count(output_buf))

    -- Detect and mark inline formatting
    M._mark_inline_formatting(line_count - 1, vim.api.nvim_buf_line_count(output_buf))

    -- Detect and render lists
    M._mark_lists(line_count - 1, vim.api.nvim_buf_line_count(output_buf))

    -- Detect and mark file paths
    M._mark_file_paths(line_count - 1, vim.api.nvim_buf_line_count(output_buf))

    -- Defer scroll to avoid excessive updates during fast streaming
    if not pending_scroll then
        pending_scroll = true
        vim.schedule(function()
            pending_scroll = false
            M._scroll_to_bottom()
        end)
    end
end

function M.append_status(msg)
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        return
    end

    local line = string.format("*%s*", msg)
    local line_count = vim.api.nvim_buf_line_count(output_buf)
    vim.api.nvim_buf_set_lines(output_buf, line_count, line_count, false, { "", line })

    -- Highlight as comment
    vim.api.nvim_buf_add_highlight(output_buf, ns_id, "Comment", line_count + 1, 0, -1)

    M._scroll_to_bottom()
end

-- Tool display

function M.show_tool_call(name, label)
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        return
    end

    local display_label = label
    if #display_label > 50 then
        display_label = display_label:sub(1, 47) .. "..."
    end

    local line = string.format("  %s **%s** `%s`", "⏳", name, display_label)
    local line_count = vim.api.nvim_buf_line_count(output_buf)
    vim.api.nvim_buf_set_lines(output_buf, line_count, line_count, false, { line })

    -- Store extmark for later update
    local mark_id = vim.api.nvim_buf_set_extmark(output_buf, ns_tools, line_count, 0, {})
    tool_extmarks[name .. "_" .. label] = { mark_id = mark_id, line = line_count }

    M._scroll_to_bottom()
end

function M.show_tool_result(id, status)
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        return
    end

    local icon = "✓"
    if status == "failed" then
        icon = "✗"
    elseif status == "running" then
        icon = "▶"
    elseif status == "pending" then
        icon = "⏳"
    end

    -- Try to find and update existing tool line by exact ID match
    -- The id parameter is the full composite key: "name_label"
    local info = tool_extmarks[id]
    if info then
        local mark = vim.api.nvim_buf_get_extmark_by_id(output_buf, ns_tools, info.mark_id, {})
        if mark and #mark > 0 then
            local line_num = mark[1]
            local current_line = vim.api.nvim_buf_get_lines(output_buf, line_num, line_num + 1, false)[1] or ""
            -- Replace icon
            local new_line = current_line:gsub("^%s*[⏳▶✓✗]", "  " .. icon)
            vim.api.nvim_buf_set_lines(output_buf, line_num, line_num + 1, false, { new_line })
            return
        end
    end

    -- Fallback: append new line
    local line = string.format("  [%s] %s", icon, id or "")
    local line_count = vim.api.nvim_buf_line_count(output_buf)
    vim.api.nvim_buf_set_lines(output_buf, line_count, line_count, false, { line })

    M._scroll_to_bottom()
end

-- Status line

function M._build_status()
    local parts = {}

    -- Connection status
    local connected = bridge and bridge.is_running and bridge.is_running()
    if connected then
        table.insert(parts, "%#DiagnosticOk#●%*")
    else
        local state = bridge and bridge.get_state and bridge.get_state() or {}
        if state.reconnect_attempt and state.reconnect_attempt > 0 then
            table.insert(parts, string.format("%%#DiagnosticWarn#○(%d)%%*", state.reconnect_attempt))
        else
            table.insert(parts, "%#DiagnosticError#○%*")
        end
    end

    -- Get state from bridge
    local state = bridge and bridge.get_state and bridge.get_state() or {}

    -- Engine
    local engine = state.engine or current_engine
    if engine then
        local engine_name = engine:sub(1, 1):upper() .. engine:sub(2):lower()
        table.insert(parts, string.format("[%s]", engine_name))
    end

    -- Model
    if state.model then
        table.insert(parts, state.model)
    end

    -- Mode (only show if not default)
    if state.mode and state.mode ~= "Default" then
        table.insert(parts, string.format("(%s)", state.mode))
    end

    -- Streaming indicator
    if is_streaming then
        table.insert(parts, "%#DiagnosticInfo#...%*")
    end

    -- Session duration
    if state.session_active and state.session_start_time then
        local elapsed_ms = vim.loop.now() - state.session_start_time
        local elapsed_sec = math.floor(elapsed_ms / 1000)
        local mins = math.floor(elapsed_sec / 60)
        local secs = elapsed_sec % 60
        table.insert(parts, string.format("[%dm %02ds]", mins, secs))
    end

    table.insert(parts, "%=")

    -- Help hint
    table.insert(parts, "%#Comment#Ctrl-C:cancel q:close%*")

    return table.concat(parts, " ")
end

function M._update_status()
    if output_win and vim.api.nvim_win_is_valid(output_win) then
        vim.api.nvim_set_option_value("winbar", M._build_status(), { win = output_win })
    end
end

function M._start_session_timer()
    if session_timer then
        return
    end

    session_timer = vim.loop.new_timer()
    if session_timer then
        session_timer:start(1000, 1000, vim.schedule_wrap(function()
            M._update_status()
        end))
    end
end

function M._stop_session_timer()
    if session_timer then
        session_timer:stop()
        session_timer:close()
        session_timer = nil
    end
end

function M._mark_markdown_headers(start_line, end_line)
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        return
    end

    -- Pattern matches: ## Header or # Header
    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(output_buf, line_num, line_num + 1, false)[1]
        if line_text and vim.startswith(vim.trim(line_text), "#") then
            -- Apply bold highlight
            vim.api.nvim_buf_add_highlight(output_buf, ns_id, "Bold", line_num, 0, -1)
        end
    end
end

function M._mark_inline_formatting(start_line, end_line)
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        return
    end

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(output_buf, line_num, line_num + 1, false)[1]
        if not line_text then
            goto continue
        end

        -- **bold**
        local col = 1
        while true do
            local s, e = string.find(line_text, "%*%*([^*]+)%*%*", col)
            if not s then break end
            vim.api.nvim_buf_set_extmark(output_buf, ns_id, line_num, s - 1, {
                end_col = e,
                hl_group = "Bold",
            })
            col = e + 1
        end

        -- *italic*
        col = 1
        while true do
            local s, e = string.find(line_text, "%*([^*]+)%*", col)
            if not s then break end
            -- Skip if it's part of **bold**
            if col > 1 and line_text:sub(s - 1, s - 1) == "*" then
                col = e + 1
                goto skip_italic
            end
            if e < #line_text and line_text:sub(e + 1, e + 1) == "*" then
                col = e + 1
                goto skip_italic
            end
            vim.api.nvim_buf_set_extmark(output_buf, ns_id, line_num, s - 1, {
                end_col = e,
                hl_group = "Italic",
            })
            ::skip_italic::
            col = e + 1
        end

        -- `inline code`
        col = 1
        while true do
            local s, e = string.find(line_text, "`([^`]+)`", col)
            if not s then break end
            vim.api.nvim_buf_set_extmark(output_buf, ns_id, line_num, s - 1, {
                end_col = e,
                hl_group = "Special",
            })
            col = e + 1
        end

        ::continue::
    end
end

function M._mark_lists(start_line, end_line)
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        return
    end

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(output_buf, line_num, line_num + 1, false)[1]
        if not line_text then
            goto continue
        end

        local trimmed = vim.trim(line_text)

        -- Unordered list: - item or * item
        local unordered_start = trimmed:match("^([%-*])%s+")
        if unordered_start then
            local indent = line_text:match("^(%s*)") or ""
            local bullet = "•"
            local new_line = indent .. bullet .. trimmed:sub(#unordered_start + 1)
            vim.api.nvim_buf_set_lines(output_buf, line_num, line_num + 1, false, { new_line })
            goto continue
        end

        -- Ordered list: 1. item or 2. item
        local number = trimmed:match("^(%d+)%.%s+")
        if number then
            -- Keep numbered lists as-is for now
            goto continue
        end

        ::continue::
    end
end

function M._mark_file_paths(start_line, end_line)
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        return
    end

    -- Pattern matches: path/to/file.ext:123 or file.ext:123
    local pattern = "([%w_/.%-]+%.[%w]+):(%d+)"

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(output_buf, line_num, line_num + 1, false)[1]
        if line_text then
            local col = 1
            while true do
                local s, e, file_path, line_number = string.find(line_text, pattern, col)
                if not s then
                    break
                end

                -- Create extmark with virtual text for underline effect
                vim.api.nvim_buf_set_extmark(output_buf, ns_links, line_num, s - 1, {
                    end_col = e,
                    hl_group = "Underlined",
                })

                col = e + 1
            end
        end
    end
end

function M._highlight_code_block(start_line, end_line, lang)
    if not output_buf or not vim.api.nvim_buf_is_valid(output_buf) then
        return
    end

    -- Map common language aliases
    local lang_map = {
        js = "javascript",
        ts = "typescript",
        py = "python",
        rb = "ruby",
        sh = "bash",
        md = "markdown",
    }
    local filetype = lang_map[lang] or lang

    -- Use treesitter for syntax highlighting
    local ok, ts_highlight = pcall(require, "vim.treesitter.highlighter")
    if not ok then
        return
    end

    -- Apply Comment highlight to code block as fallback
    for i = start_line, end_line - 1 do
        vim.api.nvim_buf_add_highlight(output_buf, ns_id, "Special", i, 0, -1)
    end
end

function M._scroll_to_bottom()
    if not output_win or not vim.api.nvim_win_is_valid(output_win) then
        return
    end

    -- Only auto-scroll if user hasn't manually scrolled in last 2 seconds
    local now = vim.loop.now()
    local time_since_scroll = now - last_manual_scroll_time

    if time_since_scroll < 2000 then
        -- User recently scrolled, preserve position
        return
    end

    -- Auto-scroll to bottom
    local line_count = vim.api.nvim_buf_line_count(output_buf)
    vim.api.nvim_win_set_cursor(output_win, { line_count, 0 })
end

-- Accessors for testing

function M.get_output_buf()
    return output_buf
end

function M.get_input_buf()
    return input_buf
end

function M.get_output_win()
    return output_win
end

function M.get_input_win()
    return input_win
end

return M
