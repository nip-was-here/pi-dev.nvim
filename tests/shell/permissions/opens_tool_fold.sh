#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 10 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local ext = require('pi-dev.extension_ui')
local state = require('pi-dev.state')

require('pi-dev.rpc').write = function()
  return true
end

local function output_foldclosed(line)
  local value
  vim.api.nvim_win_call(state.ui.output_win, function()
    value = vim.fn.foldclosed(line)
  end)
  return value
end

ui.focus_input()
renderer.clear('Pi.dev permission fold test')
local long_output = table.concat(vim.tbl_map(function(i) return 'pending line ' .. i end, vim.fn.range(1, 40)), '\n')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'perm-tool',
  toolName = 'bash',
  args = { command = 'git status' },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'perm-tool',
  toolName = 'bash',
  partialResult = { content = { { type = 'text', text = long_output } } },
})
renderer.flush_pending_tool_renders()
assert(output_foldclosed(5) == -1, 'running bash tool details should stay open before permission')

renderer.clear('Pi.dev permission opens folded tool test')
local long_input = table.concat(vim.tbl_map(function(i) return 'input line ' .. i end, vim.fn.range(1, 40)), '\n')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'perm-write-tool',
  toolName = 'write',
  args = { path = './tmp/pi-dev-test/project/file.txt', content = long_input },
})
renderer.flush_pending_tool_renders()
local write_header_line
for index, line in ipairs(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)) do
  if line:find('### Tool: write', 1, true) then
    write_header_line = index
    break
  end
end
assert(write_header_line, table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'))
local write_detail_line = write_header_line + 2
assert(output_foldclosed(write_detail_line) ~= -1, 'long non-bash tool input should auto-fold before permission')

ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-write-fold',
  method = 'select',
  title = "Permission Required\nPi requested access to file via './tmp/pi-dev-test/project/file.txt'. Allow this path?",
  options = { 'Yes', 'Yes, allow write "./tmp/pi-dev-test/project/*" for this session', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil and output_foldclosed(write_detail_line) == -1
end), 'pending permission should open the owning tool details')
local permission_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(permission_text:find(long_input, 1, true) ~= nil, permission_text)
local permission_header = permission_text:find('#### Permission request:', 1, true)
assert(permission_header and permission_text:sub(permission_header):find(long_input, 1, true) == nil, permission_text)
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction == nil and output_foldclosed(write_detail_line) ~= -1
end), 'answering permission should restore normal tool auto-fold state')

renderer.clear('Pi.dev permission fold test')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'perm-tool',
  toolName = 'bash',
  args = { command = 'git status' },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'perm-tool',
  toolName = 'bash',
  partialResult = { content = { { type = 'text', text = long_output } } },
})
renderer.flush_pending_tool_renders()
assert(output_foldclosed(5) == -1, 'running bash tool details should stay open before permission')

ext.handle_request({
  type = 'extension_ui_request',
  id = 'perm-fold',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'git status'. Allow this command?",
  options = { 'Yes', 'Yes, for this session', 'No', 'No, provide reason' },
})

assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil and output_foldclosed(5) == -1
end), 'permission request should keep running bash tool details open')

vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction == nil and output_foldclosed(5) == -1
end), 'approving permission should keep running bash details open')

renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'perm-tool',
  toolName = 'bash',
  partialResult = { content = { { type = 'text', text = long_output .. '\nafter approval' } } },
})
renderer.flush_pending_tool_renders()
assert(output_foldclosed(5) == -1, 'running bash details should stay open as work continues after approval')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'perm-tool',
  toolName = 'bash',
  result = { content = { { type = 'text', text = long_output .. '\nafter approval' } } },
})
assert(output_foldclosed(5) ~= -1, 'finished bash details should auto-fold after approval when over threshold')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
