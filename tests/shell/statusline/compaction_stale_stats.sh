#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local events = require('pi-dev.events')
local rpc = require('pi-dev.rpc')
local statusline = require('pi-dev.statusline')
local state = require('pi-dev.state')

statusline.update_from_stats({ cost = 1.25, tokens = { total = 54321 }, contextUsage = { percent = 91 } })
local before = statusline.render_for_width(140)
assert(before:find('54.3k tok', 1, true), before)
assert(before:find('ctx 91%', 1, true), before)
assert(before:find('$1.25', 1, true), before)

events.emit('*', { type = 'agent_start' })
events.emit('*', { type = 'compaction_start' })
local compacting = statusline.render_for_width(140)
assert(compacting:find('Pi status: compact', 1, true), compacting)
assert(compacting:find('54.3k tok', 1, true) == nil, compacting)
assert(compacting:find('ctx 91%', 1, true) == nil, compacting)
assert(compacting:find('ctx ?', 1, true), compacting)
assert(compacting:find('ctx 0%', 1, true) == nil, compacting)
assert(compacting:find('$1.25', 1, true) == nil, compacting)
assert(state.active_rpc_runtime().tokens == nil, 'active runtime tokens should be cleared while compacting')

statusline.update_from_stats({ cost = 0.02, tokens = { total = 200 }, contextUsage = { percent = 4 } })
local refreshed = statusline.render_for_width(140)
assert(refreshed:find('200 tok', 1, true), refreshed)
assert(refreshed:find('ctx 4%', 1, true), refreshed)
assert(refreshed:find('$0.02', 1, true), refreshed)

local background = state.ensure_rpc_runtime('background-compaction')
background.job_id = 101
background.active = true
background.status = 'running'
background.cost = 2.5
background.tokens = 777
background.context_usage = { percent = 70 }
rpc._handle_chunk(vim.json.encode({ type = 'compaction_start' }) .. '\n', background)
assert(background.status == 'compacting', background.status)
assert(background.tokens == nil and background.context_usage == nil and background.cost == nil, 'background compaction should clear stale stats')
statusline.update_from_stats({ contextUsage = { percent = vim.NIL }, tokens = vim.NIL }, { runtime = background })
assert(background.tokens == nil, 'vim.NIL token stats should stay unknown instead of normalizing to zero')
state.set_active_rpc_runtime('background-compaction')
assert(statusline.render_for_width(140):find('ctx ?', 1, true), statusline.render_for_width(140))
assert(statusline.render_for_width(140):find('ctx 0%', 1, true) == nil, statusline.render_for_width(140))
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
