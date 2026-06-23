#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ui = require('pi-dev.ui')
local ext = require('pi-dev.extension_ui')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')

rpc.write = function()
  return true
end

ui.show()
local file_win = vim.api.nvim_get_current_win()
ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-no-steal',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'pwd'. Allow this command?",
  options = { 'Yes', 'No' },
})
assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil and vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf
end), 'permission interaction did not appear while focus was outside Pi input')
assert(vim.api.nvim_get_current_win() == file_win, 'permission interaction must not steal focus when user is outside Pi input')
ui.close_interaction()

ui.focus_input()
ui.set_input_text('half typed prompt')
vim.api.nvim_set_current_win(state.ui.input_win)

ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-focus',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'git status'. Allow this command?",
  options = { 'Yes', 'Yes, for this session', 'No', 'No, provide reason' },
})

assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil and vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf
end), 'permission interaction did not appear')

assert(table.concat(vim.api.nvim_buf_get_lines(state.ui.input_buf, 0, -1, false), '\n') == 'half typed prompt')
assert(vim.api.nvim_get_current_win() == state.ui.input_win, 'permission interaction should keep focus in the Pi lower pane')
assert(vim.bo[state.ui.input_buf].modifiable == true, 'Pi input draft buffer should remain editable')
assert(vim.bo[state.ui.interaction_buf].modifiable == false, 'permission interaction buffer should be read-only')
assert(vim.bo[state.ui.interaction_buf].readonly == true, 'focused permission interaction buffer should be read-only')
assert(vim.wo[state.ui.input_win].number == false, 'permission interaction window must hide absolute line numbers')
assert(vim.wo[state.ui.input_win].relativenumber == false, 'permission interaction window must hide relative line numbers')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
