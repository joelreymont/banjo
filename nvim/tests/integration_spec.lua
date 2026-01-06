-- Integration tests for Banjo Neovim plugin
-- Tests actual binary spawning and message flow
-- Run with backend: nvim --headless -c "let g:banjo_test_binary='/path/to/banjo'" -u tests/minimal_init.lua -c "luafile tests/run.lua"

local helpers = require("tests.helpers")

describe("banjo integration", function()
  local bridge
  local panel
  local test_cwd

  before_each(function()
    package.loaded["banjo.bridge"] = nil
    package.loaded["banjo.panel"] = nil
    bridge = require("banjo.bridge")
    panel = require("banjo.panel")
    panel.setup({ width = 60, position = "right" })
    test_cwd = vim.fn.tempname() .. "_banjo_test"
    vim.fn.mkdir(test_cwd, "p")
  end)

  after_each(function()
    bridge.stop()
    helpers.cleanup()
    if test_cwd then
      vim.fn.delete(test_cwd, "rf")
    end
  end)

  describe("backend spawn", function()
    -- Skip backend tests if no binary configured
    if not vim.g.banjo_test_binary then
      it("requires g:banjo_test_binary to be set", function()
        pending("Set g:banjo_test_binary to run backend spawn tests")
      end)
      return
    end

    -- Verify binary exists
    if vim.fn.executable(vim.g.banjo_test_binary) ~= 1 then
      it("binary not found at: " .. vim.g.banjo_test_binary, function()
        pending("Binary not found")
      end)
      return
    end
    it("starts binary and receives ready notification", function()
      local ready_received = false
      local mcp_port = nil

      -- Hook into _handle_message to capture ready
      local orig_handle = bridge._handle_message
      bridge._handle_message = function(msg)
        if msg.method == "ready" then
          ready_received = true
          if msg.params and msg.params.mcp_port then
            mcp_port = msg.params.mcp_port
          end
        end
        return orig_handle(msg)
      end

      bridge.start(vim.g.banjo_test_binary, test_cwd)

      -- Wait for ready notification (up to 10 seconds)
      local ok = helpers.wait_for(function()
        return ready_received
      end, 10000)

      bridge._handle_message = orig_handle

      assert.is_true(ok, "Should receive ready notification")
      assert.is_true(bridge.is_running(), "Bridge should be running")
      assert.is_not_nil(mcp_port, "Should receive MCP port")
      assert.truthy(mcp_port > 0, "MCP port should be positive")
    end)

    it("is_running returns true after start", function()
      bridge.start(vim.g.banjo_test_binary, test_cwd)

      helpers.wait_for(function()
        return bridge.is_running()
      end, 5000)

      assert.is_true(bridge.is_running())
    end)

    it("is_running returns false after stop", function()
      bridge.start(vim.g.banjo_test_binary, test_cwd)

      helpers.wait_for(function()
        return bridge.is_running()
      end, 5000)

      bridge.stop()
      helpers.wait(100)

      assert.is_false(bridge.is_running())
    end)

    it("get_mcp_port returns port after ready", function()
      bridge.start(vim.g.banjo_test_binary, test_cwd)

      local ok = helpers.wait_for(function()
        return bridge.get_mcp_port() ~= nil
      end, 10000)

      assert.is_true(ok, "Should have MCP port")
      local port = bridge.get_mcp_port()
      assert.truthy(port > 0, "Port should be positive")
    end)
  end)

  describe("message handling", function()
    it("stream_start opens panel", function()
      -- Initialize bridge state for current tab
      bridge.get_state()

      -- Simulate message from backend
      bridge._handle_message({
        method = "stream_start",
        params = { engine = "claude" },
      })

      helpers.wait(100)
      assert.is_true(panel.is_open(), "Panel should open on stream_start")
    end)

    it("stream_chunk appends to panel", function()
      bridge.get_state()
      panel.open()
      panel.clear()

      bridge._handle_message({
        method = "stream_chunk",
        params = { text = "Hello from Claude", is_thought = false },
      })

      helpers.wait(100)

      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content = table.concat(lines, "\n")

      assert.truthy(content:find("Hello from Claude"), "Panel should show streamed text")
    end)

    it("stream_end adds separator", function()
      bridge.get_state()
      panel.open()
      panel.start_stream("claude")
      panel.append("Response text")

      bridge._handle_message({
        method = "stream_end",
        params = {},
      })

      helpers.wait(100)

      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local line_count = #lines

      assert.truthy(line_count >= 2, "Should have at least 2 lines after end_stream")
      assert.equals("", lines[line_count], "Last line should be blank after end_stream")
    end)

    it("tool_call shows in panel", function()
      bridge.get_state()
      panel.open()
      panel.clear()

      bridge._handle_message({
        method = "tool_call",
        params = { name = "Read", label = "src/main.zig" },
      })

      helpers.wait(100)

      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content = table.concat(lines, "\n")

      assert.truthy(content:find("Read"), "Panel should show tool name")
      assert.truthy(content:find("main.zig"), "Panel should show tool label")
    end)

    it("error_msg shows notification", function()
      bridge.get_state()
      local notified = false
      local notify_msg = nil
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        notified = true
        notify_msg = msg
      end

      bridge._handle_message({
        method = "error_msg",
        params = { message = "Test error message" },
      })

      vim.notify = orig_notify

      assert.is_true(notified, "Should show notification")
      assert.truthy(notify_msg:find("Test error message"), "Should contain error message")
    end)

    it("status shows notification", function()
      bridge.get_state()
      local notified = false
      local notify_msg = nil
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        notified = true
        notify_msg = msg
      end

      bridge._handle_message({
        method = "status",
        params = { text = "Processing..." },
      })

      vim.notify = orig_notify

      assert.is_true(notified, "Should show notification")
      assert.truthy(notify_msg:find("Processing"), "Should contain status text")
    end)
  end)

  describe("tool requests", function()
    it("responds to getCurrentSelection", function()
      bridge.get_state()
      local response_sent = false
      local response_result = nil
      local orig_send = bridge._send_tool_response
      bridge._send_tool_response = function(correlation_id, result, err)
        response_sent = true
        response_result = result
        -- Don't call orig_send - no job running in test
      end

      bridge._handle_message({
        method = "tool_request",
        params = {
          tool = "getCurrentSelection",
          arguments = {},
          correlation_id = "test-123",
        },
      })

      bridge._send_tool_response = orig_send
      assert.is_true(response_sent, "Should respond to tool request")
      assert.is_not_nil(response_result, "Should have result")
      assert.is_not_nil(response_result.text, "Should have text field")
      assert.is_not_nil(response_result.file, "Should have file field")
    end)

    it("responds to getOpenEditors", function()
      bridge.get_state()
      local response_sent = false
      local result_editors = nil
      local orig_send = bridge._send_tool_response
      bridge._send_tool_response = function(correlation_id, result, err)
        response_sent = true
        result_editors = result
        -- Don't call orig_send - no job running in test
      end

      bridge._handle_message({
        method = "tool_request",
        params = {
          tool = "getOpenEditors",
          arguments = {},
          correlation_id = "test-456",
        },
      })

      bridge._send_tool_response = orig_send
      assert.is_true(response_sent, "Should respond to tool request")
      assert.is_table(result_editors, "Should return table of editors")
    end)

    it("responds to getDiagnostics", function()
      bridge.get_state()
      local response_sent = false
      local result_diags = nil
      local orig_send = bridge._send_tool_response
      bridge._send_tool_response = function(correlation_id, result, err)
        response_sent = true
        result_diags = result
        -- Don't call orig_send - no job running in test
      end

      bridge._handle_message({
        method = "tool_request",
        params = {
          tool = "getDiagnostics",
          arguments = {},
          correlation_id = "test-789",
        },
      })

      bridge._send_tool_response = orig_send
      assert.is_true(response_sent, "Should respond to tool request")
      assert.is_table(result_diags, "Should return table of diagnostics")
    end)

    it("responds with error for unknown tool", function()
      bridge.get_state()
      local response_sent = false
      local response_err = nil
      local orig_send = bridge._send_tool_response
      bridge._send_tool_response = function(correlation_id, result, err)
        response_sent = true
        response_err = err
        -- Don't call orig_send - no job running in test
      end

      bridge._handle_message({
        method = "tool_request",
        params = {
          tool = "unknownTool",
          arguments = {},
          correlation_id = "test-error",
        },
      })

      bridge._send_tool_response = orig_send
      assert.is_true(response_sent, "Should respond to tool request")
      assert.is_not_nil(response_err, "Should have error for unknown tool")
      assert.truthy(response_err:find("Unknown tool"), "Error should mention unknown tool")
    end)
  end)

  describe("full message flow", function()
    it("complete stream cycle updates panel correctly", function()
      bridge.get_state()
      -- Simulate a complete response cycle
      bridge._handle_message({
        method = "stream_start",
        params = { engine = "claude" },
      })
      helpers.wait(50)

      bridge._handle_message({
        method = "stream_chunk",
        params = { text = "Here is ", is_thought = false },
      })
      helpers.wait(50)

      bridge._handle_message({
        method = "stream_chunk",
        params = { text = "the response.", is_thought = false },
      })
      helpers.wait(50)

      bridge._handle_message({
        method = "tool_call",
        params = { name = "Write", label = "test.txt" },
      })
      helpers.wait(50)

      bridge._handle_message({
        method = "tool_result",
        params = { id = "tool-1", status = "completed" },
      })
      helpers.wait(50)

      bridge._handle_message({
        method = "stream_end",
        params = {},
      })
      helpers.wait(100)

      -- Verify panel state
      assert.is_true(panel.is_open(), "Panel should be open")

      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content = table.concat(lines, "\n")


      -- Verify content from stream
      assert.truthy(content:find("Here is"), "Should have response text (part 1)")
      assert.truthy(content:find("the response"), "Should have response text (part 2)")
      assert.truthy(content:find("Write"), "Should have tool call")
      assert.truthy(content:find("test%.txt"), "Should have tool label")
    end)
  end)

describe("banjo panel integration", function()
  -- These tests verify panel behavior with simulated backend messages
  -- They don't require the actual binary

  local panel

  before_each(function()
    package.loaded["banjo.panel"] = nil
    panel = require("banjo.panel")
    panel.setup({ width = 60, position = "right" })
  end)

  after_each(function()
    helpers.cleanup()
  end)

  describe("streaming display", function()
    it("shows thoughts in italics", function()
      panel.start_stream("claude")
      panel.append("Let me think...", true) -- is_thought = true
      helpers.wait(50)

      local buf = helpers.get_banjo_buffer()
      assert.truthy(buf > 0, "Panel buffer should exist")

      -- Check that highlight was applied (Comment group for thoughts)
      local ns_id = vim.api.nvim_create_namespace("banjo")
      local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns_id, 0, -1, { details = true })

      -- Should have some highlights
      local has_highlight = #extmarks > 0
      assert.is_true(has_highlight, "Thoughts should have highlight")
    end)

    it("scrolls to bottom on new content", function()
      panel.start_stream("claude")

      -- Add many lines
      for i = 1, 50 do
        panel.append("Line " .. i .. "\n", false)
      end
      helpers.wait(100)

      -- Get panel window
      local wins = vim.api.nvim_list_wins()
      local panel_win = nil
      for _, w in ipairs(wins) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.api.nvim_buf_get_name(b):find("Banjo") then
          panel_win = w
          break
        end
      end

      if panel_win then
        local cursor = vim.api.nvim_win_get_cursor(panel_win)
        local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(panel_win))
        -- Cursor should be near the bottom
        assert.truthy(cursor[1] >= line_count - 5, "Should scroll to bottom")
      end
    end)

    it("handles rapid streaming without errors", function()
      panel.start_stream("codex")

      -- Rapid fire many chunks
      for i = 1, 100 do
        panel.append("chunk" .. i, false)
      end

      helpers.wait(100)

      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content = table.concat(lines, "")

      -- Should have all chunks
      assert.truthy(content:find("chunk1"), "Should have first chunk")
      assert.truthy(content:find("chunk100"), "Should have last chunk")
    end)
  end)

  describe("position options", function()
    it("opens on right with position=right", function()
      panel.setup({ position = "right", width = 60 })
      panel.open()
      helpers.wait(50)

      -- The panel window should be on the right
      -- We can check by comparing column positions
      local wins = vim.api.nvim_list_wins()
      if #wins >= 2 then
        local positions = {}
        for _, w in ipairs(wins) do
          local pos = vim.api.nvim_win_get_position(w)
          positions[w] = pos[2] -- column position
        end

        local panel_win = nil
        for _, w in ipairs(wins) do
          local b = vim.api.nvim_win_get_buf(w)
          if vim.api.nvim_buf_get_name(b):find("Banjo") then
            panel_win = w
            break
          end
        end

        if panel_win then
          local panel_col = positions[panel_win]
          local other_cols = {}
          for w, col in pairs(positions) do
            if w ~= panel_win then
              table.insert(other_cols, col)
            end
          end
          -- Panel should be to the right of other windows
          for _, col in ipairs(other_cols) do
            assert.truthy(panel_col >= col, "Panel should be on right")
          end
        end
      end
    end)

    it("opens on left with position=left", function()
      panel.setup({ position = "left", width = 60 })
      panel.open()
      helpers.wait(50)

      local wins = vim.api.nvim_list_wins()
      if #wins >= 2 then
        local panel_win = nil
        for _, w in ipairs(wins) do
          local b = vim.api.nvim_win_get_buf(w)
          if vim.api.nvim_buf_get_name(b):find("Banjo") then
            panel_win = w
            break
          end
        end

        if panel_win then
          local panel_pos = vim.api.nvim_win_get_position(panel_win)
          -- Panel should be at column 0 (leftmost)
          assert.equals(0, panel_pos[2], "Panel should be on left")
        end
      end
    end)
  end)
end)
