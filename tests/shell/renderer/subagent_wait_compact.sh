#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat > "$script" <<'LUA'
require('pi-dev').setup({
  keymaps = { enable = false },
  ui = { width = 96, input_height = 8, render = { fold_tool_output_over = 1 } },
})

local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')
local ui = require('pi-dev.ui')

ui.show()
renderer.clear('subagent wait compact test')

local function flush()
  renderer.flush_pending_tool_renders()
end

local function text()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
end

local function line_count()
  return #vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
end

local running = {
  type = 'tool_execution_start',
  toolCallId = 'wait-call',
  toolName = 'subagent_wait',
  args = { all = true, timeoutMs = 1800000 },
}
statusline.handle_event({ type = 'agent_start' })
statusline.handle_event(running)
renderer.handle_event(running)
flush()

local rendered = text()
assert(rendered:find('### Tool: subagent_wait all active work', 1, true), rendered)
assert(rendered:find('_run_', 1, true), rendered)
assert(not rendered:find('#### Request', 1, true), rendered)
assert(not rendered:find('#### Result', 1, true), rendered)
assert(line_count() <= 18, rendered)
assert(statusline.short_status_label(state.statusline.status) == 'sa_wait', state.statusline.status)
assert(statusline.render_for_width(80):find('Pi status: sa_wait', 1, true), statusline.render_for_width(80))

local update = vim.tbl_extend('force', running, {
  type = 'tool_execution_update',
  partialResult = {
    results = {
      {
        agent = 'example-agent',
        status = 'running',
        task = 'Investigate ExamplePrompt behavior and report findings.',
        progress = {
          status = 'running',
          currentTool = 'read',
          currentPath = 'tests/fixtures/example.txt',
          recentOutput = {
            'line 1', 'line 2', 'line 3', 'line 4', 'line 5',
          },
        },
      },
    },
  },
})
statusline.handle_event(update)
renderer.handle_event(update)
flush()
rendered = text()
assert(rendered:find('### Tool: subagent_wait all active work', 1, true), rendered)
assert(rendered:find('_run_', 1, true), rendered)
assert(not rendered:find('Investigate ExamplePrompt behavior', 1, true), rendered)
assert(not rendered:find('recent output', 1, true), rendered)
assert(not rendered:find('#### Result', 1, true), rendered)
assert(line_count() <= 18, rendered)
assert(statusline.short_status_label(state.statusline.status) == 'sa_wait', state.statusline.status)

local done = vim.tbl_extend('force', running, {
  type = 'tool_execution_end',
  result = {
    results = {
      {
        agent = 'example-agent',
        status = 'completed',
        task = 'Investigate ExamplePrompt behavior and report findings.',
        response = 'ExamplePrompt behavior is stable.',
      },
    },
  },
})
statusline.handle_event(done)
renderer.handle_event(done)
flush()
rendered = text()
assert(rendered:find('_done_', 1, true), rendered)
assert(rendered:find('#### Request', 1, true), rendered)
assert(rendered:find('#### Result', 1, true), rendered)
assert(rendered:find('##### example-agent - completed', 1, true), rendered)
assert(statusline.short_status_label(state.statusline.status) == 'run', state.statusline.status)
LUA

pidev_run_lua_file "$script"
