-- Banjo: Claude Code + Codex integration for Neovim
local M = {}

local bridge = require("banjo.bridge")
local panel = require("banjo.panel")

local default_config = {
    binary_path = nil, -- Will be auto-detected
    auto_start = true,
    panel = {},
    keymap_prefix = "<leader>a",  -- "a" for agent, avoids conflict with buffer keymaps
    keymaps = true,
    scope = true, -- Enable tab-scoped buffers via scope.nvim
}

local config = {}

local function find_binary()
    -- Check if in PATH
    local handle = io.popen("which banjo 2>/dev/null")
    if handle then
        local result = handle:read("*a"):gsub("%s+$", "")
        handle:close()
        if result ~= "" then
            return result
        end
    end

    -- Check common locations
    local locations = {
        vim.fn.expand("~/.local/bin/banjo"),
        "/usr/local/bin/banjo",
        "./zig-out/bin/banjo",
    }

    for _, path in ipairs(locations) do
        if vim.fn.executable(path) == 1 then
            return path
        end
    end

    return nil
end

function M.setup(opts)
    config = vim.tbl_deep_extend("force", default_config, opts or {})

    -- Find binary
    if not config.binary_path then
        config.binary_path = find_binary()
    end

    if not config.binary_path then
        vim.notify("Banjo: Binary not found. Set binary_path in config.", vim.log.levels.WARN)
        return
    end

    -- Setup scope.nvim for tab-scoped buffers (if available)
    if config.scope then
        local has_scope, scope = pcall(require, "scope")
        if has_scope then
            scope.setup({})
        end
    end

    -- Setup panel
    panel.setup(config.panel)

    -- Register commands
    vim.api.nvim_create_user_command("BanjoToggle", function()
        panel.toggle()
    end, { desc = "Toggle Banjo panel" })

    vim.api.nvim_create_user_command("BanjoStart", function()
        M.start()
    end, { desc = "Start Banjo" })

    vim.api.nvim_create_user_command("BanjoStop", function()
        M.stop()
    end, { desc = "Stop Banjo" })

    vim.api.nvim_create_user_command("BanjoRestart", function()
        M.stop()
        M.start()
    end, { desc = "Restart Banjo" })

    vim.api.nvim_create_user_command("BanjoClear", function()
        panel.clear()
    end, { desc = "Clear Banjo panel" })

    vim.api.nvim_create_user_command("BanjoSend", function(args)
        M.send(args.args)
    end, { nargs = 1, desc = "Send prompt to Banjo" })

    vim.api.nvim_create_user_command("BanjoCancel", function()
        bridge.cancel()
    end, { desc = "Cancel current request" })

    vim.api.nvim_create_user_command("BanjoNudge", function()
        bridge.toggle_nudge()
    end, { desc = "Toggle nudge mode" })

    vim.api.nvim_create_user_command("BanjoHelp", function()
        M.help()
    end, { desc = "Show Banjo keybindings" })

    vim.api.nvim_create_user_command("BanjoProject", function(args)
        M.open_project(args.args)
    end, { nargs = 1, complete = "dir", desc = "Open project in new tab" })

    -- Setup keymaps
    if config.keymaps then
        M.setup_keymaps()
    end

    -- Auto-start if enabled
    if config.auto_start then
        vim.defer_fn(function()
            M.start()
        end, 100)
    end
end

function M.start()
    if not config.binary_path then
        vim.notify("Banjo: Binary not configured", vim.log.levels.ERROR)
        return
    end

    -- Use tab-local CWD (-1 = current tab, 0 = any window in tab)
    local cwd = vim.fn.getcwd(-1, 0)
    bridge.start(config.binary_path, cwd)
end

function M.stop()
    bridge.stop()
end

function M.send(prompt)
    if not bridge.is_running() then
        M.start()
        -- Give it a moment to start
        vim.defer_fn(function()
            bridge.send_prompt(prompt)
        end, 200)
    else
        bridge.send_prompt(prompt)
    end
end

-- Send prompt with visual selection embedded
-- Required for Codex (no MCP), helpful for Claude (explicit context)
function M.send_selection()
    local mode = vim.fn.mode()
    if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
        vim.notify("Banjo: Not in visual mode", vim.log.levels.WARN)
        return
    end

    -- Exit visual mode to set marks
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)

    vim.defer_fn(function()
        local start_pos = vim.fn.getpos("'<")
        local end_pos = vim.fn.getpos("'>")
        local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)

        if #lines == 0 then
            vim.notify("Banjo: No selection", vim.log.levels.WARN)
            return
        end

        local text = table.concat(lines, "\n")
        local file_path = vim.api.nvim_buf_get_name(0)
        local file_name = vim.fn.fnamemodify(file_path, ":t")

        vim.ui.input({ prompt = "Banjo (with selection): " }, function(input)
            if input and input ~= "" then
                -- Embed selection in prompt with file context
                local prompt = string.format("%s\n\n```%s\n%s\n```", input, file_name, text)
                M.send(prompt)
            end
        end)
    end, 50)
end

function M.is_running()
    return bridge.is_running()
end

function M.get_mcp_port()
    return bridge.get_mcp_port()
end

-- Open a project in a new tab with its own cwd and bridge
function M.open_project(path)
    path = vim.fn.expand(path)
    if vim.fn.isdirectory(path) ~= 1 then
        vim.notify("Banjo: Not a directory: " .. path, vim.log.levels.ERROR)
        return
    end

    -- Create new tab
    vim.cmd("tabnew")

    -- Set tab-local cwd
    vim.cmd("tcd " .. vim.fn.fnameescape(path))

    -- Open file explorer if available
    local has_neotree = pcall(require, "neo-tree")
    if has_neotree then
        vim.cmd("Neotree reveal")
    else
        vim.cmd("Explore")
    end

    -- Start banjo for this tab (new bridge, new session)
    M.start()
    panel.open()
end

-- Resolve <leader> in prefix to human-readable key name
local function resolve_prefix(prefix)
    if not prefix:find("<leader>") then
        return prefix
    end
    local leader = vim.g.mapleader or "\\"
    local leader_name
    if leader == " " then
        leader_name = "SPC "
    elseif leader == "\\" then
        leader_name = "\\"
    else
        leader_name = leader
    end
    return prefix:gsub("<leader>", leader_name)
end

-- Show help in styled floating window
function M.help()
    local prefix = resolve_prefix(config.keymap_prefix or "<leader>b")

    local bindings = {
        { "b", "Toggle panel" },
        { "s", "Send prompt" },
        { "v", "Send with selection (visual)" },
        { "c", "Cancel request" },
        { "n", "Toggle nudge" },
        { "h", "Show this help" },
    }

    local lines = { "Banjo Keybindings", "" }
    for _, b in ipairs(bindings) do
        table.insert(lines, string.format("  %s%s  %s", prefix, b[1], b[2]))
    end

    -- Calculate window size
    local max_width = 0
    for _, line in ipairs(lines) do
        max_width = math.max(max_width, #line)
    end
    local width = math.min(max_width + 4, 50)
    local height = #lines

    -- Create buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

    -- Calculate position (centered)
    local uis = vim.api.nvim_list_uis()
    local ui_height = uis[1] and uis[1].height or 24
    local ui_width = uis[1] and uis[1].width or 80
    local row = math.floor((ui_height - height) / 2)
    local col = math.floor((ui_width - width) / 2)

    -- Create floating window
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Banjo ",
        title_pos = "center",
    })

    -- Apply highlights
    vim.api.nvim_set_option_value("winhl", "Normal:NormalFloat,FloatBorder:FloatBorder", { win = win })
    vim.api.nvim_buf_add_highlight(buf, -1, "Title", 0, 0, -1)

    local prefix_len = #prefix
    for i = 3, #lines do
        vim.api.nvim_buf_add_highlight(buf, -1, "Special", i - 1, 2, 2 + prefix_len + 1)
    end

    -- Close on any key
    local function close()
        vim.api.nvim_win_close(win, true)
    end
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
    vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
    vim.keymap.set("n", "<CR>", close, { buffer = buf, nowait = true })
end

-- Setup keymaps
function M.setup_keymaps()
    local prefix = config.keymap_prefix or "<leader>b"

    local mappings = {
        { "b", function() panel.toggle() end, "Toggle panel" },
        { "s", function()
            vim.ui.input({ prompt = "Banjo: " }, function(input)
                if input and input ~= "" then
                    M.send(input)
                end
            end)
        end, "Send prompt" },
        { "c", function() bridge.cancel() end, "Cancel request" },
        { "n", function() bridge.toggle_nudge() end, "Toggle nudge" },
        { "h", M.help, "Help" },
    }

    for _, m in ipairs(mappings) do
        vim.keymap.set("n", prefix .. m[1], m[2], { desc = "Banjo: " .. m[3] })
    end

    -- Visual mode mapping for send with selection
    vim.keymap.set("v", prefix .. "v", M.send_selection, { desc = "Banjo: Send with selection" })
end

return M
