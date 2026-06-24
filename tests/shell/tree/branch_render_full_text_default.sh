#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })

local api = require('pi-dev.api')
local config = require('pi-dev.config')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')

assert(config.options.session_render.max_text_chars == false, vim.inspect(config.options.session_render))
assert(config.options.tree.branch_render.max_text_chars == false, vim.inspect(config.options.tree.branch_render))

local root_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'root', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'fork from here' } }),
}, root_file)
state.session.current_file = root_file

local marker = 'FULL_MARKER_AFTER_LONG_RESTORED_BRANCH_TEXT'
local branch_messages = {
  { role = 'user', content = 'branch prompt', timestamp = '2026-01-01T00:00:01.000Z' },
  { role = 'assistant', content = 'branch answer ' .. string.rep('x', 1800) .. marker, timestamp = '2026-01-01T00:00:02.000Z' },
}

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
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'):find(marker, 1, true) ~= nil
end), 'full branch text should render without default truncation')

local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find(marker, 1, true), text)
assert(text:find('\n%.%.%.') == nil, text)
LUA

output="$({
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
