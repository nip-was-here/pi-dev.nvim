#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, session_render = { chunk_delay_ms = 1 } })
local sessions = require('pi-dev.sessions')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local renderer = require('pi-dev.renderer')
local ui = require('pi-dev.ui')

ui.show()
renderer.clear('Branch B visible')
state.session.current_file = 'branch-b.jsonl'
state.session.tree_root_file = 'root-b.jsonl'
local branch_b = state.set_active_rpc_runtime('branch-b')
branch_b.job_id = 202
branch_b.status = 'idle'
branch_b.session_file = 'branch-b.jsonl'
branch_b.branch_root = 'root-b.jsonl'
state.sync_active_rpc_runtime(branch_b)
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

local captured
rpc.start = function(key)
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key)
  runtime.job_id = runtime.job_id or 101
  runtime.status = runtime.status or 'idle'
  return runtime.job_id
end
rpc.request = function(message, cb)
  if message.type == 'switch_session' then
    captured = cb
  elseif cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end

sessions.switch_to('branch-a.jsonl', { runtime_key = 'branch-a', title = 'Branch A' })
assert(state.rpc.active_key == 'branch-a', state.rpc.active_key)
local branch_a = state.active_rpc_runtime()
assert(branch_a.loading == true, vim.inspect(branch_a))
state.set_active_rpc_runtime('branch-b')
renderer.clear('Branch B visible')
assert(captured, 'switch_session callback should be captured')
captured({ __pi_runtime_key = 'branch-a', success = true, data = { sessionFile = 'branch-a.jsonl' } })
assert(state.rpc.active_key == 'branch-b', state.rpc.active_key)
assert(state.session.current_file == 'branch-b.jsonl', state.session.current_file)
assert(state.session.tree_root_file == 'root-b.jsonl', tostring(state.session.tree_root_file))
assert(state.ensure_rpc_runtime('branch-a').loading == false, vim.inspect(state.ensure_rpc_runtime('branch-a')))
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('Branch B visible', 1, true), text)
assert(not text:find('Restored current%-directory session'), text)
assert(not text:find('branch%-a%.jsonl'), text)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
