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
    keymaps = {
        toggle = "<leader>bb",
        send = "<leader>bs",
        send_selection = "<leader>bv",
        cancel = "<leader>bc",
        nudge = "<leader>bn",
    },
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

    -- Setup keymaps
    if config.keymaps then
        if config.keymaps.toggle then
            vim.keymap.set("n", config.keymaps.toggle, function()
                panel.toggle()
            end, { desc = "Toggle Banjo panel" })
        end

        if config.keymaps.send then
            vim.keymap.set("n", config.keymaps.send, function()
                vim.ui.input({ prompt = "Banjo: " }, function(input)
                    if input and input ~= "" then
                        M.send(input)
                    end
                end)
            end, { desc = "Send prompt to Banjo" })
        end

        if config.keymaps.send_selection then
            vim.keymap.set("v", config.keymaps.send_selection, function()
                M.send_selection()
            end, { desc = "Send selection to Banjo" })
        end

        if config.keymaps.cancel then
            vim.keymap.set("n", config.keymaps.cancel, function()
                bridge.cancel()
            end, { desc = "Cancel Banjo request" })
        end

        if config.keymaps.nudge then
            vim.keymap.set("n", config.keymaps.nudge, function()
                bridge.toggle_nudge()
            end, { desc = "Toggle Banjo nudge" })
        end
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

function M.send_selection()
    local mode = vim.fn.mode()
    if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
        vim.notify("Banjo: Not in visual mode", vim.log.levels.WARN)
        return
    end

    -- Exit visual mode to update marks
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

        vim.ui.input({ prompt = "Banjo (with selection): " }, function(input)
            if input and input ~= "" then
                local prompt = input .. "\n\n```\n" .. text .. "\n```"
                local files = { { path = file_path, content = text } }
                bridge.send_prompt(prompt, files)
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

return M
