#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 110, input_height = 10 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()
renderer.clear('subagent transcript detail')
local transcript = vim.env.PIDEV_TEST_TMP .. '/subagent-transcript-detail.jsonl'
local records = {}
local function record(value)
  table.insert(records, vim.json.encode(value))
end
local function message(content)
  record({ version = 1, recordType = 'message', message = content })
end

message({ role = 'user', content = 'inspect and update the example project' })
message({
  role = 'assistant',
  content = {
    { type = 'thinking', thinking = 'I should read the existing file before writing.' },
    { type = 'text', text = 'Inspecting the current state.' },
    { type = 'toolCall', id = 'read-1', name = 'read', args = { path = './tmp/pi-dev-test/example-project/state.md' } },
  },
})
message({ role = 'toolResult', toolCallId = 'read-1', toolName = 'read', content = 'existing child file body' })
message({
  role = 'assistant',
  content = {
    { type = 'toolCall', id = 'write-1', name = 'write', args = { path = './tmp/pi-dev-test/example-project/result.md', content = 'new child file body' } },
    { type = 'toolCall', id = 'mcp-1', name = 'mcp', args = { tool = 'example_lookup', server = 'example-server', args = { query = 'detail' } } },
    { type = 'toolCall', id = 'generic-1', name = 'example_tool', args = { action = 'inspect', target = 'child-state' } },
  },
})
message({ role = 'toolResult', toolCallId = 'write-1', toolName = 'write', content = '{"path":"./tmp/pi-dev-test/example-project/result.md","bytesWritten":19}' })
message({ role = 'toolResult', toolCallId = 'mcp-1', toolName = 'mcp', content = '{"ok":true,"data":{"value":"mcp child output"}}' })
message({ role = 'toolResult', toolCallId = 'generic-1', toolName = 'example_tool', content = '{"ok":true,"value":"generic child output"}' })
record({
  version = 1,
  recordType = 'tool_start',
  toolCallId = 'bash-live',
  toolName = 'bash',
  argsPayload = '{"command":"echo live child command"}',
})
vim.fn.writefile(records, transcript)

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-transcript',
  toolName = 'subagent',
  args = { agent = 'worker', task = 'show detailed child transcript' },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'subagent-transcript',
  toolName = 'subagent',
  partialResult = {
    details = {
      results = {
        {
          agent = 'worker',
          status = 'running',
          task = 'show detailed child transcript',
          transcriptPath = transcript,
          progress = { agent = 'worker', status = 'running', currentTool = 'bash', currentToolArgs = 'echo live child command' },
        },
      },
    },
  },
})
renderer.flush_pending_tool_renders()

local function text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end
local child_line
for index, line in ipairs(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)) do
  if line:find('**Task:** show detailed child transcript', 1, true) then
    child_line = index
    break
  end
end
assert(child_line, text(state.ui.output_buf))
vim.api.nvim_set_current_win(state.ui.output_win)
vim.api.nvim_win_set_cursor(state.ui.output_win, { child_line, 0 })
assert(ui.open_subagent_at_cursor(), text(state.ui.output_buf))

assert(vim.wait(1500, function()
  local child = text(state.ui.subagent_view.buf)
  return child:find('I should read the existing file before writing.', 1, true)
    and child:find('existing child file body', 1, true)
    and child:find('new child file body', 1, true)
    and child:find('mcp child output', 1, true)
    and child:find('generic child output', 1, true)
end, 20), text(state.ui.subagent_view.buf))

local child = text(state.ui.subagent_view.buf)
assert(child:find('> Thinking', 1, true), child)
assert(child:find('### Tool: read', 1, true), child)
assert(child:find('./tmp/pi-dev-test/example-project/state.md', 1, true), child)
assert(child:find('### Tool: write', 1, true), child)
assert(child:find('```text\nnew child file body\n```', 1, true), child)
assert(child:find('Successfully wrote ./tmp/pi-dev-test/example-project/result.md. 19 bytes.', 1, true), child)
assert(child:find('### Tool: mcp', 1, true), child)
assert(child:find('#### MCP request', 1, true), child)
assert(child:find('### Tool: example_tool', 1, true), child)
assert(child:find('"action": "inspect"', 1, true), child)
assert(child:find('### Tool: bash', 1, true), child)
assert(child:find('echo live child command', 1, true), child)
assert(child:find('_run_', 1, true), child)

message({ role = 'assistant', content = 'live transcript follow-up answer' })
vim.fn.writefile(records, transcript)
assert(vim.wait(1500, function()
  return text(state.ui.subagent_view.buf):find('live transcript follow-up answer', 1, true) ~= nil
end, 20), text(state.ui.subagent_view.buf))
LUA

pidev_run_lua_file "$tmp_lua"
