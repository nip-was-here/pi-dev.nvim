#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_root="$(mktemp -d)"
empty_cwd="$(mktemp -d)"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<LUA
vim.cmd('cd ' .. vim.fn.fnameescape('$empty_cwd'))
require('pi-dev').setup({
  keymaps = { enable = false },
  session_root = '$session_root',
})
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')
local api = require('pi-dev.api')
local ui = require('pi-dev.ui')

ui.show()
state.session.current_file = './tmp/pi-dev-test/stale-session.jsonl'
state.session.tree_root_file = './tmp/pi-dev-test/stale-root.jsonl'
local runtime = state.set_active_rpc_runtime('default')
runtime.job_id = 123
runtime.status = 'idle'
state.sync_active_rpc_runtime(runtime)
state.is_job_running = function(runtime_arg)
  runtime_arg = runtime_arg or state.active_rpc_runtime()
  return runtime_arg and runtime_arg.job_id ~= nil
end

local calls = {}
rpc.stop_all = function()
  table.insert(calls, 'stop_all')
end
rpc.start = function()
  table.insert(calls, 'start')
  runtime.job_id = runtime.job_id or 123
  state.sync_active_rpc_runtime(runtime)
  return runtime.job_id
end
rpc.request = function(message, cb)
  table.insert(calls, message.type)
  if message.type == 'new_session' then
    error('empty current-directory auto-load must not request new_session')
  end
  if cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end

local callback_response
sessions.load_latest_or_new({ callback = function(response)
  callback_response = response
end })
assert(vim.wait(1000, function() return callback_response ~= nil end), 'load_latest_or_new callback missing')
assert(callback_response.success == true, vim.inspect(callback_response))
assert(state.session.current_cwd == '$empty_cwd', state.session.current_cwd or 'nil')
assert(state.session.auto_loaded_cwd == '$empty_cwd', state.session.auto_loaded_cwd or 'nil')
assert(state.session.current_file == nil, tostring(state.session.current_file))
assert(state.session.tree_root_file == nil, tostring(state.session.tree_root_file))
for _, call in ipairs(calls) do
  assert(call ~= 'new_session' and call ~= 'switch_session' and call ~= 'stop_all', vim.inspect(calls))
end
local before_prompt = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(before_prompt:find('stopped', 1, true) == nil and before_prompt:find('Killed', 1, true) == nil, before_prompt)

api.submit_text('hello from empty cwd')
assert(calls[#calls] == 'prompt', vim.inspect(calls))
local after_prompt = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(after_prompt:find('## User', 1, true), after_prompt)
assert(after_prompt:find('hello from empty cwd', 1, true), after_prompt)
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -rf "$session_root" "$empty_cwd" "$tmp_lua"
  exit 1
}

rm -rf "$session_root" "$empty_cwd" "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
