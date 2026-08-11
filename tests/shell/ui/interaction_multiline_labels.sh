#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

ui.show_interaction({
  title = 'Pick with\nextra title text',
  message = 'Choose an option.',
  items = {
    { label = 'Yes, for this session\nAllow bash "git *" for this session' },
    { label = 'No', meta = 'plain\nmetadata' },
  },
})

assert(state.ui.interaction ~= nil, 'interaction should remain visible')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf, 'interaction should render in lower pane')
local lines = vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false)
local text = table.concat(lines, '\n')
assert(text:find('Pick with extra title text', 1, true), text)
assert(text:find('Yes, for this session Allow bash "git *" for this session', 1, true), text)
assert(text:find('plain metadata', 1, true), text)
assert(vim.bo[state.ui.interaction_buf].modifiable == false, 'interaction buffer should be locked after render')
assert(vim.bo[state.ui.interaction_buf].readonly == true, 'interaction buffer should be readonly after render')

ui.close_interaction()
ui.show_interaction({ title = 'Next permission', kind = 'permission', items = { { label = 'Yes' }, { label = 'No' } } })
assert(state.ui.interaction and state.ui.interaction.title == 'Next permission', 'next interaction should still render after multiline labels')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf, 'next interaction should stay in body/lower pane')
LUA

pidev_run_lua_file "$tmp_lua"
