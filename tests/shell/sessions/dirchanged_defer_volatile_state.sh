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
local test_root = vim.fn.fnamemodify('./tmp/pi-dev-test', ':p'):gsub('/$', '')
local old_cwd = test_root .. '/old-cwd'
local new_cwd = test_root .. '/new-cwd'
state.session.current_cwd = old_cwd
state.session.auto_loaded_cwd = old_cwd
state.session.runtime_cwd = old_cwd
state.session.current_file = test_root .. '/old-cwd/session.jsonl'
local runtime = state.set_active_rpc_runtime('default')
runtime.job_id = 700
runtime.active = false
runtime.status = 'idle'
state.sync_active_rpc_runtime(runtime)
ui.set_input_text('unsent cwd draft')

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
  return 701
end
rpc.request = function(message, cb)
  table.insert(calls, message.type)
  if cb then cb({ success = true, data = {} }) end
  return message.type
end
local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

sessions.reload_for_cwd(new_cwd)
assert(#notifications == 1, vim.inspect(notifications))
assert(notifications[1].level == vim.log.levels.WARN, vim.inspect(notifications))
assert(notifications[1].message:find('deferred', 1, true), notifications[1].message)
assert(notifications[1].message:find(new_cwd, 1, true), notifications[1].message)
for _, call in ipairs(calls) do
  assert(call ~= 'stop_all' and call ~= 'start' and call ~= 'switch_session' and call ~= 'new_session', vim.inspect(calls))
end
assert(state.session.current_cwd == old_cwd, state.session.current_cwd or 'nil')
assert(state.session.runtime_cwd == old_cwd, state.session.runtime_cwd or 'nil')
assert(state.active_rpc_runtime().input_text == 'unsent cwd draft', state.active_rpc_runtime().input_text or 'nil')
local output = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(output:find('volatile runtime%-local state exists') ~= nil, output)
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
