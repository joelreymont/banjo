-- Unit tests for Banjo commands
local helpers = require("tests.helpers")

describe("banjo commands", function()
  local commands

  before_each(function()
    -- Reload module for clean state
    package.loaded["banjo.commands"] = nil
    commands = require("banjo.commands")
  end)

  describe("parse", function()
    it("parses command without arguments", function()
      local result = commands.parse("/help")
      assert.is_not_nil(result)
      assert.equals("help", result.cmd)
      assert.equals("", result.args)
    end)

    it("parses command with single argument", function()
      local result = commands.parse("/model opus")
      assert.is_not_nil(result)
      assert.equals("model", result.cmd)
      assert.equals("opus", result.args)
    end)

    it("parses command with multiple arguments", function()
      local result = commands.parse("/load my-session-id-123")
      assert.is_not_nil(result)
      assert.equals("load", result.cmd)
      assert.equals("my-session-id-123", result.args)
    end)

    it("trims whitespace from command", function()
      local result = commands.parse("  /help  ")
      assert.is_not_nil(result)
      assert.equals("help", result.cmd)
      assert.equals("", result.args)
    end)

    it("trims whitespace from arguments", function()
      local result = commands.parse("/model   opus   ")
      assert.is_not_nil(result)
      assert.equals("model", result.cmd)
      assert.equals("opus", result.args)
    end)

    it("returns nil for non-command text", function()
      local result = commands.parse("regular text")
      assert.is_nil(result)
    end)

    it("returns nil for empty string", function()
      local result = commands.parse("")
      assert.is_nil(result)
    end)

    it("returns nil for nil input", function()
      local result = commands.parse(nil)
      assert.is_nil(result)
    end)

    it("returns nil for text not starting with slash", function()
      local result = commands.parse("model opus")
      assert.is_nil(result)
    end)
  end)

  describe("register and dispatch", function()
    it("registers and dispatches custom command", function()
      local called = false
      local received_args = nil
      local received_context = nil

      commands.register("test", function(args, context)
        called = true
        received_args = args
        received_context = context
      end)

      local context = { panel = {}, bridge = {} }
      local handled = commands.dispatch("test", "arg1", context)

      assert.is_true(handled, "Should return true for handled command")
      assert.is_true(called, "Handler should be called")
      assert.equals("arg1", received_args)
      assert.equals(context, received_context)
    end)

    it("returns false for non-existent command", function()
      local context = { panel = {}, bridge = {} }
      local handled = commands.dispatch("nonexistent", "", context)

      assert.is_false(handled, "Should return false for unknown command")
    end)
  end)

  describe("list_commands", function()
    it("returns sorted list of built-in commands", function()
      local cmds = commands.list_commands()

      assert.truthy(#cmds > 0, "Should have commands")

      -- Check for known built-in commands
      local has_help = false
      local has_clear = false
      local has_model = false
      for _, cmd in ipairs(cmds) do
        if cmd == "help" then has_help = true end
        if cmd == "clear" then has_clear = true end
        if cmd == "model" then has_model = true end
      end

      assert.is_true(has_help, "Should include 'help' command")
      assert.is_true(has_clear, "Should include 'clear' command")
      assert.is_true(has_model, "Should include 'model' command")

      -- Check sorted order
      for i = 2, #cmds do
        assert.truthy(cmds[i - 1] < cmds[i], "Commands should be sorted")
      end
    end)

    it("includes custom registered commands", function()
      commands.register("custom", function() end)

      local cmds = commands.list_commands()

      local has_custom = false
      for _, cmd in ipairs(cmds) do
        if cmd == "custom" then has_custom = true end
      end

      assert.is_true(has_custom, "Should include custom command")
    end)
  end)

  describe("built-in commands", function()
    describe("/help", function()
      it("displays help text", function()
        local lines = {}
        local mock_panel = {
          append_status = function(line)
            table.insert(lines, line)
          end
        }

        commands.dispatch("help", "", { panel = mock_panel })

        assert.truthy(#lines > 0, "Should append help text")

        -- Check for expected content
        local content = table.concat(lines, "\n")
        assert.truthy(content:find("Available commands"), "Should show available commands")
        assert.truthy(content:find("/help"), "Should list /help command")
        assert.truthy(content:find("/clear"), "Should list /clear command")
        assert.truthy(content:find("Keybinds"), "Should show keybinds")
      end)

      it("handles missing panel gracefully", function()
        -- Should not error
        commands.dispatch("help", "", {})
      end)
    end)

    describe("/clear", function()
      it("calls panel.clear()", function()
        local cleared = false
        local mock_panel = {
          clear = function()
            cleared = true
          end
        }

        commands.dispatch("clear", "", { panel = mock_panel })

        assert.is_true(cleared, "Should call panel.clear()")
      end)

      it("handles missing panel gracefully", function()
        -- Should not error
        commands.dispatch("clear", "", {})
      end)
    end)

    describe("/new", function()
      it("calls bridge.cancel() and panel.clear()", function()
        local cancelled = false
        local cleared = false
        local status_lines = {}

        local mock_bridge = {
          cancel = function()
            cancelled = true
          end
        }

        local mock_panel = {
          clear = function()
            cleared = true
          end,
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("new", "", { bridge = mock_bridge, panel = mock_panel })

        assert.is_true(cancelled, "Should call bridge.cancel()")
        assert.is_true(cleared, "Should call panel.clear()")
        assert.truthy(#status_lines > 0, "Should show status message")
      end)

      it("handles missing bridge gracefully", function()
        local cleared = false
        local mock_panel = {
          clear = function()
            cleared = true
          end,
          append_status = function() end
        }

        -- Should not error
        commands.dispatch("new", "", { panel = mock_panel })
        assert.is_true(cleared, "Should still clear panel")
      end)
    end)

    describe("/cancel", function()
      it("calls bridge.cancel() when connected", function()
        local cancelled = false
        local status_lines = {}

        local mock_bridge = {
          cancel = function()
            cancelled = true
          end
        }

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("cancel", "", { bridge = mock_bridge, panel = mock_panel })

        assert.is_true(cancelled, "Should call bridge.cancel()")

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Cancelled"), "Should show cancelled message")
      end)

      it("shows not connected message when no bridge", function()
        local status_lines = {}

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("cancel", "", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Not connected"), "Should show not connected message")
      end)
    end)

    describe("/model", function()
      it("sets model when valid", function()
        local set_model_arg = nil
        local status_lines = {}

        local mock_bridge = {
          set_model = function(model)
            set_model_arg = model
          end
        }

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end,
          _update_status = function() end
        }

        commands.dispatch("model", "opus", { bridge = mock_bridge, panel = mock_panel })

        assert.equals("opus", set_model_arg, "Should set model to opus")

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Model: opus"), "Should show model confirmation")
      end)

      it("validates model names", function()
        local status_lines = {}

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("model", "invalid", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Invalid model"), "Should reject invalid model")
      end)

      it("shows usage when no arguments", function()
        local status_lines = {}

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("model", "", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Usage"), "Should show usage message")
      end)

      it("accepts all valid models", function()
        local models_set = {}

        local mock_bridge = {
          set_model = function(model)
            table.insert(models_set, model)
          end
        }

        local mock_panel = {
          append_status = function() end,
          _update_status = function() end
        }

        local context = { bridge = mock_bridge, panel = mock_panel }

        commands.dispatch("model", "opus", context)
        commands.dispatch("model", "sonnet", context)
        commands.dispatch("model", "haiku", context)

        assert.equals(3, #models_set, "Should accept all three models")
      end)

      it("shows not connected message when no bridge", function()
        local status_lines = {}

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("model", "opus", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Not connected"), "Should show not connected message")
      end)
    end)

    describe("/mode", function()
      it("sets permission mode when valid", function()
        local set_mode_arg = nil
        local status_lines = {}

        local mock_bridge = {
          set_permission_mode = function(mode)
            set_mode_arg = mode
          end
        }

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end,
          _update_status = function() end
        }

        commands.dispatch("mode", "auto_approve", { bridge = mock_bridge, panel = mock_panel })

        assert.equals("auto_approve", set_mode_arg, "Should set mode")

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Mode: auto_approve"), "Should show mode confirmation")
      end)

      it("validates mode names", function()
        local status_lines = {}

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("mode", "invalid", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Invalid mode"), "Should reject invalid mode")
      end)

      it("accepts all valid modes", function()
        local modes_set = {}

        local mock_bridge = {
          set_permission_mode = function(mode)
            table.insert(modes_set, mode)
          end
        }

        local mock_panel = {
          append_status = function() end,
          _update_status = function() end
        }

        local context = { bridge = mock_bridge, panel = mock_panel }

        commands.dispatch("mode", "default", context)
        commands.dispatch("mode", "accept_edits", context)
        commands.dispatch("mode", "auto_approve", context)
        commands.dispatch("mode", "plan_only", context)

        assert.equals(4, #modes_set, "Should accept all four modes")
      end)

      it("shows not connected message when no bridge", function()
        local status_lines = {}

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("mode", "default", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Not connected"), "Should show not connected message")
      end)
    end)

    describe("/agent", function()
      it("sets agent when valid", function()
        local set_engine_arg = nil
        local status_lines = {}

        local mock_bridge = {
          set_engine = function(agent)
            set_engine_arg = agent
          end
        }

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end,
          _update_status = function() end
        }

        commands.dispatch("agent", "codex", { bridge = mock_bridge, panel = mock_panel })

        assert.equals("codex", set_engine_arg, "Should set agent")

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Agent: codex"), "Should show agent confirmation")
      end)

      it("validates agent names", function()
        local status_lines = {}

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("agent", "invalid", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Invalid agent"), "Should reject invalid agent")
      end)

      it("accepts all valid agents", function()
        local agents_set = {}

        local mock_bridge = {
          set_engine = function(agent)
            table.insert(agents_set, agent)
          end
        }

        local mock_panel = {
          append_status = function() end,
          _update_status = function() end
        }

        local context = { bridge = mock_bridge, panel = mock_panel }

        commands.dispatch("agent", "claude", context)
        commands.dispatch("agent", "codex", context)

        assert.equals(2, #agents_set, "Should accept both agents")
      end)

      it("shows not connected message when no bridge", function()
        local status_lines = {}

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("agent", "claude", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Not connected"), "Should show not connected message")
      end)
    end)

    describe("/sessions", function()
      it("lists saved sessions", function()
        -- Mock sessions module
        package.loaded["banjo.sessions"] = {
          list = function()
            return {
              { id = "session-1", timestamp = 1704067200 },
              { id = "session-2", timestamp = 1704153600 }
            }
          end
        }

        local status_lines = {}
        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("sessions", "", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Saved sessions"), "Should show header")
        assert.truthy(status:find("session%-1"), "Should list session-1")
        assert.truthy(status:find("session%-2"), "Should list session-2")
      end)

      it("shows message when no sessions", function()
        -- Mock sessions module
        package.loaded["banjo.sessions"] = {
          list = function()
            return {}
          end
        }

        local status_lines = {}
        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("sessions", "", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("No saved sessions"), "Should show no sessions message")
      end)
    end)

    describe("/load", function()
      it("loads session when found", function()
        -- Mock sessions module
        package.loaded["banjo.sessions"] = {
          load = function(id)
            if id == "session-1" then
              return { input_text = "test input" }
            end
            return nil
          end
        }

        local status_lines = {}
        local set_input_text_arg = nil

        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end,
          set_input_text = function(text)
            set_input_text_arg = text
          end
        }

        commands.dispatch("load", "session-1", { panel = mock_panel })

        assert.equals("test input", set_input_text_arg, "Should restore input text")

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Loaded session: session%-1"), "Should show success message")
      end)

      it("shows error when session not found", function()
        -- Mock sessions module
        package.loaded["banjo.sessions"] = {
          load = function(id)
            return nil
          end
        }

        local status_lines = {}
        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("load", "nonexistent", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Session not found"), "Should show error message")
      end)

      it("shows usage when no arguments", function()
        local status_lines = {}
        local mock_panel = {
          append_status = function(line)
            table.insert(status_lines, line)
          end
        }

        commands.dispatch("load", "", { panel = mock_panel })

        local status = table.concat(status_lines, "\n")
        assert.truthy(status:find("Usage"), "Should show usage message")
      end)
    end)
  end)
end)
