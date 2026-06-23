#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local extension_ui = require('pi-dev.extension_ui')
local state = require('pi-dev.state')

state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end
local active = state.set_active_rpc_runtime('active')
active.job_id = 101
active.status = 'idle'
state.sync_active_rpc_runtime(active)
local background = state.ensure_rpc_runtime('background')
background.job_id = 202
background.status = 'idle'
state.sync_active_rpc_runtime(background)

extension_ui.handle_request({
  __pi_runtime_key = 'background',
  type = 'extension_ui_request',
  id = 'notice-1',
  method = 'notify',
  message = 'background notice',
})
background = state.ensure_rpc_runtime('background')
assert(background.pending_extension_ui_request == nil, vim.inspect(background.pending_extension_ui_request))
assert(background.waiting_input ~= true, vim.inspect(background))
assert(background.status == 'idle', vim.inspect(background))

extension_ui.handle_request({
  __pi_runtime_key = 'background',
  type = 'extension_ui_request',
  id = 'select-1',
  method = 'select',
  title = 'background select',
  options = { 'Yes', 'No' },
})
background = state.ensure_rpc_runtime('background')
assert(background.pending_extension_ui_request and background.pending_extension_ui_request.id == 'select-1', vim.inspect(background))
assert(background.waiting_input == true, vim.inspect(background))
assert(background.status == 'waiting input', vim.inspect(background))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
