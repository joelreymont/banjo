-- Unit tests for Banjo bridge module
local helpers = require("tests.helpers")

describe("banjo bridge", function()
  local bridge

  before_each(function()
    package.loaded["banjo.bridge"] = nil
    bridge = require("banjo.bridge")
  end)

  after_each(function()
    helpers.cleanup()
  end)

  describe("state", function()
    it("is_running returns false initially", function()
      assert.is_false(bridge.is_running())
    end)

    it("get_mcp_port returns nil initially", function()
      assert.is_nil(bridge.get_mcp_port())
    end)
  end)

  describe("message handling", function()
    it("handles invalid JSON gracefully", function()
      -- Should not error
      local tabid = vim.api.nvim_get_current_tabpage()
      bridge._on_stdout({ "not valid json" }, tabid)
    end)

    it("handles empty data", function()
      local tabid = vim.api.nvim_get_current_tabpage()
      bridge._on_stdout({ "" }, tabid)
    end)

    it("handles partial JSON lines", function()
      local tabid = vim.api.nvim_get_current_tabpage()
      -- First chunk
      bridge._on_stdout({ '{"method":' }, tabid)
      -- Second chunk completes the line
      bridge._on_stdout({ '"test"}\n' }, tabid)
      -- Should have processed without error
    end)
  end)

  describe("selection capture", function()
    it("returns empty selection when not in visual mode", function()
      local result = bridge._get_current_selection()
      assert.is_not_nil(result)
      assert.equals("", result.text)
    end)
  end)

  describe("editor helpers", function()
    it("get open editors returns table", function()
      local editors = bridge._get_open_editors()
      assert.is_table(editors)
    end)

    it("check dirty returns isDirty field", function()
      local result = bridge._check_dirty("/nonexistent/file.txt")
      assert.is_table(result)
      assert.is_false(result.isDirty)
    end)

    it("get diagnostics returns table", function()
      local result = bridge._get_diagnostics()
      assert.is_table(result)
    end)
  end)
end)
