#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat >"$script" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 110, input_height = 8 } })
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

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

ui.show()
state.statusline.active = true
state.statusline.status = 'running'
state.statusline.role = 'architect'
state.statusline.model = 'example/root-model'
state.statusline.thinking_level = 'high'
renderer.clear('agent context parent')
local root = buf_text(state.ui.output_buf)
assert(root:find('**Agent:** root-agent', 1, true), root)
assert(root:find('**Status:** running', 1, true), root)
assert(root:find('**Role:** architect', 1, true), root)
assert(root:find('**Model:** example/root-model', 1, true), root)
assert(root:find('**Thinking:** high', 1, true), root)

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'agent-context',
  toolName = 'subagent',
  args = { agent = 'worker', task = 'implement complete agent context', skill = { 'tdd' } },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'agent-context',
  toolName = 'subagent',
  partialResult = {
    details = {
      results = {
        {
          index = 0,
          agent = 'worker',
          status = 'running',
          task = 'implement complete agent context',
          skills = { 'tdd' },
          model = 'example/model',
          thinking = 'high',
          toolCalls = {
            { text = 'read config', expandedText = 'read lua/pi-dev/config.lua' },
            { text = 'edit renderer', expandedText = 'edit lua/pi-dev/compat/subagent.lua' },
          },
          messages = {
            { role = 'user', content = 'implement complete agent context' },
            {
              role = 'assistant',
              content = {
                { type = 'text', text = 'I am inspecting the renderer.' },
                { type = 'toolCall', id = 'read-1', name = 'read', args = { path = 'lua/pi-dev/config.lua' } },
              },
            },
            { role = 'toolResult', toolCallId = 'read-1', content = 'config contents' },
          },
          progress = {
            index = 0,
            agent = 'worker',
            status = 'running',
            task = 'implement complete agent context',
            skills = { 'tdd' },
            currentTool = 'bash',
            currentToolArgs = 'echo current command',
            toolCount = 3,
            turnCount = 2,
            tokens = 42,
            recentTools = {},
            recentOutput = {},
          },
          children = {
            {
              runId = 'nested-research',
              depth = 1,
              path = {},
              state = 'running',
              agent = 'researcher',
              role = 'research-specialist',
              model = 'example/research-model',
              thinking = 'medium',
              task = 'research nested agent context',
              toolCalls = {
                { name = 'read', args = { path = 'lua/pi-dev/compat/subagent.lua' } },
              },
              messages = {
                { role = 'user', content = 'research nested agent context' },
                { type = 'tool_execution_start', toolName = 'read', args = { path = 'lua/pi-dev/compat/subagent.lua' } },
                { role = 'assistant', content = 'nested transcript body' },
              },
              finalOutput = 'nested result body',
              currentTool = 'web_search',
              currentPath = 'agent metadata contract',
              children = {
                {
                  runId = 'deep-review',
                  depth = 2,
                  path = {},
                  state = 'running',
                  agent = 'reviewer',
                  currentTool = 'read',
                  currentPath = 'lua/pi-dev/compat/subagent.lua',
                },
                {
                  runId = 'deep-done',
                  depth = 2,
                  path = {},
                  state = 'stopped',
                  agent = 'scout',
                  currentTool = 'read',
                },
                {
                  runId = 'deep-interrupted',
                  depth = 2,
                  path = {},
                  state = 'interrupted',
                  agent = 'worker',
                },
              },
            },
          },
        },
        {
          index = 1,
          agent = 'planner',
          status = 'running',
          task = 'plan next step',
          toolCalls = {
            { name = 'read', args = { path = 'lua/pi-dev/ui.lua' } },
            { name = 'bash', args = { command = 'echo latest completed command' } },
          },
          progress = {
            index = 1,
            agent = 'planner',
            status = 'running',
            task = 'plan next step',
            recentTools = {},
            recentOutput = {},
          },
        },
      },
    },
  },
})
renderer.flush_pending_tool_renders()

local parent = buf_text(state.ui.output_buf)
assert(parent:find('**Agent:** worker', 1, true), parent)
assert(parent:find('**Skills:** tdd', 1, true), parent)
assert(parent:find('**Model:** example/model', 1, true), parent)
assert(parent:find('**Thinking:** high', 1, true), parent)
assert(parent:find('**Commands:**', 1, true), parent)
assert(parent:find('1. read lua/pi-dev/config.lua', 1, true), parent)
assert(parent:find('2. edit lua/pi-dev/compat/subagent.lua', 1, true), parent)
assert(parent:find('3. bash echo current command (running)', 1, true), parent)
assert(parent:find('1. read lua/pi-dev/ui.lua', 1, true), parent)
assert(parent:find('2. bash echo latest completed command', 1, true), parent)

assert(state.ui.subagent_tree_win and vim.api.nvim_win_is_valid(state.ui.subagent_tree_win), 'active descendants should open the agent tree')
local tree = buf_text(state.ui.subagent_tree_buf)
assert(tree:find('root-agent [architect] - subagent worker', 1, true), tree)
assert(tree:find('worker [tdd] - bash echo current command', 1, true), tree)
assert(tree:find('planner - bash echo latest completed command', 1, true), tree)
assert(tree:find('nested-research [research-specialist] - web_search a', 1, true), tree)
assert(tree:find('deep-review [reviewer] - read lua/pi-dev/compat/', 1, true), tree)
assert(tree:find('deep-done', 1, true) == nil, tree)
assert(tree:find('deep-interrupted', 1, true) == nil, tree)

local worker_row = line_with(state.ui.subagent_tree_buf, 'worker [tdd] - ')
assert(worker_row, tree)
vim.api.nvim_set_current_win(state.ui.subagent_tree_win)
vim.api.nvim_win_set_cursor(state.ui.subagent_tree_win, { worker_row, 0 })
feed_return()
assert(vim.wait(1000, function()
  return state.ui.subagent_view ~= nil and state.ui.subagent_view.title == 'worker'
end), 'worker row should open the worker chat')
local worker = buf_text(state.ui.subagent_view.buf)
assert(worker:find('## Main info', 1, true), worker)
assert(worker:find('**Agent:** worker', 1, true), worker)
assert(worker:find('**Skills:** tdd', 1, true), worker)
assert(worker:find('**Status:** running', 1, true), worker)
assert(worker:find('**Model:** example/model', 1, true), worker)
assert(worker:find('**Thinking:** high', 1, true), worker)
assert(worker:find('**Task:** implement complete agent context', 1, true), worker)
assert(worker:find('**Commands:**', 1, true), worker)
assert(worker:find('I am inspecting the renderer.', 1, true), worker)
assert(worker:find('config contents', 1, true), worker)

local nested_row = line_with(state.ui.subagent_tree_buf, 'nested-research [research-specialist] - ')
assert(nested_row, tree)
vim.api.nvim_set_current_win(state.ui.subagent_tree_win)
vim.api.nvim_win_set_cursor(state.ui.subagent_tree_win, { nested_row, 0 })
feed_return()
assert(vim.wait(1000, function()
  return state.ui.subagent_view ~= nil and state.ui.subagent_view.title == 'nested-research'
end), 'nested row should open the nested chat')
local nested = buf_text(state.ui.subagent_view.buf)
assert(nested:find('**Name:** nested-research', 1, true), nested)
assert(nested:find('**Agent:** researcher', 1, true), nested)
assert(nested:find('**Role:** research-specialist', 1, true), nested)
assert(nested:find('**Status:** running', 1, true), nested)
assert(nested:find('**Model:** example/research-model', 1, true), nested)
assert(nested:find('**Thinking:** medium', 1, true), nested)
assert(nested:find('**Task:** research nested agent context', 1, true), nested)
assert(nested:find('1. read lua/pi-dev/compat/subagent.lua', 1, true), nested)
assert(nested:find('2. web_search agent metadata contract', 1, true), nested)
assert(nested:find('nested transcript body', 1, true), nested)
assert(nested:find('**Current tool:** `web_search` `agent metadata contract`', 1, true), nested)

renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'agent-context',
  toolName = 'subagent',
  result = {
    details = {
      results = {
        {
          index = 0,
          agent = 'worker',
          status = 'completed',
          task = 'implement complete agent context',
          skills = { 'tdd' },
          model = 'example/model',
          thinking = 'high',
          toolCalls = {
            { expandedText = 'read lua/pi-dev/config.lua' },
            { expandedText = 'edit lua/pi-dev/compat/subagent.lua' },
            { expandedText = 'bash echo current command' },
          },
          finalOutput = 'agent context complete',
        },
      },
    },
  },
})
renderer.flush_pending_tool_renders()
local completed_parent = buf_text(state.ui.output_buf)
assert(completed_parent:find('1. read lua/pi-dev/config.lua', 1, true), completed_parent)
assert(completed_parent:find('2. edit lua/pi-dev/compat/subagent.lua', 1, true), completed_parent)
assert(completed_parent:find('3. bash echo current command', 1, true), completed_parent)
assert(not (state.ui.subagent_tree_win and vim.api.nvim_win_is_valid(state.ui.subagent_tree_win)), 'root-only state should hide the agent tree')
LUA

pidev_run_lua_file "$script"
