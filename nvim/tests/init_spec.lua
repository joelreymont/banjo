-- Unit tests for Banjo init module
local helpers = require("tests.helpers")

describe("banjo init", function()
  local banjo

  before_each(function()
    -- Clear any cached modules
    package.loaded["banjo"] = nil
    package.loaded["banjo.panel"] = nil
    package.loaded["banjo.bridge"] = nil
    banjo = require("banjo")
  end)

  after_each(function()
    helpers.cleanup()
    -- Clear keymaps we may have set
    pcall(vim.keymap.del, "n", "<leader>ab")
    pcall(vim.keymap.del, "n", "<leader>as")
    pcall(vim.keymap.del, "n", "<leader>ac")
    pcall(vim.keymap.del, "n", "<leader>an")
    pcall(vim.keymap.del, "n", "<leader>ah")
    pcall(vim.keymap.del, "v", "<leader>av")
    -- Clear user commands
    pcall(vim.api.nvim_del_user_command, "BanjoToggle")
    pcall(vim.api.nvim_del_user_command, "BanjoStart")
    pcall(vim.api.nvim_del_user_command, "BanjoStop")
    pcall(vim.api.nvim_del_user_command, "BanjoClear")
    pcall(vim.api.nvim_del_user_command, "BanjoSend")
    pcall(vim.api.nvim_del_user_command, "BanjoCancel")
    pcall(vim.api.nvim_del_user_command, "BanjoNudge")
    pcall(vim.api.nvim_del_user_command, "BanjoHelp")
  end)

  describe("setup", function()
    it("accepts empty options", function()
      -- Should not error with binary_path warning in test mode
      banjo.setup({ binary_path = "/bin/true", auto_start = false, keymaps = false })
    end)

    it("creates user commands", function()
      banjo.setup({ binary_path = "/bin/true", auto_start = false, keymaps = false })

      -- Check commands exist
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.BanjoToggle)
      assert.is_not_nil(commands.BanjoStart)
      assert.is_not_nil(commands.BanjoStop)
      assert.is_not_nil(commands.BanjoClear)
      assert.is_not_nil(commands.BanjoSend)
      assert.is_not_nil(commands.BanjoCancel)
      assert.is_not_nil(commands.BanjoNudge)
      assert.is_not_nil(commands.BanjoHelp)
    end)

    it("creates keymaps when enabled", function()
      banjo.setup({
        binary_path = "/bin/true",
        auto_start = false,
        keymaps = true,
        keymap_prefix = "<leader>a",
      })

      -- Check keymaps exist
      local maps = vim.api.nvim_get_keymap("n")
      local found_toggle = false
      local found_help = false
      for _, map in ipairs(maps) do
        if map.lhs:match("b$") and map.desc and map.desc:match("Toggle") then
          found_toggle = true
        end
        if map.lhs:match("h$") and map.desc and map.desc:match("Help") then
          found_help = true
        end
      end
      assert.is_true(found_toggle, "Should have toggle keymap")
      assert.is_true(found_help, "Should have help keymap")
    end)

    it("skips keymaps when disabled", function()
      banjo.setup({
        binary_path = "/bin/true",
        auto_start = false,
        keymaps = false,
      })

      local maps = vim.api.nvim_get_keymap("n")
      local found_banjo = false
      for _, map in ipairs(maps) do
        if map.desc and map.desc:match("Banjo") then
          found_banjo = true
        end
      end
      assert.is_false(found_banjo, "Should not have Banjo keymaps")
    end)
  end)

  describe("help", function()
    it("opens floating window", function()
      banjo.setup({
        binary_path = "/bin/true",
        auto_start = false,
        keymaps = false,
        keymap_prefix = "<leader>a",
      })

      local win_count_before = #vim.api.nvim_list_wins()
      banjo.help()
      helpers.wait(50)
      local win_count_after = #vim.api.nvim_list_wins()

      assert.equals(win_count_before + 1, win_count_after, "Should open one new window")
    end)

    it("shows keybindings", function()
      banjo.setup({
        binary_path = "/bin/true",
        auto_start = false,
        keymaps = false,
        keymap_prefix = "<leader>a",
      })

      banjo.help()
      helpers.wait(50)

      -- Get the floating window's buffer content
      local wins = vim.api.nvim_list_wins()
      local help_win = wins[#wins] -- Last opened window
      local buf = vim.api.nvim_win_get_buf(help_win)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content = table.concat(lines, "\n")

      assert.truthy(content:find("Toggle panel"), "Should show toggle binding")
      assert.truthy(content:find("Send prompt"), "Should show send binding")
      assert.truthy(content:find("Cancel"), "Should show cancel binding")
    end)

    it("closes on escape", function()
      banjo.setup({
        binary_path = "/bin/true",
        auto_start = false,
        keymaps = false,
      })

      banjo.help()
      helpers.wait(50)

      local win_count_with_help = #vim.api.nvim_list_wins()

      -- Simulate pressing Escape
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", true)
      helpers.wait(50)

      local win_count_after = #vim.api.nvim_list_wins()
      assert.equals(win_count_with_help - 1, win_count_after, "Help should close on Escape")
    end)
  end)

  describe("is_running", function()
    it("returns false when not started", function()
      banjo.setup({
        binary_path = "/bin/true",
        auto_start = false,
        keymaps = false,
      })

      assert.is_false(banjo.is_running())
    end)
  end)
end)
