-- Unit tests for Banjo history
local helpers = require("tests.helpers")

describe("banjo history", function()
  local History
  local history
  local temp_dir

  before_each(function()
    -- Use temp directory for history file
    temp_dir = vim.fn.tempname() .. "_history"
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
    package.loaded["banjo.history"] = nil
    History = require("banjo.history")
    history = History.new("/test/cwd")
  end)

  after_each(function()
    -- Clean up temp directory
    if history then
      pcall(function() history:clear() end)
    end
  end)

  describe("add", function()
    it("adds text to history", function()
      history:add("first")
      history:add("second")

      assert.equals(2, history:size())
      assert.equals("second", history:get(0))
      assert.equals("first", history:get(1))
    end)

    it("rejects empty string", function()
      history:add("")

      assert.equals(0, history:size())
    end)

    it("rejects nil", function()
      history:add(nil)

      assert.equals(0, history:size())
    end)

    it("rejects whitespace-only text", function()
      history:add("   ")
      history:add("\t\n")

      assert.equals(0, history:size())
    end)

    it("does not add duplicate of last entry", function()
      history:add("first")
      history:add("first")
      history:add("first")

      assert.equals(1, history:size())
      assert.equals("first", history:get(0))
    end)

    it("allows duplicate if not consecutive", function()
      history:add("first")
      history:add("second")
      history:add("first")

      assert.equals(3, history:size())
      assert.equals("first", history:get(0))
      assert.equals("second", history:get(1))
      assert.equals("first", history:get(2))
    end)

    it("enforces max entries limit", function()
      -- Add more than 50 entries
      for i = 1, 60 do
        history:add("entry" .. i)
      end

      -- Should have exactly 50
      assert.equals(50, history:size())

      -- Oldest should be entry 11 (entries 1-10 removed)
      assert.equals("entry11", history:get(49))

      -- Newest should be entry 60
      assert.equals("entry60", history:get(0))
    end)
  end)

  describe("get", function()
    it("returns most recent with offset 0", function()
      history:add("first")
      history:add("second")

      assert.equals("second", history:get(0))
    end)

    it("returns older entries with higher offset", function()
      history:add("first")
      history:add("second")
      history:add("third")

      assert.equals("third", history:get(0))
      assert.equals("second", history:get(1))
      assert.equals("first", history:get(2))
    end)

    it("defaults offset to 0", function()
      history:add("entry")

      assert.equals("entry", history:get())
    end)

    it("returns nil for negative offset", function()
      history:add("entry")

      assert.is_nil(history:get(-1))
    end)

    it("returns nil for offset beyond size", function()
      history:add("first")
      history:add("second")

      assert.is_nil(history:get(2))
      assert.is_nil(history:get(10))
    end)

    it("returns nil when history is empty", function()
      assert.is_nil(history:get(0))
    end)
  end)

  describe("size", function()
    it("returns 0 for empty history", function()
      assert.equals(0, history:size())
    end)

    it("returns correct count after adds", function()
      history:add("first")
      assert.equals(1, history:size())

      history:add("second")
      assert.equals(2, history:size())

      history:add("third")
      assert.equals(3, history:size())
    end)

    it("returns correct count after clear", function()
      history:add("first")
      history:add("second")
      history:clear()

      assert.equals(0, history:size())
    end)
  end)

  describe("get_all", function()
    it("returns empty table for empty history", function()
      local all = history:get_all()

      assert.is_table(all)
      assert.equals(0, #all)
    end)

    it("returns all entries in order", function()
      history:add("first")
      history:add("second")
      history:add("third")

      local all = history:get_all()

      assert.equals(3, #all)
      assert.equals("first", all[1])
      assert.equals("second", all[2])
      assert.equals("third", all[3])
    end)

    it("returns a copy that does not modify internal state", function()
      history:add("first")
      history:add("second")

      local all = history:get_all()
      table.insert(all, "third")
      all[1] = "modified"

      -- Original should be unchanged
      assert.equals(2, history:size())
      assert.equals("first", history:get(1))
    end)
  end)

  describe("clear", function()
    it("removes all entries", function()
      history:add("first")
      history:add("second")
      history:add("third")

      history:clear()

      assert.equals(0, history:size())
      assert.is_nil(history:get(0))
    end)

    it("allows adding after clear", function()
      history:add("before")
      history:clear()
      history:add("after")

      assert.equals(1, history:size())
      assert.equals("after", history:get(0))
    end)
  end)

  describe("save and load", function()
    it("persists history to disk", function()
      history:add("first")
      history:add("second")
      history:add("third")

      history:save()

      -- Create new instance with same cwd to get fresh state
      local history2 = History.new("/test/cwd")
      history2:load()

      assert.equals(3, history2:size())
      assert.equals("third", history2:get(0))
      assert.equals("second", history2:get(1))
      assert.equals("first", history2:get(2))
    end)

    it("handles missing file gracefully", function()
      -- Don't save anything, just try to load
      history:load()

      -- Should have empty history
      assert.equals(0, history:size())
    end)

    it("handles corrupt JSON gracefully", function()
      -- Write invalid JSON to history file
      local history_file = history:get_file_path()
      vim.fn.mkdir(temp_dir .. "/banjo", "p")

      local file = io.open(history_file, "w")
      if file then
        file:write("{ invalid json }")
        file:close()
      end

      -- Should not error
      history:load()

      -- Should have empty history
      assert.equals(0, history:size())
    end)

    it("overwrites existing file on save", function()
      history:add("first")
      history:save()

      history:clear()
      history:add("second")
      history:save()

      -- Create new instance to verify only "second" is present
      local history2 = History.new("/test/cwd")
      history2:load()

      assert.equals(1, history2:size())
      assert.equals("second", history2:get(0))
    end)

    it("round-trips complex history", function()
      -- Add various entries including edge cases
      for i = 1, 25 do
        history:add("entry " .. i)
      end
      history:add("multiline\ntext\nhere")
      history:add("special chars: !@#$%^&*()")

      history:save()

      -- Create new instance
      local history2 = History.new("/test/cwd")
      history2:load()

      assert.equals(27, history2:size())
      assert.equals("special chars: !@#$%^&*()", history2:get(0))
      assert.equals("multiline\ntext\nhere", history2:get(1))
      assert.equals("entry 1", history2:get(26))
    end)
  end)

  describe("per-cwd isolation", function()
    it("uses different files for different cwds", function()
      local history_a = History.new("/path/a")
      local history_b = History.new("/path/b")

      history_a:add("from A")
      history_b:add("from B")

      -- Reload both
      local history_a2 = History.new("/path/a")
      local history_b2 = History.new("/path/b")
      history_a2:load()
      history_b2:load()

      assert.equals(1, history_a2:size())
      assert.equals("from A", history_a2:get(0))
      assert.equals(1, history_b2:size())
      assert.equals("from B", history_b2:get(0))
    end)
  end)
end)
