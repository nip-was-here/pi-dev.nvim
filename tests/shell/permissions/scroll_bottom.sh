#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 8 } })
local ext = require('pi-dev.extension_ui')
local renderer = require('pi-dev.renderer')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

rpc.write = function()
  return true
end

local function output_cursor_above_status_separator()
  local status_win = state.ui.status_win
  if not status_win or not vim.api.nvim_win_is_valid(status_win) then
    return true
  end
  local config = vim.api.nvim_win_get_config(status_win)
  if config.relative ~= 'win' or config.win ~= state.ui.output_win then
    return true
  end
  local status_row = tonumber(config.row)
  if not status_row or status_row <= 0 then
    return true
  end
  local winline = vim.api.nvim_win_call(state.ui.output_win, function()
    return vim.fn.winline()
  end)
  return winline < status_row
end

local function output_is_at_bottom()
  local cursor = vim.api.nvim_win_get_cursor(state.ui.output_win)
  return cursor[1] == vim.api.nvim_buf_line_count(state.ui.output_buf) and output_cursor_above_status_separator()
end

ui.focus_input()
renderer.clear('Permission scroll test')
renderer.append_system(table.concat(vim.tbl_map(function(index)
  return 'history line ' .. index
end, vim.fn.range(1, 120)), '\n'))
assert(vim.wait(1000, output_is_at_bottom), 'setup should start with output at bottom')

vim.api.nvim_win_call(state.ui.output_win, function()
  vim.api.nvim_win_set_cursor(state.ui.output_win, { 5, 0 })
  vim.cmd('normal! zt')
end)
vim.api.nvim_set_current_win(state.ui.input_win)
assert(vim.api.nvim_get_current_win() ~= state.ui.output_win, 'focus must be outside output for this regression')
assert(not output_is_at_bottom(), 'test setup should move output away from the bottom')

ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-scroll-bottom',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'git status'. Allow this command?",
  options = { 'Yes', 'Yes, for this session', 'No', 'No, provide reason' },
})

assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil
end), 'permission interaction should be visible')
assert(vim.wait(1000, output_is_at_bottom), 'permission request should force output to bottom when focus is outside output')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
