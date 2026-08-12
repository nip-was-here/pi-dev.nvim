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

local sent = {}
rpc.start = function()
  local runtime = state.active_rpc_runtime()
  runtime.job_id = 42
  return 42
end
rpc.request = function(message, cb)
  table.insert(sent, message)
  if message.type == 'get_available_roles' and cb then
    cb({ success = false, command = 'get_available_roles', error = 'Unknown command: get_available_roles' })
  elseif message.type == 'set_role' and cb then
    cb({ success = false, command = 'set_role', error = 'Unknown command: set_role' })
  elseif message.type == 'prompt' and cb then
    cb({ success = true, command = 'prompt', data = {} })
  elseif cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

assert(api.submit_text('/role') == true, '/role without args should be handled')
assert(sent[#sent - 1].type == 'get_available_roles', vim.inspect(sent))
assert(sent[#sent].type == 'prompt' and sent[#sent].message == '/role', vim.inspect(sent[#sent]))
assert(state.statusline.error == nil, tostring(state.statusline.error))

assert(api.submit_text('/role architect') == true, '/role with arg should be handled')
assert(sent[#sent - 1].type == 'set_role' and sent[#sent - 1].role == 'architect', vim.inspect(sent))
assert(sent[#sent].type == 'prompt' and sent[#sent].message == '/role architect', vim.inspect(sent[#sent]))
assert(state.statusline.error == nil, tostring(state.statusline.error))
LUA

pidev_run_lua_file "$tmp_lua"
