#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

lua_file="$(pidev_lua_file)"
cat > "$lua_file" <<'LUA'
local format = require('pi-dev.format')
assert(os.date('%H:%M', format.timestamp_seconds('2000-01-01T00:00:00.000Z')) == '03:00', os.date('%Y-%m-%d %H:%M', format.timestamp_seconds('2000-01-01T00:00:00.000Z')))
assert(format.human_time_from_timestamp('2000-01-01T00:00:00.000Z') == '2000-01-01 03:00', format.human_time_from_timestamp('2000-01-01T00:00:00.000Z'))
assert(format.human_time_from_timestamp('2000-01-01T03:30:00+03:00') == '2000-01-01 03:30', format.human_time_from_timestamp('2000-01-01T03:30:00+03:00'))

local line, meta = format.prefixed_line('## ', 'Assistant answer with a very long title', '(12:34)', 32)
assert(line:match('^## '), line)
assert(line:match('%(12:34%)$'), line)
assert(line:find('...', 1, true), line)
assert(vim.fn.strdisplaywidth(line) <= 32, line)
assert(meta.body_truncated == true and meta.suffix_visible == true, vim.inspect(meta))

line, meta = format.prefixed_line('* ', 'short label', '[wait]', 24)
assert(line:match('^%* short label'), line)
assert(line:match('%[wait%]$'), line)
assert(vim.fn.strdisplaywidth(line) <= 24, line)
assert(meta.body_truncated == false and meta.suffix_visible == true, vim.inspect(meta))

line, meta = format.prefixed_line('### ', 'body is hidden when suffix must win', '(long suffix that must truncate)', 16)
assert(line:match('^### '), line)
assert(line:find('...', 1, true), line)
assert(vim.fn.strdisplaywidth(line) <= 16, line)
assert(meta.body_truncated == true and meta.suffix_visible == true and meta.suffix_truncated == true, vim.inspect(meta))
LUA

output="$({
  TZ=UTC-3 pidev_nvim_output +"luafile $lua_file"
} 2>&1)" || {
  rm -f "$lua_file"
  printf '%s\n' "$output"
  exit 1
}

rm -f "$lua_file"
pidev_assert_no_nvim_errors "$output"
