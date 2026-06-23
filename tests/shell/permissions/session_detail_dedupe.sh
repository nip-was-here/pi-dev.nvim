#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local session_file = vim.fn.tempname()
local bash_command = [[git status --short && ./tests/shell/sessions/restore_paged_render.sh]]
local mcp_call = [[ExamplePrompt.search {"query":"permission session render"}]]
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'run checks' } }),
  vim.json.encode({
    type = 'extension_ui_request',
    id = 'bash-perm',
    parentId = 'u1',
    timestamp = '2026-01-01T00:00:02.000Z',
    method = 'select',
    title = "Permission Required\nPi requested bash command './tests/*'. Allow this command?\n" .. bash_command,
    options = { 'Yes', 'Yes, allow bash "./tests/*" for this session', 'No', 'No, provide reason' },
  }),
}, session_file)

require('pi-dev').setup({ keymaps = { enable = false }, session_render = { max_messages = 10, chunk_size = 10, chunk_delay_ms = 1 } })
local ui = require('pi-dev.ui')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
ui.show()
sessions.render_current('permission restore bash', session_file)
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'):find('#### Permission request', 1, true) ~= nil
end), 'bash permission did not render')
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('```bash\n' .. bash_command .. '\n```', 1, true) == nil, text)
assert(text:find('```bash\n./tests/*\n```', 1, true) == nil, text)
local _, bash_count = text:gsub(vim.pesc(bash_command), '')
assert(bash_count == 0, text)
assert(text:find('Pi requested bash command.\nAllow this command?', 1, true), text)

vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'search context' } }),
  vim.json.encode({
    type = 'extension_ui_request',
    id = 'mcp-perm',
    parentId = 'u1',
    timestamp = '2026-01-01T00:00:02.000Z',
    method = 'select',
    title = "Permission Required\nPi requested MCP target 'ExamplePrompt.*'. Allow this MCP call?\n" .. mcp_call,
    options = { 'Yes', 'No', 'No, provide reason' },
  }),
}, session_file)

sessions.render_current('permission restore mcp', session_file)
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'):find('#### Permission request', 1, true) ~= nil
end), 'MCP permission did not render')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('```\n' .. mcp_call .. '\n```', 1, true) == nil, text)
assert(text:find('```\nExamplePrompt.*\n```', 1, true) == nil, text)
local _, mcp_count = text:gsub(vim.pesc(mcp_call), '')
assert(mcp_count == 0, text)
assert(text:find('Pi requested MCP target.\nAllow this MCP call?', 1, true), text)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
