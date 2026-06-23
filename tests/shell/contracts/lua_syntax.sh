#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

output="$({
  pidev_nvim_output \
    +"lua require('pi-dev').setup({ keymaps = { enable = false } })" \
    +"lua assert(vim.fn.exists(':PiDev') == 2)" \
    +"lua assert(vim.fn.exists(':PiDevPrompt') == 2)" \
    +"lua assert(vim.fn.exists(':PiDevResume') == 2)" \
    +"lua assert(vim.fn.exists(':PiDevModel') == 2)" \
    +"lua assert(vim.fn.exists(':PiDevReload') == 2)" \
    +"lua assert(vim.fn.exists(':PiDevTree') == 2)" \
    +"lua local events = require('pi-dev.events'); local seen = false; events.on('agent_start', function() seen = true end); require('pi-dev.rpc')._handle_chunk('{\"type\":\"agent_start\"}\n'); assert(seen)"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
