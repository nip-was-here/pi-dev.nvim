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
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'question on main branch' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'answer on main branch' } }),
}, root_file)
state.session.current_file = root_file
state.session.tree_root_file = root_file

local original_is_job_running = state.is_job_running
state.is_job_running = function(runtime)
  return runtime and runtime.job_id ~= nil
end
local runtime = state.ensure_rpc_runtime('default')
runtime.job_id = 101
runtime.active = true
runtime.status = 'waiting input'
runtime.waiting_input = true
runtime.pending_extension_ui_request = {
  type = 'extension_ui_request',
  __pi_runtime_key = 'default',
  id = 'default-waiting-select',
  method = 'select',
  title = 'Default waiting select',
  options = { 'Answer', 'Skip' },
}

rpc.request = function(message, cb)
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = root_file } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  elseif message.type == 'get_messages' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { messages = {} } })
  end
  return message.type
end

api.waiting()
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Pi waiting input'
end), 'waiting picker did not open')
assert(state.ui.interaction.surface == 'output', 'waiting tree should use the large output/session buffer')
local rendered = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(rendered:find('answer on', 1, true), rendered)
assert(rendered:find('%[wait%]'), rendered)
assert(rendered:find('%[default%]') == nil, rendered)
local selectable = {}
for index, item in ipairs(state.ui.interaction.items) do
  if item.selectable ~= false then
    table.insert(selectable, index)
  end
end
assert(#selectable == 1, vim.inspect(state.ui.interaction.items))
assert(state.ui.interaction.items[selectable[1]].runtime_key == 'default', vim.inspect(state.ui.interaction.items[selectable[1]]))
assert(state.ui.interaction.selected == selectable[1], 'waiting picker should focus the waiting node')

state.is_job_running = original_is_job_running
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
