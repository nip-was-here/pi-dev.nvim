#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
trap 'rm -f "$tmp_lua"' EXIT
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ ui = { position = 'right', width = 40, input_height = 6 } })
local ui = require('pi-dev.ui')
local state = require('pi-dev.state')
ui.show()
local out_win = state.ui.output_win
local in_win = state.ui.input_win
assert(vim.api.nvim_win_get_width(out_win) == 40, 'Pi panel should open at configured width')

pcall(vim.api.nvim_win_set_width, out_win, 28)
assert(vim.api.nvim_win_get_width(out_win) == 28, 'test must be able to simulate manual Pi panel resizing')
ui.align()
assert(vim.api.nvim_win_get_width(out_win) == 28, 'regular align/chrome refresh should preserve manual Pi panel width')

local equalize = vim.api.nvim_replace_termcodes('<C-W>=', true, false, true)
vim.api.nvim_feedkeys(equalize, 'xt', false)
assert(vim.wait(1000, function()
  return vim.api.nvim_win_is_valid(out_win) and vim.api.nvim_win_get_width(out_win) == 40
end), ('<C-W>= should restore Pi panel to configured width; got %d'):format(vim.api.nvim_win_get_width(out_win)))
assert(vim.api.nvim_win_get_width(in_win) == 40, 'lower Pi pane should stay aligned with output pane after equalize')

pcall(vim.api.nvim_win_set_width, out_win, 33)
ui.align()
assert(vim.api.nvim_win_get_width(out_win) == 33, 'manual Pi panel resizing must still be possible after equalize repair')
LUA

output="$({
  pidev_nvim_output \
    +"set columns=120 lines=40 laststatus=3" \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
