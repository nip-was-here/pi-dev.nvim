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

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

local requests = {}
rpc.request = function(message, cb)
  table.insert(requests, message)
  if cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end
rpc.start = function(key, opts)
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key)
  if not opts or opts.activate ~= false then
    state.set_active_rpc_runtime(runtime.key)
  end
  runtime.job_id = runtime.job_id or 100
  runtime.status = runtime.status or 'idle'
  state.sync_active_rpc_runtime(runtime)
  return runtime.job_id
end

local original_is_job_running = state.is_job_running
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

local current = vim.fn.tempname() .. '.jsonl'
state.session.current_file = current
local active = state.ensure_rpc_runtime('default')
active.job_id = 100
active.session_file = current
active.status = 'idle'
state.set_active_rpc_runtime('default')

local callback_response
local request_id = sessions.switch_to(current, { title = 'Same session' }, function(response)
  callback_response = response
end)
assert(request_id == nil, 'same current session should not send a switch request')
assert(callback_response and callback_response.current == true and callback_response.cancelled == true, vim.inspect(callback_response))
assert(#requests == 0, vim.inspect(requests))
assert(#notifications == 1 and notifications[1].message:find('already current', 1, true), vim.inspect(notifications))

requests = {}
notifications = {}
local forced = vim.fn.tempname() .. '.jsonl'
state.session.current_file = forced
state.active_rpc_runtime().session_file = forced
sessions.switch_to(forced, { title = 'Forced same session', force_switch = true })
assert(requests[1] and requests[1].type == 'switch_session' and requests[1].sessionPath == forced, vim.inspect(requests))
assert(#notifications == 0, vim.inspect(notifications))

requests = {}
notifications = {}
local root_a = vim.fn.tempname() .. '.jsonl'
local root_b = vim.fn.tempname() .. '.jsonl'
state.session.current_file = root_a
state.rpc.runtimes = {}
state.rpc.active_key = 'branch-a'
local branch_a = state.ensure_rpc_runtime('branch-a')
branch_a.job_id = 101
branch_a.status = 'idle'
branch_a.session_file = root_a
branch_a.branch_root = root_a
branch_a.branch_entry_id = 'same-entry-id'
state.set_active_rpc_runtime('branch-a')
sessions.switch_to(root_b, {
  title = 'Same entry in a different root',
  tree_root_file = root_b,
  branch_entry_id = 'same-entry-id',
})
assert(requests[1] and requests[1].type == 'switch_session' and requests[1].sessionPath == root_b, vim.inspect(requests))
assert(#notifications == 0, 'same entry id in a different root must not be treated as current: ' .. vim.inspect(notifications))

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
require('pi-dev.config').options.session_root = session_root
local root_file = session_root .. '/root.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'session_info', name = 'Current Waiting Session' }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'current waiting prompt' } }),
}, root_file)
state.session.current_file = root_file
state.rpc.runtimes = {}
state.rpc.active_key = 'current-waiting'
local waiting = state.ensure_rpc_runtime('current-waiting')
waiting.job_id = 200
waiting.active = true
waiting.waiting_input = true
waiting.status = 'waiting input'
waiting.session_file = root_file
waiting.branch_root = root_file
waiting.branch_entry_id = 'u1'
waiting.pending_extension_ui_request = {
  type = 'extension_ui_request',
  __pi_runtime_key = 'current-waiting',
  id = 'current-select',
  method = 'select',
  title = 'Current waiting select',
  options = { 'Yes', 'No' },
}
state.set_active_rpc_runtime('current-waiting')

requests = {}
notifications = {}
sessions.waiting()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Pi waiting input' end), 'waiting picker should open')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function() return #notifications > 0 end), vim.inspect(notifications))
assert(notifications[#notifications].message:find('Pi RPC branch is already current', 1, true), vim.inspect(notifications))
for _, request in ipairs(requests) do
  assert(request.type ~= 'get_messages' and request.type ~= 'switch_session' and request.type ~= 'fork', 'current waiting branch selection must be no-op: ' .. vim.inspect(requests))
end
assert(state.rpc.active_key == 'current-waiting', state.rpc.active_key)

state.is_job_running = original_is_job_running
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
