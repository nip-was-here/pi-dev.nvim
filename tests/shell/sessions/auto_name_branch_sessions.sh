#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, session_render = { chunk_delay_ms = 1 } })
local api = require('pi-dev.api')
local config = require('pi-dev.config')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
config.options.session_root = session_root

local root_file = session_root .. '/root.jsonl'
local branch_file = session_root .. '/branch.jsonl'
local forked_file = session_root .. '/forked-from-branch.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'session_info', name = 'Root task name' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt should not name the fork' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
}, root_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'branch', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:03.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt should not name the fork' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
  vim.json.encode({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'branch-specific prompt names the fork' } }),
}, branch_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'forked', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:04.000Z' }),
}, forked_file)

state.session.current_file = branch_file
state.session.tree_root_file = root_file
local sent = {}
rpc.start = function()
  return 1
end
rpc.request = function(message, cb)
  table.insert(sent, message)
  if message.type == 'switch_session' and cb then
    cb({ success = true, data = { cancelled = false } })
  elseif message.type == 'fork' and cb then
    cb({ success = true, data = { text = 'branch-specific prompt names the fork' } })
  elseif message.type == 'prompt' and cb then
    cb({ success = true, data = {} })
  elseif message.type == 'get_state' and cb then
    cb({ success = true, data = { sessionFile = forked_file } })
  elseif message.type == 'set_session_name' and cb then
    cb({ success = true })
  elseif message.type == 'get_messages' and cb then
    cb({ success = true, data = { messages = {} } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should open')
local branch_index
for index, item in ipairs(state.ui.interaction.items or {}) do
  if tostring(item.text or '') == 'branch-specific prompt names the fork' then
    branch_index = index
    break
  end
end
assert(branch_index, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(tostring(branch_index), 'xt', false)
assert(vim.wait(1000, function()
  return sent[4] and sent[4].type == 'get_messages'
end), vim.inspect(sent))
for _, message in ipairs(sent) do
  assert(message.type ~= 'set_session_name', 'fork point should not name the new sub-branch: ' .. vim.inspect(sent))
end
local fork_text = table.concat(vim.fn.readfile(forked_file), '\n')
assert(fork_text:find('"session_info"', 1, true) == nil, fork_text)
assert(not fork_text:find('Root task name', 1, true), fork_text)

-- A forked branch may initially contain only copied history through the fork
-- point. It must not be named from that pre-branch message, because that would
-- block the later first post-branch prompt from becoming the branch name.
local root_after_file = session_root .. '/root-after.jsonl'
local fork_after_file = session_root .. '/fork-after.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'root-after', cwd = vim.uv.cwd(), timestamp = '2026-01-02T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u-before', parentId = nil, timestamp = '2026-01-02T00:00:01.000Z', message = { role = 'user', content = 'message before branch point' } }),
  vim.json.encode({ type = 'message', id = 'a-before', parentId = 'u-before', timestamp = '2026-01-02T00:00:02.000Z', message = { role = 'assistant', content = 'answer before branch point' } }),
  vim.json.encode({ type = 'message', id = 'u-fork', parentId = 'a-before', timestamp = '2026-01-02T00:00:03.000Z', message = { role = 'user', content = 'selected fork point must not name branch' } }),
}, root_after_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'fork-after', cwd = vim.uv.cwd(), parentSession = root_after_file, timestamp = '2026-01-02T00:00:04.000Z' }),
  vim.json.encode({ type = 'message', id = 'u-before', parentId = nil, timestamp = '2026-01-02T00:00:01.000Z', message = { role = 'user', content = 'message before branch point' } }),
  vim.json.encode({ type = 'message', id = 'a-before', parentId = 'u-before', timestamp = '2026-01-02T00:00:02.000Z', message = { role = 'assistant', content = 'answer before branch point' } }),
  vim.json.encode({ type = 'message', id = 'u-fork', parentId = 'a-before', timestamp = '2026-01-02T00:00:03.000Z', message = { role = 'user', content = 'selected fork point must not name branch' } }),
}, fork_after_file)

sent = {}
local sessions = require('pi-dev.sessions')
local named = sessions.auto_name_branch_session(fork_after_file, 'selected fork point must not name branch')
assert(named == false, 'auto-name should wait for the first post-branch user message')
local initial_fork_after_text = table.concat(vim.fn.readfile(fork_after_file), '\n')
assert(initial_fork_after_text:find('session_info', 1, true) == nil, initial_fork_after_text)
for _, message in ipairs(sent) do
  assert(message.type ~= 'set_session_name', vim.inspect(sent))
end

vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'fork-after', cwd = vim.uv.cwd(), parentSession = root_after_file, timestamp = '2026-01-02T00:00:04.000Z' }),
  vim.json.encode({ type = 'message', id = 'u-before', parentId = nil, timestamp = '2026-01-02T00:00:01.000Z', message = { role = 'user', content = 'message before branch point' } }),
  vim.json.encode({ type = 'message', id = 'a-before', parentId = 'u-before', timestamp = '2026-01-02T00:00:02.000Z', message = { role = 'assistant', content = 'answer before branch point' } }),
  vim.json.encode({ type = 'message', id = 'u-fork', parentId = 'a-before', timestamp = '2026-01-02T00:00:03.000Z', message = { role = 'user', content = 'selected fork point must not name branch' } }),
  vim.json.encode({ type = 'message', id = 'u-after', parentId = 'u-fork', timestamp = '2026-01-02T00:00:05.000Z', message = { role = 'user', content = 'first prompt after branch point' } }),
}, fork_after_file)

sent = {}
state.session.current_file = fork_after_file
api.prompt('first prompt after branch point')
assert(vim.wait(1000, function()
  for _, message in ipairs(sent) do
    if message.type == 'set_session_name' then
      return true
    end
  end
  return false
end), 'successful branch prompt should trigger auto-name: ' .. vim.inspect(sent))
local after_name
for _, message in ipairs(sent) do
  if message.type == 'set_session_name' then
    after_name = message.name
  end
end
assert(after_name == 'first prompt after branch point', vim.inspect(sent))
local final_fork_after_text = table.concat(vim.fn.readfile(fork_after_file), '\n')
assert(final_fork_after_text:find('first prompt after branch point', 1, true), final_fork_after_text)
assert(final_fork_after_text:find('selected fork point must not name branch', 1, true), final_fork_after_text)
assert(final_fork_after_text:find('"name":"selected fork point must not name branch"', 1, true) == nil, final_fork_after_text)
LUA

pidev_run_lua_file "$tmp_lua"
