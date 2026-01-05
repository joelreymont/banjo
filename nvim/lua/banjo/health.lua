-- Banjo health check: :checkhealth banjo
local M = {}

local function check_binary()
    local bridge = require("banjo.bridge")
    local banjo = require("banjo")

    if banjo.is_running() then
        vim.health.ok("Banjo binary is running")
        local port = banjo.get_mcp_port()
        if port then
            vim.health.ok("MCP server listening on port " .. port)
        end
    else
        -- Check if binary exists
        local locations = {
            vim.fn.expand("~/.local/bin/banjo"),
            "/usr/local/bin/banjo",
            "./zig-out/bin/banjo",
        }

        local found = false
        for _, path in ipairs(locations) do
            if vim.fn.executable(path) == 1 then
                vim.health.ok("Found banjo binary at: " .. path)
                found = true
                break
            end
        end

        if not found then
            local handle = io.popen("which banjo 2>/dev/null")
            if handle then
                local result = handle:read("*a"):gsub("%s+$", "")
                handle:close()
                if result ~= "" then
                    vim.health.ok("Found banjo in PATH: " .. result)
                    found = true
                end
            end
        end

        if not found then
            vim.health.error("Banjo binary not found", {
                "Build with: zig build",
                "Or install to: ~/.local/bin/banjo",
            })
        end
    end
end

local function check_claude_cli()
    local handle = io.popen("which claude 2>/dev/null")
    if handle then
        local result = handle:read("*a"):gsub("%s+$", "")
        handle:close()
        if result ~= "" then
            vim.health.ok("Found Claude CLI: " .. result)
            return
        end
    end

    vim.health.warn("Claude CLI not found in PATH", {
        "Install from: https://github.com/anthropics/claude-code",
        "This is optional but required for full functionality",
    })
end

local function check_dependencies()
    -- Check for optional dependencies
    local has_snacks = pcall(require, "snacks")
    if has_snacks then
        vim.health.ok("snacks.nvim is available")
    else
        vim.health.info("snacks.nvim not found (optional, for enhanced UI)")
    end
end

function M.check()
    vim.health.start("Banjo")

    check_binary()
    check_claude_cli()
    check_dependencies()
end

return M
