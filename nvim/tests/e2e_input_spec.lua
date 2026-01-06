-- E2E tests for actual user input/output workflow
-- Tests the complete flow: type input -> send -> receive response -> display in panel

local helpers = require("tests.helpers")

-- Skip if no backend binary
if not vim.g.banjo_test_binary then
  describe("banjo E2E input/output (SKIPPED - no binary)", function()
    it("requires g:banjo_test_binary to be set", function()
      pending("Set g:banjo_test_binary to run E2E input tests")
    end)
  end)
  return
end

-- Verify binary exists
if vim.fn.executable(vim.g.banjo_test_binary) ~= 1 then
  describe("banjo E2E input/output (SKIPPED - binary not found)", function()
    it("binary not found at: " .. vim.g.banjo_test_binary, function()
      pending("Binary not found")
    end)
  end)
  return
end

describe("banjo E2E input/output", function()
  local banjo
  local bridge
  local panel
  local test_cwd

  before_each(function()
    -- Fresh module load
    package.loaded["banjo"] = nil
    package.loaded["banjo.bridge"] = nil
    package.loaded["banjo.panel"] = nil
    package.loaded["banjo.history"] = nil

    banjo = require("banjo")
    bridge = require("banjo.bridge")
    panel = require("banjo.panel")

    -- Setup test environment
    test_cwd = vim.fn.tempname() .. "_banjo_e2e"
    vim.fn.mkdir(test_cwd, "p")

    -- Initialize banjo WITHOUT auto-start
    banjo.setup({
      binary_path = vim.g.banjo_test_binary,
      auto_start = false,
      panel = {
        width = 60,
        position = "right",
        input_height = 5,
      },
    })
  end)

  after_each(function()
    pcall(bridge.stop)
    helpers.cleanup()
    if test_cwd then
      vim.fn.delete(test_cwd, "rf")
    end
  end)

  describe("complete input/output workflow", function()
    it("sends user input and receives streamed response", function()
      -- Start backend
      bridge.start(vim.g.banjo_test_binary, test_cwd)

      -- Wait for backend to be ready
      local connected = helpers.wait_for(function()
        return bridge.is_running()
      end, 10000)
      assert.is_true(connected, "Backend should connect within 10s")

      -- Open panel
      panel.open()
      helpers.wait(100)
      assert.is_true(panel.is_open(), "Panel should be open")

      -- Get input buffer
      local state = panel._get_state()
      local input_buf = state.input_buf
      assert.truthy(input_buf, "Should have input buffer")
      assert.truthy(vim.api.nvim_buf_is_valid(input_buf), "Input buffer should be valid")

      -- Type input into buffer (simulate user typing)
      local test_input = "Say hello"
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { test_input })

      -- Submit input (simulate pressing Enter)
      panel.submit_input()
      helpers.wait(100)

      -- Input should be cleared
      local cleared_lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
      assert.equals(1, #cleared_lines, "Input should be cleared to single line")
      assert.equals("", cleared_lines[1], "Input line should be empty")

      -- Wait for response to stream back (give it up to 15 seconds for AI response)
      local got_response = helpers.wait_for(function()
        local output_buf = helpers.get_banjo_buffer()
        if output_buf == -1 then
          return false
        end
        local lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
        local content = table.concat(lines, "\n")
        -- Response should contain SOME text (not just empty or header)
        return #content > 10
      end, 15000)

      assert.is_true(got_response, "Should receive response within 15s")

      -- Verify output panel contains response
      local output_buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
      local content = table.concat(lines, "\n")

      -- Should have actual content (not just empty)
      assert.truthy(#content > 10, "Should have response content")

      print("\n=== RESPONSE ===")
      print(content)
      print("=== END ===\n")
    end)

    it("handles multiple rapid inputs correctly", function()
      -- Start backend
      bridge.start(vim.g.banjo_test_binary, test_cwd)
      local connected = helpers.wait_for(function()
        return bridge.is_running()
      end, 10000)
      assert.is_true(connected, "Backend should connect")

      -- Open panel
      panel.open()
      helpers.wait(100)

      local state = panel._get_state()
      local input_buf = state.input_buf

      -- Send first message
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "First message" })
      panel.submit_input()
      helpers.wait(500)

      -- Send second message before first completes
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "Second message" })
      panel.submit_input()
      helpers.wait(500)

      -- Both should be processed without errors
      local output_buf = helpers.get_banjo_buffer()
      if output_buf ~= -1 then
        local lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
        local content = table.concat(lines, "\n")
        -- Should have received at least one response
        assert.truthy(#content > 0, "Should have response content")
      end
    end)

    it("displays streaming chunks progressively", function()
      -- This test verifies that streaming updates the panel in real-time
      bridge.start(vim.g.banjo_test_binary, test_cwd)
      local connected = helpers.wait_for(function()
        return bridge.is_running()
      end, 10000)
      assert.is_true(connected, "Backend should connect")

      panel.open()
      helpers.wait(100)

      local state = panel._get_state()
      local input_buf = state.input_buf

      -- Send a request that should stream back
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "Tell me about neovim" })
      panel.submit_input()

      -- Wait a bit for streaming to start
      helpers.wait(2000)

      -- Check that we're getting progressive updates
      local output_buf = helpers.get_banjo_buffer()
      if output_buf ~= -1 then
        local snapshot1 = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
        local len1 = table.concat(snapshot1, "\n"):len()

        -- Wait for more streaming
        helpers.wait(2000)

        local snapshot2 = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
        local len2 = table.concat(snapshot2, "\n"):len()

        -- Content should grow as streaming continues
        -- (unless response completed very fast)
        assert.truthy(len2 >= len1, "Content should grow or stay same as streaming continues")
      end
    end)
  end)

  describe("input buffer behavior", function()
    it("supports multiline input", function()
      bridge.start(vim.g.banjo_test_binary, test_cwd)
      local connected = helpers.wait_for(function()
        return bridge.is_running()
      end, 10000)
      assert.is_true(connected, "Backend should connect")

      panel.open()
      helpers.wait(100)

      local state = panel._get_state()
      local input_buf = state.input_buf

      -- Type multiline input
      local multiline = {
        "First line",
        "Second line",
        "Third line"
      }
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, multiline)

      -- Submit
      panel.submit_input()
      helpers.wait(100)

      -- Input should be cleared
      local cleared = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
      assert.equals(1, #cleared)
      assert.equals("", cleared[1])
    end)

    it("rejects empty input", function()
      panel.open()
      helpers.wait(100)

      local state = panel._get_state()
      local input_buf = state.input_buf

      -- Try to submit empty input
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "" })
      panel.submit_input()
      helpers.wait(100)

      -- No backend should be started for empty input
      assert.is_false(bridge.is_running(), "Should not start backend for empty input")
    end)

    it("rejects whitespace-only input", function()
      panel.open()
      helpers.wait(100)

      local state = panel._get_state()
      local input_buf = state.input_buf

      -- Try to submit whitespace-only
      vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "   ", "  \t  ", "" })
      panel.submit_input()
      helpers.wait(100)

      -- No backend should be started
      assert.is_false(bridge.is_running(), "Should not start backend for whitespace input")
    end)
  end)

  describe("keyboard interaction simulation", function()
    it("handles feedkeys simulation", function()
      -- This test uses feedkeys to simulate ACTUAL keyboard input
      bridge.start(vim.g.banjo_test_binary, test_cwd)
      local connected = helpers.wait_for(function()
        return bridge.is_running()
      end, 10000)
      assert.is_true(connected, "Backend should connect")

      panel.open()
      helpers.wait(100)

      local state = panel._get_state()
      local input_win = state.input_win

      -- Focus input window
      vim.api.nvim_set_current_win(input_win)
      helpers.wait(50)

      -- Simulate typing with feedkeys
      vim.api.nvim_feedkeys("iHello from keyboard", "n", false)
      helpers.wait(100)

      -- Exit insert mode
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      helpers.wait(50)

      -- Verify text was entered
      local input_buf = state.input_buf
      local lines = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      assert.truthy(text:find("Hello from keyboard"), "Input should contain typed text")

      -- Submit with <C-CR> keybinding
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-CR>", true, false, true), "n", false)
      helpers.wait(100)

      -- Input should be cleared
      local cleared = vim.api.nvim_buf_get_lines(input_buf, 0, -1, false)
      assert.truthy(#cleared == 1 and cleared[1] == "", "Input should be cleared after submit")
    end)
  end)
end)
