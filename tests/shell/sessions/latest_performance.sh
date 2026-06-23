#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local session_root = vim.fn.tempname()
local project_cwd = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
vim.fn.mkdir(project_cwd, 'p')
local function enc(value)
  return vim.json.encode(value)
end
for index = 1, 30 do
  local path = session_root .. '/session-' .. string.format('%02d', index) .. '.jsonl'
  vim.fn.writefile({
    enc({ type = 'session', version = 3, id = 'session-' .. index, cwd = project_cwd, timestamp = '2026-01-01T00:00:00.000Z' }),
    enc({ type = 'session_info', name = 'Session ' .. index }),
    enc({ type = 'message', id = 'u' .. index, timestamp = string.format('2026-01-01T00:%02d:00.000Z', index % 60), message = { role = 'user', content = 'prompt ' .. index } }),
  }, path)
  vim.uv.fs_utime(path, 1700000000 + index, 1700000000 + index)
end
require('pi-dev').setup({ keymaps = { enable = false }, session_root = session_root, cwd = project_cwd })
local sessions = require('pi-dev.sessions')
local old_readfile = vim.fn.readfile
local header_reads = 0
local name_reads = 0
vim.fn.readfile = function(path, flags, max)
  if tostring(path):find(session_root, 1, true) then
    if max == 1 then
      header_reads = header_reads + 1
    elseif max == 160 then
      name_reads = name_reads + 1
    end
  end
  return old_readfile(path, flags, max)
end
local latest = sessions.latest(project_cwd)
vim.fn.readfile = old_readfile
assert(latest and latest.name == 'Session 30', vim.inspect(latest))
assert(header_reads <= 31, 'latest should inspect candidate headers only once plus optional selected-session title context: ' .. header_reads)
assert(name_reads == 1, 'latest should read the display name only for the selected latest session, not every candidate: ' .. name_reads)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
