#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT_DIR/tests/support/shell-test.sh"

script="$(pidev_lua_file)"
cat >"$script" <<'LUA'
local pi_dev = require('pi-dev')
pi_dev.setup({ keymaps = { prefix = '<leader>a' } })
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

ui.show()

local messages = {
  {
    role = 'assistant',
    content = {
      { type = 'toolCall', id = 'restored-subagent', name = 'subagent', args = { tasks = { { agent = 'reviewer', task = 'review restored output' } } } },
    },
    timestamp = '2026-01-01T00:00:00.000Z',
  },
  {
    role = 'toolResult',
    toolCallId = 'restored-subagent',
    timestamp = '2026-01-01T00:00:01.000Z',
    content = vim.json.encode({
      details = {
        results = {
          {
            agent = 'reviewer',
            status = 'completed',
            task = 'review restored output',
            output = 'restored child result body',
            progress = { turnCount = 1, toolCount = 0, tokens = 42 },
          },
        },
      },
    }),
  },
}

local function buf_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

local function open_restored_child(label)
  local parent = buf_text(state.ui.output_buf)
  assert(parent:find('### Tool: subagent parallel tasks', 1, true), label .. '\n' .. parent)
  assert(parent:find('##### reviewer %- completed'), label .. '\n' .. parent)
  assert(parent:find('**Task:** review restored output', 1, true), label .. '\n' .. parent)
  assert(parent:find('restored child result body', 1, true) == nil, label .. '\n' .. parent)

  local child_line
  for index, line in ipairs(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)) do
    if line:find('**Task:** review restored output', 1, true) then
      child_line = index
      break
    end
  end
  assert(child_line, label .. '\n' .. parent)

  vim.api.nvim_set_current_win(state.ui.output_win)
  vim.api.nvim_win_set_cursor(state.ui.output_win, { child_line, 0 })
  vim.cmd('PiDevSubagentOpen')
  assert(state.ui.subagent_view, label .. ': subagent view should open after restored render')
  assert(vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.subagent_view.buf, label .. ': output window should show subagent buffer')
  assert(vim.bo[state.ui.input_buf].modifiable == false, label .. ': input must be locked in restored subagent buffer')

  local child = buf_text(state.ui.subagent_view.buf)
  assert(child:find('# Pi chat subagent (deep 1): reviewer', 1, true), label .. '\n' .. child)
  assert(child:find('restored child result body', 1, true), label .. '\n' .. child)
  assert(child:find('## Main info', 1, true), label .. '\n' .. child)
  assert(child:find('## Result', 1, true), label .. '\n' .. child)

  vim.cmd('PiDevSubagentParent')
  assert(state.ui.subagent_view == nil, label .. ': subagent view should close')
  assert(vim.api.nvim_win_get_buf(state.ui.output_win) == state.ui.output_buf, label .. ': root output buffer should be restored')
end

renderer.render_messages(messages, 'restored subagent')
open_restored_child('render_messages')

renderer.render_messages_chunked(messages, 'restored subagent chunked', { chunk_size = 10, chunk_delay_ms = 0, chunk_budget_ms = 100 })
open_restored_child('render_messages_chunked')
LUA

pidev_run_lua_file "$script"
