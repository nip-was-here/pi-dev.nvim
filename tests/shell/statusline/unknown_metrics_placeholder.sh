#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local events = require('pi-dev.events')
local statusline = require('pi-dev.statusline')
local state = require('pi-dev.state')

local function assert_unknown_placeholders(line)
  assert(line:find('%$%?'), line)
  assert(line:find('? tok', 1, true), line)
  assert(line:find('ctx ?', 1, true), line)
  assert(line:find('ctx 0%', 1, true) == nil, line)
  assert(line:find('0 tok', 1, true) == nil, line)
end

assert_unknown_placeholders(statusline.render_for_width(160))

statusline.update_from_stats({ contextUsage = { percent = vim.NIL }, tokens = vim.NIL, cost = vim.NIL })
assert_unknown_placeholders(statusline.render_for_width(160))

statusline.update_from_stats({ cost = 0, tokens = { total = 0 }, contextUsage = { percent = 0 } })
local known_zero = statusline.render_for_width(160)
assert(known_zero:find('$0', 1, true), known_zero)
assert(known_zero:find('0 tok', 1, true), known_zero)
assert(known_zero:find('ctx 0%', 1, true), known_zero)
assert(known_zero:find('? tok', 1, true) == nil, known_zero)
assert(known_zero:find('ctx ?', 1, true) == nil, known_zero)

statusline.update_from_stats({ cost = 1.25, tokens = { total = 54321 }, contextUsage = { percent = 91 } })
local before = statusline.render_for_width(160)
assert(before:find('54.3k tok', 1, true), before)
assert(before:find('ctx 91%', 1, true), before)
assert(before:find('$1.25', 1, true), before)

events.emit('*', { type = 'agent_start' })
events.emit('*', { type = 'compaction_start' })
local compacting = statusline.render_for_width(160)
assert(compacting:find('Pi status: compact', 1, true), compacting)
assert(compacting:find('54.3k tok', 1, true) == nil, compacting)
assert(compacting:find('ctx 91%', 1, true) == nil, compacting)
assert(compacting:find('$1.25', 1, true) == nil, compacting)
assert_unknown_placeholders(compacting)

statusline.update_from_stats({ cost = 0.02, tokens = { total = 200 }, contextUsage = { percent = 4 } })
local refreshed = statusline.render_for_width(160)
assert(refreshed:find('$0.02', 1, true), refreshed)
assert(refreshed:find('200 tok', 1, true), refreshed)
assert(refreshed:find('ctx 4%', 1, true), refreshed)

state.reset_rpc_runtime(state.active_rpc_runtime(), false)
assert_unknown_placeholders(statusline.render_for_width(160))
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
