#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

output="$({
  pidev_nvim_output \
    +"lua local plugin = require('pi-dev'); plugin.setup({ keymaps = { enable = false }, commands = { enable = true } }); assert(vim.fn.exists(':PiDev') == 2, 'PiDev command should exist after enabled setup'); plugin.setup({ keymaps = { enable = false }, commands = { enable = false } }); assert(vim.fn.exists(':PiDev') == 0, 'PiDev command should be removed after disabled setup'); plugin.setup({ keymaps = { enable = false }, commands = { enable = true } }); assert(vim.fn.exists(':PiDev') == 2, 'PiDev command should be recreated after re-enabled setup')"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
