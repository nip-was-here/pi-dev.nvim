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
local statusline = require('pi-dev.statusline')

local sent = {}
rpc.start = function()
  return 42
end
rpc.request = function(message, cb)
  table.insert(sent, message)
  if cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

statusline.set_error('Agent is already processing')
api.prompt('continue after error')
assert(state.statusline.error == nil, 'prompt should clear stale error immediately')
assert(statusline.render_for_width(100):find('Agent is already processing', 1, true) == nil)
assert(sent[#sent].type == 'prompt')

statusline.set_error('Agent is already processing')
state.statusline.active = true
api.steer('clarify running work')
assert(state.statusline.error == nil, 'steer should clear stale error immediately')
assert(state.statusline.status == 'running', state.statusline.status)
assert(sent[#sent].type == 'steer')

statusline.set_error('Agent is already processing')
state.statusline.active = true
api.follow_up('follow up running work')
assert(state.statusline.error == nil, 'follow_up should clear stale error immediately')
assert(sent[#sent].type == 'follow_up')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
