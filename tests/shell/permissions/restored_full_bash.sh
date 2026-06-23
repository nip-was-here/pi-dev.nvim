#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_root="$(mktemp -d)"
project_cwd="$(mktemp -d)"
mkdir -p "$session_root/project"
session_file="$session_root/project/pending-permission.jsonl"
command="./tests/shell/renderer/unified_history_and_diff.sh && bash -lc 'echo permission ok' && ./tests/shell/sessions/restore_paged_render.sh"
printf '%s\n' "{\"type\":\"session\",\"version\":3,\"id\":\"pending-permission\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"$project_cwd\"}" > "$session_file"
printf '%s\n' "{\"type\":\"message\",\"id\":\"u1\",\"timestamp\":\"2026-01-01T00:00:01.000Z\",\"message\":{\"role\":\"user\",\"content\":\"please run tests\"}}" >> "$session_file"
printf '%s\n' "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":\"u1\",\"timestamp\":\"2026-01-01T00:00:02.000Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"bash-call\",\"name\":\"bash\",\"arguments\":{\"command\":\"$command\"}}]}}" >> "$session_file"
printf '%s\n' "{\"type\":\"extension_ui_request\",\"id\":\"perm-restore\",\"parentId\":\"a1\",\"timestamp\":\"2026-01-01T00:00:03.000Z\",\"method\":\"select\",\"title\":\"Permission Required\\nPi requested bash command '$command'. Allow this command?\",\"options\":[\"Yes\",\"Yes, allow bash \\\"./tests/*\\\" for this session\",\"No\",\"No, provide reason\"]}" >> "$session_file"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local session_root = vim.env.PI_DEV_TEST_SESSION_ROOT
local project_cwd = vim.env.PI_DEV_TEST_PROJECT_CWD
local command = vim.env.PI_DEV_TEST_COMMAND
require('pi-dev').setup({
  keymaps = { enable = false },
  session_root = session_root,
  cwd = project_cwd,
  session_render = { max_messages = 10, chunk_size = 10, chunk_delay_ms = 1 },
})
local ui = require('pi-dev.ui')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')
ui.show()
rpc.request = function(message, cb)
  if cb then cb({ type = 'response', success = true, data = {} }) end
  return message.type
end
sessions.load_latest_or_new()
assert(vim.wait(2000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
  return text:find('#### Permission request', 1, true) ~= nil
end, 20), 'pending permission should render from restored session')
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('### Tool: bash', 1, true), text)
assert(text:find('```bash\n' .. command .. '\n```', 1, true), text)
local permission_header = text:match('(#### Permission request:[^\n]+)')
assert(permission_header and permission_header:find('bash `./test', 1, true), text)
assert(not permission_header:find(command, 1, true), permission_header)
local header_pos = text:find('#### Permission request:', 1, true)
assert(header_pos, text)
local after_header = text:sub(header_pos or 1)
assert(after_header:find('```bash\n' .. command .. '\n```', 1, true) == nil, text)
assert(after_header:find('Pi requested bash command.\nAllow this command?', 1, true), text)
assert(text:find("requested bash command '" .. command .. "'", 1, true) == nil, text)
LUA

output="$({
  PI_DEV_TEST_SESSION_ROOT="$session_root" PI_DEV_TEST_PROJECT_CWD="$project_cwd" PI_DEV_TEST_COMMAND="$command" \
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  python3 - <<'PY' "$session_root" "$project_cwd" "$tmp_lua"
import os, shutil, sys
for path in sys.argv[1:]:
    if os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.exists(path):
        os.unlink(path)
PY
  exit 1
}

python3 - <<'PY' "$session_root" "$project_cwd" "$tmp_lua"
import os, shutil, sys
for path in sys.argv[1:]:
    if os.path.isdir(path):
        shutil.rmtree(path)
    elif os.path.exists(path):
        os.unlink(path)
PY

pidev_assert_no_nvim_errors "$output"
