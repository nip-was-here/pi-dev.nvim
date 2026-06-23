#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
local root_file = session_root .. '/root.jsonl'
local function enc(value)
  return vim.json.encode(value)
end
vim.fn.writefile({
  enc({ type = 'session', version = 3, id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  enc({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'root prompt' } }),
  enc({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'root answer' } }),
  enc({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'inactive leaf branch prompt' } }),
  enc({ type = 'message', id = 'a2', parentId = 'u2', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'inactive leaf branch answer' } }),
  enc({ type = 'message', id = 'u3', parentId = 'a1', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'user', content = 'forking branch prompt' } }),
  enc({ type = 'message', id = 'a3', parentId = 'u3', timestamp = '2026-01-01T00:00:06.000Z', message = { role = 'assistant', content = 'forking branch answer' } }),
  enc({ type = 'message', id = 'u4', parentId = 'a3', timestamp = '2026-01-01T00:00:07.000Z', message = { role = 'user', content = 'runtime leaf branch prompt' } }),
  enc({ type = 'message', id = 'a4', parentId = 'u4', timestamp = '2026-01-01T00:00:08.000Z', message = { role = 'assistant', content = 'runtime leaf branch answer' } }),
  enc({ type = 'message', id = 'u5', parentId = 'a3', timestamp = '2026-01-01T00:00:09.000Z', message = { role = 'user', content = 'nested leaf branch prompt' } }),
  enc({ type = 'message', id = 'a5', parentId = 'u5', timestamp = '2026-01-01T00:00:10.000Z', message = { role = 'assistant', content = 'nested leaf branch answer' } }),
  enc({ type = 'message', id = 'u6', parentId = 'a1', timestamp = '2026-01-01T00:00:11.000Z', message = { role = 'user', content = 'current leaf branch prompt' } }),
  enc({ type = 'message', id = 'a6', parentId = 'u6', timestamp = '2026-01-01T00:00:12.000Z', message = { role = 'assistant', content = 'current leaf branch answer' } }),
}, root_file)

require('pi-dev').setup({ keymaps = { enable = false }, session_root = session_root })
local api = require('pi-dev.api')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

rpc.request = function(message, cb)
  if cb then
    cb({ success = true, data = {} })
  end
  return message.type
end
state.session.current_file = root_file
local runtime = state.ensure_rpc_runtime('runtime-leaf')
runtime.branch_root = root_file
runtime.branch_entry_id = 'u4'
runtime.waiting_input = true
runtime.status = 'waiting input'
ui.show()
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should open')

local function item_index(fragment)
  for index, item in ipairs(state.ui.interaction.items or {}) do
    if tostring(item.label or ''):find(fragment, 1, true) then
      return index
    end
  end
end
local inactive_index = assert(item_index('inactive leaf branch prompt'))
local forking_index = assert(item_index('forking branch prompt'))
local runtime_index = assert(item_index('runtime leaf branch prompt'))
local current_index = assert(item_index('current leaf branch prompt'))
local inactive_line = state.ui.interaction.item_line_by_index[inactive_index]
local forking_line = state.ui.interaction.item_line_by_index[forking_index]
local runtime_line = state.ui.interaction.item_line_by_index[runtime_index]
local current_line = state.ui.interaction.item_line_by_index[current_index]
vim.api.nvim_win_call(state.ui.output_win, function()
  assert(vim.fn.foldclosed(inactive_line) == -1, 'first inactive leaf branch row should stay visible')
  assert(vim.fn.foldclosed(forking_line) == -1, 'first forking branch row should stay visible')
  assert(vim.fn.foldclosed(runtime_line) == -1, 'first runtime branch row should stay visible')
  assert(vim.fn.foldclosed(current_line) == -1, 'first current branch row should stay visible')
  assert((state.ui.interaction.fold_start_lines or {})[inactive_line] ~= true, 'inactive leaf first row must not be a fold start')
  assert((state.ui.interaction.fold_start_lines or {})[forking_line] ~= true, 'forking branch first row must not be a fold start')
  local forking_answer_line = state.ui.interaction.item_line_by_index[assert(item_index('Assistant: forking branch answer'))]
  assert((state.ui.interaction.fold_start_lines or {})[forking_answer_line] == true, 'forking branch fold should start at its next response')
  local label = (state.ui.interaction.fold_labels or {})[forking_answer_line] or ''
  assert(label:find('runtime leaf bran', 1, true), label)
  assert(label:find('forking branch answer', 1, true) == nil, label)
end)
LUA

pidev_run_lua_file "$tmp_lua"
