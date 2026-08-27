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
local ui = require('pi-dev.ui')

ui.show()
renderer.clear('native tool summary test')

local function flush()
  renderer.flush_pending_tool_renders()
end

local function event(payload)
  renderer.handle_event(payload)
  flush()
end

local function text()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
end

local function line_number(needle)
  for index, line in ipairs(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  error('missing line containing: ' .. needle .. '\n' .. text())
end

event({
  type = 'tool_execution_start',
  toolCallId = 'mcp-call',
  toolName = 'mcp',
  args = {
    tool = 'alpha_tool_list',
    server = 'alpha-server',
    args = { project = 'example-project', limit = 2 },
  },
})
event({
  type = 'tool_execution_end',
  toolCallId = 'mcp-call',
  toolName = 'mcp',
  args = {
    tool = 'alpha_tool_list',
    server = 'alpha-server',
    args = { project = 'example-project', limit = 2 },
  },
  result = { output = '{"ok":true,"total":2,"items":["alpha","beta"]}' },
})

local rendered = text()
assert(rendered:find('### Tool: mcp call alpha_tool_list @alpha%-server'), rendered)
assert(rendered:find('target: `alpha_tool_list`', 1, true), rendered)
assert(rendered:find('server: `alpha-server`', 1, true), rendered)
assert(rendered:find('args: `{"limit":2,"project":"example-project"}`', 1, true) or rendered:find('args: `{"project":"example-project","limit":2}`', 1, true), rendered)
assert(rendered:find('result: `2 items`', 1, true), rendered)

vim.api.nvim_set_current_win(state.ui.output_win)
local summary_line = line_number('target: `alpha_tool_list`')
local request_line = line_number('#### MCP request')
assert(vim.fn.foldclosed(summary_line) == -1, 'mcp visible summary must stay outside the closed detail fold')
assert(vim.fn.foldclosed(request_line) ~= -1, 'mcp raw request should be folded')

event({
  type = 'tool_execution_start',
  toolCallId = 'script-call',
  toolName = 'mcpScript',
  args = {
    code = [[
const found = await tools.search({ query: "alpha tools" });
const details = await tools.describe({ path: "alpha_tool_list" });
const result = await tools.call("alpha_tool_list", { limit: 1 });
emit(result);
]],
    timeoutMs = 30000,
  },
})
event({
  type = 'tool_execution_update',
  toolCallId = 'script-call',
  toolName = 'mcpScript',
  args = {
    code = [[
const found = await tools.search({ query: "alpha tools" });
const details = await tools.describe({ path: "alpha_tool_list" });
const result = await tools.call("alpha_tool_list", { limit: 1 });
emit(result);
]],
    timeoutMs = 30000,
  },
  partialResult = { output = 'alpha\nbeta\n' },
})

rendered = text()
assert(rendered:find('### Tool: mcpScript search "alpha tools" %+2 calls'), rendered)
assert(rendered:find('script: `4 lines`', 1, true), rendered)
assert(rendered:find('planned: `search "alpha tools"`, `describe alpha_tool_list`, `call alpha_tool_list`', 1, true), rendered)
assert(rendered:find('emitted: `2 lines`', 1, true), rendered)
vim.api.nvim_set_current_win(state.ui.output_win)
assert(vim.fn.foldclosed(line_number('script: `4 lines`')) == -1, 'mcpScript visible summary must stay outside fold')
assert(vim.fn.foldclosed(line_number('#### Script')) ~= -1, 'mcpScript code should be folded')

event({
  type = 'tool_execution_start',
  toolCallId = 'search-call',
  toolName = 'web_search',
  args = { queries = { 'alpha release notes', 'beta compatibility' }, numResults = 3, provider = 'auto' },
})
event({
  type = 'tool_execution_start',
  toolCallId = 'fetch-call',
  toolName = 'fetch_content',
  args = { urls = { 'https://alpha.example.test/docs', 'https://beta.example.test/guide' }, mode = 'answer', prompt = 'Summarize public behavior.' },
})
event({
  type = 'tool_execution_start',
  toolCallId = 'source-call',
  toolName = 'source_check',
  args = { claim = 'AlphaService supports native MCP tool summaries.', numResults = 4 },
})
event({
  type = 'tool_execution_start',
  toolCallId = 'content-call',
  toolName = 'get_search_content',
  args = { responseId = 'response-example', findText = { 'alpha', 'beta' } },
})
event({
  type = 'tool_execution_start',
  toolCallId = 'generic-call',
  toolName = 'example_custom_tool',
  args = { action = 'inspect', target = 'ExamplePrompt', args = { depth = 1 } },
})

rendered = text()
assert(rendered:find('### Tool: web_search 2 queries'), rendered)
assert(rendered:find('queries: `alpha release notes`, `beta compatibility`', 1, true), rendered)
assert(rendered:find('### Tool: fetch_content 2 urls'), rendered)
assert(rendered:find('urls: `https://alpha.example.test/docs`, `https://beta.example.test/guide`', 1, true), rendered)
assert(rendered:find('### Tool: source_check AlphaService supports nat'), rendered)
assert(rendered:find('claim: `AlphaService supports native MCP tool summaries.`', 1, true), rendered)
assert(rendered:find('### Tool: get_search_content response%-example'), rendered)
assert(rendered:find('find: `alpha`, `beta`', 1, true), rendered)
assert(rendered:find('### Tool: example_custom_tool'), rendered)
assert(rendered:find('target: `ExamplePrompt`', 1, true), rendered)
assert(rendered:find('action: `inspect`', 1, true), rendered)
assert(rendered:find('args: `{"depth":1}`', 1, true), rendered)
LUA

pidev_run_lua_file "$script"
