---@brief WebSocket client implementation using vim.loop
--- Uses frame.lua and utils.lua adapted from claudecode.nvim (MIT License)
local utils = require("banjo.websocket.utils")
local frame = require("banjo.websocket.frame")

local M = {}

---@class WebSocketClient
---@field tcp table vim.loop TCP handle
---@field state string "connecting" | "connected" | "closing" | "closed"
---@field buffer string Receive buffer for incomplete frames
---@field buffer_pos number Number of bytes consumed from buffer
---@field on_message function Callback for received messages
---@field on_connect function Callback when connected
---@field on_disconnect function Callback when disconnected
---@field on_error function Callback for errors

---Create a new WebSocket client
---@param callbacks table Callback functions {on_message, on_connect, on_disconnect, on_error}
---@return WebSocketClient
function M.new(callbacks)
    return {
        tcp = nil,
        state = "closed",
        buffer = "",
        buffer_pos = 0,
        on_message = callbacks.on_message or function() end,
        on_connect = callbacks.on_connect or function() end,
        on_disconnect = callbacks.on_disconnect or function() end,
        on_error = callbacks.on_error or function() end,
    }
end

-- Default connection timeout in milliseconds
local DEFAULT_CONNECT_TIMEOUT = 5000
local BUFFER_COMPACT_MIN = 8192

local function buffer_len(client)
    return #client.buffer - client.buffer_pos
end

local function compact_buffer(client, force)
    if client.buffer_pos == 0 then
        return
    end
    if not force then
        if client.buffer_pos < BUFFER_COMPACT_MIN and client.buffer_pos < (#client.buffer / 2) then
            return
        end
    end
    if client.buffer_pos >= #client.buffer then
        client.buffer = ""
        client.buffer_pos = 0
        return
    end
    client.buffer = client.buffer:sub(client.buffer_pos + 1)
    client.buffer_pos = 0
end

local function append_buffer(client, data)
    if client.buffer_pos > 0 then
        compact_buffer(client, false)
    end
    client.buffer = client.buffer .. data
end

local function schedule_or_run(fn)
    if vim.in_fast_event() then
        vim.schedule(fn)
        return
    end
    fn()
end

---Connect to a WebSocket server
---@param client WebSocketClient
---@param host string Host to connect to
---@param port number Port to connect to
---@param path string|nil WebSocket path (default: "/")
---@param timeout_ms number|nil Connection timeout in ms (default: 5000)
function M.connect(client, host, port, path, timeout_ms)
    path = path or "/"
    timeout_ms = timeout_ms or DEFAULT_CONNECT_TIMEOUT

    if client.state ~= "closed" then
        client.on_error("Client already connected or connecting")
        return
    end

    client.state = "connecting"
    client.buffer = ""
    client.buffer_pos = 0

    local tcp = vim.loop.new_tcp()
    if not tcp then
        client.state = "closed"
        client.on_error("Failed to create TCP handle")
        return
    end

    client.tcp = tcp

    -- Set up connection timeout
    local timeout_timer = vim.loop.new_timer()
    local timed_out = false

    if timeout_timer then
        timeout_timer:start(timeout_ms, 0, vim.schedule_wrap(function()
            if client.state == "connecting" then
                timed_out = true
                client.state = "closed"
                client.on_error("Connection timeout after " .. timeout_ms .. "ms")
                if tcp and not tcp:is_closing() then
                    tcp:close()
                end
            end
            timeout_timer:close()
        end))
    end

    tcp:connect(host, port, function(err)
        -- Cancel timeout on connection result
        if timeout_timer and not timeout_timer:is_closing() then
            timeout_timer:stop()
            timeout_timer:close()
        end

        if timed_out then
            return -- Already handled by timeout
        end
        if err then
            client.state = "closed"
            client.on_error("Connection failed: " .. err)
            tcp:close()
            return
        end

        -- Send WebSocket handshake
        local ws_key = utils.generate_websocket_key()
        local handshake = table.concat({
            "GET " .. path .. " HTTP/1.1",
            "Host: " .. host .. ":" .. port,
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: " .. ws_key,
            "Sec-WebSocket-Version: 13",
            "", ""
        }, "\r\n")

        tcp:write(handshake, function(write_err)
            if write_err then
                client.state = "closed"
                client.on_error("Handshake write failed: " .. write_err)
                if tcp and not tcp:is_closing() then
                    tcp:close()
                end
                return
            end
        end)

        -- Start reading
        tcp:read_start(function(read_err, data)
            if read_err then
                client.state = "closed"
                client.on_error("Read error: " .. read_err)
                if tcp and not tcp:is_closing() then
                    tcp:close()
                end
                return
            end

            if not data then
                -- EOF
                local prev_state = client.state
                client.state = "closed"
                if prev_state == "connected" then
                    client.on_disconnect(1006, "Connection closed")
                end
                return
            end

            M._process_data(client, data, ws_key)
        end)
    end)
end

---Process incoming data
---@param client WebSocketClient
---@param data string
---@param ws_key string WebSocket key for handshake validation
function M._process_data(client, data, ws_key)
    append_buffer(client, data)

    if client.state == "connecting" then
        -- Look for HTTP response end
        local start = client.buffer_pos + 1
        local header_end = client.buffer:find("\r\n\r\n", start, true)
        if header_end then
            local response = client.buffer:sub(start, header_end + 3)
            client.buffer_pos = header_end + 3

            -- Validate handshake response
            if not response:match("^HTTP/1%.1 101") then
                client.state = "closed"
                client.on_error("Invalid handshake response")
                if client.tcp and not client.tcp:is_closing() then
                    client.tcp:close()
                end
                return
            end

            -- Validate accept key
            local accept_key = response:match("Sec%-WebSocket%-Accept:%s*([^\r\n]+)")
            local expected_key = utils.generate_accept_key(ws_key)
            if accept_key ~= expected_key then
                client.state = "closed"
                client.on_error("Invalid Sec-WebSocket-Accept")
                if client.tcp and not client.tcp:is_closing() then
                    client.tcp:close()
                end
                return
            end

            compact_buffer(client, true)
            client.state = "connected"
            vim.schedule(function()
                client.on_connect()
            end)
        end
    end

    if client.state == "connected" then
        M._process_frames(client)
    end
end

---Process WebSocket frames from buffer
---@param client WebSocketClient
function M._process_frames(client)
    while buffer_len(client) > 0 do
        local ws_frame, bytes_consumed = frame.parse_frame(client.buffer, client.buffer_pos + 1)
        if not ws_frame or bytes_consumed == 0 then
            break -- Need more data
        end

        client.buffer_pos = client.buffer_pos + bytes_consumed

        if ws_frame.opcode == frame.OPCODE.TEXT or ws_frame.opcode == frame.OPCODE.BINARY then
            schedule_or_run(function()
                client.on_message(ws_frame.payload)
            end)
        elseif ws_frame.opcode == frame.OPCODE.PING then
            -- Respond with pong
            local pong = frame.create_pong_frame(ws_frame.payload)
            -- Client frames must be masked
            pong = M._mask_frame(pong)
            if pong and client.tcp and not client.tcp:is_closing() then
                client.tcp:write(pong)
            end
        elseif ws_frame.opcode == frame.OPCODE.PONG then
            -- Ignore pongs
        elseif ws_frame.opcode == frame.OPCODE.CLOSE then
            local code = 1000
            local reason = ""
            if #ws_frame.payload >= 2 then
                code = utils.bytes_to_uint16(ws_frame.payload:sub(1, 2))
                reason = ws_frame.payload:sub(3)
            end
            client.state = "closed"
            client.buffer = "" -- Clear buffer on close
            client.buffer_pos = 0
            schedule_or_run(function()
                client.on_disconnect(code, reason)
            end)
            if client.tcp and not client.tcp:is_closing() then
                client.tcp:close()
            end
            return
        end
    end
    compact_buffer(client, false)
end

---Re-encode a frame with client masking
---@param frame_data string The unmasked frame
---@return string|nil masked_frame The masked frame, or nil on error
function M._mask_frame(frame_data)
    -- For simplicity, re-create the frame with masking
    -- This is a bit wasteful but ensures correctness
    local ws_frame = frame.parse_frame(frame_data)
    if ws_frame then
        return frame.create_frame(ws_frame.opcode, ws_frame.payload, ws_frame.fin, true)
    end
    -- RFC 6455: client frames MUST be masked, don't return unmasked frame
    return nil
end

---Send a text message
---@param client WebSocketClient
---@param message string
function M.send(client, message)
    if client.state ~= "connected" then
        client.on_error("Cannot send: not connected")
        return
    end

    -- Client frames MUST be masked (RFC 6455)
    local ws_frame = frame.create_frame(frame.OPCODE.TEXT, message, true, true)
    client.tcp:write(ws_frame)
end

---Close the connection
---@param client WebSocketClient
---@param code number|nil Close code (default: 1000)
---@param reason string|nil Close reason
function M.close(client, code, reason)
    if client.state == "closed" or client.state == "closing" then
        return
    end

    client.state = "closing"

    -- Send close frame (masked)
    local close_frame = frame.create_close_frame(code or 1000, reason or "")
    close_frame = M._mask_frame(close_frame)

    if not close_frame then
        -- Masking failed, just close the connection
        client.state = "closed"
        if client.tcp and not client.tcp:is_closing() then
            client.tcp:close()
        end
        return
    end

    client.tcp:write(close_frame, function()
        client.state = "closed"
        if client.tcp and not client.tcp:is_closing() then
            client.tcp:close()
        end
    end)
end

---Check if client is connected
---@param client WebSocketClient
---@return boolean
function M.is_connected(client)
    return client.state == "connected"
end

return M
