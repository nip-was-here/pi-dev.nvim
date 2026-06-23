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
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'first prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'first answer' } }),
  vim.json.encode({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'second prompt' } }),
  vim.json.encode({ type = 'message', id = 'a2', parentId = 'u2', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'second answer' } }),
}, root_file)

local original_is_job_running = state.is_job_running
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end
rpc.start = function(key, opts)
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key)
  if not opts or opts.activate ~= false then
    state.set_active_rpc_runtime(runtime.key)
  end
  runtime.job_id = runtime.job_id or 100
  runtime.status = runtime.status or 'idle'
  state.sync_active_rpc_runtime(runtime)
  return runtime.job_id
end

local startinsert_calls = 0
local original_cmd = vim.cmd
vim.cmd = function(command)
  if command == 'startinsert' then
    startinsert_calls = startinsert_calls + 1
  end
  return original_cmd(command)
end

local requests = {}
rpc.request = function(message, cb)
  table.insert(requests, message)
  if message.type == 'switch_session' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { cancelled = false } })
  elseif message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = message.sessionPath or state.session.current_file, model = 'fake/model' } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  elseif message.type == 'get_messages' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { messages = { { role = 'assistant', content = 'loaded selected branch' } } } })
  end
  return message.type
end

-- Selecting the tree row that is already active should only close/return: no
-- switch, fork, or history reload.
state.session.current_file = root_file
state.session.tree_root_file = root_file
state.set_active_rpc_runtime(root_file)
local active = state.active_rpc_runtime()
active.job_id = 100
active.session_file = root_file
active.branch_root = root_file
active.branch_entry_id = 'a2'
active.status = 'idle'
state.sync_active_rpc_runtime(active)
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree did not open for active-row case')
local active_index
for index, item in ipairs(state.ui.interaction.items or {}) do
  if item.entry_id == 'a2' then
    active_index = index
    break
  end
end
assert(active_index, vim.inspect(state.ui.interaction.items))
requests = {}
startinsert_calls = 0
vim.api.nvim_feedkeys(tostring(active_index), 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil end), 'active tree selection should close the picker')
assert(startinsert_calls == 0, 'active branch selection must not enter insert mode in Pi input')
for _, request in ipairs(requests) do
  assert(request.type ~= 'switch_session' and request.type ~= 'fork' and request.type ~= 'get_messages', 'active tree selection must not reload: ' .. vim.inspect(requests))
end

-- Selecting a different tree row loads it first, then focus returns to the lower
-- Pi panel, ready for input rather than leaving the user in the output tree.
state.session.current_file = root_file
state.session.tree_root_file = root_file
state.set_active_rpc_runtime(root_file)
active = state.active_rpc_runtime()
active.job_id = 100
active.session_file = root_file
active.branch_root = root_file
active.branch_entry_id = 'a2'
active.status = 'idle'
state.sync_active_rpc_runtime(active)
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree did not reopen for different-row case')
local other_index
for index, item in ipairs(state.ui.interaction.items or {}) do
  if item.entry_id == 'a1' then
    other_index = index
    break
  end
end
assert(other_index, vim.inspect(state.ui.interaction.items))
requests = {}
startinsert_calls = 0
vim.api.nvim_feedkeys(tostring(other_index), 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction == nil and vim.api.nvim_get_current_win() == state.ui.input_win
end), 'different tree selection should finish focused in the lower Pi pane')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'different tree selection should restore input buffer')
assert(startinsert_calls == 0, 'different branch selection must not enter insert mode in Pi input')
local saw_switch = false
for _, request in ipairs(requests) do
  if request.type == 'switch_session' then
    saw_switch = true
  end
end
assert(saw_switch, vim.inspect(requests))

-- Esc/q from tree returns focus to the surface that was active before opening
-- tree. If a permission was visible before tree, it is restored after close.
state.session.current_file = root_file
state.session.tree_root_file = root_file
ui.focus_input()
local input_win = state.ui.input_win
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.kind == 'tree' end), 'tree did not open for focus-restore input case')
assert(vim.api.nvim_get_current_win() == state.ui.output_win, 'tree should focus the output interaction surface')
vim.api.nvim_feedkeys('q', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil and vim.api.nvim_get_current_win() == input_win end), 'closing tree should return focus to prior input window')

ui.show_interaction({
  runtime_key = state.rpc.active_key,
  request_id = 'pre-tree-permission',
  title = 'Permission Required',
  kind = 'permission',
  filetype = 'markdown',
  items = { { label = 'Yes', value = 'Yes' }, { label = 'No', value = 'No' } },
  on_submit = function() end,
})
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Permission Required' end), 'permission setup before tree failed')
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.kind == 'tree' end), 'tree should preempt lower-priority permission')
vim.api.nvim_feedkeys('q', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Permission Required' and vim.api.nvim_get_current_win() == state.ui.input_win
end), 'closing tree should restore the previous permission interaction')
ui.close_interaction({ process_queue = false })

api.tree()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.kind == 'tree' end), 'tree did not reopen before queued permission case')
require('pi-dev.extension_ui').handle_request({
  type = 'extension_ui_request',
  __pi_runtime_key = state.rpc.active_key,
  id = 'queued-select-during-tree',
  method = 'select',
  title = 'Queued select',
  options = { 'one', 'two' },
})
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.kind == 'tree' end), 'lower-priority select should not replace active tree')
vim.api.nvim_feedkeys('q', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Queued select' and vim.api.nvim_get_current_win() == state.ui.input_win
end), 'queued lower-priority select should appear after closing tree')
local queued_runtime = state.ensure_rpc_runtime(state.ui.interaction.runtime_key)
ui.close_interaction({ process_queue = false })
queued_runtime.waiting_input = false
queued_runtime.status = 'idle'
queued_runtime.pending_extension_ui_request = nil
queued_runtime.current_extension_interaction = nil
queued_runtime.interaction_queue = {}

-- /waiting has the same focus contract: after choosing another waiting branch,
-- reopen its pending permission in the lower interaction pane and focus it.
local waiting_key = 'waiting-runtime'
local waiting = state.ensure_rpc_runtime(waiting_key)
waiting.job_id = 200
waiting.active = true
waiting.waiting_input = true
waiting.status = 'waiting input'
waiting.session_file = root_file
waiting.branch_root = root_file
waiting.branch_entry_id = 'u2'
waiting.pending_extension_ui_request = {
  type = 'extension_ui_request',
  __pi_runtime_key = waiting_key,
  id = 'waiting-select',
  method = 'select',
  title = 'Waiting permission',
  options = { 'Yes', 'No' },
}
state.set_active_rpc_runtime(root_file)
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.kind == 'tree' end), 'tree did not open before waiting priority check')
api.waiting()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Pi waiting input' end), 'waiting picker did not preempt lower-priority tree')
startinsert_calls = 0
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function()
  return state.rpc.active_key == waiting_key
    and state.ui.interaction
    and state.ui.interaction.title == 'Waiting permission'
    and vim.api.nvim_get_current_win() == state.ui.input_win
    and vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf
end), 'different waiting selection should focus reopened lower interaction')
assert(startinsert_calls == 0, 'switching to a waiting select branch must not enter insert mode')

state.is_job_running = original_is_job_running
vim.cmd = original_cmd
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
