#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({
  exec = { bin = 'pi-test' },
  rpc = { pool_size = 1 },
  keymaps = { enable = false },
})

local api = require('pi-dev.api')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local root_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'root', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'fork from here' } }),
}, root_file)
state.session.current_file = root_file

vim.fn.jobstart = function()
  error('tree selection must not try to start another RPC when the pool is full')
end
vim.fn.chansend = function()
  error('tree selection must not send RPC when the pool is full')
end
state.is_job_running = function(runtime)
  return runtime and runtime.job_id ~= nil
end

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = tostring(message), level = level })
end

local default_runtime = state.ensure_rpc_runtime('default')
default_runtime.job_id = 101
default_runtime.status = 'idle'
state.set_active_rpc_runtime('default')
ui.show()
local original_output_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')

api.tree()
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.kind == 'tree'
end), 'tree interaction should open')
local original_interaction = state.ui.interaction
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function()
  return #notifications > 0
end), vim.inspect(notifications))
assert(notifications[#notifications].message:find('pool exhausted', 1, true), vim.inspect(notifications))
assert(state.ui.interaction == original_interaction, 'tree should stay open when branch RPC pool is full')
assert(state.ui.interaction and state.ui.interaction.kind == 'tree', 'tree interaction should remain visible')
assert(vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.tree_buf, 'output surface should still show the tree')
assert(state.rpc.active_key == 'default', 'failed tree selection must not switch active runtime')
assert(state.rpc_runtime_count({ running_only = true }) == 1, 'running RPC count must remain at the pool limit')
assert(state.rpc_runtime_count() == 1, 'failed tree selection must not create a disconnected extra runtime')
local output_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(output_text == original_output_text or output_text:find('Pi tree', 1, true), 'tree output should not be replaced by an error dialog')
assert(output_text:find('Pi RPC pool exhausted', 1, true) == nil, output_text)
assert(ui.get_input_text() == '', 'failed tree selection must not fill input')
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
