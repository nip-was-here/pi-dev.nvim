#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, session_render = { max_messages = 10, chunk_delay_ms = 1 } })
local api = require('pi-dev.api')
local renderer = require('pi-dev.renderer')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local root_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'session_info', name = 'root session name with a deliberately very long title that should be truncated to fit the Pi panel' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'first question' } }),
  vim.json.encode({ type = 'message', id = 'a1-draft', parentId = 'u1', timestamp = '2026-01-01T00:00:01.500Z', message = { role = 'assistant', content = { { type = 'output_text', text = 'first draft answer' } } } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'a1-draft', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = { { type = 'output_text', text = 'first final model answer with a deliberately very long continuation that should be truncated before timestamp' } } } }),
  vim.json.encode({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'second question' } }),
  vim.json.encode({ type = 'message', id = 'tool-only-assistant', parentId = 'u2', timestamp = '2026-01-01T00:00:03.500Z', message = { role = 'assistant', content = { { type = 'toolCall', name = 'bash', arguments = { command = 'echo hidden tool call' } } }, stopReason = 'toolUse' } }),
  vim.json.encode({ type = 'message', id = 'a2', parentId = 'tool-only-assistant', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = { { type = 'text', text = 'second model answer' } } } }),
}, root_file)
local branch_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'branch', cwd = vim.uv.cwd(), parentSession = root_file, timestamp = '2026-01-01T00:00:05.000Z' }),
  vim.json.encode({ type = 'message', id = 'u1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'first question' } }),
  vim.json.encode({ type = 'message', id = 'a1-draft', parentId = 'u1', timestamp = '2026-01-01T00:00:01.500Z', message = { role = 'assistant', content = { { type = 'output_text', text = 'first draft answer' } } } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'a1-draft', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = { { type = 'output_text', text = 'first final model answer with a deliberately very long continuation that should be truncated before timestamp' } } } }),
  vim.json.encode({ type = 'message', id = 'u3', parentId = 'a1', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'user', content = 'branch question' } }),
  vim.json.encode({ type = 'message', id = 'a3', parentId = 'u3', timestamp = '2026-01-01T00:00:06.000Z', message = { role = 'assistant', content = { { type = 'text', text = 'branch answer' } } } }),
}, branch_file)
state.session.current_file = root_file
ui.set_input_text('stale fork prompt')

local sent = {}
rpc.request = function(message, cb)
  table.insert(sent, message)
  if message.type == 'switch_session' and cb then
    cb({ success = true, data = { cancelled = false } })
  elseif message.type == 'fork' and cb then
    cb({ success = true, data = { text = 'forked from branch entry' } })
  elseif message.type == 'get_state' and cb then
    cb({ success = true, data = { sessionFile = message.sessionPath or root_file } })
  elseif message.type == 'get_session_stats' and cb then
    cb({ success = true, data = {} })
  end
  return message.type
end

local function output_closed_fold_count()
  local count = 0
  vim.api.nvim_win_call(state.ui.output_win, function()
    for line = 1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(state.ui.output_win)) do
      if vim.fn.foldclosed(line) ~= -1 then
        count = count + 1
      end
    end
  end)
  return count
end

ui.show()
renderer.clear('Tree fold prelude')
local long_output = table.concat(vim.tbl_map(function(i)
  return 'tool line ' .. i
end, vim.fn.range(1, 40)), '\n')
renderer.handle_event({ type = 'tool_execution_start', toolCallId = 'tree-fold-prelude', toolName = 'bash', args = { command = 'printf long' } })
renderer.handle_event({ type = 'tool_execution_end', toolCallId = 'tree-fold-prelude', toolName = 'bash', result = { content = { { type = 'text', text = long_output } } } })
assert(output_closed_fold_count() > 0, 'test setup should create a closed output fold before opening tree')

state.session.current_file = nil
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'live/new-session tree interaction missing')
assert(output_closed_fold_count() == 0, 'tree interaction must not inherit or create auto-folds')
local live_labels = vim.inspect(state.ui.interaction.items)
assert(#state.ui.interaction.items == 4, 'tree should refresh current session file from RPC state and include only assistant block edges by default')
assert(state.ui.interaction.items[2].label:find('Assistant: first final model answer', 1, true), live_labels)
assert(state.ui.interaction.items[2].label:find('...', 1, true), live_labels)
assert(state.ui.interaction.items[2].label:find('%([^()]+%)$'), live_labels)
assert(vim.fn.strdisplaywidth(state.ui.interaction.items[2].label) <= vim.api.nvim_win_get_width(state.ui.output_win), live_labels)
assert(not live_labels:find('first draft answer', 1, true), live_labels)
assert(sent[1] and sent[1].type == 'get_state', 'tree should query state when current session file is unknown')
ui.close_interaction()
assert(output_closed_fold_count() > 0, 'closing tree should restore previous output folds outside the tree view')
sent = {}
state.session.current_file = root_file
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction missing')
assert(#state.ui.interaction.items == 4, 'tree should include user and final text assistant messages, skipping tool-only and intermediate assistant turns')
assert(state.ui.interaction.selected == 4, 'tree should initially focus current visible session position')
assert(state.ui.interaction.surface == 'output', 'tree interaction should use the large output/session buffer')
assert(vim.bo[vim.api.nvim_win_get_buf(state.ui.output_win)].filetype == 'text', 'tree interaction must not use markdown rendering')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'tree interaction should leave the input buffer visible')
local tree_text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(tree_text:find('#####', 1, true) == nil, tree_text)
assert(tree_text:find('%- %d+%.') == nil, tree_text)
assert(tree_text:find('%d%d:%d%d') ~= nil, tree_text)
local labels = vim.inspect(state.ui.interaction.items)
assert(state.ui.interaction.items[2].label:find('Assistant: first final model answer', 1, true), labels)
assert(state.ui.interaction.items[2].label:find('...', 1, true), labels)
assert(state.ui.interaction.items[2].label:find('%([^()]+%)$'), labels)
assert(not labels:find('first draft answer', 1, true), labels)
assert(state.ui.interaction.items[4].label:find('Assistant: second model answer', 1, true), labels)
assert(not labels:find('Response row', 1, true), labels)
assert(not labels:find('hidden tool call', 1, true), labels)
require('pi-dev.config').options.tree.assistant_responses = 'all'
ui.close_interaction()
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction missing with all response rows enabled')
labels = vim.inspect(state.ui.interaction.items)
assert(#state.ui.interaction.items == 5, labels)
assert(labels:find('first draft answer', 1, true), labels)
require('pi-dev.config').options.tree.assistant_responses = 'last_per_user'
ui.close_interaction()
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'tree interaction missing after restoring default assistant mode')
vim.api.nvim_feedkeys('4', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil and sent[1].type == 'switch_session' end), 'assistant selection should switch to selected response session')
assert(sent[1].sessionPath == root_file, 'latest response row should switch to root end')
assert(ui.get_input_text() == '', 'assistant tree selection must not fill Pi input')
assert(vim.wait(1000, function() return tostring(state.ui.output_title or ''):find('^Pi chat: first question') ~= nil end), state.ui.output_title or 'nil')
assert(vim.fn.strdisplaywidth(state.ui.output_title) <= require('pi-dev.format').window_text_width(state.ui.output_win), state.ui.output_title)
assert(state.ui.output_title ~= 'Pi.dev tree selection', 'tree selection title must not leak into session output title')
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n'):find('second model answer', 1, true) ~= nil
end), 'response row should render')
local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(text:find('second model answer', 1, true), text)
assert(text:find('stale fork prompt', 1, true) == nil, text)

ui.close_interaction()
state.session.current_file = branch_file
local badge_runtime = state.ensure_rpc_runtime('badge-branch')
badge_runtime.active = true
badge_runtime.status = 'running'
badge_runtime.session_file = branch_file
badge_runtime.branch_root = root_file
badge_runtime.branch_entry_id = 'u3'
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'branch tree interaction missing')
labels = vim.inspect(state.ui.interaction.items)
assert(labels:find('| * branch question', 1, true), labels)
assert(labels:find('| * Assistant: branch answer', 1, true), labels)
assert(not labels:find('first draft answer', 1, true), labels)
assert(labels:find('| * second question', 1, true), labels)
assert(labels:find('| * Assistant: second model answer', 1, true), labels)
local branch_question_label = state.ui.interaction.items[3].label
local branch_answer_label = state.ui.interaction.items[4].label
assert(not branch_question_label:find('%[run%]'), branch_question_label)
assert(branch_answer_label:find('%[run%]%s+%([^%)]+%)$'), branch_answer_label)
assert(not branch_answer_label:find('Assistant: branch answer %[run%]', 1, false), branch_answer_label)
state.remove_rpc_runtime('badge-branch')
local tree_render = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(tree_render:find('|\\', 1, true), tree_render)
assert(tree_render:find('>', 1, true) == nil, tree_render)
local branch_connector_row = state.ui.interaction.item_line_by_index[3] - 1
assert(state.ui.interaction.line_to_item[branch_connector_row] == nil, 'connector graph rows must not be selectable')
local main_continuation_prev_row = state.ui.interaction.item_line_by_index[5] - 1
assert(state.ui.interaction.line_to_item[main_continuation_prev_row] == nil, 'returning from a completed branch should insert a non-selectable vertical connector row')
local main_continuation_prev_text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), main_continuation_prev_row - 1, main_continuation_prev_row, false)[1] or ''
assert(main_continuation_prev_text:find('|', 1, true), main_continuation_prev_text)
assert(main_continuation_prev_text:find('/', 1, true) == nil, main_continuation_prev_text)
sent = {}
vim.api.nvim_feedkeys('3', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil and sent[2] ~= nil end), vim.inspect(sent))
assert(sent[1].type == 'switch_session' and sent[1].sessionPath == branch_file, vim.inspect(sent))
assert(sent[2].type == 'fork' and sent[2].entryId == 'u3', vim.inspect(sent))
state.session.current_file = branch_file
sent = {}
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'branch tree interaction missing before assistant source selection')
vim.api.nvim_feedkeys('4', 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil and sent[1].type == 'switch_session' end), vim.inspect(sent))
assert(sent[1].sessionPath == branch_file, 'branch assistant selection should switch to the branch file that owns the entry')
state.session.current_file = branch_file
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'branch tree interaction missing before q close')
vim.api.nvim_set_current_win(state.ui.output_win)
vim.api.nvim_feedkeys('q', 'xt', false)
assert(vim.wait(1000, function() return state.ui.interaction == nil end), 'q should close tree interaction')
assert(vim.api.nvim_win_is_valid(state.ui.input_win), 'q must not close the lower Pi pane')
assert(vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf, 'q should restore the normal Pi input buffer')

local session_root = vim.fn.tempname()
vim.fn.mkdir(session_root, 'p')
require('pi-dev.config').options.session_root = session_root
local whole_root = session_root .. '/root.jsonl'
local sibling_branch = session_root .. '/sibling.jsonl'
local unlinked_main_branch = session_root .. '/unlinked-main.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'whole-root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'wu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'whole root first' } }),
  vim.json.encode({ type = 'message', id = 'wa1', parentId = 'wu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'whole root answer' } }),
  vim.json.encode({ type = 'message', id = 'wu2', parentId = 'wa1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'main branch after fork' } }),
  vim.json.encode({ type = 'message', id = 'wa2', parentId = 'wu2', timestamp = '2026-01-01T00:00:03.500Z', message = { role = 'assistant', content = 'main branch immediate answer' } }),
  vim.json.encode({ type = 'message', id = 'wu3', parentId = 'wa2', timestamp = '2026-01-01T00:00:03.750Z', message = { role = 'user', content = 'deep main continuation should stay with main branch' } }),
  vim.json.encode({ type = 'message', id = 'wa3', parentId = 'wu3', timestamp = '2026-01-01T00:00:03.900Z', message = { role = 'assistant', content = 'deep main answer' } }),
}, whole_root)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'sibling', cwd = vim.uv.cwd(), parentSession = whole_root, timestamp = '2026-01-01T00:00:04.000Z' }),
  vim.json.encode({ type = 'message', id = 'wu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'whole root first' } }),
  vim.json.encode({ type = 'message', id = 'wa1', parentId = 'wu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'whole root answer' } }),
  vim.json.encode({ type = 'message', id = 'bu1', parentId = 'wa1', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'user', content = 'sibling branch after fork' } }),
  vim.json.encode({ type = 'message', id = 'ba1', parentId = 'bu1', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'assistant', content = 'sibling branch answer' } }),
}, sibling_branch)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'unlinked-main', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:06.000Z' }),
  vim.json.encode({ type = 'message', id = 'wu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'whole root first' } }),
  vim.json.encode({ type = 'message', id = 'wa1', parentId = 'wu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'whole root answer' } }),
  vim.json.encode({ type = 'message', id = 'um1', parentId = 'wa1', timestamp = '2026-01-01T00:00:06.000Z', message = { role = 'user', content = 'unlinked main branch still visible' } }),
}, unlinked_main_branch)
state.session.current_file = sibling_branch
state.session.tree_root_file = whole_root
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'whole tree interaction missing after branch navigation')
labels = vim.inspect(state.ui.interaction.items)
assert(labels:find('main branch after fork', 1, true), labels)
assert(labels:find('unlinked main branch still visible', 1, true), labels)
assert(labels:find('sibling branch after fork', 1, true), labels)
assert(labels:find('Assistant: sibling branch answer', 1, true), labels)
ui.close_interaction()

state.session.current_file = whole_root
state.session.tree_root_file = whole_root
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'main-active whole tree interaction missing')
local function item_index(fragment)
  for index, item in ipairs(state.ui.interaction.items or {}) do
    if tostring(item.label or ''):find(fragment, 1, true) then
      return index
    end
  end
end
local fork_parent_index = item_index('Assistant: whole root answer')
local main_index = item_index('main branch after fork')
local sibling_index = item_index('sibling branch after fork')
local deep_index = item_index('deep main continuation')
local unlinked_index = item_index('unlinked main branch still visible')
assert(fork_parent_index and main_index and sibling_index and deep_index and unlinked_index, vim.inspect(state.ui.interaction.items))
assert(unlinked_index < sibling_index and sibling_index < main_index and main_index < deep_index, vim.inspect(state.ui.interaction.items))
local main_label = state.ui.interaction.items[main_index].label
local sibling_label = state.ui.interaction.items[sibling_index].label
local unlinked_label = state.ui.interaction.items[unlinked_index].label
assert(vim.startswith(main_label, '| * main branch after fork'), main_label)
assert(vim.startswith(sibling_label, '| * sibling branch after fork'), sibling_label)
assert(vim.startswith(unlinked_label, '| * unlinked main branch still visible'), unlinked_label)
local sibling_connector_row = state.ui.interaction.item_line_by_index[sibling_index] - 1
assert(state.ui.interaction.line_to_item[sibling_connector_row] == nil, 'sibling connector row must be non-selectable')
local sibling_connector = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), sibling_connector_row - 1, sibling_connector_row, false)[1] or ''
assert(sibling_connector:find('|', 1, true), sibling_connector)
assert(sibling_connector:find('/', 1, true) == nil, sibling_connector)
ui.close_interaction()

local nested_root_dir = vim.fn.tempname()
vim.fn.mkdir(nested_root_dir, 'p')
require('pi-dev.config').options.session_root = nested_root_dir
local nested_root = nested_root_dir .. '/nested-root.jsonl'
local nested_rubric = nested_root_dir .. '/nested-rubric.jsonl'
local nested_study = nested_root_dir .. '/nested-study.jsonl'
local nested_opt = nested_root_dir .. '/nested-opt.jsonl'
local nested_raw = nested_root_dir .. '/nested-raw.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'nested-root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'nu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'prepare plugin' } }),
  vim.json.encode({ type = 'message', id = 'na1', parentId = 'nu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'codebase study answer' } }),
}, nested_root)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'nested-rubric', cwd = vim.uv.cwd(), parentSession = nested_root, timestamp = '2026-01-01T00:00:03.000Z' }),
  vim.json.encode({ type = 'message', id = 'nu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'prepare plugin' } }),
  vim.json.encode({ type = 'message', id = 'na1', parentId = 'nu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'codebase study answer' } }),
  vim.json.encode({ type = 'message', id = 'rubric-user', parentId = 'na1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'bugfix rubric' } }),
  vim.json.encode({ type = 'message', id = 'rubric-assistant', parentId = 'rubric-user', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'send first bug' } }),
  vim.json.encode({ type = 'message', id = 'session-tree-user', parentId = 'rubric-assistant', timestamp = '2026-01-01T00:00:05.000Z', message = { role = 'user', content = 'session tree current bug' } }),
}, nested_rubric)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'nested-study', cwd = vim.uv.cwd(), parentSession = nested_root, timestamp = '2026-01-01T00:00:06.000Z' }),
  vim.json.encode({ type = 'message', id = 'nu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'prepare plugin' } }),
  vim.json.encode({ type = 'message', id = 'na1', parentId = 'nu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'codebase study answer' } }),
  vim.json.encode({ type = 'message', id = 'study-user', parentId = 'na1', timestamp = '2026-01-01T00:00:06.000Z', message = { role = 'user', content = 'study Pi TUI commands' } }),
}, nested_study)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'nested-raw', cwd = vim.uv.cwd(), parentSession = nested_root, timestamp = '2026-01-01T00:00:06.500Z' }),
  vim.json.encode({ type = 'message', id = 'nu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'prepare plugin' } }),
  vim.json.encode({ type = 'message', id = 'na1', parentId = 'nu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'codebase study answer' } }),
  vim.json.encode({ type = 'message', id = 'rubric-user', parentId = 'na1', timestamp = '2026-01-01T00:00:03.000Z', message = { role = 'user', content = 'bugfix rubric' } }),
  vim.json.encode({ type = 'message', id = 'rubric-assistant', parentId = 'rubric-user', timestamp = '2026-01-01T00:00:04.000Z', message = { role = 'assistant', content = 'send first bug' } }),
  vim.json.encode({ type = 'message', id = 'raw-user', parentId = 'rubric-assistant', timestamp = '2026-01-01T00:00:06.500Z', message = { role = 'user', content = 'raw markdown bug' } }),
}, nested_raw)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'nested-opt', cwd = vim.uv.cwd(), parentSession = nested_root, timestamp = '2026-01-01T00:00:07.000Z' }),
  vim.json.encode({ type = 'message', id = 'nu1', parentId = nil, timestamp = '2026-01-01T00:00:01.000Z', message = { role = 'user', content = 'prepare plugin' } }),
  vim.json.encode({ type = 'message', id = 'na1', parentId = 'nu1', timestamp = '2026-01-01T00:00:02.000Z', message = { role = 'assistant', content = 'codebase study answer' } }),
  vim.json.encode({ type = 'message', id = 'opt-user', parentId = 'na1', timestamp = '2026-01-01T00:00:07.000Z', message = { role = 'user', content = 'optimize project pipeline' } }),
}, nested_opt)
state.session.current_file = nested_rubric
state.session.tree_root_file = nested_root
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'nested fork-point tree interaction missing')
local function nested_item_index(fragment)
  for index, item in ipairs(state.ui.interaction.items or {}) do
    if tostring(item.label or ''):find(fragment, 1, true) then
      return index
    end
  end
end
local rubric_index = nested_item_index('bugfix rubric')
local study_index = nested_item_index('study Pi TUI commands')
local opt_index = nested_item_index('optimize project pipeline')
local nested_session_index = nested_item_index('session tree current bug')
local raw_index = nested_item_index('raw markdown bug')
local rubric_label = rubric_index and state.ui.interaction.items[rubric_index].label
local study_label = study_index and state.ui.interaction.items[study_index].label
local opt_label = opt_index and state.ui.interaction.items[opt_index].label
local nested_session_label = nested_session_index and state.ui.interaction.items[nested_session_index].label
local raw_label = raw_index and state.ui.interaction.items[raw_index].label
assert(rubric_label and study_label and opt_label and nested_session_label and raw_label, vim.inspect(state.ui.interaction.items))
assert(opt_index < rubric_index and rubric_index < raw_index and raw_index < nested_session_index, vim.inspect(state.ui.interaction.items))
assert(nested_session_index < study_index, vim.inspect(state.ui.interaction.items))
assert(vim.startswith(rubric_label, '| * bugfix rubric'), rubric_label)
assert(vim.startswith(study_label, '| * study Pi TUI commands'), study_label)
assert(vim.startswith(opt_label, '| * optimize project pipeline'), opt_label)
assert(vim.startswith(nested_session_label, '| | * session tree current bug'), nested_session_label)
assert(vim.startswith(raw_label, '| | * raw markdown bug'), raw_label)
local nested_render = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(nested_render:find('| |\\', 1, true), nested_render)
ui.close_interaction()

sent = {}
require('pi-dev.config').options.session_root = vim.fn.fnamemodify(root_file, ':h')
state.session.current_file = root_file
ui.set_input_text('another stale prompt')
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'second tree interaction missing')
vim.api.nvim_set_current_win(state.ui.output_win)
vim.api.nvim_win_set_cursor(state.ui.output_win, { state.ui.interaction.item_start_line + 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false)
assert(vim.wait(1000, function() return sent[1] ~= nil and sent[1].type == 'switch_session' end), 'middle assistant selection should switch to a branched session')
assert(sent[1].sessionPath ~= root_file, 'middle response row should use a branch file at that response')
assert(ui.get_input_text() == '', 'middle assistant selection must not fill Pi input')
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n'):find('first final model answer', 1, true) ~= nil
end), 'middle response row should render')
text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(state.ui.output_win), 0, -1, false), '\n')
assert(text:find('first final model answer', 1, true), text)
assert(text:find('second model answer', 1, true) == nil, text)
assert(text:find('another stale prompt', 1, true) == nil, text)
ui.close_interaction()

local dup_dir = vim.fn.tempname()
vim.fn.mkdir(dup_dir, 'p')
require('pi-dev.config').options.session_root = dup_dir
local dup_root = dup_dir .. '/root.jsonl'
local dup_branch_a = dup_dir .. '/branch-a.jsonl'
local dup_branch_b = dup_dir .. '/branch-b.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'dup-root', cwd = vim.uv.cwd(), timestamp = '2026-01-01T00:00:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'dup-u1', parentId = nil, timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'user', content = 'duplicate root' } }),
  vim.json.encode({ type = 'message', id = 'dup-a1', parentId = 'dup-u1', timestamp = '2026-01-01T00:02:00.000Z', message = { role = 'assistant', content = 'duplicate root answer' } }),
}, dup_root)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'dup-branch-a', cwd = vim.uv.cwd(), parentSession = dup_root, timestamp = '2026-01-01T00:03:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'dup-u1', parentId = nil, timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'user', content = 'duplicate root' } }),
  vim.json.encode({ type = 'message', id = 'dup-a1', parentId = 'dup-u1', timestamp = '2026-01-01T00:02:00.000Z', message = { role = 'assistant', content = 'duplicate root answer' } }),
  vim.json.encode({ type = 'message', id = 'dup-a-user', parentId = 'dup-a1', timestamp = '2026-01-01T00:03:00.000Z', message = { role = 'user', content = 'same duplicated branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'dup-a-answer', parentId = 'dup-a-user', timestamp = '2026-01-01T00:04:00.000Z', message = { role = 'assistant', content = 'same duplicated branch answer' } }),
}, dup_branch_a)
vim.fn.writefile({
  vim.json.encode({ type = 'session', version = 3, id = 'dup-branch-b', cwd = vim.uv.cwd(), parentSession = dup_root, timestamp = '2026-01-01T00:05:00.000Z' }),
  vim.json.encode({ type = 'message', id = 'dup-u1', parentId = nil, timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'user', content = 'duplicate root' } }),
  vim.json.encode({ type = 'message', id = 'dup-a1', parentId = 'dup-u1', timestamp = '2026-01-01T00:02:00.000Z', message = { role = 'assistant', content = 'duplicate root answer' } }),
  vim.json.encode({ type = 'message', id = 'dup-b-user', parentId = 'dup-a1', timestamp = '2026-01-01T00:05:00.000Z', message = { role = 'user', content = 'same duplicated branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'dup-b-answer', parentId = 'dup-b-user', timestamp = '2026-01-01T00:06:00.000Z', message = { role = 'assistant', content = 'same duplicated branch answer' } }),
}, dup_branch_b)
local dup_runtime = state.ensure_rpc_runtime('duplicate-running-branch')
dup_runtime.active = true
dup_runtime.status = 'running'
dup_runtime.session_file = dup_branch_a
dup_runtime.branch_root = dup_root
-- A runtime can stay keyed to the fork point while its session file moves forward.
-- When sibling branches contain identical prompt/answer text, the badge must follow
-- the runtime session file rather than the last text-identical descendant.
dup_runtime.branch_entry_id = 'dup-a1'
state.session.current_file = dup_branch_a
state.session.tree_root_file = dup_root
api.tree()
assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'duplicate branch tree interaction missing')
local dup_running_label
local dup_running_text
local dup_running_count = 0
for _, item in ipairs(state.ui.interaction.items or {}) do
  local label = tostring(item.label or '')
  if label:find('%[run%]') then
    dup_running_count = dup_running_count + 1
    dup_running_label = label
    dup_running_text = item.text
  end
end
local dup_labels = vim.inspect(state.ui.interaction.items)
local branch_a_time = require('pi-dev.format').human_time_from_timestamp('2026-01-01T00:04:00.000Z')
local branch_b_time = require('pi-dev.format').human_time_from_timestamp('2026-01-01T00:06:00.000Z')
assert(dup_running_count == 1, dup_labels)
assert(dup_running_text == 'same duplicated branch answer', dup_running_label or dup_labels)
assert(dup_running_label:find('%[run%]', 1, false), dup_running_label)
assert(dup_running_label:find('(' .. branch_a_time .. ')', 1, true), dup_running_label .. '\nexpected branch A time ' .. tostring(branch_a_time))
assert(not dup_running_label:find('(' .. branch_b_time .. ')', 1, true), dup_running_label .. '\nwrong branch B time ' .. tostring(branch_b_time))
state.remove_rpc_runtime('duplicate-running-branch')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
