#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')
local ui = require('pi-dev.ui')

ui.show()
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end
local runtime = state.active_rpc_runtime()
runtime.job_id = 777
runtime.active = true
runtime.status = 'running'
state.sync_active_rpc_runtime(runtime)

local requests = {}
rpc.request = function(message, cb)
  table.insert(requests, message.type)
  if message.type == 'get_available_models' and cb then
    cb({ success = true, data = { models = { { provider = 'fake', id = 'model-a' } } } })
  elseif message.type == 'set_model' and cb then
    cb({ success = true, data = { provider = message.provider, id = message.modelId } })
  elseif cb then
    cb({ success = true, data = {} })
  end
  return message.type
end
rpc.start = function()
  local active = state.active_rpc_runtime()
  active.job_id = active.job_id or 778
  state.sync_active_rpc_runtime(active)
  return active.job_id
end
local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

local blocked
api.set_model('fake', 'blocked', function(response)
  blocked = response
end)
assert(blocked and blocked.cancelled == true, vim.inspect(blocked))
assert(#requests == 0, vim.inspect(requests))
assert(#notifications == 1 and notifications[1].level == vim.log.levels.WARN, vim.inspect(notifications))
assert(notifications[1].message:find('unavailable during active Pi work', 1, true), notifications[1].message)

api.model_picker()
assert(#requests == 0, 'model picker should not request models during active work: ' .. vim.inspect(requests))

runtime.active = true
runtime.waiting_input = true
runtime.status = 'waiting input'
state.sync_active_rpc_runtime(runtime)
notifications = {}
local waiting_done
api.set_model('fake', 'waiting-ok', function(response)
  waiting_done = response
end)
assert(waiting_done and waiting_done.success == true, vim.inspect(waiting_done))
assert(requests[1] == 'set_model', vim.inspect(requests))
assert(#notifications == 0, vim.inspect(notifications))

runtime.active = false
runtime.waiting_input = false
runtime.status = 'idle'
state.sync_active_rpc_runtime(runtime)
requests = {}
local idle_done
api.set_model('fake', 'idle-ok', function(response)
  idle_done = response
end)
assert(idle_done and idle_done.success == true, vim.inspect(idle_done))
assert(requests[1] == 'set_model', vim.inspect(requests))
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
