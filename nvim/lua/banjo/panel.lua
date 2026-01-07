-- Banjo panel: Chat UI with output section and input field
local M = {}

-- Global namespaces (process-wide identifiers)
local ns_id = vim.api.nvim_create_namespace("banjo")
local ns_tools = vim.api.nvim_create_namespace("banjo_tools")
local ns_links = vim.api.nvim_create_namespace("banjo_links")

-- Global config
local config = {
    width = 50,
    position = "right",
    input_height = 3,
    title = " Banjo ",
}

-- Per-tab state storage (indexed by tabpage handle)
local states = {}

-- Per-tab state accessor
local function get_state()
    local tabid = vim.api.nvim_get_current_tabpage()
    if not states[tabid] then
        states[tabid] = {
            output_buf = nil,
            input_buf = nil,
            output_win = nil,
            input_win = nil,
            last_width = nil,
            is_streaming = false,
            current_engine = nil,
            pending_scroll = false,
            tool_extmarks = {},
            thought_blocks = {},
            thought_buffer = nil,
            thought_start_line = nil,
            code_blocks = {},
            code_buffer = nil,
            code_start_line = nil,
            code_lang = nil,
            history_offset = 0,
            history_temp_input = "",
            last_manual_scroll_time = 0,
            session_timer = nil,
            bridge = nil,
        }
    end
    return states[tabid]
end

function M.setup(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})

    -- Load history from disk
    local history = require("banjo.history")
    history.load()
end

function M.set_bridge(b)
    local state = get_state()
    state.bridge = b
end

-- Output buffer

local function create_output_buffer()
    local state = get_state()
    if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
        return state.output_buf
    end

    state.output_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.output_buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = state.output_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = state.output_buf })
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = state.output_buf })
    vim.api.nvim_set_option_value("modifiable", true, { buf = state.output_buf })

    -- Disable completions for output buffer (prevent blink.cmp and other plugins)
    vim.api.nvim_set_option_value("omnifunc", "", { buf = state.output_buf })
    vim.api.nvim_set_option_value("completefunc", "", { buf = state.output_buf })
    vim.b[state.output_buf].cmp_enabled = false
    vim.b[state.output_buf].blink_cmp_enabled = false

    -- Use per-tab buffer name to support multiple tabs
    local tabid = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_buf_set_name(state.output_buf, string.format("Banjo-%d", tabid))

    return state.output_buf
end

-- Input buffer

local function create_input_buffer()
    local state = get_state()
    if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
        return state.input_buf
    end

    state.input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.input_buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = state.input_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = state.input_buf })
    vim.api.nvim_set_option_value("filetype", "banjo_input", { buf = state.input_buf })

    -- Use per-tab buffer name to support multiple tabs
    local tabid = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_buf_set_name(state.input_buf, string.format("BanjoInput-%d", tabid))

    -- Set initial prompt indicator
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })

    -- Disable nvim's built-in completion sources
    vim.api.nvim_set_option_value("omnifunc", "", { buf = state.input_buf })
    vim.api.nvim_set_option_value("completefunc", "", { buf = state.input_buf })

    return state.input_buf
end

-- Command argument options with descriptions
local command_args = {
    mode = {
        { word = "default", info = "Ask for permission on each action" },
        { word = "accept_edits", info = "Auto-accept file edits" },
        { word = "auto_approve", info = "No confirmations needed" },
        { word = "plan_only", info = "Suggest without executing" },
    },
    model = {
        { word = "opus", info = "Most capable, best for complex tasks" },
        { word = "sonnet", info = "Balanced speed and capability" },
        { word = "haiku", info = "Fastest, good for simple tasks" },
    },
    agent = {
        { word = "claude", info = "Claude Code (Anthropic)" },
        { word = "codex", info = "Codex (OpenAI)" },
    },
}

-- Slash command completion function
local function banjo_complete(findstart, base)
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col(".") - 1

    if findstart == 1 then
        -- Check if we're completing an argument (after command + space)
        local cmd_match = line:match("^/(%w+)%s+")
        if cmd_match and command_args[cmd_match] then
            -- Find start of argument
            local space_pos = line:find("%s+[^%s]*$")
            if space_pos then
                return space_pos  -- 0-indexed position after last space
            end
        end

        -- Find the start of the slash command
        local start = col
        while start > 0 and line:sub(start, start) ~= "/" do
            start = start - 1
        end
        if start > 0 and line:sub(start, start) == "/" then
            return start - 1  -- 0-indexed
        end
        return -3  -- Cancel completion
    else
        -- Safety check for base
        base = base or ""

        -- Check if completing command arguments
        local cmd_match = line:match("^/(%w+)%s+")
        if cmd_match and command_args[cmd_match] then
            local matches = {}
            local args = command_args[cmd_match]

            for _, arg in ipairs(args) do
                if base == "" or vim.startswith(arg.word, base) then
                    table.insert(matches, {
                        word = arg.word,
                        menu = arg.info,
                    })
                end
            end
            return matches
        end

        -- Return command matches
        local commands = require("banjo.commands")
        local all_cmds = commands.list_commands()
        local matches = {}

        -- base includes the "/" prefix, remove it for matching
        local prefix = ""
        if #base > 0 and base:sub(1, 1) == "/" then
            prefix = base:sub(2)
        end

        for _, cmd in ipairs(all_cmds) do
            if prefix == "" or vim.startswith(cmd, prefix) then
                table.insert(matches, {
                    word = "/" .. cmd,
                    menu = "[Banjo]",
                })
            end
        end

        return matches
    end
end

-- Register the completion function globally so it can be called by completefunc
_G.banjo_complete = banjo_complete

-- Set input buffer keymaps (called on buffer creation and BufEnter to ensure precedence)
local function set_input_keymaps(buf, state)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    -- Enter to submit
    vim.keymap.set("i", "<CR>", function()
        M.submit_input()
    end, { buffer = buf, noremap = true })

    vim.keymap.set("n", "<CR>", function()
        M.submit_input()
    end, { buffer = buf, noremap = true })

    -- Shift-Enter for literal newline in insert mode
    vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = buf, noremap = true })

    -- Slash triggers completion menu for commands
    vim.keymap.set("i", "/", function()
        -- Insert the slash first
        vim.api.nvim_put({ "/" }, "c", false, true)
        -- Set our completion function and trigger completion
        vim.api.nvim_set_option_value("completefunc", "v:lua.banjo_complete", { buf = buf })
        -- Trigger completion after a small delay to let the "/" be inserted
        vim.schedule(function()
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true), "n", false)
        end)
    end, { buffer = buf, noremap = true })

    -- Space triggers argument completion for commands that have arguments
    vim.keymap.set("i", "<Space>", function()
        local line = vim.api.nvim_get_current_line()
        -- Check if line is a command that accepts arguments (no space yet)
        local cmd = line:match("^/(%w+)$")
        if cmd and command_args[cmd] then
            -- Insert space and trigger completion
            vim.api.nvim_put({ " " }, "c", false, true)
            vim.api.nvim_set_option_value("completefunc", "v:lua.banjo_complete", { buf = buf })
            vim.schedule(function()
                vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true), "n", false)
            end)
        else
            -- Normal space
            vim.api.nvim_put({ " " }, "c", false, true)
        end
    end, { buffer = buf, noremap = true })

    -- Tab navigates completion menu or triggers completion
    vim.keymap.set("i", "<Tab>", function()
        if vim.fn.pumvisible() == 1 then
            -- Completion menu is visible: select next item
            return vim.api.nvim_replace_termcodes("<C-n>", true, false, true)
        end

        local line = vim.api.nvim_get_current_line()
        if vim.startswith(line, "/") then
            -- On a slash command: trigger completion
            vim.api.nvim_set_option_value("completefunc", "v:lua.banjo_complete", { buf = buf })
            return vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true)
        end

        -- Default: insert tab
        return vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
    end, { buffer = buf, expr = true })

    -- Shift-Tab navigates completion menu backwards
    vim.keymap.set("i", "<S-Tab>", function()
        if vim.fn.pumvisible() == 1 then
            return vim.api.nvim_replace_termcodes("<C-p>", true, false, true)
        end
        return vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true)
    end, { buffer = buf, expr = true })

    -- Ctrl-C to cancel
    vim.keymap.set({ "n", "i" }, "<C-c>", function()
        if state.bridge then
            state.bridge.cancel()
            M.append_status("Cancelled")
        end
    end, { buffer = buf, noremap = true })

    -- Escape to leave insert mode (standard vim behavior)
    vim.keymap.set("i", "<Esc>", "<Esc>", { buffer = buf, noremap = true })

    -- 'o' to focus output (mirrors 'i' in output to focus input)
    vim.keymap.set("n", "o", function()
        if state.output_win and vim.api.nvim_win_is_valid(state.output_win) then
            vim.api.nvim_set_current_win(state.output_win)
        end
    end, { buffer = buf, noremap = true })

    -- Up/Down for history navigation
    vim.keymap.set({ "n", "i" }, "<Up>", function()
        local history = require("banjo.history")

        -- First Up press: save current input
        if state.history_offset == 0 then
            state.history_temp_input = M.get_input_text()
        end

        -- Navigate back in history
        if state.history_offset < history.size() then
            state.history_offset = state.history_offset + 1
            local entry = history.get(state.history_offset - 1)
            if entry then
                M.set_input_text(entry)
            end
        end
    end, { buffer = buf, noremap = true })

    vim.keymap.set({ "n", "i" }, "<Down>", function()
        local history = require("banjo.history")

        if state.history_offset == 0 then
            return
        end

        -- Navigate forward in history
        state.history_offset = state.history_offset - 1

        if state.history_offset == 0 then
            -- Restore temp input
            M.set_input_text(state.history_temp_input)
        else
            local entry = history.get(state.history_offset - 1)
            if entry then
                M.set_input_text(entry)
            end
        end
    end, { buffer = buf, noremap = true })
end

local function setup_input_keymaps()
    local state = get_state()
    if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
        return
    end

    local my_tabid = vim.api.nvim_get_current_tabpage()
    local group_name = string.format("BanjoInput_%d_%d", my_tabid, state.input_buf)
    local augroup = vim.api.nvim_create_augroup(group_name, { clear = true })

    -- Re-establish keymaps on BufEnter to ensure they override any plugin keymaps
    vim.api.nvim_create_autocmd("BufEnter", {
        group = augroup,
        buffer = state.input_buf,
        callback = function()
            vim.schedule(function()
                set_input_keymaps(state.input_buf, state)
            end)
        end,
    })

    -- Set keymaps now (deferred to run after any other setup)
    vim.schedule(function()
        set_input_keymaps(state.input_buf, state)
    end)
end

-- Set output buffer keymaps (called on buffer creation and BufEnter to ensure precedence)
local function set_output_keymaps(buf, state)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    -- 'i' to focus input
    vim.keymap.set("n", "i", function()
        if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
            vim.api.nvim_set_current_win(state.input_win)
            vim.cmd("startinsert!")
        end
    end, { buffer = buf, noremap = true })

    -- 'q' to close panel
    vim.keymap.set("n", "q", function()
        M.close()
    end, { buffer = buf, noremap = true })

    -- <CR> or gf to jump to file path under cursor
    local function jump_to_file()
        if not state.output_win or not vim.api.nvim_win_is_valid(state.output_win) then
            return
        end
        local cursor = vim.api.nvim_win_get_cursor(state.output_win)
        local line_num = cursor[1] - 1
        local col = cursor[2]

        local lines = vim.api.nvim_buf_get_lines(buf, line_num, line_num + 1, false)
        local line_text = lines[1]
        if not line_text then
            return
        end

        -- Pattern matches: path/to/file:123
        local pattern = "([%w_/.%-]+):(%d+)"
        local s, e, file_path, line_number = string.find(line_text, pattern)

        while s do
            if col >= s - 1 and col < e then
                local stat = vim.loop.fs_stat(file_path)
                if stat and stat.type == "file" then
                    vim.cmd(string.format("edit +%s %s", line_number, file_path))
                else
                    vim.notify("Banjo: File not found: " .. file_path, vim.log.levels.WARN)
                end
                return
            end
            s, e, file_path, line_number = string.find(line_text, pattern, e + 1)
        end
    end

    vim.keymap.set("n", "<CR>", jump_to_file, { buffer = buf, noremap = true })
    vim.keymap.set("n", "gf", jump_to_file, { buffer = buf, noremap = true })
end

local function setup_output_keymaps()
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    local my_tabid = vim.api.nvim_get_current_tabpage()
    local group_name = string.format("BanjoOutput_%d_%d", my_tabid, state.output_buf)
    local augroup = vim.api.nvim_create_augroup(group_name, { clear = true })

    -- Track manual scrolling
    vim.api.nvim_create_autocmd("CursorMoved", {
        group = augroup,
        buffer = state.output_buf,
        callback = function()
            if vim.api.nvim_get_current_tabpage() ~= my_tabid then
                return
            end
            local my_state = states[my_tabid]
            if my_state then
                my_state.last_manual_scroll_time = vim.loop.now()
            end
        end,
    })

    -- Re-establish keymaps on BufEnter to ensure they override any ftplugin keymaps
    vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
        group = augroup,
        buffer = state.output_buf,
        callback = function()
            vim.schedule(function()
                set_output_keymaps(state.output_buf, state)
            end)
        end,
    })

    -- Set keymaps now (deferred to run after ftplugin)
    vim.schedule(function()
        set_output_keymaps(state.output_buf, state)
    end)
end

-- Window creation

local function create_panel()
    local state = get_state()
    if state.output_win and vim.api.nvim_win_is_valid(state.output_win) then
        return
    end

    create_output_buffer()
    create_input_buffer()

    -- Validate buffers were created
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        vim.notify("Banjo: Failed to create output buffer", vim.log.levels.ERROR)
        return
    end
    if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
        vim.notify("Banjo: Failed to create input buffer", vim.log.levels.ERROR)
        return
    end

    -- Create main split for the panel (use saved width if available)
    local width = state.last_width or config.width
    local cmd = config.position == "left" and "topleft" or "botright"
    local ok, err = pcall(vim.cmd, cmd .. " " .. width .. "vsplit")
    if not ok then
        vim.notify("Banjo: Failed to create panel: " .. tostring(err), vim.log.levels.ERROR)
        return
    end
    local panel_win = vim.api.nvim_get_current_win()

    -- Set output buffer in the main window
    vim.api.nvim_win_set_buf(panel_win, state.output_buf)
    state.output_win = panel_win

    -- Output window options
    vim.api.nvim_set_option_value("wrap", true, { win = state.output_win })
    vim.api.nvim_set_option_value("linebreak", true, { win = state.output_win })
    vim.api.nvim_set_option_value("number", false, { win = state.output_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = state.output_win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = state.output_win })
    vim.api.nvim_set_option_value("winfixwidth", true, { win = state.output_win })
    vim.api.nvim_set_option_value("cursorline", false, { win = state.output_win })

    -- Create horizontal split for input at bottom
    ok, err = pcall(vim.cmd, "belowright " .. config.input_height .. "split")
    if not ok then
        vim.notify("Banjo: Failed to create input split: " .. tostring(err), vim.log.levels.ERROR)
        return
    end
    state.input_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.input_win, state.input_buf)

    -- Input window options
    vim.api.nvim_set_option_value("wrap", true, { win = state.input_win })
    vim.api.nvim_set_option_value("linebreak", true, { win = state.input_win })
    vim.api.nvim_set_option_value("number", false, { win = state.input_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = state.input_win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = state.input_win })
    vim.api.nvim_set_option_value("winfixheight", true, { win = state.input_win })
    vim.api.nvim_set_option_value("winfixwidth", true, { win = state.input_win })

    -- Status line in output window
    vim.api.nvim_set_option_value("winbar", M._build_status(), { win = state.output_win })

    -- Setup keymaps
    setup_input_keymaps()
    setup_output_keymaps()

    -- Return focus to previous window
    vim.cmd("wincmd p")
    vim.cmd("wincmd p")
end

-- Public API

function M.open()
    local state = get_state()
    create_panel()
end

function M.close()
    local state = get_state()

    -- Save panel width before closing
    if state.output_win and vim.api.nvim_win_is_valid(state.output_win) then
        state.last_width = vim.api.nvim_win_get_width(state.output_win)
    end

    if state.input_win then
        if vim.api.nvim_win_is_valid(state.input_win) then
            vim.api.nvim_win_close(state.input_win, true)
        end
        state.input_win = nil
    end

    if state.output_win then
        if vim.api.nvim_win_is_valid(state.output_win) then
            vim.api.nvim_win_close(state.output_win, true)
        end
        state.output_win = nil
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
    local state = get_state()
    return state.output_win ~= nil and vim.api.nvim_win_is_valid(state.output_win)
end

function M.focus_input()
    local state = get_state()
    if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
        vim.api.nvim_set_current_win(state.input_win)
        vim.cmd("startinsert!")
    end
end

function M.focus_output()
    local state = get_state()
    if state.output_win and vim.api.nvim_win_is_valid(state.output_win) then
        vim.api.nvim_set_current_win(state.output_win)
    end
end

-- Input handling

function M.submit_input()
    local state = get_state()
    if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    text = vim.trim(text)

    -- Validate input
    if text == "" then
        return
    end

    -- Enforce reasonable length limit (1MB = 1048576 bytes)
    if #text > 1048576 then
        M.append_status("Error: Input too long (max 1MB)")
        return
    end

    -- Add to history and reset navigation
    local history = require("banjo.history")
    history.add(text)
    state.history_offset = 0
    state.history_temp_input = ""

    -- Clear input
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })

    -- Check if it's a slash command
    local commands = require("banjo.commands")
    local parsed = commands.parse(text)

    if parsed then
        -- Try to dispatch locally
        local handled = commands.dispatch(parsed.cmd, parsed.args, {
            bridge = state.bridge,
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
    if state.bridge then
        state.bridge.send_prompt(text)
    else
        M.append_status("Not connected")
    end
end

function M.get_input_text()
    local state = get_state()
    if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
        return ""
    end
    local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    return table.concat(lines, "\n")
end

function M.set_input_text(text)
    local state = get_state()
    if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
        return
    end
    local lines = vim.split(text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, lines)
end

-- Output handling

function M.clear()
    local state = get_state()
    if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
        vim.api.nvim_buf_set_lines(state.output_buf, 0, -1, false, {})

        -- Clear all extmark namespaces to prevent memory leak
        vim.api.nvim_buf_clear_namespace(state.output_buf, ns_id, 0, -1)
        vim.api.nvim_buf_clear_namespace(state.output_buf, ns_tools, 0, -1)
        vim.api.nvim_buf_clear_namespace(state.output_buf, ns_links, 0, -1)
    end

    -- Reset tool tracking
    state.tool_extmarks = {}

    -- Reset thought/code tracking state to prevent memory leak and incorrect behavior
    state.thought_blocks = {}
    state.thought_buffer = nil
    state.thought_start_line = nil
    state.code_blocks = {}
    state.code_buffer = nil
    state.code_start_line = nil
    state.code_lang = nil
end

function M.append_user_message(text)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        create_output_buffer()
    end

    local lines = vim.split(text, "\n", { plain = true })
    local formatted = { "" }
    for _, line in ipairs(lines) do
        table.insert(formatted, line)
    end
    table.insert(formatted, "")

    local line_count = vim.api.nvim_buf_line_count(state.output_buf)
    local start_line = line_count
    vim.api.nvim_buf_set_lines(state.output_buf, line_count, line_count, false, formatted)

    -- Highlight user input with distinct color (String highlight)
    for i = start_line + 1, start_line + #lines do
        vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "String", i, 0, -1)
    end

    M._scroll_to_bottom()
end

function M.start_stream(engine)
    local state = get_state()
    state.is_streaming = true
    state.current_engine = engine or "claude"

    -- Reset streaming state to ensure clean slate (prevents state leakage from cancelled streams)
    state.thought_buffer = nil
    state.thought_start_line = nil
    state.code_buffer = nil
    state.code_start_line = nil
    state.code_lang = nil

    create_output_buffer()
    create_panel()

    M._update_status()
    M._scroll_to_bottom()
end

function M.end_stream()
    local state = get_state()
    state.is_streaming = false
    state.current_engine = nil

    if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
        local line_count = vim.api.nvim_buf_line_count(state.output_buf)
        vim.api.nvim_buf_set_lines(state.output_buf, line_count, line_count, false, { "" })
    end

    -- Reset streaming state in case of unclosed tags
    state.thought_buffer = nil
    state.thought_start_line = nil
    state.code_buffer = nil
    state.code_start_line = nil
    state.code_lang = nil

    M._update_status()
end

function M.append(text, is_thought)
    local state = get_state()
    local my_tabid = vim.api.nvim_get_current_tabpage()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        create_output_buffer()
    end

    if not text or text == "" then
        return
    end

    -- Accumulate text for thought block detection
    state.thought_buffer = (state.thought_buffer or "") .. text

    -- Check for <think> tag
    local think_start = state.thought_buffer:find("<think>")
    if think_start and not state.thought_start_line then
        local line_count = vim.api.nvim_buf_line_count(state.output_buf)
        state.thought_start_line = line_count - 1
        -- Reset buffer after detecting opening tag to prevent memory leak
        state.thought_buffer = ""
    end

    -- Check for </think> tag
    local think_end = state.thought_buffer:find("</think>")
    if think_end and state.thought_start_line then
        local line_count = vim.api.nvim_buf_line_count(state.output_buf)
        local end_line = line_count

        table.insert(state.thought_blocks, {
            start_line = state.thought_start_line,
            end_line = end_line,
        })

        -- Create fold for this thought block (collapsed by default)
        vim.api.nvim_buf_call(state.output_buf, function()
            -- Enable folding in buffer
            vim.opt_local.foldmethod = "manual"
            vim.opt_local.foldenable = true

            -- Create fold
            vim.cmd(string.format("%d,%dfold", state.thought_start_line + 1, end_line))

            -- Close the fold
            vim.cmd(string.format("%dfoldclose", state.thought_start_line + 1))
        end)

        state.thought_start_line = nil
        state.thought_buffer = nil
    end

    -- Accumulate text for code fence detection
    state.code_buffer = (state.code_buffer or "") .. text

    -- Check for opening fence: ```lang
    if not state.code_start_line then
        local fence_start, fence_end, lang = state.code_buffer:find("```([%w]*)")
        if fence_start then
            local line_count = vim.api.nvim_buf_line_count(state.output_buf)
            state.code_start_line = line_count - 1
            state.code_lang = lang ~= "" and lang or nil
            -- Reset buffer after detecting opening tag to prevent memory leak
            state.code_buffer = ""
        end
    else
        -- Check for closing fence: ```
        local fence_end = state.code_buffer:find("```", 4)
        if fence_end then
            local line_count = vim.api.nvim_buf_line_count(state.output_buf)
            local end_line = line_count

            table.insert(state.code_blocks, {
                start_line = state.code_start_line,
                end_line = end_line,
                lang = state.code_lang,
            })

            -- Apply syntax highlighting if language is specified
            if state.code_lang then
                M._highlight_code_block(state.code_start_line, end_line, state.code_lang)
            end

            state.code_start_line = nil
            state.code_lang = nil
            state.code_buffer = nil
        end
    end

    local lines = vim.split(text, "\n", { plain = true })
    local line_count = vim.api.nvim_buf_line_count(state.output_buf)
    local last_line = vim.api.nvim_buf_get_lines(state.output_buf, line_count - 1, line_count, false)[1] or ""

    -- Append first line to last line
    if #lines > 0 then
        vim.api.nvim_buf_set_lines(state.output_buf, line_count - 1, line_count, false, { last_line .. lines[1] })
    end

    -- Append remaining lines
    if #lines > 1 then
        vim.api.nvim_buf_set_lines(state.output_buf, line_count, line_count, false, vim.list_slice(lines, 2))
    end

    -- Highlight thoughts
    if is_thought then
        local start_line = line_count - 1
        local end_line = vim.api.nvim_buf_line_count(state.output_buf)
        for i = start_line, end_line - 1 do
            vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "Comment", i, 0, -1)
        end
    end

    -- Detect and mark markdown headers
    M._mark_markdown_headers(line_count - 1, vim.api.nvim_buf_line_count(state.output_buf))

    -- Detect and mark inline formatting
    M._mark_inline_formatting(line_count - 1, vim.api.nvim_buf_line_count(state.output_buf))

    -- Detect and render lists
    M._mark_lists(line_count - 1, vim.api.nvim_buf_line_count(state.output_buf))

    -- Detect and mark file paths
    M._mark_file_paths(line_count - 1, vim.api.nvim_buf_line_count(state.output_buf))

    -- Defer scroll to avoid excessive updates during fast streaming
    if not state.pending_scroll then
        state.pending_scroll = true
        vim.schedule(function()
            local my_state = states[my_tabid]
            if not my_state then return end
            if not my_state.output_win or not vim.api.nvim_win_is_valid(my_state.output_win) then
                my_state.pending_scroll = false
                return
            end
            my_state.pending_scroll = false
            M._scroll_to_bottom(my_state)
        end)
    end
end

function M.append_status(msg)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    local line = string.format("*%s*", msg)
    local line_count = vim.api.nvim_buf_line_count(state.output_buf)
    vim.api.nvim_buf_set_lines(state.output_buf, line_count, line_count, false, { "", line })

    -- Highlight as comment
    vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "Comment", line_count + 1, 0, -1)

    M._scroll_to_bottom()
end

-- Tool display

function M.show_tool_call(id, name, label)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    local display_label = label
    if #display_label > 50 then
        display_label = display_label:sub(1, 47) .. "..."
    end

    local line = string.format("  %s **%s** `%s`", "⏳", name, display_label)
    local line_count = vim.api.nvim_buf_line_count(state.output_buf)
    vim.api.nvim_buf_set_lines(state.output_buf, line_count, line_count, false, { line })

    -- Store extmark for later update, keyed by tool_id from backend
    if id then
        local mark_id = vim.api.nvim_buf_set_extmark(state.output_buf, ns_tools, line_count, 0, {})
        state.tool_extmarks[id] = { mark_id = mark_id, line = line_count }
    end

    M._scroll_to_bottom()
end

function M.show_tool_result(id, status)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
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
    local info = state.tool_extmarks[id]
    if info then
        local mark = vim.api.nvim_buf_get_extmark_by_id(state.output_buf, ns_tools, info.mark_id, {})
        if mark and #mark > 0 then
            local line_num = mark[1]
            local current_line = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1] or ""
            -- Replace icon
            local new_line = current_line:gsub("^%s*[⏳▶✓✗]", "  " .. icon)
            vim.api.nvim_buf_set_lines(state.output_buf, line_num, line_num + 1, false, { new_line })
            return
        end
    end

    -- Fallback: append new line (don't show raw tool IDs)
    -- This shouldn't happen if tool_call was received first, but handle gracefully
    M._scroll_to_bottom()
end

-- Status line

function M._build_status(panel_state)
    panel_state = panel_state or get_state()
    local parts = {}

    -- Connection status
    local connected = panel_state.bridge and panel_state.bridge.is_running and panel_state.bridge.is_running()
    if connected then
        table.insert(parts, "%#DiagnosticOk#●%*")
    else
        local bridge_state = panel_state.bridge and panel_state.bridge.get_state and panel_state.bridge.get_state() or {}
        if bridge_state.reconnect_attempt and bridge_state.reconnect_attempt > 0 then
            table.insert(parts, string.format("%%#DiagnosticWarn#○(%d)%%*", bridge_state.reconnect_attempt))
        else
            table.insert(parts, "%#DiagnosticError#○%*")
        end
    end

    -- Get bridge state
    local bridge_state = panel_state.bridge and panel_state.bridge.get_state and panel_state.bridge.get_state() or {}

    -- Engine
    local engine = bridge_state.engine or panel_state.current_engine
    if engine then
        local engine_name = engine:sub(1, 1):upper() .. engine:sub(2):lower()
        table.insert(parts, string.format("[%s]", engine_name))
    end

    -- Model
    if bridge_state.model then
        table.insert(parts, bridge_state.model)
    end

    -- Mode (always show)
    local mode = bridge_state.mode or "default"
    local mode_display = {
        default = "Default",
        accept_edits = "Accept Edits",
        auto_approve = "Auto Approve",
        plan_only = "Plan",
        -- Handle capitalized versions from backend
        Default = "Default",
        ["Accept Edits"] = "Accept Edits",
        ["Auto Approve"] = "Auto Approve",
        Plan = "Plan",
    }
    table.insert(parts, string.format("(%s)", mode_display[mode] or mode))

    -- Streaming indicator
    if panel_state.is_streaming then
        table.insert(parts, "%#DiagnosticInfo#...%*")
    end

    -- Session duration (from bridge state)
    if bridge_state.session_active and bridge_state.session_start_time then
        local elapsed_ms = vim.loop.now() - bridge_state.session_start_time
        local elapsed_sec = math.floor(elapsed_ms / 1000)
        local mins = math.floor(elapsed_sec / 60)
        local secs = elapsed_sec % 60
        table.insert(parts, string.format("[%dm %02ds]", mins, secs))
    end

    table.insert(parts, "%=")

    return table.concat(parts, " ")
end

function M._update_status()
    local state = get_state()
    if state.output_win and vim.api.nvim_win_is_valid(state.output_win) then
        vim.api.nvim_set_option_value("winbar", M._build_status(), { win = state.output_win })
    end
end

function M._start_session_timer()
    local state = get_state()
    local my_tabid = vim.api.nvim_get_current_tabpage()
    if state.session_timer then
        return
    end

    state.session_timer = vim.loop.new_timer()
    if state.session_timer then
        state.session_timer:start(1000, 1000, vim.schedule_wrap(function()
            -- Use captured tabid to get correct state
            local my_state = states[my_tabid]
            if not my_state then return end
            if my_state.output_win and vim.api.nvim_win_is_valid(my_state.output_win) then
                vim.api.nvim_set_option_value("winbar", M._build_status(my_state), { win = my_state.output_win })
            end
        end))
    end
end

function M._stop_session_timer()
    local state = get_state()
    if state.session_timer then
        state.session_timer:stop()
        state.session_timer:close()
        state.session_timer = nil
    end
end

function M._mark_markdown_headers(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    -- Pattern matches: ## Header or # Header
    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if line_text and vim.startswith(vim.trim(line_text), "#") then
            -- Apply bold highlight
            vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "Bold", line_num, 0, -1)
        end
    end
end

function M._mark_inline_formatting(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if not line_text then
            goto continue
        end

        -- **bold**
        local col = 1
        while true do
            local s, e = string.find(line_text, "%*%*([^*]+)%*%*", col)
            if not s then break end
            vim.api.nvim_buf_set_extmark(state.output_buf, ns_id, line_num, s - 1, {
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
            vim.api.nvim_buf_set_extmark(state.output_buf, ns_id, line_num, s - 1, {
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
            vim.api.nvim_buf_set_extmark(state.output_buf, ns_id, line_num, s - 1, {
                end_col = e,
                hl_group = "Special",
            })
            col = e + 1
        end

        ::continue::
    end
end

function M._mark_lists(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if not line_text then
            goto continue
        end

        -- Find list marker position (accounting for leading whitespace)
        local indent_end = line_text:find("[^%s]") or 1
        local after_indent = line_text:sub(indent_end)

        -- Unordered list: - item or * item
        if after_indent:match("^[%-*]%s+") then
            -- Use virtual text to overlay the bullet
            -- This preserves the original buffer content for copy/paste
            vim.api.nvim_buf_set_extmark(state.output_buf, ns_id, line_num, indent_end - 1, {
                end_col = indent_end, -- Cover the - or * character
                virt_text = { { "•", "Normal" } },
                virt_text_pos = "overlay",
            })
            goto continue
        end

        -- Ordered lists: keep as-is (numbered lists are clear enough)

        ::continue::
    end
end

function M._mark_file_paths(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    -- Pattern matches: path/to/file:123 (with optional extension)
    -- Supports: file.ext:123, /abs/path/file.ext:123, Makefile:10, etc.
    local pattern = "([%w_/.%-]+):(%d+)"

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if line_text then
            local col = 1
            while true do
                local s, e, file_path, line_number = string.find(line_text, pattern, col)
                if not s then
                    break
                end

                -- Validate that the file exists to avoid false positives
                -- Use vim.loop.fs_stat for efficient file existence check
                local stat = vim.loop.fs_stat(file_path)
                if stat and stat.type == "file" then
                    -- Create extmark with virtual text for underline effect
                    vim.api.nvim_buf_set_extmark(state.output_buf, ns_links, line_num, s - 1, {
                        end_col = e,
                        hl_group = "Underlined",
                    })
                end

                col = e + 1
            end
        end
    end
end

function M._highlight_code_block(start_line, end_line, lang)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
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
        vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "Special", i, 0, -1)
    end
end

function M._scroll_to_bottom(panel_state)
    panel_state = panel_state or get_state()
    if not panel_state.output_win or not vim.api.nvim_win_is_valid(panel_state.output_win) then
        return
    end

    -- Only auto-scroll if user hasn't manually scrolled in last 2 seconds
    local now = vim.loop.now()
    local time_since_scroll = now - panel_state.last_manual_scroll_time

    if time_since_scroll < 2000 then
        -- User recently scrolled, preserve position
        return
    end

    -- Auto-scroll to bottom
    local line_count = vim.api.nvim_buf_line_count(panel_state.output_buf)
    vim.api.nvim_win_set_cursor(panel_state.output_win, { line_count, 0 })
end

-- Accessors for testing

function M.get_output_buf()
    local state = get_state()
    return state.output_buf
end

function M.get_input_buf()
    local state = get_state()
    return state.input_buf
end

function M.get_output_win()
    local state = get_state()
    return state.output_win
end

function M.get_input_win()
    local state = get_state()
    return state.input_win
end

function M.cleanup_tab(tabid)
    if type(tabid) ~= "number" or not states[tabid] then
        return
    end

    local state = states[tabid]

    -- Stop session timer
    if state.session_timer then
        state.session_timer:stop()
        state.session_timer:close()
    end

    -- Delete autocmd group
    local group_name = string.format("BanjoOutput_%d_%d", tabid, state.output_buf)
    pcall(vim.api.nvim_del_augroup_by_name, group_name)

    -- Clear extmarks
    if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
        vim.api.nvim_buf_clear_namespace(state.output_buf, ns_id, 0, -1)
        vim.api.nvim_buf_clear_namespace(state.output_buf, ns_tools, 0, -1)
        vim.api.nvim_buf_clear_namespace(state.output_buf, ns_links, 0, -1)
    end

    -- Remove state
    states[tabid] = nil
end

-- Expose for testing
M._get_state = get_state

return M
