-- Simple E2E test that can run without plenary
-- Usage: nvim --headless -u tests/minimal_init.lua -l tests/simple_e2e.lua

local passed = 0
local failed = 0

local function log(msg)
    print("[e2e] " .. msg)
end

local function pass(name)
    passed = passed + 1
    log("  ✓ " .. name)
end

local function fail(name, detail)
    failed = failed + 1
    log("  ✗ " .. name)
    if detail then
        log("    " .. detail)
    end
end

local function wait_for(condition, timeout_ms)
    timeout_ms = timeout_ms or 5000
    local start = vim.loop.now()
    while vim.loop.now() - start < timeout_ms do
        vim.wait(100, function() return condition() end, 100)
        if condition() then return true end
        vim.loop.run("nowait")
    end
    return false
end

local function find_prompt_window(match_text)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local config = vim.api.nvim_win_get_config(win)
        if config.relative and config.relative ~= "" then
            local buf = vim.api.nvim_win_get_buf(win)
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local content = table.concat(lines, "\n")
            if content:find(match_text, 1, true) then
                return win, buf, content
            end
        end
    end
    return nil
end

local function wait_for_prompt(match_text, timeout_ms)
    local win, buf, content
    local ok = wait_for(function()
        win, buf, content = find_prompt_window(match_text)
        return win ~= nil
    end, timeout_ms)
    return ok, win, buf, content
end

local function close_prompt(win, buf)
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

log("Starting comprehensive e2e test")
log("Binary: " .. (vim.g.banjo_test_binary or "NOT FOUND"))

if not vim.g.banjo_test_binary then
    log("ERROR: banjo binary not found")
    vim.cmd("cq")
    return
end

-- Create test directory
local test_dir = vim.fn.tempname() .. "_banjo_e2e"
vim.fn.mkdir(test_dir, "p")
log("Test dir: " .. test_dir)

-- Load banjo
local banjo = require("banjo")
local bridge = require("banjo.bridge")
local panel = require("banjo.panel")

-- Setup
banjo.setup({
    binary_path = vim.g.banjo_test_binary,
    auto_start = false,
    panel = { width = 60 },
})

log("")
log("=== Panel Tests ===")

-- Test 1: Panel opens with split layout
log("Test 1: Panel opens with split layout...")
panel.open()

local output_win = panel.get_output_win()
local input_win = panel.get_input_win()

if output_win and vim.api.nvim_win_is_valid(output_win) then
    pass("Output window created")
else
    fail("Output window NOT created")
end

if input_win and vim.api.nvim_win_is_valid(input_win) then
    pass("Input window created")
else
    fail("Input window NOT created")
end

-- Verify window layout (input should be below output)
if output_win and input_win then
    local out_pos = vim.api.nvim_win_get_position(output_win)
    local in_pos = vim.api.nvim_win_get_position(input_win)
    if in_pos[1] > out_pos[1] then
        pass("Input window is below output window")
    else
        fail("Window layout incorrect", "output row: " .. out_pos[1] .. ", input row: " .. in_pos[1])
    end
end

-- Test 2: Buffer names
log("Test 2: Buffer names...")
local output_buf = panel.get_output_buf()
local input_buf = panel.get_input_buf()

if output_buf then
    local name = vim.api.nvim_buf_get_name(output_buf)
    if name:match("Banjo$") then
        pass("Output buffer name is 'Banjo'")
    else
        fail("Output buffer name incorrect", "got: " .. name)
    end
end

if input_buf then
    local name = vim.api.nvim_buf_get_name(input_buf)
    if name:match("BanjoInput$") then
        pass("Input buffer name is 'BanjoInput'")
    else
        fail("Input buffer name incorrect", "got: " .. name)
    end
end

-- Test 3: Panel toggle
log("Test 3: Panel toggle...")
panel.close()
if not panel.is_open() then
    pass("Panel closes")
else
    fail("Panel did not close")
end
panel.toggle()
if panel.is_open() then
    pass("Panel toggles open")
else
    fail("Panel did not toggle open")
end

-- Test 4: Input text handling
log("Test 4: Input text handling...")
panel.set_input_text("Hello test")
local text = panel.get_input_text()
if text == "Hello test" then
    pass("Input text set and retrieved correctly")
else
    fail("Input text mismatch", "expected 'Hello test', got '" .. text .. "'")
end

-- Test 5: Multi-line input
log("Test 5: Multi-line input...")
panel.set_input_text("Line 1\nLine 2\nLine 3")
local multi_text = panel.get_input_text()
if multi_text:find("Line 1") and multi_text:find("Line 2") and multi_text:find("Line 3") then
    pass("Multi-line input works")
else
    fail("Multi-line input failed", "got: " .. multi_text)
end

-- Test 6: User message display
log("Test 6: User message display...")
panel.clear()
panel.append_user_message("User prompt here")

local lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
local content = table.concat(lines, "\n")
if content:find("User prompt here") then
    pass("User message displays correctly")
else
    fail("User message display incorrect", "got: " .. content:sub(1, 100))
end

-- Test 7: Streaming response
log("Test 7: Streaming response...")
panel.clear()
panel.start_stream("claude")
panel.append("Hello ")
panel.append("from ")
panel.append("stream!")
panel.end_stream()

lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
content = table.concat(lines, "\n")
if content:find("Hello from stream!") then
    pass("Streaming response displays correctly")
else
    fail("Streaming response incorrect", "got: " .. content:sub(1, 150))
end

-- Test 8: Tool call display
log("Test 8: Tool call display...")
panel.clear()
panel.show_tool_call("Read", "/path/to/file.txt")

lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
content = table.concat(lines, "\n")
if content:find("Read") and content:find("file.txt") then
    pass("Tool call displays correctly")
else
    fail("Tool call display incorrect", "got: " .. content)
end

-- Test 9: Tool result update
log("Test 9: Tool result update...")
panel.show_tool_result("file.txt", "completed")
lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
content = table.concat(lines, "\n")
if content:find("✓") then
    pass("Tool result shows completion icon")
else
    fail("Tool result icon incorrect", "got: " .. content)
end

-- Test 10: Status message
log("Test 10: Status message...")
panel.clear()
panel.append_status("Connected to server")
lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
content = table.concat(lines, "\n")
if content:find("Connected to server") then
    pass("Status message displays")
else
    fail("Status message incorrect", "got: " .. content)
end

log("")
log("=== Backend Tests ===")

-- Test 11: Start backend
log("Test 11: Start backend...")
bridge.start(vim.g.banjo_test_binary, test_dir)

local connected = wait_for(function()
    return bridge.is_running()
end, 10000)

if connected then
    pass("Backend connected")
    log("    MCP port: " .. (bridge.get_mcp_port() or "nil"))
else
    fail("Backend failed to connect within 10s")
    bridge.stop()
    vim.fn.delete(test_dir, "rf")
    log("")
    log(string.format("Results: %d passed, %d failed", passed, failed))
    vim.cmd("cq")
    return
end

-- Test 12: Tool handlers
log("Test 12: Tool handlers...")
local editors = bridge._get_open_editors()
if type(editors) == "table" then
    pass("getOpenEditors returns table (" .. #editors .. " editors)")
else
    fail("getOpenEditors failed")
end

local diags = bridge._get_diagnostics()
if type(diags) == "table" then
    pass("getDiagnostics returns table")
else
    fail("getDiagnostics failed")
end

local dirty = bridge._check_dirty("/nonexistent/file.txt")
if dirty and dirty.isDirty == false then
    pass("checkDocumentDirty returns correct structure")
else
    fail("checkDocumentDirty failed")
end

local selection = bridge._get_current_selection()
if selection and selection.file ~= nil then
    pass("getCurrentSelection returns correct structure")
else
    fail("getCurrentSelection failed")
end

-- Test 13: Message handling
log("Test 13: Message handling...")
panel.clear()

-- Simulate incoming messages
bridge._handle_message({
    method = "stream_start",
    params = { engine = "test" }
})
bridge._handle_message({
    method = "stream_chunk",
    params = { text = "Backend message" }
})
bridge._handle_message({
    method = "stream_end",
    params = {}
})

lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
content = table.concat(lines, "\n")
if content:find("Backend message") then
    pass("Message handling works end-to-end")
else
    fail("Message handling failed", "got: " .. content:sub(1, 100))
end

-- Test 13b: Approval prompt rendering
log("Test 13b: Approval prompt rendering...")
bridge._handle_message({
    method = "approval_request",
    params = { id = "appr-1", tool_name = "Bash", risk_level = "high", arguments = "ls -la" }
})
local ok, win, buf, prompt = wait_for_prompt("APPROVAL REQUIRED", 2000)
if ok and prompt and prompt:find("Bash", 1, true) then
    pass("Approval prompt renders with tool name")
else
    fail("Approval prompt not shown")
end
close_prompt(win, buf)

-- Test 13c: Permission prompt rendering
log("Test 13c: Permission prompt rendering...")
bridge._handle_message({
    method = "permission_request",
    params = { id = "perm-1", tool_name = "Read", tool_input = "README.md" }
})
ok, win, buf, prompt = wait_for_prompt("PERMISSION REQUEST", 2000)
if ok and prompt and prompt:find("Read", 1, true) then
    pass("Permission prompt renders with tool name")
else
    fail("Permission prompt not shown")
end
close_prompt(win, buf)

-- Test 13d: error_msg notifications
log("Test 13d: error_msg notifications...")
local notify_calls = {}
local orig_notify = vim.notify
vim.notify = function(message, level, opts)
    table.insert(notify_calls, { message = message, level = level, opts = opts })
end
bridge._handle_message({
    method = "error_msg",
    params = { message = "Auth required" }
})
vim.notify = orig_notify
local found = false
for _, entry in ipairs(notify_calls) do
    if entry.message:find("Auth required", 1, true) and entry.level == vim.log.levels.ERROR then
        found = true
        break
    end
end
if found then
    pass("error_msg triggers error notification")
else
    fail("error_msg did not notify")
end

-- Test 14: Window focus handling
log("Test 14: Window focus handling...")
-- Refresh window handles after toggle
local cur_input_win = panel.get_input_win()
local cur_output_win = panel.get_output_win()

panel.focus_input()
if cur_input_win and vim.api.nvim_get_current_win() == cur_input_win then
    pass("focus_input switches to input window")
else
    fail("focus_input did not switch to input window", "expected: " .. tostring(cur_input_win) .. ", got: " .. tostring(vim.api.nvim_get_current_win()))
end

panel.focus_output()
if cur_output_win and vim.api.nvim_get_current_win() == cur_output_win then
    pass("focus_output switches to output window")
else
    fail("focus_output did not switch to output window", "expected: " .. tostring(cur_output_win) .. ", got: " .. tostring(vim.api.nvim_get_current_win()))
end

log("")
log("=== State Protocol Tests ===")

-- Test 15: get_state
log("Test 15: get_state...")
local initial_state = bridge.get_state()
if initial_state and initial_state.engine then
    pass("get_state returns state object with engine: " .. initial_state.engine)
else
    fail("get_state did not return valid state")
end

-- Test 16: set_engine
log("Test 16: set_engine...")
bridge.set_engine("codex")
wait_for(function()
    local st = bridge.get_state()
    return st and st.engine == "codex"
end, 2000)
local state_after_engine = bridge.get_state()
if state_after_engine and state_after_engine.engine == "codex" then
    pass("set_engine changed engine to codex")
else
    fail("set_engine did not change engine", "got: " .. tostring(state_after_engine and state_after_engine.engine))
end
-- Reset to claude
bridge.set_engine("claude")
wait_for(function()
    local st = bridge.get_state()
    return st and st.engine == "claude"
end, 2000)

-- Test 17: set_model
log("Test 17: set_model...")
bridge.set_model("opus")
wait_for(function()
    local st = bridge.get_state()
    return st and st.model == "opus"
end, 2000)
local state_after_model = bridge.get_state()
if state_after_model and state_after_model.model == "opus" then
    pass("set_model changed model to opus")
else
    fail("set_model did not change model", "got: " .. tostring(state_after_model and state_after_model.model))
end

-- Test 18: set_permission_mode
log("Test 18: set_permission_mode...")
bridge.set_permission_mode("auto_approve")
wait_for(function()
    local st = bridge.get_state()
    return st and st.mode == "Auto-approve"
end, 2000)
local state_after_mode = bridge.get_state()
if state_after_mode and state_after_mode.mode == "Auto-approve" then
    pass("set_permission_mode changed mode to Auto-approve")
else
    fail("set_permission_mode did not change mode", "got: " .. tostring(state_after_mode and state_after_mode.mode))
end

-- Reset to default
bridge.set_permission_mode("default")
wait_for(function()
    local st = bridge.get_state()
    return st and st.mode == "Default"
end, 2000)

log("")
log("=== Markdown Rendering Tests ===")

-- Test 19: Markdown headers
log("Test 19: Markdown headers...")
panel.clear()
panel.append("# Header 1\n## Header 2\n")
lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
content = table.concat(lines, "\n")
if content:find("# Header 1") and content:find("## Header 2") then
    pass("Markdown headers render")
else
    fail("Markdown headers failed", "got: " .. content)
end

-- Test 20: Markdown lists
log("Test 20: Markdown lists...")
panel.clear()
panel.append("- Item 1\n- Item 2\n* Item 3\n")
lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
content = table.concat(lines, "\n")
-- Lists now use virtual text overlays, so buffer preserves original - and *
if content:find("%-") and content:find("%*") then
    pass("Markdown lists detected (using virtual text overlays)")
else
    fail("Markdown lists failed", "got: " .. content)
end

-- Test 21: Code blocks
log("Test 21: Code blocks...")
panel.clear()
panel.append("```lua\nlocal x = 1\n```\n")
lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
content = table.concat(lines, "\n")
if content:find("lua") and content:find("local x = 1") then
    pass("Code blocks render")
else
    fail("Code blocks failed", "got: " .. content)
end

-- Test 22: Thought blocks with folding
log("Test 22: Thought blocks with folding...")
panel.clear()
panel.append("<think>This is a thought</think>\n")
lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
content = table.concat(lines, "\n")
if content:find("think") then
    pass("Thought blocks detected")
else
    fail("Thought blocks failed", "got: " .. content)
end

log("")
log("=== Slash Command Tests ===")

-- Test 23: /clear command
log("Test 23: /clear command...")
panel.append("Test content")
local commands = require("banjo.commands")
commands.dispatch("clear", "", { panel = panel, bridge = bridge })
lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
if #lines <= 1 or (lines[1] == "" and #lines == 1) then
    pass("/clear clears output")
else
    fail("/clear failed", "buffer has " .. #lines .. " lines")
end

-- Test 24: /help command
log("Test 24: /help command...")
panel.clear()
commands.dispatch("help", "", { panel = panel, bridge = bridge })
lines = vim.api.nvim_buf_get_lines(output_buf, 0, -1, false)
content = table.concat(lines, "\n")
if content:find("/help") and content:find("/clear") and content:find("/model") then
    pass("/help displays command list")
else
    fail("/help failed", "got: " .. content:sub(1, 100))
end

-- Test 25: /model command
log("Test 25: /model command...")
panel.clear()
commands.dispatch("model", "haiku", { panel = panel, bridge = bridge })
wait_for(function()
    local st = bridge.get_state()
    return st and st.model == "haiku"
end, 2000)
local state = bridge.get_state()
if state and state.model == "haiku" then
    pass("/model sets model to haiku")
else
    fail("/model failed", "model: " .. tostring(state and state.model))
end

-- Test 26: /mode command
log("Test 26: /mode command...")
commands.dispatch("mode", "accept_edits", { panel = panel, bridge = bridge })
wait_for(function()
    local st = bridge.get_state()
    return st and st.mode == "Accept Edits"
end, 2000)
state = bridge.get_state()
if state and state.mode == "Accept Edits" then
    pass("/mode sets mode to Accept Edits")
else
    fail("/mode failed", "mode: " .. tostring(state and state.mode))
end
-- Reset to default
commands.dispatch("mode", "default", { panel = panel, bridge = bridge })
wait_for(function()
    local st = bridge.get_state()
    return st and st.mode == "Default"
end, 2000)

-- Test 27: /agent command
log("Test 27: /agent command...")
commands.dispatch("agent", "codex", { panel = panel, bridge = bridge })
wait_for(function()
    local st = bridge.get_state()
    return st and st.engine == "codex"
end, 2000)
state = bridge.get_state()
if state and state.engine == "codex" then
    pass("/agent sets engine to codex")
else
    fail("/agent failed", "engine: " .. tostring(state and state.engine))
end
-- Reset to claude
commands.dispatch("agent", "claude", { panel = panel, bridge = bridge })
wait_for(function()
    local st = bridge.get_state()
    return st and st.engine == "claude"
end, 2000)

-- Cleanup
log("")
log("Cleaning up...")
bridge.stop()
wait_for(function() return not bridge.is_running() end, 2000)
panel.close()
vim.fn.delete(test_dir, "rf")

log("")
log(string.format("=== Results: %d passed, %d failed ===", passed, failed))

if failed > 0 then
    vim.cmd("cq")
else
    vim.cmd("qa!")
end
