-- Test runner for banjo.nvim
-- Usage: nvim --headless -u tests/minimal_init.lua -c "luafile tests/run.lua"
-- Or:    nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

-- Add tests directory to Lua package path
local test_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
package.path = test_dir .. "/?.lua;" .. package.path

local helpers = require("tests.helpers")

-- Check for plenary
local has_plenary, _ = pcall(require, "plenary.busted")

-- Find and load all *_spec.lua files
local spec_files = vim.fn.glob(test_dir .. "/*_spec.lua", false, true)

if #spec_files == 0 then
    print("No test files found in " .. test_dir)
    vim.cmd("qa!")
    return
end

print("Found " .. #spec_files .. " test file(s)")
print("Binary: " .. (vim.g.banjo_test_binary or "NOT FOUND"))
print("")

if has_plenary then
    -- Use plenary.busted for better test output
    -- test_directory() loads and runs tests automatically
    require("plenary.test_harness").test_directory(test_dir, {
        minimal_init = test_dir .. "/minimal_init.lua",
        sequential = true,
    })
else
    -- Fallback to simple test runner
    print("Plenary not found, using simple test runner")
    print("")

    for _, file in ipairs(spec_files) do
        print("Loading: " .. vim.fn.fnamemodify(file, ":t"))
        -- Set up describe/it from helpers
        _G.describe = helpers.describe
        _G.it = helpers.it
        dofile(file)
    end

    local success = helpers.run_tests()

    -- Exit with appropriate code
    vim.schedule(function()
        vim.cmd("qa" .. (success and "!" or "ll!"))
    end)
end
