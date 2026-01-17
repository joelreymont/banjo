/// Shared timeout and timing constants
/// Default RPC/response timeout (30 seconds)
pub const rpc_timeout_ms: i64 = 30_000;

/// Timeout for tool requests from MCP server
pub const tool_request_timeout_ms: i64 = 30_000;

/// Permission request timeout (30 seconds)
pub const permission_timeout_ms: i64 = 30_000;

/// Nudge cooldown period (30 seconds)
pub const nudge_cooldown_ms: i64 = 30_000;

/// Timeout for live snapshot/bridge operations (8 seconds)
pub const live_snapshot_timeout_ms: i64 = 8_000;

/// Test timeout for bridge operations (8 seconds)
pub const test_timeout_ms: i64 = 8_000;

/// Stream start timeout for live CLI tests (8 seconds)
pub const live_stream_start_timeout_ms: i64 = 8_000;

/// Turn completion timeout for live CLI tests (8 seconds)
pub const live_turn_timeout_ms: i64 = 8_000;

/// Process restart timeout for live CLI tests (5 seconds)
pub const live_restart_timeout_ms: i64 = 5_000;

/// Socket read timeout for permission hooks (5 seconds)
pub const socket_read_timeout_ms: i64 = 5_000;

/// Permission hook socket response timeout (60 seconds)
pub const hook_socket_timeout_ms: i64 = 60_000;

/// WebSocket handshake timeout for MCP/nvim connections (5 seconds)
pub const websocket_handshake_timeout_ms: i64 = 5_000;

// Buffer sizes

/// Standard buffer for formatting, small messages (4KB)
pub const small_buffer_size: usize = 4096;

/// Large buffer for streaming chunks, permission messages (16KB)
pub const large_buffer_size: usize = 16384;

/// Stdout buffer for Claude bridge process output (64KB)
pub const stdout_buffer_size: usize = 64 * 1024;

/// Max queued bridge messages before applying backpressure/drop policy
pub const bridge_queue_max_messages: usize = 1024;
