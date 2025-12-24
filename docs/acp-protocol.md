# Agent Client Protocol (ACP) Specification

## Overview

ACP is JSON-RPC 2.0 over stdio. Editor spawns agent process, communicates bidirectionally.

- **Protocol**: JSON-RPC 2.0 over stdin/stdout
- **Version**: PROTOCOL_VERSION = 1

## Methods

### Initialization
| Method | Dir | Description |
|--------|-----|-------------|
| `initialize` | C→A | Handshake, negotiate capabilities |
| `authenticate` | C→A | Auth using specified method |

### Session
| Method | Type | Description |
|--------|------|-------------|
| `session/new` | Req | Create session |
| `session/prompt` | Req | Send user prompt |
| `session/cancel` | Notif | Cancel current op |
| `session/update` | Notif | Stream progress |
| `session/request_permission` | Req | Request tool permission |
| `session/set_mode` | Req | Set permission mode |

### File System (Agent→Client)
| Method | Description |
|--------|-------------|
| `fs/read_text_file` | Read file |
| `fs/write_text_file` | Write file |

### Terminal (Agent→Client)
| Method | Description |
|--------|-------------|
| `terminal/create` | Execute command |
| `terminal/output` | Get output |
| `terminal/wait_for_exit` | Wait completion |
| `terminal/kill` | Terminate |
| `terminal/release` | Release resources |

## Session Update Kinds

| Kind | Description |
|------|-------------|
| `text` | Streaming text |
| `tool_call` | Tool started |
| `tool_call_update` | Tool result |
| `plan` | Todo list |
| `thinking` | Model reasoning |

## Permission Modes

- `default` - Ask for each dangerous op
- `acceptEdits` - Auto-accept file edits
- `bypassPermissions` - Skip all checks
- `dontAsk` - Only pre-approved tools
- `plan` - Planning mode, no execution

## NOT in Protocol

- Message editing
- History manipulation
- Re-prompting with edits
