#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_root="$(pidev_tmp_dir)"
project_cwd="$(pidev_tmp_dir)"
mkdir -p "$session_root/root-one" "$session_root/root-two" "$session_root/root-three" "$session_root/other"
root_one="$session_root/root-one/root.jsonl"
child_one="$session_root/root-one/child.jsonl"
root_two="$session_root/root-two/root.jsonl"
child_two="$session_root/root-two/child.jsonl"
root_three="$session_root/root-three/root.jsonl"
child_three="$session_root/root-three/child.jsonl"
unrelated="$session_root/other/root.jsonl"

cat > "$root_one" <<EOF_ROOT_ONE
{"type":"session","version":3,"id":"root-one","timestamp":"2026-01-01T00:00:00.000Z","cwd":"$project_cwd"}
{"type":"session_info","name":"Root One"}
{"type":"message","id":"r1-u1","parentId":null,"timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"root one prompt"}}
EOF_ROOT_ONE
cat > "$child_one" <<EOF_CHILD_ONE
{"type":"session","version":3,"id":"child-one","timestamp":"2026-01-02T00:00:00.000Z","cwd":"$project_cwd","parentSession":"$root_one"}
{"type":"message","id":"r1-u1","parentId":null,"timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"root one prompt"}}
{"type":"message","id":"c1-u1","parentId":"r1-u1","timestamp":"2026-01-02T00:00:00.000Z","message":{"role":"user","content":"child branch"}}
EOF_CHILD_ONE
cat > "$root_two" <<EOF_ROOT_TWO
{"type":"session","version":3,"id":"root-two","timestamp":"2026-01-03T00:00:00.000Z","cwd":"$project_cwd"}
{"type":"session_info","name":"Root Two"}
{"type":"message","id":"r2-u1","parentId":null,"timestamp":"2026-01-03T00:00:00.000Z","message":{"role":"user","content":"root two prompt"}}
EOF_ROOT_TWO
cat > "$child_two" <<EOF_CHILD_TWO
{"type":"session","version":3,"id":"child-two","timestamp":"2026-01-04T00:00:00.000Z","cwd":"$project_cwd","parentSession":"$root_two"}
{"type":"message","id":"r2-u1","parentId":null,"timestamp":"2026-01-03T00:00:00.000Z","message":{"role":"user","content":"root two prompt"}}
{"type":"message","id":"c2-u1","parentId":"r2-u1","timestamp":"2026-01-04T00:00:00.000Z","message":{"role":"user","content":"second child branch"}}
EOF_CHILD_TWO
cat > "$root_three" <<EOF_ROOT_THREE
{"type":"session","version":3,"id":"root-three","timestamp":"2026-01-06T00:00:00.000Z","cwd":"$project_cwd"}
{"type":"session_info","name":"Root Three"}
{"type":"message","id":"r3-u1","parentId":null,"timestamp":"2026-01-06T00:00:00.000Z","message":{"role":"user","content":"root three prompt"}}
EOF_ROOT_THREE
cat > "$child_three" <<EOF_CHILD_THREE
{"type":"session","version":3,"id":"child-three","timestamp":"2026-01-07T00:00:00.000Z","cwd":"$project_cwd","parentSession":"$root_three"}
{"type":"message","id":"r3-u1","parentId":null,"timestamp":"2026-01-06T00:00:00.000Z","message":{"role":"user","content":"root three prompt"}}
{"type":"message","id":"c3-u1","parentId":"r3-u1","timestamp":"2026-01-07T00:00:00.000Z","message":{"role":"user","content":"third child branch"}}
EOF_CHILD_THREE
cat > "$unrelated" <<EOF_UNRELATED
{"type":"session","version":3,"id":"unrelated","timestamp":"2026-01-05T00:00:00.000Z","cwd":"$project_cwd"}
{"type":"session_info","name":"Unrelated"}
EOF_UNRELATED

lua_file="$(pidev_lua_file)"
cat > "$lua_file" <<LUA
require('pi-dev').setup({ keymaps = { enable = false }, session_root = '$session_root', cwd = '$project_cwd' })
local api = require('pi-dev.api')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

ui.show()
state.is_job_running = function(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime and runtime.job_id ~= nil
end

local function lines()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
end

local function readable(path)
  return vim.fn.filereadable(path) == 1
end

local function reset_runtimes(current_file, root_file)
  state.rpc.runtimes = {}
  state.rpc.active_key = 'delete-target'
  local target = state.ensure_rpc_runtime('delete-target')
  target.job_id = 101
  target.status = 'idle'
  target.session_file = current_file
  target.branch_root = root_file
  local other = state.ensure_rpc_runtime('other-runtime')
  other.job_id = 202
  other.status = 'idle'
  other.session_file = '$unrelated'
  state.sync_active_rpc_runtime(target)
  state.session.current_file = current_file
  state.session.tree_root_file = root_file
end

local select_calls = {}
vim.ui.select = function(choices, opts, callback)
  table.insert(select_calls, { choices = choices, opts = opts })
  assert(#choices == 3, vim.inspect(choices))
  assert(choices[1].action == 'cancel', vim.inspect(choices[1]))
  assert(choices[1].label == 'No', vim.inspect(choices[1]))
  assert(choices[2].action == 'trash', vim.inspect(choices[2]))
  assert(choices[2].label == 'Yes, move session tree to trash', vim.inspect(choices[2]))
  assert(choices[3].action == 'delete', vim.inspect(choices[3]))
  assert(choices[3].label == 'Yes, fully delete session tree', vim.inspect(choices[3]))
  assert((opts.prompt or ''):find('Root', 1, true), opts.prompt)
  callback(choices[vim.g.pi_dev_delete_choice])
end

reset_runtimes('$child_one', '$root_one')
local sessions = require('pi-dev.sessions')
local rpc = require('pi-dev.rpc')
rpc.request = function(message, cb)
  if cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  end
  return message.type
end
local branch_runtime = state.ensure_rpc_runtime('resume-delete-target')
branch_runtime.job_id = 303
branch_runtime.status = 'idle'
branch_runtime.session_file = '$child_two'
branch_runtime.branch_root = '$root_two'
sessions.pick()
assert(vim.wait(1000, function()
  return state.ui.interaction and state.ui.interaction.kind == 'resume'
end), 'resume picker should open before selected-row deletion')
local selected_root_two
for index, item in ipairs(state.ui.interaction.items or {}) do
  if item.root_path == '$root_two' then
    state.ui.interaction.selected = index
    selected_root_two = true
    break
  end
end
assert(selected_root_two, vim.inspect(state.ui.interaction.items))
vim.g.pi_dev_delete_choice = 2
assert(api.handle_slash_command('/delete-session'), 'resume selected delete command should be handled')
assert(not readable('$root_two') and not readable('$child_two'), 'resume selected delete must move selected tree files')
assert(readable('$root_one') and readable('$child_one'), 'resume selected delete must keep current session tree')
assert(state.session.current_file == '$child_one' and state.session.tree_root_file == '$root_one', 'non-current resume delete must keep current session state')
assert(state.rpc.runtimes['resume-delete-target'] == nil, 'resume selected delete must stop selected tree runtime')
assert(state.rpc.runtimes['delete-target'] ~= nil, 'resume selected delete must keep current runtime')
assert(vim.wait(1000, function()
  if not (state.ui.interaction and state.ui.interaction.kind == 'resume') then
    return false
  end
  for _, item in ipairs(state.ui.interaction.items or {}) do
    if item.root_path == '$root_two' then
      return false
    end
  end
  return true
end), 'resume picker should refresh without the deleted row: ' .. vim.inspect(state.ui.interaction and state.ui.interaction.items))
assert(lines():find('Moved Pi session tree to trash: 2 files.', 1, true), lines())
ui.close_interaction({ process_queue = false })

reset_runtimes('$child_one', '$root_one')
vim.g.pi_dev_delete_choice = 1
assert(api.handle_slash_command('/delete-session'), 'slash command should be handled')
assert(readable('$root_one') and readable('$child_one'), 'cancel must keep target files')
assert(state.rpc.runtimes['delete-target'] ~= nil, 'cancel must keep target runtime')

vim.g.pi_dev_delete_choice = 2
assert(api.handle_slash_command('/delete-session'), 'trash command should be handled')
assert(not readable('$root_one') and not readable('$child_one'), 'trash must move target tree files')
assert(readable('$unrelated'), 'trash must keep unrelated session')
assert(state.rpc.runtimes['delete-target'] == nil, 'trash must stop/remove target runtime')
assert(state.rpc.runtimes['other-runtime'] ~= nil, 'trash must keep unrelated runtime')
assert(state.session.current_file == nil and state.session.tree_root_file == nil, 'trash must clear deleted current session state')
local trash_files = vim.fn.glob('$session_root/.trash/pi-dev/*/files/**/*.jsonl', false, true)
assert(#trash_files == 4, vim.inspect(trash_files))
local manifests = vim.fn.glob('$session_root/.trash/pi-dev/*/manifest.json', false, true)
assert(#manifests == 2, vim.inspect(manifests))
local manifest = ''
for _, manifest_path in ipairs(manifests) do
  manifest = manifest .. '\n' .. table.concat(vim.fn.readfile(manifest_path), '\n')
end
assert(manifest:find('$root_one', 1, true) and manifest:find('$child_one', 1, true), manifest)
assert(lines():find('Moved Pi session tree to trash: 2 files.', 1, true), lines())

reset_runtimes('$child_three', '$root_three')
vim.g.pi_dev_delete_choice = 3
assert(api.handle_slash_command('/delete-session'), 'full delete command should be handled')
assert(not readable('$root_three') and not readable('$child_three'), 'full delete must remove target tree files')
assert(readable('$unrelated'), 'full delete must keep unrelated session')
assert(state.rpc.runtimes['delete-target'] == nil, 'full delete must stop/remove target runtime')
assert(state.rpc.runtimes['other-runtime'] ~= nil, 'full delete must keep unrelated runtime')
assert(state.session.current_file == nil and state.session.tree_root_file == nil, 'full delete must clear deleted current session state')
local trash_after_delete = vim.fn.glob('$session_root/.trash/pi-dev/*/manifest.json', false, true)
assert(#trash_after_delete == 2, 'full delete must not create a trash manifest: ' .. vim.inspect(trash_after_delete))
assert(lines():find('Permanently deleted Pi session tree: 2 files.', 1, true), lines())
assert(#select_calls == 4, vim.inspect(select_calls))
LUA

pidev_run_lua_file "$lua_file"
rm -f "$lua_file"
rm -rf "$session_root" "$project_cwd"
