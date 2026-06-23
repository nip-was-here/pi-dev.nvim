#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local events = require('pi-dev.events')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')

state.is_job_running = function()
  return true
end
local runtime = state.active_rpc_runtime()
runtime.job_id = 123
runtime.active = true
runtime.status = 'tool bash'
state.sync_active_rpc_runtime(runtime)
local line = statusline.render_for_width(100)
assert(line:find('Pi status: run', 1, true), line)
assert(line:find('tool bash', 1, true) == nil, line)
assert(rpc.runtime_status(runtime) == 'running', rpc.runtime_status(runtime))

events.emit('*', { type = 'tool_execution_start', toolName = 'read' })
line = statusline.render_for_width(100)
assert(state.statusline.status == 'running', state.statusline.status)
assert(line:find('Pi status: run', 1, true), line)
assert(line:find('tool read', 1, true) == nil, line)

events.emit('*', { type = 'tool_execution_end', toolName = 'read' })
line = statusline.render_for_width(100)
assert(state.statusline.status == 'running', state.statusline.status)
assert(line:find('Pi status: run', 1, true), line)
assert(line:find('tool read', 1, true) == nil, line)
assert(line:find('done', 1, true) == nil, line)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
