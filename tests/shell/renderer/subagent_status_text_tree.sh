#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat >"$script" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 100, input_height = 8 } })
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

local status_text = table.concat({
  'Run: example-run',
  'State: running',
  'Activity: active now',
  'Mode: chain',
  'Progress: step 1/1 - parallel group: 2 agents running - 1/3 done',
  'Started: 2026-01-01T00:00:00.000Z',
  'Updated: 2026-01-01T00:00:01.000Z',
  'Dir: ./tmp/pi-dev-test/async-subagent-runs/example-run',
  'Output: ./tmp/pi-dev-test/async-subagent-runs/example-run/output-2.log',
  'Step 1/1 Agent 1/3: context-builder complete (example-model, thinking medium), acceptance: rejected',
  '  Output: ./tmp/pi-dev-test/async-subagent-runs/example-run/output-0.log',
  'Step 1/1 Agent 2/3: reviewer running (example-model, thinking medium), active now',
  '  Output: ./tmp/pi-dev-test/async-subagent-runs/example-run/output-1.log',
  '  Intercom target: subagent-reviewer-example-run-2 (if registered)',
  'Step 1/1 Agent 3/3: scout running (example-model, thinking medium), active now',
  'Events: ./tmp/pi-dev-test/async-subagent-runs/example-run/events.jsonl',
}, '\n')

ui.show()
renderer.clear('subagent status text')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-status-text',
  toolName = 'subagent',
  args = { action = 'status', id = 'example-run' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'subagent-status-text',
  toolName = 'subagent',
  result = {
    content = { { type = 'text', text = status_text } },
    details = { mode = 'single', results = {} },
  },
})
renderer.flush_pending_tool_renders()

local parent = buf_text(state.ui.output_buf)
assert(parent:find('### Tool: subagent status', 1, true), parent)
assert(parent:find('**Run:** example-run', 1, true), parent)
assert(parent:find('**Progress:** step 1/1', 1, true), parent)
assert(parent:find('##### Agent 1/3: context-builder - complete', 1, true), parent)
assert(parent:find('##### Agent 2/3: reviewer - running', 1, true), parent)
assert(parent:find('##### Agent 3/3: scout - running', 1, true), parent)
assert(parent:find('**Details:** Step 1/1 Agent 2/3: reviewer running', 1, true), parent)
assert(parent:find('Output: `empty`', 1, true) == nil, parent)

assert(valid_win(state.ui.subagent_tree_win), 'running parsed subagents should open the subagent tree')
local tree = buf_text(state.ui.subagent_tree_buf)
assert(tree:find('root%-agent %- ', 1, false), tree)
assert(tree:find('reviewer %- ', 1, false), tree)
assert(tree:find('scout - running', 1, true), tree)
assert(tree:find('context-builder', 1, true) == nil, tree)

local reviewer_row = line_with(state.ui.subagent_tree_buf, 'reviewer - ')
assert(reviewer_row, tree)
vim.api.nvim_set_current_win(state.ui.subagent_tree_win)
vim.api.nvim_win_set_cursor(state.ui.subagent_tree_win, { reviewer_row, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.subagent_view ~= nil and vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.subagent_view.buf
end), 'Return on parsed subagent tree row should open that subagent chat')
local child = buf_text(state.ui.subagent_view.buf)
assert(child:find('# Pi chat subagent %(deep 1%): reviewer'), child)
assert(child:find('**Status:** running', 1, true), child)
assert(child:find('Intercom target: subagent-reviewer-example-run-2', 1, true), child)
LUA

pidev_run_lua_file "$script"
