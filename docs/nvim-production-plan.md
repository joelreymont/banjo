# Banjo Neovim Production Plan v2

## Goal
Achieve full feature parity with Zed integration - a production-grade chat interface for Claude Code and Codex in Neovim.

## Architecture Decision: Panel Layout
Two windows in vertical split within panel:
```
+------------------+
|   Output (buf1)  |  -- scrollable, markdown filetype
+------------------+
|   Status Line    |  -- 1 line (winbar or virtual text)
+------------------+
|   Input (buf2)   |  -- 2-3 lines, fixed height
+------------------+
```

## Architecture Decision: Message Storage
Use extmarks with namespace per message type for styling and boundaries.

## Architecture Decision: Tool Status Updates
Use extmarks with virtual text for in-place status updates (non-destructive).

---

## Phase 0: Backend Protocol Extensions (BLOCKING)

### 0.1 Engine/Model/Mode Protocol Messages
- [ ] Add `set_engine` protocol message to handler.zig
  - Add field: `current_engine: Engine = .claude`
  - Parse notification, store engine selection
  - File: src/nvim/handler.zig, src/nvim/protocol.zig

- [ ] Add `set_model` protocol message to handler.zig
  - Add field: `current_model: ?[]const u8 = null`
  - Store model, pass to next Claude CLI invocation via `--model` flag
  - File: src/nvim/handler.zig, src/nvim/protocol.zig

- [ ] Add `set_permission_mode` protocol message
  - Add field: `permission_mode: PermissionMode = .default`
  - Store mode, pass to CLI invocation
  - File: src/nvim/handler.zig, src/nvim/protocol.zig

- [ ] Add `session/state` request handler
  - Return current: engine, model, mode, session_id, connection status
  - File: src/nvim/handler.zig

### 0.2 Approval Flow (for Codex)
- [ ] Add `approval_request` notification (zig → lua)
  - Define protocol type in protocol.zig
  - Wire handler callback (currently null at handler.zig:461)
  - File: src/nvim/protocol.zig, src/nvim/handler.zig

- [ ] Add `approval_response` message (lua → zig)
  - Define protocol type
  - Forward to Codex bridge
  - File: src/nvim/protocol.zig, src/nvim/mcp_server.zig

### 0.3 Reconnection Infrastructure
- [ ] WebSocket reconnection with exponential backoff in client.lua
  - Track reconnection attempts (1s, 2s, 4s, 8s, cap 30s)
  - Success resets counter
  - File: nvim/lua/banjo/websocket/client.lua

- [ ] Process restart on exit in bridge.lua
  - Detect job_id exit via on_exit callback
  - Restart binary with same args after delay
  - Reconnect WebSocket
  - File: nvim/lua/banjo/bridge.lua

- [ ] State preservation on disconnect
  - Save pending input text
  - Save scroll position in conversation
  - Restore on reconnect
  - File: nvim/lua/banjo/bridge.lua

### 0.4 E2E Test Infrastructure
- [ ] Create mock WebSocket server for testing
  - Lua-based mock that sends canned responses
  - File: nvim/tests/mock_server.lua

- [ ] E2E test: input submission flow
  - Type text in input → Submit → Verify notification sent
  - File: nvim/tests/input_e2e_spec.lua

- [ ] E2E test: streaming response display
  - Mock sends stream_chunk → Verify text appears in output
  - File: nvim/tests/streaming_e2e_spec.lua

---

## Phase 1: Chat Panel UI

### 1.1 Panel Layout Architecture
- [ ] Create split buffer architecture function
  - Function to create output_buf and input_buf
  - Define window split layout (output on top, input on bottom)
  - File: nvim/lua/banjo/panel.lua

- [ ] Wire output buffer to existing panel functions
  - Replace single `buf` with `output_buf`
  - Keep existing `append()`, `start_stream()`, `end_stream()` working
  - File: nvim/lua/banjo/panel.lua

- [ ] Create input buffer with fixed-height window
  - 2-3 lines height at bottom
  - `winfixheight` option
  - Focus handling (Enter to focus input, Escape to unfocus)
  - File: nvim/lua/banjo/panel.lua

- [ ] Add separator line between output and input
  - Use `winbar` or virtual text line
  - Handle resize events
  - File: nvim/lua/banjo/panel.lua

- [ ] Create status bar rendering
  - Buffer or virtual text for status display
  - Define `update_status()` function interface
  - File: nvim/lua/banjo/panel.lua

### 1.2 Input Field Implementation
- [ ] Enter key to submit prompt
  - Map `<CR>` in input buffer
  - Extract text, call `bridge.send_prompt()`
  - Clear input after submission
  - File: nvim/lua/banjo/panel.lua

- [ ] Shift-Enter for multi-line input
  - Map `<S-CR>` to insert literal newline
  - Prevent submission on Shift-Enter
  - File: nvim/lua/banjo/panel.lua

- [ ] Control-C to cancel current request
  - Map `<C-c>` in input buffer
  - Call `bridge.cancel()`
  - Show visual feedback (brief highlight or message)
  - File: nvim/lua/banjo/panel.lua

- [ ] Input history data structure
  - Create Lua ring buffer for history (max 100 entries)
  - Save to `vim.fn.stdpath('data') .. '/banjo/history.json'` on exit
  - Load on startup
  - File: nvim/lua/banjo/history.lua (new file)

- [ ] Up/Down arrow history navigation
  - Map `<Up>` and `<Down>` in input buffer
  - Navigate through history ring
  - Preserve current input as draft when navigating away
  - File: nvim/lua/banjo/panel.lua

- [ ] Visual prompt indicator
  - Show `> ` prefix in input buffer
  - Use virtual text or extmark (read-only prefix)
  - File: nvim/lua/banjo/panel.lua

### 1.3 Output Section Enhancements
- [ ] Message block data structure
  - Define message types: user, agent, thought, tool_call, tool_result
  - Store message boundaries using extmarks with namespace
  - Track message metadata (timestamp, engine, id)
  - File: nvim/lua/banjo/messages.lua (new file)

- [ ] User message styling
  - Apply `BanjoUser` highlight group
  - Prefix with `You:` or similar identifier
  - Distinct background or border
  - File: nvim/lua/banjo/panel.lua

- [ ] Agent message styling
  - Apply `BanjoAgent` highlight group
  - Prefix with engine name: `[Claude]` or `[Codex]`
  - File: nvim/lua/banjo/panel.lua

- [ ] Thought block display (collapsible)
  - Use folds or initially collapsed virtual text
  - Dimmed style (`Comment` highlight)
  - Toggle keybind `<Tab>` to expand/collapse in output buffer
  - File: nvim/lua/banjo/panel.lua

- [ ] Tool call status indicators
  - Icons: `⏳` pending, `▶` running, `✓` done, `✗` failed
  - Use extmarks with virtual text for status
  - Update in place (don't append new lines)
  - File: nvim/lua/banjo/panel.lua

- [ ] Auto-scroll to bottom implementation
  - Track if cursor is at bottom of output buffer
  - Auto-scroll only when at bottom
  - File: nvim/lua/banjo/panel.lua

- [ ] Manual scroll detection
  - Detect when user scrolls up (cursor not at bottom)
  - Pause auto-scroll
  - Resume on `G` or when user scrolls back to bottom
  - File: nvim/lua/banjo/panel.lua

### 1.4 Status Line
- [ ] Connection status indicator
  - Show `●` connected (green), `○` disconnected (red)
  - Update on WebSocket state change callbacks
  - File: nvim/lua/banjo/panel.lua

- [ ] Engine and model display
  - Show `[Claude]` or `[Codex]` or `[Duet]`
  - Show model: `sonnet` / `opus` / `haiku`
  - File: nvim/lua/banjo/panel.lua

- [ ] Permission mode display
  - Show current mode: `Default` / `Accept` / `Bypass` / `Plan`
  - File: nvim/lua/banjo/panel.lua

- [ ] Streaming indicator animation
  - Show animated dots `...` or spinner during stream
  - Use timer to update every 200ms
  - Stop on `stream_end`
  - File: nvim/lua/banjo/panel.lua

---

## Phase 2: Slash Commands

### 2.1 Command Parser
- [ ] Slash prefix detection in input
  - Check if input starts with `/`
  - Route to command handler instead of prompt sender
  - File: nvim/lua/banjo/commands.lua (new file)

- [ ] Command name and argument extraction
  - Parse first word after `/` as command
  - Rest of line as arguments
  - Handle edge cases: `/` alone, `/cmd` no space
  - File: nvim/lua/banjo/commands.lua

- [ ] Tab completion for command names
  - Implement `completefunc` for input buffer
  - Show popup with matching commands
  - Insert selected command
  - File: nvim/lua/banjo/commands.lua

- [ ] Help text for each command
  - Store command descriptions in table
  - Show via `/help` or `K` on command
  - File: nvim/lua/banjo/commands.lua

### 2.2 Local Commands
- [ ] `/help` - Show available commands
  - Display floating window with all commands and descriptions
  - File: nvim/lua/banjo/commands.lua

- [ ] `/clear` - Clear conversation history
  - Clear output buffer
  - Reset message tracking
  - File: nvim/lua/banjo/commands.lua

- [ ] `/model <name>` - Switch model
  - Validate: sonnet, opus, haiku
  - Send `set_model` to backend
  - Update status line
  - Note: Takes effect on next prompt (can't switch mid-conversation)
  - File: nvim/lua/banjo/commands.lua

- [ ] `/mode <name>` - Switch permission mode
  - Validate: default, accept, bypass, plan
  - Send `set_permission_mode` to backend
  - Update status line
  - File: nvim/lua/banjo/commands.lua

- [ ] `/route <name>` - Switch engine/route
  - Validate: claude, codex, duet
  - Send `set_engine` to backend
  - Note: Requires new session (prompt user to confirm)
  - File: nvim/lua/banjo/commands.lua

- [ ] `/cancel` - Cancel current request
  - Call `bridge.cancel()`
  - Show confirmation
  - File: nvim/lua/banjo/commands.lua

- [ ] `/nudge` - Toggle auto-continue mode
  - Toggle nudge state
  - Show current state
  - File: nvim/lua/banjo/commands.lua

### 2.3 Forwarded Commands
- [ ] Forward unrecognized `/commands` to backend
  - Send as prompt with command prefix preserved
  - Let Claude CLI handle: `/compact`, `/review`, etc.
  - File: nvim/lua/banjo/commands.lua

---

## Phase 3: Session Management

### 3.1 Session Lifecycle
- [ ] New session protocol message handler
  - Define `session/new` in protocol.zig
  - Handler clears session state, starts fresh
  - File: src/nvim/protocol.zig, src/nvim/handler.zig

- [ ] Session ID display and storage
  - Store session_id from `session_id` notification
  - Display in status bar (truncated)
  - File: nvim/lua/banjo/bridge.lua, nvim/lua/banjo/panel.lua

- [ ] Resume session protocol
  - Define `session/resume` request in protocol.zig
  - Handler loads previous session from backend
  - File: src/nvim/protocol.zig, src/nvim/handler.zig

- [ ] Conversation history loading on resume
  - Request history from backend
  - Render previous messages in output buffer
  - File: nvim/lua/banjo/bridge.lua, nvim/lua/banjo/panel.lua

- [ ] Cancel in-flight requests tracking
  - Track pending request state in bridge
  - Cancel on user action or new prompt
  - File: nvim/lua/banjo/bridge.lua

- [ ] Clean shutdown on VimLeave
  - `VimLeave` autocmd
  - Send shutdown message to backend
  - Save input history
  - File: nvim/lua/banjo/init.lua

### 3.2 Session Persistence
- [ ] Save session ID for resume
  - Store in `vim.fn.stdpath('data') .. '/banjo/session.json'`
  - Include: session_id, engine, model, mode, project_root
  - File: nvim/lua/banjo/session.lua (new file)

- [ ] Auto-resume option
  - Config option `auto_resume = true/false`
  - On startup, check for saved session matching project
  - Prompt user or auto-resume based on config
  - File: nvim/lua/banjo/init.lua

---

## Phase 4: Tool Visualization

### 4.1 Tool Call Display
- [ ] Tool call data structure
  - Store: tool_id, name, status, label, result
  - Map keyed by tool_id for updates
  - File: nvim/lua/banjo/tools.lua (new file)

- [ ] Tool call initial display
  - Show: icon + tool name + truncated label
  - Status: `⏳` pending
  - Use extmark for the line
  - File: nvim/lua/banjo/panel.lua

- [ ] Tool call status update in place
  - Find extmark by tool_id
  - Update virtual text status icon
  - Don't append new line
  - File: nvim/lua/banjo/panel.lua

### 4.2 Tool Result Display
- [ ] Inline short results (< 3 lines)
  - Append result text after tool call
  - File: nvim/lua/banjo/panel.lua

- [ ] Collapsible long results (>= 3 lines)
  - Use fold or collapsed virtual text
  - Toggle with `<Tab>` on tool call line
  - File: nvim/lua/banjo/panel.lua

- [ ] Syntax highlighting in tool results
  - Detect code in result (fenced blocks)
  - Apply treesitter highlighting
  - File: nvim/lua/banjo/panel.lua

### 4.3 Tool Approval UI
- [ ] Approval prompt display
  - Show floating window with tool details
  - Show: tool name, arguments preview, risk level
  - Show approval options
  - File: nvim/lua/banjo/approval.lua (new file)

- [ ] Approval keybindings
  - `y` - approve once
  - `n` - deny once
  - `a` - always approve this tool
  - `!` - never approve this tool
  - File: nvim/lua/banjo/approval.lua

- [ ] Approval timeout indicator
  - Show countdown (30s default)
  - Auto-deny on timeout
  - File: nvim/lua/banjo/approval.lua

- [ ] Approval response handling
  - Send `approval_response` to backend
  - Close approval window
  - File: nvim/lua/banjo/approval.lua

---

## Phase 5: Rich Content Rendering

### 5.1 Markdown Rendering
- [ ] Header highlighting
  - Detect `#`, `##`, `###` lines
  - Apply `markdownH1`, `markdownH2`, `markdownH3` highlights
  - File: nvim/lua/banjo/render.lua (new file)

- [ ] Bold and italic text
  - Parse `**bold**` and `*italic*`
  - Apply `markdownBold`, `markdownItalic` highlights
  - Conceal markers
  - File: nvim/lua/banjo/render.lua

- [ ] Inline code styling
  - Detect `` `code` ``
  - Apply `markdownCode` highlight
  - Conceal backticks
  - File: nvim/lua/banjo/render.lua

- [ ] Fenced code block detection
  - Track state: in_code_block boolean
  - Extract language from opening fence
  - Store block boundaries
  - File: nvim/lua/banjo/render.lua

- [ ] Code block treesitter highlighting
  - Use treesitter language injection
  - Apply language-specific highlighting within block
  - File: nvim/lua/banjo/render.lua

- [ ] Lists rendering
  - Bullet lists with proper indent
  - Numbered lists
  - Apply `markdownListMarker` highlight
  - File: nvim/lua/banjo/render.lua

- [ ] Blockquote rendering
  - Detect `>` prefix
  - Apply `markdownBlockquote` highlight
  - File: nvim/lua/banjo/render.lua

- [ ] Link rendering
  - Parse `[text](url)` syntax
  - Apply `markdownLink` highlight
  - Make clickable with `gx` or custom `<CR>` handler
  - File: nvim/lua/banjo/render.lua

---

## Phase 6: Enhanced Tool Support

### 6.1 Additional Tool Handlers
- [ ] `openFile` tool handler
  - Open file at specified location
  - Navigate to line number if provided
  - File: nvim/lua/banjo/bridge.lua

- [ ] `showTerminal` tool handler
  - Display terminal output in panel or split
  - File: nvim/lua/banjo/bridge.lua

- [ ] `executeCode` tool stub
  - Placeholder for future terminal integration
  - File: nvim/lua/banjo/bridge.lua

### 6.2 File Context Tools
- [ ] Send current file as context
  - Keybind or command to include current file
  - Embed file content in prompt
  - File: nvim/lua/banjo/context.lua (new file)

- [ ] Send selection as context
  - Already exists but enhance formatting
  - Include file path and line numbers
  - File: nvim/lua/banjo/context.lua

---

## Phase 7: Testing

### 7.1 Unit Tests
- [ ] Panel buffer creation tests
- [ ] Input parsing tests
- [ ] Slash command parsing tests
- [ ] Message formatting tests
- [ ] History ring buffer tests

### 7.2 Integration Tests
- [ ] WebSocket connection lifecycle
- [ ] Tool request/response flow
- [ ] Streaming message handling
- [ ] Session management

### 7.3 E2E Tests
- [ ] Full conversation flow
- [ ] Panel opens with input and output sections
- [ ] User can type and submit
- [ ] Response streams to output with styling
- [ ] Tool calls display with status updates
- [ ] Slash commands work
- [ ] Model/route switching works
- [ ] Input history works
- [ ] Reconnection works

---

## Phase 8: Polish

### 8.1 Error Handling
- [ ] Connection error display in panel
  - Show error message in output or status
  - File: nvim/lua/banjo/panel.lua

- [ ] `/retry` command
  - Re-send last prompt
  - File: nvim/lua/banjo/commands.lua

- [ ] Rate limit handling
  - Detect rate limit error
  - Show wait time to user
  - File: nvim/lua/banjo/bridge.lua

- [ ] Auth error handling
  - Detect auth required error
  - Show setup instructions
  - File: nvim/lua/banjo/bridge.lua

### 8.2 Performance
- [ ] Efficient buffer updates
  - Batch changes with `nvim_buf_set_lines`
  - Avoid per-character updates
  - File: nvim/lua/banjo/panel.lua

- [ ] Lazy rendering for long conversations
  - Only render visible portion
  - Load more on scroll
  - File: nvim/lua/banjo/panel.lua

### 8.3 Configuration
- [ ] Config file schema definition
  - Document all options
  - Type annotations
  - File: nvim/lua/banjo/config.lua (new file)

- [ ] Per-project config loading
  - Load `.banjo.json` from project root
  - Override global defaults
  - File: nvim/lua/banjo/config.lua

- [ ] Keybinding customization
  - Allow user override of all keymaps
  - Document in README
  - File: nvim/lua/banjo/init.lua

### 8.4 Documentation
- [ ] README with setup instructions
- [ ] Keybinding reference card
- [ ] Troubleshooting guide
- [ ] Video/GIF demos

---

## Implementation Order (Dependencies)

```
Phase 0 (Backend) ─────────────────────────────────┐
  ├── 0.1 Protocol messages                        │
  ├── 0.2 Approval flow                            │
  ├── 0.3 Reconnection                             │
  └── 0.4 E2E test infrastructure                  │
                                                   │
Phase 1.1-1.2 (Panel foundation) ◄─────────────────┘
  ├── Split buffer architecture
  ├── Input buffer + submission
  └── Basic keymaps
           │
           ▼
Phase 1.3-1.4 (Output + Status)
  ├── Message styling
  ├── Tool indicators
  └── Status line
           │
           ▼
Phase 2.1-2.2 (Commands)
  ├── Command parser
  └── Local commands (/cancel, /clear, /model, /mode, /route)
           │
           ▼
Phase 3 (Sessions)
  ├── Session lifecycle
  └── Persistence
           │
           ▼
Phase 4 (Tools)
  ├── Tool visualization
  └── Approval UI (depends on 0.2)
           │
           ▼
Phase 5 (Markdown)
  └── Rich rendering
           │
           ▼
Phase 6-8 (Enhanced + Polish)
```

---

## Success Criteria

- [ ] Can have full multi-turn conversation with Claude/Codex from nvim
- [ ] Input field at bottom, output scrolling above
- [ ] All slash commands from Zed work
- [ ] Tool calls visible with live status updates
- [ ] Code blocks have syntax highlighting
- [ ] Input history with Up/Down navigation
- [ ] Session resume works
- [ ] Reconnection on disconnect works
- [ ] Approval UI for Codex tools works
- [ ] All e2e tests pass
- [ ] No memory leaks after 1 hour of use
- [ ] Sub-100ms input latency
- [ ] Streaming feels smooth (no stuttering)

---

## Dot Count Summary

| Phase | Dots |
|-------|------|
| 0. Backend/Infrastructure | 12 |
| 1. Panel UI | 24 |
| 2. Commands | 12 |
| 3. Sessions | 8 |
| 4. Tools | 10 |
| 5. Markdown | 8 |
| 6. Enhanced Tools | 5 |
| 7. Testing | 8 |
| 8. Polish | 10 |
| **Total** | **97** |
