#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local config = require('pi-dev.config')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
config.options.session_root = session_root

local root_file = session_root .. '/root.jsonl'
local recent_branch_file = session_root .. '/recent-branch.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'shared prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'shared answer' } }),
  vim.json.encode({ type = 'message', id = 'old-user', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'old active branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'old-assistant', parentId = 'old-user', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'old active branch answer' } }),
  vim.json.encode({ type = 'message', id = 'old-hidden-tool', parentId = 'old-assistant', timestamp = '2026-01-01T00:00:30.000Z', message = { role = 'toolResult', content = 'hidden old tool result must not make old branch look recent' } }),
}, root_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'recent', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:09.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'shared prompt' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'shared answer' } }),
  vim.json.encode({ type = 'message', id = 'recent-user', parentId = 'a1', timestamp = '2026-01-01T00:00:09.000Z', message = { role = 'user', content = 'recent sibling branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'recent-assistant', parentId = 'recent-user', timestamp = '2026-01-01T00:00:10.000Z', message = { role = 'assistant', content = 'recent sibling branch answer' } }),
}, recent_branch_file)

state.session.current_file = root_file
state.session.tree_root_file = root_file
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction missing')

local function item_index(fragment)
  for index, item in ipairs(state.ui.interaction.items or {}) do
    if tostring(item.label or ''):find(fragment, 1, true) then
      return index, item.label
    end
  end
end

local shared_index = item_index('Assistant: shared answer')
local recent_index, recent_label = item_index('recent sibling branch prompt')
local old_index, old_label = item_index('old active branch prompt')
local recent_answer_index = item_index('Assistant: recent sibling branch answer')
local old_answer_index = item_index('Assistant: old active branch')
assert(shared_index and recent_index and old_index and recent_answer_index and old_answer_index, vim.inspect(state.ui.interaction.items))
assert(shared_index < recent_index, vim.inspect(state.ui.interaction.items))
assert(recent_index < old_index, 'newer sibling branch should render above older active sibling branch\n' .. vim.inspect(state.ui.interaction.items))
assert(recent_index < recent_answer_index and recent_answer_index < old_index, 'newer branch block should stay together before older sibling branch\n' .. vim.inspect(state.ui.interaction.items))
assert(vim.startswith(recent_label, '| * recent sibling branch prompt'), recent_label)
assert(vim.startswith(old_label, '| * old active branch prompt'), old_label)

local tree_render = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(tree_render:find('|', 1, true), tree_render)
local old_connector_row = state.ui.interaction.item_line_by_index[old_index] - 1
assert(state.ui.interaction.line_to_item[old_connector_row] == nil, 'connector row before lower sibling branch must stay non-selectable')
ui.close_interaction()

local nested_root = session_root .. '/nested-root.jsonl'
local nested_old_file = session_root .. '/nested-old.jsonl'
local nested_new_file = session_root .. '/nested-new.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'nested-root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'nu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'nested shared prompt' } }),
  vim.json.encode({ type = 'message', id = 'na1', parentId = 'nu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'nested shared answer' } }),
  vim.json.encode({ type = 'message', id = 'current-user', parentId = 'na1', timestamp = '2026-01-01T00:00:20.000Z', message = { role = 'user', content = 'current unrelated branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'current-assistant', parentId = 'current-user', timestamp = '2026-01-01T00:00:21.000Z', message = { role = 'assistant', content = 'current unrelated branch answer' } }),
}, nested_root)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'nested-old', cwd = vim.uv.cwd(), parentSession = nested_root, timestamp = '2026-01-01T00:00:03.000Z' }),
  vim.json.encode({ type = 'message', id = 'nu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'nested shared prompt' } }),
  vim.json.encode({ type = 'message', id = 'na1', parentId = 'nu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'nested shared answer' } }),
  vim.json.encode({ type = 'message', id = 'neighbor-user', parentId = 'na1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'neighbor branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'neighbor-assistant', parentId = 'neighbor-user', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'neighbor branch answer' } }),
  vim.json.encode({ type = 'message', id = 'nested-old-user', parentId = 'neighbor-assistant', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'user', content = 'old nested sibling prompt' } }),
  vim.json.encode({ type = 'message', id = 'nested-old-assistant', parentId = 'nested-old-user', timestamp = '2026-01-01T00:00:06.000Z', message = { role = 'assistant', content = 'old nested sibling answer' } }),
}, nested_old_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'nested-new', cwd = vim.uv.cwd(), parentSession = nested_root, timestamp = '2026-01-01T00:00:09.000Z' }),
  vim.json.encode({ type = 'message', id = 'nu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'nested shared prompt' } }),
  vim.json.encode({ type = 'message', id = 'na1', parentId = 'nu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'nested shared answer' } }),
  vim.json.encode({ type = 'message', id = 'neighbor-user', parentId = 'na1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'neighbor branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'neighbor-assistant', parentId = 'neighbor-user', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'neighbor branch answer' } }),
  vim.json.encode({ type = 'message', id = 'nested-new-user', parentId = 'neighbor-assistant', timestamp = '2026-01-01T00:00:09.000Z', message = { role = 'user', content = 'new nested sibling prompt' } }),
  vim.json.encode({ type = 'message', id = 'nested-new-assistant', parentId = 'nested-new-user', timestamp = '2026-01-01T00:00:10.000Z', message = { role = 'assistant', content = 'new nested sibling answer' } }),
}, nested_new_file)

state.session.current_file = nested_root
state.session.tree_root_file = nested_root
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'nested tree interaction missing')

local neighbor_index = item_index('neighbor branch prompt')
local nested_new_index, nested_new_label = item_index('new nested sibling prompt')
local nested_old_index, nested_old_label = item_index('old nested sibling prompt')
local current_index = item_index('current unrelated branch prompt')
assert(neighbor_index and nested_new_index and nested_old_index and current_index, vim.inspect(state.ui.interaction.items))
assert(nested_new_index < nested_old_index, 'newer sibling branch under a non-current neighboring node should render above older sibling\n' .. vim.inspect(state.ui.interaction.items))
assert(neighbor_index < nested_new_index, vim.inspect(state.ui.interaction.items))
assert(vim.startswith(nested_new_label, '| | * new nested sibling prompt'), nested_new_label)
assert(vim.startswith(nested_old_label, '| | * old nested sibling prompt'), nested_old_label)
local nested_old_connector_row = state.ui.interaction.item_line_by_index[nested_old_index] - 1
assert(state.ui.interaction.line_to_item[nested_old_connector_row] == nil, 'nested sibling connector row must stay non-selectable')
ui.close_interaction()
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
