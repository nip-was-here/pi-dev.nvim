#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ext = require('pi-dev.extension_ui')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')
local sent = {}
require('pi-dev.rpc').write = function(message)
  table.insert(sent, message)
  return true
end

ui.focus_input()

local request = {
  type = 'extension_ui_request',
  id = 'perm-reprompt',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'echo ok'. Allow this command?",
  options = { 'Yes', 'No', 'No, provide reason' },
}

ext.handle_request(request)
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'permission interaction missing')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
assert(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false), '\n')
  return state.ui.interaction ~= nil
    and vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf
    and #sent == 0
    and text:find('explicit choice', 1, true) == nil
    and text:find('**Request:** bash `echo ok`', 1, true) ~= nil
end), 'Esc should re-prompt permission compactly without responding')
vim.api.nvim_feedkeys('q', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil
    and vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf
    and #sent == 0
end), 'q should re-prompt permission without responding')
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end), 'explicit selection should respond')
assert(sent[1].id == 'perm-reprompt' and sent[1].value == 'Yes', vim.inspect(sent))
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'explicit selection should restore Pi input')

sent = {}
ext.handle_request(vim.tbl_extend('force', request, { id = 'perm-reason' }))
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'second permission interaction missing')
vim.api.nvim_feedkeys('3', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil and sent[1].value == 'No, provide reason' end), 'deny-with-reason selection should respond')
ext.handle_request({ type = 'extension_ui_request', id = 'reason-input', method = 'input', title = 'Why deny?' })
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.kind == 'text' end), 'denial reason input missing')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
assert(vim.wait(1000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false), '\n')
  return state.ui.interaction and state.ui.interaction.kind == 'text' and #sent == 1 and text:find('still requires', 1, true) == nil
end), 'Esc in denial reason should re-prompt compactly without responding')
ui.close_interaction()
LUA

output="$({
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  python3 - <<PY
from pathlib import Path
Path('$tmp_lua').unlink(missing_ok=True)
PY
  exit 1
}

python3 - <<PY
from pathlib import Path
Path('$tmp_lua').unlink(missing_ok=True)
PY

pidev_assert_no_nvim_errors "$output"
