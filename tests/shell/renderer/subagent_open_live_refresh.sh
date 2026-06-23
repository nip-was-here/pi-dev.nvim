#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat >"$script" <<'LUA'
require('pi-dev').setup({ keymaps = { prefix = '<leader>a' } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()
renderer.clear('subagent live refresh')

local function payload(status, output)
  return {
    details = {
      results = {
        {
          agent = 'scout',
          status = status,
          task = 'watch live child',
          output = output,
          progress = {
            index = 0,
            agent = 'scout',
            status = status,
            task = 'watch live child',
            turnCount = 1,
            toolCount = 0,
            tokens = 5,
          },
        },
      },
    },
  }
end

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

local function line_with(needle)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return index
    end
  end
end

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-live-refresh',
  toolName = 'subagent',
  args = { tasks = { { agent = 'scout', task = 'watch live child' } } },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-live-refresh',
  toolName = 'subagent',
  partialResult = payload('running', 'first running body'),
})
renderer.flush_pending_tool_renders()

local child_line = line_with('**Task:** watch live child')
assert(child_line, buf_text(state.ui.output_buf))
vim.api.nvim_set_current_win(state.ui.output_win)
vim.api.nvim_win_set_cursor(state.ui.output_win, { child_line, 0 })
vim.cmd('PiDevSubagentOpen')
assert(state.ui.subagent_view, 'subagent view should open while child is running')
local child_before = buf_text(state.ui.subagent_view.buf)
assert(child_before:find('Sub%-agent result will be shown after this agent completes'), child_before)
assert(child_before:find('completed child body', 1, true) == nil, child_before)

renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'subagent-live-refresh',
  toolName = 'subagent',
  result = payload('completed', 'completed child body'),
})
renderer.flush_pending_tool_renders()

local child_after = buf_text(state.ui.subagent_view.buf)
assert(child_after:find('completed child body', 1, true), child_after)
assert(child_after:find('Sub%-agent result will be shown after this agent completes') == nil, child_after)
assert(vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.subagent_view.buf, 'live refresh should keep the child buffer visible')
assert(vim.bo[state.ui.input_buf].modifiable == false, 'input stays locked in refreshed subagent view')
LUA

pidev_run_lua_file "$script"
