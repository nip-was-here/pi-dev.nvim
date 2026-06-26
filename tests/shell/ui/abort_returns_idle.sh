#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local runtime = state.active_rpc_runtime()
runtime.job_id = 42
runtime.active = true
runtime.status = 'running'
state.statusline.active = true
state.statusline.status = 'running'
state.sync_active_rpc_runtime(runtime)

state.is_job_running = function(candidate)
  return candidate == nil or candidate == runtime
end
rpc.start = function()
  return runtime.job_id
end

local sent = {}
rpc.request = function(message, cb)
  table.insert(sent, message)
  if message.type == 'abort' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end

api.abort()
assert(runtime.active == false, 'abort should clear active runtime work immediately')
assert(state.statusline.active == false, 'abort should clear active status immediately')
assert(state.statusline.status == 'idle', state.statusline.status)

ui.set_input_text('new work after abort')
assert(ui.submit_input() == true)
assert(sent[#sent].type == 'prompt', 'input after abort should start a prompt, got ' .. vim.inspect(sent[#sent]))
assert(sent[#sent].message == 'new work after abort')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
