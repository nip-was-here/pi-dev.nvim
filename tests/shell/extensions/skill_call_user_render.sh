#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 100, input_height = 10 } })
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
require('pi-dev.ui').show()

local skill_text = [[<skill name="grill-with-docs" location="./tmp/pi-dev-test/skills/grill-with-docs/SKILL.md">
References are relative to ./tmp/pi-dev-test/skills/grill-with-docs.

Run a `/grilling` session, using the `/domain-modeling` skill.
</skill>

Understand why rendering is slow.]]

renderer.render_messages({
  { role = 'user', content = skill_text },
}, 'Skill render')
local text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('## User', 1, true), text)
assert(text:find('**Skill call:** `grill-with-docs`\nUnderstand why rendering is slow.', 1, true), text)
assert(text:find('**Location:**', 1, true) == nil, text)
assert(text:find('References are relative to', 1, true) == nil, text)
assert(text:find('Run a `/grilling` session', 1, true) == nil, text)
assert(text:find('<skill', 1, true) == nil, text)
assert(text:find('</skill>', 1, true) == nil, text)

renderer.clear('Live skill render')
renderer.append_user(skill_text, '2026-01-01T00:00:00.000Z')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('**Skill call:** `grill-with-docs`\nUnderstand why rendering is slow.', 1, true), text)
assert(text:find('**Location:**', 1, true) == nil, text)
assert(text:find('<skill', 1, true) == nil, text)
assert(text:find('</skill>', 1, true) == nil, text)

renderer.clear('Slash skill dedupe')
renderer.append_user('/skill:grill-with-docs Understand why rendering is slow.', '2026-01-01T00:00:00.000Z')
renderer.handle_event({ type = 'agent_start' })
renderer.handle_event({ type = 'message_start', message = { role = 'user', content = skill_text } })
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
local _, user_count = text:gsub('## User', '')
local _, skill_count = text:gsub('%*%*Skill call:%*%* `grill%-with%-docs`', '')
assert(user_count == 1, text)
assert(skill_count == 1, text)
assert(text:find('/skill:grill-with-docs', 1, true) == nil, text)
assert(text:find('References are relative to', 1, true) == nil, text)

local sessions = require('pi-dev.sessions')
local rpc = require('pi-dev.rpc')
local root_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'skill-user', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = skill_text } }),
  vim.json.encode({ type = 'message', id = 'skill-answer', parentId = 'skill-user', timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'assistant', content = 'skill answer' } }),
}, root_file)
state.session.current_file = root_file
state.session.tree_root_file = nil
sessions.tree()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Pi tree' end), 'tree interaction should open')
local tree_labels = vim.inspect(state.ui.interaction.items)
assert(tree_labels:find('Skill: grill-with-docs Understand why rendering is slow.', 1, true), tree_labels)
assert(tree_labels:find('Run a `/grilling` session', 1, true) == nil, tree_labels)
assert(tree_labels:find('<skill', 1, true) == nil, tree_labels)
assert(tree_labels:find('./tmp/pi-dev-test/skills', 1, true) == nil, tree_labels)

state.is_job_running = function(runtime)
  return runtime and runtime.job_id ~= nil
end
local wait_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'wait-skill-user', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = skill_text } }),
}, wait_file)
state.session.current_file = wait_file
state.session.tree_root_file = nil
local runtime = state.ensure_rpc_runtime('skill-waiting-runtime')
runtime.job_id = 102
runtime.active = true
runtime.waiting_input = true
runtime.status = 'waiting input'
runtime.session_file = wait_file
runtime.branch_root = wait_file
runtime.branch_entry_id = 'wait-skill-user'
runtime.pending_extension_ui_request = {
  type = 'extension_ui_request',
  __pi_runtime_key = 'skill-waiting-runtime',
  id = 'skill-waiting-select',
  method = 'select',
  title = 'Waiting skill select',
  options = { 'Yes', 'No' },
}
rpc.request = function(message, cb)
  if message.type == 'get_state' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { sessionFile = wait_file, model = 'fake/skill' } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = {} })
  elseif message.type == 'get_messages' and cb then
    cb({ __pi_runtime_key = state.rpc.active_key, success = true, data = { messages = {} } })
  end
  return message.type
end
sessions.waiting()
assert(vim.wait(1000, function() return state.ui.interaction and state.ui.interaction.title == 'Pi waiting input' end), 'waiting interaction should open')
local waiting_labels = vim.inspect(state.ui.interaction.items)
assert(waiting_labels:find('Skill: grill-with-docs Understand why rendering is slow.', 1, true), waiting_labels)
assert(waiting_labels:find('Run a `/grilling` session', 1, true) == nil, waiting_labels)
assert(waiting_labels:find('<skill', 1, true) == nil, waiting_labels)
assert(waiting_labels:find('./tmp/pi-dev-test/skills', 1, true) == nil, waiting_labels)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
