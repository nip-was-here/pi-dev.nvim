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

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
config.options.session_root = session_root
config.options.session_render.chunk_delay_ms = 1
local root_file = session_root .. '/root.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'reuse idle runtime prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
  vim.json.encode({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'current idle prompt' } }),
}, root_file)
state.session.current_file = root_file
state.session.tree_root_file = root_file

local active = state.set_active_rpc_runtime('default')
active.job_id = 777
active.status = 'idle'
active.active = false
active.waiting_input = false
active.session_file = root_file
active.branch_root = root_file
state.sync_active_rpc_runtime(active)
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

local starts = {}
rpc.start = function(key)
  table.insert(starts, tostring(key or state.rpc.active_key or 'default'))
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key)
  return runtime.job_id or 777
end

local requests = {}
rpc.request = function(message, cb)
  table.insert(requests, { type = message.type, entryId = message.entryId, sessionPath = message.sessionPath, key = state.rpc.active_key })
  if message.type == 'switch_session' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = message.sessionPath } })
  elseif message.type == 'fork' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { text = 'reuse idle runtime prompt' } })
  elseif message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = session_root .. '/forked.jsonl', model = 'fake/reused' } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { tokens = { total = 12 } } })
  elseif message.type == 'get_messages' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { messages = {
      { role = 'user', content = 'reuse idle runtime prompt' },
      { role = 'assistant', content = 'rendered through reused runtime' },
    } } })
  elseif cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end

api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should open')
local selected
for index, item in ipairs(state.ui.interaction.items) do
  if item.entry_id == 'u1' then
    selected = index
    assert(item.runtime_key == nil, 'selected historical row should not have an existing runtime link: ' .. vim.inspect(item))
  end
end
assert(selected, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(tostring(selected), 'xt', false)
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'):find('rendered through reused runtime', 1, true) ~= nil
end), vim.inspect({ active = state.rpc.active_key, starts = starts, requests = requests }))

assert(state.rpc.active_key == 'default', 'tree fork should keep using the current idle runtime key: ' .. tostring(state.rpc.active_key))
for _, started_key in ipairs(starts) do
  assert(started_key == 'default', 'tree selection must not start a new branch runtime: ' .. vim.inspect(starts))
end
for _, request in ipairs(requests) do
  assert(request.key == 'default', 'tree request should run through the current idle runtime: ' .. vim.inspect(requests))
end
local saw_fork = false
for _, request in ipairs(requests) do
  if request.type == 'fork' then
    saw_fork = true
    assert(request.entryId == 'u1', vim.inspect(requests))
  end
end
assert(saw_fork, 'selecting a historical user row should still ask Pi to fork that entry in the reused runtime')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
