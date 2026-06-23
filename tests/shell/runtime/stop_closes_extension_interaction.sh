#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, rpc = { idle_timeout_ms = 0 } })
local ext = require('pi-dev.extension_ui')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

vim.fn.jobwait = function()
  return { -1 }
end
local stopped_jobs = {}
vim.fn.jobstop = function(job_id)
  stopped_jobs[job_id] = true
  return 1
end
rpc.write = function()
  return true
end

local runtime = state.set_active_rpc_runtime('stop-me')
runtime.job_id = 501
runtime.status = 'waiting input'
runtime.waiting_input = true
runtime.input_text = 'runtime prompt draft'
runtime.editor_text = 'runtime editor draft'
runtime.current_extension_interaction = { kind = 'select', opts = { request_id = 'saved-current' } }
runtime.interaction_queue = { { kind = 'select', opts = { request_id = 'queued' } } }
runtime.pending_extension_ui_request = {
  type = 'extension_ui_request',
  __pi_runtime_key = 'stop-me',
  id = 'pending',
  method = 'select',
  title = 'Pending select',
  options = { 'Yes', 'No' },
}

ui.show()
ext.handle_request({
  type = 'extension_ui_request',
  __pi_runtime_key = 'stop-me',
  id = 'visible-stop',
  method = 'select',
  title = 'Visible stop select',
  options = { 'alpha', 'beta' },
})
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.request_id == 'visible-stop'
end), 'visible extension interaction did not open')

rpc.stop_current()
assert(stopped_jobs[501], 'runtime job should be stopped')
assert(state.ui.interaction == nil, 'visible extension interaction should close when its runtime stops')
assert(state.rpc.runtimes['stop-me'] == nil, 'stopped current runtime should be removed')
local active = state.active_rpc_runtime()
assert(active.key == 'default', active.key)
assert((active.input_text or '') == '', 'new active runtime should not inherit stopped prompt draft')
assert((active.editor_text or '') == '', 'new active runtime should not inherit stopped editor draft')

local reset_runtime = state.ensure_rpc_runtime('reset-only')
reset_runtime.job_id = 777
reset_runtime.pending_extension_ui_request = { id = 'reset-pending' }
reset_runtime.current_extension_interaction = { kind = 'select', opts = { request_id = 'reset-current' } }
reset_runtime.interaction_queue = { { kind = 'select', opts = { request_id = 'reset-queued' } } }
reset_runtime.input_text = 'reset prompt'
reset_runtime.editor_text = 'reset editor'
state.reset_rpc_runtime(reset_runtime, false)
assert(reset_runtime.pending_extension_ui_request == nil)
assert(reset_runtime.current_extension_interaction == nil)
assert(#(reset_runtime.interaction_queue or {}) == 0)
assert(reset_runtime.input_text == '')
assert(reset_runtime.editor_text == '')
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
