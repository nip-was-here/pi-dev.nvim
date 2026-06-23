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

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
require('pi-dev.config').options.session_root = session_root

local root_file = session_root .. '/root.jsonl'
local branch_file = session_root .. '/branch-from-u3.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
}, root_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'branch', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:03.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
  vim.json.encode({ type = 'message', id = 'u3', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'branch fork point' } }),
  vim.json.encode({ type = 'message', id = 'a3', parentId = 'u3', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'first branch answer' } }),
  vim.json.encode({ type = 'message', id = 'u4', parentId = 'a3', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'user', content = 'new message after first branch' } }),
  vim.json.encode({ type = 'message', id = 'a4', parentId = 'u4', timestamp = '2026-01-01T00:00:06.000Z', message = { role = 'assistant', content = 'answer after first branch' } }),
}, branch_file)

state.session.current_file = branch_file
state.session.tree_root_file = root_file
local runtime_key = rpc.branch_key(root_file, 'u3')
state.set_active_rpc_runtime(runtime_key)
local runtime = state.active_rpc_runtime()
runtime.session_file = branch_file
runtime.branch_root = root_file
runtime.branch_entry_id = 'u3'
runtime.status = 'idle'
state.sync_active_rpc_runtime(runtime)

local sent = {}
rpc.start = function()
  return 42
end
rpc.request = function(message, cb)
  table.insert(sent, message)
  if message.type == 'switch_session' and cb then
    cb({ success = true, data = { cancelled = false } })
  elseif message.type == 'fork' and cb then
    cb({ success = true, data = { text = 'second sibling draft from same step' } })
  elseif message.type == 'get_state' and cb then
    cb({ success = true, data = { sessionFile = branch_file } })
  elseif message.type == 'get_messages' and cb then
    cb({ success = true, data = { messages = {
      { role = 'user', content = 'branch fork point' },
    } } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction missing')
local target_index
for index, item in ipairs(state.ui.interaction.items or {}) do
  if tostring(item.label or ''):find('branch fork point', 1, true) then
    target_index = index
    break
  end
end
assert(target_index, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(tostring(target_index), 'xt', false)
assert(vim.wait(1000, function()
  for _, message in ipairs(sent) do
    if message.type == 'fork' and message.entryId == 'u3' then
      return true
    end
  end
  return false
end), 'selecting the active branch origin again should fork from it, not report already-current: ' .. vim.inspect(sent))
assert(sent[1] and sent[1].type == 'switch_session' and sent[1].sessionPath == branch_file, vim.inspect(sent))
assert(ui.get_input_text() == 'second sibling draft from same step', ui.get_input_text())

-- The same bug also happens for a selected response row: after
-- navigating to that response and continuing from it, the active runtime keeps
-- branch_entry_id at the original response id while the current leaf moves on.
-- Re-selecting the original response must navigate there again, not be treated
-- as already-current.
ui.close_interaction()
local assistant_branch_file = session_root .. '/branch-from-a1.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'assistant-branch', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:07.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
  vim.json.encode({ type = 'message', id = 'u5', parentId = 'a1', timestamp = '2026-01-01T00:00:07.000Z', message = { role = 'user', content = 'continued from assistant step' } }),
  vim.json.encode({ type = 'message', id = 'a5', parentId = 'u5', timestamp = '2026-01-01T00:00:08.000Z', message = { role = 'assistant', content = 'assistant-step branch answer' } }),
}, assistant_branch_file)
state.session.current_file = assistant_branch_file
state.session.tree_root_file = root_file
local assistant_runtime_key = assistant_branch_file
state.set_active_rpc_runtime(assistant_runtime_key)
runtime = state.active_rpc_runtime()
runtime.session_file = assistant_branch_file
runtime.branch_root = root_file
runtime.branch_entry_id = 'a1'
runtime.status = 'idle'
state.sync_active_rpc_runtime(runtime)
sent = {}
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'assistant-origin tree interaction missing')
target_index = nil
for index, item in ipairs(state.ui.interaction.items or {}) do
  if item.role == 'assistant' and tostring(item.label or ''):find('root answer', 1, true) then
    target_index = index
    break
  end
end
assert(target_index, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(tostring(target_index), 'xt', false)
assert(vim.wait(1000, function()
  for _, message in ipairs(sent) do
    if message.type == 'switch_session' then
      return true
    end
  end
  return false
end), 'selecting the active assistant branch origin again should navigate to it, not report already-current: ' .. vim.inspect(sent))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
