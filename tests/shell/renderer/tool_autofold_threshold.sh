#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local fold_threshold = 12
local default_threshold = require('pi-dev.config').defaults.ui.render.fold_tool_output_over
assert(default_threshold == 20, 'default fold threshold should be 20 rendered detail lines, got ' .. tostring(default_threshold))

require('pi-dev').setup({
  keymaps = { enable = false },
  ui = {
    width = 80,
    input_height = 10,
    render = { fold_tool_output_over = fold_threshold },
  },
})

local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()

local function output_text()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
end

local function output_lines()
  return vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
end

local function line_number(exact)
  for index, line in ipairs(output_lines()) do
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

local function foldlevel(line)
  local value
  vim.api.nvim_win_call(state.ui.output_win, function()
    value = vim.fn.foldlevel(line)
  end)
  return value
end

local function generated_lines(count, prefix)
  local lines = {}
  for index = 1, count do
    table.insert(lines, prefix .. ' line ' .. index)
  end
  return table.concat(lines, '\n')
end

local function assert_tool_fold(header, expected_folded)
  local header_line = line_number(header)
  assert(header_line, 'missing header ' .. header .. '\n' .. output_text())
  assert(foldclosed(header_line) == -1, 'tool header must stay visible: ' .. header)
  local detail_line = header_line + 1
  assert(foldlevel(detail_line) > 0, 'every tool detail body should be a fold block, even when open: ' .. header .. '\n' .. output_text())
  if expected_folded then
    assert(foldclosed(detail_line) ~= -1, 'detail should auto-fold only when rendered detail lines exceed config value: ' .. header .. '\n' .. output_text())
  else
    assert(foldclosed(detail_line) == -1, 'detail at/below config value must stay open: ' .. header .. '\n' .. output_text())
  end
end

-- Finished bash tools render detail as: compact status + blank + command fence block + blank + output fence block.
-- Restored read tools render detail as: status + blank + output fence block.
local bash_exactly_threshold_output_lines = fold_threshold - 9
local bash_over_threshold_output_lines = fold_threshold - 8
local read_exactly_threshold_output_lines = fold_threshold - 5
local read_over_threshold_output_lines = fold_threshold - 4

renderer.clear('live exact threshold')
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'live-exact', toolName = 'bash', args = { command = 'printf live-exact' } })
renderer.handle_event({ type = 'tool_execution_end', toolCallId = 'live-exact', toolName = 'bash', result = { content = { { type = 'text', text = generated_lines(bash_exactly_threshold_output_lines, 'live exact') } } } })
assert_tool_fold('### Tool: bash printf live-exact', false)

renderer.clear('live over threshold')
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'live-over', toolName = 'bash', args = { command = 'printf live-over' } })
renderer.handle_event({ type = 'tool_execution_end', toolCallId = 'live-over', toolName = 'bash', result = { content = { { type = 'text', text = generated_lines(bash_over_threshold_output_lines, 'live over') } } } })
assert_tool_fold('### Tool: bash printf live-over', true)

renderer.render_messages({
  { role = 'assistant', content = { { type = 'text', text = 'before restored exact' }, { type = 'toolCall', id = 'read-exact', name = 'read', arguments = { path = 'restored-exact.txt' } } } },
  { role = 'toolResult', toolCallId = 'read-exact', toolName = 'read', content = vim.json.encode({ path = 'restored-exact.txt', content = generated_lines(read_exactly_threshold_output_lines, 'restored exact') }) },
}, 'restored exact threshold')
assert_tool_fold('### Tool: read restored-exact.txt', false)

renderer.render_messages({
  { role = 'assistant', content = { { type = 'text', text = 'before restored over' }, { type = 'toolCall', id = 'read-over', name = 'read', arguments = { path = 'restored-over.txt' } } } },
  { role = 'toolResult', toolCallId = 'read-over', toolName = 'read', content = vim.json.encode({ path = 'restored-over.txt', content = generated_lines(read_over_threshold_output_lines, 'restored over') }) },
}, 'restored over threshold')
assert_tool_fold('### Tool: read restored-over.txt', true)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
