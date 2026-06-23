#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

mkdir -p "$ROOT_DIR/tmp"
tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 10, render = { fold_tool_output_over = 3 } } })
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local function closed_fold_count(win)
  local count = 0
  local starts = {}
  vim.api.nvim_win_call(win, function()
    local total = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    for line = 1, total do
      local start_line = vim.fn.foldclosed(line)
      if start_line ~= -1 and not starts[start_line] then
        starts[start_line] = true
        count = count + 1
      end
    end
  end)
  return count
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
  vim.wait(100, function() return false end)
end

local function assert_closed(win, expected, label)
  local actual = closed_fold_count(win)
  assert(actual == expected, label .. ': expected ' .. expected .. ' closed folds, got ' .. actual)
end

ui.show()
renderer.clear('output fold count commands')
local long_output = table.concat(vim.tbl_map(function(i) return 'line ' .. i end, vim.fn.range(1, 12)), '\n')
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'out-1', toolName = 'bash', args = { command = 'printf first' } })
renderer.handle_event({ type = 'tool_execution_end', toolCallId = 'out-1', toolName = 'bash', result = { content = { { type = 'text', text = long_output } } } })
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'out-2', toolName = 'bash', args = { command = 'printf second' } })
renderer.handle_event({ type = 'tool_execution_end', toolCallId = 'out-2', toolName = 'bash', result = { content = { { type = 'text', text = long_output } } } })
vim.api.nvim_set_current_win(state.ui.output_win)
assert_closed(state.ui.output_win, 2, 'output starts folded')
feed('100zr')
assert_closed(state.ui.output_win, 0, 'output 100zr opens all folds')
feed('100zm')
assert_closed(state.ui.output_win, 2, 'output 100zm closes all folds')
feed('zA')
assert_closed(state.ui.output_win, 0, 'output zA opens whole buffer')
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'out-3', toolName = 'bash', args = { command = 'printf third' } })
renderer.handle_event({ type = 'tool_execution_end', toolCallId = 'out-3', toolName = 'bash', result = { content = { { type = 'text', text = long_output } } } })
assert_closed(state.ui.output_win, 0, 'new auto-folds should stay open after output zA opened all folds')
feed('zA')
assert_closed(state.ui.output_win, 3, 'output zA closes whole buffer')
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'out-4', toolName = 'bash', args = { command = 'printf fourth' } })
renderer.handle_event({ type = 'tool_execution_end', toolCallId = 'out-4', toolName = 'bash', result = { content = { { type = 'text', text = long_output } } } })
assert_closed(state.ui.output_win, 4, 'new auto-folds should close normally after output zA closed all folds')

ui.show_interaction({
  title = 'interaction fold count commands',
  items = {
    { label = 'root one' }, { label = 'child one' }, { label = 'child two' },
    { label = 'root two' }, { label = 'child three' }, { label = 'child four' },
  },
  folds = {
    { start_index = 1, end_index = 3, closed = true },
    { start_index = 4, end_index = 6, closed = true },
  },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'interaction should open')
vim.api.nvim_set_current_win(state.ui.input_win)
assert_closed(state.ui.input_win, 2, 'interaction starts folded')
feed('100zr')
assert_closed(state.ui.input_win, 0, 'interaction 100zr opens all folds')
feed('100zm')
assert_closed(state.ui.input_win, 2, 'interaction 100zm closes all folds')
feed('zA')
assert_closed(state.ui.input_win, 0, 'interaction zA opens whole buffer')
feed('zA')
assert_closed(state.ui.input_win, 2, 'interaction zA closes whole buffer')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
