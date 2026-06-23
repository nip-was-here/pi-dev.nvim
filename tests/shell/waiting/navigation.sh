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

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
require('pi-dev.config').options.session_root = session_root
local root_file = session_root .. '/root.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'session_info', name = 'Useful Waiting Session' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'running question' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'running answer' } }),
  vim.json.encode({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'waiting question' } }),
  vim.json.encode({ type = 'message', id = 'a2', parentId = 'u2', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'waiting answer' } }),
  vim.json.encode({ type = 'message', id = 'u3', parentId = 'a1', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'user', content = 'unrelated sibling question' } }),
  vim.json.encode({ type = 'message', id = 'a3', parentId = 'u3', timestamp = '2026-01-01T00:00:06.000Z', message = { role = 'assistant', content = 'unrelated sibling answer' } }),
}, root_file)
state.session.current_file = root_file

local running = state.ensure_rpc_runtime('running-runtime')
running.job_id = 101
running.active = true
running.status = 'running'
running.session_file = root_file
running.branch_root = root_file
running.branch_entry_id = 'u1'

local waiting = state.ensure_rpc_runtime('waiting-runtime')
waiting.job_id = 102
waiting.active = true
waiting.waiting_input = true
waiting.status = 'waiting input'
waiting.session_file = root_file
waiting.branch_root = root_file
waiting.branch_entry_id = 'u2'
waiting.pending_extension_ui_request = {
  type = 'extension_ui_request',
  __pi_runtime_key = 'waiting-runtime',
  id = 'waiting-select',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'git status'. Allow this command?",
  options = { 'Yes', 'Yes, allow bash "git *" for this session', 'No', 'No, provide reason' },
}

local original_is_job_running = state.is_job_running
state.is_job_running = function(runtime)
  return runtime and runtime.job_id ~= nil
end
local sent = {}
rpc.write = function(message)
  table.insert(sent, message)
  return true
end
local requested = {}
rpc.request = function(message, cb)
  table.insert(requested, message.type)
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = root_file, model = 'fake/waiting' } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { tokens = { total = 123 } } })
  elseif message.type == 'get_messages' and cb then
    local long_tool = table.concat(vim.tbl_map(function(i) return 'waiting tool line ' .. i end, vim.fn.range(1, 40)), '\n')
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { messages = {
      { role = 'user', content = 'waiting branch rendered from rpc' },
      { role = 'assistant', content = {
        { type = 'text', text = 'waiting branch answer from rpc' },
        { type = 'toolCall', id = 'waiting-tool', name = 'bash', arguments = { command = 'printf waiting tool' } },
      } },
      { role = 'toolResult', toolCallId = 'waiting-tool', toolName = 'bash', content = long_tool },
    } } })
  end
  return message.type
end

api.waiting()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'waiting interaction did not open')
assert(state.ui.interaction.title == 'Pi waiting input', state.ui.interaction.title or 'nil')
local selectable = {}
for index, item in ipairs(state.ui.interaction.items) do
  if item.selectable ~= false then
    table.insert(selectable, index)
  end
end
assert(#selectable == 1, vim.inspect(state.ui.interaction.items))
local waiting_item = state.ui.interaction.items[selectable[1]]
local label = waiting_item.label
assert(waiting_item.text == 'waiting answer', vim.inspect(waiting_item))
assert(label:find('%[wait%]'), label)
local waiting_tree_items = vim.inspect(state.ui.interaction.items)
local saw_running_context = false
for _, item in ipairs(state.ui.interaction.items) do
  if item.text == 'running answer' and item.selectable == false then
    saw_running_context = true
  end
end
assert(saw_running_context, waiting_tree_items)
assert(not waiting_tree_items:find('unrelated sibling', 1, true), waiting_tree_items)
assert(state.ui.interaction.items[selectable[1]].runtime_key == 'waiting-runtime', vim.inspect(state.ui.interaction.items[selectable[1]]))
assert(state.ui.interaction.selected == selectable[1], 'waiting picker should focus the waiting node')

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function()
  return state.rpc.active_key == 'waiting-runtime' and state.ui.interaction and state.ui.interaction.title == 'Permission Required'
end), 'selecting waiting row should activate its runtime and reopen pending input')
assert(vim.tbl_contains(requested, 'get_state'), vim.inspect(requested))
assert(vim.tbl_contains(requested, 'get_session_stats'), vim.inspect(requested))
assert(vim.tbl_contains(requested, 'get_messages'), vim.inspect(requested))
assert(vim.wait(1000, function()
  local rendered = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
  return rendered:find('waiting branch rendered from rpc', 1, true)
    and rendered:find('waiting branch answer from rpc', 1, true)
    and rendered:find('waiting tool line 40', 1, true)
    and rendered:find('#### Permission request: bash `git *`', 1, true)
end), table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n'))
local function line_number(pattern)
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false)
  for index, line in ipairs(lines) do
    if line:find(pattern, 1, true) then
      return index
    end
  end
end
local tool_header = line_number('### Tool: bash printf waiting tool')
local permission_header = line_number('#### Permission request: bash `git *`')
assert(tool_header and permission_header, table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n'))
vim.api.nvim_win_call(state.ui.output_win, function()
  assert(vim.fn.foldclosed(tool_header + 1) == -1, 'waiting switch should expand latest folded tool details')
  assert(vim.fn.foldclosed(permission_header + 1) == -1, 'waiting switch should show latest permission details')
end)
assert(state.ui.interaction.items[1].value == 'Yes', vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), 'pending extension UI response missing')
assert(sent[1].type == 'extension_ui_response' and sent[1].id == 'waiting-select' and sent[1].value == 'Yes', vim.inspect(sent[1]))
waiting.waiting_input = false
waiting.status = 'running'
waiting.pending_extension_ui_request = nil

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end
local orphan = state.ensure_rpc_runtime('orphan-waiting-runtime')
orphan.job_id = 103
orphan.active = true
orphan.waiting_input = true
orphan.status = 'waiting input'
orphan.session_file = root_file
orphan.branch_root = root_file
orphan.branch_entry_id = 'missing-entry-id'
orphan.label = 'Pi.dev session'
orphan.pending_extension_ui_request = {
  type = 'extension_ui_request',
  __pi_runtime_key = 'orphan-waiting-runtime',
  id = 'orphan-select',
  method = 'select',
  title = 'Orphan waiting select',
  options = { 'answer', 'skip' },
}
state.set_active_rpc_runtime('running-runtime')
api.waiting()
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Pi waiting input'
end), 'fallback waiting interaction did not open')
local fallback_items = vim.inspect(state.ui.interaction.items)
assert(fallback_items:find('Useful Waiting Session', 1, true), fallback_items)
assert(fallback_items:find('Pi.dev session: Useful Waiting Session', 1, true), fallback_items)
assert(fallback_items:find('Pi.dev session  %[%w', 1, false) == nil, fallback_items)
assert(fallback_items:find('%[wait%]'), fallback_items)
assert(#notifications == 0, vim.inspect(notifications))
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function()
  return state.rpc.active_key == 'orphan-waiting-runtime' and state.ui.interaction and state.ui.interaction.title == 'Orphan waiting select'
end), 'selecting fallback waiting runtime should activate it and reopen pending input')

orphan.waiting_input = false
orphan.status = 'idle'
orphan.pending_extension_ui_request = nil
require('pi-dev.ui').close_interaction({ process_queue = false })

local stalled = state.ensure_rpc_runtime('stalled-waiting-runtime')
stalled.job_id = 104
stalled.active = true
stalled.waiting_input = true
stalled.status = 'waiting input'
stalled.session_file = root_file
stalled.branch_root = root_file
stalled.branch_entry_id = 'u2'
stalled.pending_extension_ui_request = {
  type = 'extension_ui_request',
  __pi_runtime_key = 'stalled-waiting-runtime',
  id = 'stalled-select',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'pwd'. Allow this command?",
  options = { 'Yes', 'No' },
}
state.set_active_rpc_runtime('running-runtime')
local stalled_requested = {}
rpc.request = function(message, cb)
  table.insert(stalled_requested, message.type)
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = root_file, isStreaming = false, model = 'fake/stalled' } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { tokens = { total = 456 } } })
  elseif message.type == 'get_messages' then
    -- Simulate Pi being blocked on the pending permission and not answering
    -- read-only RPC requests until the extension UI response is sent.
  end
  return message.type
end
api.waiting()
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Pi waiting input'
end), 'stalled waiting picker did not open')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function()
  return state.rpc.active_key == 'stalled-waiting-runtime'
    and state.ui.interaction
    and state.ui.interaction.title == 'Permission Required'
end), 'stalled waiting runtime should reopen permission immediately without waiting for get_messages')
assert(vim.tbl_contains(stalled_requested, 'get_messages'), vim.inspect(stalled_requested))
local stalled_rendered = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(stalled_rendered:find('#### Permission request: bash `pwd`', 1, true), stalled_rendered)
assert(stalled.waiting_input == true, 'pending permission should keep runtime counted as waiting input')
local statusline = require('pi-dev.statusline')
statusline.update_from_state({ isStreaming = true, model = 'fake/stalled' }, { runtime = stalled })
assert(stalled.pending_extension_ui_request ~= nil, 'streaming state refresh must not drop pending permission request')
assert(stalled.waiting_input == true, 'streaming state refresh must not decrement waiting input while permission is pending')
local status_text = statusline.render_for_width(120)
assert(status_text:find('wait 1', 1, true), status_text)
rpc.schedule_background_idle_stops()
assert(stalled.idle_timer == nil, 'pending permission should protect waiting runtime from idle timeout kill')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[#sent] and sent[#sent].id == 'stalled-select' end), 'stalled permission response missing')
assert(stalled.waiting_input == false, 'waiting input should clear only after permission answer')

state.is_job_running = original_is_job_running
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
