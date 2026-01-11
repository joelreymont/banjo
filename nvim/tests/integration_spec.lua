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
      bridge.start(vim.g.banjo_test_binary, test_cwd)

      -- Wait for backend to be running and MCP port to be set (ready notification received)
      local ok = helpers.wait_for(function()
        return bridge.is_running() and bridge.get_mcp_port() ~= nil
      end, 15000)

      assert.is_true(ok, "Backend should start and send ready notification")
      assert.is_true(bridge.is_running(), "Bridge should be running")

      local mcp_port = bridge.get_mcp_port()
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

  describe("state synchronization", function()
    it("state message updates bridge state", function()
      bridge.get_state()

      -- Simulate state message from backend (sent on nvim connect)
      bridge._handle_message({
        method = "state",
        params = {
          engine = "claude",
          model = "opus",
          mode = "auto_approve",
          connected = true,
        },
      })

      helpers.wait(50)

      local state = bridge.get_state()
      assert.equals("claude", state.engine, "Engine should be updated")
      assert.equals("opus", state.model, "Model should be updated")
      assert.equals("auto_approve", state.mode, "Mode should be updated")
    end)

    it("state message updates panel status line", function()
      bridge.get_state()
      panel.open()

      bridge._handle_message({
        method = "state",
        params = {
          engine = "codex",
          model = "o3",
          mode = "default",
          connected = true,
        },
      })

      helpers.wait(50)

      -- Verify status was updated (panel._build_status uses bridge.get_state)
      local state = bridge.get_state()
      assert.equals("codex", state.engine)
      assert.equals("default", state.mode)
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

end)
describe("banjo permission dialog", function()
  -- Tests for the nui.nvim permission/approval dialogs
  local ui_prompt

  before_each(function()
    package.loaded["banjo.ui.prompt"] = nil
    ui_prompt = require("banjo.ui.prompt")
  end)

  after_each(function()
    -- Close any open popup windows
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local bufname = vim.api.nvim_buf_get_name(buf)
        -- nui popups have empty or special names
        if vim.bo[buf].buftype == "nofile" and not bufname:match("Banjo") then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
    helpers.cleanup()
  end)

  describe("permission prompt", function()
    it("creates popup with tool name and risk", function()
      local action_received = nil
      local popup = ui_prompt.permission({
        tool_name = "Bash",
        tool_input = "rm -rf /tmp/test",
        on_action = function(action)
          action_received = action
        end,
      })

      helpers.wait(50)

      -- Should have created a popup window
      assert.is_not_nil(popup, "Should create popup")
      assert.is_not_nil(popup.bufnr, "Popup should have buffer")
      assert.is_true(vim.api.nvim_buf_is_valid(popup.bufnr), "Buffer should be valid")

      -- Check content
      local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
      local content = table.concat(lines, "\n")

      assert.truthy(content:find("Bash"), "Should show tool name")
      assert.truthy(content:find("high"), "Bash should have high risk")

      -- Clean up
      popup:unmount()
    end)

    it("responds to y key with allow", function()
      local action_received = nil
      local popup = ui_prompt.permission({
        tool_name = "Read",
        tool_input = "/tmp/test.txt",
        on_action = function(action)
          action_received = action
        end,
      })

      helpers.wait(50)

      -- Simulate pressing 'y'
      vim.api.nvim_buf_call(popup.bufnr, function()
        vim.api.nvim_feedkeys("y", "x", false)
      end)

      helpers.wait(50)
      assert.equals("allow", action_received, "y should trigger allow")
    end)

    it("responds to a key with allow_always", function()
      local action_received = nil
      local popup = ui_prompt.permission({
        tool_name = "Glob",
        tool_input = "**/*.lua",
        on_action = function(action)
          action_received = action
        end,
      })

      helpers.wait(50)

      vim.api.nvim_buf_call(popup.bufnr, function()
        vim.api.nvim_feedkeys("a", "x", false)
      end)

      helpers.wait(50)
      assert.equals("allow_always", action_received, "a should trigger allow_always")
    end)

    it("responds to n key with deny", function()
      local action_received = nil
      local popup = ui_prompt.permission({
        tool_name = "Write",
        tool_input = "/etc/passwd",
        on_action = function(action)
          action_received = action
        end,
      })

      helpers.wait(50)

      vim.api.nvim_buf_call(popup.bufnr, function()
        vim.api.nvim_feedkeys("n", "x", false)
      end)

      helpers.wait(50)
      assert.equals("deny", action_received, "n should trigger deny")
    end)

    it("responds to Escape with deny (default)", function()
      local action_received = nil
      local popup = ui_prompt.permission({
        tool_name = "Edit",
        tool_input = "some file",
        on_action = function(action)
          action_received = action
        end,
      })

      helpers.wait(50)

      vim.api.nvim_buf_call(popup.bufnr, function()
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      end)

      helpers.wait(50)
      assert.equals("deny", action_received, "Escape should trigger deny")
    end)

    it("determines risk level based on tool", function()
      -- High risk tools
      for _, tool in ipairs({ "Bash", "Write", "Edit" }) do
        local popup = ui_prompt.permission({
          tool_name = tool,
          tool_input = "test",
          on_action = function() end,
        })
        helpers.wait(20)
        local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
        local content = table.concat(lines, "\n")
        assert.truthy(content:find("high"), tool .. " should have high risk")
        popup:unmount()
      end

      -- Low risk tools
      for _, tool in ipairs({ "Read", "Glob", "Grep" }) do
        local popup = ui_prompt.permission({
          tool_name = tool,
          tool_input = "test",
          on_action = function() end,
        })
        helpers.wait(20)
        local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
        local content = table.concat(lines, "\n")
        assert.truthy(content:find("low"), tool .. " should have low risk")
        popup:unmount()
      end
    end)
  end)

  describe("approval prompt", function()
    it("creates popup for approval", function()
      local popup = ui_prompt.approval({
        tool_name = "execute_code",
        risk_level = "high",
        arguments = "python -c 'print(1)'",
        on_action = function() end,
      })

      helpers.wait(50)

      local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
      local content = table.concat(lines, "\n")

      assert.truthy(content:find("execute_code"), "Should show tool name")
      -- Title is in window border, not buffer content - check tool name is enough

      popup:unmount()
    end)

    it("responds to y with accept", function()
      local action_received = nil
      local popup = ui_prompt.approval({
        tool_name = "run_command",
        on_action = function(action)
          action_received = action
        end,
      })

      helpers.wait(50)

      vim.api.nvim_buf_call(popup.bufnr, function()
        vim.api.nvim_feedkeys("y", "x", false)
      end)

      helpers.wait(50)
      assert.equals("accept", action_received)
    end)

    it("responds to d with decline", function()
      local action_received = nil
      local popup = ui_prompt.approval({
        tool_name = "dangerous_op",
        on_action = function(action)
          action_received = action
        end,
      })

      helpers.wait(50)

      vim.api.nvim_buf_call(popup.bufnr, function()
        vim.api.nvim_feedkeys("d", "x", false)
      end)

      helpers.wait(50)
      assert.equals("decline", action_received)
    end)

    it("responds to a with acceptForSession", function()
      local action_received = nil
      local popup = ui_prompt.approval({
        tool_name = "run_command",
        on_action = function(action)
          action_received = action
        end,
      })

      helpers.wait(50)

      vim.api.nvim_buf_call(popup.bufnr, function()
        vim.api.nvim_feedkeys("a", "x", false)
      end)

      helpers.wait(50)
      assert.equals("acceptForSession", action_received)
    end)

    it("responds to c with cancel", function()
      local action_received = nil
      local popup = ui_prompt.approval({
        tool_name = "dangerous_op",
        on_action = function(action)
          action_received = action
        end,
      })

      helpers.wait(50)

      vim.api.nvim_buf_call(popup.bufnr, function()
        vim.api.nvim_feedkeys("c", "x", false)
      end)

      helpers.wait(50)
      assert.equals("cancel", action_received)
    end)
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
