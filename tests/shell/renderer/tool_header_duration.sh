#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 10 } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local format = require('pi-dev.format')

local function concealed_heading_text(line)
  return (line or ''):gsub('^#+%s+', '')
end

local function markdown_heading_visible_width(line)
  return vim.fn.strdisplaywidth(concealed_heading_text(line))
end

local function closing_paren_column(line)
  local before = concealed_heading_text(line):match('^(.*%))%s*$')
  return before and vim.fn.strdisplaywidth(before) or nil
end

ui.show()
renderer.clear('tool duration headers')
renderer.append_user('prompt with time', '2026-01-01T00:00:00.000Z')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'bash-duration',
  toolName = 'bash',
  args = { command = 'echo timed' },
  timestamp = '2026-01-01T00:00:02.000Z',
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'bash-duration',
  toolName = 'bash',
  result = { content = { { type = 'text', text = 'done' } } },
  timestamp = '2026-01-01T00:00:03.250Z',
})
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-duration',
  toolName = 'subagent',
  args = { agent = 'reviewer', task = 'review this' },
  timestamp = '2026-01-01T00:00:10.000Z',
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'subagent-duration',
  toolName = 'subagent',
  args = { agent = 'reviewer', task = 'review this' },
  result = { content = { { type = 'text', text = vim.json.encode({ results = { { agent = 'reviewer', status = 'completed', response = 'ok' } } }) } } },
  timestamp = '2026-01-01T00:00:12.500Z',
})
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'long-untruncated-duration',
  toolName = 'bash',
  args = { command = 'printf medium header' },
  timestamp = '2026-01-01T00:00:20.000Z',
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'long-untruncated-duration',
  toolName = 'bash',
  args = { command = 'printf medium header' },
  result = { content = { { type = 'text', text = 'done' } } },
  timestamp = '2026-01-01T00:00:20.108Z',
})
renderer.flush_pending_tool_renders()
assert(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
  return text:find('2.5s', 1, true) ~= nil and text:find('108ms', 1, true) ~= nil
end), table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'))

local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local rendered_text = table.concat(lines, '\n')
local function first_line_containing(needle)
  for _, line in ipairs(lines) do
    if tostring(line or ''):find(needle, 1, true) then
      return line
    end
  end
end
local user_header = first_line_containing('## User')
local bash_header = first_line_containing('(1.25s)')
local subagent_header = first_line_containing('(2.5s)')
local long_untruncated_header = first_line_containing('(108ms)')
assert(user_header, rendered_text)
assert(bash_header, rendered_text)
assert(subagent_header, rendered_text)
assert(long_untruncated_header and long_untruncated_header:find('...', 1, true) == nil, rendered_text)
local width = format.window_text_width(state.ui.output_win)
assert(vim.fn.strdisplaywidth(bash_header) <= width - 3, bash_header)
assert(vim.fn.strdisplaywidth(subagent_header) <= width - 3, subagent_header)
assert(vim.fn.strdisplaywidth(long_untruncated_header) <= width - 3, long_untruncated_header)
assert(markdown_heading_visible_width(bash_header) <= width, bash_header)
assert(markdown_heading_visible_width(subagent_header) <= width, subagent_header)
local live_tool_column = closing_paren_column(user_header) - 1
assert(closing_paren_column(bash_header) == live_tool_column, user_header .. '\n' .. bash_header)
assert(closing_paren_column(subagent_header) == live_tool_column, user_header .. '\n' .. subagent_header)
assert(closing_paren_column(long_untruncated_header) == live_tool_column, user_header .. '\n' .. long_untruncated_header)

renderer.clear('truncated tool duration header')
renderer.append_user('prompt with time', '2026-01-01T00:00:00.000Z')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'truncated-duration',
  toolName = 'bash',
  args = { command = 'rg --line-number --hidden --glob "*.lua" extremely-long-search-term-that-should-not-fit-on-one-header-line lua/pi-dev' },
  timestamp = '2026-01-01T00:00:02.000Z',
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'truncated-duration',
  toolName = 'bash',
  result = { content = { { type = 'text', text = 'done' } } },
  timestamp = '2026-01-01T00:00:03.250Z',
})
renderer.flush_pending_tool_renders()
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'):find('1.25s', 1, true) ~= nil
end), table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'))
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local truncated_header = text:match('(### Tool:[^\n]*%(1%.25s%))')
assert(truncated_header and truncated_header:find('...', 1, true), text)
assert(vim.fn.strdisplaywidth(truncated_header) <= width - 3, truncated_header)
assert(markdown_heading_visible_width(truncated_header) <= width, truncated_header)
assert(closing_paren_column(truncated_header) == live_tool_column, bash_header .. '\n' .. truncated_header)

renderer.render_messages({
  { role = 'assistant', __pi_timestamp = '2026-01-01T00:04:00.000Z', content = 'before tool' },
}, 'assistant tool header alignment')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'assistant-code-search-duration',
  toolName = 'code_search',
  args = {},
  timestamp = '2026-01-01T00:04:02.000Z',
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'assistant-code-search-duration',
  toolName = 'code_search',
  args = {},
  result = { content = { { type = 'text', text = 'done' } } },
  timestamp = '2026-01-01T00:04:12.100Z',
})
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'assistant-long-duration',
  toolName = 'bash',
  args = { command = 'printf medium header' },
  timestamp = '2026-01-01T00:04:12.200Z',
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'assistant-long-duration',
  toolName = 'bash',
  args = { command = 'printf medium header' },
  result = { content = { { type = 'text', text = 'done' } } },
  timestamp = '2026-01-01T00:04:12.308Z',
})
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'assistant-truncated-duration',
  toolName = 'bash',
  args = { command = 'cd ./tmp/pi-dev-test/project && git status --short && echo extra words for truncation' },
  timestamp = '2026-01-01T00:04:13.000Z',
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'assistant-truncated-duration',
  toolName = 'bash',
  args = { command = 'cd ./tmp/pi-dev-test/project && git status --short && echo extra words for truncation' },
  result = { content = { { type = 'text', text = 'done' } } },
  timestamp = '2026-01-01T00:04:13.108Z',
})
renderer.flush_pending_tool_renders()
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local assistant_header = text:match('(## Assistant[^\n]*)')
local code_search_header = text:match('(### Tool: code_search[^\n]*%(10%.1s%))')
local assistant_long_header = text:match('(### Tool: bash printf medium header[^\n]*%(108ms%))')
local assistant_truncated_header = text:match('(### Tool: bash[^\n]*%.%.%.[^\n]*%(108ms%))')
assert(assistant_header, text)
assert(code_search_header, text)
assert(assistant_long_header, text)
assert(assistant_truncated_header, text)
local assistant_tool_column = closing_paren_column(assistant_header) - 1
assert(closing_paren_column(code_search_header) == assistant_tool_column, assistant_header .. '\n' .. code_search_header)
assert(closing_paren_column(assistant_long_header) == assistant_tool_column, assistant_header .. '\n' .. assistant_long_header)
assert(closing_paren_column(assistant_truncated_header) == assistant_tool_column, assistant_header .. '\n' .. assistant_truncated_header)

renderer.clear('tool wall duration headers')
renderer.append_user('prompt without RPC timestamps', '2026-01-01T00:00:00.000Z')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'wall-duration',
  toolName = 'bash',
  args = { command = 'echo wall duration' },
})
vim.wait(20, function() return false end)
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'wall-duration',
  toolName = 'bash',
  result = { content = { { type = 'text', text = 'done' } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local wall_header = text:match('(### Tool: bash echo wall duration[^\n]*)')
assert(wall_header and wall_header:find('ms)', 1, true), text)
assert(vim.fn.strdisplaywidth(wall_header) <= width - 3, wall_header)
assert(closing_paren_column(wall_header) == live_tool_column, wall_header)

renderer.render_messages({
  {
    role = 'assistant',
    __pi_timestamp = '2026-01-01T00:01:00.000Z',
    content = {
      { type = 'text', text = 'before restored tool' },
      { type = 'toolCall', id = 'restored-read', name = 'read', arguments = { path = 'restored.txt' } },
    },
  },
  {
    role = 'toolResult',
    toolCallId = 'restored-read',
    toolName = 'read',
    __pi_timestamp = '2026-01-01T00:01:04.750Z',
    content = 'restored output',
  },
}, 'restored tool duration')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local restored_header = text:match('(### Tool: read restored%.txt[^\n]*)')
local restored_assistant_header = text:match('(## Assistant[^\n]*)')
assert(restored_header and restored_header:find('(4.75s)', 1, true), text)
assert(restored_assistant_header, text)
assert(vim.fn.strdisplaywidth(restored_header) <= width - 3, restored_header)
assert(closing_paren_column(restored_header) == closing_paren_column(restored_assistant_header) - 1, restored_assistant_header .. '\n' .. restored_header)

renderer.clear('inactive live duration survives runtime switch')
state.set_active_rpc_runtime('default')
local inactive = state.ensure_rpc_runtime('branch-with-live-tool')
inactive.job_id = 9876
rpc._handle_chunk(vim.json.encode({
  type = 'tool_execution_start',
  toolCallId = 'runtime-live-tool',
  toolName = 'bash',
  args = { command = 'printf medium header' },
  timestamp = '2026-01-01T00:02:00.000Z',
}) .. '\n', inactive)
rpc._handle_chunk(vim.json.encode({
  type = 'tool_execution_end',
  toolCallId = 'runtime-live-tool',
  toolName = 'bash',
  args = { command = 'printf medium header' },
  result = { content = { { type = 'text', text = 'done' } } },
  durationMs = 108,
  timestamp = '2026-01-01T00:02:00.108Z',
}) .. '\n', inactive)
state.set_active_rpc_runtime('branch-with-live-tool')
renderer.render_messages({
  {
    role = 'assistant',
    __pi_timestamp = '2026-01-01T00:02:00.000Z',
    content = {
      { type = 'text', text = 'before loaded live tool' },
      { type = 'toolCall', id = 'loaded-live-tool-from-history', name = 'bash', arguments = { command = 'printf medium header' } },
    },
  },
  {
    role = 'toolResult',
    toolCallId = 'loaded-live-tool-from-history',
    toolName = 'bash',
    content = 'loaded output without timestamp duration',
  },
}, 'loaded live duration')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local loaded_live_header = text:match('(### Tool: bash printf medium header[^\n]*%(108ms%))')
local loaded_live_assistant = text:match('(## Assistant[^\n]*)')
assert(loaded_live_header, text)
assert(loaded_live_assistant, text)
assert(closing_paren_column(loaded_live_header) == closing_paren_column(loaded_live_assistant) - 1, loaded_live_assistant .. '\n' .. loaded_live_header)

local sessions = require('pi-dev.sessions')
rpc.request = function(message, cb)
  assert(message.type == 'get_messages', vim.inspect(message))
  cb({
    success = true,
    data = {
      messages = {
        {
          role = 'assistant',
          __pi_timestamp = '2026-01-01T00:03:00.000Z',
          content = {
            { type = 'text', text = 'before active load tool' },
            { type = 'toolCall', id = 'active-loaded-history-id', name = 'bash', arguments = { command = 'printf medium header' } },
          },
        },
        {
          role = 'toolResult',
          toolCallId = 'active-loaded-history-id',
          toolName = 'bash',
          content = 'active loaded output without timestamp duration',
        },
      },
    },
  })
  return message.type
end
sessions.render_current('active loaded duration', false, { chunk_size = 10, chunk_delay_ms = 0 })
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'):find('108ms', 1, true) ~= nil
end), table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'))
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local active_loaded_header = text:match('(### Tool: bash printf medium header[^\n]*%(108ms%))')
local active_loaded_assistant = text:match('(## Assistant[^\n]*)')
assert(active_loaded_header, text)
assert(active_loaded_assistant, text)
assert(closing_paren_column(active_loaded_header) == closing_paren_column(active_loaded_assistant) - 1, active_loaded_assistant .. '\n' .. active_loaded_header)

state.set_active_rpc_runtime('hidden-result-active-load')
rpc.request = function(message, cb)
  assert(message.type == 'get_messages', vim.inspect(message))
  cb({
    success = true,
    data = {
      messages = {
        {
          role = 'assistant',
          __pi_timestamp = '2026-01-01T00:05:00.000Z',
          content = {
            { type = 'text', text = 'before hidden active result' },
            { type = 'toolCall', id = 'hidden-active-id', name = 'bash', arguments = { command = 'printf hidden result duration' } },
          },
        },
        {
          role = 'toolResult',
          toolCallId = 'hidden-active-id',
          toolName = 'bash',
          __pi_timestamp = '2026-01-01T00:05:00.108Z',
          content = 'hidden active result output',
        },
      },
    },
  })
  return message.type
end
sessions.render_current('hidden active duration', false, { session_render = { include_tool_results = false, chunk_size = 10, chunk_delay_ms = 0 } })
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'):find('108ms', 1, true) ~= nil
end), table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'))
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local hidden_active_header = text:match('(### Tool: bash printf hidden result duration[^\n]*%(108ms%))')
local hidden_active_assistant = text:match('(## Assistant[^\n]*)')
assert(hidden_active_header, text)
assert(hidden_active_assistant, text)
assert(text:find('hidden active result output', 1, true) == nil, text)
assert(closing_paren_column(hidden_active_header) == closing_paren_column(hidden_active_assistant) - 1, hidden_active_assistant .. '\n' .. hidden_active_header)

local session_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({
    type = 'message',
    id = 'file-assistant',
    timestamp = '2026-01-01T00:06:00.000Z',
    message = {
      role = 'assistant',
      content = {
        { type = 'text', text = 'before hidden file result' },
        { type = 'toolCall', id = 'hidden-file-id', name = 'bash', arguments = { command = 'printf hidden file duration' } },
      },
    },
  }),
  vim.json.encode({
    type = 'message',
    id = 'file-result',
    timestamp = '2026-01-01T00:06:00.108Z',
    message = { role = 'toolResult', toolCallId = 'hidden-file-id', toolName = 'bash', content = 'hidden file result output' },
  }),
}, session_file)
state.set_active_rpc_runtime('hidden-result-file-load')
sessions.render_current('hidden file duration', session_file, { session_render = { include_tool_results = false, chunk_size = 10, chunk_delay_ms = 0 } })
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'):find('108ms', 1, true) ~= nil
end), table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n'))
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local hidden_file_header = text:match('(### Tool: bash printf hidden file duration[^\n]*%(108ms%))')
local hidden_file_assistant = text:match('(## Assistant[^\n]*)')
assert(hidden_file_header, text)
assert(hidden_file_assistant, text)
assert(text:find('hidden file result output', 1, true) == nil, text)
assert(closing_paren_column(hidden_file_header) == closing_paren_column(hidden_file_assistant) - 1, hidden_file_assistant .. '\n' .. hidden_file_header)

require('pi-dev.config').options.ui.render.fold_tool_output_over = 1
renderer.clear('live assistant header after folded tool')
vim.wo[state.ui.output_win].foldcolumn = 'auto:1'
renderer.append_user('prompt before fold column', '2026-01-01T00:07:00.000Z')
renderer.handle_event({
  type = 'message_start',
  message = { role = 'assistant' },
  timestamp = '2026-01-01T00:07:01.000Z',
})
renderer.handle_event({
  type = 'message_update',
  assistantMessageEvent = { type = 'text_delta', delta = 'answer before folded tool' },
})
renderer.flush_live_render()
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'fold-column-tool',
  toolName = 'bash',
  args = { command = 'printf fold column' },
  timestamp = '2026-01-01T00:07:02.000Z',
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'fold-column-tool',
  toolName = 'bash',
  args = { command = 'printf fold column' },
  result = { content = { { type = 'text', text = table.concat({ 'line 1', 'line 2', 'line 3' }, '\n') } } },
  durationMs = 108,
  timestamp = '2026-01-01T00:07:02.108Z',
})
renderer.flush_pending_tool_renders()
renderer.handle_event({
  type = 'message_start',
  message = { role = 'assistant' },
  timestamp = '2026-01-01T00:07:03.000Z',
})
renderer.handle_event({
  type = 'message_update',
  assistantMessageEvent = { type = 'text_delta', delta = 'final live answer after folded tool' },
})
renderer.flush_live_render()
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local assistant_headers = {}
for _, line in ipairs(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)) do
  if line:find('## Assistant', 1, true) then
    table.insert(assistant_headers, line)
  end
end
assert(#assistant_headers == 2, text)
assert(closing_paren_column(assistant_headers[2]) == closing_paren_column(assistant_headers[1]), assistant_headers[1] .. '\n' .. assistant_headers[2])
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
