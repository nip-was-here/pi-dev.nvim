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
local child_file = session_root .. '/child.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'current prompt' } }),
  vim.json.encode({ type = 'message', id = 'u2', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'user', content = 'other prompt' } }),
}, root_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'child', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:03.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'current prompt' } }),
}, child_file)
state.session.current_file = child_file
state.session.tree_root_file = root_file
local runtime = state.set_active_rpc_runtime('default')
runtime.job_id = 321
runtime.status = 'idle'
runtime.active = false
runtime.waiting_input = false
runtime.label = 'Original runtime'
runtime.session_file = child_file
runtime.branch_root = root_file
runtime.branch_entry_id = 'u1'
state.sync_active_rpc_runtime(runtime)
state.is_job_running = function(candidate)
  candidate = candidate or state.active_rpc_runtime()
  return candidate and candidate.job_id ~= nil
end
rpc.start = function(key)
  local selected = state.ensure_rpc_runtime(key or state.rpc.active_key)
  selected.job_id = selected.job_id or 321
  selected.status = selected.status or 'idle'
  return selected.job_id
end
local switch_callback
rpc.request = function(message, cb)
  if message.type == 'switch_session' then
    switch_callback = cb
  elseif message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = child_file } })
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
  if item.entry_id == 'u2' then
    selected = index
    break
  end
end
assert(selected, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(tostring(selected), 'xt', false)
assert(vim.wait(1000, function() return switch_callback ~= nil end), 'tree branch selection should switch source session first')
runtime = state.ensure_rpc_runtime('default')
assert(runtime.branch_entry_id == 'u2', 'test should pre-bind runtime before switch callback: ' .. vim.inspect(runtime))
local other = state.set_active_rpc_runtime('other')
other.job_id = 654
other.status = 'idle'
state.sync_active_rpc_runtime(other)
switch_callback({ __pi_runtime_key = 'default', success = true, data = {} })
runtime = state.ensure_rpc_runtime('default')
assert(runtime.label == 'Original runtime', vim.inspect(runtime))
assert(runtime.session_file == child_file, vim.inspect(runtime))
assert(runtime.branch_root == root_file, vim.inspect(runtime))
assert(runtime.branch_entry_id == 'u1', vim.inspect(runtime))
assert(runtime.loading == false, vim.inspect(runtime))
assert(state.rpc.active_key == 'other', state.rpc.active_key)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
