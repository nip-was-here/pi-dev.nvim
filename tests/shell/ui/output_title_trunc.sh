#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

output="$({
  pidev_nvim_output \
    +"lua require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 32, input_height = 6 } })" \
    +"lua local ui = require('pi-dev.ui'); local renderer = require('pi-dev.renderer'); local state = require('pi-dev.state'); ui.show(); renderer.render_messages({}, 'Pi.dev session: this is a deliberately very long session title that must be truncated'); ui.refresh_chrome(); local title = vim.wo[state.ui.output_win].winbar; local text_width = require('pi-dev.format').window_text_width(state.ui.output_win); assert(vim.fn.strdisplaywidth(title) <= text_width, ('%s width=%d text_width=%d'):format(title, vim.fn.strdisplaywidth(title), text_width)); assert(title:find('...', 1, true), title)"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
