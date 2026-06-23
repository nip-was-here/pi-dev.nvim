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
active.active = true
active.status = 'running'
state.set_active_rpc_runtime('active')

local loading = state.ensure_rpc_runtime('loading')
loading.job_id = 202
loading.loading = true
loading.status = 'loading'
loading.active = false

local compacting = state.ensure_rpc_runtime('compacting')
compacting.job_id = 303
compacting.active = true
compacting.status = 'compacting'

local retrying = state.ensure_rpc_runtime('retrying')
retrying.job_id = 404
retrying.active = true
retrying.status = 'retrying'

local queued = state.ensure_rpc_runtime('queued')
queued.job_id = 505
queued.active = true
queued.status = 'queue update'

local idle = state.ensure_rpc_runtime('idle')
idle.job_id = 606
idle.active = false
idle.status = 'idle'

local line = statusline.render_for_width(120)
assert(line:find('run 1/6', 1, true), line)
assert(line:find('load 1', 1, true), line)
assert(line:find('compact 1', 1, true), line)
assert(line:find('retry 1', 1, true), line)
assert(line:find('queue 1', 1, true), line)
assert(line:find('run 5/6', 1, true) == nil, line)

active.active = false
active.status = 'idle'
line = statusline.render_for_width(120)
assert(line:find('run ', 1, true) == nil, line)
assert(line:find('idle 2', 1, true), line)
assert(line:find('load 1', 1, true), line)
assert(line:find('compact 1', 1, true), line)
assert(line:find('retry 1', 1, true), line)
assert(line:find('queue 1', 1, true), line)
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
