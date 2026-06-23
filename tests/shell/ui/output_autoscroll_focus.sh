#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 8 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()
local long_text = table.concat(vim.tbl_map(function(i)
  return 'scroll line ' .. i
end, vim.fn.range(1, 80)), '\n')

vim.api.nvim_set_current_win(state.ui.input_win)
renderer.clear('Output scroll unfocused')
renderer.append_system(long_text)
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

assert(vim.wait(1000, function()
  local cursor = vim.api.nvim_win_get_cursor(state.ui.output_win)
  return cursor[1] == vim.api.nvim_buf_line_count(state.ui.output_buf)
end), 'output should auto-scroll to bottom when focus is outside output/session buffer')
assert(output_cursor_above_status_separator(), 'output auto-scroll should keep the final line above the status separator overlay')

renderer.clear('Output scroll focused')
vim.api.nvim_set_current_win(state.ui.output_win)
vim.api.nvim_win_set_cursor(state.ui.output_win, { 1, 0 })
renderer.append_system(long_text)
vim.wait(150, function() return false end)
local cursor = vim.api.nvim_win_get_cursor(state.ui.output_win)
assert(cursor[1] == 1, 'output scroll/cursor should be preserved while user focuses output/session buffer: ' .. vim.inspect(cursor))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
