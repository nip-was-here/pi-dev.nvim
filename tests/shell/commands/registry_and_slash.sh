#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local plugin = require('pi-dev').setup({ keymaps = { prefix = '<leader>a' } })

local commands = {
  'PiDev',
  'PiDevOpen',
  'PiDevHide',
  'PiDevPrompt',
  'PiDevFocus',
  'PiDevAbort',
  'PiDevNextRpc',
  'PiDevPrevRpc',
  'PiDevNewSession',
  'PiDevResume',
  'PiDevModel',
  'PiDevReload',
  'PiDevTree',
  'PiDevWaiting',
}
for _, command in ipairs(commands) do
  assert(vim.fn.exists(':' .. command) == 2, command .. ' command should exist')
end

local originals = {}
for key, value in pairs(plugin.api) do
  originals[key] = value
end
local hit = {}
plugin.api.toggle = function() hit.toggle = true end
plugin.api.start = function() hit.start = true end
plugin.api.hide = function() hit.hide = true end
plugin.api.prompt = function(message) hit.prompt = message end
plugin.api.focus_input = function() hit.focus = true end
plugin.api.abort = function() hit.abort = true end
plugin.api.next_rpc = function() hit.next_rpc = true end
plugin.api.previous_rpc = function() hit.previous_rpc = true end
plugin.api.new_session = function() hit.new = true end
plugin.api.resume = function() hit.resume = true end
plugin.api.model_picker = function() hit.model = true end
plugin.api.reload = function() hit.reload = true end
plugin.api.tree = function() hit.tree = true end
plugin.api.waiting = function() hit.waiting = true end

vim.cmd('PiDev')
vim.cmd('PiDevOpen')
vim.cmd('PiDevHide')
vim.cmd('PiDevPrompt hello from command')
vim.cmd('PiDevFocus')
vim.cmd('PiDevAbort')
vim.cmd('PiDevNextRpc')
vim.cmd('PiDevPrevRpc')
vim.cmd('PiDevNewSession')
vim.cmd('PiDevResume')
vim.cmd('PiDevModel')
vim.cmd('PiDevReload')
vim.cmd('PiDevTree')
vim.cmd('PiDevWaiting')
assert(hit.toggle and hit.start and hit.hide and hit.prompt == 'hello from command')
assert(hit.focus and hit.abort and hit.next_rpc and hit.previous_rpc and hit.new and hit.resume and hit.model and hit.reload and hit.tree and hit.waiting)
for key, value in pairs(originals) do
  plugin.api[key] = value
end

local api = require('pi-dev.api')
local original_new_session = api.new_session
local original_waiting = api.waiting
local original_next_rpc = api.next_rpc
local original_previous_rpc = api.previous_rpc
local slash_new = false
local slash_waiting = false
local slash_next_rpc = false
local slash_previous_rpc = false
api.new_session = function()
  slash_new = true
end
api.waiting = function()
  slash_waiting = true
end
api.next_rpc = function()
  slash_next_rpc = true
end
api.previous_rpc = function()
  slash_previous_rpc = true
end
assert(api.handle_slash_command('/new') and slash_new, '/new slash command should dispatch')
assert(api.handle_slash_command('/waiting') and slash_waiting, '/waiting slash command should dispatch')
assert(api.handle_slash_command('/next-rpc') and slash_next_rpc, '/next-rpc slash command should dispatch')
slash_next_rpc = false
assert(api.handle_slash_command('/cycle-rpc') and slash_next_rpc, '/cycle-rpc slash command should dispatch')
assert(api.handle_slash_command('/prev-rpc') and slash_previous_rpc, '/prev-rpc slash command should dispatch')
slash_previous_rpc = false
assert(api.handle_slash_command('/previous-rpc') and slash_previous_rpc, '/previous-rpc slash command should dispatch')
api.new_session = original_new_session
api.waiting = original_waiting
api.next_rpc = original_next_rpc
api.previous_rpc = original_previous_rpc
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
