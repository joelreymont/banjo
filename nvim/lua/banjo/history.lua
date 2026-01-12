-- Banjo input history ring buffer (per-instance)
local M = {}
M.__index = M

local max_entries = 50
local history_dir = vim.fn.stdpath("data") .. "/banjo"

-- Create a new history instance for a given cwd
function M.new(cwd)
    local self = setmetatable({}, M)
    self.entries = {}
    self.cwd = cwd
    self.offset = 0
    self.temp_input = ""
    return self
end

-- Get history file path for this instance's cwd
function M:get_file_path()
    -- Hash cwd to create a unique filename
    local hash = vim.fn.sha256(self.cwd):sub(1, 16)
    return history_dir .. "/history_" .. hash .. ".json"
end

-- Add entry to history
function M:add(text)
    if not text or text == "" or vim.trim(text) == "" then
        return
    end

    -- Don't add duplicates of the last entry
    if #self.entries > 0 and self.entries[#self.entries] == text then
        return
    end

    -- Add to end
    table.insert(self.entries, text)

    -- Trim if over limit
    if #self.entries > max_entries then
        table.remove(self.entries, 1)
    end

    self:save()
end

-- Get entry at offset from end (0 = most recent, 1 = second most recent, etc)
function M:get(offset)
    offset = offset or 0
    local idx = #self.entries - offset

    if idx < 1 or idx > #self.entries then
        return nil
    end

    return self.entries[idx]
end

-- Get number of entries
function M:size()
    return #self.entries
end

-- Get all entries
function M:get_all()
    local copy = {}
    for i, entry in ipairs(self.entries) do
        copy[i] = entry
    end
    return copy
end

-- Clear all history
function M:clear()
    self.entries = {}
end

-- Save history to disk
function M:save()
    -- Ensure directory exists
    vim.fn.mkdir(history_dir, "p")

    local ok, json = pcall(vim.fn.json_encode, self.entries)
    if not ok then
        return
    end

    local file = io.open(self:get_file_path(), "w")
    if not file then
        return
    end

    file:write(json)
    file:close()
end

-- Load history from disk
function M:load()
    local file = io.open(self:get_file_path(), "r")
    if not file then
        return
    end

    local content = file:read("*a")
    file:close()

    local ok, data = pcall(vim.fn.json_decode, content)
    if ok and type(data) == "table" then
        self.entries = data
    end
end

return M
