#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({
  keymaps = { enable = false },
  session_render = { max_messages = false, chunk_size = 100, chunk_delay_ms = 1 },
  ui = { width = 90, input_height = 8, session_title_branch_fraction = 0.5 },
})
local ui = require('pi-dev.ui')
local sessions = require('pi-dev.sessions')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local config = require('pi-dev.config')

ui.show()

local function output_text()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
end

local function output_header()
  return vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''
end

local function winbar_title()
  return vim.wo[state.ui.output_win].winbar or state.ui.output_title or ''
end

local duplicate_root = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'dup-u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'repeat this exact prompt' } }),
  vim.json.encode({ type = 'message', id = 'dup-a1', parentId = 'dup-u1', timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'assistant', content = 'first answer' } }),
  vim.json.encode({ type = 'message', id = 'dup-u2', parentId = 'dup-a1', timestamp = '2026-01-01T00:02:00.000Z', message = { role = 'user', content = 'repeat this exact prompt' } }),
}, duplicate_root)

sessions.render_current('Pi.dev session', duplicate_root)
assert(vim.wait(1000, function()
  return output_header():find('# Pi.dev session: repeat this exact prompt', 1, true) ~= nil
end), output_text())
assert(vim.wait(1000, function()
  local title = winbar_title()
  return title:find('^ Pi chat: ') and title:find(' | ', 1, true)
end), 'duplicate first/second user turns must still show branch and latest in chat title: ' .. winbar_title())
assert(not winbar_title():find('  |', 1, true), 'chat title separator should not be pushed right by padding: ' .. winbar_title())

local long_branch = 'branch title alpha beta gamma delta epsilon zeta eta theta iota kappa lambda'
local long_latest = 'latest message one two three four five six seven eight nine ten eleven twelve'
config.options.ui.session_title_branch_fraction = 0.3
renderer.update_session_title(long_branch, { force = true })
renderer.update_session_header_user(long_latest)
assert(vim.wait(1000, function()
  return winbar_title():find('branch tit', 1, true) and winbar_title():find('latest message', 1, true)
end), winbar_title())
local fraction_title = winbar_title()
assert(fraction_title:find(' | ', 1, true), fraction_title)
assert(not fraction_title:find('  |', 1, true), 'fractional chat title should keep compact separator: ' .. fraction_title)
local before_pipe, after_pipe = fraction_title:match('^%s*Pi chat:%s*(.-)%s|%s(.+)%s*$')
assert(before_pipe and after_pipe, fraction_title)
assert(before_pipe:find('...', 1, true), before_pipe)
assert(after_pipe:find('...', 1, true), after_pipe)
assert(vim.fn.strdisplaywidth(before_pipe) < vim.fn.strdisplaywidth(after_pipe), fraction_title)
assert(vim.fn.strdisplaywidth(fraction_title) <= require('pi-dev.format').window_text_width(state.ui.output_win), fraction_title)

local assistant_first_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'assistant-first', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'assistant', content = 'Raw markdown & no line before some header' } }),
  vim.json.encode({ type = 'message', id = 'user-later', parentId = 'assistant-first', timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'user', content = 'real user prompt should name chat' } }),
}, assistant_first_file)
sessions.render_current('Pi.dev session', assistant_first_file)
assert(vim.wait(1000, function()
  local title = winbar_title()
  return title:find('^ Pi chat: ') and title:find('real user prompt should name chat', 1, true)
end), 'chat title should come from user chat prompts, not assistant/raw markdown text: ' .. winbar_title())
assert(not winbar_title():find('Raw markdown', 1, true), 'assistant text leaked into chat title: ' .. winbar_title())

renderer.clear('Pi chat')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'assistant stream must not become a random chat title prefix' } })
renderer.flush_live_render()
assert(vim.wait(1000, function()
  return winbar_title():find('Pi chat', 1, true) ~= nil
end), 'assistant-only streaming should not rewrite chat title from first answer fragments: ' .. winbar_title())
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
