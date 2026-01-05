-- Banjo plugin loader
-- This file is automatically loaded by lazy.nvim

if vim.g.loaded_banjo then
    return
end
vim.g.loaded_banjo = true

-- Lazy-load on first command
vim.api.nvim_create_user_command("Banjo", function(args)
    require("banjo").setup()
    if args.args ~= "" then
        require("banjo").send(args.args)
    end
end, { nargs = "?", desc = "Start Banjo with optional prompt" })
