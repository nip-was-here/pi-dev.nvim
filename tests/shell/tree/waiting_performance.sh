#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
local cwd = vim.uv.cwd()
local function enc(value)
  return vim.json.encode(value)
end

local root_file = session_root .. '/root.jsonl'
local root_lines = { enc({ type = 'session', version = 3, id = 'root', cwd = cwd, timestamp = '2026-01-01T00:00:00.000Z' }) }
local parent = nil
for index = 1, 40 do
  local user_id = 'u' .. index
  table.insert(root_lines, enc({ type = 'message', id = user_id, parentId = parent, timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'root prompt ' .. index } }))
  local assistant_id = 'a' .. index
  table.insert(root_lines, enc({ type = 'message', id = assistant_id, parentId = user_id, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'assistant', content = 'root answer ' .. index } }))
  parent = assistant_id
end
vim.fn.writefile(root_lines, root_file)

local branch_files = {}
for branch = 1, 6 do
  local branch_file = session_root .. '/branch-' .. branch .. '.jsonl'
  table.insert(branch_files, branch_file)
  local branch_lines = { enc({ type = 'session', version = 3, id = 'branch-' .. branch, cwd = cwd, parentSession = root_file, timestamp = '2026-01-01T00:00:02.000Z' }) }
  local branch_parent = 'a' .. (branch * 4)
  for index = 1, 8 do
    local user_id = 'b' .. branch .. 'u' .. index
    table.insert(branch_lines, enc({ type = 'message', id = user_id, parentId = branch_parent, timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'user', content = 'branch ' .. branch .. ' prompt ' .. index } }))
    local assistant_id = 'b' .. branch .. 'a' .. index
    table.insert(branch_lines, enc({ type = 'message', id = assistant_id, parentId = user_id, timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'assistant', content = 'branch ' .. branch .. ' answer ' .. index } }))
    branch_parent = assistant_id
  end
  vim.fn.writefile(branch_lines, branch_file)
end

require('pi-dev').setup({
  keymaps = { enable = false },
  session_root = session_root,
  cwd = cwd,
  ui = { width = 100, input_height = 10 },
})
local api = require('pi-dev.api')
local renderer = require('pi-dev.renderer')
local rpc = require('pi-dev.rpc')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

rpc.request = function(message, cb)
  if cb then
    cb({ success = true, data = {} })
  end
  return message.type
end
state.session.current_file = root_file
ui.show()
renderer.clear('large output snapshot guard')
local filler = {}
for index = 1, 500 do
  filler[index] = 'output filler line ' .. index
end
renderer.append_system(table.concat(filler, '\n'))

local old_readfile = vim.fn.readfile
local old_globpath = vim.fn.globpath
local read_counts = {}
local glob_count = 0
vim.fn.readfile = function(path, ...)
  local key = tostring(path)
  if key:find(session_root, 1, true) then
    read_counts[key] = (read_counts[key] or 0) + 1
  end
  return old_readfile(path, ...)
end
vim.fn.globpath = function(...)
  glob_count = glob_count + 1
  return old_globpath(...)
end

sessions.waiting()
assert(state.ui.interaction == nil, 'empty /waiting should not open an interaction')
assert(glob_count == 0, 'empty /waiting should not scan session files when no runtime is waiting; glob_count=' .. glob_count)
assert(next(read_counts) == nil, 'empty /waiting should not read session files when no runtime is waiting: ' .. vim.inspect(read_counts))

read_counts = {}
glob_count = 0
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should open')
local items_before = vim.inspect(state.ui.interaction.items)
assert(items_before:find('branch 6 answer 8', 1, true), items_before)
assert((read_counts[root_file] or 0) <= 3, 'tree may read the root header while resolving ancestry, but should not repeatedly scan the root: ' .. tostring(read_counts[root_file] or 0))
for _, path in ipairs(branch_files) do
  assert((read_counts[path] or 0) <= 1, 'tree should read each related branch JSONL file at most once per cache rebuild: ' .. path .. ' read ' .. tostring(read_counts[path] or 0))
end

read_counts = {}
glob_count = 0
ui.close_interaction()
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'second tree interaction should open')
assert(glob_count == 0, 'unchanged cached tree should not glob the full session root: glob_count=' .. glob_count)
for _, path in ipairs(branch_files) do
  assert((read_counts[path] or 0) == 0, 'unchanged tree should use stat-valid cache instead of rereading branch files: ' .. vim.inspect(read_counts))
end

local tree_buf = vim.api.nvim_win_get_buf(state.ui.output_win)
local output_tick = vim.api.nvim_buf_get_changedtick(tree_buf)
local selected_before = state.ui.interaction.selected
vim.api.nvim_feedkeys('j', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.selected ~= selected_before end), 'j should move tree selection')
assert(vim.api.nvim_buf_get_changedtick(tree_buf) == output_tick, 'tree cursor movement should update selection without redrawing the tree buffer')

ui.close_interaction()
local changed_branch = branch_files[1]
local changed_lines = old_readfile(changed_branch)
table.insert(changed_lines, enc({ type = 'message', id = 'cache-new-user', parentId = 'b1a8', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'user', content = 'cache invalidation prompt' } }))
table.insert(changed_lines, enc({ type = 'message', id = 'cache-new-assistant', parentId = 'cache-new-user', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'assistant', content = 'cache invalidation answer' } }))
vim.fn.writefile(changed_lines, changed_branch)

read_counts = {}
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree after changed stat should open')
local items_after = vim.inspect(state.ui.interaction.items)
assert(items_after:find('cache invalidation answer', 1, true), items_after)
assert((read_counts[changed_branch] or 0) == 1, 'changed stat should invalidate and reread the changed branch once: ' .. tostring(read_counts[changed_branch] or 0))

vim.fn.readfile = old_readfile
vim.fn.globpath = old_globpath
LUA

output="$({
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
