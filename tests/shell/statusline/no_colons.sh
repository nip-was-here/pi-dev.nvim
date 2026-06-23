#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')

state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

local active = state.ensure_rpc_runtime('active')
active.job_id = 101
active.active = false
active.waiting_input = false
active.status = 'idle'
state.set_active_rpc_runtime('active')
local line = statusline.render_for_width(80)
assert(line:find('Pi status: idle', 1, true), line)
assert(line:find('idle:', 1, true) == nil, line)

local background = state.ensure_rpc_runtime('background')
background.job_id = 202
background.active = true
background.status = 'running'
active.active = false
active.status = 'idle'
line = statusline.render_for_width(100)
assert(line:find('run 1/2', 1, true), line)
assert(line:find('running:', 1, true) == nil, line)
assert(line:find('idle:', 1, true) == nil, line)

background.waiting_input = true
background.status = 'waiting input'
background.active = true
line = statusline.render_for_width(100)
assert(line:find('run 0/', 1, true) == nil, line)
assert(line:find('wait 1', 1, true), line)
assert(line:find('waiting input:', 1, true) == nil, line)

statusline.set_error('broken')
line = statusline.render_for_width(100)
assert(line:find('err 1 broken', 1, true), line)
assert(line:find('error:', 1, true) == nil, line)
assert(line:find('Pi status:', 1, true), line)
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
