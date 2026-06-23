#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({
  keymaps = { enable = false },
  ui = { width = 44, input_height = 10, render = { fold_tool_output_over = 20 } },
})

local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()

local long_line = string.rep('wrapped-read-output ', 12)
local content = table.concat({
  long_line .. 'one',
  long_line .. 'two',
  long_line .. 'three',
  long_line .. 'four',
  long_line .. 'five',
}, '\n')

renderer.clear('read visual fold test')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'wrapped-read',
  toolName = 'read',
  args = { path = 'tests/fixtures/wrapped-read-output.txt' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'wrapped-read',
  toolName = 'read',
  result = { content = { { type = 'text', text = vim.json.encode({ path = 'tests/fixtures/wrapped-read-output.txt', content = content }) } } },
})
renderer.flush_pending_tool_renders()

local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local function line_number(exact)
  for index, line in ipairs(lines) do
    if line == exact or line:find(exact, 1, true) then
      return index
    end
  end
  return nil
end

local function foldclosed(line)
  local value
  vim.api.nvim_win_call(state.ui.output_win, function()
    value = vim.fn.foldclosed(line)
  end)
  return value
end

local header = line_number('### Tool: read')
assert(header, table.concat(lines, '\n'))
assert(foldclosed(header) == -1, 'read tool header must stay visible')
assert(foldclosed(header + 1) ~= -1, 'long wrapped read output should auto-fold by visible rendered rows, not only physical buffer lines')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
