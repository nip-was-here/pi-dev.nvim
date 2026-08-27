#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local plugin = require('pi-dev')
plugin.setup({
  keymaps = { enable = false },
  compat = {
    subagent = {
      status = {
        max_bytes = 16384,
        poll_interval_ms = 750,
        debounce_ms = 75,
      },
    },
  },
})
local plugin_config = require('pi-dev.config')
local status = plugin_config.options.compat.subagent.status
assert(status.max_bytes == 16384, 'subagent status byte limit should be configurable')
assert(status.poll_interval_ms == 750, 'subagent status polling interval should be configurable')
assert(status.debounce_ms == 75, 'subagent status debounce should be configurable')

local defaults = plugin_config.defaults.compat.subagent.status
assert(defaults.max_bytes == 2 * 1024 * 1024, 'unexpected default status byte limit')
assert(defaults.poll_interval_ms == 1000, 'unexpected default status polling interval')
assert(defaults.debounce_ms == 50, 'unexpected default status debounce')

local invalid = {
  { option = { max_bytes = 0 }, message = 'compat.subagent.status.max_bytes must be a positive number' },
  { option = { poll_interval_ms = 0 }, message = 'compat.subagent.status.poll_interval_ms must be a positive number' },
  { option = { debounce_ms = -1 }, message = 'compat.subagent.status.debounce_ms must be a non-negative number' },
}
for _, case in ipairs(invalid) do
  local ok, err = pcall(plugin.setup, { compat = { subagent = { status = case.option } } })
  assert(not ok, 'invalid status watcher option should be rejected')
  assert(tostring(err):find(case.message, 1, true), tostring(err))
end

local watcher = require('pi-dev.compat.subagent_async')
local async_dir = vim.env.PIDEV_TEST_TMP .. '/configured-subagent-status'
vim.fn.mkdir(async_dir, 'p')
vim.fn.writefile({ vim.json.encode({ state = 'running', padding = string.rep('x', 20000) }) }, async_dir .. '/status.json')
local calls = 0
local watch_opts = {
  key = 'configured-status',
  async_dir = async_dir,
  is_current = function() return true end,
  on_status = function() calls = calls + 1 end,
}
watcher.watch(watch_opts)
vim.wait(250, function() return calls > 0 end, 10)
assert(calls == 0, 'configured byte limit should prevent reading oversized status')
watcher.stop('configured-status')

plugin.setup({
  keymaps = { enable = false },
  compat = { subagent = { status = { max_bytes = 32768, poll_interval_ms = 10, debounce_ms = 0 } } },
})
watcher.watch(watch_opts)
assert(vim.wait(500, function() return calls == 1 end, 10), 'updated status watcher tuning should apply')
watcher.stop('configured-status')
LUA

pidev_run_lua_file "$tmp_lua"
