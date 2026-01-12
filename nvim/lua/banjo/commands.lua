-- Banjo slash command parser and registry
local M = {}

-- Command registry: name -> handler function
local registry = {}

-- Built-in command handlers

local function cmd_help(args, context)
    local panel = context.panel
    if not panel then return end

    local help_text = {
        "Available commands:",
        "  /help - Show this help",
        "  /clear - Clear output buffer",
        "  /new - Start new session",
        "  /cancel - Cancel current request",
        "  /model <name> - Set model (claude: opus/sonnet/haiku, codex: o3/o4-mini/gpt-4.1)",
        "  /mode <name> - Set permission mode (default, accept_edits, auto_approve, plan_only)",
        "  /agent <name> - Switch agent (claude, codex)",
        "  /sessions - List saved sessions",
        "  /load <id> - Restore a saved session",
        "  /project <path> - Open project in new tab",
        "",
        "Keybinds:",
        "  <CR> - Submit input",
        "  <S-CR> - Insert newline (insert mode)",
        "  <C-c> - Cancel request",
        "  <Tab> - Complete slash command (insert mode)",
        "  <Up>/<Down> - Navigate input history",
        "  <Esc> - Leave insert mode and focus output",
        "  i - Focus input (from output)",
        "  q - Close panel (from output)",
        "  z - Toggle fold at cursor (from output)",
    }

    for _, line in ipairs(help_text) do
        panel.append_status(line)
    end
end

local function cmd_clear(args, context)
    local panel = context.panel
    if not panel then return end

    panel.clear()
end

local function cmd_new(args, context)
    local bridge = context.bridge
    local panel = context.panel

    if bridge and bridge.cancel then
        bridge.cancel()
    end

    if panel then
        panel.clear()
        panel.append_status("Starting new session...")
    end

    -- Backend will start new session on next prompt
end

local function cmd_cancel(args, context)
    local bridge = context.bridge
    local panel = context.panel

    if bridge and bridge.cancel then
        bridge.cancel()
        if panel then
            panel.append_status("Cancelled")
        end
    else
        if panel then
            panel.append_status("Not connected")
        end
    end
end

-- Valid models per engine
local claude_models = { opus = true, sonnet = true, haiku = true }
local codex_models = { o3 = true, ["o4-mini"] = true, ["gpt-4.1"] = true }

local function cmd_model(args, context)
    local bridge = context.bridge
    local panel = context.panel

    local engine = bridge and bridge.get_state and bridge.get_state().engine or "claude"
    local valid_models = engine == "codex" and codex_models or claude_models
    local model_list = engine == "codex" and "o3, o4-mini, gpt-4.1" or "opus, sonnet, haiku"

    if not args or args == "" then
        if panel then
            panel.append_status("Usage: /model <" .. model_list .. ">")
        end
        return
    end

    local model = args:lower()
    if not valid_models[model] then
        if panel then
            panel.append_status("Invalid model. Use: " .. model_list)
        end
        return
    end

    if bridge and bridge.set_model then
        bridge.set_model(model)
        if panel then
            panel.append_status("Model: " .. model)
            panel._update_status()
        end
    else
        if panel then
            panel.append_status("Not connected")
        end
    end
end

local function cmd_mode(args, context)
    local bridge = context.bridge
    local panel = context.panel

    if not args or args == "" then
        if panel then
            panel.append_status("Usage: /mode <default|accept_edits|auto_approve|plan_only>")
        end
        return
    end

    local mode = args:lower()
    if mode ~= "default" and mode ~= "accept_edits" and mode ~= "auto_approve" and mode ~= "plan_only" then
        if panel then
            panel.append_status("Invalid mode. Use: default, accept_edits, auto_approve, or plan_only")
        end
        return
    end

    if bridge and bridge.set_permission_mode then
        bridge.set_permission_mode(mode)
        if panel then
            panel.append_status("Mode: " .. mode)
            panel._update_status()
        end
    else
        if panel then
            panel.append_status("Not connected")
        end
    end
end

local function cmd_agent(args, context)
    local bridge = context.bridge
    local panel = context.panel

    if not args or args == "" then
        if panel then
            panel.append_status("Usage: /agent <claude|codex>")
        end
        return
    end

    local agent = args:lower()
    if agent ~= "claude" and agent ~= "codex" then
        if panel then
            panel.append_status("Invalid agent. Use: claude or codex")
        end
        return
    end

    if bridge and bridge.set_engine then
        bridge.set_engine(agent)
        if panel then
            panel.append_status("Agent: " .. agent)
            panel._update_status()
        end
    else
        if panel then
            panel.append_status("Not connected")
        end
    end
end

local function cmd_sessions(args, context)
    local panel = context.panel
    if not panel then return end

    local sessions = require("banjo.sessions")
    local list = sessions.list()

    if #list == 0 then
        panel.append_status("No saved sessions")
        return
    end

    panel.append_status("Saved sessions:")
    for _, session in ipairs(list) do
        local time = os.date("%Y-%m-%d %H:%M:%S", session.timestamp)
        panel.append_status(string.format("  %s - %s", session.id, time))
    end
end

local function cmd_load(args, context)
    local panel = context.panel
    if not panel then return end

    if not args or args == "" then
        panel.append_status("Usage: /load <session_id>")
        return
    end

    local sessions = require("banjo.sessions")
    local data = sessions.load(args)

    if not data then
        panel.append_status(string.format("Session not found: %s", args))
        return
    end

    -- Restore input text
    if data.input_text then
        panel.set_input_text(data.input_text)
    end

    panel.append_status(string.format("Loaded session: %s", args))
end

local function cmd_project(args, context)
    local panel = context.panel

    if not args or args == "" then
        if panel then
            panel.append_status("Usage: /project <path>")
        end
        return
    end

    local banjo = require("banjo")
    banjo.open_project(args)
end

-- Parse input text into command and arguments
-- Returns: {cmd = string, args = string} or nil if not a command
function M.parse(text)
    if not text or text == "" then
        return nil
    end

    text = vim.trim(text)

    if not vim.startswith(text, "/") then
        return nil
    end

    -- Remove leading slash
    local rest = text:sub(2)

    -- Split into command and args
    local space_idx = rest:find("%s")
    if space_idx then
        local cmd = rest:sub(1, space_idx - 1)
        local args = vim.trim(rest:sub(space_idx + 1))
        return { cmd = cmd, args = args }
    else
        return { cmd = rest, args = "" }
    end
end

-- Register a command handler
-- handler receives (args, context) where context has {bridge, panel}
function M.register(name, handler)
    registry[name] = handler
end

-- Register built-in commands
M.register("help", cmd_help)
M.register("clear", cmd_clear)
M.register("new", cmd_new)
M.register("cancel", cmd_cancel)
M.register("model", cmd_model)
M.register("mode", cmd_mode)
M.register("agent", cmd_agent)
M.register("sessions", cmd_sessions)
M.register("load", cmd_load)
M.register("project", cmd_project)

-- Dispatch a command
-- Returns: true if handled locally, false if should forward to backend
function M.dispatch(cmd, args, context)
    local handler = registry[cmd]
    if handler then
        handler(args, context)
        return true
    end
    return false
end

-- Get list of registered commands (for completion)
function M.list_commands()
    local cmds = {}
    for name, _ in pairs(registry) do
        table.insert(cmds, name)
    end
    table.sort(cmds)
    return cmds
end

return M
