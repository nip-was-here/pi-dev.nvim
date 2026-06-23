#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ext = require('pi-dev.extension_ui')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')
require('pi-dev.rpc').write = function()
  return true
end

local function select_request(id, title)
  return {
    type = 'extension_ui_request',
    id = id,
    method = 'select',
    title = title,
    options = { 'alpha', 'beta' },
  }
end

ui.show()
ext.handle_request(select_request('visible-dup', 'Visible duplicate'))
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.request_id == 'visible-dup'
end), 'visible duplicate baseline interaction missing')
ext.handle_request(select_request('visible-dup', 'Visible duplicate changed'))
assert(#(state.active_rpc_runtime().interaction_queue or {}) == 0, 'duplicate visible request must not be queued')
assert(state.ui.interaction.title == 'Visible duplicate', 'duplicate visible request must not replace visible interaction')

ui.close_interaction({ process_queue = false, save_runtime_interaction = true })
assert(state.ui.interaction == nil)
assert(state.active_rpc_runtime().current_extension_interaction ~= nil, 'visible interaction should be saved')
ext.handle_request(select_request('visible-dup', 'Saved current duplicate changed'))
assert(#(state.active_rpc_runtime().interaction_queue or {}) == 0, 'duplicate saved-current request must not be queued')
assert(state.active_rpc_runtime().current_extension_interaction.opts.title == 'Visible duplicate', 'duplicate saved-current request must not replace saved interaction')
state.active_rpc_runtime().current_extension_interaction = nil
state.active_rpc_runtime().pending_extension_ui_request = nil

local function permission_request(id, command)
  return {
    type = 'extension_ui_request',
    id = id,
    method = 'select',
    title = "Permission Required\nPi requested bash command '" .. command .. "'. Allow this command?",
    options = { 'Yes', 'No' },
  }
end

ui.show_interaction({ title = 'Plugin overlay', items = { { label = 'stay' } } })
ext.handle_request(permission_request('queued-dup', 'echo one'))
ext.handle_request(permission_request('queued-dup', 'echo two'))
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Plugin overlay' and #(state.active_rpc_runtime().interaction_queue or {}) == 1
end), 'plugin overlay should remain visible and permission should queue')
local queue = state.active_rpc_runtime().interaction_queue or {}
assert(#queue == 1, vim.inspect(queue))
assert(queue[1].opts.request_id == 'queued-dup')
assert(queue[1].opts.message:find('echo one', 1, true), 'duplicate queued request must not replace queued interaction')
local output = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local permission_count = select(2, output:gsub('#### Permission request:', ''))
assert(permission_count == 1, output)
assert(output:find('echo one', 1, true), output)
assert(output:find('echo two', 1, true) == nil, output)
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
