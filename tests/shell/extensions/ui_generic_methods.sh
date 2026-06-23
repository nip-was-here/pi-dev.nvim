#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ext = require('pi-dev.extension_ui')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local sent = {}
rpc.write = function(message)
  table.insert(sent, message)
  return true
end

ext.handle_request({
  type = 'extension_ui_request',
  id = 'select-1',
  method = 'select',
  title = 'Pick one',
  options = { 'alpha', 'beta' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'select interaction did not open')
vim.api.nvim_feedkeys('2', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), 'select response missing')
assert(sent[1].type == 'extension_ui_response')
assert(sent[1].id == 'select-1')
assert(sent[1].value == 'beta')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'select should restore input buffer')

vim.ui.input = function()
  error('generic extension input/editor should use native pi-dev interaction surface')
end
ext.handle_request({
  type = 'extension_ui_request',
  id = 'input-1',
  method = 'input',
  title = 'Generic input',
  message = 'Enter a generic value.',
  placeholder = 'placeholder text',
  prefill = 'prefilled value',
})
assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil and state.ui.interaction.kind == 'input'
end), 'input interaction did not open')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf, 'input should use interaction buffer')
assert(vim.bo[state.ui.interaction_buf].modifiable == true, 'generic input should be editable')
local input_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false), '\n')
assert(input_text:find('Generic input', 1, true), input_text)
assert(input_text:find('Enter a generic value.', 1, true), input_text)
assert(input_text:find('Placeholder: placeholder text', 1, true), input_text)
local interaction = state.ui.interaction
assert(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false)[1] == 'prefilled value')
vim.api.nvim_buf_set_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false, { 'typed generic value' })
vim.api.nvim_set_current_win(state.ui.input_win)
vim.cmd('stopinsert')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function() return sent[2] ~= nil end), 'input response missing')
assert(sent[2].id == 'input-1' and sent[2].value == 'typed generic value')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'input should restore Pi input buffer')

ext.handle_request({
  type = 'extension_ui_request',
  id = 'editor-1',
  method = 'editor',
  title = 'Generic editor',
  text = 'first line\nsecond line',
})
assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil and state.ui.interaction.kind == 'editor'
end), 'editor interaction did not open')
interaction = state.ui.interaction
local editor_render = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false), '\n')
assert(editor_render:find('Submit with <C%-s>; cancel with <Esc>%.') ~= nil, editor_render)
assert(vim.wo[state.ui.input_win].winbar:find('<C%-s> submit editor input, Esc cancel') ~= nil, vim.wo[state.ui.input_win].winbar)
local editor_value = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false), '\n')
assert(editor_value == 'first line\nsecond line', editor_value)
ext.handle_request({ type = 'extension_ui_request', method = 'set_editor_text', text = 'remote replacement\nmore text' })
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf, 'set_editor_text should keep active editor interaction visible')
editor_value = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false), '\n')
assert(editor_value == 'remote replacement\nmore text', editor_value)
assert(ui.get_input_text() == '', 'set_editor_text should not overwrite Pi input while editor interaction is active')
vim.api.nvim_buf_set_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false, { 'edited line', 'more text' })
vim.api.nvim_set_current_win(state.ui.input_win)
vim.cmd('stopinsert')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
vim.wait(100)
assert(sent[3] == nil, 'normal Enter must not submit generic editor interaction')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-s>', true, false, true), 'xt', false)
assert(vim.wait(1000, function() return sent[3] ~= nil end), 'editor response missing')
assert(sent[3].id == 'editor-1' and sent[3].value == 'edited line\nmore text', vim.inspect(sent[3]))

ext.handle_request({ type = 'extension_ui_request', method = 'setTitle', title = 'Remote title' })
assert(vim.o.titlestring == 'Remote title')
assert(state.ui.output_title == 'Pi chat: Remote title')

ext.handle_request({ type = 'extension_ui_request', method = 'set_editor_text', text = 'draft from extension' })
assert(ui.get_input_text() == '', 'set_editor_text must not overwrite normal Pi input when no editor interaction is open')
assert(state.active_rpc_runtime().editor_text == 'draft from extension')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf)

ext.handle_request({ type = 'extension_ui_request', id = 'editor-2', method = 'editor', title = 'Stored editor' })
assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil and state.ui.interaction.kind == 'editor'
end), 'stored editor interaction did not open')
interaction = state.ui.interaction
editor_value = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false), '\n')
assert(editor_value == 'draft from extension', editor_value)
vim.api.nvim_set_current_win(state.ui.input_win)
vim.cmd('stopinsert')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
assert(vim.wait(1000, function() return sent[4] ~= nil end), 'stored editor cancel response missing')
assert(sent[4].id == 'editor-2' and sent[4].cancelled == true)

ui.set_input_text('hidden prompt draft')
ext.handle_request({
  type = 'extension_ui_request',
  id = 'select-overlay',
  method = 'select',
  title = 'Overlay select',
  options = { 'ok' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'overlay select missing')
ext.handle_request({ type = 'extension_ui_request', method = 'set_editor_text', text = 'editor behind overlay' })
assert(ui.get_input_text() == 'hidden prompt draft', 'set_editor_text must not overwrite hidden Pi input behind a select overlay')
assert(state.active_rpc_runtime().editor_text == 'editor behind overlay')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf, 'select overlay should stay visible')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[5] ~= nil end), 'overlay select response missing')
assert(sent[5].id == 'select-overlay' and sent[5].value == 'ok')
assert(ui.get_input_text() == 'hidden prompt draft', 'Pi input draft should survive overlay close')

ext.handle_request({ type = 'extension_ui_request', id = 'bad-1', method = 'not_a_method' })
assert(vim.wait(1000, function() return sent[6] ~= nil end), 'unsupported method response missing')
assert(sent[6].id == 'bad-1' and sent[6].cancelled == true)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
