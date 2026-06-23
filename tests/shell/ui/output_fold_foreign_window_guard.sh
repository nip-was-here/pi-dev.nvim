#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 10 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()
renderer.clear('fold foreign win guard')
local long_output = table.concat(vim.tbl_map(function(i)
  return 'tool line ' .. i
end, vim.fn.range(1, 40)), '\n')
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'tool-1', toolName = 'bash', args = { command = 'printf long' } })
renderer.handle_event({ type = 'tool_execution_end', toolCallId = 'tool-1', toolName = 'bash', result = { content = { { type = 'text', text = long_output } } } })

local foreign = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(foreign, 0, -1, false, { 'foreign short buffer' })
vim.wo[state.ui.output_win].winfixbuf = false
vim.api.nvim_win_set_buf(state.ui.output_win, foreign)

local ok, err = pcall(function()
  renderer.handle_event({ type = 'tool_execution_end', toolCallId = 'tool-1', toolName = 'bash', result = { content = { { type = 'text', text = long_output .. '\nupdated' } } } })
end)
assert(ok, 'folding must not throw when output window temporarily contains a foreign buffer: ' .. tostring(err))

renderer.clear('thinking foreign win guard')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = 'thought one\nthought two' } })
renderer.flush_live_render()
vim.wo[state.ui.output_win].winfixbuf = false
vim.api.nvim_win_set_buf(state.ui.output_win, foreign)
ok, err = pcall(function()
  renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = '\nthought three' } })
  renderer.flush_live_render()
end)
assert(ok, 'thinking folding must not throw when output window temporarily contains a foreign buffer: ' .. tostring(err))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
