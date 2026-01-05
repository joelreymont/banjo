-- Minimal init for testing
-- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

-- Add plugin to runtimepath
vim.opt.rtp:prepend(root)

-- Find plenary.nvim in common locations
local plenary_paths = {
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim",
  vim.fn.stdpath("data") .. "/site/pack/plugins/start/plenary.nvim",
  vim.fn.expand("~/.vim/plugged/plenary.nvim"),
}

for _, path in ipairs(plenary_paths) do
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.rtp:prepend(path)
    break
  end
end

-- Configure banjo for testing
vim.g.banjo_test_mode = true

-- Find the backend binary relative to plugin root
local backend_paths = {
  root .. "/../zig-out/bin/banjo",
}

for _, path in ipairs(backend_paths) do
  local expanded = vim.fn.fnamemodify(path, ":p")
  if vim.fn.executable(expanded) == 1 then
    vim.g.banjo_test_binary = expanded
    break
  end
end
