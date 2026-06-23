#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, session_render = { chunk_delay_ms = 1 } })
local api = require('pi-dev.api')
local config = require('pi-dev.config')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
config.options.session_root = session_root
local root_file = session_root .. '/root.jsonl'
local active_branch = session_root .. '/active.jsonl'
local sibling_branch = session_root .. '/sibling.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
}, root_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'active', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:03.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
  vim.json.encode({ type = 'message', id = 'au1', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'active branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'aa1', parentId = 'au1', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'active branch answer' } }),
}, active_branch)
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'sibling', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:05.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
  vim.json.encode({ type = 'message', id = 'su1', parentId = 'a1', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'user', content = 'sibling branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'sa1', parentId = 'su1', timestamp = '2026-01-01T00:00:06.000Z', message = { role = 'assistant', content = 'sibling branch answer' } }),
}, sibling_branch)
state.session.current_file = active_branch
state.session.tree_root_file = root_file
local runtime = state.set_active_rpc_runtime('default')
runtime.job_id = 321
runtime.status = 'idle'
runtime.active = false
runtime.waiting_input = false
runtime.session_file = active_branch
runtime.branch_root = root_file
state.sync_active_rpc_runtime(runtime)
state.is_job_running = function(candidate)
  candidate = candidate or state.active_rpc_runtime()
  return candidate and candidate.job_id ~= nil
end

local starts = {}
rpc.start = function(key)
  table.insert(starts, tostring(key or state.rpc.active_key or 'default'))
  local selected = state.ensure_rpc_runtime(key or state.rpc.active_key)
  return selected.job_id or 321
end
local requests = {}
local fail_switch = false
rpc.request = function(message, cb)
  table.insert(requests, { type = message.type, sessionPath = message.sessionPath, entryId = message.entryId, key = state.rpc.active_key })
  if message.type == 'switch_session' and cb then
    if fail_switch then
      cb({ __pi_runtime_key = state.rpc.active_key, success = false, error = 'synthetic switch failure' })
    else
      cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = message.sessionPath } })
    end
  elseif message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = sibling_branch, model = 'fake/reused' } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  elseif cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end

api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should open')
local selected
for index, item in ipairs(state.ui.interaction.items or {}) do
  if item.entry_id == 'su1' then
    selected = index
    assert(item.session_path == sibling_branch, vim.inspect(item))
  end
end
assert(selected, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(tostring(selected), 'xt', false)
assert(vim.wait(1000, function() return state.session.current_file == sibling_branch end), vim.inspect({ current = state.session.current_file, requests = requests }))
assert(state.rpc.active_key == 'default', 'existing sibling branch switch should reuse the current idle runtime: ' .. tostring(state.rpc.active_key))
assert(state.rpc_runtime_count() == 1, 'switching to an existing same-root branch must not create another runtime')
for _, started_key in ipairs(starts) do
  assert(started_key == 'default', 'same-root existing branch switch must not start a branch runtime: ' .. vim.inspect(starts))
end
local saw_switch = false
for _, request in ipairs(requests) do
  assert(request.type ~= 'fork', 'existing same-root branch should switch/load, not fork: ' .. vim.inspect(requests))
  assert(request.key == 'default', 'tree branch switch should use current idle runtime: ' .. vim.inspect(requests))
  if request.type == 'switch_session' then
    saw_switch = true
    assert(request.sessionPath == sibling_branch, vim.inspect(requests))
  end
end
assert(saw_switch, 'existing same-root branch selection should switch_session to the branch file')

state.session.current_file = active_branch
runtime = state.active_rpc_runtime()
runtime.status = 'idle'
runtime.active = false
runtime.waiting_input = false
runtime.session_file = active_branch
runtime.branch_root = root_file
runtime.branch_entry_id = nil
state.sync_active_rpc_runtime(runtime)
starts = {}
requests = {}
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should reopen for assistant branch selection')
selected = nil
for index, item in ipairs(state.ui.interaction.items or {}) do
  if item.entry_id == 'sa1' then
    selected = index
    assert(item.role == 'assistant', vim.inspect(item))
    assert(item.session_path == sibling_branch, vim.inspect(item))
  end
end
assert(selected, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(tostring(selected), 'xt', false)
assert(vim.wait(1000, function() return state.session.current_file == sibling_branch end), vim.inspect({ current = state.session.current_file, requests = requests }))
assert(state.rpc.active_key == 'default', 'existing sibling assistant selection should reuse the current idle runtime: ' .. tostring(state.rpc.active_key))
assert(state.rpc_runtime_count() == 1, 'assistant selection in an existing same-root branch must not create another runtime')
for _, started_key in ipairs(starts) do
  assert(started_key == 'default', 'assistant same-root branch switch must not start a branch runtime: ' .. vim.inspect(starts))
end
saw_switch = false
for _, request in ipairs(requests) do
  assert(request.type ~= 'fork', 'existing same-root assistant row should switch/load, not fork: ' .. vim.inspect(requests))
  assert(request.key == 'default', 'assistant tree branch switch should use current idle runtime: ' .. vim.inspect(requests))
  if request.type == 'switch_session' then
    saw_switch = true
    assert(request.sessionPath == sibling_branch, vim.inspect(requests))
  end
end
assert(saw_switch, 'existing same-root assistant selection should switch_session to the branch file')

state.session.current_file = active_branch
runtime = state.active_rpc_runtime()
runtime.status = 'idle'
runtime.active = false
runtime.waiting_input = false
runtime.session_file = active_branch
runtime.branch_root = root_file
runtime.branch_entry_id = nil
state.sync_active_rpc_runtime(runtime)
starts = {}
requests = {}
fail_switch = true
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should reopen for failed branch switch')
selected = nil
for index, item in ipairs(state.ui.interaction.items or {}) do
  if item.entry_id == 'su1' then
    selected = index
    break
  end
end
assert(selected, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(tostring(selected), 'xt', false)
assert(vim.wait(1000, function()
  for _, request in ipairs(requests) do
    if request.type == 'switch_session' then
      return true
    end
  end
  return false
end), vim.inspect(requests))
runtime = state.active_rpc_runtime()
assert(state.session.current_file == active_branch, 'failed switch should leave current session unchanged: ' .. tostring(state.session.current_file))
assert(runtime.session_file == active_branch, 'failed switch should restore idle runtime session file: ' .. vim.inspect(runtime))
assert(runtime.branch_root == root_file, 'failed switch should restore idle runtime branch root: ' .. vim.inspect(runtime))
assert(runtime.branch_entry_id == nil, 'failed switch should restore idle runtime branch entry: ' .. vim.inspect(runtime))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
