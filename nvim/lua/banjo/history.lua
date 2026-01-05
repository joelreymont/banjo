-- Banjo input history ring buffer
local M = {}

local max_entries = 50
local entries = {}
local history_file = vim.fn.stdpath("data") .. "/banjo_history.json"

-- Add entry to history
function M.add(text)
    if not text or text == "" or vim.trim(text) == "" then
        return
    end

    -- Don't add duplicates of the last entry
    if #entries > 0 and entries[#entries] == text then
        return
    end

    -- Add to end
    table.insert(entries, text)

    -- Trim if over limit
    if #entries > max_entries then
        table.remove(entries, 1)
    end
end

-- Get entry at offset from end (0 = most recent, 1 = second most recent, etc)
function M.get(offset)
    offset = offset or 0
    local idx = #entries - offset

    if idx < 1 or idx > #entries then
        return nil
    end

    return entries[idx]
end

-- Get number of entries
function M.size()
    return #entries
end

-- Get all entries (for session persistence)
function M.get_all()
    -- Return a copy to prevent external modification
    local copy = {}
    for i, entry in ipairs(entries) do
        copy[i] = entry
    end
    return copy
end

-- Clear all history
function M.clear()
    entries = {}
end

-- Save history to disk
function M.save()
    local ok, json = pcall(vim.fn.json_encode, entries)
    if not ok then
        return
    end

    local file = io.open(history_file, "w")
    if file then
        file:write(json)
        file:close()
    end
end

-- Load history from disk
function M.load()
    local file = io.open(history_file, "r")
    if not file then
        return
    end

    local content = file:read("*a")
    file:close()

    local ok, data = pcall(vim.fn.json_decode, content)
    if ok and type(data) == "table" then
        entries = data
    end
end

return M
