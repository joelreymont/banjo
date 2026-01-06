-- Unit tests for Banjo sessions
local helpers = require("tests.helpers")

describe("banjo sessions", function()
  local sessions
  local temp_dir

  before_each(function()
    -- Use temp directory for sessions
    temp_dir = vim.fn.tempname() .. "_sessions"
    vim.fn.mkdir(temp_dir, "p")

    -- Mock stdpath to use temp directory
    local orig_stdpath = vim.fn.stdpath
    vim.fn.stdpath = function(what)
      if what == "data" then
        return temp_dir
      end
      return orig_stdpath(what)
    end

    -- Reload module for clean state
    package.loaded["banjo.sessions"] = nil
    sessions = require("banjo.sessions")
  end)

  after_each(function()
    -- Clean up temp directory
    if temp_dir and vim.fn.isdirectory(temp_dir) == 1 then
      vim.fn.delete(temp_dir, "rf")
    end
  end)

  describe("save", function()
    it("saves session data to disk", function()
      local data = {
        input_text = "test input",
        timestamp = 1704067200
      }

      local ok = sessions.save("test-session", data)

      assert.is_true(ok, "Should save successfully")

      -- Verify file exists
      local sessions_dir = temp_dir .. "/banjo_sessions"
      local file_path = sessions_dir .. "/test-session.json"
      assert.equals(1, vim.fn.filereadable(file_path), "Session file should exist")
    end)

    it("returns false for empty id", function()
      local ok = sessions.save("", { data = "test" })

      assert.is_false(ok, "Should reject empty id")
    end)

    it("returns false for nil id", function()
      local ok = sessions.save(nil, { data = "test" })

      assert.is_false(ok, "Should reject nil id")
    end)

    it("creates sessions directory if missing", function()
      local sessions_dir = temp_dir .. "/banjo_sessions"

      -- Directory should not exist yet
      assert.equals(0, vim.fn.isdirectory(sessions_dir))

      sessions.save("test", { data = "test" })

      -- Directory should now exist
      assert.equals(1, vim.fn.isdirectory(sessions_dir))
    end)

    it("overwrites existing session", function()
      sessions.save("test", { value = "first" })
      sessions.save("test", { value = "second" })

      local loaded = sessions.load("test")

      assert.is_not_nil(loaded)
      assert.equals("second", loaded.value)
    end)

    it("handles complex data structures", function()
      local data = {
        input_text = "multiline\ntext\nhere",
        timestamp = 1704067200,
        metadata = {
          model = "opus",
          mode = "default"
        },
        messages = { "msg1", "msg2", "msg3" }
      }

      local ok = sessions.save("complex", data)
      assert.is_true(ok)

      local loaded = sessions.load("complex")
      assert.is_not_nil(loaded)
      assert.equals("multiline\ntext\nhere", loaded.input_text)
      assert.equals(1704067200, loaded.timestamp)
      assert.equals("opus", loaded.metadata.model)
      assert.equals(3, #loaded.messages)
    end)
  end)

  describe("load", function()
    it("loads saved session", function()
      local data = {
        input_text = "test input",
        timestamp = 1704067200
      }

      sessions.save("test", data)
      local loaded = sessions.load("test")

      assert.is_not_nil(loaded)
      assert.equals("test input", loaded.input_text)
      assert.equals(1704067200, loaded.timestamp)
    end)

    it("returns nil for non-existent session", function()
      local loaded = sessions.load("nonexistent")

      assert.is_nil(loaded)
    end)

    it("returns nil for empty id", function()
      local loaded = sessions.load("")

      assert.is_nil(loaded)
    end)

    it("returns nil for nil id", function()
      local loaded = sessions.load(nil)

      assert.is_nil(loaded)
    end)

    it("handles corrupt JSON gracefully", function()
      -- Create sessions directory
      local sessions_dir = temp_dir .. "/banjo_sessions"
      vim.fn.mkdir(sessions_dir, "p")

      -- Write invalid JSON
      local file = io.open(sessions_dir .. "/corrupt.json", "w")
      if file then
        file:write("{ invalid json }")
        file:close()
      end

      local loaded = sessions.load("corrupt")

      assert.is_nil(loaded, "Should return nil for corrupt JSON")
    end)
  end)

  describe("list", function()
    it("returns empty list when no sessions", function()
      local list = sessions.list()

      assert.is_table(list)
      assert.equals(0, #list)
    end)

    it("lists saved sessions", function()
      sessions.save("session-1", { timestamp = 1704067200 })
      sessions.save("session-2", { timestamp = 1704153600 })
      sessions.save("session-3", { timestamp = 1704240000 })

      local list = sessions.list()

      assert.equals(3, #list)

      -- Check that all sessions are present
      local ids = {}
      for _, session in ipairs(list) do
        ids[session.id] = true
      end
      assert.is_true(ids["session-1"])
      assert.is_true(ids["session-2"])
      assert.is_true(ids["session-3"])
    end)

    it("sorts sessions by timestamp descending", function()
      sessions.save("oldest", { timestamp = 1704067200 })
      sessions.save("middle", { timestamp = 1704153600 })
      sessions.save("newest", { timestamp = 1704240000 })

      local list = sessions.list()

      assert.equals(3, #list)
      assert.equals("newest", list[1].id, "Most recent should be first")
      assert.equals("middle", list[2].id)
      assert.equals("oldest", list[3].id, "Oldest should be last")
    end)

    it("includes timestamp in session metadata", function()
      sessions.save("test", { timestamp = 1704067200 })

      local list = sessions.list()

      assert.equals(1, #list)
      assert.equals("test", list[1].id)
      assert.equals(1704067200, list[1].timestamp)
    end)

    it("ignores non-JSON files", function()
      local sessions_dir = temp_dir .. "/banjo_sessions"
      vim.fn.mkdir(sessions_dir, "p")

      -- Create a non-JSON file
      local file = io.open(sessions_dir .. "/README.txt", "w")
      if file then
        file:write("This is not a session")
        file:close()
      end

      sessions.save("valid-session", { timestamp = 1704067200 })

      local list = sessions.list()

      assert.equals(1, #list, "Should only list JSON files")
      assert.equals("valid-session", list[1].id)
    end)

    it("skips sessions with corrupt JSON", function()
      local sessions_dir = temp_dir .. "/banjo_sessions"
      vim.fn.mkdir(sessions_dir, "p")

      -- Create corrupt session
      local file = io.open(sessions_dir .. "/corrupt.json", "w")
      if file then
        file:write("{ invalid }")
        file:close()
      end

      sessions.save("valid", { timestamp = 1704067200 })

      local list = sessions.list()

      assert.equals(1, #list, "Should skip corrupt sessions")
      assert.equals("valid", list[1].id)
    end)

    it("handles sessions with missing timestamp", function()
      sessions.save("no-timestamp", { data = "test" })
      sessions.save("with-timestamp", { timestamp = 1704067200 })

      local list = sessions.list()

      assert.equals(2, #list)
      -- Session with timestamp should be first (timestamp > 0)
      assert.equals("with-timestamp", list[1].id)
      assert.equals("no-timestamp", list[2].id)
    end)
  end)

  describe("delete", function()
    it("deletes existing session", function()
      sessions.save("test", { timestamp = 1704067200 })

      local ok = sessions.delete("test")

      assert.is_true(ok, "Should delete successfully")

      local loaded = sessions.load("test")
      assert.is_nil(loaded, "Deleted session should not load")
    end)

    it("returns false for empty id", function()
      local ok = sessions.delete("")

      assert.is_false(ok)
    end)

    it("returns false for nil id", function()
      local ok = sessions.delete(nil)

      assert.is_false(ok)
    end)

    it("handles non-existent session gracefully", function()
      -- Should not error even if session doesn't exist
      local ok = sessions.delete("nonexistent")

      -- pcall returns true even if file doesn't exist
      assert.is_true(ok)
    end)

    it("removes session from list", function()
      sessions.save("session-1", { timestamp = 1704067200 })
      sessions.save("session-2", { timestamp = 1704153600 })

      sessions.delete("session-1")

      local list = sessions.list()

      assert.equals(1, #list)
      assert.equals("session-2", list[1].id)
    end)
  end)

  describe("round-trip", function()
    it("saves and loads complete session data", function()
      local original = {
        input_text = "What is the meaning of life?",
        timestamp = 1704067200,
        model = "opus",
        mode = "default",
        messages = {
          "user message 1",
          "assistant response 1",
          "user message 2"
        },
        metadata = {
          version = "1.0",
          client = "banjo-nvim"
        }
      }

      sessions.save("complete-session", original)
      local loaded = sessions.load("complete-session")

      assert.is_not_nil(loaded)
      assert.equals(original.input_text, loaded.input_text)
      assert.equals(original.timestamp, loaded.timestamp)
      assert.equals(original.model, loaded.model)
      assert.equals(original.mode, loaded.mode)
      assert.equals(#original.messages, #loaded.messages)
      assert.equals(original.metadata.version, loaded.metadata.version)
    end)
  end)
end)
