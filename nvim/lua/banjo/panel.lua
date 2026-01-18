-- Banjo panel: Chat UI with output section and input field
local sections = require("banjo.ui.sections")
local M = {}

-- Global config
local config = {
    width = 50,
    position = "right",
    input_height = 3,
    title = " Banjo ",
    debug = false,
}

-- Debug logging (opt-in)
local function lua_debug(msg)
    if not vim.g.banjo_debug then
        return
    end
    local ok, err = pcall(function()
        local line = os.date("%H:%M:%S ") .. "[panel] " .. msg
        vim.fn.writefile({line}, "/tmp/banjo-lua-debug.log", "a")
    end)
    if not ok then
        vim.notify("lua_debug error: " .. tostring(err), vim.log.levels.ERROR)
    end
end

-- Global namespaces (process-wide identifiers)
local ns_id = vim.api.nvim_create_namespace("banjo")
local ns_tools = vim.api.nvim_create_namespace("banjo_tools")
local ns_links = vim.api.nvim_create_namespace("banjo_links")
local ns_header = vim.api.nvim_create_namespace("banjo_header")
local ns_actions = vim.api.nvim_create_namespace("banjo_actions")

local set_output_keymaps

local function setup_highlights()
    local set_hl = vim.api.nvim_set_hl
    set_hl(0, "BanjoUser", { link = "String" })
    set_hl(0, "BanjoAssistant", { link = "Normal" })
    set_hl(0, "BanjoThought", { link = "Comment" })
    set_hl(0, "BanjoTool", { link = "Function" })
    set_hl(0, "BanjoToolOk", { link = "DiagnosticOk" })
    set_hl(0, "BanjoToolErr", { link = "DiagnosticError" })
    set_hl(0, "BanjoToolPending", { link = "DiagnosticWarn" })
    set_hl(0, "BanjoLink", { link = "Underlined" })
    set_hl(0, "BanjoCodeFence", { link = "Special" })
    set_hl(0, "BanjoInlineCode", { link = "Special" })
    set_hl(0, "BanjoHeader", { link = "Title" })
    set_hl(0, "BanjoAuthKey", { link = "Special" })
    set_hl(0, "BanjoAuthActive", { link = "Title" })
    set_hl(0, "BanjoAuthInactive", { link = "Comment" })
    set_hl(0, "BanjoQuote", { link = "Comment" })
    set_hl(0, "BanjoListBullet", { link = "Delimiter" })
    set_hl(0, "BanjoStatus", { link = "Comment" })
    set_hl(0, "BanjoCodeBlock", { link = "Special" })
    set_hl(0, "BanjoActionKey", { link = "Special" })
    set_hl(0, "BanjoActionLabel", { link = "Comment" })
    set_hl(0, "BanjoActionValue", { link = "Identifier" })
end

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
            link_data = {},
            stat_cache = {},
            stat_cache_size = 0,
            thought_blocks = {},
            thought_buffer = nil,
            thought_start_line = nil,
            code_blocks = {},
            code_start_line = nil,
            code_lang = nil,
            code_scan_line = -1,
            code_line_partial = false,
            history = nil,
            last_manual_scroll_time = 0,
            session_timer = nil,
            bridge = nil,
            sections = sections.new(),
        }
    end
    return states[tabid]
end

local function ensure_sections(state)
    if not state.sections then
        state.sections = sections.new()
    end
end

local function refresh_section_ranges(state)
    ensure_sections(state)
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end
    local total = vim.api.nvim_buf_line_count(state.output_buf)
    local ranges, resolved = sections.compute_ranges(total, state.sections.counts or {})
    state.sections.ranges = ranges
    state.sections.counts = {
        header = resolved.header or 0,
        input = resolved.input or 0,
        actions = resolved.actions or 0,
        history = nil,
    }
end

local function history_range(state)
    refresh_section_ranges(state)
    return state.sections.ranges.history or { start = 0, stop = 0 }
end

local function append_history_lines(state, lines)
    if not lines or #lines == 0 then
        return history_range(state).stop
    end
    local range = history_range(state)
    vim.api.nvim_buf_set_lines(state.output_buf, range.stop, range.stop, false, lines)
    refresh_section_ranges(state)
    return range.stop
end

local function set_section_lines(state, key, lines)
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end
    refresh_section_ranges(state)
    local range = state.sections.ranges[key] or { start = 0, stop = 0 }
    vim.api.nvim_buf_set_lines(state.output_buf, range.start, range.stop, false, lines)
    state.sections.counts[key] = #lines
    refresh_section_ranges(state)
end

function M.setup(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})
    if opts and opts.debug ~= nil then
        vim.g.banjo_debug = opts.debug
    elseif vim.g.banjo_debug == nil then
        vim.g.banjo_debug = config.debug
    end
    setup_highlights()
end

function M.set_bridge(b)
    local state = get_state()
    state.bridge = b
end

function M._set_permission_mode(mode)
    local state = get_state()
    if state.bridge and state.bridge.set_permission_mode then
        state.bridge.set_permission_mode(mode)
    end
end

-- Get or create history for this tab (uses bridge cwd)
local function get_history()
    local state = get_state()
    if not state.history then
        local History = require("banjo.history")
        local cwd = (state.bridge and state.bridge.reconnect and state.bridge.reconnect.cwd)
            or vim.fn.getcwd()
        state.history = History.new(cwd)
        state.history:load()
    end
    return state.history
end

-- Output buffer

local function create_output_buffer()
    local state = get_state()
    if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
        return state.output_buf
    end

    -- Clean up stale buffer with same name if it exists
    local tabid = vim.api.nvim_get_current_tabpage()
    local bufname = string.format("Banjo-%d", tabid)
    local existing = vim.fn.bufnr(bufname)
    if existing ~= -1 and not vim.api.nvim_buf_is_valid(existing) then
        pcall(vim.cmd, "bwipeout! " .. existing)
    elseif existing ~= -1 and existing ~= state.output_buf then
        pcall(vim.cmd, "bwipeout! " .. existing)
    end

    state.output_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.output_buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = state.output_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = state.output_buf })
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = state.output_buf })
    vim.api.nvim_set_option_value("modifiable", true, { buf = state.output_buf })

    -- Set fold options for manual folding (must be window-local, set when displayed)
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = state.output_buf,
        callback = function()
            vim.opt_local.foldmethod = "manual"
            vim.opt_local.foldenable = true
            vim.opt_local.foldlevel = 99  -- Start with all folds open
        end,
    })

    -- Disable completions for output buffer (prevent blink.cmp and other plugins)
    vim.api.nvim_set_option_value("omnifunc", "", { buf = state.output_buf })
    vim.api.nvim_set_option_value("completefunc", "", { buf = state.output_buf })
    vim.b[state.output_buf].cmp_enabled = false
    vim.b[state.output_buf].blink_cmp_enabled = false

    vim.api.nvim_buf_set_name(state.output_buf, bufname)
    set_output_keymaps(state.output_buf, state)
    refresh_section_ranges(state)

    return state.output_buf
end

-- Input buffer

local function create_input_buffer()
    local state = get_state()
    if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
        return state.input_buf
    end

    -- Clean up stale buffer with same name if it exists
    local tabid = vim.api.nvim_get_current_tabpage()
    local bufname = string.format("BanjoInput-%d", tabid)
    local existing = vim.fn.bufnr(bufname)
    if existing ~= -1 and not vim.api.nvim_buf_is_valid(existing) then
        pcall(vim.cmd, "bwipeout! " .. existing)
    elseif existing ~= -1 and existing ~= state.input_buf then
        pcall(vim.cmd, "bwipeout! " .. existing)
    end

    state.input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.input_buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = state.input_buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = state.input_buf })
    vim.api.nvim_set_option_value("filetype", "banjo_input", { buf = state.input_buf })

    vim.api.nvim_buf_set_name(state.input_buf, bufname)

    -- Set initial prompt indicator
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { "" })

    -- Disable nvim's built-in completion sources
    vim.api.nvim_set_option_value("omnifunc", "", { buf = state.input_buf })
    vim.api.nvim_set_option_value("completefunc", "", { buf = state.input_buf })

    return state.input_buf
end

local function build_input_padding(count)
    local lines = {}
    for i = 1, count do
        lines[i] = ""
    end
    return lines
end

local function update_input_window(state)
    if not state.output_win or not vim.api.nvim_win_is_valid(state.output_win) then
        return
    end
    if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
        return
    end

    local width = vim.api.nvim_win_get_width(state.output_win)
    local height = vim.api.nvim_win_get_height(state.output_win)
    local header_lines = state.sections.counts.header or 0
    local action_lines = state.sections.counts.actions or 0
    local fixed_top = header_lines + action_lines
    local max_input = height - fixed_top
    if max_input < 1 then
        max_input = 1
    end
    local input_height = math.min(config.input_height, max_input)
    state.sections.counts.input = input_height
    set_section_lines(state, "input", build_input_padding(input_height))

    local row = height - input_height
    local cfg = {
        relative = "win",
        win = state.output_win,
        row = row,
        col = 0,
        width = width,
        height = input_height,
        style = "minimal",
        focusable = true,
        noautocmd = true,
    }
    local update_cfg = {
        relative = cfg.relative,
        win = cfg.win,
        row = cfg.row,
        col = cfg.col,
        width = cfg.width,
        height = cfg.height,
        style = cfg.style,
        focusable = cfg.focusable,
    }

    if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
        vim.api.nvim_win_set_config(state.input_win, update_cfg)
        if vim.api.nvim_win_get_buf(state.input_win) ~= state.input_buf then
            vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
        end
    else
        state.input_win = vim.api.nvim_open_win(state.input_buf, false, cfg)
    end

    vim.api.nvim_set_option_value("wrap", true, { win = state.input_win })
    vim.api.nvim_set_option_value("linebreak", true, { win = state.input_win })
    vim.api.nvim_set_option_value("number", false, { win = state.input_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = state.input_win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = state.input_win })
    vim.api.nvim_set_option_value("cursorline", false, { win = state.input_win })
end

-- Command argument options with descriptions
local command_args = {
    mode = {
        { word = "default", abbr = "Ask permission" },
        { word = "accept_edits", abbr = "Accept edits" },
        { word = "auto_approve", abbr = "Approve all" },
        { word = "plan_only", abbr = "Plan only" },
    },
}

-- Build model completions from backend state
local function get_model_completions()
    local state = get_state()
    local models = state.bridge and state.bridge.get_state and state.bridge.get_state().models or {}
    local result = {}
    for _, m in ipairs(models) do
        table.insert(result, {
            word = m.id,
            abbr = m.name .. (m.desc and (" (" .. m.desc .. ")") or ""),
        })
    end
    return result
end

-- Slash command completion function
local function banjo_complete(findstart, base)
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col(".") - 1

    if findstart == 1 then
        -- Check if we're completing an argument (after command + space)
        local cmd_match = line:match("^/(%w+)%s+")
        if cmd_match and (cmd_match == "model" or command_args[cmd_match]) then
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
        if cmd_match then
            local args
            if cmd_match == "model" then
                args = get_model_completions()
            else
                args = command_args[cmd_match]
            end

            if args then
                local matches = {}
                for _, arg in ipairs(args) do
                    if base == "" or vim.startswith(arg.word, base) then
                        table.insert(matches, {
                            word = arg.word,
                            abbr = arg.abbr,
                        })
                    end
                end
                return matches
            end
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

    -- Enter to submit (accepts completion first if popup visible)
    vim.keymap.set("i", "<CR>", function()
        if vim.fn.pumvisible() == 1 then
            -- Accept completion, then submit after popup closes
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-y>", true, false, true), "n", false)
            vim.schedule(function()
                M.submit_input()
            end)
            return
        end
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

    -- 'q' to close panel (same as output buffer)
    vim.keymap.set("n", "q", function()
        M.close()
    end, { buffer = buf, noremap = true })

    -- Up/Down for history navigation
    vim.keymap.set({ "n", "i" }, "<Up>", function()
        local history = get_history()

        -- First Up press: save current input
        if history.offset == 0 then
            history.temp_input = M.get_input_text()
        end

        -- Navigate back in history
        if history.offset < history:size() then
            history.offset = history.offset + 1
            local entry = history:get(history.offset - 1)
            if entry then
                M.set_input_text(entry)
            end
        end
    end, { buffer = buf, noremap = true })

    vim.keymap.set({ "n", "i" }, "<Down>", function()
        local history = get_history()

        if history.offset == 0 then
            return
        end

        -- Navigate forward in history
        history.offset = history.offset - 1

        if history.offset == 0 then
            -- Restore temp input
            M.set_input_text(history.temp_input)
        else
            local entry = history:get(history.offset - 1)
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
set_output_keymaps = function(buf, state)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local function set_mode(mode)
        M._set_permission_mode(mode)
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

    -- 'z' to toggle fold under cursor
    vim.keymap.set("n", "z", function()
        pcall(vim.cmd, "normal! za")
    end, { buffer = buf, noremap = true })

    -- Ctrl-C to cancel
    vim.keymap.set("n", "<C-c>", function()
        if state.bridge then
            state.bridge.cancel()
            M.append_status("Cancelled")
        end
    end, { buffer = buf, noremap = true })

    local commands = require("banjo.commands")
    local function dispatch(cmd, args)
        commands.dispatch(cmd, args or "", { bridge = state.bridge, panel = M })
    end

    vim.keymap.set("n", "p", function()
        M.focus_input()
    end, { buffer = buf, noremap = true })
    vim.keymap.set("n", "c", function()
        dispatch("cancel", "")
    end, { buffer = buf, noremap = true })
    vim.keymap.set("n", "n", function()
        if state.bridge and state.bridge.toggle_nudge then
            state.bridge.toggle_nudge()
            M.append_status("Nudge toggled")
        end
    end, { buffer = buf, noremap = true })
    vim.keymap.set("n", "m", function()
        M._action_cycle_mode()
    end, { buffer = buf, noremap = true })
    vim.keymap.set("n", "a", function()
        M._action_toggle_agent()
    end, { buffer = buf, noremap = true })
    vim.keymap.set("n", "M", function()
        M._action_cycle_model()
    end, { buffer = buf, noremap = true })

    vim.keymap.set("n", "D", function()
        set_mode("default")
    end, { buffer = buf, noremap = true })
    vim.keymap.set("n", "E", function()
        set_mode("accept_edits")
    end, { buffer = buf, noremap = true })
    vim.keymap.set("n", "A", function()
        set_mode("auto_approve")
    end, { buffer = buf, noremap = true })
    vim.keymap.set("n", "P", function()
        set_mode("plan_only")
    end, { buffer = buf, noremap = true })

    vim.keymap.set("n", "<LeftMouse>", function()
        local mouse = vim.fn.getmousepos()
        if not mouse or mouse.winid ~= state.output_win then
            return "<LeftMouse>"
        end
        local line = mouse.line - 1
        local col = mouse.column - 1
        for _, item in ipairs(state.header_actions or {}) do
            if line == item.line and col >= item.start and col < item.stop then
                set_mode(item.mode)
                return "<Ignore>"
            end
        end
        return "<LeftMouse>"
    end, { buffer = buf, noremap = true, silent = true, expr = true })
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

    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
        group = augroup,
        callback = function()
            local my_state = states[my_tabid]
            if my_state then
                update_input_window(my_state)
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
    vim.api.nvim_set_option_value("breakindent", true, { win = state.output_win })
    vim.api.nvim_set_option_value("number", false, { win = state.output_win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = state.output_win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = state.output_win })
    vim.api.nvim_set_option_value("winfixwidth", true, { win = state.output_win })
    vim.api.nvim_set_option_value("cursorline", false, { win = state.output_win })

    update_input_window(state)

    -- Setup keymaps
    setup_input_keymaps()
    setup_output_keymaps()

    -- Focus back on the main editing window (not panel)
    vim.cmd("wincmd p")

    M._update_status()
end

-- Public API

function M.open()
    lua_debug("M.open called")
    local state = get_state()
    create_panel()
    lua_debug("M.open done, input_buf=" .. tostring(state.input_buf))
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
    if not state.input_win or not vim.api.nvim_win_is_valid(state.input_win) then
        update_input_window(state)
    end
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
    lua_debug("submit_input called")
    local state = get_state()
    if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
        lua_debug("  no valid input_buf, recreating")
        -- Buffer was invalidated (e.g., by :bwipe), recreate panel
        state.input_buf = nil
        state.output_buf = nil
        state.input_win = nil
        state.output_win = nil
        create_panel()
        if not state.input_buf or not vim.api.nvim_buf_is_valid(state.input_buf) then
            vim.notify("Banjo: Failed to recover panel. Try :BanjoToggle", vim.log.levels.ERROR)
            return
        end
    end

    local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    text = vim.trim(text)
    lua_debug("  text length: " .. #text)

    -- Validate input
    if text == "" then
        lua_debug("  empty text, returning")
        return
    end

    -- Enforce reasonable length limit (1MB = 1048576 bytes)
    if #text > 1048576 then
        M.append_status("Error: Input too long (max 1MB)")
        return
    end

    -- Add to history and reset navigation
    local history = get_history()
    history:add(text)
    history.offset = 0
    history.temp_input = ""

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
    lua_debug("  checking bridge: " .. tostring(state.bridge ~= nil))
    if state.bridge then
        lua_debug("  calling bridge.send_prompt")
        state.bridge.send_prompt(text)
        lua_debug("  send_prompt returned")
    else
        lua_debug("  no bridge!")
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
        local range = history_range(state)
        vim.api.nvim_buf_set_lines(state.output_buf, range.start, range.stop, false, { "" })

        -- Clear all extmark namespaces to prevent memory leak
        vim.api.nvim_buf_clear_namespace(state.output_buf, ns_id, range.start, range.stop)
        vim.api.nvim_buf_clear_namespace(state.output_buf, ns_tools, range.start, range.stop)
        vim.api.nvim_buf_clear_namespace(state.output_buf, ns_links, range.start, range.stop)
    end

    -- Reset tool tracking
    state.tool_extmarks = {}
    state.link_data = {}
    state.stat_cache = {}
    state.stat_cache_size = 0

    -- Reset thought/code tracking state to prevent memory leak and incorrect behavior
    state.thought_blocks = {}
    state.thought_buffer = nil
    state.thought_start_line = nil
    state.code_blocks = {}
    state.code_start_line = nil
    state.code_lang = nil
    state.code_scan_line = -1
    state.code_line_partial = false
    if state.sections and state.sections.counts then
        state.sections.counts.history = nil
    end
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

    local start_line = append_history_lines(state, formatted)

    -- Highlight user input with distinct color (String highlight)
    for i = start_line + 1, start_line + #lines do
        vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "BanjoUser", i, 0, -1)
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
    state.code_start_line = nil
    state.code_lang = nil
    state.code_scan_line = -1
    state.code_line_partial = false

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
        append_history_lines(state, { "" })
    end

    -- Reset streaming state in case of unclosed tags
    state.thought_buffer = nil
    state.thought_start_line = nil
    state.code_start_line = nil
    state.code_lang = nil
    state.code_scan_line = -1
    state.code_line_partial = false

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
        local range = history_range(state)
        state.thought_start_line = range.stop - 1
        -- Reset buffer after detecting opening tag to prevent memory leak
        state.thought_buffer = ""
    end

    -- Check for </think> tag
    local think_end = state.thought_buffer:find("</think>")
    if think_end and state.thought_start_line then
        local range = history_range(state)
        local end_line = range.stop

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

    local range = history_range(state)
    local history_end = range.stop
    local last_line = ""
    if history_end > range.start then
        last_line = vim.api.nvim_buf_get_lines(state.output_buf, history_end - 1, history_end, false)[1] or ""
    end

    -- If we just showed tool calls, add blank line before continuing text
    if state.needs_newline_after_tool then
        state.needs_newline_after_tool = false
        append_history_lines(state, { "" })
        range = history_range(state)
        history_end = range.stop
        last_line = ""
    end

    local did_append_to_last = last_line ~= ""
    local lines = vim.split(text, "\n", { plain = true })

    -- If last line is blank (separator), don't consume it - add new lines after
    if last_line == "" then
        append_history_lines(state, lines)
    else
        -- Append first line to last line
        if #lines > 0 then
            vim.api.nvim_buf_set_lines(state.output_buf, history_end - 1, history_end, false, { last_line .. lines[1] })
        end

        -- Append remaining lines
        if #lines > 1 then
            append_history_lines(state, vim.list_slice(lines, 2))
        end
    end

    -- Highlight thoughts
    if is_thought then
        local start_line = math.max(history_end - 1, range.start)
        local end_line = history_range(state).stop
        for i = start_line, end_line - 1 do
            vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "BanjoThought", i, 0, -1)
        end
    end

    local mark_start = math.max(history_end - 1, range.start)
    local mark_end = history_range(state).stop

    local scan_start = did_append_to_last and mark_start or history_end
    if state.code_line_partial then
        local pending_line = state.code_scan_line + 1
        if pending_line < scan_start then
            scan_start = pending_line
        end
    end
    if scan_start < 0 then
        scan_start = 0
    end
    if scan_start < mark_end then
        M._update_code_fences(scan_start, mark_end)
    end
    local ends_with_newline = text:sub(-1) == "\n"
    local last_idx = mark_end - 1
    if ends_with_newline then
        state.code_line_partial = false
        state.code_scan_line = last_idx
    else
        state.code_line_partial = true
        state.code_scan_line = math.max(last_idx - 1, -1)
    end

    -- Clear link extmarks in updated range to avoid duplicates
    local removed_links = vim.api.nvim_buf_get_extmarks(
        state.output_buf,
        ns_links,
        { mark_start, 0 },
        { mark_end - 1, -1 },
        {}
    )
    for _, mark in ipairs(removed_links) do
        state.link_data[mark[1]] = nil
    end
    vim.api.nvim_buf_clear_namespace(state.output_buf, ns_links, mark_start, mark_end)

    -- Detect and mark markdown headers
    M._mark_markdown_headers(mark_start, mark_end)

    -- Detect and mark inline formatting
    M._mark_inline_formatting(mark_start, mark_end)

    -- Highlight lines while inside an open code block
    M._mark_open_code_block(mark_start, mark_end)

    -- Detect and mark code fences
    M._mark_code_fences(mark_start, mark_end)

    -- Detect and mark blockquotes
    M._mark_blockquotes(mark_start, mark_end)

    -- Detect and render lists
    M._mark_lists(mark_start, mark_end)

    -- Detect and mark file paths
    M._mark_file_paths(mark_start, mark_end)

    -- Detect and mark file:// URIs
    M._mark_file_uris(mark_start, mark_end)

    -- Detect and mark URLs
    M._mark_urls(mark_start, mark_end)

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
    local start_line = append_history_lines(state, { "", line })

    -- Highlight as comment
    vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "BanjoStatus", start_line + 1, 0, -1)

    M._scroll_to_bottom()
end

-- Tool display

-- Format tool input for display (extract meaningful fields, not raw JSON)
-- Split a string by newlines and add each line to the table with optional prefix
local function add_lines(tbl, text, prefix)
    prefix = prefix or ""
    for line in text:gmatch("[^\n]+") do
        table.insert(tbl, prefix .. line)
    end
end

local function format_tool_input(name, input_json)
    if not input_json or input_json == "" then
        return nil
    end

    -- Try to parse JSON
    local ok, input = pcall(vim.json.decode, input_json)
    if not ok or type(input) ~= "table" then
        return nil
    end

    local lines = {}

    -- Bash/shell commands - show the command
    if name == "Bash" then
        if input.command then
            add_lines(lines, input.command, "$ ")
        end
        if input.description then
            add_lines(lines, input.description, "# ")
        end
        return #lines > 0 and lines or nil
    end

    -- Task - show description and prompt
    if name == "Task" then
        if input.description then
            add_lines(lines, input.description)
        end
        if input.prompt then
            -- Truncate long prompts
            local prompt = input.prompt
            if #prompt > 200 then
                prompt = prompt:sub(1, 197) .. "..."
            end
            add_lines(lines, prompt)
        end
        return #lines > 0 and lines or nil
    end

    -- WebFetch - show URL
    if name == "WebFetch" or name == "WebSearch" then
        if input.url then
            add_lines(lines, input.url)
        end
        if input.query then
            add_lines(lines, input.query)
        end
        return #lines > 0 and lines or nil
    end

    -- AskUserQuestion - show questions
    if name == "AskUserQuestion" then
        if input.questions and type(input.questions) == "table" then
            for _, q in ipairs(input.questions) do
                if q.question then
                    add_lines(lines, q.question, "? ")
                end
            end
        end
        return #lines > 0 and lines or nil
    end

    -- Default: extract common fields
    if input.file_path then
        add_lines(lines, input.file_path)
    end
    if input.pattern then
        add_lines(lines, input.pattern, "pattern: ")
    end
    if input.content and #input.content < 100 then
        add_lines(lines, input.content)
    end

    return #lines > 0 and lines or nil
end

function M.show_tool_call(id, name, label, input)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    -- Only show label if different from name and non-empty
    local display_label = nil
    if label and label ~= "" and label ~= name then
        display_label = label
        if #display_label > 50 then
            display_label = display_label:sub(1, 47) .. "..."
        end
    end

    local line
    if display_label then
        line = string.format("  %s **%s** `%s`", ".", name, display_label)
    else
        line = string.format("  %s **%s**", ".", name)
    end

    local start_line = history_range(state).stop

    -- Format input nicely (extract meaningful fields)
    local formatted_lines = format_tool_input(name, input)

    if formatted_lines and #formatted_lines > 0 then
        -- Indent formatted lines
        for i, l in ipairs(formatted_lines) do
            formatted_lines[i] = "    " .. l
        end
        local all_lines = { line }
        vim.list_extend(all_lines, formatted_lines)
        append_history_lines(state, all_lines)
        for i = start_line + 1, start_line + #formatted_lines do
            vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "BanjoCodeBlock", i, 0, -1)
        end

        -- Mark that we need a newline before next text append (only when we have input lines)
        state.needs_newline_after_tool = true

        -- Create fold for input (start after header, end at last input line)
        local fold_start = start_line + 1  -- 0-indexed, +1 for first input line
        local fold_end = start_line + #formatted_lines
        vim.api.nvim_buf_call(state.output_buf, function()
            vim.opt_local.foldmethod = "manual"
            vim.opt_local.foldenable = true
            pcall(vim.cmd, string.format("%d,%dfold", fold_start + 1, fold_end + 1))
            pcall(vim.cmd, string.format("%dfoldclose", fold_start + 1))
        end)
    else
        append_history_lines(state, { line })
    end

    -- Highlight tool header line
    vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "BanjoTool", start_line, 0, -1)

    -- Store extmark for later update, keyed by tool_id from backend
    if id then
        local mark_id = vim.api.nvim_buf_set_extmark(state.output_buf, ns_tools, start_line, 0, {})
        local icon_mark = vim.api.nvim_buf_set_extmark(state.output_buf, ns_tools, start_line, 2, {
            end_col = 3,
            hl_group = "BanjoToolPending",
        })
        state.tool_extmarks[id] = { mark_id = mark_id, line = start_line, icon_mark = icon_mark }
    end

    M._scroll_to_bottom()
end

function M.show_tool_result(id, status)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    local icon = "✓"
    local hl = "BanjoToolOk"
    if status == "failed" then
        icon = "✗"
        hl = "BanjoToolErr"
    elseif status == "running" then
        icon = ">"
        hl = "BanjoToolPending"
    elseif status == "pending" then
        icon = "."
        hl = "BanjoToolPending"
    end

    -- Try to find and update existing tool line by exact ID match
    -- The id parameter is the full composite key: "name_label"
    local info = state.tool_extmarks[id]
    if info then
        local mark = vim.api.nvim_buf_get_extmark_by_id(state.output_buf, ns_tools, info.mark_id, {})
        if mark and #mark > 0 then
            local line_num = mark[1]
            local current_line = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1] or ""
            -- Replace icon at position 3 (after "  ")
            -- Use vim.fn to handle UTF-8 properly
            local prefix = vim.fn.strcharpart(current_line, 0, 2)  -- "  "
            local suffix = vim.fn.strcharpart(current_line, 3)     -- everything after icon
            local new_line = prefix .. icon .. suffix
            vim.api.nvim_buf_set_lines(state.output_buf, line_num, line_num + 1, false, { new_line })
            if info.icon_mark then
                vim.api.nvim_buf_del_extmark(state.output_buf, ns_tools, info.icon_mark)
            end
            info.icon_mark = vim.api.nvim_buf_set_extmark(state.output_buf, ns_tools, line_num, 2, {
                end_col = 3,
                hl_group = hl,
            })
            return
        end
    end

    -- Fallback: append new line (don't show raw tool IDs)
    -- This shouldn't happen if tool_call was received first, but handle gracefully
    M._scroll_to_bottom()
end

-- Status line

local function format_mode_label(mode)
    local mode_display = {
        default = "Default",
        accept_edits = "Accept Edits",
        auto_approve = "Auto-approve",
        plan_only = "Plan",
        -- Handle capitalized versions from backend
        Default = "Default",
        ["Accept Edits"] = "Accept Edits",
        ["Auto Approve"] = "Auto-approve",
        ["Auto-approve"] = "Auto-approve",
        Plan = "Plan",
    }
    return mode_display[mode] or mode
end

local function normalize_mode(mode)
    local normalized = {
        Default = "default",
        ["Accept Edits"] = "accept_edits",
        ["Auto Approve"] = "auto_approve",
        ["Auto-approve"] = "auto_approve",
        Plan = "plan_only",
    }
    return normalized[mode] or mode
end

function M._action_cycle_mode()
    local state = get_state()
    local commands = require("banjo.commands")
    local bridge_state = state.bridge and state.bridge.get_state and state.bridge.get_state() or {}
    local current = normalize_mode(bridge_state.mode or "default")
    local modes = { "default", "accept_edits", "auto_approve", "plan_only" }
    local idx = 0
    for i, mode in ipairs(modes) do
        if mode == current then
            idx = i
            break
        end
    end
    local next_mode = modes[(idx % #modes) + 1]
    commands.dispatch("mode", next_mode, { bridge = state.bridge, panel = M })
end

function M._action_toggle_agent()
    local state = get_state()
    local commands = require("banjo.commands")
    local bridge_state = state.bridge and state.bridge.get_state and state.bridge.get_state() or {}
    local engine = (bridge_state.engine or state.current_engine or "claude")
    engine = engine:lower()
    local next_engine = engine == "claude" and "codex" or "claude"
    commands.dispatch(next_engine, "", { bridge = state.bridge, panel = M })
end

function M._action_cycle_model()
    local state = get_state()
    local commands = require("banjo.commands")
    local bridge_state = state.bridge and state.bridge.get_state and state.bridge.get_state() or {}
    local models = bridge_state.models or {}
    if #models == 0 then
        M.append_status("No models available")
        return
    end

    local ids = {}
    for _, model in ipairs(models) do
        local id = model.id or model
        if id then
            table.insert(ids, id)
        end
    end

    if #ids == 0 then
        M.append_status("No models available")
        return
    end

    local current = bridge_state.model
    local idx = 0
    for i, id in ipairs(ids) do
        if id == current then
            idx = i
            break
        end
    end
    local next_id = ids[(idx % #ids) + 1]
    commands.dispatch("model", next_id, { bridge = state.bridge, panel = M })
end

function M._build_status(panel_state)
    panel_state = panel_state or get_state()
    local bridge_state = panel_state.bridge and panel_state.bridge.get_state and panel_state.bridge.get_state() or {}
    local connected = panel_state.bridge and panel_state.bridge.is_running and panel_state.bridge.is_running()

    local conn_label = "offline"
    local conn_hl = "DiagnosticError"
    if connected then
        conn_label = "online"
        conn_hl = "DiagnosticOk"
    elseif bridge_state.reconnect_attempt and bridge_state.reconnect_attempt > 0 then
        conn_label = string.format("reconnect %d", bridge_state.reconnect_attempt)
        conn_hl = "DiagnosticWarn"
    end

    local engine = bridge_state.engine or panel_state.current_engine
    local engine_name = engine and (engine:sub(1, 1):upper() .. engine:sub(2):lower()) or nil

    local line1_parts = { "Banjo" }
    if engine_name then
        table.insert(line1_parts, engine_name)
    end
    if bridge_state.model then
        table.insert(line1_parts, bridge_state.model)
    end

    if panel_state.is_streaming then
        table.insert(line1_parts, "Streaming")
    end

    if bridge_state.session_active and bridge_state.session_start_time then
        local elapsed_ms = vim.loop.now() - bridge_state.session_start_time
        local elapsed_sec = math.floor(elapsed_ms / 1000)
        local mins = math.floor(elapsed_sec / 60)
        local secs = elapsed_sec % 60
        table.insert(line1_parts, string.format("Session: %dm %02ds", mins, secs))
    end

    local line1 = table.concat(line1_parts, "  ")

    local active_mode = normalize_mode(bridge_state.mode or "default")
    local line2 = conn_label
    local mode_items = {
        { key = "D", mode = "default", label = format_mode_label("default") },
        { key = "E", mode = "accept_edits", label = format_mode_label("accept_edits") },
        { key = "A", mode = "auto_approve", label = format_mode_label("auto_approve") },
        { key = "P", mode = "plan_only", label = format_mode_label("plan_only") },
    }

    local highlights = {
        { line = 0, start = 0, stop = #"Banjo", group = "BanjoHeader" },
        { line = 1, start = 0, stop = #conn_label, group = conn_hl },
    }

    local header_actions = {}
    for _, item in ipairs(mode_items) do
        if line2 ~= "" then
            line2 = line2 .. "  "
        end
        local seg_start = #line2
        local seg = "[" .. item.key .. "] " .. item.label
        local label_start = seg_start + 4
        local label_end = label_start + #item.label
        line2 = line2 .. seg

        table.insert(header_actions, { line = 1, start = seg_start, stop = seg_start + #seg, mode = item.mode })
        table.insert(highlights, { line = 1, start = seg_start + 1, stop = seg_start + 2, group = "BanjoAuthKey" })
        table.insert(highlights, {
            line = 1,
            start = label_start,
            stop = label_end,
            group = item.mode == active_mode and "BanjoAuthActive" or "BanjoAuthInactive",
        })
    end

    panel_state.header_actions = header_actions

    return { line1, line2 }, highlights
end

function M._build_actions(panel_state)
    panel_state = panel_state or get_state()
    local bridge_state = panel_state.bridge and panel_state.bridge.get_state and panel_state.bridge.get_state() or {}

    local engine = bridge_state.engine or panel_state.current_engine
    local engine_name = engine and (engine:sub(1, 1):upper() .. engine:sub(2):lower()) or "-"
    local mode_label = format_mode_label(bridge_state.mode or "default")
    local model = bridge_state.model or "-"

    local items = {
        { key = "p", label = "Prompt" },
        { key = "c", label = "Cancel" },
        { key = "n", label = "Nudge" },
        { key = "m", label = "Mode", value = mode_label },
        { key = "a", label = "Agent", value = engine_name },
        { key = "M", label = "Model", value = model },
    }

    local line = ""
    local highlights = {}

    local function append_item(item)
        if line ~= "" then
            line = line .. "  "
        end
        local seg_start = #line
        local seg = "[" .. item.key .. "] " .. item.label
        local label_start = seg_start + 4
        local label_end = label_start + #item.label
        line = line .. seg
        table.insert(highlights, { line = 0, start = seg_start + 1, stop = seg_start + 2, group = "BanjoActionKey" })
        table.insert(highlights, { line = 0, start = label_start, stop = label_end, group = "BanjoActionLabel" })

        if item.value then
            local value_prefix = ": "
            local value_start = #line + #value_prefix
            line = line .. value_prefix .. item.value
            table.insert(highlights, {
                line = 0,
                start = value_start,
                stop = value_start + #item.value,
                group = "BanjoActionValue",
            })
        end
    end

    for _, item in ipairs(items) do
        append_item(item)
    end

    return { line }, highlights
end

local function render_header(state)
    if not state or not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end
    local lines, highlights = M._build_status(state)
    set_section_lines(state, "header", lines)
    refresh_section_ranges(state)

    local header_range = state.sections.ranges.header or { start = 0, stop = 0 }
    vim.api.nvim_buf_clear_namespace(state.output_buf, ns_header, header_range.start, header_range.stop)
    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(
            state.output_buf,
            ns_header,
            hl.group,
            header_range.start + hl.line,
            hl.start,
            hl.stop
        )
    end
end

local function render_actions(state)
    if not state or not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end
    local lines, highlights = M._build_actions(state)
    set_section_lines(state, "actions", lines)
    refresh_section_ranges(state)

    local action_range = state.sections.ranges.actions or { start = 0, stop = 0 }
    vim.api.nvim_buf_clear_namespace(state.output_buf, ns_actions, action_range.start, action_range.stop)
    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(
            state.output_buf,
            ns_actions,
            hl.group,
            action_range.start + hl.line,
            hl.start,
            hl.stop
        )
    end
end

function M._update_status()
    local state = get_state()
    render_header(state)
    render_actions(state)
end

function M._start_session_timer()
    local state = get_state()
    local my_tabid = vim.api.nvim_get_current_tabpage()

    -- Stop existing timer if any (restart behavior)
    if state.session_timer then
        state.session_timer:stop()
        state.session_timer:close()
        state.session_timer = nil
    end

    state.session_timer = vim.loop.new_timer()
    if state.session_timer then
        state.session_timer:start(1000, 1000, vim.schedule_wrap(function()
            -- Use captured tabid to get correct state
            local my_state = states[my_tabid]
            if not my_state then return end
            render_header(my_state)
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
            vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "BanjoHeader", line_num, 0, -1)
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
                hl_group = "BanjoInlineCode",
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
                virt_text = { { "-", "BanjoListBullet" } },
                virt_text_pos = "overlay",
            })
            goto continue
        end

        -- Ordered lists: keep as-is (numbered lists are clear enough)

        ::continue::
    end
end

function M._update_code_fences(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if line_text and vim.startswith(vim.trim(line_text), "```") then
            local lang = line_text:match("^%s*```([%w]*)") or ""
            if state.code_start_line then
                local end_line_idx = line_num + 1
                table.insert(state.code_blocks, {
                    start_line = state.code_start_line,
                    end_line = end_line_idx,
                    lang = state.code_lang,
                })
                M._highlight_code_block(state.code_start_line, end_line_idx, state.code_lang)
                state.code_start_line = nil
                state.code_lang = nil
            else
                state.code_start_line = line_num
                state.code_lang = lang ~= "" and lang or nil
            end
        end
    end
end

function M._mark_open_code_block(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end
    if not state.code_start_line then
        return
    end

    for line_num = start_line, end_line - 1 do
        if line_num <= state.code_start_line then
            goto continue
        end
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if line_text and vim.startswith(vim.trim(line_text), "```") then
            goto continue
        end
        vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "BanjoCodeBlock", line_num, 0, -1)
        ::continue::
    end
end

function M._mark_code_fences(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if line_text and vim.startswith(vim.trim(line_text), "```") then
            vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "BanjoCodeFence", line_num, 0, -1)
        end
    end
end

function M._mark_blockquotes(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if line_text and vim.startswith(vim.trim(line_text), ">") then
            vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "BanjoQuote", line_num, 0, -1)
        end
    end
end

local function resolve_path(state, path)
    if path:match("^/") or path:match("^%a:[/\\]") then
        return path
    end
    local cwd = (state.bridge and state.bridge.reconnect and state.bridge.reconnect.cwd) or vim.fn.getcwd()
    return vim.fn.fnamemodify(cwd .. "/" .. path, ":p")
end

local function stat_cached(state, path)
    local cached = state.stat_cache[path]
    if cached ~= nil then
        return cached
    end
    local stat = vim.loop.fs_stat(path)
    if stat and stat.type == "file" then
        state.stat_cache[path] = true
        state.stat_cache_size = state.stat_cache_size + 1
        if state.stat_cache_size > 256 then
            state.stat_cache = {}
            state.stat_cache_size = 0
        end
        return true
    end
    return false
end

local function set_link_extmark(state, buf, line_num, s, e, data)
    local id = vim.api.nvim_buf_set_extmark(buf, ns_links, line_num, s - 1, {
        end_col = e,
        hl_group = "BanjoLink",
    })
    state.link_data[id] = data
end

function M._mark_file_paths(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    local pattern_colon = "([%w_./~%-]+):(%d+):?(%d*)"
    local pattern_hash = "([%w_./~%-]+)#L(%d+)C?(%d*)"
    local pattern_bare = "([%w_./~%-]+/[%w_./~%-]+)"

    local function add_file_link(line_num, s, e, file_path, line_number, col_number)
        local abs_path = resolve_path(state, file_path)
        if stat_cached(state, abs_path) then
            local col_val = tonumber(col_number)
            set_link_extmark(state, state.output_buf, line_num, s, e, {
                type = "file",
                path = abs_path,
                line = tonumber(line_number) or 1,
                col = col_val and col_val > 0 and col_val or nil,
            })
        end
    end

    local function scan(line_text, line_num, pattern, handler)
        local col = 1
        while true do
            local s, e, a, b, c = string.find(line_text, pattern, col)
            if not s then
                break
            end
            handler(line_num, s, e, a, b, c)
            col = e + 1
        end
    end

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if line_text then
            scan(line_text, line_num, pattern_colon, function(ln, s, e, file_path, line_number, col_number)
                add_file_link(ln, s, e, file_path, line_number, col_number)
            end)
            scan(line_text, line_num, pattern_hash, function(ln, s, e, file_path, line_number, col_number)
                add_file_link(ln, s, e, file_path, line_number, col_number)
            end)
            scan(line_text, line_num, pattern_bare, function(ln, s, e, file_path)
                local next_char = line_text:sub(e + 1, e + 1)
                if next_char == ":" or next_char == "#" then
                    return
                end
                add_file_link(ln, s, e, file_path, 1, nil)
            end)
        end
    end
end

local function parse_file_uri(uri)
    local path_part, fragment = uri:match("^(file://[^#]+)#?(.*)$")
    if not path_part or path_part == "" then
        return nil
    end
    local ok, path = pcall(vim.uri_to_fname, path_part)
    if not ok or not path or path == "" then
        return nil
    end
    local line = 1
    local col = nil
    if fragment and fragment ~= "" then
        local l, c = fragment:match("^L(%d+)C?(%d*)$")
        if l then
            line = tonumber(l) or 1
            col = tonumber(c)
        end
    end
    return path, line, col
end

function M._mark_file_uris(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    local pattern = "(file://[^%s%]%[%)>\"']+)"

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if line_text then
            local col = 1
            while true do
                local s, e, uri = string.find(line_text, pattern, col)
                if not s then
                    break
                end
                local path, line, column = parse_file_uri(uri)
                if path then
                    if stat_cached(state, path) then
                        set_link_extmark(state, state.output_buf, line_num, s, e, {
                            type = "file",
                            path = path,
                            line = line or 1,
                            col = column,
                        })
                    end
                end
                col = e + 1
            end
        end
    end
end

function M._mark_urls(start_line, end_line)
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end

    local pattern = "(https?://[^%s%]%[%)>\"']+)"

    for line_num = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, line_num, line_num + 1, false)[1]
        if line_text then
            local col = 1
            while true do
                local s, e, url = string.find(line_text, pattern, col)
                if not s then
                    break
                end
                set_link_extmark(state, state.output_buf, line_num, s, e, { type = "url", url = url })
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

    _ = lang
    for i = start_line, end_line - 1 do
        local line_text = vim.api.nvim_buf_get_lines(state.output_buf, i, i + 1, false)[1]
        if line_text and vim.startswith(vim.trim(line_text), "```") then
            goto continue
        end
        vim.api.nvim_buf_add_highlight(state.output_buf, ns_id, "BanjoCodeBlock", i, 0, -1)
        ::continue::
    end
end

function M.open_link_under_cursor()
    local state = get_state()
    if not state.output_buf or not vim.api.nvim_buf_is_valid(state.output_buf) then
        return
    end
    if not state.output_win or not vim.api.nvim_win_is_valid(state.output_win) then
        return
    end

    local row, col = unpack(vim.api.nvim_win_get_cursor(state.output_win))
    local marks = vim.api.nvim_buf_get_extmarks(
        state.output_buf,
        ns_links,
        { row - 1, 0 },
        { row - 1, -1 },
        { details = true }
    )
    local best = nil
    local best_priority = -1
    local best_len = nil
    for _, mark in ipairs(marks) do
        local mcol = mark[3]
        local details = mark[4] or {}
        local end_col = details.end_col or mcol
        if col >= mcol and col <= end_col then
            local data = state.link_data[mark[1]]
            if data then
                local priority = data.type == "url" and 2 or 1
                local len = end_col - mcol
                if priority > best_priority or (priority == best_priority and (best_len == nil or len < best_len)) then
                    best = data
                    best_priority = priority
                    best_len = len
                end
            end
        end
    end
    if best and best.type == "file" then
        vim.cmd("edit " .. vim.fn.fnameescape(best.path))
        local lnum = best.line or 1
        local cnum = best.col or 1
        vim.api.nvim_win_set_cursor(0, { lnum, math.max(cnum - 1, 0) })
        return
    elseif best and best.type == "url" then
        if vim.ui and vim.ui.open then
            vim.ui.open(best.url)
        else
            vim.notify(best.url, vim.log.levels.INFO)
        end
        return
    end
end

function M._get_link_data()
    local state = get_state()
    return state.link_data
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

-- Get history entries for session saving
function M.get_history_entries()
    local history = get_history()
    return history:get_all()
end

return M
