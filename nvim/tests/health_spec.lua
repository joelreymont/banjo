-- Unit tests for Banjo health checks
local helpers = require("tests.helpers")

describe("banjo health", function()
  local health
  local health_reports

  before_each(function()
    -- Mock vim.health API
    health_reports = {
      start = {},
      ok = {},
      warn = {},
      error = {},
      info = {}
    }

    vim.health = {
      start = function(name)
        table.insert(health_reports.start, name)
      end,
      ok = function(msg)
        table.insert(health_reports.ok, msg)
      end,
      warn = function(msg, advice)
        table.insert(health_reports.warn, { msg = msg, advice = advice })
      end,
      error = function(msg, advice)
        table.insert(health_reports.error, { msg = msg, advice = advice })
      end,
      info = function(msg)
        table.insert(health_reports.info, msg)
      end
    }

    -- Reload module
    package.loaded["banjo.health"] = nil
    package.loaded["banjo"] = nil
    package.loaded["banjo.bridge"] = nil

    health = require("banjo.health")
  end)

  describe("check", function()
    it("starts health check section", function()
      -- Mock banjo module
      package.loaded["banjo"] = {
        is_running = function() return false end,
        get_mcp_port = function() return nil end
      }

      health.check()

      assert.equals(1, #health_reports.start)
      assert.equals("Banjo", health_reports.start[1])
    end)

    it("reports running binary with MCP port", function()
      -- Mock banjo module as running
      package.loaded["banjo"] = {
        is_running = function() return true end,
        get_mcp_port = function() return 8080 end
      }

      health.check()

      -- Should have OK messages for running binary and MCP port
      local has_running = false
      local has_port = false
      for _, msg in ipairs(health_reports.ok) do
        if msg:find("binary is running") then
          has_running = true
        end
        if msg:find("MCP server listening on port 8080") then
          has_port = true
        end
      end

      assert.is_true(has_running, "Should report binary is running")
      assert.is_true(has_port, "Should report MCP port")
    end)

    it("reports running binary without MCP port", function()
      -- Mock banjo module as running but no port yet
      package.loaded["banjo"] = {
        is_running = function() return true end,
        get_mcp_port = function() return nil end
      }

      health.check()

      -- Should have OK message for running binary
      local has_running = false
      for _, msg in ipairs(health_reports.ok) do
        if msg:find("binary is running") then
          has_running = true
        end
      end

      assert.is_true(has_running, "Should report binary is running")
    end)

    it("checks for binary in common locations", function()
      -- Mock banjo module as not running
      package.loaded["banjo"] = {
        is_running = function() return false end,
        get_mcp_port = function() return nil end
      }

      -- Mock vim.fn.executable to return false
      local orig_executable = vim.fn.executable
      vim.fn.executable = function(path)
        return 0
      end

      health.check()

      -- Should have error about binary not found
      local has_error = false
      for _, report in ipairs(health_reports.error) do
        if report.msg:find("not found") then
          has_error = true
        end
      end

      assert.is_true(has_error, "Should report binary not found")

      vim.fn.executable = orig_executable
    end)

    it("finds binary at standard location", function()
      -- Mock banjo module as not running
      package.loaded["banjo"] = {
        is_running = function() return false end,
        get_mcp_port = function() return nil end
      }

      -- Mock vim.fn.executable to return true for first location
      local orig_executable = vim.fn.executable
      local call_count = 0
      vim.fn.executable = function(path)
        call_count = call_count + 1
        if call_count == 1 then
          return 1  -- First location exists
        end
        return 0
      end

      health.check()

      -- Should have OK message about found binary
      local has_found = false
      for _, msg in ipairs(health_reports.ok) do
        if msg:find("Found banjo binary") then
          has_found = true
        end
      end

      assert.is_true(has_found, "Should report found binary")

      vim.fn.executable = orig_executable
    end)

    it("checks for Claude CLI in PATH", function()
      -- Mock banjo module
      package.loaded["banjo"] = {
        is_running = function() return false end,
        get_mcp_port = function() return nil end
      }

      -- Mock vim.fn.executable for banjo binary check
      local orig_executable = vim.fn.executable
      vim.fn.executable = function(path)
        return 0
      end

      health.check()

      -- Should check for Claude CLI (either OK or warn)
      local checked_claude = #health_reports.ok > 0 or #health_reports.warn > 0

      assert.is_true(checked_claude, "Should check for Claude CLI")

      vim.fn.executable = orig_executable
    end)

    it("warns when Claude CLI not found", function()
      -- Mock banjo module
      package.loaded["banjo"] = {
        is_running = function() return false end,
        get_mcp_port = function() return nil end
      }

      -- Mock vim.fn.executable
      local orig_executable = vim.fn.executable
      vim.fn.executable = function(path)
        return 0
      end

      -- Mock io.popen to simulate "which claude" not found
      local orig_popen = io.popen
      io.popen = function(cmd)
        if cmd:find("which claude") then
          -- Return a handle that returns empty string
          return {
            read = function() return "" end,
            close = function() end
          }
        end
        return orig_popen(cmd)
      end

      health.check()

      -- Should have warning about Claude CLI
      local has_claude_warning = false
      for _, report in ipairs(health_reports.warn) do
        if report.msg:find("Claude CLI") then
          has_claude_warning = true
        end
      end

      assert.is_true(has_claude_warning, "Should warn about missing Claude CLI")

      vim.fn.executable = orig_executable
      io.popen = orig_popen
    end)

    it("checks for optional dependencies", function()
      -- Mock banjo module
      package.loaded["banjo"] = {
        is_running = function() return false end,
        get_mcp_port = function() return nil end
      }

      -- Mock vim.fn.executable
      local orig_executable = vim.fn.executable
      vim.fn.executable = function(path)
        return 0
      end

      health.check()

      -- Should check for snacks.nvim (either OK or info)
      local checked_snacks = false
      for _, msg in ipairs(health_reports.ok) do
        if msg:find("snacks") then
          checked_snacks = true
        end
      end
      for _, msg in ipairs(health_reports.info) do
        if msg:find("snacks") then
          checked_snacks = true
        end
      end

      assert.is_true(checked_snacks, "Should check for snacks.nvim")

      vim.fn.executable = orig_executable
    end)

    it("reports snacks.nvim when available", function()
      -- Mock snacks module
      package.loaded["snacks"] = {}

      -- Mock banjo module
      package.loaded["banjo"] = {
        is_running = function() return false end,
        get_mcp_port = function() return nil end
      }

      -- Mock vim.fn.executable
      local orig_executable = vim.fn.executable
      vim.fn.executable = function(path)
        return 0
      end

      health.check()

      -- Should have OK message about snacks
      local has_snacks = false
      for _, msg in ipairs(health_reports.ok) do
        if msg:find("snacks.nvim is available") then
          has_snacks = true
        end
      end

      assert.is_true(has_snacks, "Should report snacks.nvim available")

      vim.fn.executable = orig_executable
      package.loaded["snacks"] = nil
    end)

    it("reports snacks.nvim as optional when missing", function()
      -- Ensure snacks is not loaded
      package.loaded["snacks"] = nil

      -- Mock banjo module
      package.loaded["banjo"] = {
        is_running = function() return false end,
        get_mcp_port = function() return nil end
      }

      -- Mock vim.fn.executable
      local orig_executable = vim.fn.executable
      vim.fn.executable = function(path)
        return 0
      end

      health.check()

      -- Should have info message about snacks being optional
      local has_info = false
      for _, msg in ipairs(health_reports.info) do
        if msg:find("snacks") and msg:find("optional") then
          has_info = true
        end
      end

      assert.is_true(has_info, "Should report snacks as optional")

      vim.fn.executable = orig_executable
    end)
  end)
end)
