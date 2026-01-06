-- Unit tests for Banjo panel
local helpers = require("tests.helpers")

describe("banjo panel", function()
  local panel

  before_each(function()
    panel = require("banjo.panel")
    panel.setup({ width = 60, position = "right" })
  end)

  after_each(function()
    helpers.cleanup()
  end)

  describe("toggle", function()
    it("opens panel when closed", function()
      local initial_wins = helpers.count_windows()
      assert.equals(1, initial_wins)

      panel.toggle()
      helpers.wait(50)

      assert.equals(3, helpers.count_windows()) -- +2 windows (output + input)
      assert.is_true(panel.is_open())
    end)

    it("closes panel when open", function()
      panel.toggle() -- open
      helpers.wait(50)
      assert.equals(3, helpers.count_windows())

      panel.toggle() -- close
      helpers.wait(50)

      assert.equals(1, helpers.count_windows())
      assert.is_false(panel.is_open())
    end)
  end)

  describe("open/close", function()
    it("open creates window", function()
      panel.open()
      helpers.wait(50)

      assert.is_true(panel.is_open())
      assert.equals(3, helpers.count_windows()) -- +2 windows (output + input)
    end)

    it("close removes window", function()
      panel.open()
      helpers.wait(50)
      panel.close()
      helpers.wait(50)

      assert.is_false(panel.is_open())
      assert.equals(1, helpers.count_windows())
    end)

    it("multiple opens only create one window", function()
      panel.open()
      panel.open()
      panel.open()
      helpers.wait(50)

      assert.equals(3, helpers.count_windows()) -- +2 windows (output + input)
    end)
  end)

  describe("append", function()
    it("adds text to buffer", function()
      panel.open()
      helpers.wait(50)

      panel.append("Hello World")

      -- Get buffer content
      local buf = vim.fn.bufnr("Banjo")
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content = table.concat(lines, "\n")

      assert.truthy(content:find("Hello World"))
    end)

    it("handles multiline text", function()
      panel.open()
      helpers.wait(50)

      panel.append("Line 1\nLine 2\nLine 3")

      local buf = vim.fn.bufnr("Banjo")
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      assert.truthy(#lines >= 3)
    end)
  end)

  describe("clear", function()
    it("removes all content", function()
      panel.open()
      panel.append("Some text")
      helpers.wait(50)

      panel.clear()

      local buf = vim.fn.bufnr("Banjo")
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content = table.concat(lines, "")

      assert.equals("", content)
    end)
  end)

  describe("stream", function()
    it("start_stream opens panel with header", function()
      panel.start_stream("claude")
      helpers.wait(50)

      assert.is_true(panel.is_open(), "Panel should be open after start_stream")

      local buf = vim.fn.bufnr("Banjo")
      assert.truthy(buf > 0, "Panel buffer should exist")
    end)

    it("end_stream adds blank line", function()
      panel.start_stream("codex")
      panel.append("Response text")

      local buf = vim.fn.bufnr("Banjo")
      local lines_before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local count_before = #lines_before

      panel.end_stream()
      helpers.wait(50)

      local lines_after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      -- end_stream should add a blank line
      assert.truthy(#lines_after > count_before, "Should add blank line after end_stream")
    end)
  end)
end)
