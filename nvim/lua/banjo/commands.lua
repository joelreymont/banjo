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
        "  /model <name> - Set model (opus, sonnet, haiku)",
        "  /mode <name> - Set permission mode (default, accept_edits, auto_approve, plan_only)",
        "  /route <engine> - Switch engine (claude, codex)",
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
    }

    for _, line in ipairs(help_text) do
        panel.append_status(line)
    end
end

local function cmd_clear(args, context)
    local panel = context.panel
    if panel then
        panel.clear()
    end
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

local function cmd_model(args, context)
    local bridge = context.bridge
    local panel = context.panel

    if not args or args == "" then
        if panel then
            panel.append_status("Usage: /model <opus|sonnet|haiku>")
        end
        return
    end

    local model = args:lower()
    if model ~= "opus" and model ~= "sonnet" and model ~= "haiku" then
        if panel then
            panel.append_status("Invalid model. Use: opus, sonnet, or haiku")
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

local function cmd_route(args, context)
    local bridge = context.bridge
    local panel = context.panel

    if not args or args == "" then
        if panel then
            panel.append_status("Usage: /route <claude|codex>")
        end
        return
    end

    local engine = args:lower()
    if engine ~= "claude" and engine ~= "codex" then
        if panel then
            panel.append_status("Invalid engine. Use: claude or codex")
        end
        return
    end

    if bridge and bridge.set_engine then
        bridge.set_engine(engine)
        if panel then
            panel.append_status("Engine: " .. engine)
            panel._update_status()
        end
    else
        if panel then
            panel.append_status("Not connected")
        end
    end
end

-- Register built-in commands
M.register("help", cmd_help)
M.register("clear", cmd_clear)
M.register("new", cmd_new)
M.register("cancel", cmd_cancel)
M.register("model", cmd_model)
M.register("mode", cmd_mode)
M.register("route", cmd_route)

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
