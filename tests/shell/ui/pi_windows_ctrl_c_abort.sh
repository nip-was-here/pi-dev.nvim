#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local ui = require('pi-dev.ui')
local state = require('pi-dev.state')

local aborts = 0
api.abort = function()
  aborts = aborts + 1
end

ui.show()
local key = vim.api.nvim_replace_termcodes('<C-c>', true, false, true)
for _, win in ipairs({ state.ui.output_win, state.ui.input_win, state.ui.status_win }) do
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(key, 'xt', false)
  assert(vim.wait(1000, function() return aborts > 0 end), 'Ctrl-C should abort in Pi window')
end
assert(aborts == 3, tostring(aborts))

ui.show_interaction({
  title = 'Pi select',
  items = { { label = 'Yes' }, { label = 'No' } },
  on_submit = function() end,
  on_cancel = function() end,
})
vim.api.nvim_set_current_win(state.ui.input_win)
vim.api.nvim_feedkeys(key, 'xt', false)
assert(vim.wait(1000, function() return aborts == 4 end), 'Ctrl-C should abort in Pi interaction/input window')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
