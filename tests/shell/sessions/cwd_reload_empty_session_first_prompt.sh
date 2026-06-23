#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_root="$(mktemp -d)"
old_cwd="$(mktemp -d)"
new_cwd="$(mktemp -d)"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<LUA
vim.cmd('cd ' .. vim.fn.fnameescape('$old_cwd'))
require('pi-dev').setup({
  keymaps = { enable = false },
  session_root = '$session_root',
})
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')
local ui = require('pi-dev.ui')

ui.show()
state.session.current_cwd = '$old_cwd'
state.session.auto_loaded_cwd = '$old_cwd'
state.session.runtime_cwd = '$old_cwd'
state.session.current_file = './tmp/pi-dev-test/old-session.jsonl'
state.session.tree_root_file = './tmp/pi-dev-test/old-root.jsonl'
local runtime = state.set_active_rpc_runtime('default')
runtime.job_id = 321
runtime.status = 'idle'
state.sync_active_rpc_runtime(runtime)
state.is_job_running = function(runtime_arg)
  runtime_arg = runtime_arg or state.active_rpc_runtime()
  return runtime_arg and runtime_arg.job_id ~= nil
end

local calls = {}
rpc.stop_all = function()
  table.insert(calls, 'stop_all')
  state.rpc.runtimes = {}
  state.rpc.active_key = 'default'
  state.sync_active_rpc_runtime(state.ensure_rpc_runtime('default'))
end
rpc.start = function()
  table.insert(calls, 'start')
  local active = state.set_active_rpc_runtime('default')
  active.job_id = 654
  active.status = 'idle'
  state.sync_active_rpc_runtime(active)
  return active.job_id
end
rpc.request = function(message, cb)
  table.insert(calls, message.type)
  if message.type == 'new_session' then
    error('cwd reload into an empty current-directory session must not request new_session')
  end
  if cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end
local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

sessions.reload_for_cwd('$new_cwd')
assert(vim.wait(1000, function() return state.session.auto_loaded_cwd == '$new_cwd' end), 'empty cwd reload did not complete')
assert(state.session.current_cwd == '$new_cwd', state.session.current_cwd or 'nil')
assert(state.session.runtime_cwd == '$new_cwd', state.session.runtime_cwd or 'nil')
assert(state.session.current_file == nil, tostring(state.session.current_file))
assert(state.session.tree_root_file == nil, tostring(state.session.tree_root_file))
assert(#notifications == 0, vim.inspect(notifications))
assert(calls[1] == 'stop_all', vim.inspect(calls))
for _, call in ipairs(calls) do
  assert(call ~= 'new_session' and call ~= 'switch_session' and call ~= 'start', vim.inspect(calls))
end
local output = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(output:find('stopped', 1, true) == nil and output:find('Killed', 1, true) == nil, output)
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -rf "$session_root" "$old_cwd" "$new_cwd" "$tmp_lua"
  exit 1
}

rm -rf "$session_root" "$old_cwd" "$new_cwd" "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
