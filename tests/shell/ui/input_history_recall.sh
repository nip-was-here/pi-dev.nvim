#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()
renderer.render_messages({
  { role = 'user', content = 'first restored prompt' },
  { role = 'assistant', content = 'answer' },
  { role = 'user', content = 'second restored prompt' },
}, 'Pi.dev session: recall')
renderer.append_user('live prompt')

vim.api.nvim_set_current_win(state.ui.input_win)
ui.clear_input()

local pageup = vim.api.nvim_replace_termcodes('<PageUp>', true, false, true)
local pagedown = vim.api.nvim_replace_termcodes('<PageDown>', true, false, true)

vim.api.nvim_feedkeys(pageup, 'xt', false)
assert(vim.wait(1000, function() return ui.get_input_text() == 'live prompt' end), ui.get_input_text())

vim.api.nvim_feedkeys(pageup, 'xt', false)
assert(vim.wait(1000, function() return ui.get_input_text() == 'second restored prompt' end), ui.get_input_text())

vim.api.nvim_feedkeys(pagedown, 'xt', false)
assert(vim.wait(1000, function() return ui.get_input_text() == 'live prompt' end), ui.get_input_text())
vim.api.nvim_feedkeys(pagedown, 'xt', false)
assert(vim.wait(1000, function() return ui.get_input_text() == '' end), ui.get_input_text())
vim.api.nvim_feedkeys(pagedown, 'xt', false)
vim.wait(100)
assert(ui.get_input_text() == '', 'PageDown must stop on the final empty prompt slot')

ui.set_input_text('do not replace typed text')
vim.api.nvim_feedkeys(pageup, 'xt', false)
vim.wait(100)
assert(ui.get_input_text() == 'do not replace typed text', ui.get_input_text())

ui.clear_input()
vim.api.nvim_feedkeys(pagedown, 'xt', false)
assert(vim.wait(1000, function() return ui.get_input_text() == 'first restored prompt' end), ui.get_input_text())
vim.api.nvim_feedkeys(pageup, 'xt', false)
vim.wait(100)
assert(ui.get_input_text() == 'first restored prompt', 'PageUp must not wrap from oldest to newest')

renderer.clear('Pi.dev branch recall test')
local root_file = vim.fn.tempname()
local child_file = vim.fn.tempname()
local sibling_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
  vim.json.encode({ type = 'message', id = 'sibling-user', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'sibling prompt must stay hidden' } }),
}, root_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'child', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:04.000Z' }),
  vim.json.encode({ type = 'message', id = 'child-user', parentId = 'a1', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'user', content = 'child branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'child-answer', parentId = 'child-user', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'assistant', content = 'child answer' } }),
}, child_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'sibling', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:06.000Z' }),
  vim.json.encode({ type = 'message', id = 'other-user', parentId = 'a1', timestamp = '2026-01-01T00:00:06.000Z', message = { role = 'user', content = 'other sibling prompt must stay hidden' } }),
}, sibling_file)
state.session.current_file = child_file
ui.clear_input()
vim.api.nvim_feedkeys(pageup, 'xt', false)
assert(vim.wait(1000, function() return ui.get_input_text() == 'child branch prompt' end), ui.get_input_text())
vim.api.nvim_feedkeys(pageup, 'xt', false)
assert(vim.wait(1000, function() return ui.get_input_text() == 'root branch prompt' end), ui.get_input_text())
vim.api.nvim_feedkeys(pageup, 'xt', false)
vim.wait(100)
assert(ui.get_input_text() == 'root branch prompt', 'PageUp must stop at the branch root prompt')
vim.api.nvim_feedkeys(pagedown, 'xt', false)
assert(vim.wait(1000, function() return ui.get_input_text() == 'child branch prompt' end), ui.get_input_text())
vim.api.nvim_feedkeys(pagedown, 'xt', false)
assert(vim.wait(1000, function() return ui.get_input_text() == '' end), ui.get_input_text())
vim.api.nvim_feedkeys(pageup, 'xt', false)
assert(vim.wait(1000, function() return ui.get_input_text() == 'child branch prompt' end), ui.get_input_text())
assert(ui.get_input_text() ~= 'sibling prompt must stay hidden')
assert(ui.get_input_text() ~= 'other sibling prompt must stay hidden')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
