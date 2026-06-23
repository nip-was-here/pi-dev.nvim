#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
local session_file = session_root .. '/fresh.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.fn.fnamemodify(vim.uv.cwd(), ':p'):gsub('/$', ''), id = 'fresh' }),
  vim.json.encode({ type = 'message', id = 'm1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'fresh prompt' } }),
}, session_file)

require('pi-dev').setup({
  exec = { bin = 'pi-test' },
  session_root = session_root,
  rpc = { pool_size = 8, idle_timeout_ms = 0 },
  keymaps = { enable = false },
  session_render = { chunk_delay_ms = 1 },
})

local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')
local api = require('pi-dev.api')

local job_id = 200
vim.fn.jobstart = function()
  job_id = job_id + 1
  return job_id
end
vim.fn.chansend = function()
  return 1
end
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

api.start()
assert(vim.wait(1000, function()
  return state.active_rpc_runtime().session_file == session_file
end), vim.inspect(state.rpc.runtimes))

local count = state.rpc_runtime_count()
assert(count == 1, 'fresh auto-restore should attach the default runtime instead of creating a duplicate: ' .. vim.inspect(state.rpc.runtimes))
local line = statusline.render_for_width(100)
assert(line:find('Pi status: load', 1, true), line)
assert(line:find('load 1', 1, true) == nil, line)
assert(line:find('load (', 1, true) == nil, line)
assert(line:find('waiting input', 1, true) == nil, line)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
