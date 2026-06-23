#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, rpc = { idle_timeout_ms = 0 } })
local api = require('pi-dev.api')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

vim.fn.jobstart = function()
  return math.random(1000, 2000)
end
vim.fn.jobwait = function()
  return { -1 }
end

local sent = {}
local function interaction_opts(runtime_key, request_id, title, value)
  return {
    runtime_key = runtime_key,
    request_id = request_id,
    title = title,
    kind = 'permission',
    items = { { label = 'Answer', value = value } },
    on_submit = function(item)
      table.insert(sent, { id = request_id, value = item and item.value })
    end,
  }
end

rpc.request = function(message, cb)
  if message.type == 'get_state' then
    if cb then cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} }) end
  elseif message.type == 'get_fork_messages' or message.type == 'get_messages' then
    if cb then cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { messages = {} } }) end
  end
  return message.type
end

local queued = state.ensure_rpc_runtime('queued-runtime')
queued.job_id = 101
queued.label = 'A queued runtime'
queued.waiting_input = true
queued.status = 'waiting input'
queued.interaction_queue = { { kind = 'select', opts = interaction_opts('queued-runtime', 'queued-select', 'Queued select', 'queued answer') } }

local current = state.ensure_rpc_runtime('current-runtime')
current.job_id = 102
current.label = 'B current runtime'
current.waiting_input = true
current.status = 'waiting input'
current.current_extension_interaction = { kind = 'select', opts = interaction_opts('current-runtime', 'current-select', 'Current select', 'current answer') }

api.waiting()
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Pi waiting input'
end), 'waiting picker did not open')
assert(state.ui.interaction.surface == 'output', 'waiting tree should use the large output/session buffer')
local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(text:find('A queued runtime', 1, true), text)
assert(text:find('B current runtime', 1, true), text)
assert(text:find('%[wait%]'), text)

vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function()
  return state.rpc.active_key == 'queued-runtime' and state.ui.interaction and state.ui.interaction.title == 'Queued select'
end), 'selecting queued waiting runtime should restore queued interaction')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), 'queued interaction submit missing')
assert(sent[1].id == 'queued-select' and sent[1].value == 'queued answer', vim.inspect(sent[1]))
assert(#(queued.interaction_queue or {}) == 0, 'queued runtime queue should be consumed')

api.waiting()
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.title == 'Pi waiting input'
end), 'second waiting picker did not open')
text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(text:find('B current runtime', 1, true), text)
assert(text:find('A queued runtime', 1, true) == nil, text)
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function()
  return state.rpc.active_key == 'current-runtime' and state.ui.interaction and state.ui.interaction.title == 'Current select'
end), 'selecting saved-current waiting runtime should restore current interaction')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[2] ~= nil end), 'current interaction submit missing')
assert(sent[2].id == 'current-select' and sent[2].value == 'current answer', vim.inspect(sent[2]))
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
