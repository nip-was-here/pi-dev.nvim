#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

output="$({
  pidev_nvim_output \
    +"lua require('pi-dev').setup({ keymaps = { enable = false } })" \
    +"lua local statusline = require('pi-dev.statusline'); statusline.update_from_stats({ tokens = { total = vim.NIL }, contextUsage = { tokens = vim.NIL, contextWindow = vim.NIL, percent = vim.NIL } }); local line = statusline.render_for_width(120); assert(line:find('? tok', 1, true), line); assert(line:find('ctx ?', 1, true), line); assert(line:find('0 tok', 1, true) == nil, line); assert(line:find('ctx 0%', 1, true) == nil, line)" \
    +"lua local statusline = require('pi-dev.statusline'); local state = require('pi-dev.state'); local original_is_job_running = state.is_job_running; state.is_job_running = function() return true end; statusline.update_from_stats({ cost = 0.42, tokens = { total = 9999 }, contextUsage = { percent = 88 } }); local before = statusline.render_for_width(120); assert(before:find('10.0k tok', 1, true), before); assert(before:find('ctx 88%', 1, true), before); state.statusline.active = true; state.statusline.status = 'running'; statusline.update_from_state({ isCompacting = true }); local compacting = statusline.render_for_width(120); assert(state.statusline.status == 'compacting', state.statusline.status); assert(compacting:find('Pi status: compact', 1, true), compacting); assert(compacting:find('10.0k tok', 1, true) == nil, compacting); assert(compacting:find('ctx 88%', 1, true) == nil, compacting); assert(compacting:find('ctx ?', 1, true), compacting); assert(compacting:find('ctx 0%', 1, true) == nil, compacting); assert(compacting:find('0.42', 1, true) == nil, compacting); statusline.update_from_state({ isCompacting = false, isStreaming = false }); local after = statusline.render_for_width(120); assert(state.statusline.active == false, 'compaction get_state should use current isStreaming=false'); assert(state.statusline.status == 'idle', state.statusline.status); assert(after:find('Pi status: idle', 1, true), after); assert(after:find('ctx ?', 1, true), after); statusline.update_from_stats({ tokens = { total = 12 }, contextUsage = { percent = 3 } }); local refreshed = statusline.render_for_width(120); assert(refreshed:find('12 tok', 1, true), refreshed); assert(refreshed:find('ctx 3%', 1, true), refreshed); state.is_job_running = original_is_job_running"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
