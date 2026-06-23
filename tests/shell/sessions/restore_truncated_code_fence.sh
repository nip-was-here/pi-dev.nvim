#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_root="$(pidev_tmp_dir)"
project_cwd="$(pidev_tmp_dir)"
mkdir -p "$session_root/project"
session_file="$session_root/project/truncated-code-fence.jsonl"

printf '%s\n' "{\"type\":\"session\",\"version\":3,\"id\":\"truncated-code-fence\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"$project_cwd\"}" > "$session_file"

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

local code_lines = {}
for index = 1, 80 do
  code_lines[index] = string.format('print("line-%03d keeps this code block long")', index)
end
local assistant = table.concat({
  'Before the long code block.',
  '```lua',
  table.concat(code_lines, '\n'),
  '```',
  '## Heading after the restored code block',
  'This part may be outside the render cap, but following messages must still render as markdown.',
}, '\n')

append_entry({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'show a long code answer' } })
append_entry({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = assistant } })
append_entry({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'follow-up after truncated answer' } })

require('pi-dev').setup({
  keymaps = { enable = false },
  session_root = session_root,
  cwd = project_cwd,
  session_render = { max_messages = false, max_text_chars = 180, chunk_size = 10, chunk_delay_ms = 0 },
})
local ui = require('pi-dev.ui')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
ui.show()
local done = false
sessions.render_current('Truncated code fence test', session_file, { on_done = function() done = true end })
assert(vim.wait(1000, function() return done end), 'session render did not finish')

local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local text = table.concat(lines, '\n')
assert(text:find('```lua', 1, true), text)
assert(text:find('%.%.%.'), text)
assert(text:find('follow%-up after truncated answer'), text)

local first_fence
local next_user_header
for index, line in ipairs(lines) do
  if line == '```lua' and not first_fence then
    first_fence = index
  elseif first_fence and line:match('^## User') then
    next_user_header = index
    break
  end
end
assert(first_fence, text)
assert(next_user_header, text)

local closed_before_next_message = false
for index = first_fence + 1, next_user_header - 1 do
  if lines[index] == '```' then
    closed_before_next_message = true
    break
  end
end
assert(closed_before_next_message, 'truncated assistant code fence must be closed before the next markdown message:\n' .. text)
LUA

output="$({
  PIDEV_SESSION_FILE="$session_file" \
  PIDEV_SESSION_ROOT="$session_root" \
  PIDEV_PROJECT_CWD="$project_cwd" \
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  rm -rf "$session_root" "$project_cwd" "$tmp_lua"
  exit 1
}

rm -rf "$session_root" "$project_cwd" "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
