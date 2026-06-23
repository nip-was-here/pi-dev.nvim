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
local root_file = session_root .. '/root.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
  vim.json.encode({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'existing runtime prompt' } }),
}, root_file)
state.session.current_file = root_file

local existing = state.ensure_rpc_runtime('existing-runtime')
existing.job_id = 101
existing.status = 'running'
existing.active = true
existing.session_file = root_file
existing.branch_root = root_file
existing.branch_entry_id = 'u2'
existing.label = 'Existing runtime branch'
state.set_active_rpc_runtime('default')
state.is_job_running = function(runtime)
  return runtime and runtime.job_id ~= nil
end

local requests = {}
rpc.request = function(message, cb)
  table.insert(requests, { type = message.type, key = state.rpc.active_key })
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = root_file, model = 'fake/' .. state.rpc.active_key } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { tokens = { total = 321 } } })
  elseif message.type == 'get_messages' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { messages = {
      { role = 'user', content = 'rendered existing runtime' },
      { role = 'assistant', content = 'answer from existing runtime' },
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
  if item.entry_id == 'u2' then
    selected = index
    assert(item.runtime_key == 'existing-runtime', vim.inspect(item))
    assert(item.label:find('%[run%]'), item.label)
  end
end
assert(selected, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(tostring(selected), 'xt', false)
assert(vim.wait(1000, function()
  return state.rpc.active_key == 'existing-runtime'
    and table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'):find('answer from existing runtime', 1, true) ~= nil
end), vim.inspect({ active = state.rpc.active_key, requests = requests, output = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false) }))
for _, request in ipairs(requests) do
  assert(request.type ~= 'fork', 'selecting an existing runtime tree row should switch to that runtime instead of forking: ' .. vim.inspect(requests))
  assert(request.type ~= 'switch_session', 'selecting an existing runtime tree row should not switch the session before reusing the runtime: ' .. vim.inspect(requests))
end
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
