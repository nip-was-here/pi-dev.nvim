#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
require('pi-dev').setup({ keymaps = { enable = false }, ui = { width = 80, input_height = 10, render = { fold_tool_output_over = 8 } } })

local ui = require('pi-dev.ui')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local fence = string.rep('`', 3)

ui.show()
renderer.render_messages({
  { role = 'user', content = 'restored user prompt' },
  { role = 'assistant', content = { { type = 'thinking', thinking = 'restored thinking\n\nrestored thought 2\n\n\n' }, { type = 'text', text = 'restored assistant answer' } } },
}, 'Pi.dev session: test')
renderer.append_user('live user prompt')
renderer.handle_event({ type = 'message_start', message = { role = 'user', content = '' } })
renderer.handle_event({ type = 'message_start', message = { role = 'user', content = 'live user prompt' } })
local initial_lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local text = table.concat(initial_lines, '\n')
assert(text:find('## User\n\nrestored user prompt') ~= nil, text)
assert(text:find('## Assistant') ~= nil, text)
assert(text:find('> Thinking\n\n> restored thinking', 1, true), text)
assert(text:find('> restored thinking\n> restored thought 2\n\nrestored assistant answer', 1, true), text)
assert(text:find('> restored thought 2\nrestored assistant answer', 1, true) == nil, text)
assert(text:find('\n> \n', 1, true) == nil, text)
assert(text:find('\n>\n', 1, true) == nil, text)
assert(text:find('restored assistant answer', 1, true), text)
local restored_thinking_header
local restored_thinking_body
local restored_thinking_last_body
for index, line in ipairs(initial_lines) do
  if line == '> Thinking' and not restored_thinking_header then
    restored_thinking_header = index
  elseif line == '> restored thinking' and not restored_thinking_body then
    restored_thinking_body = index
  elseif line == '> restored thought 2' then
    restored_thinking_last_body = index
  end
end
assert(restored_thinking_header and restored_thinking_body and restored_thinking_last_body, text)
vim.api.nvim_win_call(state.ui.output_win, function()
  assert(vim.fn.foldclosed(restored_thinking_header) == -1, 'restored thinking header must stay visible')
  assert(vim.fn.foldlevel(restored_thinking_header + 1) > 0, 'restored thinking detail should remain a fold block')
  assert(vim.fn.foldclosed(restored_thinking_header + 1) == -1, 'restored thinking detail at/below 8 lines should stay open')
  assert(restored_thinking_last_body == restored_thinking_body + 1, 'empty thinking quote lines should be removed')
  for line = restored_thinking_header + 1, restored_thinking_last_body do
    assert(vim.fn.foldclosed(line) == -1, 'short restored thinking detail lines should stay open: line ' .. line)
  end
  assert(vim.fn.foldclosed(restored_thinking_last_body + 1) == -1, 'separator after restored thinking body must remain visible')
end)
assert(text:find('type = "thinking"', 1, true) == nil, text)

renderer.render_messages({
  { role = 'thinking', content = 'role thinking one\nrole thinking two' },
  { role = 'assistant', thinking = 'top-level thought one\ntop-level thought two', content = 'answer after top-level thought' },
}, 'Pi.dev restored thinking shapes')
local shape_lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
text = table.concat(shape_lines, '\n')
assert(text:find('## Thinking', 1, true) == nil, text)
assert(text:find('> Thinking\n\n> role thinking one\n> role thinking two', 1, true), text)
assert(text:find('> Thinking\n\n> top-level thought one\n> top-level thought two\n\nanswer after top-level thought', 1, true), text)
local shape_thinking_headers = {}
for index, line in ipairs(shape_lines) do
  if line == '> Thinking' then
    table.insert(shape_thinking_headers, index)
  end
end
assert(#shape_thinking_headers == 2, text)
vim.api.nvim_win_call(state.ui.output_win, function()
  for _, header in ipairs(shape_thinking_headers) do
    assert(vim.fn.foldclosed(header) == -1, 'restored thinking shape header must stay visible')
    assert(vim.fn.foldlevel(header + 1) > 0, 'restored thinking shape details should remain a fold block')
    assert(vim.fn.foldclosed(header + 1) == -1, 'short restored thinking shape details should stay open')
    assert(vim.fn.foldclosed(header + 2) == -1, 'short restored thinking shape body should stay open')
    assert(vim.fn.foldclosed(header + 3) == -1, 'short restored thinking shape full body should stay open')
  end
end)

renderer.render_messages({
  { role = 'user', content = 'restored user prompt' },
}, 'Pi.dev session: test')
renderer.append_user('live user prompt')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('## User[^\n]*%([^%)]+%)\n\nlive user prompt') ~= nil, text)
local _, user_heading_count = text:gsub('## User', '')
assert(user_heading_count == 2, text)
assert(text:find('%*%*User%*%*') == nil, text)
assert(text:find('\n%-%-%-\n') == nil, text)
renderer.append_system('status notice')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('## System', 1, true) == nil, text)
assert(text:find('> status notice', 1, true), text)

pcall(vim.api.nvim_win_set_width, state.ui.output_win, 42)
vim.wo[state.ui.output_win].number = true
vim.wo[state.ui.output_win].numberwidth = 4
renderer.render_messages({
  { role = 'user', content = 'timestamped prompt', __pi_timestamp = '2026-01-01T00:00:01.000Z' },
  { role = 'assistant', content = 'timestamped answer', __pi_timestamp = '2026-01-01T00:00:02.000Z' },
  { role = 'toolResult', toolName = 'very-long-tool-name-that-must-be-truncated-before-time', content = 'tool output', __pi_timestamp = '2026-01-01T00:00:03.000Z' },
}, 'Pi.dev timestamp header test')
local timestamp_lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local user_header
local assistant_header
local tool_header
for _, line in ipairs(timestamp_lines) do
  if line:find('## User', 1, true) then
    user_header = line
  elseif line:find('## Assistant', 1, true) then
    assistant_header = line
  elseif line:find('### Tool', 1, true) then
    tool_header = line
  end
end
assert(user_header and user_header:find('%([^()]+%)$'), table.concat(timestamp_lines, '\n'))
assert(assistant_header and assistant_header:find('%([^()]+%)$'), table.concat(timestamp_lines, '\n'))
assert(tool_header and tool_header:find('%([^()]+%)$'), table.concat(timestamp_lines, '\n'))
assert(tool_header:find('### Tool result', 1, true), tool_header)
assert(tool_header:find('...', 1, true), tool_header)
assert(user_header:find('%s%s%('), user_header)
assert(assistant_header:find('%s%s%('), assistant_header)
assert(tool_header:find('%s%('), tool_header)
local header_width = require('pi-dev.format').window_text_width(state.ui.output_win)
assert(vim.fn.strdisplaywidth(user_header) <= header_width, user_header)
assert(vim.fn.strdisplaywidth(assistant_header) <= header_width, assistant_header)
assert(vim.fn.strdisplaywidth(tool_header) <= header_width, tool_header)
assert(vim.fn.strdisplaywidth(user_header) == vim.fn.strdisplaywidth(assistant_header), user_header .. '\n' .. assistant_header)
assert(header_width - vim.fn.strdisplaywidth(user_header) <= 4, user_header)
assert(header_width - vim.fn.strdisplaywidth(assistant_header) <= 4, assistant_header)
assert(header_width - vim.fn.strdisplaywidth(tool_header) <= 6, tool_header)
pcall(vim.api.nvim_win_set_width, state.ui.output_win, 80)
vim.wo[state.ui.output_win].number = false

renderer.clear('Pi.dev live user spacing test')
renderer.append_user('live user spacing prompt')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'spacing answer' } })
renderer.flush_live_render()
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('## User[^\n]*%([^%)]+%)\n\nlive user spacing prompt\n\n## Assistant[^\n]*%([^%)]+%)\n\nspacing answer'), text)
assert(text:find('live user spacing prompt\n\n\n## Assistant', 1, true) == nil, text)
assert(text:find('## Assistant[^\n]*%([^%)]+%)\nspacing answer') == nil, text)

renderer.render_messages({
  { role = 'user', content = 'prompt before silent assistant' },
  { role = 'assistant', content = '' },
}, 'Pi.dev silent assistant test')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('prompt before silent assistant', 1, true), text)
assert(text:find('## Assistant', 1, true) == nil, text)
renderer.clear('Pi.dev live silent assistant test')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = '\n\n' } })
renderer.flush_live_render()
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('## Assistant', 1, true) == nil, text)
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'live answer\n\n\n\n' } })
renderer.flush_live_render()
local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
text = table.concat(lines, '\n')
assert(text:find('## Assistant[^\n]*%([^%)]+%)\n\nlive answer'), text)
assert(text:find('## Assistant[^\n]*%([^%)]+%)\nlive answer') == nil, text)
assert(lines[#lines] == '', vim.inspect(lines))
assert(lines[#lines - 1] == 'live answer', vim.inspect(lines))
renderer.clear('Pi.dev coalesced leading blank test')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = '\n\n' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'coalesced answer' } })
renderer.flush_live_render()
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('## Assistant[^\n]*%([^%)]+%)\n\ncoalesced answer'), text)
assert(text:find('## Assistant[^\n]*%([^%)]+%)\n\n\ncoalesced answer') == nil, text)

renderer.render_messages({
  { role = 'assistant', content = '# Model heading\n\n## Model subheading\n\n````lua\n# code heading stays literal\n```\ninner shorter fence\n```\n````\n\n# Outside after fence' },
}, 'Pi.dev assistant markdown demotion test')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('###### Model heading', 1, true), text)
assert(text:find('###### Model subheading', 1, true), text)
assert(text:find('````lua\n# code heading stays literal\n```\ninner shorter fence\n```\n````\n\n###### Outside after fence', 1, true), text)
assert(text:find('\n# Model heading', 1, true) == nil, text)
renderer.clear('Pi.dev live assistant markdown demotion test')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = '# Live model heading\nbody\n\n````\n# live code heading stays literal\n```\ninner\n```\n````\n# Live outside' } })
renderer.flush_live_render()
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('###### Live model heading\nbody', 1, true), text)
assert(text:find('````\n# live code heading stays literal\n```\ninner\n```\n````\n###### Live outside', 1, true), text)
assert(text:find('\n# Live model heading', 1, true) == nil, text)
renderer.clear('Pi.dev live split markdown demotion test')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = '#' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = ' Split live model heading\nbody' } })
renderer.flush_live_render()
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('###### Split live model heading\nbody', 1, true), text)
assert(text:find('\n# Split live model heading', 1, true) == nil, text)

renderer.clear('Pi.dev live thinking whitespace test')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = '> **Testing fold functionality**' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = '\nI' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = ' need' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = ' to ensure spaces stay intact.\n\n\n' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'answer after whitespace thinking' } })
renderer.flush_live_render()
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('> **Testing fold functionality**\n> I need to ensure spaces stay intact.\n\nanswer after whitespace thinking', 1, true), text)
assert(text:find('Ineedtoensure', 1, true) == nil, text)
assert(text:find('> \n> \n\nanswer after whitespace thinking', 1, true) == nil, text)

renderer.clear('Pi.dev live thinking blockquote test')
renderer.handle_event({ type = 'message_start', message = { role = 'assistant' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'thinking_delta', delta = 'first thought' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'reasoning_delta', delta = '\n> > Reasoning\n> > second thought\n\n```\n# hidden code heading\n```\nlast thought' } })
renderer.handle_event({ type = 'message_update', assistantMessageEvent = { type = 'text_delta', delta = 'final answer' } })
renderer.flush_live_render()
local thinking_lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
text = table.concat(thinking_lines, '\n')
assert(text:find('> Thinking\n\n> first thought\n> second thought\n> ```\n> # hidden code heading\n> ```\n> last thought', 1, true), text)
assert(text:find('\n> \n', 1, true) == nil, text)
assert(text:find('\n>\n', 1, true) == nil, text)
assert(text:find('> > Thinking', 1, true) == nil, text)
assert(text:find('> > Reasoning', 1, true) == nil, text)
assert(text:find('> Thinking\n> Thinking', 1, true) == nil, text)
assert(text:find('> Reasoning', 1, true) == nil, text)
assert(text:find('> last thought\n\nfinal answer', 1, true), text)
assert(text:find('> last thought\nfinal answer', 1, true) == nil, text)
assert(text:find('> final answer', 1, true) == nil, text)
local thinking_header_line
local thinking_body_line
local thinking_last_body_line
for index, line in ipairs(thinking_lines) do
  if line == '> Thinking' and not thinking_header_line then
    thinking_header_line = index
  elseif line == '> first thought' and not thinking_body_line then
    thinking_body_line = index
  elseif line == '> last thought' then
    thinking_last_body_line = index
  end
end
assert(thinking_header_line and thinking_body_line and thinking_last_body_line, text)
vim.api.nvim_win_call(state.ui.output_win, function()
  assert(vim.fn.foldclosed(thinking_header_line) == -1, 'thinking header must stay visible')
  assert(vim.fn.foldlevel(thinking_header_line + 1) > 0, 'thinking detail should remain a fold block')
  assert(vim.fn.foldclosed(thinking_header_line + 1) == -1, 'blank line under thinking header should stay open at 8 lines')
  for line = thinking_header_line + 1, thinking_last_body_line do
    assert(vim.fn.foldclosed(line) == -1, 'live thinking detail at/below 8 lines should stay open: line ' .. line)
  end
  assert(vim.fn.foldclosed(thinking_last_body_line + 1) == -1, 'separator after thinking body must remain visible')
end)

renderer.clear('Pi.dev diff test')
renderer.handle_event({
  type = 'message_update',
  assistantMessageEvent = { type = 'toolcall_start', toolCall = { name = 'tool' } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('Tool call:', 1, true) == nil, text)
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'edit-1',
  toolName = 'edit',
  args = { path = 'file.txt', edits = { { oldText = 'old line', newText = 'new line' } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('### Tool: edit file.txt', 1, true), text)
assert(text:find('##### Input', 1, true) == nil, text)
assert(text:find('#### Output', 1, true) == nil, text)
assert(text:find(fence .. 'diff', 1, true), text)
assert(text:find('-old line', 1, true), text)
assert(text:find('+new line', 1, true), text)
assert(text:find(fence .. 'json', 1, true) == nil, text)
assert(text:find('<!--', 1, true) == nil, text)
local diff_ns = vim.api.nvim_get_namespaces().pi_dev_diff_blocks
assert(diff_ns ~= nil, 'diff highlight namespace missing')
assert(#vim.api.nvim_buf_get_extmarks(state.ui.output_buf, diff_ns, 0, -1, { details = true }) > 0, 'diff lines should receive highlights')

renderer.clear('Pi.dev read/write test')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'write-1',
  toolName = 'write',
  args = { path = 'new.txt', content = 'hello write\n# heading in write input\n```\ninner write fence\n```\nlast write line' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'write-1',
  toolName = 'write',
  result = { content = { { type = 'text', text = '{"path":"new.txt","bytes":11}' } } },
})
local read_payload = vim.json.encode({ path = 'new.md', content = '# heading\n```\ninner\n```\nnext\n' })
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'read-1',
  toolName = 'read',
  args = { path = 'new.md' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'read-1',
  toolName = 'read',
  result = { content = { { type = 'text', text = read_payload } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('### Tool: write new.txt', 1, true), text)
assert(text:find('hello write', 1, true), text)
assert(text:find('hello write\n# heading in write input\n```\ninner write fence\n```\nlast write line', 1, true), text)
assert(text:find('hello write\n\n# heading in write input', 1, true) == nil, text)
assert(text:find('_Successfully wrote new.txt. 11 bytes._', 1, true), text)
assert(text:find('### Tool: read new.md', 1, true), text)
assert(text:find('**Read:**', 1, true) == nil, text)
assert(text:find('#### Output', 1, true) == nil, text)
assert(text:find('````text', 1, true), text)
assert(text:find('# heading', 1, true), text)
assert(text:find('# heading\n```\ninner\n```\nnext', 1, true), text)
assert(text:find('# heading\n\n```', 1, true) == nil, text)
assert(text:find('inner', 1, true), text)
assert(text:find('\nnext\n````\n\n', 1, true) == nil, text)
assert(text:find('{"path"', 1, true) == nil, text)
local _, write_heading_count = text:gsub('### Tool: write', '')
assert(write_heading_count == 1, text)

renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'diff-1',
  result = { content = { { type = 'text', text = 'diff --git a/a b/a\n@@ -1 +1 @@\n-old\n+new' } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find(fence .. 'diff', 1, true), text)
assert(text:find('diff --git a/a b/a', 1, true), text)

renderer.clear('Pi.dev CRLF script output test')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'bash-crlf-1',
  toolName = 'bash',
  result = { content = { { type = 'text', text = 'line one\r\n\27[31mline two\27[0m\rprogress\r\n' } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('line one', 1, true), text)
assert(text:find('line two', 1, true), text)
assert(text:find('progress', 1, true), text)
assert(text:find(fence .. 'bash\nline one', 1, true), text)
assert(text:find('\nprogress\n' .. fence, 1, true), text)
assert(text:find('\r', 1, true) == nil, text)
assert(text:find('\27', 1, true) == nil, text)

renderer.clear('Pi.dev bash stdio output test')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'bash-stdio-1',
  toolName = 'bash',
  result = { stdout = 'stdout line\n', stderr = 'stderr line\n' },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('**stdout:**\n' .. fence .. 'bash\nstdout line\n' .. fence, 1, true), text)
assert(text:find('**stderr:**\n' .. fence .. 'bash\nstderr line\n' .. fence, 1, true), text)

renderer.clear('Pi.dev pretty JSON tool response test')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'json-input-1',
  toolName = 'mcp_tool',
  args = { z = 2, a = { b = { true, vim.NIL, 'x' } } },
})
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'json-input-2',
  toolName = 'mcp_tool',
  args = '[{"id":1},{}]',
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'empty-input-output-1',
  toolName = 'mcp_tool',
  args = {},
  result = { content = { { type = 'text', text = '' } } },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'json-response-1',
  toolName = 'mcp_tool',
  result = { content = { { type = 'text', text = '{"z":2,"a":{"b":[true,null,"x"]}}' } } },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'json-response-2',
  toolName = 'bash',
  result = { stdout = '{"status":"ok","items":[1,2]}\n' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'json-response-3',
  toolName = 'read',
  result = { content = { { type = 'text', text = vim.json.encode({ path = 'data.json', content = '{"one":1,"two":[2,3]}' }) } } },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'json-response-4',
  toolName = 'mcp_tool',
  result = { content = { { type = 'text', text = '[{},[]]' } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find(fence .. 'json\n{\n  "a": {\n    "b": [\n      true,\n      null,\n      "x"\n    ]\n  },\n  "z": 2\n}\n' .. fence, 1, true), text)
assert(text:find(fence .. 'json\n[\n  {\n    "id": 1\n  },\n  {}\n]\n' .. fence, 1, true), text)
assert(text:find('Input: `empty`', 1, true), text)
assert(text:find('Output: `empty`', 1, true), text)
assert(text:find(fence .. 'json\n{}\n' .. fence, 1, true) == nil, text)
assert(text:find(fence .. 'json\n[]\n' .. fence, 1, true) == nil, text)
assert(text:find('**stdout:**\n' .. fence .. 'json\n{\n  "items": [\n    1,\n    2\n  ],\n  "status": "ok"\n}\n' .. fence, 1, true), text)
assert(text:find(fence .. 'json\n{\n  "one": 1,\n  "two": [\n    2,\n    3\n  ]\n}\n' .. fence, 1, true), text)
assert(text:find(fence .. 'json\n[\n  {},\n  []\n]\n' .. fence, 1, true), text)
assert(text:find('{"z":2', 1, true) == nil, text)
assert(text:find('{"status":"ok"', 1, true) == nil, text)

renderer.clear('Pi.dev edit fenced markdown test')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'edit-fenced-markdown',
  toolName = 'edit',
  args = { path = 'fenced.md', edits = { { oldText = '# old heading\n```\nold inner\n```', newText = '# new heading\n```\nnew inner\n```' } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('-# old heading\n-```\n-old inner\n-```\n+# new heading\n+```\n+new inner\n+```', 1, true), text)
assert(text:find('-# old heading\n\n-```', 1, true) == nil, text)

renderer.clear('Pi.dev diff highlight test')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'diff-highlight',
  toolName = 'edit',
  result = { content = { { type = 'text', text = 'diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,3 +1,3 @@\n neighbor before\n-old\n+new\n neighbor after' } } },
})
local rendered = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
local line_hl = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.ui.output_buf, -1, 0, -1, { details = true })) do
  local row = mark[2] + 1
  line_hl[rendered[row]] = mark[4].line_hl_group
end
assert(line_hl['-old'] == 'DiffDelete', vim.inspect(line_hl))
assert(line_hl['+new'] == 'DiffAdd', vim.inspect(line_hl))
assert(line_hl['--- a/a'] == nil, vim.inspect(line_hl))
assert(line_hl['+++ b/a'] == nil, vim.inspect(line_hl))
assert(line_hl['@@ -1,3 +1,3 @@'] == nil, vim.inspect(line_hl))
assert(line_hl[' neighbor before'] == nil, vim.inspect(line_hl))
assert(line_hl[' neighbor after'] == nil, vim.inspect(line_hl))

renderer.clear('Pi.dev subagent result test')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-list',
  toolName = 'subagent',
  args = { action = 'list' },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('### Tool: subagent list', 1, true), text)
assert(text:find('#### Request', 1, true), text)
assert(text:find('**Action:** list', 1, true), text)
assert(text:find('```json', 1, true) == nil, text)
assert(text:find('{"action"', 1, true) == nil, text)
local function line_number(pattern)
  local lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
  for index, line in ipairs(lines) do
    if line:find(pattern, 1, true) then
      return index
    end
  end
end
local request_line = line_number('#### Request')
assert(request_line, text)
local subagent_header = line_number('### Tool: subagent list')
local request_fold
local request_fold_level
local header_gap_fold
local header_gap_level
vim.api.nvim_win_call(state.ui.output_win, function()
  request_fold = vim.fn.foldclosed(request_line)
  request_fold_level = vim.fn.foldlevel(request_line)
  header_gap_fold = vim.fn.foldclosed(subagent_header + 1)
  header_gap_level = vim.fn.foldlevel(subagent_header + 1)
end)
assert(request_fold == -1 and request_fold_level > 0, 'small subagent request should be an open fold block')
assert(header_gap_fold == -1 and header_gap_level > 0, 'subagent fold should start immediately below the tool header but stay open below threshold')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'subagent-review',
  toolName = 'subagent',
  args = { agent = 'reviewer', context = 'fresh', timeoutMs = 120000, task = 'Review publication readiness.' },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('### Tool: subagent reviewer', 1, true), text)
assert(text:find('**Agent:** reviewer', 1, true), text)
assert(text:find('**Context:** fresh', 1, true), text)
assert(text:find('**Timeout:** 120000 ms', 1, true), text)
assert(text:find('**Task:**\nReview publication readiness.', 1, true), text)
assert(text:find('{"context"', 1, true) == nil, text)
request_line = line_number('#### Request')
subagent_header = line_number('### Tool: subagent reviewer')
vim.api.nvim_win_call(state.ui.output_win, function()
  request_fold = vim.fn.foldclosed(request_line)
  request_fold_level = vim.fn.foldlevel(request_line)
  header_gap_fold = vim.fn.foldclosed(subagent_header + 1)
  header_gap_level = vim.fn.foldlevel(subagent_header + 1)
end)
assert(request_fold ~= -1 or request_fold_level > 0, 'subagent reviewer request should be inside a fold block')
if request_fold ~= -1 then
  assert(header_gap_fold == subagent_header + 1, 'subagent reviewer auto-fold should start immediately below the tool header without a visible blank gap')
else
  assert(header_gap_level > 0, 'subagent reviewer open fold should start immediately below the tool header')
end
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'subagent-1',
  toolName = 'subagent',
  result = { content = { { type = 'text', text = vim.json.encode({ results = { { agent = 'reviewer', status = 'completed', response = '# Review heading\nLooks good\n```markdown\n# code heading stays literal\n```\n## One note.', thinking = 'Checked release risks.', toolCalls = { { name = 'bash', args = { command = './tests/run.sh' }, result = 'passed' } } }, { agent = 'worker', output = '# Worker heading\nImplemented fix', messages = { { role = 'assistant', thinking = 'Need a small patch.', text = '# Activity heading\nUsed edit.' }, { type = 'tool_execution_start', toolName = 'edit', args = { path = 'lua/pi-dev/renderer.lua' } } } } } }) } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('#### Result', 1, true), text)
assert(text:find('##### Agent 1/2: reviewer - completed', 1, true), text)
assert(text:find('##### Agent 2/2: worker', 1, true), text)
assert(text:find('###### Main info', 1, true), text)
assert(text:find('###### Result', 1, true) == nil, text)
assert(text:find('Details are lazy-rendered', 1, true) == nil, text)
assert(text:find('###### Details', 1, true) == nil, text)
assert(text:find('#######', 1, true) == nil, text)
assert(text:find('Review heading', 1, true) == nil, text)
assert(text:find('Worker heading', 1, true) == nil, text)
assert(text:find('One note.', 1, true) == nil, text)
assert(text:find('####### Thinking', 1, true) == nil, text)
assert(text:find('####### Tool calls', 1, true) == nil, text)
assert(text:find('####### Activity', 1, true) == nil, text)
assert(text:find('"results"', 1, true) == nil, text)
assert(text:find('{"agent"', 1, true) == nil, text)

renderer.clear('Pi.dev subagent final result variants')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'subagent-final-variants',
  toolName = 'subagent',
  result = { results = { { agent = 'reviewer', final_result = 'variant final text' } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('variant final text', 1, true) == nil, text)
assert(text:find('###### Main info', 1, true), text)
assert(text:find('###### Result', 1, true) == nil, text)
assert(text:find('###### Details', 1, true) == nil, text)

renderer.clear('Pi.dev tool fold test')
local long_output = table.concat(vim.tbl_map(function(i) return 'tool line ' .. i end, vim.fn.range(1, 40)), '\n')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'long-1',
  toolName = 'bash',
  args = { command = 'printf long' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'long-1',
  toolName = 'bash',
  result = { content = { { type = 'text', text = long_output } } },
})
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('### Tool: bash printf long', 1, true), text)
local function output_foldclosed(line)
  local value
  vim.api.nvim_win_call(state.ui.output_win, function()
    value = vim.fn.foldclosed(line)
  end)
  return value
end
local long_tool_header = line_number('### Tool: bash printf long')
local long_tool_fold_line = long_tool_header + 1
assert(output_foldclosed(long_tool_header) == -1, 'tool heading must not be inside the fold')
assert(output_foldclosed(long_tool_fold_line) ~= -1, 'blank line under long tool header should be folded with details')
assert(vim.wait(1000, function()
  return vim.api.nvim_win_get_cursor(state.ui.output_win)[1] == long_tool_fold_line
end), 'auto-scroll after folding should land on the closed fold header, not hidden folded body lines')
vim.api.nvim_win_call(state.ui.output_win, function()
  local fold_text = vim.fn.foldtextresult(long_tool_fold_line)
  assert(fold_text:find('details %- %d+ lines'), fold_text)
  assert(fold_text:find('Finished', 1, true) == nil, fold_text)
end)
vim.api.nvim_win_call(state.ui.output_win, function()
  vim.api.nvim_win_set_cursor(state.ui.output_win, { long_tool_fold_line, 0 })
  vim.cmd('silent! normal! zo')
end)
assert(output_foldclosed(long_tool_fold_line) == -1, 'tool fold should open')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'long-1',
  toolName = 'bash',
  result = { content = { { type = 'text', text = long_output .. '\nopen preserved' } } },
})
renderer.flush_pending_tool_renders()
assert(output_foldclosed(long_tool_fold_line) == -1, 'open tool fold should stay open after update')
vim.api.nvim_win_call(state.ui.output_win, function()
  vim.api.nvim_win_set_cursor(state.ui.output_win, { long_tool_fold_line, 0 })
  vim.cmd('silent! normal! zc')
end)
assert(output_foldclosed(long_tool_fold_line) ~= -1, 'tool fold should close')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'long-1',
  toolName = 'bash',
  result = { content = { { type = 'text', text = long_output .. '\nclosed preserved' } } },
})
renderer.flush_pending_tool_renders()
assert(output_foldclosed(long_tool_fold_line) ~= -1, 'closed tool fold should stay closed after update')
vim.api.nvim_set_current_win(state.ui.output_win)
vim.api.nvim_win_set_cursor(state.ui.output_win, { long_tool_header, 0 })
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'long-1',
  toolName = 'bash',
  result = { content = { { type = 'text', text = long_output .. '\nview preserved' } } },
})
renderer.flush_pending_tool_renders()
assert(vim.api.nvim_get_current_win() == state.ui.output_win, 'tool fold updates must not steal focus from output')
local cursor = vim.api.nvim_win_get_cursor(state.ui.output_win)
assert(cursor[1] == long_tool_header, 'tool fold updates must preserve output cursor/view while user is reading')

renderer.append_permission_request('fold-boundary-perm', 'bash `git status`', { 'Permission Required', 'Allow it?' })
local permission_header = line_number('#### Permission request: bash `git status`')
assert(output_foldclosed(permission_header) == -1, 'live permission header must not be inside the preceding tool fold')
assert(output_foldclosed(permission_header - 1) == -1, 'separator before permission header must not be inside the preceding tool fold')
renderer.finish_permission_request('fold-boundary-perm', 'Yes')
assert(output_foldclosed(permission_header) == -1, 'answered permission header must stay outside fold')
assert(output_foldclosed(permission_header + 1) ~= -1, 'answered permission details should fold below header')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'after-permission',
  toolName = 'bash',
  args = { command = 'echo after' },
})
local after_permission_tool_header = line_number('### Tool: bash echo after')
assert(output_foldclosed(after_permission_tool_header) == -1, 'tool header after permission must not be inside permission fold')
assert(output_foldclosed(after_permission_tool_header - 1) == -1, 'separator before next tool header must not be inside permission fold')

renderer.clear('Pi.dev running bash permission boundary test')
local running_output = table.concat(vim.tbl_map(function(i) return 'running line ' .. i end, vim.fn.range(1, 30)), '\n')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'running-bash',
  toolName = 'bash',
  args = { command = 'printf running' },
})
renderer.handle_event({
  type = 'tool_execution_update',
  toolCallId = 'running-bash',
  toolName = 'bash',
  partialResult = { content = { { type = 'text', text = running_output } } },
})
renderer.flush_pending_tool_renders()
local running_tool_header = line_number('### Tool: bash printf running')
assert(output_foldclosed(running_tool_header + 1) == -1, 'running bash details must stay open while tool is still running')
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'running-bash',
  toolName = 'bash',
  result = { content = { { type = 'text', text = running_output } } },
})
assert(output_foldclosed(running_tool_header + 1) ~= -1, 'finished bash details should auto-fold when over threshold')
renderer.append_permission_request('running-boundary-perm', 'bash `pwd`', { 'Permission Required', 'Allow it?' })
local running_permission_header = line_number('#### Permission request: bash `pwd`')
assert(output_foldclosed(running_permission_header) == -1, 'permission header after running bash must stay visible')
assert(output_foldclosed(running_permission_header - 1) == -1, 'separator before permission after running bash must stay outside fold')

renderer.clear('Pi.dev read/write fold test')
local long_file = table.concat(vim.tbl_map(function(i) return 'file line ' .. i end, vim.fn.range(1, 100)), '\n')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'read-long',
  toolName = 'read',
  args = { path = 'long.txt' },
})
renderer.handle_event({
  type = 'tool_execution_end',
  toolCallId = 'read-long',
  toolName = 'read',
  result = { content = { { type = 'text', text = vim.json.encode({ path = 'long.txt', content = long_file }) } } },
})
vim.wait(100)
local read_tool_header = line_number('### Tool: read long.txt')
assert(output_foldclosed(read_tool_header) == -1, 'read tool heading must stay visible')
assert(output_foldclosed(read_tool_header + 1) ~= -1, 'read output blank/detail lines should stay folded after auto-scroll')

renderer.render_messages({
  { role = 'assistant', content = { { type = 'text', text = 'restored read before tool' }, { type = 'toolCall', id = 'restored-read-call', name = 'read', arguments = { path = 'restored.txt' } } } },
  { role = 'toolResult', toolCallId = 'restored-read-call', toolName = 'read', content = vim.json.encode({ path = 'restored.txt', content = table.concat({ 'restored line 1', '# heading inside file', '```', 'inner fence text', '```', 'restored line 6', 'restored line 7', 'restored line 8', 'restored line 9' }, '\n') }) },
}, 'Pi.dev restored read fold test')
text = table.concat(vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false), '\n')
assert(text:find('restored line 1\n# heading inside file\n```\ninner fence text\n```\nrestored line 6', 1, true), text)
assert(text:find('restored line 1\n\n# heading inside file', 1, true) == nil, text)
local restored_read_header = line_number('### Tool: read restored.txt')
local restored_read_closing_fence
local restored_read_lines = vim.api.nvim_buf_get_lines(state.ui.output_buf, 0, -1, false)
for index = restored_read_header + 1, #restored_read_lines do
  if restored_read_lines[index] == '````' then
    restored_read_closing_fence = index
  end
end
assert(restored_read_closing_fence, text)
assert(output_foldclosed(restored_read_header) == -1, 'restored read header must stay visible')
for line = restored_read_header + 1, restored_read_closing_fence do
  assert(output_foldclosed(line) ~= -1, 'entire restored read fenced output should be folded: line ' .. line)
end

renderer.clear('Pi.dev write fold test')
renderer.handle_event({
  type = 'tool_execution_start',
  toolCallId = 'write-long',
  toolName = 'write',
  args = { path = 'long.txt', content = long_file },
})
vim.wait(100)
local write_tool_header = line_number('### Tool: write long.txt')
assert(output_foldclosed(write_tool_header) == -1, 'write tool heading must stay visible')
assert(output_foldclosed(write_tool_header + 1) ~= -1, 'write input blank/detail lines should stay folded after auto-scroll')
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
