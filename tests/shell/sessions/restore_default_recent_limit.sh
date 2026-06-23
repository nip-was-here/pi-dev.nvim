#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_file="$(mktemp)"
printf '%s\n' '{"type":"session","version":3,"id":"default-recent-limit","timestamp":"2026-01-01T00:00:00.000Z","cwd":"./tmp/pi-dev-test/default-recent-limit"}' > "$session_file"
for i in $(seq 1 105); do
  printf '{"type":"message","id":"m%s","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"default recent message %s"}}\n' "$i" "$i" >> "$session_file"
done

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<LUA
require('pi-dev').setup({ keymaps = { enable = false } })
local config = require('pi-dev.config')
assert(config.options.session_render.max_messages == 100, vim.inspect(config.options.session_render))

local ui = require('pi-dev.ui')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
ui.show()
local done = false
sessions.render_current('Default recent limit test', '$session_file', { on_done = function() done = true end })
assert(vim.wait(1000, function() return done end), 'default recent render did not finish')
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('Showing latest 100/105 rendered messages', 1, true), text)
assert(text:find('default recent message 6', 1, true), text)
assert(text:find('default recent message 105', 1, true), text)
assert(text:find('\ndefault recent message 1\n', 1, true) == nil, text)
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
