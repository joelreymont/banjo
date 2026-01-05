-- Minimal init for testing banjo.nvim
-- Usage: nvim --headless -u tests/minimal_init.lua -c "luafile tests/run.lua"

-- Add plugin to runtimepath
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

-- Find plenary (required for test framework)
local plenary_paths = {
    vim.fn.expand("~/.local/share/nvim/site/pack/*/start/plenary.nvim"),
    vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
    vim.fn.expand("~/.config/nvim/pack/*/start/plenary.nvim"),
}

for _, pattern in ipairs(plenary_paths) do
    local matches = vim.fn.glob(pattern, false, true)
    for _, path in ipairs(matches) do
        if vim.fn.isdirectory(path) == 1 then
            vim.opt.rtp:prepend(path)
            break
        end
    end
end

-- Find banjo binary
local binary_paths = {
    plugin_root .. "/../../zig-out/bin/banjo",
    plugin_root .. "/../zig-out/bin/banjo",
    "./zig-out/bin/banjo",
    vim.fn.expand("~/.local/bin/banjo"),
}

for _, path in ipairs(binary_paths) do
    if vim.fn.executable(path) == 1 then
        vim.g.banjo_test_binary = vim.fn.fnamemodify(path, ":p")
        break
    end
end

-- Minimal settings for testing
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false
vim.o.hidden = true

-- Don't auto-start banjo during tests
vim.g.banjo_test_mode = true
