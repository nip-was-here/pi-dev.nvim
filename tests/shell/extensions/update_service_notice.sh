#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ext = require('pi-dev.extension_ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
require('pi-dev.ui').show()

local notifications = {}
vim.notify = function(message, level)
  table.insert(notifications, { message = message, level = level })
end

renderer.clear('Update notice')
ext.handle_request({
  type = 'extension_ui_request',
  method = 'notify',
  notifyType = 'warning',
  message = 'New version 9.9.9 is available. Run pi update\nChangelog: https://pi.dev/changelog',
})

local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local text = table.concat(lines, '\n')
assert(#notifications == 1 and notifications[1].message:find('pi update', 1, true), vim.inspect(notifications))
assert(text:find('> New version 9.9.9 is available. Run pi update', 1, true), text)
assert(text:find('> Changelog: https://pi.dev/changelog', 1, true), text)
assert(lines[#lines] == '', 'service notice should be appended at the output tail: ' .. vim.inspect(lines))

ext.handle_request({ type = 'extension_ui_request', method = 'notify', notifyType = 'info', message = 'ordinary notification only' })
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('ordinary notification only', 1, true) == nil, text)

renderer.clear('Future update event')
renderer.handle_event({ type = 'update_available', release = { version = '10.0.0', note = 'Important update note.' } })
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('> Update Available', 1, true), text)
assert(text:find('> New version 10.0.0 is available. Run pi update', 1, true), text)
assert(text:find('> Important update note.', 1, true), text)
assert(text:find('> Changelog: https://pi.dev/changelog', 1, true), text)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
