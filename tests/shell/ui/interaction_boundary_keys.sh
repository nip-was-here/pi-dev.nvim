#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ui = require('pi-dev.ui')
local state = require('pi-dev.state')

ui.show_interaction({
  title = 'Boundary choices',
  filetype = 'text',
  markdown = false,
  numbered = false,
  selection_marker = false,
  selected = 3,
  items = {
    { label = 'context header', selectable = false },
    { label = 'first selectable', value = 'first' },
    { label = 'middle selectable', value = 'middle' },
    { label = 'context footer', selectable = false },
  },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'interaction should open')
assert(state.ui.interaction.selected == 3, 'test should start on middle selectable item')

vim.api.nvim_feedkeys('gg', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.selected == 2
end), 'gg should focus the first selectable interaction item')
assert(vim.api.nvim_win_get_cursor(state.ui.input_win)[1] == state.ui.interaction.item_line_by_index[2], 'gg should move cursor to selected item line')

vim.api.nvim_feedkeys('G', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.selected == 3
end), 'G should focus the last selectable interaction item, skipping non-selectable context rows')
assert(vim.api.nvim_win_get_cursor(state.ui.input_win)[1] == state.ui.interaction.item_line_by_index[3], 'G should move cursor to selected item line')

ui.show_interaction({
  title = 'Output surface tree',
  surface = 'output',
  filetype = 'text',
  markdown = false,
  numbered = false,
  selection_marker = false,
  selected = 2,
  items = {
    { label = 'tree context header', selectable = false },
    { label = 'tree first selectable', value = 'first' },
    { label = 'tree middle selectable', value = 'middle' },
    { label = 'tree context footer', selectable = false },
  },
})
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Output surface tree'
end), 'output-surface interaction should open')

vim.api.nvim_feedkeys('G', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.selected == 3
end), 'G should focus the last selectable output-surface item')
assert(vim.api.nvim_win_get_cursor(state.ui.output_win)[1] == state.ui.interaction.item_line_by_index[3], 'G should move output cursor to selected item line')

vim.api.nvim_feedkeys('gg', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.selected == 2
end), 'gg should focus the first selectable output-surface item')
assert(vim.api.nvim_win_get_cursor(state.ui.output_win)[1] == state.ui.interaction.item_line_by_index[2], 'gg should move output cursor to selected item line')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
