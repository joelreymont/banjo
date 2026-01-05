-- Test helpers for Banjo Neovim plugin
local M = {}

-- Create a test buffer with content
function M.setup_test_buffer(content)
  content = content or { "fn main() {", "    let x = 1;", "}" }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.bo[buf].filetype = "rust"
  return buf
end

-- Clean up test state
function M.cleanup()
  -- Stop bridge if running
  local ok, bridge = pcall(require, "banjo.bridge")
  if ok and bridge.stop then
    bridge.stop()
  end

  -- Close panel if open
  local ok2, panel = pcall(require, "banjo.panel")
  if ok2 and panel.close then
    panel.close()
  end

  -- Close all buffers except current
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  -- Close all windows except current
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and win ~= vim.api.nvim_get_current_win() then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

-- Wait for async operations
function M.wait(ms)
  ms = ms or 100
  vim.wait(ms)
end

-- Wait for a condition with libuv event processing
function M.wait_for(condition_fn, timeout_ms)
  timeout_ms = timeout_ms or 5000
  local uv = vim.uv or vim.loop
  local start = uv.now()
  while not condition_fn() and (uv.now() - start) < timeout_ms do
    uv.run("nowait")
    vim.wait(10, condition_fn, 10)
  end
  return condition_fn()
end

-- Count windows
function M.count_windows()
  return #vim.api.nvim_list_wins()
end

-- Find window by buffer name pattern
function M.find_window_by_name(pattern)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match(pattern) then
      return win
    end
  end
  return nil
end

return M
