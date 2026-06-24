#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, rpc = { idle_timeout_ms = 0 } })
local api = require('pi-dev.api')
local ext = require('pi-dev.extension_ui')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

vim.fn.jobwait = function()
  return { -1 }
end

local requests = {}
rpc.request = function(message, callback)
  table.insert(requests, message)
  if callback then
    callback({ __pi_runtime_key = state.rpc.active_key, success = true })
  end
  return message.id or 'abort-request'
end

local runtime = state.set_active_rpc_runtime('abort-me')
runtime.job_id = 901
runtime.active = true
runtime.status = 'waiting input'
runtime.waiting_input = true
runtime.current_extension_interaction = { kind = 'select', opts = { request_id = 'saved-current' } }
runtime.interaction_queue = { { kind = 'select', opts = { request_id = 'queued' } } }
runtime.pending_extension_ui_request = {
  type = 'extension_ui_request',
  __pi_runtime_key = 'abort-me',
  id = 'pending',
  method = 'select',
  title = 'Pending select',
  options = { 'Yes', 'No' },
}

ui.show()
ext.handle_request({
  type = 'extension_ui_request',
  __pi_runtime_key = 'abort-me',
  id = 'visible-abort',
  method = 'select',
  title = 'Visible abort select',
  options = { 'alpha', 'beta' },
})
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.request_id == 'visible-abort'
end), 'visible extension interaction did not open')

api.abort()

assert(requests[1] and requests[1].type == 'abort', vim.inspect(requests))
assert(state.ui.interaction == nil, 'user abort should close the visible extension interaction')
assert(runtime.pending_extension_ui_request == nil, 'user abort should clear pending extension UI request')
assert(runtime.current_extension_interaction == nil, 'user abort should clear saved visible extension interaction')
assert(#(runtime.interaction_queue or {}) == 0, 'user abort should clear queued extension interactions')
assert(runtime.waiting_input == false, 'user abort should leave runtime out of waiting-input state')
assert(state.statusline.waiting_input == false, 'user abort should clear status waiting-input state')

ext.handle_request({
  type = 'extension_ui_request',
  __pi_runtime_key = 'abort-me',
  id = 'scheduled-abort',
  method = 'select',
  title = 'Scheduled abort select',
  options = { 'one', 'two' },
})
api.abort()
vim.wait(100, function()
  return state.ui.interaction ~= nil
end)
assert(state.ui.interaction == nil, 'user abort should suppress extension prompts already scheduled for display')
assert(runtime.pending_extension_ui_request == nil, 'scheduled abort should clear pending request')
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
