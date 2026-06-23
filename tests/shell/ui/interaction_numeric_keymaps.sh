#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ui = require('pi-dev.ui')
local state = require('pi-dev.state')

local many = {}
for index = 1, 12 do
  table.insert(many, { label = 'item ' .. index, value = index })
end
ui.show_interaction({
  title = 'Many choices',
  items = many,
  on_submit = function(item)
    state._selected_many = item and item.value
  end,
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'many-item interaction should open')
for index = 1, 9 do
  assert(vim.fn.maparg(tostring(index), 'n', false, true).buffer == 1, 'numeric shortcut missing for ' .. index)
end
assert(vim.fn.maparg('10', 'n', false, true).buffer ~= 1, 'multi-digit interaction shortcuts must not be created')

vim.api.nvim_feedkeys('9', 'xt', false)
assert(vim.wait(1000, function() return state._selected_many == 9 end), 'single-digit numeric shortcut should submit item 9')

ui.show_interaction({
  title = 'Few choices',
  items = { { label = 'only one', value = 'one' } },
})
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Few choices' end), 'few-item interaction should open')
assert(vim.fn.maparg('2', 'n', false, true).buffer ~= 1, 'stale numeric shortcut 2 should be cleared')
assert(vim.fn.maparg('10', 'n', false, true).buffer ~= 1, 'stale multi-digit shortcut should be absent')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
