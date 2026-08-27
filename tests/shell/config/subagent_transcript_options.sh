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
      transcript = {
        max_bytes = 16384,
        poll_interval_ms = 750,
        debounce_ms = 75,
      },
    },
  },
})
local plugin_config = require('pi-dev.config')
local transcript = plugin_config.options.compat.subagent.transcript
assert(transcript.max_bytes == 16384, 'subagent transcript byte limit should be configurable')
assert(transcript.poll_interval_ms == 750, 'subagent transcript polling interval should be configurable')
assert(transcript.debounce_ms == 75, 'subagent transcript debounce should be configurable')

local defaults = plugin_config.defaults.compat.subagent.transcript
assert(defaults.max_bytes == 8 * 1024 * 1024, 'unexpected default transcript byte limit')
assert(defaults.poll_interval_ms == 500, 'unexpected default transcript polling interval')
assert(defaults.debounce_ms == 50, 'unexpected default transcript debounce')

local invalid = {
  { option = { max_bytes = 0 }, message = 'compat.subagent.transcript.max_bytes must be a positive number' },
  { option = { poll_interval_ms = 0 }, message = 'compat.subagent.transcript.poll_interval_ms must be a positive number' },
  { option = { debounce_ms = -1 }, message = 'compat.subagent.transcript.debounce_ms must be a non-negative number' },
}
for _, case in ipairs(invalid) do
  local ok, err = pcall(plugin.setup, { compat = { subagent = { transcript = case.option } } })
  assert(not ok, 'invalid transcript watcher option should be rejected')
  assert(tostring(err):find(case.message, 1, true), tostring(err))
end

local watcher = require('pi-dev.compat.subagent_transcript')
local path = vim.env.PIDEV_TEST_TMP .. '/configured-subagent-transcript.jsonl'
vim.fn.writefile({ vim.json.encode({
  version = 1,
  recordType = 'message',
  message = { role = 'assistant', content = string.rep('x', 20000) },
}) }, path)
local calls = 0
watcher.watch({ path = path, is_current = function() return true end, on_records = function() calls = calls + 1 end })
vim.wait(250, function() return calls > 0 end, 10)
assert(calls == 0, 'configured byte limit should prevent reading an oversized transcript')
watcher.stop()

plugin.setup({
  keymaps = { enable = false },
  compat = { subagent = { transcript = { max_bytes = 32768, poll_interval_ms = 10, debounce_ms = 0 } } },
})
watcher.watch({ path = path, is_current = function() return true end, on_records = function() calls = calls + 1 end })
assert(vim.wait(500, function() return calls == 1 end, 10), 'updated watcher limits and timing should apply')
watcher.stop()
LUA

pidev_run_lua_file "$tmp_lua"
