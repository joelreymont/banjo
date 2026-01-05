-- Banjo panel: display streaming output in a side panel
local M = {}

local buf = nil
local win = nil
local ns_id = vim.api.nvim_create_namespace("banjo")
local is_streaming = false
local current_engine = nil

local config = {
    width = 80,
    position = "right", -- "left" or "right"
    title = " Banjo ",
}

function M.setup(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})
end

local function create_buffer()
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end

    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
    vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
    vim.api.nvim_buf_set_name(buf, "Banjo")

    return buf
end

local function create_window()
    if win and vim.api.nvim_win_is_valid(win) then
        return win
    end

    create_buffer()

    local cmd = config.position == "left" and "topleft" or "botright"
    vim.cmd(cmd .. " " .. config.width .. "vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    -- Window options
    vim.api.nvim_set_option_value("wrap", true, { win = win })
    vim.api.nvim_set_option_value("linebreak", true, { win = win })
    vim.api.nvim_set_option_value("number", false, { win = win })
    vim.api.nvim_set_option_value("relativenumber", false, { win = win })
    vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
    vim.api.nvim_set_option_value("winfixwidth", true, { win = win })

    -- Return focus to previous window
    vim.cmd("wincmd p")

    return win
end

function M.open()
    create_window()
end

function M.close()
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
        win = nil
    end
end

function M.toggle()
    if win and vim.api.nvim_win_is_valid(win) then
        M.close()
    else
        M.open()
    end
end

function M.is_open()
    return win and vim.api.nvim_win_is_valid(win)
end

function M.clear()
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    end
end

function M.start_stream(engine)
    is_streaming = true
    current_engine = engine or "claude"

    create_buffer()
    create_window()

    -- Add header
    local header = "## " .. current_engine:upper() .. " Response"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { header, "" })
end

function M.end_stream()
    is_streaming = false
    current_engine = nil

    if buf and vim.api.nvim_buf_is_valid(buf) then
        -- Add separator
        local line_count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "", "---", "" })
    end
end

function M.append(text, is_thought)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        create_buffer()
    end

    if not text or text == "" then
        return
    end

    -- Split text into lines
    local lines = vim.split(text, "\n", { plain = true })

    local line_count = vim.api.nvim_buf_line_count(buf)
    local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""

    -- Append first line to last line
    if #lines > 0 then
        vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { last_line .. lines[1] })
    end

    -- Append remaining lines
    if #lines > 1 then
        vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, vim.list_slice(lines, 2))
    end

    -- Highlight thoughts in italics
    if is_thought then
        local start_line = line_count - 1
        local end_line = vim.api.nvim_buf_line_count(buf)
        for i = start_line, end_line - 1 do
            vim.api.nvim_buf_add_highlight(buf, ns_id, "Comment", i, 0, -1)
        end
    end

    -- Scroll to bottom if window is open
    if win and vim.api.nvim_win_is_valid(win) then
        local new_line_count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_win_set_cursor(win, { new_line_count, 0 })
    end
end

function M.tool_call(params)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local line = string.format("> **%s** `%s`", params.name, params.label)
    local line_count = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { "", line })
end

function M.tool_result(params)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local status_icon = params.status == "completed" and "+" or (params.status == "failed" and "x" or "...")
    local line = string.format("> [%s] %s", status_icon, params.id)
    local line_count = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, { line })
end

return M
