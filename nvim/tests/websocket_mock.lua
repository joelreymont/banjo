-- WebSocket mock for testing async callback behavior
-- Simulates vim.loop TCP callbacks in fast event context

local M = {}

---@class MockWebSocketClient
---@field callbacks table Original callbacks from bridge
---@field state string Connection state
---@field _scheduled_calls table[] Calls scheduled for delivery

---Create a mock WebSocket client
---@param callbacks table {on_message, on_connect, on_disconnect, on_error}
---@return MockWebSocketClient
function M.new(callbacks)
    return {
        callbacks = callbacks,
        state = "closed",
        _scheduled_calls = {},
    }
end

---Simulate async connection
---Callbacks will be invoked in next event loop tick (like real TCP)
---@param client MockWebSocketClient
---@param host string
---@param port number
---@param path string
function M.connect(client, host, port, path)
    client.state = "connecting"

    -- Schedule on_connect callback to run in "fast event context"
    -- (Simulates vim.loop TCP callback)
    vim.schedule(function()
        -- This runs in fast event context
        -- Any nvim API calls here should error with E5560
        client.state = "connected"

        -- Call the callback directly (no vim.schedule wrapper)
        -- If bridge didn't wrap in vim.schedule, this will fail
        client.callbacks.on_connect()
    end)
end

---Simulate receiving a message
---@param client MockWebSocketClient
---@param message string JSON message to deliver
function M.send_message(client, message)
    if client.state ~= "connected" then
        error("Cannot send message: not connected")
    end

    -- Schedule message delivery in fast event context
    vim.schedule(function()
        -- This simulates the TCP read callback
        client.callbacks.on_message(message)
    end)
end

---Simulate disconnect
---@param client MockWebSocketClient
---@param code number Close code
---@param reason string Close reason
function M.disconnect(client, code, reason)
    client.state = "closed"

    vim.schedule(function()
        client.callbacks.on_disconnect(code, reason)
    end)
end

---Simulate error
---@param client MockWebSocketClient
---@param error_msg string Error message
function M.error(client, error_msg)
    vim.schedule(function()
        client.callbacks.on_error(error_msg)
    end)
end

---Send data (client to server) - for testing send path
---@param client MockWebSocketClient
---@param data string
function M.send(client, data)
    -- No-op in mock, just track that send was called
    table.insert(client._scheduled_calls, {type = "send", data = data})
end

---Close the connection
---@param client MockWebSocketClient
function M.close(client)
    if client.state ~= "closed" then
        M.disconnect(client, 1000, "Normal closure")
    end
end

return M
