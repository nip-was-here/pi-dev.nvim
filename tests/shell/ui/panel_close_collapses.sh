#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { position = 'right', width = 40, input_height = 6 } })
local ui = require('pi-dev.ui')
local state = require('pi-dev.state')

local function assert_panel_visible()
  assert(state.ui.visible == true, 'panel should be marked visible')
  assert(state.ui.output_win and vim.api.nvim_win_is_valid(state.ui.output_win), 'output window should be valid')
  assert(state.ui.input_win and vim.api.nvim_win_is_valid(state.ui.input_win), 'input window should be valid')
  assert(state.ui.status_win and vim.api.nvim_win_is_valid(state.ui.status_win), 'status separator should be valid')
end

local function assert_panel_hidden(label)
  assert(vim.wait(1000, function()
    return state.ui.visible == false
      and state.ui.output_win == nil
      and state.ui.input_win == nil
      and state.ui.status_win == nil
  end), label .. ': closing one Pi pane should collapse the whole panel')
end

ui.show()
assert_panel_visible()
local input_win = state.ui.input_win
vim.api.nvim_win_close(input_win, true)
assert_panel_hidden('input close')

ui.show()
assert_panel_visible()
local output_win = state.ui.output_win
vim.api.nvim_win_close(output_win, true)
assert_panel_hidden('output close')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
