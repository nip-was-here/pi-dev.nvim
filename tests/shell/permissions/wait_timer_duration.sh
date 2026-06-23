#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 10 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

local function output_text()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
end

local base = (os.time() - 60) * 1000
local function timestamp(offset_ms)
  local total = base + offset_ms
  return os.date('!%Y-%m-%dT%H:%M:%S.000Z', math.floor(total / 1000))
end

ui.show()
renderer.clear('permission wait duration')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'permission-wait-tool',
  toolName = 'bash',
  args = { command = 'chmod target' },
  timestamp = timestamp(0),
})
renderer.append_permission_request('permission-wait', 'bash `chmod target`', {
  'Permission Required',
  'Allow chmod?',
}, { timestamp = timestamp(2000) })

local pending_text = output_text()
local pending_header = pending_text:match('(#### Permission request: bash `chmod target`[^\n]*)')
assert(pending_header and pending_header:find('%([^()]+%)'), pending_text)

renderer.finish_permission_request('permission-wait', 'Yes', { timestamp = timestamp(7000) })
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'permission-wait-tool',
  toolName = 'bash',
  args = { command = 'chmod target' },
  result = { content = { { type = 'text', text = 'done' } } },
  durationMs = 10000,
  timestamp = timestamp(10000),
})
renderer.flush_pending_tool_renders()

local text = output_text()
assert(text:find('#### Permission request: bash `chmod target` - Yes', 1, true), text)
local answered_permission = text:match('(#### Permission request: bash `chmod target` %- Yes[^\n]*)')
assert(answered_permission and answered_permission:find('(5s)', 1, true), text)
local tool_header = text:match('(### Tool: bash chmod target[^\n]*)')
assert(tool_header and tool_header:find('(5s)', 1, true), text)
assert(not tool_header:find('(10s)', 1, true), tool_header)
LUA

pidev_run_lua_file "$tmp_lua"
