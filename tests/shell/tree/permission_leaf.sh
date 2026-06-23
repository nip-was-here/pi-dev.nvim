#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local root_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'first prompt' } }),
  vim.json.encode({ type = 'extension_ui_request', id = 'old-perm', parentId = 'u1', timestamp = '2026-01-01T00:00:01.500Z', method = 'select', title = "Permission Required\nPi requested bash command 'echo old'. Allow this command?", options = { 'Yes', 'No' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'old-perm', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'answer after old permission' } }),
  vim.json.encode({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'needs final permission' } }),
  vim.json.encode({ type = 'extension_ui_request', id = 'leaf-perm', parentId = 'u2', timestamp = '2026-01-01T00:00:04.000Z', method = 'select', title = "Permission Required\nPi requested bash command 'git status'. Allow this command?", options = { 'Yes', 'Yes, allow bash "git *" for this session', 'No', 'No, provide reason' } }),
}, root_file)

state.session.current_file = root_file
local sent = {}
rpc.request = function(message, cb)
  table.insert(sent, message)
  if message.type == 'switch_session' and cb then
    cb({ success = true, data = { cancelled = false } })
  elseif message.type == 'fork' and cb then
    cb({ success = true, data = { text = 'unexpected fork' } })
  elseif message.type == 'get_state' and cb then
    cb({ success = true, data = { sessionFile = root_file } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction missing')
local labels = vim.inspect(state.ui.interaction.items)
assert(#state.ui.interaction.items == 4, labels)
assert(labels:find('first prompt', 1, true), labels)
assert(labels:find('Assistant: answer after old permission', 1, true), labels)
assert(labels:find('needs final permission', 1, true), labels)
assert(labels:find('Permission: bash `git status`', 1, true), labels)
assert(labels:find('echo old', 1, true) == nil, labels)
assert(state.ui.interaction.selected == 4, 'terminal permission request should be the current visible tree row')

vim.api.nvim_feedkeys('4', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), vim.inspect(sent))
assert(sent[1].type == 'switch_session' and sent[1].sessionPath == root_file, vim.inspect(sent))
for _, message in ipairs(sent) do
  assert(message.type ~= 'fork', 'permission tree row must navigate, not fork: ' .. vim.inspect(sent))
end
assert(ui.get_input_text() == '', 'permission tree selection must not fill Pi input')
assert(vim.wait(1000, function()
  local rendered = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
  return rendered:find('#### Permission request: bash `git st', 1, true) ~= nil
    and rendered:find('Pi requested bash command.\nAllow this command?', 1, true) ~= nil
    and rendered:find('```bash\ngit status\n```', 1, true) == nil
end), table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n'))
local output = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(output:find('answer after old permission', 1, true), output)
assert(output:find('echo old', 1, true) == nil, output)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
