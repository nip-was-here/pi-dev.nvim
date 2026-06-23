#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, rpc = { idle_timeout_ms = 0 } })
local api = require('pi-dev.api')
local extension_ui = require('pi-dev.extension_ui')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
require('pi-dev.config').options.session_root = session_root
local root_file = session_root .. '/root.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'session_info', name = 'Cycle Session' }),
  vim.json.encode({ type = 'message', id = 'a', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'branch a prompt' } }),
  vim.json.encode({ type = 'message', id = 'b', parentId = 'a', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'user', content = 'branch b prompt' } }),
  vim.json.encode({ type = 'message', id = 'c', parentId = 'a', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'branch c prompt' } }),
}, root_file)
state.session.current_file = root_file

local branch_a = state.ensure_rpc_runtime('branch-a')
branch_a.job_id = 101
branch_a.status = 'idle'
branch_a.session_file = root_file
branch_a.branch_root = root_file
branch_a.branch_entry_id = 'a'
branch_a.label = 'Pi.dev branch A'

local branch_b = state.ensure_rpc_runtime('branch-b')
branch_b.job_id = 102
branch_b.active = true
branch_b.status = 'running'
branch_b.session_file = root_file
branch_b.branch_root = root_file
branch_b.branch_entry_id = 'b'
branch_b.label = 'Pi.dev branch B'

local branch_c = state.ensure_rpc_runtime('branch-c')
branch_c.job_id = 103
branch_c.status = 'idle'
branch_c.session_file = root_file
branch_c.branch_root = root_file
branch_c.branch_entry_id = 'c'
branch_c.label = 'Pi.dev branch C'

local original_is_job_running = state.is_job_running
state.is_job_running = function(runtime)
  return runtime and runtime.job_id ~= nil
end
local original_start = rpc.start
rpc.start = function(key)
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key)
  assert(runtime.job_id ~= nil, 'cycle must not start a new runtime: ' .. tostring(key))
  return runtime.job_id
end
local requests = {}
rpc.request = function(message, cb)
  table.insert(requests, { type = message.type, key = state.rpc.active_key })
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = root_file, model = 'fake/' .. state.rpc.active_key } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { tokens = { total = state.rpc.active_key == 'branch-b' and 222 or 111 } } })
  elseif message.type == 'get_messages' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { messages = {
      { role = 'user', content = 'rendered ' .. state.rpc.active_key },
      { role = 'assistant', content = {
        { type = 'text', text = 'answer ' .. state.rpc.active_key },
        { type = 'toolCall', id = 'cycle-read', name = 'read', arguments = { path = 'cycle.txt' } },
      } },
      { role = 'toolResult', toolCallId = 'cycle-read', toolName = 'read', content = vim.json.encode({
        path = 'cycle.txt',
        content = table.concat(vim.tbl_map(function(index)
          return 'cycle read line ' .. tostring(index)
        end, vim.fn.range(1, 25)), '\n'),
      }) },
    } } })
  end
  return message.type
end

state.set_active_rpc_runtime('branch-a')
assert(api.next_rpc() == true, 'next-rpc should switch to another running branch runtime')
assert(state.rpc.active_key == 'branch-b', state.rpc.active_key)
assert(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
  return text:find('answer branch%-b') ~= nil and text:find('cycle read line 25', 1, true) ~= nil
end), table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'))
local function output_line(pattern)
  local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
  for index, line in ipairs(lines) do
    if tostring(line):find(pattern, 1, true) then
      return index
    end
  end
  return nil
end
local read_tool_header = output_line('### Tool: read cycle.txt')
assert(read_tool_header, table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'))
vim.api.nvim_win_call(state.ui.output_win, function()
  assert(vim.fn.foldclosed(read_tool_header) == -1, 'read tool heading must stay visible after runtime cycling')
  assert(vim.fn.foldclosed(read_tool_header + 1) ~= -1, 'read tool details must fold after runtime cycling')
end)
local request_dump = vim.inspect(requests)
assert(request_dump:find('branch%-b'), request_dump)
assert(request_dump:find('get_messages'), request_dump)

-- Active extension interactions should be remembered before cycling away, then
-- reopened when cycling back to that runtime.
extension_ui.handle_request({ __pi_runtime_key = 'branch-b', type = 'extension_ui_request', id = 'branch-b-select', method = 'select', title = 'Branch B select', options = { 'Yes', 'No' } })
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Branch B select' end), 'active branch select did not render')
assert(branch_b.pending_extension_ui_request and branch_b.pending_extension_ui_request.id == 'branch-b-select', 'active request should be retained on its runtime')
assert(api.previous_rpc() == true, 'reverse cycle should switch back to branch-a')
assert(state.rpc.active_key == 'branch-a', state.rpc.active_key)
assert(state.ui.interaction == nil, 'cycling away should close the old branch interaction surface without answering it')
assert(api.previous_rpc() == true, 'reverse cycle from first branch should wrap to branch-c')
assert(state.rpc.active_key == 'branch-c', state.rpc.active_key)
assert(api.next_rpc() == true, 'forward cycle should wrap from branch-c back to branch-a')
assert(state.rpc.active_key == 'branch-a', state.rpc.active_key)
assert(api.next_rpc() == true, 'third forward cycle should switch back to branch-b')
assert(vim.wait(1000, function()
  return state.rpc.active_key == 'branch-b' and state.ui.interaction and state.ui.interaction.title == 'Branch B select'
end), 'cycling back should reopen pending branch interaction')

state.is_job_running = original_is_job_running
rpc.start = original_start
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
