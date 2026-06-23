#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })

local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')
local ui = require('pi-dev.ui')

ui.show()
state.session.current_file = './tmp/pi-dev-test/current-session.jsonl'

local original_is_job_running = state.is_job_running
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

local function reset_runtime(key, active)
  state.rpc.runtimes = {}
  state.rpc.active_key = key
  local runtime = state.ensure_rpc_runtime(key)
  runtime.job_id = 100
  runtime.active = active == true
  runtime.status = active and 'running' or 'idle'
  state.sync_active_rpc_runtime(runtime)
  ui.clear_input()
  return runtime
end

local sent = {}
rpc.request = function(message, cb)
  if not state.is_job_running(state.active_rpc_runtime()) then
    rpc.start(state.rpc.active_key, { activate = true })
  end
  table.insert(sent, message)
  if cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end

local stop_all_count = 0
rpc.stop_all = function()
  stop_all_count = stop_all_count + 1
  state.rpc.runtimes = {}
  state.rpc.active_key = 'default'
  state.sync_active_rpc_runtime(state.ensure_rpc_runtime('default'))
end

rpc.start = function(key, opts)
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key or 'default')
  if not opts or opts.activate ~= false then
    state.set_active_rpc_runtime(runtime.key)
  end
  runtime.job_id = 200 + stop_all_count
  runtime.active = false
  runtime.status = 'idle'
  state.sync_active_rpc_runtime(runtime)
  return runtime.job_id
end

local select_calls = 0
vim.ui.select = function(items, opts, cb)
  select_calls = select_calls + 1
  assert(opts.prompt:find('Switching Pi session will stop 1 Pi RPC runtime', 1, true), opts.prompt)
  assert(opts.prompt:find('volatile runtime-local state', 1, true), opts.prompt)
  assert(items[1].confirm == false, vim.inspect(items))
  assert(items[2].confirm == true, vim.inspect(items))
  cb(items[1])
end

reset_runtime('running-branch', true)
local cancelled
sessions.switch_to('./tmp/pi-dev-test/target-session.jsonl', { title = 'Target session' }, function(response)
  cancelled = response
end)
assert(vim.wait(1000, function() return cancelled ~= nil end), 'cancelled callback missing')
assert(cancelled.cancelled == true, vim.inspect(cancelled))
assert(#sent == 0, vim.inspect(sent))
assert(stop_all_count == 0, 'cancel must keep running runtimes')
assert(select_calls == 1, select_calls)

vim.ui.select = function(items, opts, cb)
  select_calls = select_calls + 1
  cb(items[2])
end

reset_runtime('running-branch', true)
local switched
sessions.switch_to('./tmp/pi-dev-test/target-session.jsonl', { title = 'Target session' }, function(response)
  switched = response
end)
assert(vim.wait(1000, function() return switched ~= nil end), 'confirmed switch callback missing')
assert(stop_all_count == 1, 'confirm must stop all existing running RPC runtimes')
assert(sent[1] and sent[1].type == 'switch_session' and sent[1].sessionPath == './tmp/pi-dev-test/target-session.jsonl', vim.inspect(sent))
assert(state.rpc_runtime_count({ running_only = true }) == 1, 'confirmed switch should leave exactly one fresh RPC runtime')
assert(state.session.current_file == './tmp/pi-dev-test/target-session.jsonl', state.session.current_file)
assert(select_calls == 2, select_calls)

local same_root_dir = vim.fn.tempname()
vim.fn.mkdir(same_root_dir, 'p')
local root_file = same_root_dir .. '/root.jsonl'
local current_child = same_root_dir .. '/current-child.jsonl'
local target_child = same_root_dir .. '/target-child.jsonl'
vim.fn.writefile({ vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }) }, root_file)
vim.fn.writefile({ vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), parentSession = root_file }) }, current_child)
vim.fn.writefile({ vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), parentSession = root_file }) }, target_child)
state.session.current_file = current_child
sent = {}
local select_before_same_root = select_calls
vim.ui.select = function()
  error('switching within the same root session tree must not ask destructive confirmation while the branch RPC pool has capacity')
end
reset_runtime('same-root-running-branch', true)
sessions.switch_to(target_child, { title = 'Same root target' })
assert(vim.wait(1000, function() return sent[1] ~= nil end), vim.inspect(sent))
assert(sent[1] and sent[1].type == 'switch_session' and sent[1].sessionPath == target_child, vim.inspect(sent))
assert(select_calls == select_before_same_root, 'same-root branch switch must not prompt')
assert(stop_all_count == 1, 'same-root branch switch must not stop running RPC runtimes')

vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'tree-root-u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'tree branch point while running' } }),
  vim.json.encode({ type = 'message', id = 'tree-root-a1', parentId = 'tree-root-u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'assistant', content = 'branch answer' } }),
  vim.json.encode({ type = 'message', id = 'tree-root-u2', parentId = 'tree-root-a1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'user', content = 'current branch prompt' } }),
}, root_file)
state.session.current_file = root_file
state.session.tree_root_file = root_file
sent = {}
local tree_same_root_select_calls = 0
vim.ui.select = function()
  tree_same_root_select_calls = tree_same_root_select_calls + 1
  error('same-root tree branch selection must not ask while the branch RPC pool has capacity')
end
reset_runtime('tree-same-root-running-branch', true)
sessions.tree()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Pi tree' end), 'same-root file tree should open')
assert(state.ui.interaction.items[1].entry_id == 'tree-root-u1', vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil and sent[2] ~= nil end), vim.inspect(sent))
assert(sent[1].type == 'switch_session' and sent[1].sessionPath == root_file, vim.inspect(sent))
assert(sent[2].type == 'fork' and sent[2].entryId == 'tree-root-u1', vim.inspect(sent))
assert(tree_same_root_select_calls == 0, 'same-root tree branch selection must not prompt')
assert(stop_all_count == 1, 'same-root tree branch selection must not stop running RPC runtimes')

state.session.current_file = current_child
state.session.tree_root_file = nil
sent = {}
reset_runtime('idle-branch', false)
state.rpc.runtimes['idle-inactive-branch'] = { key = 'idle-inactive-branch', job_id = 101, active = false, status = 'idle', pending = {}, stderr = {}, buffer = '' }
sessions.switch_to('./tmp/pi-dev-test/other-session.jsonl', { title = 'Other session' })
assert(select_calls == 2, 'idle connected runtimes without drafts should not prompt for destructive confirmation')
assert(stop_all_count == 2, 'different-root switch should reset idle old-root runtimes without prompting: ' .. tostring(stop_all_count))
assert(state.rpc.runtimes['idle-branch'] == nil and state.rpc.runtimes['idle-inactive-branch'] == nil, 'old-root runtimes should be removed after different-root switch')

sent = {}
local inactive_non_idle_cancelled
vim.ui.select = function(items, opts, cb)
  select_calls = select_calls + 1
  assert(opts.prompt:find('Switching Pi session will stop 1 Pi RPC runtime', 1, true), opts.prompt)
  cb(items[1])
end
reset_runtime('active-idle-session-switch', false)
state.rpc.runtimes['inactive-waiting-branch'] = { key = 'inactive-waiting-branch', job_id = 102, active = false, waiting_input = true, status = 'waiting input', pending = {}, stderr = {}, buffer = '' }
sessions.switch_to('./tmp/pi-dev-test/non-idle-target.jsonl', { title = 'Non-idle target' }, function(response)
  inactive_non_idle_cancelled = response
end)
assert(vim.wait(1000, function() return inactive_non_idle_cancelled ~= nil end), 'inactive non-idle cancellation callback missing')
assert(inactive_non_idle_cancelled.cancelled == true, vim.inspect(inactive_non_idle_cancelled))
assert(#sent == 0, vim.inspect(sent))
assert(stop_all_count == 2, 'cancelled session switch with inactive non-idle runtime must keep runtimes')
assert(select_calls == 3, select_calls)

vim.ui.select = function(items, opts, cb)
  select_calls = select_calls + 1
  assert(opts.prompt:find('Switching Pi session will stop 1 Pi RPC runtime', 1, true), opts.prompt)
  cb(items[1])
end
sent = {}
reset_runtime('new-running-cancel', true)
local new_cancelled
sessions.new_session(function(response)
  new_cancelled = response
end)
assert(vim.wait(1000, function() return new_cancelled ~= nil end), 'cancelled new-session callback missing')
assert(new_cancelled.cancelled == true, vim.inspect(new_cancelled))
assert(#sent == 0, vim.inspect(sent))
assert(stop_all_count == 2, 'cancelled new-session switch must keep running runtimes')

vim.ui.select = function(items, opts, cb)
  select_calls = select_calls + 1
  cb(items[2])
end
sent = {}
reset_runtime('new-running-confirm', true)
local new_done
sessions.new_session(function(response)
  new_done = response
end)
assert(vim.wait(1000, function() return new_done ~= nil end), 'confirmed new-session callback missing')
assert(stop_all_count == 3, 'confirmed new-session switch must stop running RPC runtimes')
assert(sent[1] and sent[1].type == 'new_session', vim.inspect(sent))
assert(state.rpc_runtime_count({ running_only = true }) == 1, 'confirmed new session should leave exactly one fresh RPC runtime')
assert(select_calls == 5, select_calls)

local tree_select_calls = 0
vim.ui.select = function(items, opts, cb)
  tree_select_calls = tree_select_calls + 1
  assert(opts.prompt:find('Switching Pi session will stop 1 Pi RPC runtime', 1, true), opts.prompt)
  cb(items[1])
end
sent = {}
state.session.current_file = nil
reset_runtime('tree-running-cancel', true)
rpc.request = function(message, cb)
  table.insert(sent, message)
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  elseif message.type == 'get_fork_messages' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { messages = {
      { entryId = 'tree-u1', role = 'user', text = 'fallback tree prompt', graph = '* ' },
    } } })
  elseif message.type == 'fork' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { text = 'forked text' } })
  end
  return message.type
end
sessions.tree()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Pi tree' end), 'fallback tree should open')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function() return tree_select_calls == 1 end), 'tree destructive switch confirmation should appear')
for _, message in ipairs(sent) do
  assert(message.type ~= 'fork', 'cancelled tree destructive confirmation must not fork: ' .. vim.inspect(sent))
end
assert(stop_all_count == 3, 'cancelled tree destructive confirmation must keep running runtimes')

vim.ui.select = function(items, opts, cb)
  tree_select_calls = tree_select_calls + 1
  cb(items[2])
end
sent = {}
state.ui.interaction = nil
reset_runtime('tree-running-confirm', true)
sessions.tree()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Pi tree' end), 'fallback tree should reopen')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function()
  for _, message in ipairs(sent) do
    if message.type == 'fork' and message.entryId == 'tree-u1' then
      return true
    end
  end
  return false
end), vim.inspect(sent))
assert(stop_all_count == 4, 'confirmed tree destructive switch should stop running RPC runtimes')
assert(tree_select_calls == 2, tree_select_calls)

state.is_job_running = original_is_job_running
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
