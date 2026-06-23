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
  enc({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'main branch prompt' } }),
  enc({ type = 'message', id = 'a2', parentId = 'u2', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'main branch answer' } }),
  enc({ type = 'message', id = 'u3', parentId = 'a1', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'user', content = 'side branch prompt' } }),
  enc({ type = 'message', id = 'a3', parentId = 'u3', timestamp = '2026-01-01T00:00:06.000Z', message = { role = 'assistant', content = 'side branch answer' } }),
  enc({ type = 'message', id = 'u4', parentId = 'a3', timestamp = '2026-01-01T00:00:07.000Z', message = { role = 'user', content = 'side continuation prompt' } }),
  enc({ type = 'message', id = 'a4', parentId = 'u4', timestamp = '2026-01-01T00:00:08.000Z', message = { role = 'assistant', content = 'side continuation answer' } }),
  enc({ type = 'message', id = 'u5', parentId = 'a3', timestamp = '2026-01-01T00:00:09.000Z', message = { role = 'user', content = 'side subbranch prompt' } }),
  enc({ type = 'message', id = 'a5', parentId = 'u5', timestamp = '2026-01-01T00:00:10.000Z', message = { role = 'assistant', content = 'side subbranch answer' } }),
  enc({ type = 'message', id = 'u6', parentId = 'a1', timestamp = '2026-01-01T00:00:11.000Z', message = { role = 'user', content = 'other branch prompt' } }),
  enc({ type = 'message', id = 'a6', parentId = 'u6', timestamp = '2026-01-01T00:00:12.000Z', message = { role = 'assistant', content = 'other branch answer' } }),
}, root_file)

require('pi-dev').setup({ keymaps = { enable = false }, session_root = session_root })
local api = require('pi-dev.api')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local requests = {}
rpc.request = function(message, cb)
  table.insert(requests, message)
  if cb then
    cb({ success = true, data = {} })
  end
  return message.type
end
state.session.current_file = root_file
local neighboring_runtime = state.ensure_rpc_runtime('neighboring-runtime')
neighboring_runtime.branch_root = root_file
neighboring_runtime.branch_entry_id = 'u5'
neighboring_runtime.waiting_input = true
neighboring_runtime.status = 'waiting input'
ui.show()
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should open')
assert(state.ui.interaction.surface == 'output', 'tree should render in output surface')

local function item_index(fragment)
  for index, item in ipairs(state.ui.interaction.items or {}) do
    if tostring(item.label or ''):find(fragment, 1, true) then
      return index
    end
  end
end
local root_index = item_index('root prompt')
local root_answer_index = item_index('Assistant: root answer')
local main_index = item_index('main branch prompt')
local side_index = item_index('side branch prompt')
local side_answer_index = item_index('Assistant: side branch answer')
local continuation_index = item_index('side continuation prompt')
local continuation_answer_index = item_index('Assistant: side continuation answer')
local sub_index = item_index('side subbranch prompt')
local sub_answer_index = item_index('Assistant: side subbranch an')
local other_index = item_index('other branch prompt')
assert(root_index and root_answer_index and main_index and side_index and side_answer_index and continuation_index and continuation_answer_index and sub_index and sub_answer_index and other_index, vim.inspect(state.ui.interaction.items))

local tree_win = state.ui.output_win
local tree_buf = vim.api.nvim_win_get_buf(tree_win)
local function item_line(index)
  return state.ui.interaction.item_line_by_index[index]
end
local root_line = item_line(root_index)
local root_answer_line = item_line(root_answer_index)
local main_line = item_line(main_index)
local side_line = item_line(side_index)
local side_answer_line = item_line(side_answer_index)
local continuation_line = item_line(continuation_index)
local continuation_answer_line = item_line(continuation_answer_index)
local sub_line = item_line(sub_index)
local sub_answer_line = item_line(sub_answer_index)
local other_line = item_line(other_index)
assert(root_line and root_answer_line and main_line and side_line and side_answer_line and continuation_line and continuation_answer_line and sub_line and sub_answer_line and other_line, vim.inspect(state.ui.interaction.item_line_by_index))

vim.api.nvim_win_call(tree_win, function()
  assert(vim.fn.foldlevel(root_line) == 0, 'first root branch row should not be inside a fold')
  assert(vim.fn.foldclosed(side_line) == -1, 'first side branch row should stay visible')
  assert(vim.fn.foldclosed(sub_line) == -1, 'first sub-branch row should stay visible')
  assert(vim.fn.foldclosed(main_line) == -1, 'first main leaf row should stay visible')
  assert(vim.fn.foldclosed(other_line) == -1, 'first current leaf row should stay visible')
  assert(vim.fn.foldclosed(root_answer_line) == -1, 'root branch details should stay open by default')
  assert(vim.fn.foldclosed(side_answer_line) == -1, 'branch details with visible sub-branches should stay open by default')
  assert((state.ui.interaction.fold_start_lines or {})[root_line] ~= true, 'first root branch row must not be a fold start')
  assert((state.ui.interaction.fold_start_lines or {})[side_line] ~= true, 'first side branch row must not be a fold start')
  assert((state.ui.interaction.fold_start_lines or {})[sub_line] ~= true, 'first sub-branch row must not be a fold start')
  assert((state.ui.interaction.fold_start_lines or {})[main_line] ~= true, 'first main leaf row must not be a fold start')
  assert((state.ui.interaction.fold_start_lines or {})[other_line] ~= true, 'first current leaf row must not be a fold start')
  assert((state.ui.interaction.fold_start_lines or {})[root_answer_line] == true, 'root branch fold should start at the next response')
  assert((state.ui.interaction.fold_start_lines or {})[side_answer_line] == true, 'side branch fold should start at the next response')
  vim.api.nvim_win_set_cursor(tree_win, { side_answer_line, 0 })
end)
vim.api.nvim_feedkeys('zc', 'xt', false)
assert(vim.wait(1000, function()
  return vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(side_answer_line) == side_answer_line
  end)
end), 'zc from the second branch row should collapse the branch details')
vim.api.nvim_win_call(tree_win, function()
  assert(vim.fn.foldclosed(side_line) == -1, 'first branch row should stay visible beside the folded details')
  assert(vim.fn.foldclosedend(side_answer_line) == continuation_answer_line, 'collapsed side details should include nested sub-branch and older continuation')
  local first_text = vim.api.nvim_buf_get_lines(tree_buf, side_line - 1, side_line, false)[1] or ''
  assert(first_text:find('side branch prompt', 1, true), first_text)
  local folded_label = vim.fn.foldtextresult(side_answer_line)
  assert(folded_label:find('side continuation answer', 1, true), folded_label)
  assert(folded_label:find('side branch prompt', 1, true) == nil, folded_label)
  assert(folded_label:find('details', 1, true) == nil, folded_label)
end)
assert(state.ui.interaction.selected == side_answer_index, 'folded details row should stay selected')
vim.api.nvim_feedkeys('j', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction.selected == main_index end), 'j from folded details must skip hidden branch contents')
assert(vim.api.nvim_win_get_cursor(tree_win)[1] == main_line, 'cursor should land on the next visible item after folded details')
vim.api.nvim_feedkeys('k', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction.selected == side_answer_index end), 'k should move back to the folded details row, not hidden branch contents')
assert(vim.api.nvim_win_get_cursor(tree_win)[1] == side_answer_line, 'cursor should land on folded details row')
vim.api.nvim_feedkeys('zo', 'xt', false)
assert(vim.wait(1000, function()
  return vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(side_answer_line) == -1
  end)
end), 'zo from the folded details row should reopen the branch details')
vim.api.nvim_feedkeys('zc', 'xt', false)
assert(vim.wait(1000, function()
  return vim.api.nvim_win_call(tree_win, function()
    return vim.fn.foldclosed(side_answer_line) == side_answer_line
  end)
end), 'zc should collapse the branch details before Enter selection')
vim.api.nvim_win_set_cursor(tree_win, { side_line, 0 })
requests = {}
vim.api.nvim_feedkeys('\r', 'xt', false)
local switch_path
assert(vim.wait(1000, function()
  for _, request in ipairs(requests) do
    if request.type == 'switch_session' then
      switch_path = request.sessionPath
    end
  end
  return switch_path ~= nil
end), 'Enter on a folded branch row should navigate to the folded branch target')
for _, request in ipairs(requests) do
  assert(not (request.type == 'fork' and request.entryId == 'u3'), 'folded branch Enter should not fork from the branch prompt: ' .. vim.inspect(requests))
end
local _, switched_entries = require('pi-dev.sessions.store').load_entries(switch_path)
local last_entry = switched_entries[#switched_entries]
assert(last_entry and last_entry.id == 'a4', 'folded branch Enter should navigate to last step a4, got ' .. vim.inspect(last_entry))
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}
rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
