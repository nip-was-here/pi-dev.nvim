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

local sent = {}
require('pi-dev.rpc').write = function(message)
  table.insert(sent, message)
  return true
end

local function permission_request(id)
  return {
    type = 'extension_ui_request',
    id = id,
    method = 'select',
    title = "Permission Required\nPi requested bash command 'git status'. Allow this command?",
    options = { 'Yes', 'No' },
  }
end

ui.show_interaction({
  title = 'Pi tree',
  filetype = 'text',
  markdown = false,
  items = { { label = '* tree row', value = 'tree row' } },
  on_submit = function(item)
    state._test_tree_selected = item and item.value
  end,
})
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Pi tree' end), 'tree interaction should open')
ext.handle_request(permission_request('perm-tree'))
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Pi tree' and #(state.active_rpc_runtime().interaction_queue or {}) == 1
end), 'permission should queue behind active tree interaction')
assert(#sent == 0, 'queued permission must not respond before it is shown')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return state._test_tree_selected == 'tree row' end), 'tree selection should still submit')
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Permission Required' and state.ui.interaction.kind == 'permission'
end), 'queued permission should show after tree closes')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), 'permission response missing after queued prompt is selected')
assert(sent[1].id == 'perm-tree' and sent[1].value == 'Yes', vim.inspect(sent[1]))

ext.handle_request({
  type = 'extension_ui_request',
  id = 'generic-select',
  method = 'select',
  title = 'Waiting selection',
  options = { 'alpha', 'beta' },
})
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Waiting selection' end), 'generic waiting selection should open')
ext.handle_request(permission_request('perm-waiting'))
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Waiting selection' and #(state.active_rpc_runtime().interaction_queue or {}) == 1
end), 'permission should queue behind active waiting selection')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[2] and sent[2].id == 'generic-select' end), 'waiting selection response missing')
assert(sent[2].value == 'alpha', vim.inspect(sent[2]))
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Permission Required' and state.ui.interaction.kind == 'permission'
end), 'queued permission should show after waiting selection resolves')
vim.api.nvim_feedkeys('2', 'xt', false)
assert(vim.wait(1000, function() return sent[3] ~= nil end), 'second queued permission response missing')
assert(sent[3].id == 'perm-waiting' and sent[3].value == 'No', vim.inspect(sent[3]))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
