#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 90, input_height = 10 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local observed_defer_delay
local original_defer_fn = vim.defer_fn
vim.defer_fn = function(callback, delay)
  observed_defer_delay = delay
  return original_defer_fn(callback, delay)
end

ui.show()
renderer.clear('subagent live progress')

local function text()
  renderer.flush_pending_tool_renders()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
end

local function line_number(needle, occurrence)
  occurrence = occurrence or 1
  local seen = 0
  local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
  for index, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      seen = seen + 1
      if seen == occurrence then
        return index
      end
    end
  end
end

local function line_count(needle)
  local count = 0
  local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      count = count + 1
    end
  end
  return count
end

local function foldclosed(line)
  local value
  vim.api.nvim_win_call(state.ui.output_win, function()
    value = vim.fn.foldclosed(line)
  end)
  return value
end

local function foldlevel(line)
  local value
  vim.api.nvim_win_call(state.ui.output_win, function()
    value = vim.fn.foldlevel(line)
  end)
  return value
end

local function progress_payload(scout_extra)
  return {
    content = { { type = 'text', text = '(running...)' } },
    details = {
      mode = 'parallel',
      context = 'fresh',
      results = {
        {
          agent = 'scout',
          task = 'Map renderer paths',
          exitCode = -1,
          usage = { input = 0, output = 0, totalTokens = 0, cost = { total = 0 } },
          progress = {
            index = 0,
            agent = 'scout',
            status = 'running',
            task = 'Map renderer paths',
            currentTool = 'read',
            currentPath = 'lua/pi-dev/renderer/tools.lua',
            recentTools = { { tool = 'rg', args = 'subagent renderer with a long query that should stay readable across most of the panel width instead of truncating early', durationMs = 1000 } },
            recentOutput = { '# Scout heading', 'found current renderer seam', scout_extra or 'first update' },
            toolCount = 2,
            turnCount = 1,
            tokens = 123,
            durationMs = 1500,
          },
        },
        {
          agent = 'reviewer',
          task = 'Review folds',
          exitCode = 0,
          finalOutput = 'Reviewer final output\n## Nested heading from child',
          usage = { input = 0, output = 0, totalTokens = 0, cost = { total = 0 } },
          progress = {
            index = 1,
            agent = 'reviewer',
            status = 'completed',
            task = 'Review folds',
            recentTools = {},
            recentOutput = {},
            toolCount = 1,
            tokens = 55,
            durationMs = 900,
          },
        },
      },
      progress = {
        {
          index = 0,
          agent = 'scout',
          status = 'running',
          task = 'Map renderer paths',
          currentTool = 'read',
          currentPath = 'lua/pi-dev/renderer/tools.lua',
          recentTools = {},
          recentOutput = { 'progress array fallback' },
          toolCount = 2,
          tokens = 123,
          durationMs = 1500,
        },
      },
    },
  }
end

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-live',
  toolName = 'subagent',
  args = { context = 'fresh', tasks = { { agent = 'scout' }, { agent = 'reviewer' } } },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-live',
  toolName = 'subagent',
  partialResult = progress_payload('first update'),
})

local rendered = text()
assert(rendered:find('### Tool: subagent parallel tasks', 1, true), rendered)
assert(rendered:find('#### Request', 1, true), rendered)
assert(rendered:find('#### Result', 1, true), rendered)
assert(rendered:find('##### Agent 1/2: scout - running', 1, true), rendered)
assert(rendered:find('##### Agent 2/2: reviewer - completed', 1, true), rendered)
assert(observed_defer_delay == 1000, 'subagent live updates should be throttled to one second, got ' .. tostring(observed_defer_delay))
assert(rendered:find('###### Main info', 1, true), rendered)
assert(rendered:find('**Current tool:** `read` `lua/pi-dev/renderer/tools.lua`', 1, true), rendered)
assert(rendered:find('1. rg %- subagent renderer with a long query', 1, false), rendered)
assert(rendered:find('%(1s%)', 1, false), rendered)
assert(rendered:find('Sub-agent result will be shown after this agent completes.', 1, true) == nil, rendered)
assert(rendered:find('Reviewer final output', 1, true) == nil, rendered)
assert(rendered:find('###### Nested heading from child', 1, true) == nil, rendered)
assert(rendered:find('###### Details', 1, true) == nil, rendered)
assert(rendered:find('Details are lazy-rendered', 1, true) == nil, rendered)
assert(rendered:find('found current renderer seam', 1, true) == nil, rendered)
assert(rendered:find('###### Scout heading', 1, true) == nil, rendered)
assert(rendered:find('#######', 1, true) == nil, rendered)
assert(rendered:find('#### Output', 1, true) == nil, rendered)
assert(rendered:find('(running...)', 1, true) == nil, rendered)

local tool_header = line_number('### Tool: subagent parallel tasks')
assert(tool_header, rendered)
assert(foldlevel(tool_header + 1) == 0, 'running subagent tool body should not get an outer auto-fold')
local scout_header = line_number('##### Agent 1/2: scout - running')
assert(scout_header, rendered)
assert(foldclosed(scout_header) == -1, 'child subagent heading should stay visible')
assert(foldclosed(scout_header + 1) == -1, 'Main info should stay visible below the child subagent heading')
local tool_line = line_number('1. rg - subagent renderer with a long query')
assert(tool_line and foldlevel(tool_line) == 0, 'Main info Tools list should not be covered by stale detail folds')
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-live',
  toolName = 'subagent',
  partialResult = progress_payload('second update persists'),
})
rendered = text()
assert(rendered:find('second update persists', 1, true) == nil, rendered)
assert(rendered:find('(running...)', 1, true) == nil, rendered)
scout_header = line_number('##### Agent 1/2: scout - running')
assert(scout_header, rendered)
assert(foldclosed(scout_header + 1) == -1, 'Main info should remain visible after live update')
assert(line_count('###### Details') == 0, rendered)
assert(rendered:find('Sub-agent result will be shown after this agent completes.', 1, true) == nil, rendered)
tool_line = line_number('1. rg - subagent renderer with a long query')
assert(tool_line and foldlevel(tool_line) == 0, 'Main info Tools list should stay outside stale detail folds after update')

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-raw-running',
  toolName = 'subagent',
  args = { agent = 'raw' },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-raw-running',
  toolName = 'subagent',
  partialResult = { content = { { type = 'text', text = 'raw partial answer before completion' } } },
})
rendered = text()
assert(rendered:find('raw partial answer before completion', 1, true) == nil, rendered)
assert(rendered:find('Sub-agent result will be shown after this agent completes.', 1, true) == nil, rendered)
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-string-running',
  toolName = 'subagent',
  args = { agent = 'raw' },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-string-running',
  toolName = 'subagent',
  partialResult = { results = { 'raw string array partial before completion' } },
})
rendered = text()
assert(rendered:find('raw string array partial before completion', 1, true) == nil, rendered)
assert(rendered:find('Sub-agent result will be shown after this agent completes.', 1, true) == nil, rendered)

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-complete',
  toolName = 'subagent',
  args = { context = 'fresh', tasks = { { agent = 'scout' } } },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'subagent-complete',
  toolName = 'subagent',
  result = progress_payload('final hidden until opened'),
})
rendered = text()
assert(rendered:find('final hidden until opened', 1, true) == nil, rendered)
assert(rendered:find('Details are lazy%-rendered', 1, false) == nil, rendered)
assert(rendered:find('###### Details', 1, true) == nil, rendered)
assert(rendered:find('###### Recent output', 1, true) == nil, rendered)
assert(rendered:find('#######', 1, true) == nil, rendered)
vim.defer_fn = original_defer_fn
LUA

pidev_run_lua_file "$tmp_lua"
