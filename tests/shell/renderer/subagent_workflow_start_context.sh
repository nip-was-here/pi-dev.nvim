#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 100, input_height = 10 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()
renderer.clear('subagent workflow input context')

local workflow_script = [[
const tasks = [
  { key: 'correctness', agent: 'reviewer', task: 'Review the renderer contract', cwd: './tmp/pi-dev-test/project', skill: ['tdd'], model: 'example/review-model' },
  { key: 'tests', agent: 'worker', task: 'Run focused regression tests', cwd: './tmp/pi-dev-test/project' }
];
return runs.all(tasks);
]]

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-workflow-live',
  toolName = 'subagent',
  args = {
    workflowScript = workflow_script,
    context = 'fresh',
    async = true,
    timeoutMs = 900000,
    chatProgress = 'off',
  },
})

local function text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

local parent = text(state.ui.output_buf)
assert(parent:find('### Tool: subagent workflow (2 agents)', 1, true), parent)
assert(parent:find('**Agent:** reviewer', 1, true), parent)
assert(parent:find('**Name:** correctness', 1, true), parent)
assert(parent:find('**Skills:** tdd', 1, true), parent)
assert(parent:find('**Model:** example/review-model', 1, true), parent)
assert(parent:find('**Task:** Review the renderer contract', 1, true), parent)
assert(parent:find('**Command:** runs.all', 1, true), parent)
assert(parent:find('**Name:** tests', 1, true), parent)
assert(parent:find('**Agent:** worker', 1, true), parent)
assert(parent:find('**Task:** Run focused regression tests', 1, true), parent)

assert(state.ui.subagent_tree_win and vim.api.nvim_win_is_valid(state.ui.subagent_tree_win), 'live workflow children should open the agent tree')
local tree = text(state.ui.subagent_tree_buf)
assert(tree:find('correctness [reviewer, tdd] - runs.all', 1, true), tree)
assert(tree:find('tests [worker] - runs.all', 1, true), tree)

renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-workflow-live',
  toolName = 'subagent',
  partialResult = {
    details = {
      results = {
        {
          agent = 'reviewer',
          task = 'Review the renderer contract',
          progress = { index = 0, agent = 'reviewer', status = 'running', currentTool = 'read', currentPath = 'lua/pi-dev/renderer.lua' },
        },
        {
          agent = 'worker',
          task = 'Run focused regression tests',
          progress = { index = 1, agent = 'worker', status = 'running', currentTool = 'bash', currentToolArgs = './tests/shell/renderer/subagent_workflow_start_context.sh' },
        },
      },
    },
  },
})
renderer.flush_pending_tool_renders()
tree = text(state.ui.subagent_tree_buf)
assert(tree:find('correctness [reviewer, tdd] - read lua/pi-dev/', 1, true), tree)
assert(tree:find('tests [worker] - bash ./tests/shell/', 1, true), tree)
local children = state.render.tool_blocks['subagent-workflow-live'].subagent_children
assert(children[1].lines and table.concat(children[1].lines, '\n'):find('**Model:** example/review-model', 1, true), vim.inspect(children[1]))
assert(table.concat(children[1].lines, '\n'):find('**Command:** runs.all', 1, true), vim.inspect(children[1]))

renderer.clear('subagent workflow parser boundaries')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-workflow-lookalikes',
  toolName = 'subagent',
  args = {
    workflowScript = [[
      // runs.all([{ agent: 'comment-agent', task: 'comment task' }])
      const note = "runs.all([{ agent: 'string-agent', task: 'string task' }])";
      return runs.all([{ subagent: 'not-an-agent', taskLabel: 'not a task' }]);
    ]],
    context = 'fresh',
  },
})
parent = text(state.ui.output_buf)
assert(parent:find('comment-agent', 1, true) == nil, parent)
assert(parent:find('string-agent', 1, true) == nil, parent)
assert(parent:find('not-an-agent', 1, true) == nil, parent)
assert(not (state.ui.subagent_tree_win and vim.api.nvim_win_is_valid(state.ui.subagent_tree_win)), 'lookalike fields must not fabricate an active agent tree')

renderer.clear('single subagent workflow input')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-workflow-single',
  toolName = 'subagent',
  args = {
    workflowScript = [[return runs.run('single-review', { agent: 'reviewer', task: 'Review the single run' });]],
    context = 'fresh',
  },
})
parent = text(state.ui.output_buf)
assert(parent:find('**Name:** single-review', 1, true), parent)
assert(parent:find('**Task:** Review the single run', 1, true), parent)
assert(parent:find('**Command:** runs.run', 1, true), parent)
assert(state.ui.subagent_tree_win and vim.api.nvim_win_is_valid(state.ui.subagent_tree_win), 'single runs.run child should open the agent tree')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
