#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local project = vim.fn.tempname()
vim.fn.mkdir(project, 'p')
vim.fn.mkdir(project .. '/agent', 'p')
vim.fn.mkdir(project .. '/agent/mcp-oauth/alphaservice', 'p')
vim.fn.writefile({ vim.json.encode({ tokens = { accessToken = 'example-access-value', expiresAt = os.time() + 3600 } }) }, project .. '/agent/mcp-oauth/alphaservice/tokens.json')
local hashed_betaservice_dir = project .. '/agent/mcp-oauth/sha256-' .. vim.fn.sha256('BetaService')
vim.fn.mkdir(hashed_betaservice_dir, 'p')
vim.fn.writefile({ vim.json.encode({ tokens = { accessToken = 'example-hashed-access-value', expiresAt = os.time() + 3600 } }) }, hashed_betaservice_dir .. '/tokens.json')
vim.env.PI_CODING_AGENT_DIR = project .. '/agent'
vim.cmd('cd ' .. vim.fn.fnameescape(project))
vim.fn.writefile({ vim.json.encode({
  mcpServers = {
    ExamplePrompt = { command = 'example-prompt-cli' },
    AlphaService = { url = 'https://alphaservice.example.test/mcp', auth = 'oauth' },
    BetaService = { url = 'https://betaservice.example.test/mcp', auth = 'oauth' },
    already = { command = 'already-mcp', directTools = true },
  },
  disabledMcpServers = {
    disabled = { command = 'disabled-mcp' },
  },
}) }, project .. '/.mcp.json')

require('pi-dev').setup({ keymaps = { enable = false } })
local api = require('pi-dev.api')
local mcp = require('pi-dev.compat.mcp_adapter')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
ui.show()

local remaining, directives = mcp.extract_directives('before\n/mcp on exampleprompt\nmiddle\n  /mcp off ALREADY  \nafter')
assert(remaining == 'before\nmiddle\nafter', remaining)
assert(#directives == 2 and directives[1].action == 'on' and directives[1].name == 'exampleprompt', vim.inspect(directives))
assert(directives[2].action == 'off' and directives[2].name == 'ALREADY', vim.inspect(directives))

api.handle_slash_command('/mcp')
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('MCP Server Status:', 1, true), text)
assert(text:find('| mcp name | status | auth |', 1, true), text)
assert(text:find('| `AlphaService` | lazy | ok |', 1, true), text)
assert(text:find('| `BetaService` | lazy | ok |', 1, true), text)
assert(text:find('| `ExamplePrompt` | lazy | - |', 1, true), text)
assert(text:find('| `already` | on | - |', 1, true), text)
assert(text:find('| `disabled` | off | - |', 1, true), text)
assert(text:find('Effective direct tools:', 1, true) == nil, text)
assert(text:find('Config mutation:', 1, true) == nil, text)
assert(text:find('| MCP server | Status | Config | Source | Transport | Note |', 1, true) == nil, text)

local prompted
local reloaded = false
api.prompt = function(message)
  prompted = message
end
api.steer = function(message)
  error('idle native MCP command must not steer')
end
assert(api.handle_slash_command('/mcp-auth EXAMPLEPROMPT') == true, 'native /mcp-auth should canonicalize configured server names')
assert(prompted == '/mcp-auth ExamplePrompt', prompted or 'nil')
prompted = nil
assert(api.handle_slash_command('/mcp-auth alphaservce') == true, 'native /mcp-auth should resolve a unique near-match server name')
assert(prompted == '/mcp-auth AlphaService', prompted or 'nil')
prompted = nil
assert(api.handle_slash_command('/mcp-auth unknown-server') == true, 'unknown /mcp-auth should still be forwarded to Pi')
assert(prompted == '/mcp-auth unknown-server', prompted or 'nil')
api.reload = function(callback)
  reloaded = true
  if callback then
    callback({ success = true })
  end
end

ui.set_input_text('/mcp on exampleprompt\nplease use it\nthen answer')
assert(ui.submit_input() == true)
assert(reloaded, 'enabling direct MCP tools should reload before prompt')
assert(prompted == 'please use it\nthen answer', prompted or 'nil')
local raw = vim.json.decode(table.concat(vim.fn.readfile(project .. '/.mcp.json'), '\n'))
assert(raw.mcpServers.ExamplePrompt.directTools == nil, 'native /mcp on must not mutate Pi MCP config')
assert(raw.mcpServers.already.directTools == true, vim.inspect(raw))
assert(mcp.rpc_env().MCP_DIRECT_TOOLS == 'already,ExamplePrompt', vim.inspect(mcp.rpc_env()))
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('MCP context update:', 1, true), text)
assert(text:find('enabled: ExamplePrompt', 1, true), text)
assert(text:find('config: unchanged', 1, true), text)
renderer.clear('MCP status after override')
api.handle_slash_command('/mcp status')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('MCP Server Status:', 1, true), text)
assert(text:find('| mcp name | status | auth |', 1, true), text)
assert(text:find('| `AlphaService` | lazy | ok |', 1, true), text)
assert(text:find('| `BetaService` | lazy | ok |', 1, true), text)
assert(text:find('| `ExamplePrompt` | on | - |', 1, true), text)
assert(text:find('| `already` | on | - |', 1, true), text)
assert(text:find('| `disabled` | off | - |', 1, true), text)
assert(text:find('MCP_DIRECT_TOOLS=', 1, true) == nil, text)
assert(text:find('session override', 1, true) == nil, text)

prompted = nil
reloaded = false
ui.set_input_text('work without mcp\n/mcp off\ncontinue')
assert(ui.submit_input() == true)
assert(reloaded, 'disabling MCP direct tools should reload before prompt')
assert(prompted == 'work without mcp\ncontinue', prompted or 'nil')
assert(mcp.rpc_env().MCP_DIRECT_TOOLS == '__none__', vim.inspect(mcp.rpc_env()))
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('disabled: all', 1, true), text)

prompted = nil
reloaded = false
ui.set_input_text('/MCP on alphaServce')
assert(ui.submit_input() == true)
assert(reloaded, 'server name lookup should be case-insensitive and near-match tolerant for standalone /mcp on')
assert(prompted == nil, 'standalone /mcp on must not send prompt')
assert(mcp.rpc_env().MCP_DIRECT_TOOLS == 'AlphaService', vim.inspect(mcp.rpc_env()))

prompted = nil
reloaded = false
ui.set_input_text('/mcp on unknown-server')
assert(ui.submit_input() == true)
assert(not reloaded, 'unknown server should not reload')
assert(prompted == nil, 'standalone /mcp on must not send prompt')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('unknown: unknown-server', 1, true), text)

prompted = nil
reloaded = false
api.reload = function(callback)
  reloaded = true
  if callback then
    callback({ success = false, cancelled = true })
  end
end
ui.set_input_text('/mcp off\nmust not send after cancelled reload')
assert(ui.submit_input() == true)
assert(reloaded, 'changed MCP direct tools should attempt reload')
assert(prompted == nil, 'cancelled MCP reload must not send remaining prompt')
assert(mcp.rpc_env().MCP_DIRECT_TOOLS == 'AlphaService', vim.inspect(mcp.rpc_env()))
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('MCP context change cancelled; prompt was not sent.', 1, true), text)

prompted = nil
reloaded = false
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end
local runtime = state.active_rpc_runtime()
runtime.job_id = 4242
runtime.active = true
runtime.status = 'running'
api.reload = function()
  reloaded = true
  error('active-turn MCP toggle must defer instead of reloading')
end
ui.set_input_text('/mcp off\nmust not send during active work')
assert(ui.submit_input() == true)
assert(not reloaded, 'active-turn MCP toggle must not reload')
assert(prompted == nil, 'active-turn MCP toggle must not send remaining prompt')
assert(mcp.rpc_env().MCP_DIRECT_TOOLS == 'AlphaService', vim.inspect(mcp.rpc_env()))
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('MCP context change deferred', 1, true), text)
runtime.active = false
runtime.status = 'idle'

require('pi-dev.config').options.compat.mcp_adapter.enable = false
remaining, directives = mcp.extract_directives('keep\n/mcp on exampleprompt\n/mcp off')
assert(remaining == 'keep\n/mcp on exampleprompt\n/mcp off', remaining)
assert(#directives == 0, vim.inspect(directives))
assert(api.handle_slash_command('/mcp') == false, 'disabled native MCP compat should let Pi handle /mcp')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
