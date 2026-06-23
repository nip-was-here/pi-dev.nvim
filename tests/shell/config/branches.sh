#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local config = require('pi-dev.config')
local ok, err = pcall(config.setup, { executable = 'pi' })
assert(not ok and tostring(err):find('executable was renamed to exec.bin', 1, true), tostring(err))
ok, err = pcall(config.setup, { args = { '--debug' } })
assert(not ok and tostring(err):find('args was renamed to exec.args', 1, true), tostring(err))
ok, err = pcall(config.setup, { rpc = { args = { '--mode', 'rpc' } } })
assert(not ok and tostring(err):find('rpc.args was renamed to exec.args', 1, true), tostring(err))
ok, err = pcall(config.setup, { exec = { bin = 42 } })
assert(not ok and tostring(err):find('exec.bin must be a string or argv table', 1, true), tostring(err))
ok, err = pcall(config.setup, { exec = { args = 'bad' } })
assert(not ok and tostring(err):find('exec.args must be a list', 1, true), tostring(err))
assert(config.defaults.rpc.idle_timeout_ms == 180000, 'default RPC idle timeout should be 3 minutes')
config.setup({
  exec = { bin = { 'custom-pi' }, args = { '--mode', 'rpc', '--profile', 'test', '--debug' } },
})
local command = table.concat(config.command({ '--extra' }), ' ')
assert(command == 'custom-pi --mode rpc --profile test --debug --extra', command)
assert(config.options.rpc.idle_timeout_ms == 180000, 'partial rpc setup should preserve 3-minute idle timeout default')

require('pi-dev').setup({
  keymaps = { enable = false },
  ui = {
    position = 'bottom',
    height = 8,
    input_height = 3,
    statusline = { enable = false },
    render = { show_tool_arguments = false, show_thinking = false, show_stderr = false },
  },
})
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
ui.show()
assert(vim.api.nvim_win_is_valid(state.ui.output_win))
assert(vim.api.nvim_win_is_valid(state.ui.input_win))
assert(state.ui.status_win == nil or not vim.api.nvim_win_is_valid(state.ui.status_win), 'status separator should not open when disabled')
assert(vim.api.nvim_win_get_height(state.ui.input_win) == 3, 'bottom input height should be configurable')

renderer.clear('Config branch render')
renderer.render_messages({
  { role = 'assistant', content = { { type = 'thinking', thinking = 'hidden thinking' }, { type = 'text', text = 'visible answer' } } },
  { role = 'thinking', content = 'hidden role thinking' },
  { role = 'reasoning', content = 'hidden role reasoning' },
}, 'Config branch render')
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'tool-1', toolName = 'bash', args = { command = 'echo hidden args' } })
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('visible answer', 1, true), text)
assert(text:find('hidden thinking', 1, true) == nil, text)
assert(text:find('hidden role thinking', 1, true) == nil, text)
assert(text:find('hidden role reasoning', 1, true) == nil, text)
assert(text:find('echo hidden args', 1, true) == nil, text)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
