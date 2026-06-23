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

local next_job = 300
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

ui.show()
rpc.use_runtime('editor-branch', { branch_entry_id = 'editor' })
ext.handle_request({
  type = 'extension_ui_request',
  id = 'editor-draft',
  method = 'editor',
  title = 'Branch editor',
  text = 'original line',
})
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.kind == 'editor'
end), 'editor interaction did not open')
local interaction = state.ui.interaction
vim.api.nvim_buf_set_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false, { 'edited before switch', 'second line' })

rpc.use_runtime('other-branch', { branch_entry_id = 'other' })
assert(state.rpc.active_key == 'other-branch')
local editor_runtime = state.ensure_rpc_runtime('editor-branch')
assert(editor_runtime.editor_text == 'edited before switch\nsecond line', editor_runtime.editor_text or 'nil')
assert(editor_runtime.current_extension_interaction and editor_runtime.current_extension_interaction.opts.request_id == 'editor-draft')

rpc.use_runtime('editor-branch')
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.kind == 'editor'
end), 'editor interaction should restore after switching back')
interaction = state.ui.interaction
local restored = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false), '\n')
assert(restored == 'edited before switch\nsecond line', restored)
vim.api.nvim_set_current_win(state.ui.input_win)
vim.cmd('stopinsert')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-s>', true, false, true), 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), 'editor submit missing')
assert(sent[1].id == 'editor-draft' and sent[1].value == 'edited before switch\nsecond line', vim.inspect(sent[1]))
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
