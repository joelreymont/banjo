-- Banjo panel: Chat UI with output section and input field
local M = {}

-- Buffer and window state
local output_buf = nil
local input_buf = nil
local output_win = nil
local input_win = nil
local ns_id = vim.api.nvim_create_namespace("banjo")
local ns_tools = vim.api.nvim_create_namespace("banjo_tools")

-- Streaming state
local is_streaming = false
local current_engine = nil

-- Tool tracking for in-place updates
local tool_extmarks = {}

-- History navigation state
local history_offset = 0
local history_temp_input = ""

-- Auto-scroll state
local last_manual_scroll_time = 0

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

    M._scroll_to_bottom()
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

    -- Try to find and update existing tool line
    for key, info in pairs(tool_extmarks) do
        if key:find(id, 1, true) then
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
        table.insert(parts, "%#DiagnosticError#○%*")
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
