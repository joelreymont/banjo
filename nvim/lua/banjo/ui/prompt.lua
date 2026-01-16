-- Permission and approval prompts using nui.nvim
local M = {}

local Popup
local has_nui, nui_popup = pcall(require, "nui.popup")
if has_nui then
    Popup = nui_popup
end

-- Format tool input for display (extract meaningful fields, not raw JSON)
local function format_tool_input(name, input_json)
    if not input_json or input_json == "" then
        return nil
    end

    -- Try to parse JSON
    local ok, input = pcall(vim.json.decode, input_json)
    if not ok or type(input) ~= "table" then
        -- Not JSON, return as-is if short
        if #input_json < 200 then
            return input_json
        end
        return input_json:sub(1, 197) .. "..."
    end

    local lines = {}

    -- Bash - show command
    if name == "Bash" then
        if input.command then
            table.insert(lines, "$ " .. input.command)
        end
        if input.description then
            table.insert(lines, "# " .. input.description)
        end
        return #lines > 0 and table.concat(lines, "\n") or nil
    end

    -- Read/Write/Edit - show file path
    if name == "Read" or name == "Write" or name == "Edit" or name == "MultiEdit" then
        if input.file_path then
            table.insert(lines, input.file_path)
        end
        if input.old_string then
            local old = input.old_string
            if #old > 60 then old = old:sub(1, 57) .. "..." end
            table.insert(lines, "- " .. old)
        end
        if input.new_string then
            local new = input.new_string
            if #new > 60 then new = new:sub(1, 57) .. "..." end
            table.insert(lines, "+ " .. new)
        end
        return #lines > 0 and table.concat(lines, "\n") or nil
    end

    -- Glob/Grep - show pattern
    if name == "Glob" or name == "Grep" then
        if input.pattern then
            table.insert(lines, input.pattern)
        end
        if input.path then
            table.insert(lines, "in: " .. input.path)
        end
        return #lines > 0 and table.concat(lines, "\n") or nil
    end

    -- Task - show description
    if name == "Task" then
        if input.description then
            table.insert(lines, input.description)
        end
        return #lines > 0 and table.concat(lines, "\n") or nil
    end

    -- WebFetch/WebSearch - show URL or query
    if name == "WebFetch" or name == "WebSearch" then
        if input.url then
            table.insert(lines, input.url)
        end
        if input.query then
            table.insert(lines, input.query)
        end
        return #lines > 0 and table.concat(lines, "\n") or nil
    end

    -- Default: extract common fields
    if input.file_path then
        table.insert(lines, input.file_path)
    end
    if input.command then
        table.insert(lines, "$ " .. input.command)
    end
    if input.pattern then
        table.insert(lines, input.pattern)
    end

    return #lines > 0 and table.concat(lines, "\n") or nil
end

-- Create a permission/approval prompt
function M.show(opts)
    if not Popup then
        error("banjo.nvim requires nui.nvim for prompts. Install: https://github.com/MunifTanjim/nui.nvim")
    end

    opts = opts or {}
    local title = opts.title or "Prompt"
    local tool_name = opts.tool_name or "unknown"
    local risk_level = opts.risk_level or "medium"
    local content = opts.content or ""
    local actions = opts.actions or {}
    local on_action = opts.on_action or function() end

    -- Determine highlight based on risk
    local hl_group = "NormalFloat"
    local border_hl = "FloatBorder"
    if risk_level == "high" then
        hl_group = "DiagnosticError"
        border_hl = "DiagnosticError"
    elseif risk_level == "medium" then
        hl_group = "DiagnosticWarn"
        border_hl = "DiagnosticWarn"
    end

    -- Build content lines
    local lines = {}
    table.insert(lines, "")
    table.insert(lines, "  Tool: " .. tool_name)
    table.insert(lines, "  Risk: " .. risk_level)
    table.insert(lines, "")

    -- Add content (potentially multi-line)
    if content and content ~= "" then
        for line in content:gmatch("[^\n]+") do
            -- Truncate long lines
            if #line > 60 then
                line = line:sub(1, 57) .. "..."
            end
            table.insert(lines, "  " .. line)
        end
        table.insert(lines, "")
    end

    -- Build action hint line
    local action_hints = {}
    for _, action in ipairs(actions) do
        table.insert(action_hints, string.format("[%s] %s", action.key, action.label))
    end
    table.insert(lines, "  " .. table.concat(action_hints, "  "))
    table.insert(lines, "")

    -- Calculate dimensions
    local max_width = 0
    for _, line in ipairs(lines) do
        max_width = math.max(max_width, #line)
    end
    local width = math.min(math.max(max_width + 4, 40), 80)
    local height = #lines

    local popup = Popup({
        position = "50%",
        size = { width = width, height = height },
        enter = true,
        focusable = true,
        border = {
            style = "rounded",
            text = { top = " " .. title .. " ", top_align = "center" },
            padding = { top = 0, bottom = 0, left = 1, right = 1 },
        },
        win_options = {
            winhl = "Normal:" .. hl_group .. ",FloatBorder:" .. border_hl,
        },
    })
    popup:mount()
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = popup.bufnr })

    -- Highlight tool name and risk
    local ns = vim.api.nvim_create_namespace("banjo_prompt")
    for i, line in ipairs(lines) do
        if line:find("Tool:") then
            vim.api.nvim_buf_add_highlight(popup.bufnr, ns, "Special", i - 1, 2, 8)
        elseif line:find("Risk:") then
            local risk_hl = "Normal"
            if risk_level == "high" then
                risk_hl = "DiagnosticError"
            elseif risk_level == "medium" then
                risk_hl = "DiagnosticWarn"
            else
                risk_hl = "DiagnosticOk"
            end
            vim.api.nvim_buf_add_highlight(popup.bufnr, ns, "Special", i - 1, 2, 8)
            vim.api.nvim_buf_add_highlight(popup.bufnr, ns, risk_hl, i - 1, 8, -1)
        end
    end

    -- Setup keymaps
    local function close_and_act(action_name)
        popup:unmount()
        on_action(action_name)
    end

    for _, action in ipairs(actions) do
        vim.keymap.set("n", action.key, function()
            close_and_act(action.name)
        end, { buffer = popup.bufnr, nowait = true })
        -- Also map uppercase
        vim.keymap.set("n", action.key:upper(), function()
            close_and_act(action.name)
        end, { buffer = popup.bufnr, nowait = true })
    end

    -- Escape/q to dismiss (default action)
    local default_action = opts.default_action or (actions[#actions] and actions[#actions].name) or "cancel"
    vim.keymap.set("n", "<Esc>", function() close_and_act(default_action) end, { buffer = popup.bufnr, nowait = true })
    vim.keymap.set("n", "q", function() close_and_act(default_action) end, { buffer = popup.bufnr, nowait = true })

    return popup
end

-- Approval prompt (Codex style: accept/decline/cancel)
function M.approval(opts)
    -- Format arguments for display (not raw JSON)
    local formatted = format_tool_input(opts.tool_name, opts.arguments)

    return M.show({
        title = "APPROVAL REQUIRED",
        tool_name = opts.tool_name,
        risk_level = opts.risk_level or "high",
        content = formatted,
        actions = {
            { key = "y", label = "Accept", name = "accept" },
            { key = "a", label = "Always", name = "acceptForSession" },
            { key = "d", label = "Decline", name = "decline" },
            { key = "c", label = "Cancel", name = "cancel" },
        },
        default_action = "decline",
        on_action = opts.on_action,
    })
end

-- Permission prompt (Claude style: allow/always/deny)
function M.permission(opts)
    -- Determine risk based on tool
    local risk_level = "medium"
    local high_risk = { Bash = true, Write = true, Edit = true, MultiEdit = true }
    local low_risk = { Read = true, Glob = true, Grep = true, LSP = true }
    if high_risk[opts.tool_name] then
        risk_level = "high"
    elseif low_risk[opts.tool_name] then
        risk_level = "low"
    end

    -- Format tool_input for display (not raw JSON)
    local formatted = format_tool_input(opts.tool_name, opts.tool_input)

    -- Build actions from ACP options if provided, otherwise use defaults
    local actions
    if opts.options and #opts.options > 0 then
        actions = {}
        local keys = { "y", "a", "n", "x" }
        for i, opt in ipairs(opts.options) do
            local key = keys[i] or tostring(i)
            table.insert(actions, {
                key = key,
                label = opt.name or opt.optionId,
                name = opt.optionId or opt.kind or "allow",
            })
        end
    else
        actions = {
            { key = "y", label = "Allow", name = "allow" },
            { key = "a", label = "Always", name = "allow_always" },
            { key = "n", label = "Deny", name = "deny" },
        }
    end

    return M.show({
        title = "PERMISSION REQUEST",
        tool_name = opts.tool_name,
        risk_level = risk_level,
        content = formatted,
        actions = actions,
        default_action = "deny",
        on_action = function(action)
            if opts.on_action then
                -- Pass both the action name and the original optionId
                opts.on_action(action, action)
            end
        end,
    })
end

return M
