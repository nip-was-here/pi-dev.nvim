#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ext = require('pi-dev.extension_ui')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')
require('pi-dev.rpc').write = function()
  return true
end

ui.focus_input()
ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-object',
  method = 'select',
  title = "Permission Required\r\nPi requested bash command 'adr new Test'. Allow this command?\r\nAllow it?",
  options = { 'Yes', 'Yes, allow bash "adr *" for this session', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'permission interaction missing')
local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local header_line
for index, line in ipairs(lines) do
  if line:find('#### Permission request', 1, true) then
    header_line = index
    assert(line:find('bash `adr %*`') ~= nil, line)
    assert(line:find('Source plugin:', 1, true) == nil, line)
  end
end
assert(header_line, table.concat(lines, '\n'))
local output_text = table.concat(lines, '\n')
assert(output_text:find('Options:', 1, true) == nil, output_text)
assert(output_text:find('No, provide reason', 1, true) == nil, output_text)
assert(output_text:find("requested bash command 'adr new Test'", 1, true) == nil, output_text)
assert(output_text:find('```bash\nadr new Test\n```', 1, true) == nil, output_text)
assert(output_text:find('Pi requested bash command.\nAllow this command?', 1, true), output_text)
local interaction_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false), '\n')
assert(interaction_text:find('Yes, for session', 1, true), interaction_text)
assert(interaction_text:find('No, with reason', 1, true), interaction_text)
assert(interaction_text:find('Yes, for this session: bash `adr *`', 1, true) == nil, interaction_text)
vim.api.nvim_win_call(state.ui.output_win, function()
  assert(vim.fn.foldclosed(header_line) == -1, 'pending permission header should be visible')
  assert(vim.fn.foldclosed(header_line + 2) == -1, 'pending permission details should remain open')
end)

vim.api.nvim_feedkeys('2', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction == nil
end), 'permission interaction did not close')
lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local text = table.concat(lines, '\n')
assert(text:find('\r', 1, true) == nil, text)
assert(text:find('#### Permission request: bash `adr *` - Yes, for session', 1, true) ~= nil, text)
assert(text:find('#### Permission request: bash `adr *` - Yes, allow bash "adr *" for this session', 1, true) == nil, text)
assert(text:find('Permission result:', 1, true) == nil, text)
assert(text:find('Options:', 1, true) == nil, text)
assert(text:find('\n- No', 1, true) == nil, text)
assert(text:find('@gotgenes/pi%-permission%-system') == nil, text)
vim.api.nvim_win_call(state.ui.output_win, function()
  assert(vim.fn.foldclosed(header_line) == -1, 'permission header must stay outside fold')
  assert(vim.fn.foldclosed(header_line + 1) ~= -1, 'blank line under permission header should be folded')
  assert(vim.fn.foldclosed(header_line + 2) ~= -1, 'answered permission details should fold under header')
  local fold_text = vim.fn.foldtextresult(header_line + 1)
  assert(fold_text:find('details %- %d+ lines'), fold_text)
  assert(fold_text:find('Permission Required', 1, true) == nil, fold_text)
end)

local quoted_command = [[bash -lc 'printf "%s\n" "hello world"' && echo done]]
ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-quoted-bash-object',
  method = 'select',
  title = "Permission Required\nPi requested bash command '" .. quoted_command .. "'. Allow this command?",
  options = { 'Yes', 'No' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'quoted bash permission interaction missing')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('#### Permission request: bash `' .. quoted_command .. '`', 1, true), text)
local quoted_header_pos = text:find('#### Permission request: bash `' .. quoted_command .. '`', 1, true)
assert(quoted_header_pos, text)
assert(text:find('```bash\n' .. quoted_command .. '\n```', 1, true) == nil, text)
assert(text:find('Pi requested bash command.\nAllow this command?', 1, true), text)
assert(text:find("requested bash command 'bash -lc '", 1, true) == nil, text)
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil end), 'quoted bash permission did not close')

ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-no-object',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'git status'. Allow this command?",
  options = { 'Yes', 'Yes, for this session', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'second permission interaction missing')
vim.api.nvim_feedkeys('3', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil end), 'second permission did not close')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('#### Permission request: bash `git status` - No', 1, true), text)
assert(text:find('Options:', 1, true) == nil, text)

ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-path-object',
  method = 'select',
  title = "Permission Required\nPi requested access to file via './tmp/pi-dev-test/project/restricted.txt'. Allow this path?",
  options = { 'Yes', 'Yes, allow read "./tmp/pi-dev-test/project/*" for this session', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'path permission interaction missing')
vim.api.nvim_feedkeys('2', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil end), 'path permission did not close')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('#### Permission request: read `./tmp/pi-dev-test/project/*` - Yes, for session', 1, true) ~= nil, text)
assert(text:find('#### Permission request: read `./tmp/pi-dev-test/project/*` - Yes, allow read "./tmp/pi-dev-test/project/*" for this session', 1, true) == nil, text)

ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-external-object',
  method = 'select',
  title = "Permission Required\nPi requested external directory access outside working directory '/repo': /var/log. Allow?",
  options = { 'Yes', 'Yes, allow bash "/var/log/*" for this session', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'external permission interaction missing')
vim.api.nvim_feedkeys('2', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil end), 'external permission did not close')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('#### Permission request: External directory access: `/var/log` - Yes, for session', 1, true), text)
assert(text:find('#### Permission request: External directory access: `/var/log` - Yes, allow bash "/var/log/*" for this session', 1, true) == nil, text)

ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-mcp-object',
  method = 'select',
  title = "Permission Required\nPi requested MCP target 'ExamplePrompt.search {\"query\":\"long session permission\"}'. Allow this MCP call?",
  options = { 'Yes', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'MCP permission interaction missing')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find("requested MCP target 'ExamplePrompt.search", 1, true) == nil, text)
local mcp_header_pos = text:find('#### Permission request: MCP `ExamplePrompt.search {"query":"long session permission"}`', 1, true)
assert(mcp_header_pos, text)
assert(text:find('```\nExamplePrompt.search {"query":"long session permission"}\n```', 1, true) == nil, text)
assert(text:find('Pi requested MCP target.\nAllow this MCP call?', 1, true), text)
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil end), 'MCP permission did not close')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
