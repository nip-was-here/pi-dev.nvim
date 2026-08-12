#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
vim.o.columns = 220
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 160, input_height = 10 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()
renderer.clear('subagent live tool timing')
local seconds, microseconds = vim.uv.gettimeofday()
local base_ms = math.floor(seconds * 1000 + microseconds / 1000)

local function payload(progress)
  return {
    details = {
      results = {
        {
          agent = 'worker',
          task = 'Implement live timings',
          toolCalls = progress.toolCalls,
          children = progress.children,
          progress = progress,
        },
      },
    },
  }
end

local function progress(fields)
  return vim.tbl_extend('force', {
    index = 0,
    agent = 'worker',
    status = 'running',
    task = 'Implement live timings',
    recentTools = {},
    recentOutput = {},
    toolCount = 1,
    tokens = 10,
    durationMs = 1000,
  }, fields)
end

local function text(bufnr)
  renderer.flush_pending_tool_renders()
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-live-timing',
  toolName = 'subagent',
  args = { tasks = { { agent = 'worker' } } },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-live-timing',
  toolName = 'subagent',
  partialResult = payload(progress({
    currentTool = 'read',
    currentToolArgs = 'lua/pi-dev/compat/subagent.lua',
    currentPath = 'lua/pi-dev/compat/subagent.lua',
    currentToolStartedAt = base_ms - 1000,
  })),
  timestamp = base_ms,
})

local parent = text(state.ui.output_buf)
assert(parent:find('**Current tool:** `read` `lua/pi-dev/compat/subagent.lua` (1s)', 1, true), parent)
local tree = text(state.ui.subagent_tree_buf)
assert(tree:find('worker - read lua/pi-dev/compat/subagent.lua (1s)', 1, true), tree)
assert(vim.wait(1400, function()
  parent = text(state.ui.output_buf)
  local elapsed = tonumber(parent:match('%*%*Current tool:%*%* `read` `lua/pi%-dev/compat/subagent%.lua` %(([%d.]+)s%)'))
  return elapsed and elapsed >= 1.5
end, 50), parent)
tree = text(state.ui.subagent_tree_buf)
local tree_elapsed = tonumber(tree:match('worker %- read lua/pi%-dev/compat/subagent%.lua %(([%d.]+)s%)'))
assert(tree_elapsed and tree_elapsed >= 1.5, tree)

renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-live-timing',
  toolName = 'subagent',
  partialResult = payload(progress({
    currentTool = 'bash',
    currentToolArgs = './tests/shell/renderer/subagent_live_tool_timing.sh',
    currentToolStartedAt = base_ms + 500,
    children = {
      {
        runId = 'nested-review',
        state = 'running',
        agent = 'reviewer',
        currentTool = 'web_search',
        currentToolStartedAt = base_ms + 1000,
        currentPath = 'agent timing contract',
      },
    },
    toolCalls = {
      { text = 'read lua/pi-dev/compat/subagent.lua', expandedText = 'read lua/pi-dev/compat/subagent.lua' },
      { text = 'bash ./tests/shell/renderer/subagent_live_tool_timing.sh', expandedText = 'bash ./tests/shell/renderer/subagent_live_tool_timing.sh' },
    },
    recentTools = {},
    toolCount = 2,
    durationMs = 2500,
  })),
  timestamp = base_ms + 1500,
})

parent = text(state.ui.output_buf)
assert(parent:find('1. read lua/pi-dev/compat/subagent.lua (1.5s)', 1, true), parent)
assert(parent:find('**Current tool:** `bash` ./tests/shell/renderer/subagent_live_tool_timing.sh (1s)', 1, true), parent)
tree = text(state.ui.subagent_tree_buf)
assert(tree:find('worker - bash ./tests/shell/renderer/subagent_live_tool_timing.sh (1s)', 1, true), tree)
assert(tree:find('nested-review [reviewer] - web_search agent timing contract (500ms)', 1, true), tree)
assert(tree:find('worker - read ', 1, true) == nil, tree)

renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-live-timing',
  toolName = 'subagent',
  partialResult = payload(progress({
    currentTool = 'edit',
    currentToolArgs = 'lua/pi-dev/compat/subagent.lua',
    currentToolStartedAt = base_ms + 2000,
    toolCalls = {
      { text = 'read lua/pi-dev/compat/subagent.lua', expandedText = 'read lua/pi-dev/compat/subagent.lua' },
      { text = 'bash ./tests/shell/renderer/subagent_live_tool_timing.sh', expandedText = 'bash ./tests/shell/renderer/subagent_live_tool_timing.sh' },
      { text = 'edit lua/pi-dev/compat/subagent.lua', expandedText = 'edit lua/pi-dev/compat/subagent.lua' },
    },
    recentTools = {
      { tool = 'read', args = 'lua/pi-dev/compat/subagent.lua', endMs = base_ms + 400 },
      { tool = 'bash', args = './tests/shell/renderer/subagent_live_tool_timing.sh', endMs = base_ms + 2000 },
    },
    toolCount = 3,
    durationMs = 2500,
  })),
  timestamp = base_ms + 2500,
})
parent = text(state.ui.output_buf)
assert(parent:find('1. read lua/pi-dev/compat/subagent.lua (1.4s)', 1, true), parent)
assert(parent:find('1. read lua/pi-dev/compat/subagent.lua (1.5s)', 1, true) == nil, parent)
assert(parent:find('2. bash ./tests/shell/renderer/subagent_live_tool_timing.sh (1.5s)', 1, true), parent)
assert(parent:find('3. edit lua/pi-dev/compat/subagent.lua (500ms, running)', 1, true), parent)
tree = text(state.ui.subagent_tree_buf)
assert(tree:find('worker - edit lua/pi-dev/compat/subagent.lua (500ms)', 1, true), tree)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
