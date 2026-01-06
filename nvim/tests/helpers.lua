-- Test helpers for banjo.nvim e2e tests
local M = {}

-- Wait for a condition with timeout, processing vim event loop
-- This is critical for async operations in headless mode
---@param condition_fn function Returns true when condition is met
---@param timeout_ms number Maximum time to wait
---@param interval_ms number|nil Poll interval (default 50ms)
---@return boolean success True if condition was met
function M.wait_for(condition_fn, timeout_ms, interval_ms)
    timeout_ms = timeout_ms or 5000
    interval_ms = interval_ms or 50

    local start = vim.loop.now()
    while vim.loop.now() - start < timeout_ms do
        -- Process pending vim events (critical for headless mode)
        vim.wait(interval_ms, function()
            return condition_fn()
        end, interval_ms)

        if condition_fn() then
            return true
        end

        -- Run the libuv event loop to process I/O
        vim.loop.run("nowait")
    end

    return false
end

-- Setup an isolated test environment
---@param opts table|nil Options: {cwd = string}
---@return table env Test environment with cleanup function
function M.setup_test_env(opts)
    opts = opts or {}

    local test_dir = opts.cwd or vim.fn.tempname() .. "_banjo_e2e_" .. math.random(10000)
    vim.fn.mkdir(test_dir, "p")

    -- Create a test file
    local test_file = test_dir .. "/test.lua"
    local f = io.open(test_file, "w")
    if f then
        f:write("-- Test file\nlocal x = 1\n")
        f:close()
    end

    return {
        dir = test_dir,
        file = test_file,
        binary = vim.g.banjo_test_binary,
        cleanup = function()
            vim.fn.delete(test_dir, "rf")
        end,
    }
end

-- Capture the current state of a buffer for assertions
---@param buf number|nil Buffer handle (default: current)
---@return table state Buffer state
function M.capture_buffer_state(buf)
    buf = buf or vim.api.nvim_get_current_buf()

    return {
        lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
        line_count = vim.api.nvim_buf_line_count(buf),
        name = vim.api.nvim_buf_get_name(buf),
        filetype = vim.bo[buf].filetype,
        modified = vim.bo[buf].modified,
    }
end

-- Capture display state (extmarks, virtual text, etc.)
---@param buf number|nil Buffer handle
---@param ns_id number|nil Namespace (default: all)
---@return table state Display state
function M.capture_display_state(buf, ns_id)
    buf = buf or vim.api.nvim_get_current_buf()
    ns_id = ns_id or -1  -- -1 = all namespaces

    local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns_id, 0, -1, {
        details = true,
    })

    return {
        extmarks = extmarks,
        extmark_count = #extmarks,
    }
end

-- Get all windows and their properties
---@return table windows Window info list
function M.get_windows()
    local windows = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        table.insert(windows, {
            handle = win,
            buffer = buf,
            buffer_name = vim.api.nvim_buf_get_name(buf),
            width = vim.api.nvim_win_get_width(win),
            height = vim.api.nvim_win_get_height(win),
            cursor = vim.api.nvim_win_get_cursor(win),
        })
    end
    return windows
end

-- Find the banjo panel window
---@return table|nil window Panel window info or nil
function M.find_panel_window()
    for _, win in ipairs(M.get_windows()) do
        if win.buffer_name:match("Banjo$") then
            return win
        end
    end
    return nil
end

-- Assert that a condition is true, with message
---@param condition boolean
---@param message string
function M.assert(condition, message)
    if not condition then
        error("Assertion failed: " .. (message or "unknown"))
    end
end

-- Assert two values are equal
---@param expected any
---@param actual any
---@param message string|nil
function M.assert_eq(expected, actual, message)
    if expected ~= actual then
        local msg = message and (message .. ": ") or ""
        error(string.format("%sExpected %s, got %s", msg, vim.inspect(expected), vim.inspect(actual)))
    end
end

-- Assert a value is truthy
---@param value any
---@param message string|nil
function M.assert_truthy(value, message)
    if not value then
        error("Expected truthy value: " .. (message or vim.inspect(value)))
    end
end

-- Assert a string contains a substring
---@param haystack string
---@param needle string
---@param message string|nil
function M.assert_contains(haystack, needle, message)
    if not haystack:find(needle, 1, true) then
        local msg = message and (message .. ": ") or ""
        error(string.format("%sExpected '%s' to contain '%s'", msg, haystack, needle))
    end
end

-- Cleanup function for tests
function M.cleanup()
    -- Clean up any test state
    -- Tests should call this in after_each
end

-- Simple wait helper for tests
function M.wait(ms)
    vim.wait(ms, function() return false end, 10)
end

return M
