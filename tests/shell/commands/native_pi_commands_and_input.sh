#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local completion = require('pi-dev.completion')
local renderer = require('pi-dev.renderer')
local rpc = require('pi-dev.rpc')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

ui.show()
renderer.clear('native feature test')

local commands = {
  'PiDevName',
  'PiDevSession',
  'PiDevCompact',
  'PiDevExport',
  'PiDevHotkeys',
  'PiDevQuit',
}
for _, command in ipairs(commands) do
  assert(vim.fn.exists(':' .. command) == 2, command .. ' command should exist')
end

local sent = {}
rpc.start = function()
  return 42
end
rpc.request = function(message, cb)
  table.insert(sent, message)
  if message.type == 'set_session_name' and cb then
    cb({ success = true, data = {} })
  elseif message.type == 'get_state' and cb then
    cb({ success = true, data = { sessionFile = state.session.current_file, sessionId = 'sid-1', sessionName = 'Named root', model = { provider = 'fake', id = 'model' } } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ success = true, data = { sessionId = 'sid-1', totalMessages = 7, userMessages = 3, assistantMessages = 2, toolCalls = 1, tokens = { total = 123 }, cost = 0.25 } })
  elseif message.type == 'compact' and cb then
    cb({ success = true, data = { summary = 'compact summary', tokensBefore = 999 } })
  elseif message.type == 'export_html' and cb then
    cb({ success = true, data = { path = message.outputPath } })
  elseif message.type == 'bash' and cb then
    cb({ success = true, data = { output = 'bash output', exitCode = 0 } })
  elseif cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

local root = vim.fn.tempname() .. '.jsonl'
local child = vim.fn.tempname() .. '.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'root-id', cwd = vim.fn.getcwd() }),
  vim.json.encode({ type = 'message', id = 'root-msg', message = { role = 'user', content = 'root prompt' } }),
}, root)
vim.fn.writefile({
  vim.json.encode({ type = 'session', id = 'child-id', cwd = vim.fn.getcwd(), parentSession = root }),
  vim.json.encode({ type = 'message', id = 'child-msg', parentId = 'root-msg', message = { role = 'user', content = 'child prompt' } }),
}, child)
state.session.current_file = child
state.session.tree_root_file = root

assert(api.name_session('Named root') ~= nil, '/name should send set_session_name')
assert(sent[#sent].type == 'set_session_name' and sent[#sent].name == 'Named root', vim.inspect(sent[#sent]))
local root_text = table.concat(vim.fn.readfile(root), '\n')
assert(root_text:find('"session_info"', 1, true), root_text)
assert(root_text:find('Named root', 1, true), root_text)

api.show_session_info()
assert(sent[#sent - 1].type == 'get_state', vim.inspect(sent))
assert(sent[#sent].type == 'get_session_stats', vim.inspect(sent))

api.compact('keep decisions')
assert(sent[#sent].type == 'compact' and sent[#sent].customInstructions == 'keep decisions', vim.inspect(sent[#sent]))

api.export_session('./tmp/pi-dev-test/export.html')
assert(sent[#sent].type == 'export_html' and sent[#sent].outputPath == './tmp/pi-dev-test/export.html', vim.inspect(sent[#sent]))

api.bash('printf pi')
assert(sent[#sent].type == 'bash' and sent[#sent].command == 'printf pi', vim.inspect(sent[#sent]))

local local_hit
api.local_bash = function(command)
  local_hit = command
  return true
end
local bash_hit
api.bash = function(command)
  bash_hit = command
  return true
end
assert(api.submit_text('!! printf local') == true and local_hit == 'printf local', local_hit)
assert(api.submit_text('! printf context') == true and bash_hit == 'printf context', bash_hit)

local stop_hit = false
api.stop_current_rpc = function()
  stop_hit = true
  return true
end
assert(api.handle_slash_command('/quit') == true and stop_hit, '/quit should stop only current RPC runtime')

api.hotkeys()
local output = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(output:find(':PiDevName', 1, true), output)
assert(output:find(':PiDevSession', 1, true), output)
assert(output:find(':PiDevCompact', 1, true), output)
assert(output:find(':PiDevExport', 1, true), output)
assert(output:find(':PiDevHotkeys', 1, true), output)
assert(output:find(':PiDevQuit', 1, true), output)

local skill_items = completion.items('skill:')
local has_skill_fallback = false
for _, item in ipairs(skill_items) do
  if item.word == '/skill:' and item.menu == '[pi-dev]' then
    has_skill_fallback = true
  end
end
assert(has_skill_fallback, vim.inspect(skill_items))

local project = vim.fn.tempname()
vim.fn.mkdir(project .. '/src', 'p')
vim.fn.mkdir(project .. '/reports', 'p')
vim.fn.mkdir(project .. '/bin', 'p')
vim.fn.writefile({ 'hello' }, project .. '/src/main.lua')
vim.fn.writefile({ 'html' }, project .. '/reports/index.html')
vim.fn.writefile({ '#!/usr/bin/env sh', 'echo ok' }, project .. '/bin/pi-dev-test-tool')
vim.fn.setfperm(project .. '/bin/pi-dev-test-tool', 'rwxr-xr-x')
vim.env.PATH = project .. '/bin:' .. tostring(vim.env.PATH or '')
vim.cmd('cd ' .. vim.fn.fnameescape(project))
local file_items = completion.file_items('@src/ma')
assert(#file_items >= 1 and file_items[1].word == '@src/main.lua', vim.inspect(file_items))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'see @src/ma' })
vim.api.nvim_win_set_cursor(0, { 1, #'see @src/ma' })
assert(completion.complete(1, '') == 4, 'completion should start at @ in input text')

local export_items = completion.path_items('reports/ind')
assert(#export_items >= 1 and export_items[1].word == 'reports/index.html', vim.inspect(export_items))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '/export reports/ind' })
vim.api.nvim_win_set_cursor(0, { 1, #'/export reports/ind' })
assert(completion.complete(1, '') == #'/export ', 'completion should start at /export path arg')
assert(completion.complete(0, 'reports/ind')[1].word == 'reports/index.html')

local shell_items = completion.shell_items('pi-dev-test')
assert(#shell_items >= 1 and shell_items[1].word == 'pi-dev-test-tool', vim.inspect(shell_items))
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '! pi-dev-test' })
vim.api.nvim_win_set_cursor(0, { 1, #'! pi-dev-test' })
assert(completion.complete(1, '') == #'! ', 'completion should start after ! command prefix')
assert(completion.complete(0, 'pi-dev-test')[1].word == 'pi-dev-test-tool')
vim.api.nvim_buf_set_lines(0, 0, -1, false, { '!! pi-dev-test' })
vim.api.nvim_win_set_cursor(0, { 1, #'!! pi-dev-test' })
assert(completion.complete(1, '') == #'!! ', 'completion should start after !! command prefix')
vim.bo.modified = false
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
