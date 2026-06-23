#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

output="$({
  pidev_nvim_output \
    +"lua require('pi-dev').setup({ keymaps = { enable = false } })" \
    +"lua local request = { type = 'extension_ui_request', id = 'perm-heading', method = 'select', title = 'Permission Required\nPi requested bash command \'git status\'. Allow this command?', options = { 'Yes', 'Yes, for this session', 'No', 'No, provide reason' } }; require('pi-dev.rpc').write = function() return true end; require('pi-dev.extension_ui').handle_request(request); assert(vim.wait(1000, function() return require('pi-dev.state').ui.interaction ~= nil end)); local state = require('pi-dev.state'); local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\\n'); assert(text:find('#### Permission request', 1, true), text); assert(text:find('\\n### Permission request\\n', 1, true) == nil, text); assert(text:find('Source plugin:', 1, true) == nil, text); assert(text:find('@gotgenes/pi%-permission%-system') == nil, text)"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
