#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 8 } })
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')
local statusline = require('pi-dev.statusline')
local runtime_status = require('pi-dev.runtime_status')

state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

local function line()
  ui.refresh_chrome()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.status_buf, 0, -1, false), '\n')
end

local function push(runtime, event)
  rpc._handle_chunk(vim.json.encode(event) .. '\n', runtime)
  assert(vim.wait(1000, function() return line() ~= nil end), 'status separator did not refresh')
  return line()
end

ui.show()
local active = state.ensure_rpc_runtime('active')
active.job_id = 101
state.set_active_rpc_runtime('active')
local background = state.ensure_rpc_runtime('background')
background.job_id = 202

local text = push(active, { type = 'agent_start' })
assert(text:find('Pi status: run', 1, true), text)

text = push(active, { type = 'message_start', message = { role = 'assistant' } })
assert(text:find('Pi status: run', 1, true), text)
assert(text:find('assistant', 1, true) == nil, text)

text = push(active, { type = 'message_start', message = { role = 'user' } })
assert(text:find('Pi status: run', 1, true), text)
assert(text:find('user message', 1, true) == nil, text)

text = push(active, { type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = 'thinking' } })
assert(text:find('Pi status: run', 1, true), text)
assert(text:find('thinking', 1, true) == nil, text)

text = push(active, { type = 'tool_execution_start', toolName = 'bash', toolCallId = 't1', args = { command = 'echo hi' } })
assert(text:find('Pi status: run', 1, true), text)
assert(text:find('tool bash', 1, true) == nil, text)
assert(statusline.render_for_width(80):find('tool bash', 1, true) == nil, statusline.render_for_width(80))

text = push(active, { type = 'tool_execution_end', toolName = 'bash', toolCallId = 't1', result = { content = { { type = 'text', text = 'ok' } } } })
assert(text:find('Pi status: run', 1, true), text)
assert(text:find('tool bash', 1, true) == nil, text)
assert(text:find('done', 1, true) == nil, text)

text = push(active, { type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'answer' } })
assert(text:find('Pi status: run', 1, true), text)
assert(text:find('answering', 1, true) == nil, text)

text = push(background, { type = 'agent_start' })
assert(text:find('run 2/2', 1, true), text)

text = push(background, { type = 'tool_execution_start', toolName = 'read', toolCallId = 't2' })
assert(text:find('run 2/2', 1, true), text)
assert(text:find('tool read', 1, true) == nil, text)

text = push(background, { type = 'extension_ui_request', id = 'perm-bg', method = 'select', options = { 'Yes', 'No' } })
assert(text:find('run 1/2', 1, true), text)
assert(text:find('wait 1', 1, true), text)

text = push(background, { type = 'agent_end' })
assert(text:find('run 1/2', 1, true), text)

state.set_active_rpc_runtime('active')
active.branch_root = 'root-session.jsonl'
active.branch_entry_id = 'active-entry'
background.branch_root = 'root-session.jsonl'
background.branch_entry_id = 'background-entry'
statusline.update_from_state({ model = { provider = 'active', id = 'model' }, thinkingLevel = 'low', isStreaming = false }, { runtime = active })
statusline.update_from_stats({ cost = 0.01, tokens = { total = 111 }, contextUsage = { percent = 10 } }, { runtime = active })
background.pending_extension_ui_request = nil
background.waiting_input = false
statusline.update_from_state({ model = { provider = 'background', id = 'model' }, thinkingLevel = 'high', isStreaming = true }, { runtime = background })
statusline.update_from_stats({ cost = 0.25, tokens = { total = 222 }, contextUsage = { percent = 20 } }, { runtime = background })
text = statusline.render_for_width(160)
assert(text:find('active/model', 1, true), text)
assert(text:find('background/model', 1, true) == nil, text)
assert(text:find('111 tok', 1, true), text)
assert(runtime_status.badge(background) == '[run]', 'tree badge should reflect non-active Pi RPC runtime state')
state.set_active_rpc_runtime('background')
text = statusline.render_for_width(160)
assert(text:find('background/model', 1, true), text)
assert(text:find('active/model', 1, true) == nil, text)
assert(text:find('222 tok', 1, true), text)
assert(text:find('think high', 1, true) == nil, text)
state.set_active_rpc_runtime('active')
text = statusline.render_for_width(160)
assert(text:find('active/model', 1, true), text)
assert(text:find('background/model', 1, true) == nil, text)

local original_refresh_chrome = ui.refresh_chrome
local chrome_refreshes = 0
ui.refresh_chrome = function(...)
  chrome_refreshes = chrome_refreshes + 1
  return original_refresh_chrome(...)
end
for index = 1, 200 do
  rpc._handle_chunk(vim.json.encode({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = tostring(index) } }) .. '\n', active)
end
assert(vim.wait(1000, function() return chrome_refreshes > 0 end), 'chrome refresh should run after event burst')
assert(chrome_refreshes <= 5, 'wildcard chrome refreshes should be coalesced, got ' .. tostring(chrome_refreshes))
ui.refresh_chrome = original_refresh_chrome

local response_seen = false
local unsubscribe = require('pi-dev.events').on('*', function(event)
  if event.type == 'response' then
    response_seen = true
  end
end)
local req_id = 'status-response-test'
background.pending[req_id] = { callback = function() end }
rpc._handle_chunk(vim.json.encode({ type = 'response', id = req_id, success = true, data = { isStreaming = false } }) .. '\n', background)
assert(response_seen, 'pending RPC responses should emit wildcard events for status/chrome refresh')
unsubscribe()
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
