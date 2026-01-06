#!/usr/bin/env -S nvim -l

-- Test runner for Banjo nvim plugin using plenary
-- Usage: nvim -l scripts/run_tests.lua [test_file_pattern]

-- Add nvim/lua to package.path
local script_path = debug.getinfo(1, "S").source:sub(2)
local nvim_dir = vim.fn.fnamemodify(script_path, ":h:h")
package.path = nvim_dir .. "/lua/?.lua;" .. nvim_dir .. "/lua/?/init.lua;" .. package.path

-- Load minimal init for test environment
vim.cmd("source " .. nvim_dir .. "/tests/minimal_init.lua")

-- Load plenary
local ok, plenary = pcall(require, "plenary.test_harness")
if not ok then
  print("Error: plenary.nvim not found")
  print("Install with: git clone https://github.com/nvim-lua/plenary.nvim ~/.local/share/nvim/site/pack/test/start/plenary.nvim")
  os.exit(1)
end

-- Get test file pattern from args
local pattern = arg[1] or ".*_spec%.lua$"

-- Run tests
local test_dir = nvim_dir .. "/tests"
print("Running tests in: " .. test_dir)
print("Pattern: " .. pattern)
print("")

-- plenary.test_directory returns a table with summary
local results = plenary.test_directory(test_dir, {
  minimal_init = nvim_dir .. "/tests/minimal_init.lua",
  sequential = false,
  keep_going = true,
})

-- Exit with appropriate code
local failed = results.fail + results.errs
os.exit(failed > 0 and 1 or 0)
