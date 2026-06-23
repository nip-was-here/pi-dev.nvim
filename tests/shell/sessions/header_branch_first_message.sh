#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({
  keymaps = { enable = false },
  session_render = { max_messages = false, chunk_size = 100, chunk_delay_ms = 1 },
  ui = { width = 80, input_height = 8, session_title_branch_fraction = 0.6 },
})
local ui = require('pi-dev.ui')
local sessions = require('pi-dev.sessions')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')

ui.show()

local function output_text()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
end

local function winbar_title()
  return vim.wo[state.ui.output_win].winbar or state.ui.output_title or ''
end

local function assert_branch_title(expected)
  local prefix = expected:sub(1, math.min(#expected, 12))
  assert(vim.wait(1000, function()
    local title = winbar_title()
    return title:find('^ Pi chat: ') and title:find(prefix, 1, true)
  end), winbar_title())
  assert(output_text():find('> Last user:', 1, true) == nil, output_text())
end

local function assert_latest_in_title(expected)
  local prefix = expected:sub(1, math.min(#expected, 12))
  assert(vim.wait(1000, function()
    local title = winbar_title()
    return title:find('^ Pi chat: ') and title:find(' | ', 1, true) and title:find(prefix, 1, true)
  end), winbar_title())
  assert(output_text():find('> Last user:', 1, true) == nil, output_text())
end

local function assert_no_latest_in_title()
  assert(vim.wait(1000, function()
    local title = winbar_title()
    return title:find('^ Pi chat: ') and not title:find(' | ', 1, true)
  end), winbar_title())
  assert(output_text():find('> Last user:', 1, true) == nil, output_text())
end

local root_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'first root prompt should stay in header' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'assistant', content = { { type = 'text', text = 'latest assistant answer must not replace header' } } } }),
}, root_file)

sessions.render_current('Pi.dev session', root_file)
assert(vim.wait(1000, function()
  local first = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''
  return first:find('# Pi.dev session: first root prompt should stay in header', 1, true) ~= nil
end), output_text())
assert_branch_title('first root prompt should stay in header')
assert_no_latest_in_title()

renderer.append_permission_request('perm-1', 'bash `pwd`', { 'Permission Required', 'Allow it?' })
assert((vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''):find('# Pi.dev session: first root prompt should stay in header', 1, true), output_text())
assert_no_latest_in_title()

renderer.append_user('new live prompt from this branch must not replace header')
assert((vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''):find('# Pi.dev session: first root prompt should stay in header', 1, true), output_text())
assert_latest_in_title('new live prompt from this branch must not replace header')

renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'final live answer must not replace header' } })
assert(vim.wait(1000, function()
  local first = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''
  return first:find('# Pi.dev session: first root prompt should stay in header', 1, true) ~= nil
end), output_text())
assert_latest_in_title('new live prompt from this branch must not replace header')

local child_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), parentSession = root_file }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'first root prompt should stay in header' } }),
  vim.json.encode({ type = 'message', id = 'a1', parentId = 'u1', timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'assistant', content = { { type = 'text', text = 'latest root answer copied into branch' } } } }),
  vim.json.encode({ type = 'message', id = 'u2', parentId = 'a1', timestamp = '2026-01-01T00:02:00.000Z', message = { role = 'user', content = 'first prompt after branch point' } }),
  vim.json.encode({ type = 'message', id = 'a2', parentId = 'u2', timestamp = '2026-01-01T00:03:00.000Z', message = { role = 'assistant', content = { { type = 'text', text = 'latest branch answer must not replace branch prompt' } } } }),
  vim.json.encode({ type = 'message', id = 'u3', parentId = 'a2', timestamp = '2026-01-01T00:04:00.000Z', message = { role = 'user', content = '/skill:review inspect branch' } }),
  vim.json.encode({ type = 'message', id = 'a3', parentId = 'u3', timestamp = '2026-01-01T00:05:00.000Z', message = { role = 'assistant', content = { { type = 'text', text = 'latest branch answer after skill user' } } } }),
}, child_file)

sessions.render_current('Pi.dev session', child_file)
assert(vim.wait(1000, function()
  local first = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''
  return first:find('# Pi.dev session: first prompt after branch point', 1, true) ~= nil
end), output_text())
assert_branch_title('first prompt after branch point')
assert_latest_in_title('Skill: review inspect branch')

local multi_user_root_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'root-multi-u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'first loaded root prompt' } }),
  vim.json.encode({ type = 'message', id = 'root-multi-a1', parentId = 'root-multi-u1', timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'assistant', content = 'root answer' } }),
  vim.json.encode({ type = 'message', id = 'root-multi-u2', parentId = 'root-multi-a1', timestamp = '2026-01-01T00:02:00.000Z', message = { role = 'user', content = '<skill name="loaded-review"></skill> inspect loaded history' } }),
}, multi_user_root_file)
sessions.render_current('Pi.dev session', multi_user_root_file)
assert(vim.wait(1000, function()
  local first = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''
  return first:find('# Pi.dev session: first loaded root prompt', 1, true) ~= nil
end), output_text())
assert_branch_title('first loaded root prompt')
assert_latest_in_title('Skill: loaded-review inspect loaded history')

local rpc = require('pi-dev.rpc')
rpc.request = function(message, cb)
  assert(message.type == 'get_messages', vim.inspect(message))
  cb({ success = true, data = { messages = {
    { role = 'user', content = 'first rpc loaded prompt' },
    { role = 'assistant', content = 'rpc answer' },
    { role = 'user', content = 'latest rpc loaded prompt' },
  } } })
  return message.type
end
sessions.render_current('Pi.dev session', false)
assert(vim.wait(1000, function()
  local first = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''
  return first:find('# Pi.dev session: first rpc loaded prompt', 1, true) ~= nil
end), output_text())
assert_branch_title('first rpc loaded prompt')
assert_latest_in_title('latest rpc loaded prompt')

local empty_branch_file = vim.fn.tempname()
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), parentSession = root_file }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'first root prompt should stay in header' } }),
}, empty_branch_file)
sessions.render_current('Pi.dev session', empty_branch_file)
assert(vim.wait(1000, function()
  local first = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''
  return first:find('# Pi.dev session: first root prompt should stay in header', 1, true) ~= nil
end), output_text())
assert_no_latest_in_title()
renderer.append_user('branch first live prompt should become header')
assert(vim.wait(1000, function()
  local first = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''
  return first:find('# Pi.dev session: branch first live prompt', 1, true) ~= nil
end), output_text())
assert_branch_title('branch first live prompt should become header')
assert_no_latest_in_title()

local nested_dir = vim.fn.tempname()
vim.fn.mkdir(nested_dir, 'p')
local nested_root = nested_dir .. '/root.jsonl'
local nested_middle = nested_dir .. '/middle.jsonl'
local nested_leaf = nested_dir .. '/leaf.jsonl'
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd() }),
  vim.json.encode({ type = 'message', id = 'nested-root-u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'nested root prompt' } }),
  vim.json.encode({ type = 'message', id = 'nested-root-a1', parentId = 'nested-root-u1', timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'assistant', content = 'nested root answer' } }),
}, nested_root)
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), parentSession = nested_root }),
  vim.json.encode({ type = 'message', id = 'nested-root-u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'nested root prompt' } }),
  vim.json.encode({ type = 'message', id = 'nested-root-a1', parentId = 'nested-root-u1', timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'assistant', content = 'nested root answer' } }),
  vim.json.encode({ type = 'message', id = 'nested-middle-u1', parentId = 'nested-root-a1', timestamp = '2026-01-01T00:02:00.000Z', message = { role = 'user', content = 'nested middle branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'nested-middle-a1', parentId = 'nested-middle-u1', timestamp = '2026-01-01T00:03:00.000Z', message = { role = 'assistant', content = 'nested middle answer' } }),
  vim.json.encode({ type = 'message', id = 'nested-middle-u2', parentId = 'nested-middle-a1', timestamp = '2026-01-01T00:04:00.000Z', message = { role = 'user', content = 'nested middle original continuation' } }),
}, nested_middle)
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), parentSession = nested_root }),
  vim.json.encode({ type = 'message', id = 'nested-root-u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'nested root prompt' } }),
  vim.json.encode({ type = 'message', id = 'nested-root-a1', parentId = 'nested-root-u1', timestamp = '2026-01-01T00:01:00.000Z', message = { role = 'assistant', content = 'nested root answer' } }),
  vim.json.encode({ type = 'message', id = 'nested-middle-u1', parentId = 'nested-root-a1', timestamp = '2026-01-01T00:02:00.000Z', message = { role = 'user', content = 'nested middle branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'nested-middle-a1', parentId = 'nested-middle-u1', timestamp = '2026-01-01T00:03:00.000Z', message = { role = 'assistant', content = 'nested middle answer' } }),
  vim.json.encode({ type = 'message', id = 'nested-leaf-u1', parentId = 'nested-middle-a1', timestamp = '2026-01-01T00:05:00.000Z', message = { role = 'user', content = 'nested leaf latest branch prompt' } }),
  vim.json.encode({ type = 'message', id = 'nested-leaf-a1', parentId = 'nested-leaf-u1', timestamp = '2026-01-01T00:06:00.000Z', message = { role = 'assistant', content = 'nested leaf answer' } }),
}, nested_leaf)
sessions.render_current('Pi.dev session', nested_leaf)
assert(vim.wait(1000, function()
  return (vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''):find('# Pi.dev session: nested leaf latest branch prompt', 1, true) ~= nil
end), output_text())
assert_branch_title('nested leaf latest branch prompt')

local long_branch_file = vim.fn.tempname()
local long_prompt = 'latest user is ' .. string.rep('very long title segment ', 20)
vim.fn.writefile({
  vim.json.encode({ type = 'session', cwd = vim.uv.cwd(), parentSession = root_file }),
  vim.json.encode({ type = 'message', id = 'u1', timestamp = '2026-01-01T00:00:00.000Z', message = { role = 'user', content = 'first root prompt should stay in header' } }),
  vim.json.encode({ type = 'message', id = 'u-first', parentId = 'u1', timestamp = '2026-01-01T00:04:00.000Z', message = { role = 'user', content = 'branch starts here' } }),
  vim.json.encode({ type = 'message', id = 'u-long', parentId = 'u-first', timestamp = '2026-01-01T00:05:00.000Z', message = { role = 'user', content = long_prompt } }),
}, long_branch_file)
sessions.render_current('Pi.dev session', long_branch_file)
assert(vim.wait(1000, function()
  return (vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, 1, false)[1] or ''):find('# Pi.dev session: branch starts here', 1, true) ~= nil
end), output_text())
assert_latest_in_title('latest user is')
local title = winbar_title()
assert(title:find('Pi chat: branch starts', 1, true), title)
assert(title:find('latest user is ' .. string.rep('very long title segment ', 10), 1, true) == nil, title)
assert(output_text():find('> Last user:', 1, true) == nil, output_text())
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
