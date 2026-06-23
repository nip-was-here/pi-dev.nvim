#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, rpc = { idle_timeout_ms = 0 } })
local ext = require('pi-dev.extension_ui')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local next_job = 200
vim.fn.jobstart = function()
  next_job = next_job + 1
  return next_job
end
vim.fn.jobwait = function()
  return { -1 }
end
local sent = {}
rpc.write = function(message)
  table.insert(sent, message)
  return true
end

local function permission(id, command)
  return {
    type = 'extension_ui_request',
    id = id,
    method = 'select',
    title = "Permission Required\nPi requested bash command '" .. command .. "'. Allow this command?",
    options = { 'Yes', 'No' },
  }
end

ui.show()
rpc.use_runtime('branch-a', { branch_entry_id = 'a' })
ui.show_interaction({ title = 'Branch A overlay', items = { { label = 'close a' } } })
ext.handle_request(permission('perm-a', 'echo a'))
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Branch A overlay' and #(state.active_rpc_runtime().interaction_queue or {}) == 1
end), 'branch A permission should queue behind branch A overlay')
local runtime_a = state.active_rpc_runtime()
assert(runtime_a.key == 'branch-a')
ui.close_interaction({ process_queue = false })

rpc.use_runtime('branch-b', { branch_entry_id = 'b' })
assert(state.active_rpc_runtime().key == 'branch-b')
assert(#(state.active_rpc_runtime().interaction_queue or {}) == 0, 'branch B must not inherit branch A queue')
ui.show_interaction({ title = 'Branch B overlay', items = { { label = 'close b' } } })
ext.handle_request(permission('perm-b', 'echo b'))
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Branch B overlay' and #(state.active_rpc_runtime().interaction_queue or {}) == 1
end), 'branch B permission should queue behind branch B overlay')
assert(#(runtime_a.interaction_queue or {}) == 1, 'branch A queue should remain isolated while branch B queues')

ui.close_interaction()
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Permission Required' and state.ui.interaction.kind == 'permission'
end), 'branch B queued permission should show after branch B overlay closes')
local runtime_b = state.active_rpc_runtime()
assert(runtime_b.key == 'branch-b')

rpc.use_runtime('branch-a')
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Permission Required' and state.ui.interaction.kind == 'permission'
end), 'branch A queued permission should show when returning to branch A')
assert(runtime_b.current_extension_interaction and runtime_b.current_extension_interaction.opts.request_id == 'perm-b', 'visible branch B permission should be saved on branch switch')

rpc.use_runtime('branch-b')
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Permission Required' and state.ui.interaction.kind == 'permission'
end), 'branch B visible permission should restore when returning to branch B')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), 'branch B permission response missing')
assert(sent[1].id == 'perm-b' and sent[1].value == 'Yes', vim.inspect(sent[1]))
assert(runtime_a.current_extension_interaction and runtime_a.current_extension_interaction.opts.request_id == 'perm-a', 'visible branch A permission should remain saved while branch B is active')

rpc.use_runtime('branch-a')
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Permission Required' and state.ui.interaction.kind == 'permission'
end), 'branch A visible permission should restore when returning to branch A')
vim.api.nvim_feedkeys('2', 'xt', false)
assert(vim.wait(1000, function() return sent[2] ~= nil end), 'branch A permission response missing')
assert(sent[2].id == 'perm-a' and sent[2].value == 'No', vim.inspect(sent[2]))
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
