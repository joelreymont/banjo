/// Shared timeout and timing constants
/// Default RPC/response timeout (30 seconds)
pub const rpc_timeout_ms: i64 = 30_000;

/// Timeout for tool requests from MCP server
pub const tool_request_timeout_ms: i64 = 30_000;

/// Permission request timeout (30 seconds)
pub const permission_timeout_ms: i64 = 30_000;

/// Nudge cooldown period (30 seconds)
pub const nudge_cooldown_ms: i64 = 30_000;

/// Timeout for live snapshot/bridge operations (60 seconds)
pub const live_snapshot_timeout_ms: i64 = 60_000;

/// Test timeout for bridge operations (60 seconds)
pub const test_timeout_ms: i64 = 60_000;

/// Socket read timeout for permission hooks (5 seconds)
pub const socket_read_timeout_ms: i64 = 5_000;

// Buffer sizes

/// Standard buffer for formatting, small messages (4KB)
pub const small_buffer_size: usize = 4096;

/// Large buffer for streaming chunks, permission messages (16KB)
pub const large_buffer_size: usize = 16384;

/// Stdout buffer for Claude bridge process output (64KB)
pub const stdout_buffer_size: usize = 64 * 1024;
