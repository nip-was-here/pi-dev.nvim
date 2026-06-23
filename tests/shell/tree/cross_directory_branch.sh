#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root .. '/root-dir', 'p')
vim.fn.mkdir(session_root .. '/branch-dir', 'p')
require('pi-dev.config').options.session_root = session_root

local root_file = session_root .. '/root-dir/root.jsonl'
local branch_file = session_root .. '/branch-dir/branch.jsonl'
local cwd = vim.uv.cwd()

vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'cross-root', cwd = cwd, timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'root-user', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'cross dir root prompt' } }),
  vim.json.encode({ type = 'message', id = 'root-assistant', parentId = 'root-user', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'cross dir root answer' } }),
}, root_file)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'cross-branch', cwd = cwd, parentSession = root_file, timestamp = '2026-01-01T00:00:03.000Z' }),
  vim.json.encode({ type = 'message', id = 'root-user', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'cross dir root prompt' } }),
  vim.json.encode({ type = 'message', id = 'root-assistant', parentId = 'root-user', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'cross dir root answer' } }),
  vim.json.encode({ type = 'message', id = 'branch-user', parentId = 'root-assistant', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'cross dir branch prompt must stay in root tree' } }),
  vim.json.encode({ type = 'message', id = 'branch-assistant', parentId = 'branch-user', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'cross dir branch answer' } }),
}, branch_file)

state.session.current_file = root_file
state.session.tree_root_file = root_file
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should open')
local labels = vim.inspect(state.ui.interaction.items)
assert(labels:find('cross dir root prompt', 1, true), labels)
assert(labels:find('cross dir branch prompt must stay in root tree', 1, true), labels)
assert(labels:find('cross dir branch answer', 1, true), labels)
ui.close_interaction()

vim.fn.mkdir(session_root .. '/late-branch-dir', 'p')
local late_branch_file = session_root .. '/late-branch-dir/late-branch.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'late-cross-branch', cwd = cwd, parentSession = root_file, timestamp = '2026-01-01T00:00:05.000Z' }),
  vim.json.encode({ type = 'message', id = 'root-user', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'cross dir root prompt' } }),
  vim.json.encode({ type = 'message', id = 'root-assistant', parentId = 'root-user', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'cross dir root answer' } }),
  vim.json.encode({ type = 'message', id = 'late-branch-user', parentId = 'root-assistant', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'user', content = 'late cross dir branch must invalidate tree cache' } }),
}, late_branch_file)
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction should reopen')
labels = vim.inspect(state.ui.interaction.items)
assert(labels:find('late cross dir branch must invalidate tree cache', 1, true), labels)
ui.close_interaction()
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
