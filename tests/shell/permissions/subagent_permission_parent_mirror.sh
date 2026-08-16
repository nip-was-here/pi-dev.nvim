#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat >"$script" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local renderer = require('pi-dev.renderer')
local extension_ui = require('pi-dev.extension_ui')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local sent = {}
rpc.write = function(message)
  table.insert(sent, message)
  return true
end
state.ensure_rpc_runtime('default').job_id = 123
state.rpc.job_id = 123
state.is_job_running = function(runtime)
  return runtime == nil or runtime.job_id ~= nil
end

ui.show()
renderer.clear('permission parent mirror')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-permission',
  toolName = 'subagent',
  args = { tasks = { { agent = 'reviewer', task = 'needs permission' }, { agent = 'scout', task = 'needs another permission' } } },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-permission',
  toolName = 'subagent',
  partialResult = {
    progress = {
      { index = 0, agent = 'reviewer', status = 'running', turnCount = 1, currentTool = 'read', currentPath = 'lua/pi-dev/old.lua' },
      { index = 1, agent = 'scout', status = 'running', turnCount = 1 },
    },
    results = {
      { agent = 'reviewer', status = 'running', task = 'needs permission' },
      { agent = 'scout', status = 'running', task = 'needs another permission' },
    },
  },
})

extension_ui.handle_request({
  type = 'extension_ui_request',
  id = 'perm-subagent-1',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'git status'. Allow this command?",
  options = { 'Yes', [[Yes, allow bash "git *" for this session]], 'No', 'No, provide reason' },
})
extension_ui.handle_request({
  type = 'extension_ui_request',
  id = 'perm-subagent-2',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'pwd'. Allow this command?",
  options = { 'Yes', [[Yes, allow bash "pwd" for this session]], 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'permission interaction should render')

local tree = table.concat(vim.api.nvim_buf_get_lines(state.ui.subagent_tree_buf, 0, -1, false), '\n')
assert(tree:find('reviewer - bash git status', 1, true), tree)
assert(tree:find('reviewer - read lua/pi-dev/old.lua', 1, true) == nil, tree)

local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local reviewer_pos = text:find('##### Agent 1/2: reviewer %- running')
local scout_pos = text:find('##### Agent 2/2: scout %- running')
local first_permission_pos = text:find('###### Permission request: bash `git *`', 1, true)
local second_permission_pos = text:find('###### Permission request: bash `pwd`', 1, true)
assert(reviewer_pos and scout_pos and first_permission_pos and second_permission_pos, text)
assert(text:find('##### Agent 1/2: reviewer - running\n\n###### Permission request: bash `git *`', 1, true), text)
assert(text:find('##### Agent 2/2: scout - running\n\n###### Permission request: bash `pwd`', 1, true), text)
assert(text:find('Permission request: bash `git status`', 1, true) == nil, text)
assert(text:find('```bash\ngit status\n```', 1, true), text)
assert(text:find('\n#### Permission request: bash `git *`', 1, true) == nil, text)
assert(text:find('\n#### Permission request: bash `pwd`', 1, true) == nil, text)
assert(text:find('perm%-subagent%-1') == nil, 'internal request ids should not leak into chat')
assert(state.statusline.waiting_input == true, 'root status should count subagent permission as waiting')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf, 'permission decision should be in lower pane')

vim.cmd('stopinsert')
vim.api.nvim_set_current_win(state.ui.input_win)
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), 'permission response should be sent')
assert(sent[1].type == 'extension_ui_response', vim.inspect(sent[1]))
assert(sent[1].id == 'perm-subagent-1', vim.inspect(sent[1]))
assert(sent[1].value == 'Yes', vim.inspect(sent[1]))

state.ui.subagent_view = {
  title = 'nested child',
  depth = 2,
  parent_view = { title = 'reviewer', depth = 1 },
}
renderer.append_permission_request('perm-nested', 'bash `nested`', { 'nested detail' })
state.ui.subagent_view = nil
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('##### reviewer\n\n###### nested child\n\n####### Permission request: bash `nested`', 1, true), text)

local ancestor_parent_buf = vim.api.nvim_create_buf(false, true)
local ancestor_child_buf = vim.api.nvim_create_buf(false, true)
local ancestor_parent_view = {
  title = 'reviewer',
  output_title = 'Pi chat subagent (deep 1): reviewer',
  depth = 1,
  buf = ancestor_parent_buf,
  base_lines = { '# Pi chat subagent (deep 1): reviewer', '', '## Main info', '**Agent:** reviewer' },
}
local ancestor_child_view = {
  parent_view = ancestor_parent_view,
  parent_title = ancestor_parent_view.output_title,
  title = 'nested child',
  output_title = 'Pi chat subagent (deep 2): nested child',
  depth = 2,
  buf = ancestor_child_buf,
  base_lines = { '# Pi chat subagent (deep 2): nested child', '', '## Main info', '**Agent:** nested child' },
}
state.ui.subagent_view = ancestor_child_view
renderer.append_permission_request('perm-subsub-up', 'bash `nested status`', { 'nested detail' })
local ancestor_child_text = table.concat(vim.api.nvim_buf_get_lines(ancestor_child_buf, 0, -1, false), '\n')
local ancestor_parent_text = table.concat(vim.api.nvim_buf_get_lines(ancestor_parent_buf, 0, -1, false), '\n')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(ancestor_child_text:find('## Permission request: bash `nested status`', 1, true), ancestor_child_text)
assert(ancestor_parent_text:find('## nested child\n\n### Permission request: bash `nested status`', 1, true), ancestor_parent_text)
assert(text:find('##### reviewer\n\n###### nested child\n\n####### Permission request: bash `nested status`', 1, true), text)
ui.close_all_subagent_views({ title = 'permission parent mirror' })

ui.close_interaction({ process_queue = false })
local runtime = state.active_rpc_runtime()
runtime.interaction_queue = {}
runtime.current_extension_interaction = nil
runtime.pending_extension_ui_request = nil
renderer.clear('visible subagent permission')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-visible-permission',
  toolName = 'subagent',
  args = { tasks = { { agent = 'reviewer', task = 'needs visible permission' } } },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-visible-permission',
  toolName = 'subagent',
  partialResult = {
    progress = { { index = 0, agent = 'reviewer', status = 'running', turnCount = 1 } },
    results = { { agent = 'reviewer', status = 'running', task = 'needs visible permission' } },
  },
})
renderer.flush_pending_tool_renders()
local parent_lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local child_header
for index, line in ipairs(parent_lines) do
  if line:find('##### reviewer %- running') or line:find('##### Agent 1/1: reviewer %- running') then
    child_header = index
    break
  end
end
assert(child_header, table.concat(parent_lines, '\n'))
vim.api.nvim_win_set_cursor(state.ui.output_win, { child_header, 0 })
assert(ui.open_subagent_at_cursor(), 'subagent chat should open from parent child row')
assert(state.ui.subagent_view and vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.subagent_view.buf, 'subagent chat should be visible')
extension_ui.handle_request({
  type = 'extension_ui_request',
  id = 'perm-visible-subagent',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'git status'. Allow this command?",
  options = { 'Yes', [[Yes, allow bash "git *" for this session]], 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'visible subagent permission interaction should render')
local visible = table.concat(vim.api.nvim_buf_get_lines(state.ui.subagent_view.buf, 0, -1, false), '\n')
assert(visible:find('## Permission request: bash `git *`', 1, true), visible)
assert(visible:find('Permission request: bash `git status`', 1, true) == nil, visible)
assert(visible:find('```bash\ngit status\n```', 1, true), visible)
assert(visible:find('Pi requested bash command', 1, true), visible)
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-visible-permission',
  toolName = 'subagent',
  partialResult = {
    progress = { { index = 0, agent = 'reviewer', status = 'running', turnCount = 2 } },
    results = { { agent = 'reviewer', status = 'running', task = 'needs visible permission' } },
  },
})
renderer.flush_pending_tool_renders()
visible = table.concat(vim.api.nvim_buf_get_lines(state.ui.subagent_view.buf, 0, -1, false), '\n')
assert(visible:find('## Permission request: bash `git *`', 1, true), visible)
LUA

pidev_run_lua_file "$script"
