#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cleanup() {
  python3 - <<'PY' "$tmp_lua"
import os, sys
for path in sys.argv[1:]:
    if os.path.exists(path):
        os.unlink(path)
PY
}
trap cleanup EXIT
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false } })
local ui = require('pi-dev.ui')
local compat = require('pi-dev.compat.pi_permission_system')
local extension_ui = require('pi-dev.extension_ui')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')

ui.focus_input()
ui.set_input_text('draft prompt survives permission')
local sent = {}
rpc.write = function(message)
  table.insert(sent, message)
  return true
end

local full = 'git status && printf very-long-tool-arguments && sleep 1'
local request = {
  type = 'extension_ui_request',
  id = 'perm-1',
  method = 'select',
  title = "Permission Required\nPi requested bash command '" .. full .. "'. Allow this command?",
  options = { 'Yes', 'Yes, allow bash "git *" for this session', 'No', 'No, provide reason' },
}
assert(compat.is_permission_select_request(request))
extension_ui.handle_request(request)
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end))

assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf, 'permission should use separate interaction buffer')
assert(table.concat(vim.api.nvim_buf_get_lines(state.ui.input_buf, 0, -1, false), '\n') == 'draft prompt survives permission')
local input_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false), '\n')
assert(vim.bo[state.ui.interaction_buf].filetype == 'markdown')
assert(input_text:find('#### Permission Required', 1, true) ~= nil, input_text)
assert(input_text:find('Permission Required: bash', 1, true) == nil, input_text)
assert(input_text:find('**Request:** bash `git *`', 1, true) ~= nil, input_text)
assert(input_text:find('Yes, for session', 1, true) ~= nil, input_text)
assert(input_text:find('No, with reason', 1, true) ~= nil, input_text)
assert(input_text:find('Yes, for this session: bash `git *`', 1, true) == nil, input_text)
assert(input_text:find('very%-long%-tool%-arguments') == nil, input_text)
assert(vim.bo[state.ui.interaction_buf].modifiable == false)
assert(vim.bo[state.ui.interaction_buf].readonly == true)

local output_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local header_pos = output_text:find('#### Permission request: bash `git *`', 1, true)
assert(header_pos, output_text)
assert(output_text:find('Pi requested bash command.\nAllow this command?', 1, true), output_text)
assert(output_text:find(full, 1, true) == nil, output_text)
assert(output_text:find('full command', 1, true) == nil, output_text)
assert(input_text:find('full command', 1, true) == nil, input_text)

vim.api.nvim_feedkeys('2', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil end))
assert(sent[1].type == 'extension_ui_response')
assert(sent[1].id == 'perm-1')
assert(sent[1].value == 'Yes, allow bash "git *" for this session')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'input window should return to Pi input buffer')
assert(table.concat(vim.api.nvim_buf_get_lines(state.ui.input_buf, 0, -1, false), '\n') == 'draft prompt survives permission')

local full_command = 'git status && printf hidden-full-command'
local metadata_request = {
  type = 'extension_ui_request',
  id = 'perm-full-command-metadata',
  method = 'select',
  title = "Permission Required\nPi requested bash command 'git *' (full command: '" .. full_command .. "'). Allow this command?",
  options = { 'Yes', 'Yes, allow bash "git *" for this session', 'No', 'No, provide reason' },
}
extension_ui.handle_request(metadata_request)
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.request_id == 'perm-full-command-metadata' end))
output_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
input_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false), '\n')
assert(output_text:find('#### Permission request: bash `git *`', 1, true), output_text)
assert(output_text:find('full command', 1, true) == nil, output_text)
assert(output_text:find(full_command, 1, true) == nil, output_text)
assert(input_text:find('full command', 1, true) == nil, input_text)
assert(input_text:find(full_command, 1, true) == nil, input_text)
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil end))

local python_command = [[python3 - <<'PY'
import json, subprocess, re
raw=subprocess.check_output(['example-cli','list-records','--format=json'], text=True)
for p in re.findall(r'example apply -p ([A-Za-z0-9_\-]+)', raw):
    print('applycmd', p)
PY]]
local matched_request = {
  type = 'extension_ui_request',
  id = 'perm-matched-full-command',
  method = 'select',
  title = "Permission Required\nCurrent agent requested bash command 'python3' (matched '*') (full command: '" .. python_command .. "'). Allow this command?",
  options = { 'Yes', 'Yes, allow bash "*" for this session', 'No', 'No, provide reason' },
}
extension_ui.handle_request(matched_request)
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.request_id == 'perm-matched-full-command' end))
output_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
input_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false), '\n')
assert(output_text:find('#### Permission request: bash `*`', 1, true), output_text)
assert(output_text:find('Current agent requested bash command.\nAllow this command?', 1, true), output_text)
assert(output_text:find('matched', 1, true) == nil, output_text)
assert(output_text:find('full command', 1, true) == nil, output_text)
assert(output_text:find('subprocess.check_output', 1, true) == nil, output_text)
assert(input_text:find('subprocess.check_output', 1, true) == nil, input_text)
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil end))

local external_path = './tmp/pi-dev-test/outside/generated-records.jsonl'
local external_command = [[example-cli list-records --filter '.[] | select(.owner=="example-user") | {id,created_at,body,url}' > ]] .. external_path .. [[ && python3 - <<'PY'
import json
rows=[json.loads(l) for l in open(']] .. external_path .. [[')]
for c in rows[-8:]:
 print(c['created_at'], c['id'], len(c['body']), c['url'], c['body'][:120].replace('\n',' | '))
PY]]
local external_request = {
  type = 'extension_ui_request',
  id = 'perm-external-command-context',
  method = 'select',
  title = "Permission Required\nCurrent agent requested bash command '" .. external_command .. "' which references path(s) outside working directory '/workspace/project': " .. external_path .. ". Allow this external directory access?",
  options = { 'Yes', 'Yes, allow bash "./tmp/pi-dev-test/outside/*" for this session', 'No', 'No, provide reason' },
}
extension_ui.handle_request(external_request)
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.request_id == 'perm-external-command-context' end))
output_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
input_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, 0, -1, false), '\n')
local external_header = output_text:find('#### Permission request: External directory access: `' .. external_path .. '`', 1, true)
assert(external_header, output_text)
local external_section = output_text:sub(external_header)
assert(external_section:find('Current agent requested external directory access outside working directory `/workspace/project`.', 1, true), external_section)
assert(external_section:find('Path: `' .. external_path .. '`', 1, true), external_section)
assert(external_section:find('Allow this external directory access?', 1, true), external_section)
assert(external_section:find('Current agent requested bash command.', 1, true) == nil, external_section)
assert(external_section:find('select(.owner', 1, true) == nil, external_section)
assert(external_section:find('rows=[json.loads', 1, true) == nil, external_section)
assert(input_text:find('select(.owner', 1, true) == nil, input_text)
vim.api.nvim_feedkeys('1', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil end))

local path = './tmp/pi-dev-test/project/restricted.txt'
local path_request = {
  type = 'extension_ui_request',
  id = 'perm-path',
  method = 'select',
  title = "Permission Required\nPi requested access to file via '" .. path .. "'. Allow this path?",
  options = { 'Yes', 'Yes, allow read "./tmp/pi-dev-test/project/*" for this session', 'No', 'No, provide reason' },
}
extension_ui.handle_request(path_request)
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.request_id == 'perm-path' end))
output_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local path_header_pos = output_text:find('#### Permission request: read `./tmp/pi-dev-test/project/*`', 1, true)
assert(path_header_pos, output_text)
assert(output_text:find(path, 1, true) == nil, output_text)
LUA

output="$({
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"
