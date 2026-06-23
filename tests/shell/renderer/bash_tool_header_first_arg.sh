#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 72, input_height = 10 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

local function output_text()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
end

local function render_tool(id, name, args)
  renderer.clear('Pi.dev tool header truncation test')
  renderer.handle_event({
    type = 'tool_execution_start',
    toolCallId = id,
    toolName = name,
    args = args,
  })
  return output_text()
end

ui.show()

local text = render_tool('bash-rg', 'bash', { command = 'rg -n "needle" lua' })
assert(text:find('### Tool: bash rg -n "needle" lua', 1, true), text)
assert(text:find('```bash\nrg -n "needle" lua\n```', 1, true), text)

text = render_tool('bash-nl', 'bash', { command = 'nl -ba lua/pi-dev/renderer.lua' })
assert(text:find('### Tool: bash nl -ba lua/pi-dev/renderer.lua', 1, true), text)

text = render_tool('bash-echo', 'bash', { command = 'echo hello world' })
assert(text:find('### Tool: bash echo hello world', 1, true), text)

text = render_tool('bash-script', 'bash', { command = 'bash ./tests/run.sh' })
assert(text:find('### Tool: bash bash ./tests/run.sh', 1, true), text)

text = render_tool('bash-script-wrapper', 'bash', {
  command = './tmp/pi-dev-test/pi-dev-runner.sh',
  args = { './tests/run.sh', '--verbose' },
})
local wrapper_header = text:match('(### Tool: bash[^\n]+)')
assert(wrapper_header and wrapper_header:find('./tmp/pi-dev-test/pi-dev-runner', 1, true), text)
assert(wrapper_header:find('...', 1, true), wrapper_header)
assert(vim.fn.strdisplaywidth(wrapper_header) <= require('pi-dev.format').window_text_width(state.ui.output_win) - 6, wrapper_header)
assert(wrapper_header:find('--verbose', 1, true) == nil, wrapper_header)

text = render_tool('bash-long', 'bash', {
  command = 'rg --line-number --hidden --glob "*.lua" extremely-long-search-term-that-should-not-fit-on-one-header-line lua/pi-dev',
})
local long_header = text:match('(### Tool: bash[^\n]+)')
assert(long_header and long_header:find('...', 1, true), text)
assert(vim.fn.strdisplaywidth(long_header) <= require('pi-dev.format').window_text_width(state.ui.output_win) - 6, long_header)
assert(text:find('```bash\nrg --line-number --hidden', 1, true), text)

text = render_tool('bash-user-reported', 'bash', {
  command = './tests/shell/renderer/unified_history_and_diff.sh && ./tests/shell/sessions/restore_paged_render.sh',
})
local reported_header = text:match('(### Tool: bash[^\n]+)')
assert(reported_header and reported_header:find('...', 1, true), text)
assert(vim.fn.strdisplaywidth(reported_header) <= require('pi-dev.format').window_text_width(state.ui.output_win) - 6, reported_header)
assert(text:find('```bash\n./tests/shell/renderer/unified_history_and_diff.sh && ./tests/shell/sessions/restore_paged_render.sh\n```', 1, true), text)

text = render_tool('bash-multiline', 'bash', {
  command = 'printf first\r\nsecond line with enough words to force a header truncation after normalization\nthird line',
})
local multiline_header = text:match('(### Tool: bash[^\n]+)')
assert(multiline_header and multiline_header:find('printf first second line', 1, true), text)
assert(multiline_header:find('...', 1, true), multiline_header)
assert(multiline_header:find('\r', 1, true) == nil, multiline_header)
assert(multiline_header:find('\n', 1, true) == nil, multiline_header)
assert(vim.fn.strdisplaywidth(multiline_header) <= require('pi-dev.format').window_text_width(state.ui.output_win) - 6, multiline_header)
assert(text:find('```bash\nprintf first\nsecond line with enough words to force a header truncation after normalization\nthird line\n```', 1, true), text)

text = render_tool('write-long', 'write', {
  path = 'very/long/path/that/should/be/truncated/before/it/can/wrap/in/the/tool/header/azaza.txt',
  content = 'body',
})
local write_header = text:match('(### Tool: write[^\n]+)')
assert(write_header and write_header:find('...', 1, true), text)
assert(vim.fn.strdisplaywidth(write_header) <= require('pi-dev.format').window_text_width(state.ui.output_win) - 6, write_header)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
