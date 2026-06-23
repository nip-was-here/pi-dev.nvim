#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')
local ui = require('pi-dev.ui')

ui.show()
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

local function reset_active(key)
  state.rpc.runtimes = {}
  state.rpc.active_key = key or 'active'
  local runtime = state.ensure_rpc_runtime(state.rpc.active_key)
  runtime.job_id = 900
  runtime.active = false
  runtime.status = 'idle'
  state.sync_active_rpc_runtime(runtime)
  ui.clear_input()
  state.session.current_file = './tmp/pi-dev-test/current-reload.jsonl'
  return runtime
end

local calls = {}
rpc.request = function(message, cb)
  table.insert(calls, message.type .. (message.sessionPath and (':' .. message.sessionPath) or ''))
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = './tmp/pi-dev-test/reloaded.jsonl' } })
  elseif message.type == 'switch_session' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  elseif cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end
rpc.stop = function()
  table.insert(calls, 'stop:' .. tostring(state.rpc.active_key))
  state.reset_rpc_runtime()
end
rpc.start = function()
  table.insert(calls, 'start:' .. tostring(state.rpc.active_key))
  local runtime = state.ensure_rpc_runtime(state.rpc.active_key)
  runtime.job_id = 901
  runtime.active = false
  runtime.status = 'idle'
  state.sync_active_rpc_runtime(runtime)
  return runtime.job_id
end

reset_active('cancel-draft')
ui.set_input_text('unsent reload draft')
local select_calls = 0
vim.ui.select = function(items, opts, cb)
  select_calls = select_calls + 1
  assert(opts.prompt:find('active Pi RPC runtime', 1, true), opts.prompt)
  assert(opts.prompt:find('volatile runtime-local state', 1, true), opts.prompt)
  cb(items[1])
end
local cancelled
api.reload(function(response)
  cancelled = response
end)
assert(vim.wait(1000, function() return cancelled ~= nil end), 'cancelled reload callback missing')
assert(cancelled.cancelled == true, vim.inspect(cancelled))
assert(select_calls == 1, select_calls)
assert(#calls == 0, vim.inspect(calls))
assert(state.active_rpc_runtime().input_text == 'unsent reload draft', state.active_rpc_runtime().input_text or 'nil')

calls = {}
reset_active('confirm-editor')
state.active_rpc_runtime().editor_text = 'unsent editor reload draft'
vim.ui.select = function(items, opts, cb)
  select_calls = select_calls + 1
  cb(items[2])
end
local confirmed
api.reload(function(response)
  confirmed = response
end)
assert(vim.wait(1000, function() return confirmed ~= nil end), vim.inspect(calls))
assert(select_calls == 2, select_calls)
assert(calls[1] == 'get_state', vim.inspect(calls))
assert(calls[2] == 'stop:confirm-editor', vim.inspect(calls))
assert(calls[3] == 'start:confirm-editor', vim.inspect(calls))
assert(vim.tbl_contains(calls, 'switch_session:./tmp/pi-dev-test/reloaded.jsonl'), vim.inspect(calls))

calls = {}
reset_active('active-idle')
state.rpc.runtimes['inactive-volatile'] = {
  key = 'inactive-volatile',
  job_id = 902,
  active = true,
  status = 'running',
  input_text = 'background draft',
  pending = {},
  stderr = {},
  buffer = '',
}
vim.ui.select = function()
  error('inactive volatile runtime must not prompt active-runtime reload')
end
local no_prompt_done
api.reload(function(response)
  no_prompt_done = response
end)
assert(vim.wait(1000, function() return no_prompt_done ~= nil end), vim.inspect(calls))
assert(calls[1] == 'get_state', vim.inspect(calls))
assert(calls[2] == 'stop:active-idle', vim.inspect(calls))
assert(calls[3] == 'start:active-idle', vim.inspect(calls))
assert(state.rpc.runtimes['inactive-volatile'] ~= nil, 'inactive runtime should stay attached')
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
