#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local renderer = require('pi-dev.renderer')
local ui = require('pi-dev.ui')

ui.show()
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end
local runtime_a = state.set_active_rpc_runtime('runtime-a')
runtime_a.job_id = 101
runtime_a.status = 'idle'
state.sync_active_rpc_runtime(runtime_a)
local callbacks = {}
rpc.start = function(key)
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key)
  runtime.job_id = runtime.job_id or 101
  runtime.status = runtime.status or 'idle'
  return runtime.job_id
end
rpc.request = function(message, cb)
  callbacks[message.type] = cb
  return message.type
end

api.bash('echo stale')
assert(callbacks.bash, 'bash callback should be captured')
local runtime_b = state.set_active_rpc_runtime('runtime-b')
runtime_b.job_id = 202
runtime_b.status = 'idle'
state.sync_active_rpc_runtime(runtime_b)
renderer.clear('Runtime B output')
callbacks.bash({ __pi_runtime_key = 'runtime-a', success = true, data = { stdout = 'stale bash output', exitCode = 0 } })
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('Runtime B output', 1, true), text)
assert(not text:find('stale bash output', 1, true), text)

callbacks = {}
state.set_active_rpc_runtime('runtime-a')
api.compact()
assert(callbacks.compact, 'compact callback should be captured')
state.set_active_rpc_runtime('runtime-b')
renderer.clear('Runtime B compact output')
callbacks.compact({ __pi_runtime_key = 'runtime-a', success = true, data = { summary = 'stale compact summary', tokensBefore = 123 } })
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('Runtime B compact output', 1, true), text)
assert(not text:find('stale compact summary', 1, true), text)

callbacks = {}
state.set_active_rpc_runtime('runtime-a')
api.export_session('./tmp/pi-dev-test/out.html')
assert(callbacks.export_html, 'export callback should be captured')
state.set_active_rpc_runtime('runtime-b')
renderer.clear('Runtime B export output')
callbacks.export_html({ __pi_runtime_key = 'runtime-a', success = true, data = { path = './tmp/pi-dev-test/out.html' } })
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('Runtime B export output', 1, true), text)
assert(not text:find('Exported Pi session HTML', 1, true), text)

callbacks = {}
state.set_active_rpc_runtime('runtime-a')
api.set_model('provider-a', 'model-a')
assert(callbacks.set_model, 'set_model callback should be captured')
state.set_active_rpc_runtime('runtime-b')
state.statusline.error = nil
state.active_rpc_runtime().error = nil
callbacks.set_model({ __pi_runtime_key = 'runtime-a', success = false, error = 'stale model error' })
assert(state.statusline.error ~= 'stale model error', tostring(state.statusline.error))
assert(state.active_rpc_runtime().error ~= 'stale model error', tostring(state.active_rpc_runtime().error))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
