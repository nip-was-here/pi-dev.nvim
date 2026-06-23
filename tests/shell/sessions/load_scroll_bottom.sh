#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({
  keymaps = { enable = false },
  session_render = { max_messages = 20, chunk_size = 5, chunk_delay_ms = 1, chunk_budget_ms = 0 },
  ui = { width = 80, input_height = 8 },
})
local ui = require('pi-dev.ui')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')

ui.show()
local session_file = vim.fn.tempname()
local lines = {
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
}
for i = 1, 30 do
  table.insert(lines, vim.json.encode({
    type = 'message',
    id = 'm' .. tostring(i),
    timestamp = '2026-01-01T00:00:' .. string.format('%02d', i % 60) .. '.000Z',
    message = { role = 'user', content = 'loaded scroll message ' .. tostring(i) },
  }))
end
local long_tool_result = table.concat(vim.tbl_map(function(i)
  return 'loaded final tool line ' .. tostring(i)
end, vim.fn.range(1, 40)), '\n')
table.insert(lines, vim.json.encode({
  type = 'message',
  id = 'm31',
  parentId = 'm30',
  timestamp = '2026-01-01T00:00:31.000Z',
  message = {
    role = 'assistant',
    content = { { type = 'toolCall', id = 'final-tool', name = 'bash', arguments = { command = 'printf loaded-final-tool' } } },
  },
}))
table.insert(lines, vim.json.encode({
  type = 'message',
  id = 'm32',
  parentId = 'm31',
  timestamp = '2026-01-01T00:00:32.000Z',
  message = { role = 'toolResult', toolCallId = 'final-tool', toolName = 'bash', content = long_tool_result },
}))
vim.fn.writefile(lines, session_file)
state.session.current_file = session_file

-- /tree and /waiting use the output surface as their picker. When Enter closes
-- that picker, the output window is still focused at the old tree cursor. A
-- session/branch load should override the normal "preserve focused output"
-- behavior and land on the bottom after the paged render completes.
vim.api.nvim_set_current_win(state.ui.output_win)
vim.api.nvim_win_set_cursor(state.ui.output_win, { 1, 0 })
sessions.render_current('Loaded scroll test', session_file)
assert(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
  return text:find('loaded scroll message 30', 1, true) ~= nil
    and text:find('loaded final tool line 40', 1, true) ~= nil
end), 'session load did not render the final message')
local function line_number(pattern)
  local rendered = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
  for index, line in ipairs(rendered) do
    if line:find(pattern, 1, true) then
      return index
    end
  end
end
local tool_header = line_number('### Tool: bash printf loaded-final-tool')
assert(tool_header, table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'))
assert(vim.wait(1000, function()
  return vim.api.nvim_win_call(state.ui.output_win, function()
    return vim.fn.foldclosed(tool_header + 1) ~= -1
  end)
end), 'session load should apply the latest auto-fold before final scrolling')
assert(vim.wait(1000, function()
  return vim.api.nvim_win_call(state.ui.output_win, function()
    local last = vim.api.nvim_buf_line_count(state.ui.output_buf)
    local expected = vim.fn.foldclosed(last)
    if expected == -1 then
      expected = last
    end
    local cursor = vim.api.nvim_win_get_cursor(state.ui.output_win)
    return cursor[1] == expected
  end)
end), 'session load should scroll focused output to the post-autofold bottom after rendering')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
