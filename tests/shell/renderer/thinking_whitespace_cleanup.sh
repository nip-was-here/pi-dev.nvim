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

local function rendered_lines()
  renderer.flush_pending_tool_renders()
  return vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
end

local function rendered_text()
  return table.concat(rendered_lines(), '\n')
end

local function assert_clean_thinking_lines(label)
  local lines = rendered_lines()
  for index, line in ipairs(lines) do
    if line:match('^>') then
      assert(not line:match('[ \t]$'), label .. ': thinking line has trailing whitespace at line ' .. index .. ': ' .. vim.inspect(line))
      assert(line ~= '>', label .. ': empty thinking quote line survived at line ' .. index)
      assert(line ~= '> ', label .. ': empty thinking quote line with a space survived at line ' .. index)
    end
  end
end

renderer.render_messages({
  {
    role = 'assistant',
    content = {
      {
        type = 'thinking',
        thinking = table.concat({
          'restored thought one   ',
          '',
          '> ',
          '> restored prequoted thought   ',
          'restored thought two\t ',
          '',
        }, '\n'),
      },
      { type = 'text', text = 'answer after restored thinking' },
    },
  },
  { role = 'thinking', content = 'role thought   \n> \nrole next\t ' },
}, 'Pi.dev restored thinking whitespace cleanup')

local text = rendered_text()
assert(text:find('> restored thought one\n', 1, true), text)
assert(text:find('> restored prequoted thought\n', 1, true), text)
assert(text:find('> restored thought two\n\nanswer after restored thinking', 1, true), text)
assert(text:find('> role thought\n', 1, true), text)
assert(text:find('> role next', 1, true), text)
assert(text:find('> restored thought one   ', 1, true) == nil, text)
assert(text:find('> restored prequoted thought   ', 1, true) == nil, text)
assert(text:find('> restored thought two\t ', 1, true) == nil, text)
assert(text:find('\n> \n', 1, true) == nil, text)
assert(text:find('\n>\n', 1, true) == nil, text)
assert_clean_thinking_lines('restored')

renderer.clear('Pi.dev live thinking whitespace cleanup')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = 'live thought one   \n\n> \n' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = 'live thought two ' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = 'continues   \n> live prequoted   \n> \n' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'answer after live thinking' } })
renderer.flush_live_render()

text = rendered_text()
assert(text:find('> live thought one\n', 1, true), text)
assert(text:find('> live thought two continues\n', 1, true), text)
assert(text:find('> live prequoted\n\nanswer after live thinking', 1, true), text)
assert(text:find('> live thought one   ', 1, true) == nil, text)
assert(text:find('> live thought two continues   ', 1, true) == nil, text)
assert(text:find('> live prequoted   ', 1, true) == nil, text)
assert(text:find('\n> \n', 1, true) == nil, text)
assert(text:find('\n>\n', 1, true) == nil, text)
assert_clean_thinking_lines('live')

renderer.clear('Pi.dev live thinking newline boundary cleanup')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = 'boundary thought   ' } })
renderer.flush_live_render()
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = '\nboundary next ' } })
renderer.flush_live_render()
text = rendered_text()
assert(text:find('> boundary thought\n', 1, true), text)
assert(text:find('> boundary thought   ', 1, true) == nil, text)
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = 'done   \n' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'answer after boundary thinking' } })
renderer.flush_live_render()
text = rendered_text()
assert(text:find('> boundary next done\n\nanswer after boundary thinking', 1, true), text)
assert(text:find('> boundary next done   ', 1, true) == nil, text)
assert_clean_thinking_lines('boundary')
LUA

pidev_run_lua_file "$tmp_lua"
