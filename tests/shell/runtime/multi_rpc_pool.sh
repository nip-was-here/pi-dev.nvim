#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({
  exec = { bin = 'pi-test' },
  rpc = { pool_size = 2, idle_timeout_ms = 0 },
  keymaps = { enable = true, prefix = '<leader>a' },
})
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')
local extension_ui = require('pi-dev.extension_ui')
local sessions = require('pi-dev.sessions')
local api = require('pi-dev.api')
local ui = require('pi-dev.ui')

local job_id = 100
local started = {}
vim.fn.jobstart = function(cmd, opts)
  job_id = job_id + 1
  started[job_id] = opts
  return job_id
end
vim.fn.chansend = function()
  return 1
end
local stopped_jobs = {}
vim.fn.jobstop = function(job)
  stopped_jobs[job] = (stopped_jobs[job] or 0) + 1
  return 1
end
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

assert(rpc.use_runtime('branch-a', { branch_entry_id = 'a' }).job_id == 101)
assert(rpc.use_runtime('branch-b', { branch_entry_id = 'b' }).job_id == 102)
local branch_a_job = state.rpc.runtimes['branch-a'].job_id
assert(rpc.use_runtime('branch-a').job_id == branch_a_job, 'returning to an active branch must reuse its runtime')
ui.show()
assert(rpc.use_runtime('branch-c', { branch_entry_id = 'c' }).job_id == nil, 'pool exhaustion should not start a third runtime')
assert(rpc.use_runtime('branch-c', { branch_entry_id = 'c' }).job_id == nil, 'repeated pool exhaustion should still not start a runtime')
assert(vim.wait(1000, function() return #notifications > 0 end), vim.inspect(notifications))
assert(notifications[#notifications].message:find('pool exhausted', 1, true), vim.inspect(notifications))
local output_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local _, pool_notice_count = output_text:gsub('Pi RPC pool exhausted', '')
assert(pool_notice_count == 1, output_text)

state.set_active_rpc_runtime('branch-b')
state.session.current_file = 'branch-b-before-reload.jsonl'
local original_rpc_request = rpc.request
local reload_requests = {}
rpc.request = function(message, cb)
  table.insert(reload_requests, message.type)
  if message.type == 'get_state' and cb then
    cb({ success = true, data = { sessionFile = 'branch-b-before-reload.jsonl' } })
  elseif message.type == 'switch_session' and cb then
    cb({ success = true, data = { cancelled = false } })
  elseif cb then
    cb({ success = true, data = {} })
  end
  return message.type
end
local reload_map = vim.fn.maparg('<leader>aR', 'n', false, true)
assert(type(reload_map.callback) == 'function', '<leader>aR keymap callback missing')
reload_map.callback()
assert(vim.wait(1000, function()
  return state.rpc.runtimes['branch-b'] and state.rpc.runtimes['branch-b'].job_id == 103 and vim.tbl_contains(reload_requests, 'switch_session')
end), vim.inspect({ runtimes = state.rpc.runtimes, reload_requests = reload_requests }))
assert(stopped_jobs[102] == 1, vim.inspect(stopped_jobs))
assert(stopped_jobs[101] == nil, '<leader>aR must not stop the inactive branch-a RPC job')
assert(state.rpc.runtimes['branch-a'].job_id == 101, 'inactive branch-a RPC job should stay attached')
assert(vim.tbl_contains(reload_requests, 'get_state'), vim.inspect(reload_requests))
assert(vim.tbl_contains(reload_requests, 'switch_session'), vim.inspect(reload_requests))
rpc.request = original_rpc_request

state.rpc.runtimes['branch-a'].active = true
state.rpc.runtimes['branch-a'].status = 'running'
state.rpc.runtimes['branch-b'].active = true
state.rpc.runtimes['branch-b'].waiting_input = true
state.rpc.runtimes['branch-b'].status = 'waiting input'
local aggregate = statusline.render_for_width(100)
assert(aggregate:find('run 1/2', 1, true), aggregate)
assert(aggregate:find('wait 1', 1, true), aggregate)
assert(aggregate:find('(', 1, true) == nil, aggregate)
assert(aggregate:find(')', 1, true) == nil, aggregate)
assert(aggregate:find('%[', 1, false) == nil, aggregate)
assert(aggregate:find('%]', 1, false) == nil, aggregate)

state.set_active_rpc_runtime('branch-a')
extension_ui.handle_request({ __pi_runtime_key = 'branch-b', type = 'extension_ui_request', id = 'perm-b', method = 'select', title = 'Branch B permission', options = { 'Yes', 'No' } })
assert(state.rpc.runtimes['branch-b'].pending_extension_ui_request ~= nil, 'inactive permission should be queued on its branch runtime')
assert(state.ui.interaction == nil, 'inactive permission must not replace current Pi input/interaction surface')
rpc.use_runtime('branch-b')
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'queued branch permission should render after switching to its runtime')
assert(state.ui.interaction.title == 'Branch B permission', vim.inspect(state.ui.interaction))

local session_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'a', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = string.rep('tree row ', 30) } }),
  vim.json.encode({ type = 'message', id = 'b', parentId = 'a', timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'user', content = 'branch waiting input' } }),
}, session_file)
state.session.current_file = session_file
state.session.tree_root_file = nil
sessions.tree()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Pi tree' end), 'tree interaction should open')
local labels = vim.inspect(state.ui.interaction.items)
assert(labels:find('%[run%]'), labels)
assert(labels:find('%[wait%]'), labels)
for _, item in ipairs(state.ui.interaction.items) do
  assert(vim.fn.strdisplaywidth(item.label) <= require('pi-dev.format').window_text_width(state.ui.output_win), item.label)
end

assert(vim.fn.exists(':PiDevStopRpc') == 2, 'stop current RPC command should exist')
assert(vim.fn.maparg('<leader>aK', 'n') ~= '', 'kill current RPC keymap missing')
assert(vim.fn.maparg('<leader>ax', 'n') == '', 'old stop current RPC keymap should stay unmapped')
local stopped = false
api.stop_current_rpc = function()
  stopped = true
  return true
end
assert(api.handle_slash_command('/stop-rpc') and stopped, '/stop-rpc slash command should dispatch')
stopped = false
assert(api.handle_slash_command('/stop') and stopped, '/stop slash command should dispatch')

-- Idle runtimes must leave the pool after rpc.idle_timeout_ms so the idle
-- counter in the status separator shrinks after Pi RPC jobs are closed. A sole
-- idle runtime stays attached; background idle runtimes are timed out once a
-- second runtime exists.
require('pi-dev.config').options.rpc.idle_timeout_ms = 20
state.rpc.runtimes = {}
state.rpc.active_key = 'default'
local permission_runtime = rpc.use_runtime('perm-wait', { branch_entry_id = 'perm-wait' })
local permission_job = permission_runtime.job_id
rpc._handle_chunk(vim.json.encode({ type = 'agent_start' }) .. '\n', permission_runtime)
rpc._handle_chunk(vim.json.encode({ type = 'extension_ui_request', id = 'long-perm', method = 'select', title = 'Permission Required', options = { 'Yes', 'No' } }) .. '\n', permission_runtime)
rpc._handle_chunk(vim.json.encode({ type = 'compaction_end', isStreaming = true, reason = 'threshold' }) .. '\n', permission_runtime)
assert(permission_runtime.waiting_input == true, 'pending permission must stay waiting after compact-mode stream resumes')
assert(permission_runtime.status == 'waiting input', permission_runtime.status)
rpc._handle_chunk(vim.json.encode({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'after compact' } }) .. '\n', permission_runtime)
assert(permission_runtime.waiting_input == true, 'pending permission must stay waiting after late stream update')
assert(permission_runtime.status == 'waiting input', permission_runtime.status)
rpc._handle_chunk(vim.json.encode({ type = 'tool_execution_start', toolCallId = 'after-perm', toolName = 'bash' }) .. '\n', permission_runtime)
assert(permission_runtime.waiting_input == true, 'pending permission must stay waiting after late tool event')
assert(permission_runtime.status == 'waiting input', permission_runtime.status)
rpc._handle_chunk(vim.json.encode({ type = 'agent_end' }) .. '\n', permission_runtime)
assert(permission_runtime.waiting_input == true, 'pending permission must keep runtime in waiting-input state after agent_end')
assert(permission_runtime.status == 'waiting input', permission_runtime.status)
assert(permission_runtime.idle_timer == nil, 'pending permission must not schedule idle-stop timer')
assert(not vim.wait(80, function()
  return stopped_jobs[permission_job] ~= nil
end), 'pending permission runtime must not be stopped by idle timeout')
assert(state.rpc.runtimes['perm-wait'].job_id == permission_job, 'pending permission runtime must stay attached')

state.rpc.runtimes = {}
state.rpc.active_key = 'default'
local draft_runtime = rpc.use_runtime('draft-wait', { branch_entry_id = 'draft-wait' })
local draft_job = draft_runtime.job_id
ui.set_input_text('unsent idle draft')
rpc.use_runtime('draft-active', { branch_entry_id = 'draft-active' })
assert(draft_runtime.idle_timer == nil, 'unsent Pi input draft must protect idle runtime from idle-stop timer')
assert(not vim.wait(80, function()
  return stopped_jobs[draft_job] ~= nil
end), 'idle runtime with Pi input draft must not be stopped by idle timeout')
assert(state.rpc.runtimes['draft-wait'].job_id == draft_job, 'draft runtime must stay attached')

draft_runtime.input_text = ''
draft_runtime.editor_text = 'unsent editor draft'
rpc.schedule_idle_stop(draft_runtime)
assert(draft_runtime.idle_timer == nil, 'unsent editor draft must protect idle runtime from idle-stop timer')
assert(state.rpc.runtimes['draft-wait'].job_id == draft_job, 'editor draft runtime must stay attached')

state.rpc.runtimes = {}
state.rpc.active_key = 'default'
local initial_idle = rpc.use_runtime('default', { branch_entry_id = 'default' })
assert(initial_idle.idle_timer == nil, 'the only idle runtime should not be timed out')
local active_branch = rpc.use_runtime('active-branch', { branch_entry_id = 'active-branch' })
assert(active_branch.idle_timer == nil, 'newly active idle runtime should not immediately schedule its own idle-stop timer')
assert(initial_idle.idle_timer ~= nil, 'initial background idle runtime should get an idle-stop timer after another runtime starts')
assert(vim.wait(1000, function()
  return state.rpc.runtimes['default'] == nil and state.rpc_runtime_count({ running_only = true }) == 1
end), vim.inspect(state.rpc.runtimes))
assert(state.rpc.runtimes['active-branch'].job_id == active_branch.job_id, 'active branch runtime should be the remaining connected runtime')

state.rpc.runtimes = {}
state.rpc.active_key = 'default'
ui.clear_input()
local idle_a = rpc.use_runtime('idle-a', { branch_entry_id = 'idle-a' })
local idle_b = rpc.use_runtime('idle-b', { branch_entry_id = 'idle-b' })
state.set_active_rpc_runtime('idle-a')
if idle_a.idle_timer then
  vim.fn.timer_stop(idle_a.idle_timer)
  idle_a.idle_timer = nil
end
idle_a.active = false
idle_a.waiting_input = false
idle_a.status = 'idle'
idle_b.active = false
idle_b.waiting_input = false
idle_b.status = 'idle'
assert(statusline.render_for_width(100):find('idle 2', 1, true), statusline.render_for_width(100))
rpc.schedule_idle_stop(idle_b)
local idle_b_timer = idle_b.idle_timer
assert(idle_b_timer ~= nil, 'background idle runtime should have an idle-stop timer while another runtime is connected')
rpc.use_runtime('idle-b')
assert(idle_b.idle_timer == nil, 'activating/viewing an idle runtime must cancel its existing idle-stop timer')
assert(idle_a.idle_timer ~= nil, 'leaving an idle runtime should start its background idle-stop timer')
vim.fn.timer_stop(idle_a.idle_timer)
idle_a.idle_timer = nil
assert(not vim.wait(80, function()
  return state.rpc.runtimes['idle-b'] == nil
end), 'visible active idle runtime must not be stopped by a timer that started before activation')
assert(state.rpc.runtimes['idle-b'].job_id == idle_b.job_id, 'active idle runtime should stay attached while visible')
rpc.use_runtime('idle-a')
assert(idle_a.idle_timer == nil, 'returning to an idle runtime should cancel its background idle-stop timer')
assert(idle_b.idle_timer ~= nil, 'leaving the previously visible idle runtime should start its timer only after switching away')
assert(vim.wait(1000, function()
  return state.rpc.runtimes['idle-b'] == nil and state.rpc_runtime_count({ running_only = true }) == 1
end), vim.inspect(state.rpc.runtimes))
local after_idle_close = statusline.render_for_width(100)
assert(after_idle_close:find('Pi status: idle', 1, true), after_idle_close)
assert(after_idle_close:find('idle 2', 1, true) == nil, after_idle_close)

rpc.schedule_idle_stop(idle_a)
assert(idle_a.idle_timer == nil, 'remaining sole idle runtime should not be timed out')
local idle_c = rpc.use_runtime('idle-c', { branch_entry_id = 'idle-c' })
state.set_active_rpc_runtime('idle-c')
idle_a.active = false
idle_a.waiting_input = false
idle_a.status = 'idle'
rpc._handle_chunk(vim.json.encode({ type = 'agent_start' }) .. '\n', idle_c)
rpc._handle_chunk(vim.json.encode({ type = 'agent_end' }) .. '\n', idle_c)
assert(idle_c.idle_timer == nil, 'active visible branch must not start an idle timer when its turn ends')
rpc.schedule_idle_stop(idle_c)
assert(idle_c.idle_timer == nil, 'explicit idle-stop scheduling for the visible active runtime should be ignored')
rpc.schedule_idle_stop(idle_a)
assert(idle_a.idle_timer ~= nil, 'idle runtime should get a timer again after another runtime connects')
rpc.request({ type = 'prompt', message = 'reuse before idle timeout' }, nil, { runtime = idle_a })
assert(idle_a.idle_timer == nil, 'starting new work must cancel the idle-stop timer to avoid killing the prompt')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
