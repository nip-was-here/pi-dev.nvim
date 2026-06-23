#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { prefix = '<leader>a' } })

local internal_keymaps = {
  '<leader>ap',
  '<leader>ai',
  '<leader>aq',
  '<leader>ac',
  '<leader>aK',
  '<leader>aa',
  '<leader>aA',
  '<leader>an',
  '<leader>ar',
  '<leader>aR',
  '<leader>am',
  '<leader>at',
  '<leader>aw',
}
local function assert_internal_keymaps(expected, suffix)
  for _, lhs in ipairs(internal_keymaps) do
    if expected then
      assert(vim.fn.maparg(lhs, 'n') ~= '', lhs .. ' keymap missing ' .. suffix)
    else
      assert(vim.fn.maparg(lhs, 'n') == '', lhs .. ' keymap should be inactive ' .. suffix)
    end
  end
end

assert(vim.fn.maparg('<leader>ag', 'n') ~= '', 'toggle keymap missing')
assert_internal_keymaps(false, 'while Pi panel is closed')

local rpc = require('pi-dev.rpc')
local original_rpc_start = rpc.start
local original_rpc_request = rpc.request
rpc.start = function() return 42 end
rpc.request = function(message, cb)
  if cb then
    cb({ success = true, data = {} })
  end
  return message.type
end
local toggle_map = vim.fn.maparg('<leader>ag', 'n', false, true)
assert(type(toggle_map.callback) == 'function', 'toggle keymap callback missing')
toggle_map.callback()
local state = require('pi-dev.state')
assert(vim.wait(1000, function()
  return state.ui.visible and state.ui.input_win and vim.api.nvim_get_current_win() == state.ui.input_win
end), 'toggle keymap should focus Pi input when opening the panel')
assert_internal_keymaps(true, 'while Pi panel is open')
assert(vim.fn.maparg('<leader>a<Tab>', 'n') == '', 'old cycle keymap should stay unmapped after remap')
assert(vim.fn.maparg('<leader>ax', 'n') == '', 'old stop RPC keymap should stay unmapped after remap')
rpc.start = original_rpc_start
rpc.request = original_rpc_request
require('pi-dev.ui').hide()
assert(vim.wait(1000, function() return require('pi-dev.state').ui.visible ~= true end), 'Pi panel should hide')
assert(vim.fn.maparg('<leader>ag', 'n') ~= '', 'toggle keymap should stay available after hide')
assert_internal_keymaps(false, 'after Pi panel is hidden')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
