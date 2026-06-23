#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 10, render = { fold_tool_output_over = 20 } } })

local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

ui.show()

local function output_lines()
  return vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
end

local function output_text()
  return table.concat(output_lines(), '\n')
end

local function line_number(needle, occurrence)
  occurrence = occurrence or 1
  local seen = 0
  for index, line in ipairs(output_lines()) do
    if line == needle then
      seen = seen + 1
      if seen == occurrence then
        return index
      end
    end
  end
  error('missing line ' .. needle .. ' occurrence ' .. tostring(occurrence) .. '\n' .. output_text())
end

local function foldclosed(line)
  return vim.api.nvim_win_call(state.ui.output_win, function()
    return vim.fn.foldclosed(line)
  end)
end

local function foldlevel(line)
  return vim.api.nvim_win_call(state.ui.output_win, function()
    return vim.fn.foldlevel(line)
  end)
end

local function thinking_text(prefix, count)
  local lines = {}
  for index = 1, count do
    table.insert(lines, prefix .. ' ' .. index)
  end
  return table.concat(lines, '\n')
end

local function assert_thinking_fold(header, body, should_close, label)
  local body_line = line_number('> ' .. body)
  assert(foldclosed(header) == -1, label .. ': thinking header must stay visible')
  assert(foldlevel(header + 1) > 0, label .. ': thinking detail should still be a fold block')
  if should_close then
    assert(foldclosed(header + 1) ~= -1, label .. ': thinking detail over 8 lines should auto-fold')
    assert(foldclosed(body_line) ~= -1, label .. ': long thinking body should be hidden')
  else
    assert(foldclosed(header + 1) == -1, label .. ': thinking detail at/below 8 lines should stay open')
    assert(foldclosed(body_line) == -1, label .. ': short thinking body should remain visible')
  end
end

renderer.render_messages({
  { role = 'assistant', content = { { type = 'thinking', thinking = thinking_text('restored short', 7) }, { type = 'text', text = 'after restored short' } } },
  { role = 'assistant', content = { { type = 'thinking', thinking = thinking_text('restored long', 8) }, { type = 'text', text = 'after restored long' } } },
}, 'Pi.dev thinking fold threshold restored')

local restored_short_header = line_number('> Thinking', 1)
local restored_long_header = line_number('> Thinking', 2)
assert_thinking_fold(restored_short_header, 'restored short 7', false, 'restored short')
assert_thinking_fold(restored_long_header, 'restored long 8', true, 'restored long')

renderer.clear('Pi.dev thinking fold threshold live short')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = thinking_text('live short', 7) } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'after live short' } })
renderer.flush_live_render()
local live_short_header = line_number('> Thinking', 1)
assert_thinking_fold(live_short_header, 'live short 7', false, 'live short')

renderer.clear('Pi.dev thinking fold threshold live long')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = thinking_text('live long', 8) } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'after live long' } })
renderer.flush_live_render()
local live_long_header = line_number('> Thinking', 1)
assert_thinking_fold(live_long_header, 'live long 8', true, 'live long')
LUA

pidev_run_lua_file "$tmp_lua"
