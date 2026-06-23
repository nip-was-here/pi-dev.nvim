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

ui.show()
renderer.clear('agent tool heading nesting')

local function text()
  renderer.flush_pending_tool_renders()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
end

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'agent-plain',
  toolName = 'agent',
  args = { task = 'Review renderer headers' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'agent-plain',
  toolName = 'agent',
  result = {
    content = {
      {
        type = 'text',
        text = table.concat({
          '# Agent headline',
          'agent body',
          '## Agent subheading',
          '####### Agent too deep',
          '```markdown',
          '# fenced heading stays literal',
          '```',
        }, '\n'),
      },
    },
  },
})

renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-raw',
  toolName = 'subagent',
  args = { agent = 'reviewer' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'subagent-raw',
  toolName = 'subagent',
  result = { content = { { type = 'text', text = '# Raw subagent headline\nraw body' } } },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'subagent-string-result',
  toolName = 'subagent',
  result = { results = { '####### Raw array subagent headline' } },
})

local rendered = text()
assert(rendered:find('### Tool: agent', 1, true), rendered)
assert(rendered:find('### Tool: subagent reviewer', 1, true), rendered)
assert(rendered:find('#### Result', 1, true), rendered)
assert(rendered:find('###### Details', 1, true) == nil, rendered)
assert(rendered:find('#######', 1, true) == nil, rendered)
assert(rendered:find('Agent headline', 1, true) == nil, rendered)
assert(rendered:find('Raw subagent headline', 1, true) == nil, rendered)

local first_child_line
for index, line in ipairs(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)) do
  if line == '##### subagent' then
    first_child_line = index
    break
  end
end
assert(first_child_line, rendered)
vim.api.nvim_set_current_win(state.ui.output_win)
vim.api.nvim_win_set_cursor(state.ui.output_win, { first_child_line, 0 })
vim.cmd('PiDevSubagentOpen')
local child = table.concat(vim.api.nvim_buf_get_lines(state.ui.subagent_view.buf, 0, -1, false), '\n')
assert(child:find('## Agent headline', 1, true), child)
assert(child:find('## Agent subheading', 1, true), child)
assert(child:find('###### Agent too deep', 1, true), child)
assert(child:find('```markdown\n# fenced heading stays literal\n```', 1, true), child)
assert(child:find('\n# Agent headline', 1, true) == nil, child)
assert(child:find('\n####### Agent too deep', 1, true) == nil, child)
LUA

pidev_run_lua_file "$tmp_lua"
