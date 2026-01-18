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

  describe("layout", function()
    it("defines section order and scroll rules", function()
      local sections = require("banjo.ui.sections")
      local order = sections.order()
      assert.same({ "header", "actions", "history", "input" }, order)

      local defs = sections.defs()
      assert.equals("fixed", defs.header.scroll)
      assert.equals("scroll", defs.history.scroll)
      assert.equals("fixed", defs.input.scroll)
      assert.equals("fixed", defs.actions.scroll)
    end)

    it("computes ranges from total and fixed counts", function()
      local sections = require("banjo.ui.sections")
      local ranges, counts = sections.compute_ranges(10, { header = 2, actions = 1, input = 0 })
      assert.equals(2, ranges.header.stop)
      assert.equals(3, ranges.history.start)
      assert.equals(10, ranges.history.stop)
      assert.equals(7, counts.history)
      assert.equals(2, ranges.actions.start)
      assert.equals(3, ranges.actions.stop)
    end)

    it("keeps history above input padding", function()
      panel.open()
      helpers.wait(50)

      panel.append("Hello layout")
      helpers.wait(50)

      local state = panel._get_state()
      local ranges = state.sections.ranges
      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local hello_idx = nil
      for i, line in ipairs(lines) do
        if line:find("Hello layout", 1, true) then
          hello_idx = i - 1
          break
        end
      end

      assert.truthy(hello_idx, "Expected history line")
      assert.is_true(hello_idx < (ranges.input and ranges.input.start or 0), "History should be above input")

      local input_lines = vim.api.nvim_buf_get_lines(buf, ranges.input.start, ranges.input.stop, false)
      assert.equals(state.sections.counts.input or 0, #input_lines)
    end)
  end)

  describe("header", function()
    it("renders auth menu and highlights active mode", function()
      panel.open()
      helpers.wait(50)

      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, 2, false)
      local line1 = lines[1] or ""
      local line2 = lines[2] or ""

      assert.truthy(line1:find("Banjo", 1, true), "Expected header title")
      assert.truthy(line2:find("[D] Default", 1, true), "Expected default option")
      assert.truthy(line2:find("[E] Accept Edits", 1, true), "Expected accept edits option")
      assert.truthy(line2:find("[A] Auto-approve", 1, true), "Expected auto-approve option")
      assert.truthy(line2:find("[P] Plan", 1, true), "Expected plan option")

      local ns_header = vim.api.nvim_create_namespace("banjo_header")
      local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns_header, 0, -1, { details = true })
      local has_active = false
      local has_inactive = false
      for _, mark in ipairs(extmarks) do
        local details = mark[4] or {}
        if details.hl_group == "BanjoAuthActive" then
          has_active = true
        elseif details.hl_group == "BanjoAuthInactive" then
          has_inactive = true
        end
      end

      assert.is_true(has_active, "Expected active mode highlight")
      assert.is_true(has_inactive, "Expected inactive mode highlight")
    end)

    it("calls bridge.set_permission_mode from keymaps", function()
      panel.open()
      helpers.wait(100)

      local called = nil
      local bridge = {
        get_state = function()
          return { mode = "default" }
        end,
        is_running = function()
          return true
        end,
        set_permission_mode = function(mode)
          called = mode
        end,
      }

      panel.set_bridge(bridge)
      panel._update_status()
      helpers.wait(50)

      local buf = helpers.get_banjo_buffer()
      vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf })
      helpers.wait(50)

      local maps = vim.api.nvim_buf_get_keymap(buf, "n")
      local has_a = false
      for _, m in ipairs(maps) do
        if m.lhs == "A" then
          has_a = true
          break
        end
      end
      assert.is_true(has_a, "Expected A keymap")

      panel._set_permission_mode("auto_approve")
      assert.equals("auto_approve", called)
    end)
  end)

  describe("actions", function()
    it("renders action row with hints and highlights", function()
      panel.open()
      helpers.wait(50)

      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local action_line = nil
      for _, line in ipairs(lines) do
        if line:find("%[p%]%s+Prompt") then
          action_line = line
          break
        end
      end

      assert.truthy(action_line, "Expected action row")
      assert.truthy(action_line:find("Mode:", 1, true), "Expected mode entry")
      assert.truthy(action_line:find("Agent:", 1, true), "Expected agent entry")
      assert.truthy(action_line:find("Model:", 1, true), "Expected model entry")

      local ns_actions = vim.api.nvim_create_namespace("banjo_actions")
      local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns_actions, 0, -1, { details = true })
      local has_key = false
      local has_label = false
      local has_value = false
      for _, mark in ipairs(extmarks) do
        local details = mark[4] or {}
        if details.hl_group == "BanjoActionKey" then
          has_key = true
        elseif details.hl_group == "BanjoActionLabel" then
          has_label = true
        elseif details.hl_group == "BanjoActionValue" then
          has_value = true
        end
      end

      assert.is_true(has_key, "Expected action key highlight")
      assert.is_true(has_label, "Expected action label highlight")
      assert.is_true(has_value, "Expected action value highlight")
    end)

    it("dispatches mode/agent/model actions", function()
      panel.open()
      helpers.wait(50)

      local bridge = {
        get_state = function()
          return {
            mode = "default",
            engine = "claude",
            model = "m1",
            models = { { id = "m1" }, { id = "m2" } },
          }
        end,
      }
      panel.set_bridge(bridge)

      local commands = require("banjo.commands")
      local calls = {}
      local original = commands.dispatch

      local ok, err = pcall(function()
        commands.dispatch = function(cmd, args, context)
          table.insert(calls, { cmd = cmd, args = args })
          return true
        end

        panel._action_cycle_mode()
        panel._action_toggle_agent()
        panel._action_cycle_model()
      end)

      commands.dispatch = original
      if not ok then
        error(err)
      end

      assert.equals("mode", calls[1].cmd)
      assert.equals("accept_edits", calls[1].args)
      assert.equals("codex", calls[2].cmd)
      assert.equals("", calls[2].args)
      assert.equals("model", calls[3].cmd)
      assert.equals("m2", calls[3].args)
    end)
  end)

  describe("append", function()
    it("adds text to buffer", function()
      panel.open()
      helpers.wait(50)

      panel.append("Hello World")

      -- Get buffer content
      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content = table.concat(lines, "\n")

      assert.truthy(content:find("Hello World"))
    end)

    it("handles multiline text", function()
      panel.open()
      helpers.wait(50)

      panel.append("Line 1\nLine 2\nLine 3")

      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      assert.truthy(#lines >= 3)
    end)
  end)

  describe("links", function()
    it("marks #L file links", function()
      panel.open()
      helpers.wait(50)

      local env = helpers.setup_test_env()
      local cwd = vim.fn.getcwd()
      vim.cmd("cd " .. env.dir)

      local ok, err = pcall(function()
        panel.append("test.lua#L2")
        helpers.wait(50)

        local link_data = panel._get_link_data()
        local found = nil
        for _, data in pairs(link_data) do
          if data and data.type == "file" then
            found = data
            break
          end
        end

        assert.truthy(found, "Expected file link extmark")
        assert.equals(vim.loop.fs_realpath(env.file), found.path)
        assert.equals(2, found.line)
      end)

      vim.cmd("cd " .. cwd)
      env.cleanup()

      if not ok then
        error(err)
      end
    end)
  end)

  describe("code blocks", function()
    it("highlights fenced blocks", function()
      panel.open()
      helpers.wait(50)

      panel.append("```\ncode line\n```\n")
      helpers.wait(50)

      local buf = helpers.get_banjo_buffer()
      local ns_id = vim.api.nvim_create_namespace("banjo")
      local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns_id, 0, -1, { details = true })

      local has_code = false
      for _, mark in ipairs(extmarks) do
        local details = mark[4] or {}
        if details.hl_group == "BanjoCodeBlock" then
          has_code = true
          break
        end
      end

      assert.is_true(has_code, "Expected code block highlight")
    end)

    it("stops highlighting after closing fence", function()
      panel.open()
      helpers.wait(50)

      panel.append("```\ncode line\n```\nplain\n")
      helpers.wait(50)

      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local plain_idx = nil
      for i, line in ipairs(lines) do
        if line == "plain" then
          plain_idx = i - 1
          break
        end
      end
      assert.truthy(plain_idx, "Expected plain line in buffer")

      local ns_id = vim.api.nvim_create_namespace("banjo")
      local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns_id, 0, -1, { details = true })
      local has_plain_code = false
      for _, mark in ipairs(extmarks) do
        local line = mark[2]
        local details = mark[4] or {}
        if line == plain_idx and details.hl_group == "BanjoCodeBlock" then
          has_plain_code = true
          break
        end
      end

      assert.is_false(has_plain_code, "Expected code block to end before plain line")
    end)
  end)

  describe("clear", function()
    it("removes all content", function()
      panel.open()
      panel.append("Some text")
      helpers.wait(50)

      panel.clear()

      local buf = helpers.get_banjo_buffer()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content = table.concat(lines, "\n")

      assert.is_nil(content:find("Some text", 1, true), "History should be cleared")
      assert.truthy(content:find("Banjo", 1, true), "Header should remain")
    end)
  end)

  describe("input text", function()
    it("get_input_text returns empty initially", function()
      panel.open()
      helpers.wait(50)

      local text = panel.get_input_text()
      assert.equals("", text)
    end)

    it("set_input_text updates input buffer", function()
      panel.open()
      helpers.wait(50)

      panel.set_input_text("test input")
      local text = panel.get_input_text()

      assert.equals("test input", text)
    end)

    it("set_input_text handles multiline", function()
      panel.open()
      helpers.wait(50)

      panel.set_input_text("line 1\nline 2\nline 3")
      local text = panel.get_input_text()

      assert.equals("line 1\nline 2\nline 3", text)
    end)

    it("set_input_text clears previous content", function()
      panel.open()
      helpers.wait(50)

      panel.set_input_text("first")
      panel.set_input_text("second")
      local text = panel.get_input_text()

      assert.equals("second", text)
    end)
  end)

  describe("output keymaps", function()
    it("sets q keymap on output buffer", function()
      panel.open()
      helpers.wait(100) -- Wait for deferred keymap setup

      local buf = helpers.get_banjo_buffer()
      local maps = vim.api.nvim_buf_get_keymap(buf, "n")
      local has_q = false
      for _, m in ipairs(maps) do
        if m.lhs == "q" then
          has_q = true
          break
        end
      end
      assert.is_true(has_q, "Output buffer should have 'q' keymap")
    end)

    it("sets i keymap on output buffer", function()
      panel.open()
      helpers.wait(100)

      local buf = helpers.get_banjo_buffer()
      local maps = vim.api.nvim_buf_get_keymap(buf, "n")
      local has_i = false
      for _, m in ipairs(maps) do
        if m.lhs == "i" then
          has_i = true
          break
        end
      end
      assert.is_true(has_i, "Output buffer should have 'i' keymap")
    end)

    it("keymaps persist after FileType event", function()
      panel.open()
      helpers.wait(100)

      local buf = helpers.get_banjo_buffer()

      -- Simulate ftplugin setting a keymap that would override ours
      vim.keymap.set("n", "q", ":close<CR>", { buffer = buf })

      -- Trigger FileType event (simulates what happens when ftplugin loads)
      vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
      helpers.wait(100)

      -- Check our keymap is still there (callback should have re-established it)
      local maps = vim.api.nvim_buf_get_keymap(buf, "n")
      local q_map = nil
      for _, m in ipairs(maps) do
        if m.lhs == "q" then
          q_map = m
          break
        end
      end

      assert.truthy(q_map, "Should have 'q' keymap after FileType event")
      -- Our callback-based keymap won't have rhs set to a string
      assert.not_equals(":close<CR>", q_map.rhs, "Keymap should be our callback, not the overridden one")
    end)
  end)

  describe("stream", function()
    it("start_stream opens panel with header", function()
      panel.start_stream("claude")
      helpers.wait(50)

      assert.is_true(panel.is_open(), "Panel should be open after start_stream")

      local buf = helpers.get_banjo_buffer()
      assert.truthy(buf > 0, "Panel buffer should exist")
    end)

    it("end_stream adds blank line", function()
      panel.start_stream("codex")
      panel.append("Response text")

      local buf = helpers.get_banjo_buffer()
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
