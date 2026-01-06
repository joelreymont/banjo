-- WebSocket module tests
-- Tests websocket/utils.lua, websocket/frame.lua, and websocket/client.lua

local helpers = require("tests.helpers")

describe("banjo websocket", function()
  local utils
  local frame
  local client

  before_each(function()
    -- Reload modules for clean state
    package.loaded["banjo.websocket.utils"] = nil
    package.loaded["banjo.websocket.frame"] = nil
    package.loaded["banjo.websocket.client"] = nil

    utils = require("banjo.websocket.utils")
    frame = require("banjo.websocket.frame")
    client = require("banjo.websocket.client")
  end)

  describe("utils", function()
    describe("base64 encoding/decoding", function()
      it("encodes strings to base64", function()
        local result = utils.base64_encode("hello")
        assert.equals("aGVsbG8=", result)
      end)

      it("decodes base64 strings", function()
        local result = utils.base64_decode("aGVsbG8=")
        assert.equals("hello", result)
      end)

      it("round-trips encoding and decoding", function()
        local original = "The quick brown fox jumps over the lazy dog"
        local encoded = utils.base64_encode(original)
        local decoded = utils.base64_decode(encoded)
        assert.equals(original, decoded)
      end)

      it("handles empty strings", function()
        local encoded = utils.base64_encode("")
        assert.equals("", encoded)
        local decoded = utils.base64_decode("")
        assert.equals("", decoded)
      end)
    end)

    describe("WebSocket key generation", function()
      it("generates valid WebSocket keys", function()
        local key = utils.generate_websocket_key()
        assert.is_not_nil(key)
        assert.truthy(#key > 0, "Key should not be empty")
      end)

      it("generates unique keys", function()
        local key1 = utils.generate_websocket_key()
        local key2 = utils.generate_websocket_key()
        assert.is_not.equals(key1, key2, "Keys should be unique")
      end)

      it("generates keys of expected format (base64)", function()
        local key = utils.generate_websocket_key()
        -- Valid base64 should decode without error
        local decoded = utils.base64_decode(key)
        assert.truthy(#decoded > 0)
      end)
    end)

    describe("WebSocket accept key generation", function()
      it("generates correct accept key for known client key", function()
        -- Test vector from RFC 6455
        local client_key = "dGhlIHNhbXBsZSBub25jZQ=="
        local expected = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        local result = utils.generate_accept_key(client_key)
        assert.equals(expected, result)
      end)
    end)

    describe("SHA-1 hashing", function()
      it("computes correct SHA-1 hash", function()
        -- Test vector: SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
        local result = utils.sha1("abc")
        -- Result is binary, convert to hex for comparison
        local hex = ""
        for i = 1, #result do
          hex = hex .. string.format("%02x", string.byte(result, i))
        end
        assert.equals("a9993e364706816aba3e25717850c26c9cd0d89d", hex)
      end)
    end)

    describe("byte conversion", function()
      it("converts uint16 to bytes", function()
        local bytes = utils.uint16_to_bytes(0x1234)
        assert.equals(2, #bytes)
        assert.equals(0x12, string.byte(bytes, 1))
        assert.equals(0x34, string.byte(bytes, 2))
      end)

      it("converts bytes to uint16", function()
        local bytes = string.char(0x12, 0x34)
        local result = utils.bytes_to_uint16(bytes)
        assert.equals(0x1234, result)
      end)

      it("round-trips uint16 conversion", function()
        local original = 12345
        local bytes = utils.uint16_to_bytes(original)
        local result = utils.bytes_to_uint16(bytes)
        assert.equals(original, result)
      end)

      it("converts uint64 to bytes", function()
        local bytes = utils.uint64_to_bytes(0x123456789ABCDEF0)
        assert.equals(8, #bytes)
      end)

      it("converts bytes to uint64", function()
        local bytes = string.char(0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0)
        local result = utils.bytes_to_uint64(bytes)
        assert.equals(0x123456789ABCDEF0, result)
      end)
    end)

    describe("UTF-8 validation", function()
      it("validates valid UTF-8 strings", function()
        assert.is_true(utils.is_valid_utf8("hello"))
        assert.is_true(utils.is_valid_utf8("hello world"))
        assert.is_true(utils.is_valid_utf8("你好"))
        assert.is_true(utils.is_valid_utf8("こんにちは"))
      end)

      it("handles empty strings", function()
        assert.is_true(utils.is_valid_utf8(""))
      end)
    end)

    describe("masking", function()
      it("applies XOR mask to data", function()
        local data = "hello"
        local mask = string.char(0x12, 0x34, 0x56, 0x78)
        local masked = utils.apply_mask(data, mask)
        assert.is_not.equals(data, masked, "Masked data should differ")
      end)

      it("unmasks data by applying mask twice", function()
        local original = "hello"
        local mask = string.char(0x12, 0x34, 0x56, 0x78)
        local masked = utils.apply_mask(original, mask)
        local unmasked = utils.apply_mask(masked, mask)
        assert.equals(original, unmasked, "Double masking should restore original")
      end)
    end)

    describe("HTTP header parsing", function()
      it("parses HTTP headers", function()
        local request = "GET / HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\n\r\n"
        local headers = utils.parse_http_headers(request)
        assert.is_not_nil(headers)
        assert.equals("example.com", headers.host)
        assert.equals("websocket", headers.upgrade)
      end)

      it("handles case-insensitive header names", function()
        local request = "GET / HTTP/1.1\r\nHOST: example.com\r\n\r\n"
        local headers = utils.parse_http_headers(request)
        assert.equals("example.com", headers.host)
      end)
    end)
  end)

  describe("frame", function()
    describe("text frame creation", function()
      it("creates text frames", function()
        local result = frame.create_text_frame("hello", true)
        assert.is_not_nil(result)
        assert.truthy(#result > 0)
      end)

      it("creates fragmented text frames", function()
        local frag1 = frame.create_text_frame("hel", false)
        local frag2 = frame.create_text_frame("lo", true)
        assert.is_not_nil(frag1)
        assert.is_not_nil(frag2)
      end)
    end)

    describe("control frames", function()
      it("creates close frames", function()
        local result = frame.create_close_frame(1000, "Normal closure")
        assert.is_not_nil(result)
      end)

      it("creates ping frames", function()
        local result = frame.create_ping_frame("ping")
        assert.is_not_nil(result)
      end)

      it("creates pong frames", function()
        local result = frame.create_pong_frame("pong")
        assert.is_not_nil(result)
      end)

      it("identifies control frames", function()
        assert.is_true(frame.is_control_frame(0x8)) -- close
        assert.is_true(frame.is_control_frame(0x9)) -- ping
        assert.is_true(frame.is_control_frame(0xA)) -- pong
        assert.is_false(frame.is_control_frame(0x1)) -- text
        assert.is_false(frame.is_control_frame(0x2)) -- binary
      end)
    end)

    describe("frame parsing", function()
      it("parses simple text frames", function()
        -- Create a frame and parse it back
        local created = frame.create_text_frame("test", true)
        local parsed, remaining = frame.parse_frame(created)
        assert.is_not_nil(parsed)
        assert.equals("test", parsed.payload)
      end)

      it("handles incomplete frames", function()
        -- Only send first few bytes of a frame
        local created = frame.create_text_frame("test", true)
        local partial = string.sub(created, 1, 2)
        local parsed, remaining = frame.parse_frame(partial)
        assert.is_nil(parsed, "Should return nil for incomplete frame")
        assert.equals(0, remaining, "Should return 0 for incomplete frame")
      end)
    end)

    describe("frame validation", function()
      it("validates well-formed frames", function()
        local text_frame = {
          fin = true,
          opcode = 0x1,
          masked = false,
          payload = "hello",
        }
        local valid, err = frame.validate_frame(text_frame)
        assert.is_true(valid, err)
      end)

      it("rejects control frames with large payloads", function()
        -- Control frames must have payload <= 125 bytes
        local large_payload = string.rep("x", 126)
        local close_frame = {
          fin = true,
          opcode = 0x8, -- close
          masked = false,
          payload = large_payload,
          payload_length = #large_payload,
        }
        local valid, err = frame.validate_frame(close_frame)
        assert.is_false(valid)
        assert.truthy(err:find("Control frame"), "Error should mention control frame")
      end)

      it("rejects fragmented control frames", function()
        local ping_frame = {
          fin = false, -- fragmented
          opcode = 0x9, -- ping
          masked = false,
          payload = "ping",
        }
        local valid, err = frame.validate_frame(ping_frame)
        assert.is_false(valid)
        assert.truthy(err:find("Control frame"), "Error should mention control frame")
      end)
    end)
  end)

  describe("client", function()
    it("creates new client with callbacks", function()
      local callbacks = {
        on_message = function() end,
        on_connect = function() end,
        on_disconnect = function() end,
        on_error = function() end,
      }
      local ws = client.new(callbacks)
      assert.is_not_nil(ws)
      assert.equals("closed", ws.state)
    end)

    it("initializes with default callbacks if not provided", function()
      local ws = client.new({})
      assert.is_not_nil(ws)
      assert.is_function(ws.on_message)
      assert.is_function(ws.on_connect)
    end)

    it("rejects connection when already connected", function()
      local error_called = false
      local ws = client.new({
        on_error = function(msg)
          error_called = true
          assert.truthy(msg:find("already connected"))
        end,
      })
      ws.state = "connected"
      client.connect(ws, "localhost", 8080)
      assert.is_true(error_called)
    end)
  end)
end)
