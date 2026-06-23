#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local project = vim.fn.tempname()
vim.fn.mkdir(project .. '/src/nested', 'p')
vim.fn.writefile({ 'return {}' }, project .. '/src/nested/foo.lua')
vim.fn.writefile({ 'notes' }, project .. '/src/notes.txt')
vim.cmd('cd ' .. vim.fn.fnameescape(project))

require('pi-dev').setup({ keymaps = { enable = false } })
local completion = require('pi-dev.completion')

local function set_line(text)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
  vim.api.nvim_win_set_cursor(0, { 1, #text })
end

set_line('inspect @src/ne')
assert(completion.complete(1, '') == 8, 'file mention completion should start at @')
local mention_items = completion.complete(0, '@src/ne')
local mention_words = vim.tbl_map(function(item) return item.word end, mention_items)
assert(vim.tbl_contains(mention_words, '@src/nested/'), vim.inspect(mention_items))

set_line('inspect @src/nested/fo')
assert(completion.complete(1, '') == 8, 'file mention completion must keep slash-separated base')
local nested_items = completion.complete(0, '@src/nested/fo')
assert(#nested_items == 1 and nested_items[1].word == '@src/nested/foo.lua', vim.inspect(nested_items))

set_line('contact a@src/ne')
assert(completion.complete(1, '') == -3, 'inline @ without leading whitespace is not a file mention')

set_line('!! cat src/ne')
assert(completion.complete(1, '') == 7, 'shell path completion should start at current shell argument')
local shell_path_items = completion.complete(0, 'src/ne')
assert(vim.tbl_contains(vim.tbl_map(function(item) return item.word end, shell_path_items), 'src/nested/'), vim.inspect(shell_path_items))

vim.bo.modified = false
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
