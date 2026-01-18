# ACP WebSocket Transport

## Overview

Banjo's daemon mode exposes ACP (Agent Client Protocol) over WebSocket on the same server used by the Neovim/Emacs bridge. The ACP payload is standard JSON-RPC 2.0; only the transport differs.

See `docs/acp-protocol.md` for the ACP message schema and flow.

## Connection and Port Discovery

When `banjo --daemon` starts, it creates a WebSocket server bound to localhost and reports the port in two places:

- **Ready notification (stdout)**: a JSON-RPC notification with `method: "ready"` and `params.mcp_port`.
- **Lockfile**: `~/.claude/ide/<port>.lock` with JSON containing `pid`, `workspaceFolders`, `ideName`, and `transport`.

The port is taken from the lockfile name (`<port>.lock`), not from a field inside the file.

## WebSocket Handshake

- Connect to: `ws://127.0.0.1:<port>/acp`
- Handshake must include `Sec-WebSocket-Version: 13` and `Sec-WebSocket-Key`.
- The server rejects unknown paths and oversized headers (> 4KB).

## Framing and Message Format

- **Text frames only**. Each frame must contain exactly one JSON-RPC message.
- **No fragmentation**. Clients must send unfragmented frames with `FIN = 1`.
- **Client masking required** (per RFC 6455). Unmasked client frames are rejected.
- **Server frames are unmasked**.
- **Max frame size**: 16 MiB.

On the server side, the WebSocket payload is treated as a complete JSON-RPC message. Newlines are added internally for the stdio JSON-RPC reader; clients should not include trailing newlines in the payload.

## Ping/Pong and Close

- `ping` frames receive `pong` responses (payload echoed).
- `close` frames terminate the connection.

## Errors and Limits

- Invalid path → handshake error.
- Missing/invalid WebSocket headers → handshake error.
- Oversized handshake headers → handshake error.
- Oversized frames → frame parse error.
