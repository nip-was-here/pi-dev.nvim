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
local statusline = require('pi-dev.statusline')

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
require('pi-dev.config').options.session_root = session_root
local root_file = session_root .. '/root.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'stale status branch' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'stale status answer' } }),
}, root_file)
state.session.current_file = root_file

local stale = state.ensure_rpc_runtime('stale-runtime')
stale.job_id = 999999
stale.active = true
stale.waiting_input = true
stale.status = 'waiting input'
stale.session_file = root_file
stale.branch_root = root_file
stale.branch_entry_id = 'u1'
state.set_active_rpc_runtime('stale-runtime')

local rendered_before = statusline.render_for_width(80)
assert(rendered_before:find('Pi status: off', 1, true), rendered_before)
assert(not rendered_before:find('wait', 1, true), rendered_before)
assert(state.rpc.runtimes['stale-runtime'].job_id == nil, 'statusline render should clear stale active runtime job')

local stale_tree = state.ensure_rpc_runtime('stale-tree-runtime')
stale_tree.job_id = 999998
stale_tree.active = true
stale_tree.waiting_input = true
stale_tree.status = 'waiting input'
stale_tree.session_file = root_file
stale_tree.branch_root = root_file
stale_tree.branch_entry_id = 'u1'

rpc.start = function()
  return 42
end
rpc.request = function(message, cb)
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = root_file } })
  end
  return message.type
end
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree did not open')
local labels = vim.inspect(state.ui.interaction.items)
assert(labels:find('stale status answer', 1, true), labels)
assert(not labels:find('%[wait%]'), labels)
assert(state.rpc.runtimes['stale-tree-runtime'] == nil, 'tree render should remove stale non-active runtime status')

state.ui.statuses.demo = 'ready'
state.ui.widgets.demo = { 'one' }
local live = state.ensure_rpc_runtime('live-runtime')
live.job_id = 999997
live.active = true
live.status = 'running'
rpc.stop_all()
assert(next(state.ui.statuses) == nil, vim.inspect(state.ui.statuses))
assert(next(state.ui.widgets) == nil, vim.inspect(state.ui.widgets))
assert(state.rpc_runtime_count() == 0, 'stop_all should clear tree/statusline runtime statuses')
local rendered_after = statusline.render_for_width(80)
assert(rendered_after:find('Pi status: off', 1, true), rendered_after)
assert(not rendered_after:find('run', 1, true), rendered_after)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
