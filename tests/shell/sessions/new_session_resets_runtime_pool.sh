#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')
local ui = require('pi-dev.ui')

ui.show()
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

state.rpc.runtimes = {}
state.rpc.active_key = 'old-active'
local active = state.ensure_rpc_runtime('old-active')
active.job_id = 501
active.active = false
active.status = 'idle'
state.rpc.runtimes['old-inactive'] = {
  key = 'old-inactive',
  job_id = 502,
  active = false,
  status = 'idle',
  pending = {},
  stderr = {},
  buffer = '',
}
state.sync_active_rpc_runtime(active)

local select_called = false
vim.ui.select = function()
  select_called = true
  error('idle new-session reset must not prompt when no volatile state exists')
end

local stop_all_count = 0
rpc.stop_all = function()
  stop_all_count = stop_all_count + 1
  state.rpc.runtimes = {}
  state.rpc.active_key = 'default'
  state.sync_active_rpc_runtime(state.ensure_rpc_runtime('default'))
end
rpc.start = function(key, opts)
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key or 'default')
  if not opts or opts.activate ~= false then
    state.set_active_rpc_runtime(runtime.key)
  end
  runtime.job_id = 600 + stop_all_count
  runtime.active = false
  runtime.status = 'idle'
  state.sync_active_rpc_runtime(runtime)
  return runtime.job_id
end
local sent = {}
rpc.request = function(message, cb)
  if not state.is_job_running(state.active_rpc_runtime()) then
    rpc.start(state.rpc.active_key, { activate = true })
  end
  table.insert(sent, { type = message.type, runtime = state.rpc.active_key })
  if cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end

local done
sessions.new_session(function(response)
  done = response
end)
assert(vim.wait(1000, function() return done ~= nil end), 'new session callback missing')
assert(done.success == true, vim.inspect(done))
assert(not select_called, 'new session without volatile state must not prompt')
assert(stop_all_count == 1, stop_all_count)
assert(sent[1] and sent[1].type == 'new_session' and sent[1].runtime == 'default', vim.inspect(sent))
assert(state.rpc.runtimes['old-active'] == nil, 'old active runtime should be removed')
assert(state.rpc.runtimes['old-inactive'] == nil, 'old inactive runtime should be removed')
assert(state.rpc_runtime_count({ running_only = true }) == 1, 'new session should leave one fresh runtime')
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
