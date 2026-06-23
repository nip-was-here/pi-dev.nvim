#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { prefix = '<leader>a' } })

local rpc = require('pi-dev.rpc')
local original_rpc_start = rpc.start
local original_rpc_request = rpc.request
rpc.start = function()
  return 42
end
rpc.request = function(message, cb)
  if cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

local startinsert_calls = 0
local original_cmd = vim.cmd
vim.cmd = function(command)
  if command == 'startinsert' then
    startinsert_calls = startinsert_calls + 1
  end
  return original_cmd(command)
end

local state = require('pi-dev.state')
local ui = require('pi-dev.ui')
local toggle_map = vim.fn.maparg('<leader>ag', 'n', false, true)
assert(type(toggle_map.callback) == 'function', 'toggle keymap callback missing')
toggle_map.callback()
assert(vim.wait(1000, function()
  return state.ui.visible and state.ui.input_win and vim.api.nvim_get_current_win() == state.ui.input_win
end), 'toggle keymap should focus Pi input when opening the panel')
assert(startinsert_calls == 0, '<leader>ag must focus Pi input in normal mode by default')

ui.hide()
startinsert_calls = 0
ui.focus_input()
assert(vim.wait(1000, function()
  return state.ui.visible and state.ui.input_win and vim.api.nvim_get_current_win() == state.ui.input_win
end), 'focus_input should focus Pi input')
assert(startinsert_calls == 0, 'ui.focus_input must not enter insert mode by default')

vim.cmd = original_cmd
rpc.start = original_rpc_start
rpc.request = original_rpc_request
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
