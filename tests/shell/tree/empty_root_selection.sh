#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local sessions = require('pi-dev.sessions')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')

state.session.current_file = nil
state.session.tree_root_file = nil
local active = state.set_active_rpc_runtime('runtime-a')
active.job_id = 101
active.status = 'idle'
state.sync_active_rpc_runtime(active)
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = tostring(message), level = level })
end

local forbidden_requests = {}
rpc.request = function(message, cb)
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  elseif message.type == 'get_fork_messages' and cb then
    cb({
      __pi_runtime_key = state.rpc.active_key,
      success = true,
      data = {
        messages = {
          { role = 'user', text = '', timestamp = '2026-01-01T00:00:00.000Z' },
        },
      },
    })
  else
    table.insert(forbidden_requests, message)
    if cb then
      cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
    end
  end
  return message.type
end

sessions.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'empty-root tree interaction should open')
assert(#state.ui.interaction.items == 1, vim.inspect(state.ui.interaction.items))
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function()
  for _, notification in ipairs(notifications) do
    if notification.message:find('empty root', 1, true) and notification.message:find('no messages in history', 1, true) then
      return true
    end
  end
  return false
end), 'selecting an empty root should show an empty-history popup: ' .. vim.inspect(notifications))
assert(#forbidden_requests == 0, 'empty root selection must not switch or fork: ' .. vim.inspect(forbidden_requests))
assert(state.ui.interaction ~= nil, 'empty root popup should keep tree interaction open')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
