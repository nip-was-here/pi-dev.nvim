#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, rpc = { idle_timeout_ms = 0 } })
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')

state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

state.rpc.runtimes = {}
state.rpc.active_key = 'default'
state.set_active_rpc_runtime('default')
state.reset_rpc_runtime(state.active_rpc_runtime())

local background = state.ensure_rpc_runtime('background-only')
background.job_id = 301
background.active = true
background.status = 'running'
local line = statusline.render_for_width(100)
assert(line:find('Pi status: run', 1, true), line)
assert(line:find('not connected', 1, true) == nil, line)

background.active = false
background.waiting_input = false
background.status = 'idle'
line = statusline.render_for_width(100)
assert(line:find('Pi status: idle', 1, true), line)
assert(line:find('idle 1', 1, true) == nil, line)

background.active = true
background.waiting_input = true
background.status = 'waiting input'
line = statusline.render_for_width(100)
assert(line:find('Pi status: wait', 1, true), line)
assert(line:find('wait 1', 1, true) == nil, line)

state.set_active_rpc_runtime('background-only')
statusline.update_from_stats({ tokens = { total = vim.NIL, totalTokens = 333 } })
line = statusline.render_for_width(120)
assert(line:find('333 tok', 1, true), line)
statusline.update_from_stats({ tokens = { inputTokens = 2, outputTokens = 5 } })
line = statusline.render_for_width(120)
assert(line:find('7 tok', 1, true), line)

state.set_active_rpc_runtime('active')
local inactive = state.ensure_rpc_runtime('inactive')
inactive.job_id = 302
local stopped_response
inactive.pending['stop-test'] = { callback = function(response)
  stopped_response = response
end }
rpc.stop('inactive')
assert(vim.wait(1000, function() return stopped_response ~= nil end), 'inactive stop callback did not fire')
assert(stopped_response.__pi_runtime_key == 'inactive', vim.inspect(stopped_response))
assert(stopped_response.__pi_active_runtime == false, vim.inspect(stopped_response))
assert(state.rpc.active_key == 'active', state.rpc.active_key)
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
