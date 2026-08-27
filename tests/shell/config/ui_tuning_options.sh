#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local plugin = require('pi-dev')
plugin.setup({
  keymaps = { enable = false },
  ui = {
    agent_tree = { max_height = 6 },
    render = { fold_thinking_over = 3 },
  },
})
local plugin_config = require('pi-dev.config')
assert(plugin_config.options.ui.agent_tree.max_height == 6, 'agent-tree height should be configurable')
assert(plugin_config.options.ui.render.fold_thinking_over == 3, 'thinking fold threshold should be configurable')
assert(plugin_config.defaults.ui.agent_tree.max_height == 8, 'unexpected default agent-tree height')
assert(plugin_config.defaults.ui.render.fold_thinking_over == 8, 'unexpected default thinking fold threshold')

local invalid = {
  {
    options = { ui = { agent_tree = { max_height = 0 } } },
    message = 'ui.agent_tree.max_height must be a positive number',
  },
  {
    options = { ui = { render = { fold_thinking_over = -1 } } },
    message = 'ui.render.fold_thinking_over must be a non-negative number',
  },
}
for _, case in ipairs(invalid) do
  local ok, err = pcall(plugin.setup, case.options)
  assert(not ok, 'invalid UI tuning option should be rejected')
  assert(tostring(err):find(case.message, 1, true), tostring(err))
end
LUA

pidev_run_lua_file "$tmp_lua"
