#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, rpc = { idle_timeout_ms = 0 } })

local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')
local ui = require('pi-dev.ui')
local api = require('pi-dev.api')

ui.show()
local runtime = state.active_rpc_runtime()
state.set_runtime_loading(runtime, true)
ui.refresh_chrome()

local line = statusline.render_for_width(100)
assert(line:find('Pi status: load', 1, true), line)
assert(ui.input_locked() == true, 'Pi input should report locked while runtime is loading')
assert(vim.bo[state.ui.input_buf].modifiable == false, 'Pi input must be non-modifiable while loading')
assert(vim.bo[state.ui.input_buf].readonly == true, 'Pi input must be readonly while loading')
assert((vim.wo[state.ui.input_win].winbar or ''):find('load session', 1, true), vim.wo[state.ui.input_win].winbar)

ui.set_input_text('draft while loading')
assert(ui.get_input_text() == 'draft while loading', 'programmatic draft restore should still work while locked')
assert(vim.bo[state.ui.input_buf].modifiable == false, 'programmatic draft restore must re-apply loading lock')

local submitted = false
local original_submit_text = api.submit_text
api.submit_text = function()
  submitted = true
  return true
end
assert(ui.submit_input() == false, 'loading Pi input must not submit')
assert(submitted == false, 'loading Pi input must not call api.submit_text')
assert(ui.get_input_text() == 'draft while loading', 'blocked submit must preserve draft')

state.set_runtime_loading(runtime, false)
ui.refresh_chrome()
line = statusline.render_for_width(100)
assert(line:find('Pi status: load', 1, true) == nil, line)
assert(ui.input_locked() == false, 'Pi input should unlock after loading')
assert(vim.bo[state.ui.input_buf].modifiable == true, 'Pi input must become modifiable after loading')
assert(vim.bo[state.ui.input_buf].readonly == false, 'Pi input must become writable after loading')
assert(ui.submit_input() == true, 'unlocked Pi input should submit')
assert(submitted == true, 'unlocked Pi input should call api.submit_text')
api.submit_text = original_submit_text
LUA

output="$(pidev_nvim_output +"luafile $tmp_lua" 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}

rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
