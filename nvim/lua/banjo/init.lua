-- Banjo: Claude Code + Codex integration for Neovim
local M = {}

local bridge = require("banjo.bridge")
local panel = require("banjo.panel")

local default_config = {
    binary_path = nil, -- Will be auto-detected
    auto_start = true,
    panel = {
        width = 80,
        position = "right",
    },
    keymap_prefix = "<leader>b",
    keymaps = true,
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

    bridge.start(config.binary_path, vim.fn.getcwd())
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

function M.is_running()
    return bridge.is_running()
end

function M.get_mcp_port()
    return bridge.get_mcp_port()
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
end

return M
