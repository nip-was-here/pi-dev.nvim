#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local sessions = require('pi-dev.sessions')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')

state.session.current_file = nil
state.session.tree_root_file = nil
local active = state.set_active_rpc_runtime('runtime-a')
active.job_id = 101
active.status = 'idle'
state.sync_active_rpc_runtime(active)
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end
local fork_callback
rpc.request = function(message, cb)
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  elseif message.type == 'get_fork_messages' then
    fork_callback = cb
  elseif cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end

sessions.tree()
assert(fork_callback, 'tree should fall back to RPC fork messages')
local other = state.set_active_rpc_runtime('runtime-b')
other.job_id = 202
other.status = 'idle'
state.sync_active_rpc_runtime(other)
fork_callback({
  __pi_runtime_key = 'runtime-a',
  success = true,
  data = {
    messages = {
      { entryId = 'u1', role = 'user', text = 'stale tree prompt', timestamp = '2026-01-01T00:00:00.000Z' },
    },
  },
})
assert(state.rpc.active_key == 'runtime-b', state.rpc.active_key)
assert(state.ui.interaction == nil, 'inactive RPC fallback must not open a visible tree interaction: ' .. vim.inspect(state.ui.interaction))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
