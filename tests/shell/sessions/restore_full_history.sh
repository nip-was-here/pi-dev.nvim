#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_file="$(mktemp)"
printf '%s\n' '{"type":"session","version":3,"id":"full-history","timestamp":"2026-01-01T00:00:00.000Z","cwd":"./tmp/pi-dev-test/full-history"}' > "$session_file"
for i in $(seq 1 250); do
  printf '{"type":"message","id":"m%s","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"full history message %s"}}\n' "$i" "$i" >> "$session_file"
done

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<LUA
require('pi-dev').setup({
  keymaps = { enable = false },
  session_render = { max_messages = 0, chunk_size = 100, chunk_delay_ms = 0, chunk_budget_ms = 8 },
})
local ui = require('pi-dev.ui')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
ui.show()
local done = false
sessions.render_current('Full history test', '$session_file', { on_done = function() done = true end })
assert(vim.wait(1000, function() return done end), 'full history render did not finish')
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('full history message 1', 1, true), text)
assert(text:find('full history message 250', 1, true), text)
assert(text:find('Showing latest', 1, true) == nil, text)

require('pi-dev.config').options.session_render.max_messages = false
done = false
sessions.render_current('Full history false test', '$session_file', { on_done = function() done = true end })
assert(vim.wait(1000, function() return done end), 'false full history render did not finish')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('full history message 1', 1, true), text)
assert(text:find('full history message 250', 1, true), text)
assert(text:find('Showing latest', 1, true) == nil, text)
LUA

output="$({
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua" "$session_file"
  exit 1
}

rm -f "$tmp_lua" "$session_file"

pidev_assert_no_nvim_errors "$output"
