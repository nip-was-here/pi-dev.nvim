#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ext = require('pi-dev.extension_ui')
local state = require('pi-dev.state')
local sent = {}
require('pi-dev.rpc').write = function(message)
  table.insert(sent, message)
  return true
end

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end
ext.handle_request({ type = 'extension_ui_request', method = 'notify', message = 'hello notice', notifyType = 'warn' })
assert(#notifications == 1 and notifications[1].message == 'hello notice', vim.inspect(notifications))

ext.handle_request({ type = 'extension_ui_request', id = 'confirm-no', method = 'confirm', title = 'Confirm?', message = 'No path' })
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'confirm interaction missing')
vim.api.nvim_feedkeys('2', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), 'confirm no response missing')
assert(sent[1].id == 'confirm-no' and sent[1].confirmed == false and sent[1].cancelled == false, vim.inspect(sent[1]))

ext.handle_request({ type = 'extension_ui_request', id = 'select-cancel', method = 'select', title = 'Select?', options = { 'a', 'b' } })
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'select interaction missing')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
assert(vim.wait(1000, function() return sent[2] ~= nil end), 'select cancel response missing')
assert(sent[2].id == 'select-cancel' and sent[2].cancelled == true, vim.inspect(sent[2]))

vim.ui.input = function()
  error('generic editor should use native pi-dev interaction surface')
end
ext.handle_request({ type = 'extension_ui_request', id = 'editor-cancel', method = 'editor', title = 'Editor title', prefill = 'draft' })
assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil and state.ui.interaction.kind == 'editor'
end), 'editor interaction missing')
local interaction = state.ui.interaction
assert(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false)[1] == 'draft')
vim.api.nvim_set_current_win(state.ui.input_win)
vim.cmd('stopinsert')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
assert(vim.wait(1000, function() return sent[3] ~= nil end), 'editor cancel response missing')
assert(sent[3].id == 'editor-cancel' and sent[3].cancelled == true, vim.inspect(sent[3]))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
