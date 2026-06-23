#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({
  keymaps = { enable = false },
  session_render = {
    max_messages = 100,
    include_tool_results = true,
    max_text_chars = 8000,
    chunk_size = 100,
    chunk_delay_ms = 0,
    chunk_budget_ms = 8,
  },
  tree = {
    branch_render = {
      max_messages = 9,
      include_tool_results = false,
      max_text_chars = 80,
    },
  },
})

local api = require('pi-dev.api')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local root_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'root', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'fork from here' } }),
}, root_file)
state.session.current_file = root_file

local branch_messages = {}
for i = 1, 12 do
  table.insert(branch_messages, { role = 'user', content = 'branch prompt ' .. i, timestamp = '2026-01-01T00:00:00.000Z' })
  table.insert(branch_messages, { role = 'assistant', content = {
    { type = 'text', text = 'branch answer ' .. i .. ' ' .. string.rep('x', 160) },
    { type = 'toolCall', id = 'tool-' .. i, name = 'bash', arguments = { command = 'printf long ' .. i } },
  }, timestamp = '2026-01-01T00:00:00.000Z' })
  table.insert(branch_messages, { role = 'toolResult', toolCallId = 'tool-' .. i, toolName = 'bash', content = 'TOOL RESULT SHOULD BE HIDDEN ' .. i .. '\n' .. string.rep('tool output ', 200), timestamp = '2026-01-01T00:00:00.000Z' })
end

local calls = {}
rpc.request = function(message, cb)
  table.insert(calls, message.type)
  if message.type == 'switch_session' and cb then
    cb({ success = true, data = { cancelled = false } })
  elseif message.type == 'fork' and cb then
    cb({ success = true, data = { text = 'fork from here' } })
  elseif message.type == 'get_state' and cb then
    cb({ success = true, data = { sessionFile = 'branch-session.jsonl', model = 'fake/model' } })
  elseif message.type == 'get_messages' and cb then
    cb({ success = true, data = { messages = branch_messages } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should open')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return vim.tbl_contains(calls, 'get_messages') end), vim.inspect(calls))
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'):find('branch answer 12', 1, true) ~= nil
end), 'branch render should finish')

local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('branch answer 12', 1, true), text)
assert(text:find('branch answer 7', 1, true) == nil, text)
assert(text:find('TOOL RESULT SHOULD BE HIDDEN', 1, true) == nil, text)
assert(text:find('Tool results are hidden in this view', 1, true), text)
assert(text:find('Showing latest 9/36 rendered messages', 1, true), text)
assert(text:find(string.rep('x', 100), 1, true) == nil, text)
assert(ui.get_input_text() == 'fork from here', ui.get_input_text())
LUA

output="$({
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
