#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_root="$(pidev_tmp_dir)"
project_cwd="$(pidev_tmp_dir)"
mkdir -p "$session_root/project"
session_file="$session_root/project/full-assistant-output.jsonl"

printf '%s\n' "{\"type\":\"session\",\"version\":3,\"id\":\"full-assistant-output\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"$project_cwd\"}" > "$session_file"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local session_file = assert(os.getenv('PIDEV_SESSION_FILE'))
local session_root = assert(os.getenv('PIDEV_SESSION_ROOT'))
local project_cwd = assert(os.getenv('PIDEV_PROJECT_CWD'))

local function append_entry(entry)
  local fd = assert(io.open(session_file, 'a'))
  fd:write(vim.json.encode(entry), '\n')
  fd:close()
end

local paragraphs = {}
for index = 1, 360 do
  paragraphs[index] = string.format('assistant restored paragraph %03d with enough text to exceed the old restored-message character cap', index)
end
local assistant = table.concat(paragraphs, '\n')

append_entry({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'write a long answer' } })
append_entry({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = assistant } })

require('pi-dev').setup({
  keymaps = { enable = false },
  session_root = session_root,
  cwd = project_cwd,
})
local ui = require('pi-dev.ui')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
ui.show()
local done = false
sessions.render_current('Full restored output test', session_file, { on_done = function() done = true end })
assert(vim.wait(1000, function() return done end), 'session render did not finish')

local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('assistant restored paragraph 001', 1, true), text)
assert(text:find('assistant restored paragraph 360', 1, true), text)
assert(not text:match('%.%.%.%s*$'), text)
assert(text:find('Showing latest', 1, true) == nil, text)
LUA

output="$({
  PIDEV_SESSION_FILE="$session_file" \
  PIDEV_SESSION_ROOT="$session_root" \
  PIDEV_PROJECT_CWD="$project_cwd" \
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
