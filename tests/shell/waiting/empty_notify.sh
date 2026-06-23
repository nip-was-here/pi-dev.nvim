#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local config = require('pi-dev.config')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
config.options.session_root = session_root
local root_file = session_root .. '/root.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'idle branch prompt' } }),
}, root_file)
state.session.current_file = root_file

local original_is_job_running = state.is_job_running
state.is_job_running = function(runtime)
  return runtime and runtime.job_id ~= nil
end
local runtime = state.ensure_rpc_runtime('default')
runtime.job_id = 101
runtime.status = 'idle'
runtime.session_file = root_file
runtime.branch_root = root_file
runtime.branch_entry_id = 'u1'

rpc.request = function(message, cb)
  if cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { messages = {} } })
  end
  return message.type
end

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

ui.show_interaction({
  title = 'Pi waiting input',
  kind = 'waiting',
  message = 'stale waiting picker',
  filetype = 'text',
  markdown = false,
  items = { { label = 'stale row', value = 'stale' } },
  on_submit = function() end,
})
assert(state.ui.interaction and state.ui.interaction.title == 'Pi waiting input', 'stale waiting picker setup failed')

api.waiting()
assert(#notifications == 1, vim.inspect(notifications))
assert(notifications[1].message == 'No Pi branches are currently waiting for input.', vim.inspect(notifications))
assert(state.ui.interaction == nil, 'empty /waiting should close the stale waiting picker instead of leaving an interaction buffer visible')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'empty /waiting should restore the normal input buffer')

notifications = {}
runtime.waiting_input = true
runtime.status = 'waiting input'
api.waiting()
assert(#notifications == 1, vim.inspect(notifications))
assert(notifications[1].message == 'No Pi branches are currently waiting for input.', vim.inspect(notifications))
assert(state.ui.interaction == nil, 'runtime.waiting_input without a respondable interaction must not open a false default waiting row')
runtime.waiting_input = false
runtime.status = 'idle'

ui.hide()
notifications = {}
api.waiting()
assert(#notifications == 1, vim.inspect(notifications))
assert(state.ui.visible == false, 'empty /waiting should not open the Pi panel when it was hidden')
assert(state.ui.interaction == nil, 'empty /waiting should not create an interaction')

state.is_job_running = original_is_job_running
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
