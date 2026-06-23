#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ui = require('pi-dev.ui')
local api = require('pi-dev.api')
local state = require('pi-dev.state')

local prompted
local steered
api.prompt = function(message)
  prompted = message
end
api.steer = function(message)
  steered = message
end
api.handle_slash_command = function()
  return false
end

state.statusline.active = true
ui.set_input_text('clarify while running')
assert(ui.submit_input() == true)
assert(steered == 'clarify while running', 'active input should be sent as steer')
assert(prompted == nil, 'active input must not use prompt and trigger already-processing errors')

state.statusline.active = false
ui.set_input_text('normal prompt')
assert(ui.submit_input() == true)
assert(prompted == 'normal prompt', 'idle input should still use prompt')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
