#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat >"$script" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 90, input_height = 8 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

local function line_with(bufnr, needle)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return index
    end
  end
end

local function feed_return()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
end

local function subagent_payload()
  return {
    details = {
      results = {
        {
          agent = 'scout',
          status = 'running',
          task = 'map renderer state',
          progress = {
            index = 0,
            agent = 'scout',
            status = 'running',
            task = 'map renderer state',
            currentTool = 'read',
            currentPath = 'lua/pi-dev/renderer.lua',
            toolCount = 1,
          },
        },
        {
          agent = 'reviewer',
          status = 'completed',
          task = 'review tree panel',
          output = 'review complete',
        },
      },
    },
  }
end

ui.show()
renderer.clear('subagent tree parent')
assert(not valid_win(state.ui.subagent_tree_win), 'agent tree must stay hidden when no subagents exist')

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-tree',
  toolName = 'subagent',
  args = { tasks = { { agent = 'scout' }, { agent = 'reviewer' } } },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-tree',
  toolName = 'subagent',
  partialResult = subagent_payload(),
})
renderer.flush_pending_tool_renders()
assert(valid_win(state.ui.subagent_tree_win), 'agent tree should appear when subagents exist')
assert(vim.api.nvim_win_get_height(state.ui.subagent_tree_win) <= 8, 'agent tree height must be capped at 8 rows')
assert(vim.api.nvim_win_get_buf(state.ui.subagent_tree_win) == state.ui.subagent_tree_buf, 'agent tree window should show agent tree buffer')
local tree = buf_text(state.ui.subagent_tree_buf)
assert(tree:find('root%-agent %- ', 1, false), tree)
assert(tree:find('scout %- read lua/pi%-dev/renderer%.lua', 1, false), tree)
assert(tree:find('reviewer - review tree panel', 1, true), tree)

local scout_row = line_with(state.ui.subagent_tree_buf, 'scout - read lua/pi-dev/renderer.lua')
assert(scout_row, tree)
vim.api.nvim_set_current_win(state.ui.subagent_tree_win)
vim.api.nvim_win_set_cursor(state.ui.subagent_tree_win, { scout_row, 0 })
feed_return()
assert(vim.wait(1000, function()
  return state.ui.subagent_view ~= nil and vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.subagent_view.buf
end), 'Return on a subagent tree row should switch the chat to that subagent')
assert(vim.bo[state.ui.input_buf].modifiable == false, 'input should be locked while a subagent chat is focused')
local child = buf_text(state.ui.subagent_view.buf)
assert(child:find('# Pi chat subagent %(deep 1%): scout'), child)

local root_row = line_with(state.ui.subagent_tree_buf, 'root-agent - ')
assert(root_row, buf_text(state.ui.subagent_tree_buf))
vim.api.nvim_set_current_win(state.ui.subagent_tree_win)
vim.api.nvim_win_set_cursor(state.ui.subagent_tree_win, { root_row, 0 })
feed_return()
assert(vim.wait(1000, function()
  return state.ui.subagent_view == nil and vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.output_buf
end), 'Return on root-agent should restore the root chat')
assert(vim.bo[state.ui.input_buf].modifiable == true, 'input should unlock after returning to the root chat')
assert(valid_win(state.ui.subagent_tree_win), 'agent tree should remain visible while subagents still exist')

ui.show_interaction({
  title = 'Pi tree',
  kind = 'tree',
  surface = 'output',
  items = { { label = 'session row' } },
})
assert(not valid_win(state.ui.subagent_tree_win), 'session/tree navigation should replace the agent tree')
assert(vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.tree_buf, 'session/tree navigation should replace the chat surface')
ui.close_interaction({ process_queue = false })
assert(valid_win(state.ui.subagent_tree_win), 'agent tree should reappear after closing a temporary tree view while subagents remain')

renderer.clear('after session switch')
assert(not valid_win(state.ui.subagent_tree_win), 'new session renders should clear stale agent trees')
assert(state.ui.subagent_view == nil, 'new session renders should clear focused subagent chats')
LUA

pidev_run_lua_file "$script"
