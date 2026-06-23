#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local project = vim.fn.tempname()
vim.fn.mkdir(project, 'p')
vim.fn.mkdir(project .. '/agent/mcp-oauth/alphaservice', 'p')
vim.fn.writefile({ vim.json.encode({ tokens = { accessToken = 'example-access-value', expiresAt = os.time() + 3600 } }) }, project .. '/agent/mcp-oauth/alphaservice/tokens.json')
vim.env.PI_CODING_AGENT_DIR = project .. '/agent'
vim.cmd('cd ' .. vim.fn.fnameescape(project))
vim.fn.writefile({ vim.json.encode({
  mcpServers = {
    AlphaService = { url = 'https://alphaservice.example.test/mcp', auth = 'oauth' },
    sampleNotes = { command = 'sample-notes-mcp', directTools = true },
  },
}) }, project .. '/.mcp.json')

require('pi-dev').setup({ keymaps = { enable = false } })
local completion = require('pi-dev.completion')
local rpc = require('pi-dev.rpc')

rpc.request = function(message, cb)
  assert(message.type == 'get_commands')
  cb({ success = true, data = { commands = {
    { name = 'hello', description = 'Remote hello', source = 'extension' },
    { name = 'model', description = 'Remote duplicate should win', source = 'remote' },
    { name = 'skill:tdd', description = 'Test-driven development', source = 'skill' },
    { name = 'skill:diagnosing-bugs', description = 'Debug hard bugs', source = 'skill' },
    { name = 'models', description = 'Hidden legacy command' },
  } } })
  return 'get_commands'
end

local refreshed
completion.refresh(function(commands)
  refreshed = commands
end)
assert(refreshed ~= nil, 'completion refresh callback missing')
local items = completion.items('')
local by_word = {}
for _, item in ipairs(items) do
  by_word[item.word] = item
end
assert(by_word['/hello'] and by_word['/hello'].menu == '[extension]', vim.inspect(items))
assert(by_word['/model'] and by_word['/model'].menu == '[remote]', vim.inspect(items))
assert(by_word['/new'] and by_word['/new'].menu == '[pi-dev]', vim.inspect(items))
assert(by_word['/waiting'] and by_word['/waiting'].menu == '[pi-dev]', vim.inspect(items))
assert(by_word['/next-rpc'] and by_word['/next-rpc'].menu == '[pi-dev]', vim.inspect(items))
assert(by_word['/cycle-rpc'] and by_word['/cycle-rpc'].menu == '[pi-dev]', vim.inspect(items))
assert(by_word['/mcp'] and by_word['/mcp'].menu == '[pi-dev]', vim.inspect(items))
assert(by_word['/mcp-auth'] and by_word['/mcp-auth'].menu == '[pi-dev]', vim.inspect(items))
assert(by_word['/skill:tdd'] and by_word['/skill:tdd'].menu == '[skill]', vim.inspect(items))
assert(by_word['/models'] == nil, vim.inspect(items))
local skill_items = completion.items('skill:')
assert(#skill_items == 2, vim.inspect(skill_items))
assert(skill_items[1].menu == '[skill]' and skill_items[2].menu == '[skill]', vim.inspect(skill_items))
assert(vim.tbl_contains(vim.tbl_map(function(item) return item.word end, skill_items), '/skill:tdd'), vim.inspect(skill_items))
assert(vim.tbl_contains(vim.tbl_map(function(item) return item.word end, skill_items), '/skill:diagnosing-bugs'), vim.inspect(skill_items))
assert(#completion.items('skill:td') == 1 and completion.items('skill:td')[1].word == '/skill:tdd', vim.inspect(completion.items('skill:td')))
local mcp_items = completion.mcp_items('alpha')
assert(#mcp_items == 1 and mcp_items[1].word == 'AlphaService', vim.inspect(mcp_items))
assert(mcp_items[1].menu == '[mcp lazy, auth ok]', vim.inspect(mcp_items))
assert(completion.mcp_items('sam')[1].word == 'sampleNotes', vim.inspect(completion.mcp_items('sam')))

completion.commands = nil
completion.loading = false
completion.pending_callbacks = {}
local held_callback
local request_count = 0
rpc.request = function(message, cb)
  request_count = request_count + 1
  held_callback = cb
  return 'get_commands'
end
local first_done = false
local second_done = false
completion.refresh(function(commands)
  first_done = commands ~= nil
end)
completion.refresh(function(commands)
  second_done = commands ~= nil
end)
assert(request_count == 1, 'concurrent refresh should share one RPC request')
assert(not first_done and not second_done, 'callbacks should wait for the in-flight refresh')
held_callback({ success = true, data = { commands = { { name = 'late', source = 'extension' } } } })
assert(first_done and second_done, 'all queued refresh callbacks should run')
assert(completion.items('late')[1].word == '/late', vim.inspect(completion.items('late')))

local filtered = completion.items('late')
assert(#filtered == 1 and filtered[1].word == '/late', vim.inspect(filtered))

vim.api.nvim_buf_set_lines(0, 0, -1, false, { '  /mcp-auth alpha' })
vim.api.nvim_win_set_cursor(0, { 1, 17 })
assert(completion.complete(1, '') == 12)
assert(completion.complete(0, 'alpha')[1].word == 'AlphaService', vim.inspect(completion.complete(0, 'alpha')))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '  /MCP off sam' })
vim.api.nvim_win_set_cursor(0, { 1, 14 })
assert(completion.complete(1, '') == 11)
assert(completion.complete(0, 'sam')[1].word == 'sampleNotes', vim.inspect(completion.complete(0, 'sam')))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '  /he' })
vim.api.nvim_win_set_cursor(0, { 1, 5 })
assert(completion.complete(1, '') == 2)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'not /command' })
vim.api.nvim_win_set_cursor(0, { 1, 12 })
assert(completion.complete(1, '') == -3)
vim.bo.modified = false
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
