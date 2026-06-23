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
local ui = require('pi-dev.ui')

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
config.options.session_root = session_root
local root_file = session_root .. '/root.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
}, root_file)
state.session.current_file = root_file
state.session.tree_root_file = root_file
local default_runtime = state.set_active_rpc_runtime('default')
default_runtime.job_id = 321
default_runtime.status = 'idle'
default_runtime.active = false
default_runtime.waiting_input = false
default_runtime.session_file = root_file
default_runtime.branch_root = root_file
state.sync_active_rpc_runtime(default_runtime)
state.is_job_running = function(candidate)
  candidate = candidate or state.active_rpc_runtime()
  return candidate and candidate.job_id ~= nil
end

ui.show()
ui.set_input_text('keep draft')

rpc.start = function(key)
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key)
  runtime.job_id = runtime.job_id or 321
  return runtime.job_id
end
rpc.request = function(message, cb)
  local request_key = state.rpc.active_key
  if message.type == 'switch_session' and cb then
    cb({ __pi_runtime_key = request_key, success = true, data = { sessionFile = message.sessionPath } })
  elseif message.type == 'fork' and cb then
    local other = state.set_active_rpc_runtime('other')
    other.job_id = 654
    other.status = 'idle'
    other.session_file = session_root .. '/other.jsonl'
    state.sync_active_rpc_runtime(other)
    cb({ __pi_runtime_key = request_key, success = true, data = { text = 'inactive fork draft' } })
  elseif message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = root_file } })
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
  if item.entry_id == 'u1' then
    selected = index
    break
  end
end
assert(selected, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(tostring(selected), 'xt', false)
assert(vim.wait(1000, function() return state.rpc.active_key == 'other' end), 'test should switch active runtime before fork callback completes')
assert(ui.get_input_text() ~= 'inactive fork draft', 'inactive fork callback must not overwrite visible input: ' .. vim.inspect(ui.get_input_text()))
assert(state.session.tree_root_file == root_file, 'inactive fork callback should not alter visible tree root unexpectedly')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
