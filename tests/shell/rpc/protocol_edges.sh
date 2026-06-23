#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({
  exec = { bin = 'pi-edge-test', args = {} },
  rpc = { pool_size = 8, idle_timeout_ms = 0 },
  keymaps = { enable = false },
  auto_resume_last_session = false,
})
local events = require('pi-dev.events')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')

local function reset_rpc_state()
  state.rpc.runtimes = {}
  state.rpc.active_key = 'default'
  state.set_active_rpc_runtime('default')
  state.reset_rpc_runtime(state.active_rpc_runtime())
end

local function wait_for(predicate, message)
  assert(vim.wait(1000, predicate), message)
end

reset_rpc_state()

-- 1. CRLF-delimited events decode and carry runtime annotations.
local crlf_event
local star_events = {}
events.on('custom_rpc_event', function(event)
  crlf_event = event
end)
events.on('*', function(event)
  table.insert(star_events, event)
end)
rpc._handle_chunk('{"type":"custom_rpc_event","value":1}\r\n')
assert(crlf_event and crlf_event.value == 1, 'CRLF event should decode and emit')
assert(crlf_event.__pi_runtime_key == 'default', vim.inspect(crlf_event))
assert(crlf_event.__pi_active_runtime == true, vim.inspect(crlf_event))

-- 2. Blank chunks and empty JSONL lines are ignored without emitting events.
local star_before_blank = #star_events
rpc._handle_chunk('')
rpc._handle_chunk('\n\r\n')
assert(#star_events == star_before_blank, 'empty chunks/lines should not emit events')

-- 3. Multiple JSONL messages in one chunk are decoded independently.
local multi = {}
events.on('multi_one', function(event)
  table.insert(multi, event.type)
end)
events.on('multi_two', function(event)
  table.insert(multi, event.type)
end)
rpc._handle_chunk('{"type":"multi_one"}\n{"type":"multi_two"}\n')
assert(vim.deep_equal(multi, { 'multi_one', 'multi_two' }), vim.inspect(multi))

-- 4. Invalid JSON emits protocol_error and does not poison the following line.
local protocol_error
local after_bad_json
events.on('protocol_error', function(event)
  protocol_error = event
end)
events.on('after_bad_json', function(event)
  after_bad_json = event
end)
rpc._handle_chunk('{not json}\n{"type":"after_bad_json","ok":true}\n')
assert(protocol_error and protocol_error.line == '{not json}', 'invalid JSON should emit protocol_error')
assert(after_bad_json and after_bad_json.ok == true, 'valid event after protocol_error should still decode')

-- 5. pi-mcp-adapter /mcp-auth prints an OAuth URL outside JSONL; render it without protocol-error noise.
ui.show()
renderer.clear('MCP auth URL test')
local mcp_auth_url
protocol_error = nil
events.on('mcp_auth_url', function(event)
  mcp_auth_url = event
end)
rpc._handle_chunk('MCP Auth: Open this URL to authenticate example-auth-server:\nhttps://auth.example/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A19876%2Fcallback&state=abc\n')
assert(mcp_auth_url and mcp_auth_url.server == 'example-auth-server', vim.inspect(mcp_auth_url))
assert(mcp_auth_url.url:find('https://auth.example/authorize', 1, true), vim.inspect(mcp_auth_url))
assert(protocol_error == nil, 'mcp-auth URL lines must not render as protocol errors')
local rendered_auth = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(rendered_auth:find('MCP OAuth required for `example-auth-server`', 1, true), rendered_auth)
assert(rendered_auth:find('https://auth.example/authorize', 1, true), rendered_auth)
assert(rendered_auth:find('auth%-complete'), rendered_auth)

-- 6. Split response chunks do not resolve callbacks before the newline arrives.
local original_write = rpc.write
local written
rpc.write = function(message)
  written = vim.deepcopy(message)
  return true
end
local response
local request_id = rpc.request({ type = 'get_state' }, function(message)
  response = message
end)
assert(request_id and written.id == request_id, 'request should assign/write id')
assert(state.rpc.pending[request_id] ~= nil, 'request callback should be pending')
local encoded = vim.json.encode({ type = 'response', id = request_id, success = true, data = { ok = true } }) .. '\n'
rpc._handle_chunk(encoded:sub(1, 8))
assert(response == nil, 'partial JSONL chunk must not respond early')
rpc._handle_chunk(encoded:sub(9))
wait_for(function() return response ~= nil end, 'split response should resolve callback')
assert(response.success == true and response.data.ok == true)
assert(response.__pi_runtime_key == 'default' and response.__pi_active_runtime == true, vim.inspect(response))
assert(state.rpc.pending[request_id] == nil, 'resolved request should clear pending callback')
rpc.write = original_write

-- 7. Unsolicited responses are emitted as response events rather than dropped.
local unsolicited
events.on('response', function(event)
  if event.id == 'unsolicited-response' then
    unsolicited = event
  end
end)
rpc._handle_chunk(vim.json.encode({ type = 'response', id = 'unsolicited-response', success = true }) .. '\n')
assert(unsolicited and unsolicited.success == true, vim.inspect(unsolicited))

-- 8. Request ids and pending maps are isolated per Pi RPC runtime.
local branch_runtime = state.ensure_rpc_runtime('branch-runtime')
local branch_write
rpc.write = function(message, opts)
  branch_write = { message = vim.deepcopy(message), runtime = opts and opts.runtime }
  return true
end
local branch_response
local branch_request_id = rpc.request({ type = 'get_state' }, function(message)
  branch_response = message
end, { runtime = branch_runtime })
assert(branch_request_id == 'pi-dev-1', branch_request_id)
assert(branch_runtime.pending[branch_request_id] ~= nil, 'branch runtime should own its pending request')
assert(state.rpc.pending[branch_request_id] == nil, 'inactive branch request must not leak into active pending table')
assert(branch_write.runtime == branch_runtime, 'request should write to the explicit runtime')
rpc._handle_chunk(vim.json.encode({ type = 'response', id = branch_request_id, success = true, data = { sessionFile = 'branch.jsonl' } }) .. '\n', branch_runtime)
wait_for(function() return branch_response ~= nil end, 'branch runtime response should resolve')
assert(branch_response.__pi_runtime_key == 'branch-runtime', vim.inspect(branch_response))
assert(branch_response.__pi_active_runtime == false, vim.inspect(branch_response))
assert(branch_runtime.session_file == 'branch.jsonl', vim.inspect(branch_runtime))
assert(branch_runtime.pending[branch_request_id] == nil, 'branch pending callback should clear')
rpc.write = original_write

-- 9. Runtime event state tracks active/running/waiting/error status without exposing noisy tool names.
rpc._handle_chunk('{"type":"agent_start"}\n')
assert(state.statusline.active == true and state.statusline.status == 'running', vim.inspect(state.statusline))
rpc._handle_chunk(vim.json.encode({ type = 'tool_execution_start', toolName = 'bash\nwith-control-character-name-that-is-way-too-long' }) .. '\n')
assert(state.statusline.status == 'running', state.statusline.status)
assert(statusline.render_for_width(100):find('tool bash', 1, true) == nil, statusline.render_for_width(100))
rpc._handle_chunk(vim.json.encode({ type = 'extension_ui_request', id = 'perm-1', method = 'select', options = { 'Yes', 'No' } }) .. '\n')
assert(state.statusline.waiting_input == true and state.statusline.status == 'waiting input', vim.inspect(state.statusline))
rpc._handle_chunk('{"type":"provider_error","error":"provider down"}\n')
assert(state.statusline.status == 'error' and state.statusline.error == 'provider down', vim.inspect(state.statusline))

-- 10. Process exit rejects pending callbacks and resets runtime state.
reset_rpc_state()
local original_jobstart = vim.fn.jobstart
local original_jobwait = vim.fn.jobwait
local original_chansend = vim.fn.chansend
local running = {}
local exit_opts
vim.fn.jobstart = function(_, opts)
  exit_opts = opts
  running[701] = true
  return 701
end
vim.fn.jobwait = function(ids)
  local out = {}
  for index, id in ipairs(ids) do
    out[index] = running[id] and -1 or 0
  end
  return out
end
vim.fn.chansend = function()
  return 1
end
local job_id = rpc.start('exit-runtime')
assert(job_id == 701 and exit_opts and type(exit_opts.on_exit) == 'function', 'fake job should start')
local exit_runtime = state.ensure_rpc_runtime('exit-runtime')
local exit_response
local exit_request_id = rpc.request({ type = 'get_state' }, function(message)
  exit_response = message
end, { runtime = exit_runtime })
assert(exit_runtime.pending[exit_request_id], 'exit runtime request should be pending')
running[701] = false
exit_opts.on_exit(nil, 17)
wait_for(function() return exit_response ~= nil end, 'exit should fail pending callbacks')
assert(exit_response.success == false and exit_response.error == 'pi rpc process exited', vim.inspect(exit_response))
assert(exit_runtime.job_id == nil and exit_runtime.status == 'not connected', vim.inspect(exit_runtime))

-- 11. The Pi RPC pool permits 8 running runtimes, rejects the 9th, and frees stale stopped runtimes.
reset_rpc_state()
running = {}
local starts = {}
vim.fn.jobstart = function(_, opts)
  local id = 800 + #starts + 1
  table.insert(starts, { id = id, opts = opts })
  running[id] = true
  return id
end
vim.fn.jobwait = function(ids)
  local out = {}
  for index, id in ipairs(ids) do
    out[index] = running[id] and -1 or 0
  end
  return out
end
local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end
for index = 1, 8 do
  local id = rpc.start('pool-' .. index)
  assert(id == 800 + index, 'runtime #' .. index .. ' should start, got ' .. tostring(id))
end
assert(state.rpc_runtime_count({ running_only = true }) == 8, 'exactly 8 Pi RPC runtimes should be running')
local ninth = rpc.start('pool-9')
assert(ninth == nil, '9th Pi RPC runtime should be rejected at pool limit')
assert(#starts == 8, 'pool exhaustion must not spawn a 9th process')
assert(vim.wait(1000, function()
  return notifications[#notifications] and notifications[#notifications].message:find('Pi RPC pool exhausted %(8/8%)') ~= nil
end), vim.inspect(notifications))
running[801] = false
local after_stale = rpc.start('pool-9')
assert(after_stale == 809, 'stale stopped runtime should be rechecked and free a pool slot')
assert(#starts == 9, 'freed slot should start exactly one replacement runtime')
assert(state.rpc_runtime_count({ running_only = true }) == 8, 'pool should remain capped at 8 running runtimes')

vim.notify = original_notify
vim.fn.jobstart = original_jobstart
vim.fn.jobwait = original_jobwait
vim.fn.chansend = original_chansend
LUA

output="$( {
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1 )" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
