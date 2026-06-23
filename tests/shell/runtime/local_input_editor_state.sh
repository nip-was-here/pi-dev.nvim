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

local next_job = 100
vim.fn.jobstart = function()
  next_job = next_job + 1
  return next_job
end
vim.fn.jobwait = function()
  return { -1 }
end
require('pi-dev.rpc').write = function()
  return true
end

ui.show()
rpc.use_runtime('branch-a', { branch_entry_id = 'a' })
ui.set_input_text('draft a')
vim.api.nvim_buf_set_lines(state.ui.input_buf, 0, -1, false, { 'typed draft a' })

rpc.use_runtime('branch-b', { branch_entry_id = 'b' })
assert(ui.get_input_text() == '', 'new branch should start with its own empty Pi input draft')
ui.set_input_text('draft b')

rpc.use_runtime('branch-a')
assert(ui.get_input_text() == 'typed draft a', ui.get_input_text())

rpc.use_runtime('branch-b')
assert(ui.get_input_text() == 'draft b', ui.get_input_text())
ui.set_input_text('branch b prompt')
ui.show_interaction({ title = 'Overlay select', items = { { label = 'ok' } } })
ext.handle_request({ type = 'extension_ui_request', method = 'set_editor_text', text = 'branch b editor text' })
assert(ui.get_input_text() == 'branch b prompt', 'set_editor_text must not overwrite hidden branch input behind overlay')
assert(state.active_rpc_runtime().editor_text == 'branch b editor text')
ui.close_interaction()

rpc.use_runtime('branch-a')
assert(ui.get_input_text() == 'typed draft a', ui.get_input_text())
assert((state.active_rpc_runtime().editor_text or '') == '', 'editor text should be runtime-local')

rpc.use_runtime('branch-b')
assert(ui.get_input_text() == 'branch b prompt', ui.get_input_text())
assert(state.active_rpc_runtime().editor_text == 'branch b editor text')
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
