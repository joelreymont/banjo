-- Multi-tab tests for Banjo Neovim plugin
-- Tests tab isolation, cleanup, and state management
local helpers = require("tests.helpers")

describe("banjo multi-tab", function()
    local panel
    local bridge

    before_each(function()
        package.loaded["banjo.panel"] = nil
        package.loaded["banjo.bridge"] = nil
        panel = require("banjo.panel")
        bridge = require("banjo.bridge")
        panel.setup({ width = 60, position = "right" })
    end)

    after_each(function()
        -- Close extra tabs
        while #vim.api.nvim_list_tabpages() > 1 do
            vim.cmd("tabclose!")
        end
        helpers.cleanup()
    end)

    describe("tab state isolation", function()
        it("each tab has independent panel state", function()
            local tab1 = vim.api.nvim_get_current_tabpage()
            panel.open()
            helpers.wait(50)
            panel.set_input_text("tab1 input")

            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()
            assert.not_equals(tab1, tab2)

            panel.open()
            helpers.wait(50)
            panel.set_input_text("tab2 input")

            -- Tab 2 should have its own input
            assert.equals("tab2 input", panel.get_input_text())

            -- Switch back to tab 1
            vim.api.nvim_set_current_tabpage(tab1)
            helpers.wait(50)

            -- Tab 1 should still have its input
            assert.equals("tab1 input", panel.get_input_text())
        end)

        it("each tab has independent output buffer", function()
            local tab1 = vim.api.nvim_get_current_tabpage()
            panel.open()
            helpers.wait(50)
            panel.append("Tab 1 content")

            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()
            panel.open()
            helpers.wait(50)
            panel.append("Tab 2 content")

            -- Tab 2 should have its own content
            local buf2 = helpers.get_banjo_buffer()
            local lines2 = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
            local content2 = table.concat(lines2, "\n")
            assert.truthy(content2:find("Tab 2"))
            assert.falsy(content2:find("Tab 1"))

            -- Switch to tab 1
            vim.api.nvim_set_current_tabpage(tab1)
            helpers.wait(50)

            -- Tab 1 should have its own content
            local buf1 = helpers.get_banjo_buffer()
            local lines1 = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
            local content1 = table.concat(lines1, "\n")
            assert.truthy(content1:find("Tab 1"))
            assert.falsy(content1:find("Tab 2"))
        end)
    end)

    describe("TabClosed cleanup", function()
        it("cleans up state when tab is closed", function()
            local tab1 = vim.api.nvim_get_current_tabpage()
            panel.open()
            helpers.wait(50)

            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()
            panel.open()
            helpers.wait(50)

            -- Access internal state to verify cleanup
            local state_before = panel._get_state()
            assert.is_not_nil(state_before.input_buf)

            -- Close tab 2 (current tab)
            vim.cmd("tabclose")
            helpers.wait(100)

            -- Should be back in tab 1
            assert.equals(tab1, vim.api.nvim_get_current_tabpage())

            -- Tab 2's state should be cleaned up
            -- (We can't directly check since we can't access tab2's state anymore,
            -- but we verify tab 1's state is still valid)
            local state_after = panel._get_state()
            assert.is_not_nil(state_after.input_buf)
            assert.is_true(vim.api.nvim_buf_is_valid(state_after.input_buf))
        end)

        it("handles multiple tab closes correctly", function()
            local tab1 = vim.api.nvim_get_current_tabpage()

            -- Create 3 additional tabs
            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()
            panel.open()
            helpers.wait(50)

            vim.cmd("tabnew")
            local tab3 = vim.api.nvim_get_current_tabpage()
            panel.open()
            helpers.wait(50)

            vim.cmd("tabnew")
            panel.open()
            helpers.wait(50)

            -- Close tabs in various order
            vim.cmd("tabclose") -- close tab 4
            helpers.wait(50)
            vim.api.nvim_set_current_tabpage(tab2)
            vim.cmd("tabclose") -- close tab 2
            helpers.wait(50)

            -- Verify remaining tabs work
            vim.api.nvim_set_current_tabpage(tab3)
            helpers.wait(50)
            assert.is_true(panel.is_open())

            vim.api.nvim_set_current_tabpage(tab1)
            helpers.wait(50)
            -- Tab 1 never had panel opened, so should not be open
            assert.is_false(panel.is_open())
        end)
    end)

    describe("buffer recovery", function()
        it("submit_input recovers when input_buf becomes invalid", function()
            panel.open()
            helpers.wait(50)

            local state = panel._get_state()
            local old_input_buf = state.input_buf
            assert.is_not_nil(old_input_buf)
            assert.is_true(vim.api.nvim_buf_is_valid(old_input_buf))

            -- Set some text first
            panel.set_input_text("test input")
            helpers.wait(50)

            -- Forcibly invalidate the buffer (simulate what could happen)
            vim.cmd(string.format("bwipeout! %d", old_input_buf))
            helpers.wait(50)

            -- Buffer should now be invalid
            assert.is_false(vim.api.nvim_buf_is_valid(old_input_buf))

            -- Try to submit - should recover by recreating panel
            -- Note: submit_input will create new panel but won't have text
            panel.submit_input()
            helpers.wait(100)

            -- Panel should have been recreated with valid buffers
            local new_state = panel._get_state()
            assert.is_not_nil(new_state.input_buf, "input_buf should exist after recovery")
            assert.is_true(vim.api.nvim_buf_is_valid(new_state.input_buf), "input_buf should be valid after recovery")
            assert.not_equals(old_input_buf, new_state.input_buf, "should have new buffer after recovery")
        end)
    end)

    describe("tab handle vs number", function()
        it("TabClosed cleanup works regardless of tab position", function()
            -- This test verifies the bug fix: ev.match is tab NUMBER, not handle
            local tab1 = vim.api.nvim_get_current_tabpage()

            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()
            panel.open()
            helpers.wait(50)

            vim.cmd("tabnew")
            local tab3 = vim.api.nvim_get_current_tabpage()
            panel.open()
            helpers.wait(50)

            -- Verify handles are not sequential with positions
            -- Tab positions: 1, 2, 3 but handles could be 1000, 1001, 1002, etc.

            -- Close middle tab (tab2)
            vim.api.nvim_set_current_tabpage(tab2)
            vim.cmd("tabclose")
            helpers.wait(100)

            -- After closing tab2, we should be on tab3 or tab1
            local current = vim.api.nvim_get_current_tabpage()
            assert.truthy(current == tab1 or current == tab3)

            -- Verify tab3's panel still works (if we're on it)
            if current == tab3 then
                assert.is_true(panel.is_open())
                panel.append("Still working after sibling tab closed")
                helpers.wait(50)
                local buf = helpers.get_banjo_buffer()
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                local content = table.concat(lines, "\n")
                assert.truthy(content:find("Still working"))
            end
        end)
    end)
end)
