#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local ext = require('pi-dev.extension_ui')
local state = require('pi-dev.state')

ui.show()
local function output_header()
  return vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''
end
local function winbar_title()
  return vim.wo[state.ui.output_win].winbar or state.ui.output_title or ''
end

assert(vim.api.nvim_buf_get_name(state.ui.output_buf):match('pi%-dev://chat$'), vim.api.nvim_buf_get_name(state.ui.output_buf))
assert(output_header() == '# Pi chat', output_header())
assert(winbar_title():find('Pi chat', 1, true), winbar_title())
assert(not winbar_title():find('dialog', 1, true), winbar_title())
assert(not winbar_title():find('output', 1, true), winbar_title())

renderer.clear()
assert(output_header() == '# Pi chat', output_header())
assert(winbar_title():find('Pi chat', 1, true), winbar_title())

ext.handle_request({ type = 'extension_ui_request', method = 'setTitle', title = 'Remote title' })
assert(state.ui.output_title == 'Pi chat: Remote title', state.ui.output_title)
assert(winbar_title():find('Pi chat: Remote title', 1, true), winbar_title())
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
