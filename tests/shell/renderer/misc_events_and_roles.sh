#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
require('pi-dev.ui').show()

renderer.clear('Misc events')
renderer.handle_event({ type = 'queue_update', steering = { 'a', 'b' }, followUp = { 'c' } })
renderer.handle_event({ type = 'compaction_start', reason = 'threshold' })
renderer.handle_event({ type = 'compaction_end', reason = 'threshold' })
renderer.handle_event({ type = 'auto_retry_start', attempt = 1, maxAttempts = 3, delayMs = 250, errorMessage = 'rate limited' })
renderer.handle_event({ type = 'auto_retry_end', success = true })
renderer.handle_event({ type = 'extension_error', error = 'boom' })
renderer.handle_event({ type = 'provider_error', error = 'provider down' })
renderer.handle_event({ type = 'protocol_error', error = 'bad json' })
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('> _Queue: 2 steering, 1 follow%-up_'), text)
assert(text:find('> _Compact start: threshold_', 1, true), text)
assert(text:find('> _Compact done: threshold_', 1, true), text)
assert(text:find('> _Retry 1/3 in 250ms: rate limited_', 1, true), text)
assert(text:find('> _Retry done: success_', 1, true), text)
assert(text:find('## Extension error', 1, true) == nil, text)
assert(text:find('> **Extension error:** boom', 1, true), text)
assert(text:find('> **Error:** provider down', 1, true), text)
assert(text:find('> **Protocol error:** bad json', 1, true), text)

renderer.clear('Agent notice spacing')
renderer.handle_event({ type = 'agent_start' })
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'answer after start' } })
renderer.flush_live_render()
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('> _Agent start%._\n\n## Assistant[^\n]*\n\nanswer after start'), text)
assert(text:find('> _Agent start%._\n\n\n## Assistant') == nil, text)

local api = require('pi-dev.api')
local rpc = require('pi-dev.rpc')
rpc.request = function(message, cb)
  assert(message.type == 'abort', vim.inspect(message))
  if cb then
    cb({ success = true })
  end
  return message.type
end
api.abort()
renderer.handle_event({ type = 'agent_end' })
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('> _User cancelled._', 1, true), text)
assert(text:find('> _Agent done._', 1, true), text)
assert(text:find('## Agent done', 1, true) == nil, text)

renderer.render_messages({
  { role = 'toolResult', toolName = 'bash', content = 'tool result body' },
  { role = 'bashExecution', command = 'echo hi', output = 'hi' },
  { role = 'compactionSummary', summary = 'compact summary' },
  { role = 'branchSummary', summary = 'branch summary' },
  { role = 'custom', customType = 'mcp-ui', content = 'custom body' },
}, 'Role render')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('### Tool result: bash', 1, true), text)
assert(text:find('tool result body', 1, true), text)
assert(text:find('### Tool: bash', 1, true), text)
assert(text:find('Ran `echo hi`', 1, true), text)
assert(text:find('```bash\nhi\n```', 1, true), text)
assert(text:find('```shell', 1, true) == nil, text)
assert(text:find('# Compaction summary', 1, true), text)
assert(text:find('compact summary', 1, true), text)
assert(text:find('# Branch summary', 1, true), text)
assert(text:find('branch summary', 1, true), text)
assert(text:find('# /mcp-ui', 1, true), text)
assert(text:find('custom body', 1, true), text)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
