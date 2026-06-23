#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local orig_get = vim.api.nvim_buf_get_lines
local orig_set = vim.api.nvim_buf_set_lines
local orig_schedule = vim.schedule
local stats = { get_calls = 0, get_lines = 0, set_calls = 0, set_lines = 0, schedules = 0 }

vim.api.nvim_buf_get_lines = function(buf, start, stop, strict)
  stats.get_calls = stats.get_calls + 1
  local total = vim.api.nvim_buf_line_count(buf)
  local s = start or 0
  local e = stop or 0
  if e < 0 then
    e = total
  end
  stats.get_lines = stats.get_lines + math.max(0, e - s)
  return orig_get(buf, start, stop, strict)
end

vim.api.nvim_buf_set_lines = function(buf, start, stop, strict, lines)
  stats.set_calls = stats.set_calls + 1
  stats.set_lines = stats.set_lines + #(lines or {})
  return orig_set(buf, start, stop, strict, lines)
end

vim.schedule = function(callback)
  stats.schedules = stats.schedules + 1
  return orig_schedule(callback)
end

require('pi-dev').setup({
  keymaps = { enable = false },
  ui = { width = 80, input_height = 6, render = { show_timestamps = false } },
})
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
ui.show()
vim.api.nvim_set_current_win(state.ui.input_win)

stats = { get_calls = 0, get_lines = 0, set_calls = 0, set_lines = 0, schedules = 0 }
renderer.clear('fast live stream flush')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'fast delta\n' } })
assert(vim.wait(40, function()
  local text = table.concat(orig_get(state.ui.output_buf, 0, -1, false), '\n')
  local cursor = vim.api.nvim_win_get_cursor(state.ui.output_win)
  return text:find('fast delta', 1, true) ~= nil and cursor[1] == vim.api.nvim_buf_line_count(state.ui.output_buf)
end, 2), 'live stream should flush text and sticky-scroll quickly when output is unfocused')

stats = { get_calls = 0, get_lines = 0, set_calls = 0, set_lines = 0, schedules = 0 }
renderer.clear('coalesced live stream')
stats = { get_calls = 0, get_lines = 0, set_calls = 0, set_lines = 0, schedules = 0 }
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
for i = 1, 2000 do
  renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'x\n' } })
end
assert(vim.wait(1000, function()
  local text = table.concat(orig_get(state.ui.output_buf, 0, -1, false), '\n')
  return text:find('x\nx\nx', 1, true) ~= nil and vim.api.nvim_buf_line_count(state.ui.output_buf) >= 2000
end), 'coalesced live stream did not flush')

assert(stats.get_lines < 100000, 'live stream rendered with too many buffer-line reads: ' .. vim.inspect(stats))
assert(stats.set_calls < 50, 'live stream rendered with too many buffer writes: ' .. vim.inspect(stats))
assert(stats.schedules <= 5, 'live stream scheduled too many autoscroll callbacks: ' .. vim.inspect(stats))

local original_defer_fn = vim.defer_fn
local observed_tool_delay
vim.defer_fn = function(callback, delay)
  observed_tool_delay = delay
  return original_defer_fn(callback, delay)
end
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'large-live-tool', toolName = 'bash', args = { command = 'yes' } })
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'large-live-tool',
  toolName = 'bash',
  partialResult = { stdout = string.rep('x', 25000) },
})
assert(observed_tool_delay == 250, 'large live tool output should use a slower flush cadence, got ' .. tostring(observed_tool_delay))
vim.defer_fn = original_defer_fn

local defaults = require('pi-dev.config').defaults.session_render
assert(defaults.chunk_size >= 100, vim.inspect(defaults))
assert(defaults.chunk_delay_ms == 0, vim.inspect(defaults))
assert(defaults.chunk_budget_ms and defaults.chunk_budget_ms > 0, vim.inspect(defaults))

local messages = {}
for i = 1, 500 do
  messages[i] = { role = i % 2 == 0 and 'assistant' or 'user', content = 'message ' .. i }
end
local done = false
renderer.render_messages_chunked(messages, 'fast restored session', { on_done = function() done = true end })
assert(vim.wait(1000, function() return done end), 'default restored-session render did not finish quickly')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
