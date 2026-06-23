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

local function reset_runtime(key)
  state.rpc.runtimes = {}
  state.rpc.active_key = key
  local runtime = state.ensure_rpc_runtime(key)
  runtime.job_id = 900
  runtime.active = false
  runtime.status = 'idle'
  state.sync_active_rpc_runtime(runtime)
  ui.clear_input()
  return runtime
end

local sent = {}
rpc.request = function(message, cb)
  table.insert(sent, message)
  if cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
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
  runtime.job_id = 901
  runtime.active = false
  runtime.status = 'idle'
  state.sync_active_rpc_runtime(runtime)
  return runtime.job_id
end

local select_calls = 0
vim.ui.select = function(items, opts, cb)
  select_calls = select_calls + 1
  assert(opts.prompt:find('volatile runtime%-local state') ~= nil, opts.prompt)
  cb(items[1])
end

state.session.current_file = './tmp/pi-dev-test/current-a.jsonl'
reset_runtime('idle-visible-draft')
ui.set_input_text('unsent visible draft')
local cancelled
sessions.switch_to('./tmp/pi-dev-test/target-a.jsonl', { title = 'Target A', confirm_same_root = true, confirm_same_session = true }, function(response)
  cancelled = response
end)
assert(vim.wait(1000, function() return cancelled ~= nil end), 'visible draft cancellation callback missing')
assert(cancelled.cancelled == true, vim.inspect(cancelled))
assert(select_calls == 1, select_calls)
assert(#sent == 0, vim.inspect(sent))
assert(stop_all_count == 0)

vim.ui.select = function(items, opts, cb)
  select_calls = select_calls + 1
  assert(opts.prompt:find('Switching Pi session will stop 1 Pi RPC runtime', 1, true), opts.prompt)
  cb(items[2])
end
state.session.current_file = './tmp/pi-dev-test/current-b.jsonl'
reset_runtime('idle-editor-draft')
state.active_rpc_runtime().editor_text = 'unsent editor draft'
local confirmed
sessions.switch_to('./tmp/pi-dev-test/target-b.jsonl', { title = 'Target B', confirm_same_root = true, confirm_same_session = true }, function(response)
  confirmed = response
end)
assert(vim.wait(1000, function() return confirmed ~= nil end), 'editor draft confirmation callback missing')
assert(select_calls == 2, select_calls)
assert(stop_all_count == 1, stop_all_count)
assert(sent[1] and sent[1].type == 'switch_session' and sent[1].sessionPath == './tmp/pi-dev-test/target-b.jsonl', vim.inspect(sent))
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
