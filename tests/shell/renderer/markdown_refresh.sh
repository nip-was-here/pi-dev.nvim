#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

output="$({
  pidev_nvim_output \
    +"lua _G.pi_md_calls = {}; package.preload['render-markdown'] = function() return { set_buf = function(enabled) table.insert(_G.pi_md_calls, { kind = 'set_buf', enabled = enabled, buf = vim.api.nvim_get_current_buf() }) end, render = function(opts) table.insert(_G.pi_md_calls, { kind = 'render', buf = opts.buf, win = opts.win, event = opts.event }) end } end" \
    +"lua require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 8 }, session_render = { chunk_size = 1, chunk_delay_ms = 1 } })" \
    +"lua local ui = require('pi-dev.ui'); local state = require('pi-dev.state'); ui.show(); assert(vim.wait(1000, function() return #_G.pi_md_calls > 0 end), vim.inspect(_G.pi_md_calls)); local found = false; for _, call in ipairs(_G.pi_md_calls) do if call.kind == 'render' and call.buf == state.ui.output_buf and call.win == state.ui.output_win and call.event == 'PiDevRefresh' then found = true end end; assert(found, vim.inspect(_G.pi_md_calls)); _G.pi_md_calls = {}" \
    +"lua local renderer = require('pi-dev.renderer'); local state = require('pi-dev.state'); renderer.render_messages_chunked({ { role = 'user', content = 'chunk user' }, { role = 'assistant', content = 'chunk assistant' } }, 'Chunked session', { chunk_size = 1, chunk_delay_ms = 1 }); assert(vim.wait(1000, function() local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\\n'); return text:find('chunk assistant', 1, true) and #_G.pi_md_calls > 0 end), vim.inspect(_G.pi_md_calls)); local found = false; for _, call in ipairs(_G.pi_md_calls) do if call.kind == 'render' and call.buf == state.ui.output_buf and call.win == state.ui.output_win and call.event == 'PiDevRefresh' then found = true end end; assert(found, vim.inspect(_G.pi_md_calls))" \
    +"lua local renderer = require('pi-dev.renderer'); local state = require('pi-dev.state'); renderer.clear('Permission refresh'); renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } }); renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'streaming answer' } }); _G.pi_md_calls = {}; renderer.append_permission_request('perm-refresh', 'bash pwd', { 'Permission Required', 'Allow it?' }); assert(vim.wait(1000, function() return #_G.pi_md_calls > 0 end), vim.inspect(_G.pi_md_calls)); local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false); local header; for index, line in ipairs(lines) do if line:find('^#### Permission request') then header = index end end; assert(header and header > 1 and lines[header - 1] == '', vim.inspect(lines)); local found = false; for _, call in ipairs(_G.pi_md_calls) do if call.kind == 'render' and call.buf == state.ui.output_buf and call.win == state.ui.output_win and call.event == 'PiDevRefresh' then found = true end end; assert(found, vim.inspect(_G.pi_md_calls))"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"

settled_refresh_lua="$(pidev_lua_file)"
cat > "$settled_refresh_lua" <<'LUA'
_G.pi_md_calls = {}
package.preload['render-markdown'] = function()
  return {
    set_buf = function() end,
    render = function(opts)
      table.insert(_G.pi_md_calls, { buf = opts.buf, win = opts.win, event = opts.event })
    end,
  }
end

require('pi-dev').setup({
  keymaps = { enable = false },
  ui = { width = 80, input_height = 8 },
})

local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')
ui.show()
assert(vim.wait(1000, function() return #_G.pi_md_calls > 0 end), 'initial markdown refresh did not run')
_G.pi_md_calls = {}

renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = '**streamed markdown**' } })

assert(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
  return text:find('streamed markdown', 1, true) ~= nil and #_G.pi_md_calls >= 1
end), vim.inspect(_G.pi_md_calls))

assert(vim.wait(1000, function()
  return #_G.pi_md_calls >= 2
end), 'live chat output should schedule a trailing markdown refresh after the first render pass: ' .. vim.inspect(_G.pi_md_calls))
LUA

pidev_run_lua_file "$settled_refresh_lua"

refresh_order_lua="$(pidev_lua_file)"
cat > "$refresh_order_lua" <<'LUA'
require('pi-dev').setup({
  keymaps = { enable = false },
  ui = { width = 80, input_height = 8, render = { fold_tool_output_over = 3 } },
  session_render = { chunk_size = 1, chunk_delay_ms = 1 },
})

local ui = require('pi-dev.ui')
local markdown = require('pi-dev.markdown')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
ui.show()

local snapshots = {}
markdown.refresh_output = function()
  local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
  local header
  for index, line in ipairs(lines) do
    if line:find('^### Tool:') then
      header = index
      break
    end
  end
  local foldclosed = header and vim.api.nvim_win_call(state.ui.output_win, function()
    return vim.fn.foldclosed(header + 1)
  end) or nil
  table.insert(snapshots, {
    text = table.concat(lines, '\n'),
    foldclosed = foldclosed,
  })
end

local long_content = table.concat(vim.tbl_map(function(index)
  return 'line ' .. index
end, vim.fn.range(1, 20)), '\n')
local messages = {
  {
    role = 'assistant',
    content = {
      { type = 'text', text = 'before tool' },
      { type = 'toolCall', id = 'read-call', name = 'read', arguments = { path = 'long.txt' } },
    },
  },
  {
    role = 'toolResult',
    toolCallId = 'read-call',
    toolName = 'read',
    content = vim.json.encode({ path = 'long.txt', content = long_content }),
  },
}

renderer.render_messages(messages, 'Restored fold refresh order')
assert(#snapshots > 0, 'restored render should request markdown refresh')
assert(snapshots[#snapshots].foldclosed and snapshots[#snapshots].foldclosed ~= -1, vim.inspect(snapshots))

snapshots = {}
renderer.render_messages_chunked(messages, 'Chunked fold refresh order', { chunk_size = 1, chunk_delay_ms = 1, chunk_budget_ms = 0 })
assert(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
  return text:find('line 20', 1, true) and #snapshots > 0
end), vim.inspect(snapshots))
assert(snapshots[#snapshots].foldclosed and snapshots[#snapshots].foldclosed ~= -1, vim.inspect(snapshots))
LUA

pidev_run_lua_file "$refresh_order_lua"
