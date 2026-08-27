#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat >"$script" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 100, input_height = 8, agent_tree = { max_height = 6 } } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

ui.show()
renderer.render_messages({
  {
    role = 'assistant',
    content = {
      {
        type = 'toolCall',
        id = 'old-subagent',
        name = 'subagent',
        args = { agent = 'reviewer', task = 'review old state' },
      },
    },
  },
  {
    role = 'toolResult',
    toolCallId = 'old-subagent',
    toolName = 'subagent',
    result = {
      details = {
        results = {
          { agent = 'reviewer', status = 'completed', task = 'review old state', output = 'old done' },
        },
      },
    },
  },
}, 'restored parent with old subagent')

assert(not valid_win(state.ui.subagent_tree_win), 'completed restored subagent must not appear in Pi agents')

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'old-subagent',
  toolName = 'subagent',
  args = {
    action = 'resume',
    id = 'old-subagent-run',
    agent = 'reviewer',
    task = 'continue the old child after editor restart',
  },
})
renderer.flush_pending_tool_renders()

assert(valid_win(state.ui.subagent_tree_win), 'resumed subagent should appear in Pi agents while it is active')
local running_tree = buf_text(state.ui.subagent_tree_buf)
assert(running_tree:find('old%-subagent%-run', 1, false), running_tree)
assert(running_tree:find('resume', 1, true), running_tree)
assert(running_tree:find('reviewer', 1, true), running_tree)
assert(running_tree:find('old done', 1, true) == nil, running_tree)
local running_parent = buf_text(state.ui.output_buf)
assert(running_parent:find('**Resume:** old-subagent-run', 1, true), running_parent)

renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'old-subagent',
  toolName = 'subagent',
  result = {
    details = {
      results = {
        { agent = 'reviewer', status = 'completed', task = 'continue the old child after editor restart', output = 'resumed done' },
      },
    },
  },
})
renderer.flush_pending_tool_renders()

assert(not valid_win(state.ui.subagent_tree_win), 'completed resumed subagent must be pruned from Pi agents')
local final_parent = buf_text(state.ui.output_buf)
assert(final_parent:find('##### reviewer - completed', 1, true), final_parent)

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'old-subagent',
  toolName = 'subagent',
  args = {
    action = 'resume',
    id = 'second-old-subagent-run',
    agent = 'reviewer',
    task = 'continue the same child again',
  },
})
renderer.flush_pending_tool_renders()

assert(valid_win(state.ui.subagent_tree_win), 'restarting a finished resume with the same tool id should reactivate Pi agents')
local restarted_tree = buf_text(state.ui.subagent_tree_buf)
assert(restarted_tree:find('second%-old%-subagent%-run', 1, false), restarted_tree)
assert(restarted_tree:find('  old-subagent-run', 1, true) == nil, restarted_tree)

renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'old-subagent',
  toolName = 'subagent',
  result = {
    details = {
      results = {
        { agent = 'reviewer', status = 'completed', task = 'continue the same child again' },
      },
    },
  },
})
renderer.flush_pending_tool_renders()

assert(not valid_win(state.ui.subagent_tree_win), 'restarted completed resume must be pruned from Pi agents')
LUA

pidev_run_lua_file "$script"
