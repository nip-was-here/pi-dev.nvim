#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local project = vim.fn.tempname()
vim.fn.mkdir(project, 'p')
vim.cmd('cd ' .. vim.fn.fnameescape(project))
vim.fn.writefile({ vim.json.encode({ mcpServers = { ExamplePrompt = { command = 'rp' } } }) }, project .. '/.mcp.json')
require('pi-dev').setup({
  exec = { bin = 'pi-test' },
  env = { BASE_ENV = 'yes' },
  keymaps = { enable = false },
})
local mcp = require('pi-dev.compat.mcp_adapter')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')

mcp.apply_directives({ { action = 'on', name = 'exampleprompt' } })
local captured
local original_jobstart = vim.fn.jobstart
vim.fn.jobstart = function(cmd, opts)
  captured = { cmd = cmd, opts = opts }
  return 4242
end
rpc.start()
vim.fn.jobstart = original_jobstart
assert(captured ~= nil, 'rpc.start should invoke jobstart')
assert(captured.opts.env.BASE_ENV == 'yes', vim.inspect(captured.opts.env))
assert(captured.opts.env.MCP_DIRECT_TOOLS == 'ExamplePrompt', vim.inspect(captured.opts.env))
state.reset_rpc_runtime()

local api = require('pi-dev.api')
local calls = {}
rpc.start = function()
  table.insert(calls, 'start')
  return 99
end
rpc.stop = function()
  table.insert(calls, 'stop')
  state.reset_rpc_runtime()
end
state.is_job_running = function()
  return true
end
rpc.request = function(message, cb)
  table.insert(calls, message.type .. (message.sessionPath and (':' .. message.sessionPath) or ''))
  if message.type == 'get_state' and cb then
    cb({ success = true, data = { sessionFile = 'active-branch.jsonl' } })
  elseif message.type == 'switch_session' and cb then
    cb({ success = true, data = { messages = {} } })
  elseif cb then
    cb({ success = true, data = {} })
  end
  return message.type
end
local done = false
api.reload(function()
  done = true
end)
assert(vim.wait(1000, function() return done end), vim.inspect(calls))
assert(calls[1] == 'get_state', vim.inspect(calls))
assert(calls[2] == 'stop', vim.inspect(calls))
assert(calls[3] == 'start', vim.inspect(calls))
assert(vim.tbl_contains(calls, 'switch_session:active-branch.jsonl'), vim.inspect(calls))
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
