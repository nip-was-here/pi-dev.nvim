#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({
  keymaps = { enable = false },
  ui = { width = 80, input_height = 10, render = { fold_tool_output_over = 8 } },
  session_render = { chunk_size = 1, chunk_delay_ms = 1 },
})
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()
local read_content = table.concat({
  'read line 1',
  '# heading inside read output',
  '```',
  'inner read fence',
  '```',
  'read line 6',
  'read line 7',
  'read line 8',
  'read line 9',
  'read line 10',
}, '\n')
local bash_output = table.concat({
  'bash line 1',
  '# heading inside bash output',
  '```',
  'inner bash fence',
  '```',
  'bash line 6',
  'bash line 7',
  'bash line 8',
  'bash line 9',
  'bash line 10',
}, '\n')

renderer.render_messages_chunked({
  { role = 'assistant', content = { { type = 'text', text = 'before read' }, { type = 'toolCall', id = 'read-call', name = 'read', arguments = { path = 'chunked-read.md' } } } },
  { role = 'toolResult', toolCallId = 'read-call', toolName = 'read', content = vim.json.encode({ path = 'chunked-read.md', content = read_content }) },
  { role = 'assistant', content = { { type = 'text', text = 'before bash' }, { type = 'toolCall', id = 'bash-call', name = 'bash', arguments = { command = 'printf chunked-bash' } } } },
  { role = 'toolResult', toolCallId = 'bash-call', toolName = 'bash', content = bash_output },
}, 'Pi.dev chunked fold test', { chunk_size = 1, chunk_delay_ms = 1 })

assert(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
  return text:find('### Tool: bash printf chunked%-bash') ~= nil
end), 'chunked restored bash tool did not render')

local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local function line_number(exact)
  for index, line in ipairs(lines) do
    if line == exact then
      return index
    end
  end
  return nil
end

local function output_foldclosed(line)
  local value
  vim.api.nvim_win_call(state.ui.output_win, function()
    value = vim.fn.foldclosed(line)
  end)
  return value
end

local function assert_tool_fully_folded(header_text)
  local header = line_number(header_text)
  assert(header, table.concat(lines, '\n'))
  assert(output_foldclosed(header) == -1, header_text .. ' header must stay visible')
  local closing_fence
  for index = header + 1, #lines do
    if lines[index] == '````' then
      closing_fence = index
      break
    end
  end
  assert(closing_fence, 'missing closing fence after ' .. header_text .. '\n' .. table.concat(lines, '\n'))
  for line = header + 1, closing_fence do
    assert(output_foldclosed(line) ~= -1, header_text .. ' detail line should be hidden by auto-fold: line ' .. line .. ' = ' .. tostring(lines[line]))
  end
  if closing_fence + 1 <= #lines then
    assert(output_foldclosed(closing_fence + 1) == -1, header_text .. ' separator/next block after closing fence must stay visible')
  end
end

assert_tool_fully_folded('### Tool: read chunked-read.md')
assert_tool_fully_folded('### Tool: bash printf chunked-bash')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
