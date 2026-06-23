#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat >"$script" <<'LUA'
local pi_dev = require('pi-dev')
pi_dev.setup({ keymaps = { prefix = '<leader>a' } })
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

ui.show()
renderer.clear('subagent parent')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-buffer',
  toolName = 'subagent',
  args = { tasks = { { agent = 'reviewer', task = 'review parent summary' } } },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'subagent-buffer',
  toolName = 'subagent',
  result = {
    details = {
      results = {
        {
          agent = 'reviewer',
          status = 'completed',
          task = 'review parent summary',
          output = table.concat({
            '> _Agent start._',
            '',
            'child unique result body',
            '',
            '##### Agent 1/1: nested - completed',
            '',
            '###### Main info',
            '',
            '**Task:** nested task',
            '',
            '###### Result',
            '',
            'nested result body',
            '',
            '> _Agent done._',
          }, '\n'),
          progress = { turnCount = 2, toolCount = 1, tokens = 123 },
        },
        {
          agent = 'scout',
          status = 'completed',
          task = 'second child',
          output = 'second child body',
        },
      },
    },
  },
})

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

local parent = buf_text(state.ui.output_buf)
assert(parent:find('##### Agent 1/2: reviewer %- completed'), parent)
assert(parent:find('###### Main info', 1, true), parent)
assert(parent:find('**Task:** review parent summary', 1, true), parent)
assert(parent:find('child unique result body', 1, true) == nil, parent)
assert(parent:find('###### Result', 1, true) == nil, parent)

local child_line
for index, line in ipairs(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)) do
  if line:find('**Task:** review parent summary', 1, true) then
    child_line = index
    break
  end
end
assert(child_line, parent)
vim.api.nvim_set_current_win(state.ui.output_win)
vim.api.nvim_win_set_cursor(state.ui.output_win, { child_line, 0 })
vim.cmd('PiDevSubagentOpen')

assert(state.ui.subagent_view, 'subagent view should be active')
assert(state.ui.output_title:find('^Pi chat subagent %(deep 1%): reviewer'), state.ui.output_title)
assert(vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.subagent_view.buf, 'output window should show subagent buffer')
assert(vim.bo[state.ui.input_buf].modifiable == false, 'input must be non-modifiable in subagent buffer')

local child = buf_text(state.ui.subagent_view.buf)
assert(child:find('# Pi chat subagent (deep 1): reviewer', 1, true), child)
assert(child:find('child unique result body', 1, true), child)
assert(child:find('> _Subagent started._', 1, true), child)
assert(child:find('> _Subagent done._', 1, true), child)
assert(child:find('> _Agent start._', 1, true) == nil, child)
assert(child:find('> _Agent done._', 1, true) == nil, child)
assert(child:find('##### Agent 1/1: nested - completed', 1, true), child)

local nested_line
for index, line in ipairs(vim.api.nvim_buf_get_lines(state.ui.subagent_view.buf, 0, -1, false)) do
  if line:find('**Task:** nested task', 1, true) then
    nested_line = index
    break
  end
end
assert(nested_line, child)
vim.api.nvim_win_set_cursor(state.ui.output_win, { nested_line, 0 })
vim.cmd('PiDevSubagentOpen')
assert(state.ui.subagent_view.depth == 2, tostring(state.ui.subagent_view.depth))
assert(state.ui.output_title:find('^Pi chat subagent %(deep 2%): nested'), state.ui.output_title)
local nested = buf_text(state.ui.subagent_view.buf)
assert(nested:find('# Pi chat subagent (deep 2): nested', 1, true), nested)
assert(nested:find('## Main info', 1, true), nested)
assert(nested:find('## Result', 1, true), nested)
assert(nested:find('###### Main info', 1, true) == nil, nested)
assert(nested:find('nested result body', 1, true), nested)

vim.cmd('PiDevSubagentParent')
assert(state.ui.subagent_view and state.ui.subagent_view.depth == 1, 'first parent subagent view should be restored')
vim.cmd('PiDevSubagentParent')
assert(state.ui.subagent_view == nil, 'subagent view should close')
assert(vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.output_buf, 'parent output buffer should be restored')
assert(vim.bo[state.ui.input_buf].modifiable == true, 'input must be modifiable again in parent buffer')

vim.api.nvim_win_set_cursor(state.ui.output_win, { child_line, 0 })
vim.cmd('PiDevSubagentOpen')
assert(state.ui.subagent_view, 'subagent view should reopen before runtime switch')
local rpc = require('pi-dev.rpc')
local original_start = rpc.start
rpc.start = function(key)
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key)
  runtime.job_id = runtime.job_id or 321
  return runtime.job_id
end
rpc.use_runtime('other-runtime', { defer_pending_ui = true })
rpc.start = original_start
assert(state.ui.subagent_view == nil, 'runtime switch should close subagent drill-down to avoid cross-runtime mixing')
assert(vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.output_buf, 'runtime switch should restore root output buffer')
LUA

pidev_run_lua_file "$script"
