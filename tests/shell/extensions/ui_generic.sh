#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

output="$({
  pidev_nvim_output \
    +"lua require('pi-dev').setup({ keymaps = { enable = false } })" \
    +"lua local sent = {}; require('pi-dev.rpc').write = function(message) table.insert(sent, message); return true end; local ext = require('pi-dev.extension_ui'); ext.handle_request({ type = 'extension_ui_request', id = 'confirm-1', method = 'confirm', title = 'Confirm title', message = 'Confirm body' }); assert(vim.wait(1000, function() return require('pi-dev.state').ui.interaction ~= nil end), 'confirm interaction did not open'); vim.api.nvim_feedkeys('1', 'xt', false); assert(vim.wait(1000, function() return sent[1] ~= nil end), 'confirm response not sent'); assert(sent[1].type == 'extension_ui_response'); assert(sent[1].id == 'confirm-1'); assert(sent[1].confirmed == true); local state = require('pi-dev.state'); assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'generic confirm should restore input buffer')" \
    +"lua local ext = require('pi-dev.extension_ui'); local ui_state = require('pi-dev.state').ui; ext.handle_request({ type = 'extension_ui_request', method = 'setStatus', statusKey = 'demo', statusText = 'ready' }); assert(ui_state.statuses.demo == 'ready'); ext.handle_request({ type = 'extension_ui_request', method = 'setWidget', widgetKey = 'demo', widgetLines = { 'one', 'two' } }); assert(#ui_state.widgets.demo == 2); ext.handle_request({ type = 'extension_ui_request', method = 'setWidget', widgetKey = 'demo', widgetLines = vim.NIL }); assert(ui_state.widgets.demo == nil)"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
