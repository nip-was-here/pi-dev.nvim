#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ext = require('pi-dev.extension_ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')
local sent = {}
require('pi-dev.rpc').write = function(message)
  table.insert(sent, message)
  return true
end

ui.focus_input()
renderer.clear('Permission denial reason test')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'deny-tool',
  toolName = 'bash',
  args = { command = 'rm -rf tmp' },
})

ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-deny',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'rm -rf tmp'. Allow this command?",
  options = { 'Yes', 'Yes, for this session', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'permission select did not open')
vim.api.nvim_feedkeys('4', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), 'permission denial choice not sent')
assert(sent[1].id == 'perm-deny' and sent[1].value == 'No, provide reason')

ext.handle_request({
  type = 'extension_ui_request',
  id = 'deny-reason',
  method = 'input',
  title = 'Why deny?',
  placeholder = 'reason',
})
assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil and state.ui.interaction.kind == 'text'
end), 'denial reason input did not open')
local interaction = state.ui.interaction
vim.api.nvim_buf_set_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false, { 'unsafe command' })
vim.api.nvim_set_current_win(state.ui.input_win)
vim.cmd('stopinsert')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function() return sent[2] ~= nil end), 'normal Enter should submit denial reason')
assert(sent[2].id == 'deny-reason' and sent[2].value == 'unsafe command')
assert(state.ui.interaction == nil, 'denial reason interaction should close after normal Enter')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'deny-tool',
  toolName = 'bash',
  result = { content = { { type = 'text', text = "[pi-permission-system] User denied bash command 'rm -rf tmp'. Reason: unsafe command" } } },
})
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('[pi-permission-system]', 1, true) == nil, text)
assert(text:find('#### Permission request: bash `rm -rf tmp` - No, with reason: "unsafe command"', 1, true) ~= nil, text)
assert(text:find('Permission result: denied:', 1, true) == nil, text)
assert(text:find('- denied:', 1, true) == nil, text)

renderer.clear('Permission raw denial style test')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'deny-tool-raw',
  toolName = 'bash',
  args = { command = 'rm -f tmp/new_state.lua tmp/new_rpc.lua' },
})
ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-raw-deny',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'rm -f tmp/new_state.lua tmp/new_rpc.lua'. Allow this command?",
  options = { 'Yes', 'Yes, for this session', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'raw denial permission select did not open')
vim.api.nvim_feedkeys('3', 'xt', false)
assert(vim.wait(1000, function() return sent[3] ~= nil end), 'permission no response missing')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'deny-tool-raw',
  toolName = 'bash',
  result = { content = { { type = 'text', text = "[pi-permission-system] is not permitted to run 'bash' command 'rm -f tmp/new_state.lua tmp/new_rpc.lua' (matched 'rm *')." } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('[pi-permission-system]', 1, true) == nil, text)
assert(text:find('is not permitted to run', 1, true) == nil, text)
assert(text:find("matched 'rm *'", 1, true) == nil, text)
assert(text:find('#### Permission request: bash `rm -f tmp/new_state.lua tmp/new_rpc.lua` - No', 1, true) ~= nil, text)

renderer.clear('Permission raw denial stdio style test')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'deny-tool-stdio',
  toolName = 'bash',
  args = { command = 'rm -f tmp/new_state.lua tmp/new_rpc.lua' },
})
ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-stdio-deny',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'rm -f tmp/new_state.lua tmp/new_rpc.lua'. Allow this command?",
  options = { 'Yes', 'Yes, for this session', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'stdio denial permission select did not open')
vim.api.nvim_feedkeys('3', 'xt', false)
assert(vim.wait(1000, function() return sent[4] ~= nil end), 'stdio permission no response missing')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'deny-tool-stdio',
  toolName = 'bash',
  result = {
    stdout = "[pi-permission-system] is not permitted to run 'bash' command 'rm -f tmp/new_state.lua tmp/new_rpc.lua' (matched 'rm *').\nkept stdout",
    stderr = "[pi-permission-system] User denied bash command 'rm -f tmp/new_state.lua tmp/new_rpc.lua'.",
  },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('[pi-permission-system]', 1, true) == nil, text)
assert(text:find('is not permitted to run', 1, true) == nil, text)
assert(text:find('User denied bash command', 1, true) == nil, text)
assert(text:find('matched \'rm *\'', 1, true) == nil, text)
assert(text:find('kept stdout', 1, true), text)
assert(text:find('#### Permission request: bash `rm -f tmp/new_state.lua tmp/new_rpc.lua` - No', 1, true) ~= nil, text)

renderer.clear('Permission raw read external denial style test')
local external_path = './tmp/pi-dev-test/external/skills/example-skill/SKILL.md'
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'deny-tool-read-external',
  toolName = 'read',
  args = { path = external_path },
})
ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-read-external-deny',
  method = 'select',
  title = "Permission Required\nPi requested tool 'read' for path '" .. external_path .. "' outside working directory './tmp/pi-dev-test/project'. Allow this external directory access?",
  options = { 'Yes', 'No' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'read external permission select did not open')
vim.api.nvim_feedkeys('2', 'xt', false)
assert(vim.wait(1000, function() return sent[5] ~= nil end), 'read external permission no response missing')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'deny-tool-read-external',
  toolName = 'read',
  result = { content = { { type = 'text', text = "[pi-permission-system] User denied external directory access for tool 'read' path '" .. external_path .. "'." } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('[pi-permission-system]', 1, true) == nil, text)
assert(text:find('User denied external directory access', 1, true) == nil, text)
assert(text:find('```text\n%[pi%-permission%-system%]', 1, false) == nil, text)
assert(text:find('#### Permission request: External directory access: `' .. external_path .. '` - No', 1, true) ~= nil, text)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
