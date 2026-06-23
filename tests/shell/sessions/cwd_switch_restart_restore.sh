#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_root="$(mktemp -d)"
old_cwd="$(mktemp -d)"
new_cwd="$(mktemp -d)"
mkdir -p "$session_root/new"
session_file="$session_root/new/restored.jsonl"
printf '%s\n' "{\"type\":\"session\",\"version\":3,\"id\":\"restored\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"$new_cwd\"}" > "$session_file"
printf '%s\n' "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-01-01T00:00:01.000Z\",\"message\":{\"role\":\"user\",\"content\":\"restored from switched cwd\"}}" >> "$session_file"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<LUA
vim.cmd('cd ' .. vim.fn.fnameescape('$old_cwd'))
require('pi-dev').setup({
  keymaps = { enable = false },
  session_root = '$session_root',
  session_render = { max_messages = 5, chunk_size = 1, chunk_delay_ms = 1 },
})
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')
local ui = require('pi-dev.ui')
ui.show()

state.session.runtime_cwd = nil
assert(sessions.current_cwd() == '$old_cwd', sessions.current_cwd())
vim.cmd('lcd ' .. vim.fn.fnameescape('$new_cwd'))
state.session.runtime_cwd = nil
assert(sessions.current_cwd() == '$new_cwd', 'current_cwd should respect local/window cwd changes, got ' .. tostring(sessions.current_cwd()))

state.session.current_cwd = '$old_cwd'
state.session.auto_loaded_cwd = '$old_cwd'
state.session.current_file = '$session_root/old.jsonl'
local runtime = state.set_active_rpc_runtime('default')
runtime.job_id = 111
runtime.status = 'idle'
state.sync_active_rpc_runtime(runtime)
state.rpc.runtimes.branch = { key = 'branch', job_id = 222, status = 'idle', pending = {}, stderr = {}, buffer = '' }

local calls = {}
rpc.stop_all = function()
  table.insert(calls, 'stop_all')
  state.rpc.runtimes = {}
  state.set_active_rpc_runtime('default')
end
rpc.start = function()
  table.insert(calls, 'start:' .. tostring(state.session.runtime_cwd))
  local active = state.set_active_rpc_runtime('default')
  active.job_id = 333
  active.status = 'idle'
  state.sync_active_rpc_runtime(active)
  return 333
end
state.is_job_running = function(runtime_arg)
  runtime_arg = runtime_arg or state.active_rpc_runtime()
  return runtime_arg and runtime_arg.job_id ~= nil
end
rpc.request = function(message, cb)
  table.insert(calls, message.type .. (message.sessionPath and (':' .. message.sessionPath) or ''))
  if message.type == 'switch_session' and cb then
    cb({ success = true, data = {} })
  elseif cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

sessions.reload_for_cwd('$new_cwd')
assert(calls[1] == 'stop_all', vim.inspect(calls))
assert(calls[2] == 'start:$new_cwd', vim.inspect(calls))
assert(#notifications == 1 and notifications[1].level == vim.log.levels.WARN, vim.inspect(notifications))
assert(notifications[1].message:find('cwd changed', 1, true), notifications[1].message)
assert(notifications[1].message:find('$new_cwd', 1, true), notifications[1].message)
assert(vim.wait(1000, function()
  for _, call in ipairs(calls) do
    if call == 'switch_session:$session_file' then
      return true
    end
  end
  return false
end), vim.inspect(calls))
assert(state.session.current_cwd == '$new_cwd', tostring(state.session.current_cwd))
assert(state.session.auto_loaded_cwd == '$new_cwd', tostring(state.session.auto_loaded_cwd))
assert(state.session.current_file == '$session_file', tostring(state.session.current_file))
assert(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
  return text:find('restored from switched cwd', 1, true) ~= nil
end), table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'))
LUA

output="$({
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  rm -rf "$session_root" "$old_cwd" "$new_cwd" "$tmp_lua"
  exit 1
}

rm -rf "$session_root" "$old_cwd" "$new_cwd" "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
