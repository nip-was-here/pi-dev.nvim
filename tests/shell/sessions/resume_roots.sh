#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_root="$(pidev_tmp_dir)"
project_cwd="$(pidev_tmp_dir)"
mkdir -p "$session_root/root-a" "$session_root/root-b" "$session_root/root-c" "$session_root/root-a/subagent-run/run-0"
root_one="$session_root/root-a/root.jsonl"
child_one="$session_root/root-a/child-one.jsonl"
child_two="$session_root/root-a/child-two.jsonl"
root_two="$session_root/root-b/root.jsonl"
root_three="$session_root/root-c/root.jsonl"
internal_task="$session_root/root-a/subagent-run/run-0/session.jsonl"

cat > "$root_one" <<EOF_ROOT_ONE
{"type":"session","version":3,"id":"root-one","timestamp":"2026-01-01T00:00:00.000Z","cwd":"$project_cwd"}
{"type":"session_info","name":"Root One"}
{"type":"message","id":"r1-u1","parentId":null,"timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"root one prompt"}}
EOF_ROOT_ONE
cat > "$child_one" <<EOF_CHILD_ONE
{"type":"session","version":3,"id":"child-one","timestamp":"2026-01-02T00:00:00.000Z","cwd":"$project_cwd","parentSession":"$root_one"}
{"type":"message","id":"r1-u1","parentId":null,"timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"root one prompt"}}
{"type":"message","id":"c1-u1","parentId":"r1-u1","timestamp":"2026-01-02T00:00:00.000Z","message":{"role":"user","content":"older branch"}}
EOF_CHILD_ONE
cat > "$child_two" <<EOF_CHILD_TWO
{"type":"session","version":3,"id":"child-two","timestamp":"2026-01-03T00:00:00.000Z","cwd":"$project_cwd","parentSession":"$root_one"}
{"type":"message","id":"r1-u1","parentId":null,"timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"root one prompt"}}
{"type":"message","id":"c2-u1","parentId":"r1-u1","timestamp":"2026-01-03T00:00:00.000Z","message":{"role":"user","content":"newer branch"}}
EOF_CHILD_TWO
cat > "$root_two" <<EOF_ROOT_TWO
{"type":"session","version":3,"id":"root-two","timestamp":"2026-01-04T00:00:00.000Z","cwd":"$project_cwd"}
{"type":"session_info","name":"Root Two"}
{"type":"message","id":"r2-u1","parentId":null,"timestamp":"2026-01-04T00:00:00.000Z","message":{"role":"user","content":"root two prompt"}}
EOF_ROOT_TWO
cat > "$root_three" <<EOF_ROOT_THREE
{"type":"session","version":3,"id":"root-three","timestamp":"2025-12-31T00:00:00.000Z","cwd":"$project_cwd"}
{"type":"session_info","name":"Root Three"}
{"type":"message","id":"r3-u1","parentId":null,"timestamp":"2025-12-31T00:00:00.000Z","message":{"role":"user","content":"root three prompt"}}
EOF_ROOT_THREE
cat > "$internal_task" <<EOF_INTERNAL_TASK
{"type":"session","version":3,"id":"internal-task","timestamp":"2026-01-05T00:00:00.000Z","cwd":"$project_cwd"}
{"type":"message","id":"task-u1","parentId":null,"timestamp":"2026-01-05T00:00:00.000Z","message":{"role":"user","content":"Synthetic nested run prompt hidden from resume"}}
EOF_INTERNAL_TASK

touch -t 202601010000 "$root_one"
touch -t 202601020000 "$child_one"
touch -t 202601030000 "$child_two"
touch -t 202601040000 "$root_two"
touch -t 202512310000 "$root_three"
touch -t 202601050000 "$internal_task"

lua_file="$(pidev_lua_file)"
cat > "$lua_file" <<LUA
require('pi-dev').setup({ keymaps = { enable = false }, session_root = '$session_root', cwd = '$project_cwd', ui = { width = 80 } })
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local rpc = require('pi-dev.rpc')

vim.ui.select = function()
  error('resume picker must not use vim.ui.select for branch-heavy session lists')
end

local sent = {}
rpc.request = function(message, cb)
  table.insert(sent, message)
  if cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

local listed = sessions.list('$project_cwd')
assert(#listed == 5, vim.inspect(listed))
local latest = sessions.latest('$project_cwd')
assert(latest and latest.path == '$root_two', vim.inspect(latest))

sessions.pick()
assert(vim.wait(1000, function()
  return state.ui.interaction ~= nil
end), 'resume should open the native interaction picker')
assert(state.ui.interaction.surface == 'output', 'resume should use the large output surface')

local items = state.ui.interaction.items or {}
local selectable = {}
for _, item in ipairs(items) do
  if item.selectable ~= false then
    table.insert(selectable, item)
  end
end
assert(#selectable == 3, vim.inspect(items))
assert(#items == #selectable, 'resume should show root rows only, without branch/sub-session rows: ' .. vim.inspect(items))
assert(selectable[1].root_path ~= nil and selectable[2].root_path ~= nil and selectable[3].root_path ~= nil, vim.inspect(selectable))
assert(selectable[1].label:find('* Root Two', 1, true), selectable[1].label)
assert(selectable[2].label:find('* Root One', 1, true), selectable[2].label)
assert(selectable[3].label:find('* Root Three', 1, true), selectable[3].label)
assert(selectable[2].label:find('2 branches Last:', 1, true), selectable[2].label)
assert(selectable[2].label:find('2 branches', 1, true) < selectable[2].label:find('Last:', 1, true), selectable[2].label)
assert(selectable[2].label:find('child%-one%.jsonl') == nil, selectable[2].label)
assert(selectable[2].label:find('child%-two%.jsonl') == nil, selectable[2].label)
assert(selectable[2].before_lines and selectable[2].before_lines[1] == '', vim.inspect(selectable[2]))
assert(selectable[3].before_lines and selectable[3].before_lines[1] == '', vim.inspect(selectable[3]))
for _, item in ipairs(items) do
  assert(not item.label:find('| *', 1, true), item.label)
  assert(not item.label:find('Synthetic nested run prompt', 1, true), item.label)
  assert(item.label:find('Last:', 1, true), item.label)
end
local width = require('pi-dev.format').window_text_width(state.ui.output_win)
for _, item in ipairs(items) do
  assert(vim.fn.strdisplaywidth(item.label) <= width, ('wrapped label width=%d limit=%d label=%s'):format(vim.fn.strdisplaywidth(item.label), width, item.label))
end

-- Choosing the Root One tree resumes the newest branch in that root tree.
vim.api.nvim_feedkeys('j', 'xt', false)
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.selected == 2
end), 'resume selection should move to Root One')
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function()
  return sent[1] ~= nil
end), 'resume tree selection should switch to a session')
assert(sent[1].type == 'switch_session', vim.inspect(sent))
assert(sent[1].sessionPath == '$child_two', vim.inspect(sent[1]))
LUA

pidev_run_lua_file "$lua_file"
rm -f "$lua_file"
rm -rf "$session_root" "$project_cwd"
