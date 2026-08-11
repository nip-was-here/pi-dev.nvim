#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat >"$script" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local renderer = require('pi-dev.renderer')
local extension_ui = require('pi-dev.extension_ui')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

rpc.write = function()
  return true
end
state.ensure_rpc_runtime('default').job_id = 123
state.rpc.job_id = 123
state.is_job_running = function(runtime)
  return runtime == nil or runtime.job_id ~= nil
end

ui.show()
renderer.clear('subagent_wait permission')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'wait-tool',
  toolName = 'subagent_wait',
  args = { id = 'example-run', timeoutMs = 600000 },
})
extension_ui.handle_request({
  type = 'extension_ui_request',
  id = 'perm-subagent-wait',
  method = 'select',
  title = [[Permission Required
Current agent requested tool 'subagent_wait' with input {"id":"example-run","timeoutMs":600000}. Allow this call?]],
  options = { 'Yes', 'No' },
})
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'permission interaction should render')

local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('### Tool: subagent_wait', 1, true), text)
assert(text:find('\n#### Permission request: tool `subagent_wait`', 1, true), text)
assert(text:find('\n##### subagent\n\n###### Permission request: tool `subagent_wait`', 1, true) == nil, text)
assert(text:find('\n###### Permission request: tool `subagent_wait`', 1, true) == nil, text)
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf, 'permission decision should stay in the lower interaction pane')
LUA

pidev_run_lua_file "$script"
