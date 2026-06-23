#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
-- Exercise session tree/fork flow.
require('pi-dev.config').options.session_render.max_messages = 3
require('pi-dev.config').options.session_render.chunk_delay_ms = 1
local rpc = require('pi-dev.rpc')
local ui = require('pi-dev.ui')
local state = require('pi-dev.state')
local renderer = require('pi-dev.renderer')
local old_session_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'entry-1', parentId = nil, timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'fork here' } }),
  vim.json.encode({ type = 'message', id = 'entry-2', parentId = 'other-branch', timestamp = '2026-01-02T00:00:00.000Z', message = { role = 'user', content = 'fork there from whole session tree' } }),
  vim.json.encode({ type = 'message', id = 'old-context', parentId = 'entry-2', timestamp = '2026-01-03T00:00:00.000Z', message = { role = 'user', content = 'WRONG FULL OLD CONTEXT' } }),
}, old_session_file)
local truncated_child_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), parentSession = old_session_file }),
  vim.json.encode({ type = 'message', id = 'entry-1', parentId = nil, timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'fork here' } }),
}, truncated_child_file)
state.session.current_file = truncated_child_file
local sent = {}
rpc.request = function(message, cb)
  table.insert(sent, message)
  if message.type == 'get_fork_messages' and cb then
    cb({ success = true, data = { messages = { { text = 'ACTIVE BRANCH ONLY', entryId = 'active-only' } } } })
  elseif message.type == 'switch_session' and cb then
    cb({ success = true, data = { cancelled = false } })
  elseif message.type == 'fork' and cb then
    cb({ success = true, data = { text = 'fork there from whole session tree' } })
  elseif message.type == 'get_state' and cb then
    cb({ success = true, data = { sessionFile = 'new-forked-session.jsonl', model = 'fake/model' } })
  elseif message.type == 'get_messages' and cb then
    local messages = {}
    for i = 1, 8 do
      table.insert(messages, { role = 'user', content = i == 1 and 'OLD SELECTED FORK CONTEXT' or ('selected fork context only ' .. i) })
    end
    cb({ success = true, data = { messages = messages } })
  end
  return message.type
end
renderer.clear('Tree test')
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should open')
assert(#sent == 0, 'tree should read whole root session file before falling back to active-branch RPC messages')
assert(state.ui.interaction.items[2].entry_id == 'entry-2', 'tree should include user messages from the whole root session file even after restart into a child session')
assert(state.ui.interaction.surface == 'output', 'tree interaction should use the large output/session buffer')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'tree interaction should not replace the input buffer')
assert(vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.tree_buf, 'tree interaction should render in the output buffer')
local first_cursor = vim.api.nvim_win_get_cursor(state.ui.output_win)[1]
vim.api.nvim_feedkeys('j', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction.selected == 2 end), 'j should move tree selection')
assert(vim.api.nvim_win_get_cursor(state.ui.output_win)[1] == first_cursor + 1, 'tree cursor should follow selected item downward')
local down = vim.api.nvim_replace_termcodes('<Down>', true, false, true)
local up = vim.api.nvim_replace_termcodes('<Up>', true, false, true)
vim.api.nvim_feedkeys(up, 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction.selected == 1 end), 'Up should move tree selection')
assert(vim.api.nvim_win_get_cursor(state.ui.output_win)[1] == first_cursor, 'tree cursor should follow selected item upward')
vim.api.nvim_feedkeys(down, 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction.selected == 2 end), 'Down should move tree selection')
vim.api.nvim_feedkeys('2', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil and sent[1].type == 'switch_session' end), 'tree selection should first switch back to the root session file')
assert(sent[1].sessionPath == old_session_file, 'tree should switch to whole root file before forking arbitrary tree entry')
assert(vim.wait(1000, function() return sent[2] ~= nil and sent[2].type == 'fork' end), 'tree selection should fork after loading root')
assert(sent[2].entryId == 'entry-2')
assert(vim.wait(1000, function() return sent[4] ~= nil and sent[4].type == 'get_messages' end), 'tree fork should render active fork context via RPC, not old session file')
assert(vim.wait(1000, function()
  local rendered = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
  return rendered:find('selected fork context only 8', 1, true) ~= nil
    and rendered:find('selected fork context only 6', 1, true) ~= nil
end), 'selected fork context should render')
local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(text:find('# Pi.dev session: selected fork context only 8', 1, true), text)
assert(text:find('selected fork context only 8', 1, true), text)
assert(text:find('selected fork context only 6', 1, true), text)
assert(text:find('OLD SELECTED FORK CONTEXT', 1, true) == nil, text)
assert(text:find('Showing latest 3/8 rendered messages', 1, true), text)
assert(text:find('WRONG FULL OLD CONTEXT', 1, true) == nil, text)
assert(state.session.current_file == 'new-forked-session.jsonl', 'tree should remember the active forked session file from get_state')
assert(ui.get_input_text() == 'fork there from whole session tree', 'fork response text should be restored into Pi input for editing')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'tree interaction should restore input buffer')
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree should reopen after selecting a fork point')
local reopened_labels = vim.inspect(state.ui.interaction.items)
assert(reopened_labels:find('fork here', 1, true), reopened_labels)
assert(reopened_labels:find('fork there from whole session tree', 1, true), reopened_labels)
assert(reopened_labels:find('WRONG FULL OLD CONTEXT', 1, true), reopened_labels)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
