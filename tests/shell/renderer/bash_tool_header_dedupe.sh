#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 10 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local ext = require('pi-dev.extension_ui')
local state = require('pi-dev.state')

require('pi-dev.rpc').write = function()
  return true
end

ui.show()
renderer.clear('bash no-id dedupe')

renderer.handle_event({
  type = 'tool_execution_start',
  toolName = 'bash',
  args = { command = 'echo duplicated header' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  result = { content = { { type = 'text', text = 'done' } } },
})

local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local _, count = text:gsub('### Tool: bash echo duplicated header', '')
assert(count == 1, text)
assert(text:find('_done_', 1, true), text)
assert(text:find('done', 1, true), text)

renderer.handle_event({
  type = 'tool_execution_start',
  toolName = 'bash',
  args = { command = 'echo second command' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolName = 'bash',
  result = { content = { { type = 'text', text = 'second done' } } },
})

text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local _, first_count = text:gsub('### Tool: bash echo duplicated header', '')
local _, second_count = text:gsub('### Tool: bash echo second command', '')
assert(first_count == 1, text)
assert(second_count == 1, text)

renderer.clear('bash permission result header')
local command = 'chmod u+x tests/shell/sessions/redundant_switch_notify.sh && ./tests/shell/sessions/redundant_switch_notify.sh'
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'bash-before-permission',
  toolName = 'bash',
  args = { command = command },
})
renderer.append_permission_request('bash-permission', 'bash `chmod *`', {
  '**Permission Required**',
  '',
  'Pi requested bash command.',
})
renderer.finish_permission_request('bash-permission', 'Yes')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'bash-result-after-permission',
  toolName = 'bash',
  args = { command = command },
  result = { content = { { type = 'text', text = '(no output)' } } },
})

text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local _, top_level_bash_count = text:gsub('### Tool: bash', '')
local _, result_header_count = text:gsub('#### Result:', '')
assert(top_level_bash_count == 1, text)
assert(result_header_count == 1, text)
assert(text:find('#### Permission request: bash `chmod *` - Yes', 1, true), text)
assert(text:find('#### Result:\n\n_done_', 1, false), text)
assert(text:find('(no output)', 1, true), text)

renderer.clear('bash permission result without repeated args')
ui.focus_input()
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'bash-start-no-end-args',
  toolName = 'bash',
  args = { command = 'echo permission gap' },
})
ext.handle_request({
  type = 'extension_ui_request',
  id = 'bash-permission-no-end-args',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'echo permission gap'. Allow this command?",
  options = { 'Yes', 'No', 'No, provide reason' },
})
assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil
end), 'permission interaction did not render')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction == nil
end), 'permission interaction did not close')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'bash-end-no-args',
  toolName = 'bash',
  result = { content = { { type = 'text', text = 'permission output' } } },
})

text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
top_level_bash_count = select(2, text:gsub('### Tool: bash', ''))
assert(top_level_bash_count == 1, text)
assert(text:find('#### Permission request: bash `echo permission gap` - Yes', 1, true), text)
assert(text:find('permission output', 1, true), text)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
