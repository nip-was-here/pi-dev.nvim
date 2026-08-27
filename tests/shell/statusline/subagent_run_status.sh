#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat > "$script" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 8 } })

local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')

local function status_label()
  return statusline.short_status_label(state.statusline.status)
end

statusline.handle_event({ type = 'agent_start' })
assert(status_label() == 'run', state.statusline.status)

statusline.handle_event({
  type = 'tool_execution_start',
  toolName = 'subagent',
  toolCallId = 'sa-call',
  args = { agent = 'example-agent', task = 'Inspect ExamplePrompt behavior.' },
})
assert(state.statusline.status == 'subagent run', state.statusline.status)
assert(status_label() == 'sa_run', state.statusline.status)
assert(statusline.render_for_width(80):find('Pi status: sa_run', 1, true), statusline.render_for_width(80))

statusline.handle_event({
  type = 'tool_execution_update',
  toolName = 'subagent',
  toolCallId = 'sa-call',
  args = { agent = 'example-agent' },
  partialResult = { results = { { agent = 'example-agent', status = 'running' } } },
})
assert(status_label() == 'sa_run', state.statusline.status)

statusline.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'still delegated' } })
assert(status_label() == 'sa_run', 'subagent activity should not collapse to generic run')
statusline.update_from_state({ isStreaming = false })
assert(status_label() == 'sa_run', 'subagent activity should not collapse to idle')
assert(statusline.render_for_width(80):find('Pi status: sa_run', 1, true), statusline.render_for_width(80))

statusline.handle_event({
  type = 'tool_execution_update',
  toolName = 'subagent',
  toolCallId = 'sa-call',
  args = { agent = 'example-agent' },
  partialResult = { results = { { agent = 'example-agent', status = 'waiting input' } } },
})
assert(state.statusline.status == 'waiting input', state.statusline.status)
assert(status_label() == 'wait', state.statusline.status)

statusline.handle_event({
  type = 'tool_execution_update',
  toolName = 'subagent',
  toolCallId = 'sa-call',
  args = { agent = 'example-agent' },
  partialResult = { results = { { agent = 'example-agent', status = 'running' } } },
})
assert(status_label() == 'sa_run', 'non-interactive subagent progress should reclaim false wait')

statusline.handle_event({
  type = 'message_start',
  message = { role = 'assistant' },
})
statusline.handle_event({
  type = 'tool_execution_end',
  toolName = 'subagent',
  toolCallId = 'sa-call',
  args = { agent = 'example-agent' },
  result = { results = { { agent = 'example-agent', status = 'completed' } } },
})
assert(status_label() == 'run', state.statusline.status)

statusline.handle_event({
  type = 'tool_execution_start',
  toolName = 'subagent_wait',
  toolCallId = 'wait-call',
  args = { all = true },
})
assert(status_label() == 'sa_wait', state.statusline.status)
LUA

pidev_run_lua_file "$script"
