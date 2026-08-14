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
renderer.clear('async subagent artifact watch')
local async_dir = vim.env.PIDEV_TEST_TMP .. '/async-artifact-watch/example-async-run'
vim.fn.mkdir(async_dir, 'p')
local status_path = async_dir .. '/status.json'
local base_ms = 1700000000000

local function write_status(status)
  vim.fn.writefile({ vim.json.encode(status) }, status_path)
end

local function text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

local function running_status()
  return {
    lifecycleArtifactVersion = 1,
    runId = 'example-async-run',
    state = 'running',
    mode = 'parallel',
    startedAt = base_ms,
    lastUpdate = base_ms + 2500,
    steps = {
      {
        agent = 'reviewer',
        label = 'correctness',
        description = 'Review async renderer status',
        status = 'running',
        model = 'example/review-model',
        thinking = 'high',
        currentTool = 'bash',
        currentToolArgs = './tests/shell/renderer/subagent_async_artifact_watch.sh',
        currentToolStartedAt = base_ms + 1500,
        recentTools = {
          { tool = 'read', args = 'lua/pi-dev/compat/subagent.lua', endMs = base_ms + 1400, durationMs = 1400 },
        },
        toolCount = 2,
        turnCount = 1,
        tokens = { input = 20, output = 5, total = 25 },
        startedAt = base_ms,
        children = {
          {
            runId = 'nested-review',
            state = 'running',
            agent = 'researcher',
            currentTool = 'web_search',
            currentToolStartedAt = base_ms + 2000,
            currentPath = 'async lifecycle status',
            recentTools = {
              { tool = 'read', args = 'lua/pi-dev/renderer.lua', endMs = base_ms + 1900, durationMs = 400 },
            },
          },
        },
        steps = {
          {
            agent = 'scout',
            status = 'running',
            currentTool = 'edit',
            currentToolStartedAt = base_ms + 2100,
            currentPath = 'lua/pi-dev/compat/subagent_async.lua',
          },
        },
      },
    },
  }
end

write_status(running_status())
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'async-subagent-tool',
  toolName = 'subagent',
  args = {
    workflowScript = [[return runs.run('correctness', { agent: 'reviewer', task: 'Review async renderer status' });]],
    async = true,
    context = 'fresh',
  },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'async-subagent-tool',
  toolName = 'subagent',
  result = {
    content = { { type = 'text', text = 'Async workflow started.' } },
    details = {
      mode = 'workflow',
      runId = 'example-async-run',
      asyncId = 'example-async-run',
      asyncDir = async_dir,
      results = {},
    },
  },
})

assert(vim.wait(1500, function()
  local parent = text(state.ui.output_buf)
  local tree = state.ui.subagent_tree_buf and text(state.ui.subagent_tree_buf) or ''
  return parent:find('1. read - lua/pi-dev/compat/subagent.lua (1.4s)', 1, true)
    and parent:find('2. bash ./tests/shell/renderer/subagent_async_artifact_watch.sh (1s, running)', 1, true)
    and tree:find('correctness [reviewer] - bash ./tests/shell/renderer/subagent_async_artifact_watch.sh (1s)', 1, true)
    and tree:find('nested-review [researcher] - web_search async lifecycle status (500ms)', 1, true)
    and tree:find('correctness/step-1 [scout] - edit lua/pi-dev/compat/subagent_async.lua (400ms)', 1, true)
end, 25), text(state.ui.output_buf) .. '\n--- tree ---\n' .. (state.ui.subagent_tree_buf and text(state.ui.subagent_tree_buf) or ''))

local nested_row
for index, line in ipairs(vim.api.nvim_buf_get_lines(state.ui.subagent_tree_buf, 0, -1, false)) do
  if line:find('nested-review [researcher] - ', 1, true) then nested_row = index end
end
assert(nested_row, text(state.ui.subagent_tree_buf))
vim.api.nvim_set_current_win(state.ui.subagent_tree_win)
vim.api.nvim_win_set_cursor(state.ui.subagent_tree_win, { nested_row, 0 })
assert(ui.select_subagent_tree_item(), text(state.ui.subagent_tree_buf))
local nested_chat = text(state.ui.subagent_view.buf)
assert(nested_chat:find('1. read - lua/pi-dev/renderer.lua (400ms)', 1, true), nested_chat)
assert(nested_chat:find('2. web_search async lifecycle status (500ms, running)', 1, true), nested_chat)
ui.close_all_subagent_views()

local finished = running_status()
finished.state = 'complete'
finished.lastUpdate = base_ms + 3000
finished.steps[1].status = 'completed'
finished.steps[1].currentTool = nil
finished.steps[1].currentToolArgs = nil
finished.steps[1].currentToolStartedAt = nil
finished.steps[1].recentTools = {
  { tool = 'read', args = 'lua/pi-dev/compat/subagent.lua', endMs = base_ms + 1400, durationMs = 1400 },
  { tool = 'bash', args = './tests/shell/renderer/subagent_async_artifact_watch.sh', endMs = base_ms + 3000, durationMs = 1500 },
}
finished.steps[1].children[1].state = 'completed'
finished.steps[1].children[1].currentTool = nil
finished.steps[1].children[1].currentPath = nil
finished.steps[1].steps[1].status = 'completed'
finished.steps[1].steps[1].currentTool = nil
finished.steps[1].steps[1].currentPath = nil
write_status(finished)

assert(vim.wait(2000, function()
  local parent = text(state.ui.output_buf)
  local tree_open = state.ui.subagent_tree_win and vim.api.nvim_win_is_valid(state.ui.subagent_tree_win)
  return not tree_open
    and parent:find('2. bash - ./tests/shell/renderer/subagent_async_artifact_watch.sh (1.5s)', 1, true)
    and parent:find('(running)', 1, true) == nil
end, 25), text(state.ui.output_buf))

renderer.clear('restored async watcher')
local restored_dir = vim.env.PIDEV_TEST_TMP .. '/async-artifact-watch/restored-run'
vim.fn.mkdir(restored_dir, 'p')
local restored_status = running_status()
restored_status.runId = 'restored-run'
restored_status.steps[1].currentTool = 'web_search'
restored_status.steps[1].currentToolArgs = 'async lifecycle status'
restored_status.steps[1].currentPath = nil
vim.fn.writefile({ vim.json.encode(restored_status) }, restored_dir .. '/status.json')
renderer.render_messages({
  {
    role = 'assistant',
    content = {
      {
        type = 'toolCall',
        id = 'restored-async-tool',
        name = 'subagent',
        arguments = {
          workflowScript = [[return runs.run('correctness', { agent: 'reviewer', task: 'Review async renderer status' });]],
          async = true,
        },
      },
    },
  },
  {
    role = 'toolResult',
    toolCallId = 'restored-async-tool',
    toolName = 'subagent',
    content = { { type = 'text', text = 'Async workflow started.' } },
    details = { mode = 'workflow', runId = 'restored-run', asyncId = 'restored-run', asyncDir = restored_dir, results = {} },
  },
}, 'restored async session')
assert(vim.wait(1500, function()
  local tree = state.ui.subagent_tree_buf and text(state.ui.subagent_tree_buf) or ''
  return tree:find('correctness [reviewer] - web_search async lifecycle status', 1, true) ~= nil
end, 25), text(state.ui.output_buf))

renderer.clear('async watcher ownership')
local second_dir = vim.env.PIDEV_TEST_TMP .. '/async-artifact-watch/owned-run'
vim.fn.mkdir(second_dir, 'p')
local second_path = second_dir .. '/status.json'
local second = running_status()
second.runId = 'owned-run'
second.steps[1].currentTool = 'read'
second.steps[1].currentToolArgs = 'lua/pi-dev/ui.lua'
second.steps[1].currentToolStartedAt = base_ms + 2000
vim.fn.writefile({ vim.json.encode(second) }, second_path)
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'owned-tool', toolName = 'subagent', args = { agent = 'reviewer', async = true } })
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'owned-tool',
  toolName = 'subagent',
  result = {
    content = { { type = 'text', text = 'Async run started.' } },
    details = { mode = 'single', runId = 'owned-run', asyncId = 'owned-run', asyncDir = second_dir, results = {} },
  },
})
assert(vim.wait(1500, function()
  return text(state.ui.output_buf):find('read lua/pi-dev/ui.lua', 1, true) ~= nil
end, 25), text(state.ui.output_buf))

state.set_active_rpc_runtime('other-runtime')
second.lastUpdate = base_ms + 3500
second.steps[1].currentTool = 'edit'
second.steps[1].currentToolArgs = 'lua/pi-dev/ui.lua'
vim.fn.writefile({ vim.json.encode(second) }, second_path)
vim.wait(1200, function() return false end, 50)
assert(text(state.ui.output_buf):find('edit lua/pi-dev/ui.lua', 1, true) == nil, text(state.ui.output_buf))
state.set_active_rpc_runtime('default')
second.lastUpdate = base_ms + 4000
second.steps[1].currentTool = 'bash'
second.steps[1].currentToolArgs = 'echo stale watcher'
vim.fn.writefile({ vim.json.encode(second) }, second_path)
vim.wait(1200, function() return false end, 50)
assert(text(state.ui.output_buf):find('echo stale watcher', 1, true) == nil, text(state.ui.output_buf))

renderer.clear('malformed async status fails open')
local malformed_dir = vim.env.PIDEV_TEST_TMP .. '/async-artifact-watch/malformed-run'
vim.fn.mkdir(malformed_dir, 'p')
vim.fn.writefile({ '{ malformed status' }, malformed_dir .. '/status.json')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'malformed-tool',
  toolName = 'subagent',
  args = {
    workflowScript = [[return runs.run('fallback', { agent: 'worker', task: 'Keep provisional status' });]],
    async = true,
  },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'malformed-tool',
  toolName = 'subagent',
  result = {
    content = { { type = 'text', text = 'Async run started.' } },
    details = { mode = 'workflow', runId = 'malformed-run', asyncId = 'malformed-run', asyncDir = malformed_dir, results = {} },
  },
})
vim.wait(1200, function() return false end, 50)
local fallback_parent = text(state.ui.output_buf)
local fallback_tree = state.ui.subagent_tree_buf and text(state.ui.subagent_tree_buf) or ''
assert(fallback_parent:find('**Command:** runs.run', 1, true), fallback_parent)
assert(fallback_tree:find('fallback [worker] - runs.run', 1, true), fallback_tree)
renderer.clear('async watcher cleanup')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
