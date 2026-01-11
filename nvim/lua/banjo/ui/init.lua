-- UI components using nui.nvim
local M = {}

-- Check if nui.nvim is available
local has_nui, _ = pcall(require, "nui.popup")
M.has_nui = has_nui

if not has_nui then
    vim.notify("Banjo: nui.nvim not found, using fallback dialogs", vim.log.levels.WARN)
end

M.prompt = require("banjo.ui.prompt")

return M
