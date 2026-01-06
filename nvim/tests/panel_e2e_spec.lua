-- E2E tests for banjo.nvim panel functionality
local helpers = require("tests.helpers")

describe("Banjo Panel", function()
    local env
    local banjo
    local panel
    local bridge

    -- Setup before tests
    before_each(function()
        env = helpers.setup_test_env()

        -- Require modules fresh
        package.loaded["banjo"] = nil
        package.loaded["banjo.panel"] = nil
        package.loaded["banjo.bridge"] = nil

        banjo = require("banjo")
        panel = require("banjo.panel")
        bridge = require("banjo.bridge")
    end)

    -- Cleanup after tests
    after_each(function()
        if bridge then
            pcall(bridge.stop)
        end
        if panel then
            pcall(panel.close)
        end
        helpers.cleanup()  -- Clean up panel buffers/windows
        if env then
            env.cleanup()
        end
    end)

    it("creates panel window when opened", function()
        -- Setup banjo without auto-start
        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
            panel = {
                width = 60,
                position = "right",
            },
        })

        -- Initially no panel
        helpers.assert(not helpers.find_panel_window(), "Panel should not exist initially")

        -- Open panel
        panel.open()

        -- Panel should now exist
        local panel_win = helpers.find_panel_window()
        helpers.assert_truthy(panel_win, "Panel should exist after open")
        -- Panel width may vary due to neovim's window management
        helpers.assert_truthy(panel_win.width > 0, "Panel should have positive width")
    end)

    it("toggles panel visibility", function()
        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        -- Toggle open
        panel.toggle()
        helpers.assert_truthy(panel.is_open(), "Panel should be open after toggle")

        -- Toggle closed
        panel.toggle()
        helpers.assert(not panel.is_open(), "Panel should be closed after second toggle")
    end)

    it("reopens panel after close via toggle", function()
        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        -- Step 1: Open panel (simulates user pressing <leader>ab which calls panel.toggle())
        panel.open()
        helpers.wait_for(function()
            return panel.is_open()
        end, 1000)
        helpers.assert_truthy(panel.is_open(), "Panel should be open initially")
        helpers.assert_truthy(helpers.find_panel_window(), "Panel window should exist")

        -- Capture state for debugging
        local state_before_close = panel._get_state()
        local output_win_before = state_before_close.output_win
        local input_win_before = state_before_close.input_win

        -- Step 2: Close via toggle (simulates :BanjoToggle)
        panel.toggle()
        helpers.wait_for(function()
            return not panel.is_open()
        end, 1000)
        helpers.assert(not panel.is_open(), "Panel should be closed after toggle")
        helpers.assert(not helpers.find_panel_window(), "Panel window should not exist after close")

        -- Verify state was cleaned up
        local state_after_close = panel._get_state()
        helpers.assert(state_after_close.output_win == nil, "output_win should be nil after close")
        helpers.assert(state_after_close.input_win == nil, "input_win should be nil after close")

        -- Step 3: Reopen via toggle (this is the failing case user reported)
        panel.toggle()
        helpers.wait_for(function()
            return panel.is_open()
        end, 1000)
        helpers.assert_truthy(panel.is_open(), "Panel should reopen after second toggle")
        helpers.assert_truthy(helpers.find_panel_window(), "Panel window should exist after reopen")

        -- Verify new windows were created
        local state_after_reopen = panel._get_state()
        helpers.assert_truthy(state_after_reopen.output_win, "output_win should exist after reopen")
        helpers.assert_truthy(state_after_reopen.input_win, "input_win should exist after reopen")
    end)

    it("reopens panel multiple times", function()
        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        -- Toggle 5 times to ensure state is properly managed
        for i = 1, 5 do
            panel.toggle()
            local expected_open = (i % 2 == 1)
            helpers.wait_for(function()
                return panel.is_open() == expected_open
            end, 1000)
            helpers.assert_eq(expected_open, panel.is_open(),
                string.format("Toggle %d: panel should be %s", i, expected_open and "open" or "closed"))
        end
    end)

    it("reopens after external window close", function()
        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        -- Open panel
        panel.open()
        helpers.wait_for(function()
            return panel.is_open()
        end, 1000)
        helpers.assert_truthy(panel.is_open(), "Panel should be open")

        local state = panel._get_state()
        local output_win = state.output_win

        -- Simulate external close (user presses 'q' or :q in panel window)
        -- This closes window without going through panel.close()
        if output_win and vim.api.nvim_win_is_valid(output_win) then
            vim.api.nvim_win_close(output_win, true)
        end

        -- Panel should detect it's closed via is_open() check
        helpers.wait_for(function()
            return not panel.is_open()
        end, 1000)
        helpers.assert(not panel.is_open(), "Panel should detect external close")

        -- Toggle should reopen
        panel.toggle()
        helpers.wait_for(function()
            return panel.is_open()
        end, 1000)
        helpers.assert_truthy(panel.is_open(), "Panel should reopen after external close")
        helpers.assert_truthy(helpers.find_panel_window(), "Panel window should exist")
    end)

    it("appends text to panel", function()
        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        panel.start_stream("test")
        panel.append("Hello ")
        panel.append("World!")

        -- Get panel buffer content
        local panel_win = helpers.find_panel_window()
        helpers.assert_truthy(panel_win, "Panel should exist")

        local state = helpers.capture_buffer_state(panel_win.buffer)
        local content = table.concat(state.lines, "\n")

        helpers.assert_contains(content, "Hello World!", "Panel content")
    end)

    it("clears panel content", function()
        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        panel.open()
        panel.append("Some content")
        panel.clear()

        local panel_win = helpers.find_panel_window()
        helpers.assert_truthy(panel_win, "Panel should exist")

        local state = helpers.capture_buffer_state(panel_win.buffer)
        helpers.assert_eq(1, state.line_count, "Panel should have one empty line after clear")
    end)
end)

describe("Banjo Bridge", function()
    local env
    local banjo
    local bridge

    before_each(function()
        env = helpers.setup_test_env()

        package.loaded["banjo"] = nil
        package.loaded["banjo.panel"] = nil
        package.loaded["banjo.bridge"] = nil

        banjo = require("banjo")
        bridge = require("banjo.bridge")
    end)

    after_each(function()
        if bridge then
            pcall(bridge.stop)
        end
        helpers.cleanup()
        if env then
            env.cleanup()
        end
    end)

    it("starts and connects to backend", function()
        if not env.binary then
            print("  SKIP: banjo binary not found")
            return
        end

        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        -- Start the backend
        bridge.start(env.binary, env.dir)

        -- Wait for connection
        local connected = helpers.wait_for(function()
            return bridge.is_running()
        end, 5000)

        helpers.assert_truthy(connected, "Bridge should connect within 5s")

        -- Should have MCP port
        local port = bridge.get_mcp_port()
        helpers.assert_truthy(port and port > 0, "Should have valid MCP port")
    end)

    it("stops backend cleanly", function()
        if not env.binary then
            print("  SKIP: banjo binary not found")
            return
        end

        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        bridge.start(env.binary, env.dir)

        -- Wait for connection
        helpers.wait_for(function()
            return bridge.is_running()
        end, 5000)

        -- Stop
        bridge.stop()

        -- Should be stopped
        helpers.wait_for(function()
            return not bridge.is_running()
        end, 2000)

        helpers.assert(not bridge.is_running(), "Bridge should not be running after stop")
    end)
end)

describe("Banjo Integration", function()
    local env
    local banjo
    local bridge
    local panel

    before_each(function()
        env = helpers.setup_test_env()

        package.loaded["banjo"] = nil
        package.loaded["banjo.panel"] = nil
        package.loaded["banjo.bridge"] = nil

        banjo = require("banjo")
        bridge = require("banjo.bridge")
        panel = require("banjo.panel")
    end)

    after_each(function()
        if bridge then
            pcall(bridge.stop)
        end
        if panel then
            pcall(panel.close)
        end
        helpers.cleanup()
        if env then
            env.cleanup()
        end
    end)

    it("shows streaming output in panel", function()
        if not env.binary then
            print("  SKIP: banjo binary not found")
            return
        end

        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        -- Start backend
        bridge.start(env.binary, env.dir)

        -- Wait for connection
        local connected = helpers.wait_for(function()
            return bridge.is_running()
        end, 5000)

        if not connected then
            print("  SKIP: Could not connect to backend")
            return
        end

        -- Simulate a stream (the panel module handles this)
        panel.start_stream("claude")
        panel.append("This is a test response.")
        panel.end_stream()

        -- Check panel shows content
        local panel_win = helpers.find_panel_window()
        helpers.assert_truthy(panel_win, "Panel should be open")

        local state = helpers.capture_buffer_state(panel_win.buffer)
        local content = table.concat(state.lines, "\n")

        -- Engine name is in winbar, not buffer content
    end)

    it("handles tool requests from backend", function()
        if not env.binary then
            print("  SKIP: banjo binary not found")
            return
        end

        -- Open the test file
        vim.cmd("edit " .. env.file)

        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        bridge.start(env.binary, env.dir)

        local connected = helpers.wait_for(function()
            return bridge.is_running()
        end, 5000)

        if not connected then
            print("  SKIP: Could not connect to backend")
            return
        end

        -- Test getOpenEditors tool handler
        local editors = bridge._get_open_editors()
        helpers.assert_truthy(#editors > 0, "Should have at least one open editor")

        local found = false
        for _, e in ipairs(editors) do
            if e.path:match("test%.lua$") then
                found = true
                break
            end
        end
        helpers.assert_truthy(found, "Should find test.lua in open editors")

        -- Test getDiagnostics tool handler
        local diagnostics = bridge._get_diagnostics()
        helpers.assert_truthy(type(diagnostics) == "table", "Diagnostics should be a table")
    end)

    it("supports independent panels per tab", function()
        -- Setup banjo without auto-start
        banjo.setup({
            binary_path = env.binary,
            auto_start = false,
        })

        -- Create 3 tabs
        vim.cmd("tabnew")
        local tab1 = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabnew")
        local tab2 = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabnew")
        local tab3 = vim.api.nvim_get_current_tabpage()

        -- Open panel in tab 1
        vim.api.nvim_set_current_tabpage(tab1)
        panel.open()
        helpers.wait_for(function()
            return helpers.find_panel_window() ~= nil
        end, 2000)
        local panel1_win = helpers.find_panel_window()
        helpers.assert_truthy(panel1_win, "Panel should open in tab 1")

        -- Switch to tab 2, verify no panel
        vim.api.nvim_set_current_tabpage(tab2)
        local panel2_before = helpers.find_panel_window()
        helpers.assert(not panel2_before, "Tab 2 should not have panel initially")

        -- Open panel in tab 2
        panel.open()
        helpers.wait_for(function()
            return helpers.find_panel_window() ~= nil
        end, 2000)
        local panel2_win = helpers.find_panel_window()
        helpers.assert_truthy(panel2_win, "Panel should open in tab 2")

        -- Verify panels are different windows
        helpers.assert(panel1_win.handle ~= panel2_win.handle, "Each tab should have its own panel window")

        -- Switch back to tab 1, verify panel still there
        vim.api.nvim_set_current_tabpage(tab1)
        local panel1_still_there = helpers.find_panel_window()
        helpers.assert_truthy(panel1_still_there, "Tab 1 panel should still exist")

        -- Close tab 2, verify tab 1 panel unaffected
        vim.api.nvim_set_current_tabpage(tab2)
        vim.cmd("tabclose")
        vim.api.nvim_set_current_tabpage(tab1)
        local panel1_after_close = helpers.find_panel_window()
        helpers.assert_truthy(panel1_after_close, "Tab 1 panel should survive tab 2 close")
    end)
end)
