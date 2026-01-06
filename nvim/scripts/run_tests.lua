#!/usr/bin/env -S nvim -l

-- Test runner for Banjo nvim plugin
-- Usage: nvim -l scripts/run_tests.lua [test_file_pattern]

local helpers = require("tests.helpers")

-- Make test functions global for test files
_G.describe = helpers.describe
_G.it = helpers.it
_G.before_each = function() end  -- Not implemented yet
_G.after_each = function() end   -- Not implemented yet
_G.assert = {
  is_false = function(v) if v then error("Expected false, got " .. vim.inspect(v)) end end,
  is_nil = function(v) if v ~= nil then error("Expected nil, got " .. vim.inspect(v)) end end,
  is_not_nil = function(v) if v == nil then error("Expected non-nil") end end,
  equals = function(expected, actual) if expected ~= actual then error("Expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)) end end,
  is_table = function(v) if type(v) ~= "table" then error("Expected table, got " .. type(v)) end end,
  is_true = function(v) if not v then error("Expected true, got " .. vim.inspect(v)) end end,
  truthy = function(v, msg) if not v then error(msg or "Expected truthy") end end,
}

-- Add nvim/lua to package.path
local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*)/")
local nvim_dir = script_dir:match("(.*/nvim)/")
package.path = nvim_dir .. "/lua/?.lua;" .. nvim_dir .. "/lua/?/init.lua;" .. package.path

-- Get test file pattern from args
local pattern = arg[1] or ".*_spec%.lua$"

-- Find and load test files
local test_dir = nvim_dir .. "/tests"
local handle = vim.loop.fs_scandir(test_dir)
if not handle then
  print("Error: Cannot open tests directory: " .. test_dir)
  os.exit(1)
end

local test_files = {}
while true do
  local name, type = vim.loop.fs_scandir_next(handle)
  if not name then break end
  if type == "file" and name:match(pattern) then
    table.insert(test_files, test_dir .. "/" .. name)
  end
end

if #test_files == 0 then
  print("No test files found matching: " .. pattern)
  os.exit(1)
end

print("Loading " .. #test_files .. " test file(s)...\n")

-- Load all test files
for _, file in ipairs(test_files) do
  print("Loading: " .. file)
  local ok, err = pcall(dofile, file)
  if not ok then
    print("ERROR loading " .. file .. ": " .. err)
    os.exit(1)
  end
end

print("")

-- Run tests
local success = helpers.run_tests()

-- Exit with appropriate code
os.exit(success and 0 or 1)
