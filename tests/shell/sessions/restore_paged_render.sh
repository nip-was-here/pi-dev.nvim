#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_root="$(mktemp -d)"
project_cwd="$(mktemp -d)"
mkdir -p "$session_root/project"
session_file="$session_root/project/large.jsonl"
printf '%s\n' "{\"type\":\"session\",\"version\":3,\"id\":\"large\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"$project_cwd\"}" > "$session_file"
for i in $(seq 1 12); do
  printf '%s\n' "{\"type\":\"message\",\"id\":\"m$i\",\"parentId\":null,\"timestamp\":\"2026-01-01T00:00:$i.000Z\",\"message\":{\"role\":\"user\",\"content\":\"message $i\"}}" >> "$session_file"
done
printf '%s\n' "{\"type\":\"message\",\"id\":\"m13\",\"parentId\":null,\"createdAt\":\"2026-01-01T00:00:13.000Z\",\"message\":{\"role\":\"user\",\"content\":\"message 13\"}}" >> "$session_file"
printf '%s\n' "{\"type\":\"message\",\"id\":\"m14\",\"parentId\":\"m13\",\"timestamp\":\"2026-01-01T00:00:14.000Z\",\"message\":{\"role\":\"assistant\",\"content\":\"assistant message 14\"}}" >> "$session_file"
printf '%s\n' "{\"type\":\"message\",\"id\":\"m15\",\"parentId\":\"m14\",\"timestamp\":\"2026-01-01T00:00:15.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"call-15\",\"name\":\"bash\",\"arguments\":{\"command\":\"printf restored-tool-call\"}}]}}" >> "$session_file"
printf '%s\n' "{\"type\":\"message\",\"id\":\"m16\",\"parentId\":\"m15\",\"timestamp\":\"2026-01-01T00:00:16.000Z\",\"message\":{\"role\":\"toolResult\",\"toolName\":\"bash\",\"content\":\"tool result 16\"}}" >> "$session_file"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<LUA
require('pi-dev').setup({
  keymaps = { enable = false },
  session_root = '$session_root',
  cwd = '$project_cwd',
  session_render = { max_messages = 6, chunk_size = 2, chunk_delay_ms = 1 },
  ui = { render = { show_timestamps = true, fold_tool_output_over = 7 } },
})
local ui = require('pi-dev.ui')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')
ui.show()
local sent = {}
rpc.request = function(message, cb)
  table.insert(sent, message)
  if cb then cb({ type = 'response', success = true, data = {} }) end
  return message.type
end
sessions.load_latest_or_new()
assert(sent[1] and sent[1].type == 'switch_session', 'must switch to latest session')
for _, message in ipairs(sent) do
  assert(message.type ~= 'get_messages', 'session restore should render from file instead of blocking on full get_messages RPC')
end
assert(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
  return text:find('message 13', 1, true) and text:find('assistant message 14', 1, true) and text:find('printf restored-tool-call', 1, true) and text:find('tool result 16', 1, true) and not text:find('message 8', 1, true)
end), 'paged restore should render only latest messages')
local status_cfg = vim.api.nvim_win_get_config(state.ui.status_win)
assert(status_cfg.row == vim.api.nvim_win_get_height(state.ui.output_win) - 1, 'status separator should sit one row above the lower Pi pane during restored session output')
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('Showing latest 6/16', 1, true), text)
assert(text:find('## User%s+%([^%)]+%)'), text)
assert(text:find('## Assistant%s+%([^%)]+%)'), text)
assert(text:find('message 13', 1, true), text)
assert(text:find('assistant message 14', 1, true), text)
assert(text:find('### Tool result: bash', 1, true) == nil, text)
assert(text:find('Tool call:', 1, true) == nil, text)
local tick = string.char(96)
assert(text:find('### Tool: bash printf restored-tool-call', 1, true), text)
assert(text:find(tick .. tick .. tick .. 'bash\nprintf restored-tool-call\n' .. tick .. tick .. tick, 1, true), text)
assert(text:find('_done_', 1, true), text)
assert(text:find('tool result 16', 1, true), text)
local command_count = 0
local offset = 1
while true do
  local found = text:find('printf restored-tool-call', offset, true)
  if not found then
    break
  end
  command_count = command_count + 1
  offset = found + 1
end
assert(command_count == 2, text)
assert(vim.wait(1000, function()
  return vim.api.nvim_win_call(state.ui.output_win, function()
    for _, block in pairs(state.render.tool_blocks or {}) do
      if block.fold_start_line and vim.fn.foldlevel(block.fold_start_line) > 0 then
        return true
      end
    end
    return false
  end)
end), vim.inspect(state.render.tool_blocks))
assert(text:find('%(Jan 01 %d%d:%d%d%)'), text)
local user_header = text:match('(## User[^\n]+)')
local assistant_header = text:match('(## Assistant[^\n]+)')
assert(user_header and assistant_header, text)
assert(vim.fn.strdisplaywidth(user_header) == vim.fn.strdisplaywidth(assistant_header), user_header .. '\n' .. assistant_header)
LUA

output="$({
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  rm -rf "$session_root" "$project_cwd" "$tmp_lua"
  exit 1
}

rm -rf "$session_root" "$project_cwd" "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
