#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({
  keymaps = { enable = false },
  ui = { width = 44, input_height = 8 },
})
local ext = require('pi-dev.extension_ui')
local format = require('pi-dev.format')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')
require('pi-dev.rpc').write = function()
  return true
end

ui.focus_input()
local long_path = '/very/long/external/directory/name/with/many/segments/that/used/to/wrap/and/hide/the/fourth/permission/choice'
ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-long-external-dir',
  method = 'select',
  title = "Permission Required\nPi requested external directory access outside working directory '/repo': " .. long_path .. '. Allow?',
  options = { 'Yes', 'Yes, allow bash "' .. long_path .. '/*" for this session', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'permission interaction missing')

local width = format.window_text_width(state.ui.input_win)
local lines = vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false)
local text = table.concat(lines, '\n')
assert(text:find('#### Permission Required', 1, true), text)
assert(text:find('External directory access:', 1, true), text)
assert(text:find('...', 1, true), text)
assert(text:find(long_path, 1, true) == nil, text)
assert(text:find('No, with reason', 1, true), text)
assert(#lines == 8, vim.inspect(lines))
for _, line in ipairs(lines) do
  assert(vim.fn.strdisplaywidth(line) <= width, string.format('line wider than pane (%d > %d): %s', vim.fn.strdisplaywidth(line), width, line))
end
assert(state.ui.interaction.items[4] and state.ui.interaction.items[4].label == 'No, with reason', vim.inspect(state.ui.interaction.items))
assert(state.ui.interaction.item_line_by_index[4] == 8, vim.inspect(state.ui.interaction.item_line_by_index))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
