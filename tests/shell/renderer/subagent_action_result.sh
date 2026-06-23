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
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

ui.show()
renderer.render_messages({
  {
    role = 'assistant',
    timestamp = '2026-01-01T00:00:00.000Z',
    content = {
      { type = 'toolCall', id = 'status', name = 'subagent', args = { action = 'status' } },
      { type = 'toolCall', id = 'interrupt', name = 'subagent', args = { action = 'interrupt' } },
      { type = 'toolCall', id = 'bash', name = 'bash', args = { command = 'git diff --stat d5ec4fd..HEAD || true\ngit diff --name-only d5ec4fd..HEAD || true' } },
    },
  },
  {
    role = 'toolResult',
    toolCallId = 'status',
    timestamp = '2026-01-01T00:00:00.111Z',
    content = 'Run: example-run\nState: running',
  },
  {
    role = 'toolResult',
    toolCallId = 'interrupt',
    timestamp = '2026-01-01T00:00:00.170Z',
    content = 'No interrupt-capable run found in this session',
  },
  {
    role = 'toolResult',
    toolCallId = 'bash',
    timestamp = '2026-01-01T00:00:01.046Z',
    content = '40 files changed\ndoc/pi-dev.txt',
  },
}, 'subagent action result')

local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('### Tool: subagent status', 1, true), text)
assert(text:find('### Tool: subagent interrupt', 1, true), text)
assert(text:find('Run: example%-run'), text)
assert(text:find('State: running', 1, true), text)
assert(text:find('No interrupt%-capable run found in this session'), text)
assert(text:find('### Tool: bash git diff', 1, true), text)
assert(not text:find('##### subagent\n\n###### Main info', 1, true), text)
LUA

pidev_run_lua_file "$script"
