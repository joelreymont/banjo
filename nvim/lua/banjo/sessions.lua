-- Banjo session persistence module
local M = {}

local sessions_dir = vim.fn.stdpath("data") .. "/banjo_sessions"

-- Ensure sessions directory exists
local function ensure_dir()
    if vim.fn.isdirectory(sessions_dir) == 0 then
        vim.fn.mkdir(sessions_dir, "p")
    end
end

-- Save session data to disk
function M.save(id, data)
    if not id or id == "" then
        return false
    end

    ensure_dir()

    local file_path = sessions_dir .. "/" .. id .. ".json"
    local ok, json = pcall(vim.fn.json_encode, data)
    if not ok then
        return false
    end

    local file = io.open(file_path, "w")
    if file then
        file:write(json)
        file:close()
        return true
    end

    return false
end

-- Load session data from disk
function M.load(id)
    if not id or id == "" then
        return nil
    end

    local file_path = sessions_dir .. "/" .. id .. ".json"
    local file = io.open(file_path, "r")
    if not file then
        return nil
    end

    local content = file:read("*a")
    file:close()

    local ok, data = pcall(vim.fn.json_decode, content)
    if ok and type(data) == "table" then
        return data
    end

    return nil
end

-- List all saved sessions
function M.list()
    ensure_dir()

    local sessions = {}
    local handle = vim.loop.fs_scandir(sessions_dir)
    if not handle then
        return sessions
    end

    while true do
        local name, type = vim.loop.fs_scandir_next(handle)
        if not name then
            break
        end

        if type == "file" and name:match("%.json$") then
            local id = name:gsub("%.json$", "")
            local data = M.load(id)
            if data then
                table.insert(sessions, {
                    id = id,
                    timestamp = data.timestamp,
                })
            end
        end
    end

    -- Sort by timestamp descending (most recent first)
    table.sort(sessions, function(a, b)
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)

    return sessions
end

-- Delete a session
function M.delete(id)
    if not id or id == "" then
        return false
    end

    local file_path = sessions_dir .. "/" .. id .. ".json"
    local ok = pcall(vim.fn.delete, file_path)
    return ok
end

return M
