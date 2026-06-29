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

local function child_messages(final)
  local messages = {
    { role = 'user', content = 'inspect example project state' },
    {
      role = 'assistant',
      content = {
        { type = 'text', text = 'I will inspect the synthetic project file.' },
        { type = 'toolCall', id = 'child-read', name = 'read', args = { path = './tmp/pi-dev-test/example-project/state.md' } },
      },
    },
    {
      role = 'toolResult',
      toolCallId = 'child-read',
      content = 'example tool result body',
    },
  }
  if final then
    table.insert(messages, { role = 'assistant', content = 'completed child body' })
  end
  return messages
end

local function payload(status, output)
  local done = status == 'completed'
  return {
    details = {
      results = {
        {
          agent = 'scout',
          status = status,
          task = 'watch live child',
          output = output,
          messages = child_messages(done),
          progress = {
            index = 0,
            agent = 'scout',
            status = status,
            task = 'watch live child',
            turnCount = 1,
            toolCount = 1,
            tokens = 5,
            currentTool = done and nil or 'bash',
            currentToolArgs = done and nil or 'echo running synthetic command',
            recentTools = {
              { tool = 'read', args = './tmp/pi-dev-test/example-project/state.md', endMs = 1000 },
            },
            recentOutput = { 'first running body' },
          },
        },
      },
    },
  }
end

local function progress_only_payload()
  return {
    details = {
      results = {
        {
          agent = 'planner',
          status = 'running',
          task = 'track synthetic progress only',
          progress = {
            index = 0,
            agent = 'planner',
            status = 'running',
            task = 'track synthetic progress only',
            turnCount = 2,
            toolCount = 3,
            tokens = 42,
            currentTool = 'bash',
            currentToolArgs = 'echo synthetic running command',
            recentTools = {
              { tool = 'read', args = './tmp/pi-dev-test/example-project/notes.md', endMs = 1000 },
              { tool = 'edit', args = './tmp/pi-dev-test/example-project/notes.md', endMs = 2000 },
            },
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
local parent_during = buf_text(state.ui.output_buf)
assert(parent_during:find('**Task:** watch live child', 1, true), parent_during)
assert(parent_during:find('first running body', 1, true) == nil, parent_during)
assert(parent_during:find('I will inspect the synthetic project file.', 1, true) == nil, parent_during)
assert(parent_during:find('example tool result body', 1, true) == nil, parent_during)

local child_before = buf_text(state.ui.subagent_view.buf)
assert(child_before:find('## User', 1, true), child_before)
assert(child_before:find('inspect example project state', 1, true), child_before)
assert(child_before:find('## Assistant', 1, true), child_before)
assert(child_before:find('I will inspect the synthetic project file.', 1, true), child_before)
assert(child_before:find('### Tool: read', 1, true), child_before)
assert(child_before:find('./tmp/pi-dev-test/example-project/state.md', 1, true), child_before)
assert(child_before:find('example tool result body', 1, true), child_before)
assert(child_before:find('### Tool: bash', 1, true), child_before)
assert(child_before:find('echo running synthetic command', 1, true), child_before)
assert(child_before:find('first running body', 1, true), child_before)
assert(child_before:find('Sub%-agent result will be shown after this agent completes') == nil, child_before)
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

vim.cmd('PiDevSubagentParent')
renderer.clear('subagent progress only')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-progress-only',
  toolName = 'subagent',
  args = { agent = 'planner', task = 'track synthetic progress only' },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-progress-only',
  toolName = 'subagent',
  partialResult = progress_only_payload(),
})
renderer.flush_pending_tool_renders()

local progress_child_line = line_with('**Task:** track synthetic progress only')
assert(progress_child_line, buf_text(state.ui.output_buf))
vim.api.nvim_set_current_win(state.ui.output_win)
vim.api.nvim_win_set_cursor(state.ui.output_win, { progress_child_line, 0 })
vim.cmd('PiDevSubagentOpen')
local progress_child = buf_text(state.ui.subagent_view.buf)
assert(progress_child:find('### Tool: read', 1, true), progress_child)
assert(progress_child:find('./tmp/pi-dev-test/example-project/notes.md', 1, true), progress_child)
assert(progress_child:find('### Tool: edit', 1, true), progress_child)
assert(progress_child:find('### Tool: bash', 1, true), progress_child)
assert(progress_child:find('echo synthetic running command', 1, true), progress_child)
assert(progress_child:find('Sub%-agent result will be shown after this agent completes') == nil, progress_child)
LUA

pidev_run_lua_file "$script"
