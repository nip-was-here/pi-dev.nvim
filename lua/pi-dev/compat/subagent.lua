-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local message_content = require('pi-dev.message_content')
local pipeline = require('pi-dev.render_pipeline')

local M = {}

M.tool_flush_delay_ms = 1000

local normalize_line_endings = pipeline.normalize_line_endings
local fenced_lines = pipeline.fenced_lines

local function inline_code(text)
  text = tostring(text or '')
  if text:find('`', 1, true) then
    return '`` ' .. text .. ' ``'
  end
  return '`' .. text .. '`'
end

local function compact_header_text(text, max_chars)
  text = tostring(text or ''):gsub('%s+', ' ')
  max_chars = max_chars or 120
  if vim.fn.strchars(text) <= max_chars then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(0, max_chars - 3)) .. '...'
end

local function first_string_field(tbl, fields)
  if type(tbl) ~= 'table' then
    return nil
  end
  for _, field in ipairs(fields) do
    local value = tbl[field]
    if type(value) == 'string' and value ~= '' then
      return value
    end
  end
  return nil
end

local function first_present_field(tbl, fields)
  if type(tbl) ~= 'table' then
    return nil
  end
  for _, field in ipairs(fields) do
    local value = tbl[field]
    if value ~= nil and value ~= vim.NIL and value ~= '' then
      return value
    end
  end
  return nil
end

local function demote_heading_line(line, min_level, max_level)
  local indent, hashes, title = tostring(line or ''):match('^(%s*)(#+)%s+(.+)$')
  if not hashes then
    return line
  end
  min_level = tonumber(min_level) or 6
  local level = math.max(#hashes, min_level)
  if max_level then
    level = math.min(level, tonumber(max_level) or level)
  end
  title = title:gsub('%s+#+%s*$', '')
  return indent .. string.rep('#', level) .. ' ' .. title
end

local function markdown_lines(text, opts)
  opts = opts or {}
  local out = {}
  local fence = nil
  for _, line in ipairs(vim.split(normalize_line_endings(text), '\n', { plain = true })) do
    local marker = pipeline.markdown_fence_marker(line)
    if fence then
      table.insert(out, line)
      if pipeline.markdown_fence_closes(marker, fence) then
        fence = nil
      end
    elseif marker then
      fence = marker
      table.insert(out, line)
    else
      table.insert(out, demote_heading_line(line, opts.min_heading_level, opts.max_heading_level))
    end
  end
  return out
end

local function append_wrapped_text(lines, text, opts)
  text = normalize_line_endings(text)
  if text == '' then
    return
  end
  vim.list_extend(lines, markdown_lines(text, opts))
end

local function progress_for(source, item, index)
  if type(item) == 'table' and type(item.progress) == 'table' then
    return item.progress
  end
  local progress = type(source) == 'table' and source.progress or nil
  if type(progress) ~= 'table' then
    return nil
  end
  local agent = type(item) == 'table' and item.agent or nil
  for _, candidate in ipairs(progress) do
    if type(candidate) == 'table' and candidate.index == index - 1 then
      return candidate
    end
  end
  if agent then
    for _, candidate in ipairs(progress) do
      if type(candidate) == 'table' and candidate.agent == agent then
        return candidate
      end
    end
  end
  return nil
end

local function status_for(item, progress)
  if type(item) ~= 'table' then
    return nil
  end
  if item.timedOut then
    return 'timed out'
  end
  if item.detached then
    return 'detached'
  end
  if item.interrupted then
    return 'interrupted'
  end
  local status = item.status or item.state or (type(progress) == 'table' and progress.status or nil)
  if status and status ~= '' then
    return tostring(status)
  end
  local exit_code = tonumber(item.exitCode)
  if exit_code == 0 then
    return 'completed'
  end
  if exit_code then
    return 'failed'
  end
  return nil
end

local function format_duration_ms(ms)
  ms = tonumber(ms)
  if not ms or ms < 0 then
    return nil
  end
  if ms < 1000 then
    return tostring(math.floor(ms)) .. 'ms'
  end
  if ms < 60000 then
    return string.format('%.1fs', ms / 1000):gsub('%.0s$', 's')
  end
  return string.format('%.1fm', ms / 60000):gsub('%.0m$', 'm')
end

local function progress_stats(progress)
  if type(progress) ~= 'table' then
    return nil
  end
  local parts = {}
  if tonumber(progress.turnCount) then
    table.insert(parts, tostring(progress.turnCount) .. ' turns')
  end
  if tonumber(progress.toolCount) then
    table.insert(parts, tostring(progress.toolCount) .. ' tools')
  end
  if tonumber(progress.tokens) then
    table.insert(parts, tostring(progress.tokens) .. ' tok')
  end
  local duration = format_duration_ms(progress.durationMs)
  if duration then
    table.insert(parts, duration)
  end
  return #parts > 0 and table.concat(parts, ', ') or nil
end

local function tool_duration(tool)
  local direct = tool.durationMs or tool.duration_ms or tool.elapsedMs or tool.elapsed_ms or tool.timeMs or tool.time_ms
  local formatted = format_duration_ms(direct)
  if formatted then
    return formatted
  end
  local seconds = tonumber(tool.durationSeconds or tool.duration_seconds or tool.elapsedSeconds or tool.elapsed_seconds)
  if seconds then
    return format_duration_ms(seconds * 1000)
  end
  local duration = tool.duration or tool.elapsed
  if type(duration) == 'string' and duration ~= '' then
    return duration
  end
  if tonumber(duration) then
    return format_duration_ms(tonumber(duration))
  end
  local start_ms = tonumber(tool.startMs or tool.start_ms or tool.startedAtMs or tool.started_at_ms)
  local end_ms = tonumber(tool.endMs or tool.end_ms or tool.finishedAtMs or tool.finished_at_ms or tool.completedAtMs or tool.completed_at_ms)
  if start_ms and end_ms then
    return format_duration_ms(end_ms - start_ms)
  end
  return nil
end

local function recent_tool_line(tool, index)
  if type(tool) ~= 'table' then
    return nil
  end
  local line = tostring(index or '-') .. '. ' .. tostring(tool.tool or tool.name or tool.toolName or 'tool')
  if tool.args and tool.args ~= '' then
    line = line .. ' - ' .. compact_header_text(tool.args, 220)
  end
  local duration = tool_duration(tool)
  if duration then
    line = line .. ' (' .. duration .. ')'
  elseif not tool.endMs and not tool.end_ms and not tool.finishedAt and not tool.finished_at and not tool.completedAt and not tool.completed_at then
    line = line .. ' (running)'
  end
  return line
end

local function append_progress(lines, progress, opts)
  opts = opts or {}
  if type(progress) ~= 'table' then
    return
  end
  local stats = progress_stats(progress)
  if stats then
    table.insert(lines, '**Progress:** ' .. stats)
  end
  if progress.currentTool then
    local current = inline_code(progress.currentTool)
    if progress.currentPath then
      current = current .. ' ' .. inline_code(progress.currentPath)
    elseif progress.currentToolArgs then
      current = current .. ' ' .. compact_header_text(progress.currentToolArgs, 100)
    end
    table.insert(lines, '**Current tool:** ' .. current)
  end
  if opts.include_recent_tools ~= false and type(progress.recentTools) == 'table' and #progress.recentTools > 0 then
    table.insert(lines, '')
    table.insert(lines, '**Tools:**')
    table.insert(lines, '```')
    for index, tool in ipairs(progress.recentTools) do
      local line = recent_tool_line(tool, index)
      if line then
        table.insert(lines, line)
      end
    end
    table.insert(lines, '```')
  end
  if opts.include_recent_output == true and type(progress.recentOutput) == 'table' and #progress.recentOutput > 0 then
    table.insert(lines, '')
    if opts.heading_level then
      table.insert(lines, string.rep('#', opts.heading_level) .. ' Recent output')
    else
      table.insert(lines, '**Recent output:**')
    end
    for _, output_line in ipairs(progress.recentOutput) do
      append_wrapped_text(lines, tostring(output_line), { min_heading_level = opts.heading_level })
    end
  end
  if progress.error and progress.error ~= '' then
    table.insert(lines, '')
    append_wrapped_text(lines, 'Error: ' .. tostring(progress.error))
  end
end

local function result_available(status, opts)
  if opts and opts.lazy_details ~= true then
    return true
  end
  status = tostring(status or ''):lower()
  return status ~= '' and status ~= 'running'
end

local function done_status(status)
  status = tostring(status or ''):lower()
  return status ~= '' and status ~= 'running' and status ~= 'active' and status ~= 'queued'
end

local function buffer_title(label)
  local text = tostring(label or 'subagent'):gsub('^Agent%s+%d+/%d+:%s*', '')
  text = text:gsub('%s+%-%s+.+$', '')
  text = vim.trim(text)
  return text ~= '' and text or 'subagent'
end

local function notice_line(line)
  line = tostring(line or '')
  line = line:gsub('Agent started', 'Subagent started')
  line = line:gsub('Agent start', 'Subagent started')
  line = line:gsub('Agent done', 'Subagent done')
  return line
end

local function append_body(lines, body, opts)
  opts = opts or {}
  local before = #lines
  append_wrapped_text(lines, body, opts)
  for index = before + 1, #lines do
    lines[index] = notice_line(lines[index])
  end
end

local function child_buffer_lines(title, main_info, result_lines, status)
  local lines = { '# Pi chat subagent: ' .. title, '', '> _Subagent started._' }
  if #main_info > 0 then
    table.insert(lines, '')
    vim.list_extend(lines, main_info)
  end
  if #result_lines > 0 then
    table.insert(lines, '')
    table.insert(lines, '## Result')
    vim.list_extend(lines, result_lines)
  end
  if done_status(status) then
    table.insert(lines, '')
    table.insert(lines, '> _Subagent done._')
  end
  return lines
end

local function tool_call_id(item)
  if type(item) ~= 'table' then
    return nil
  end
  local id = item.id or item.toolCallId or item.tool_call_id or item.callId or item.toolUseId or item.tool_use_id
  return id ~= nil and id ~= '' and tostring(id) or nil
end

local function tool_result_id(message)
  if type(message) ~= 'table' then
    return nil
  end
  local id = message.toolCallId or message.tool_call_id or message.callId or message.toolUseId or message.tool_use_id or message.id
  return id ~= nil and id ~= '' and tostring(id) or nil
end

local function is_tool_call_item(item)
  local kind = type(item) == 'table' and item.type or nil
  return kind == 'toolCall' or kind == 'tool_call' or kind == 'tool_use' or kind == 'function_call'
end

local function tool_call_name(item)
  if type(item) ~= 'table' then
    return 'tool'
  end
  local fn = type(item['function']) == 'table' and item['function'] or {}
  return tostring(item.name or item.toolName or item.tool_name or fn.name or 'tool')
end

local function tool_call_args(item)
  if type(item) ~= 'table' then
    return nil
  end
  local fn = type(item['function']) == 'table' and item['function'] or {}
  return item.arguments or item.args or item.input or item.parameters or fn.arguments
end

local function append_value_lines(lines, value, lang)
  if value == nil or value == vim.NIL then
    return
  end
  if type(value) == 'string' then
    local text = normalize_line_endings(value)
    if vim.trim(text) == '' then
      return
    end
    vim.list_extend(lines, fenced_lines(lang or '', text, { trim_final_empty = true }))
    return
  end
  local ok, encoded = pcall(vim.json.encode, value)
  vim.list_extend(lines, fenced_lines('json', ok and encoded or vim.inspect(value), { trim_final_empty = true }))
end

local function message_text(message, opts)
  opts = opts or {}
  if type(message) ~= 'table' then
    return ''
  end
  return message_content.message_render_text(message, opts)
end

local function append_message_block(lines, title, text, opts)
  text = normalize_line_endings(text or '')
  if vim.trim(text) == '' then
    return false
  end
  if #lines > 0 and lines[#lines] ~= '' then
    table.insert(lines, '')
  end
  table.insert(lines, '## ' .. title)
  append_wrapped_text(lines, text, opts or { min_heading_level = 3, max_heading_level = 6 })
  return true
end

local function append_tool_transcript_block(lines, name, args, result_text, status)
  if #lines > 0 and lines[#lines] ~= '' then
    table.insert(lines, '')
  end
  table.insert(lines, '### Tool: ' .. tostring(name or 'tool'))
  if status and status ~= '' then
    table.insert(lines, '_' .. status .. '_')
  end
  if args ~= nil then
    table.insert(lines, '')
    table.insert(lines, '#### Input')
    append_value_lines(lines, args, name == 'bash' and 'bash' or '')
  end
  if result_text and vim.trim(normalize_line_endings(result_text)) ~= '' then
    table.insert(lines, '')
    table.insert(lines, '#### Output')
    append_wrapped_text(lines, result_text, { min_heading_level = 5, max_heading_level = 6 })
  end
end

local function result_text_from_message(message)
  if type(message) ~= 'table' then
    return ''
  end
  local text = message_text(message, { skip_tool_calls = true })
  if vim.trim(text) ~= '' then
    return text
  end
  for _, field in ipairs({ 'output', 'text', 'result', 'response', 'data' }) do
    local value = message[field]
    if type(value) == 'string' and vim.trim(value) ~= '' then
      return value
    elseif type(value) == 'table' then
      local ok, encoded = pcall(vim.json.encode, value)
      return ok and encoded or vim.inspect(value)
    end
  end
  return ''
end

local function transcript_lines_from_progress(progress)
  if type(progress) ~= 'table' then
    return nil
  end
  local lines = {}
  local recent = type(progress.recentTools) == 'table' and progress.recentTools or {}
  for _, tool in ipairs(recent) do
    if type(tool) == 'table' then
      append_tool_transcript_block(lines, tool.tool or tool.name or 'tool', tool.args, nil, 'done')
    end
  end
  if progress.status == 'running' and progress.currentTool then
    append_tool_transcript_block(lines, progress.currentTool, progress.currentToolArgs or progress.currentPath, nil, 'run')
  end
  if type(progress.recentOutput) == 'table' and #progress.recentOutput > 0 then
    append_message_block(lines, 'Assistant', table.concat(progress.recentOutput, '\n'))
  end
  return #lines > 0 and lines or nil
end

local function transcript_lines_from_messages(messages, progress)
  if type(messages) ~= 'table' or #messages == 0 then
    return nil
  end
  local result_by_id = {}
  for _, message in ipairs(messages) do
    if type(message) == 'table' and message.role == 'toolResult' then
      local id = tool_result_id(message)
      if id then
        result_by_id[id] = message
      end
    end
  end

  local lines = {}
  local rendered_results = {}
  for _, message in ipairs(messages) do
    if type(message) == 'table' and message.role == 'user' then
      append_message_block(lines, 'User', message_text(message, { skip_tool_calls = true }))
    elseif type(message) == 'table' and message.role == 'assistant' then
      append_message_block(lines, 'Assistant', message_text(message, { skip_tool_calls = true }))
      if type(message.content) == 'table' then
        for _, item in ipairs(message.content) do
          if is_tool_call_item(item) then
            local id = tool_call_id(item)
            local result_message = id and result_by_id[id] or nil
            if result_message then
              rendered_results[id] = true
            end
            append_tool_transcript_block(lines, tool_call_name(item), tool_call_args(item), result_text_from_message(result_message), result_message and 'done' or 'run')
          end
        end
      end
    elseif type(message) == 'table' and message.role == 'toolResult' then
      local id = tool_result_id(message)
      if not (id and rendered_results[id]) then
        append_tool_transcript_block(lines, 'tool', nil, result_text_from_message(message), 'done')
      end
    elseif type(message) == 'table' then
      local role = tostring(message.role or message.type or 'Message')
      append_message_block(lines, role:sub(1, 1):upper() .. role:sub(2), message_text(message, { skip_tool_calls = true }))
    end
  end

  if type(progress) == 'table' and progress.status == 'running' and progress.currentTool then
    append_tool_transcript_block(lines, progress.currentTool, progress.currentToolArgs or progress.currentPath, nil, 'run')
  end
  if type(progress) == 'table' and progress.status == 'running' and type(progress.recentOutput) == 'table' and #progress.recentOutput > 0 then
    append_message_block(lines, 'Assistant', table.concat(progress.recentOutput, '\n'))
  end

  return #lines > 0 and lines or nil
end

function M.is_tool(tool_name)
  local lower = tostring(tool_name or ''):lower()
  return lower == 'agent' or lower:find('subagent', 1, true) ~= nil or lower:match('[_%-]agent$') ~= nil
end

function M.summary(args)
  if type(args) ~= 'table' then
    return nil
  end
  if args.action then
    return tostring(args.action)
  end
  if args.agent then
    return tostring(args.agent)
  end
  if args.tasks then
    return 'parallel tasks'
  end
  if args.chain then
    return 'chain'
  end
  return nil
end

function M.args_to_lines(args)
  if type(args) ~= 'table' then
    return fenced_lines('', vim.inspect(args))
  end

  local lines = { '#### Request' }
  local function field(label, value)
    if value ~= nil and value ~= '' then
      table.insert(lines, ('**%s:** %s'):format(label, tostring(value)))
    end
  end

  field('Action', args.action)
  field('Agent', args.agent)
  field('Context', args.context)
  field('Timeout', args.timeoutMs and (tostring(args.timeoutMs) .. ' ms') or args.maxRuntimeMs and (tostring(args.maxRuntimeMs) .. ' ms') or nil)
  if args.task and args.task ~= '' then
    table.insert(lines, '**Task:**')
    vim.list_extend(lines, vim.split(normalize_line_endings(args.task), '\n', { plain = true }))
  end
  if type(args.tasks) == 'table' then
    field('Parallel tasks', #args.tasks)
  end
  if type(args.chain) == 'table' then
    field('Chain steps', #args.chain)
  end

  if #lines == 1 then
    local ok, encoded = pcall(vim.json.encode, args)
    return fenced_lines('json', ok and encoded or vim.inspect(args))
  end
  return lines
end

function M.result_to_lines(source, text, opts)
  opts = opts or {}
  if type(source) ~= 'table' then
    return nil
  end
  local runs = source.results or source.children or source.tasks or source
  if type(runs) ~= 'table' then
    return nil
  end
  local is_array = #runs > 0
  if not is_array and (source.response or source.output or source.text or source.summary or source.final or source.finalOutput or source.finalResult or source.final_result or source.final_output) then
    runs = { source }
    is_array = true
  end
  if not is_array then
    return nil
  end

  local lines = { '#### Result' }
  local children = {}
  for index, item in ipairs(runs) do
    if type(item) == 'table' then
      local progress = progress_for(source, item, index)
      local agent = first_string_field(item, { 'agent', 'name', 'role' }) or (progress and progress.agent) or ('child ' .. tostring(index))
      local status = status_for(item, progress)
      local label = (#runs > 1 and ('Agent ' .. index .. '/' .. #runs .. ': ' .. agent) or agent)
      local header = status and ('##### ' .. label .. ' - ' .. tostring(status)) or ('##### ' .. label)
      table.insert(lines, '')
      table.insert(lines, header)
      table.insert(lines, '')
      table.insert(lines, '###### Main info')

      local main_info = { '## Main info' }
      local task = first_present_field(item, { 'task', 'prompt', 'request' })
      if task then
        local task_line = '**Task:** ' .. compact_header_text(task, 160)
        table.insert(lines, task_line)
        table.insert(main_info, task_line)
      end
      local progress_lines = {}
      append_progress(progress_lines, progress, { include_recent_output = false })
      vim.list_extend(lines, progress_lines)
      vim.list_extend(main_info, progress_lines)
      if item.error then
        append_wrapped_text(lines, 'Error: ' .. tostring(item.error))
        append_wrapped_text(main_info, 'Error: ' .. tostring(item.error))
      end

      local body = first_string_field(item, { 'response', 'output', 'text', 'summary', 'final', 'finalOutput', 'finalResult', 'final_result', 'final_output', 'message' })
      local show_result = result_available(status, opts)
      local result_lines = transcript_lines_from_messages(item.messages, progress) or transcript_lines_from_progress(progress) or {}
      local added_result = #result_lines > 0
      if show_result then
        if not added_result and body then
          append_body(result_lines, body, { min_heading_level = 2, max_heading_level = 6 })
          added_result = true
        elseif item.error then
          append_body(result_lines, 'Error: ' .. tostring(item.error), { min_heading_level = 2, max_heading_level = 6 })
          added_result = true
        elseif type(progress) == 'table' and type(progress.recentOutput) == 'table' and #progress.recentOutput > 0 then
          for _, output_line in ipairs(progress.recentOutput) do
            append_body(result_lines, tostring(output_line), { min_heading_level = 2, max_heading_level = 6 })
          end
          added_result = true
        end
        if not added_result and not progress then
          local ok, encoded = pcall(vim.json.encode, item)
          append_body(result_lines, ok and encoded or vim.inspect(item), { min_heading_level = 2, max_heading_level = 6 })
        elseif not added_result then
          table.insert(result_lines, '_No sub-agent result was returned._')
        end
      else
        if not added_result and body then
          append_body(result_lines, body, { min_heading_level = 2, max_heading_level = 6 })
          added_result = true
        elseif item.error then
          append_body(result_lines, 'Error: ' .. tostring(item.error), { min_heading_level = 2, max_heading_level = 6 })
          added_result = true
        elseif type(progress) == 'table' and type(progress.recentOutput) == 'table' and #progress.recentOutput > 0 then
          for _, output_line in ipairs(progress.recentOutput) do
            append_body(result_lines, tostring(output_line), { min_heading_level = 2, max_heading_level = 6 })
          end
          added_result = true
        end
        if not added_result then
          table.insert(result_lines, '_Sub-agent has not produced output yet._')
        end
      end

      local title = buffer_title(label)
      table.insert(children, {
        header = header,
        label = label,
        title = title,
        lines = child_buffer_lines(title, main_info, result_lines, status),
      })
    else
      local label = 'subagent'
      local header = '##### ' .. label
      table.insert(lines, '')
      table.insert(lines, header)
      table.insert(lines, '')
      table.insert(lines, '###### Main info')
      local result_lines = {}
      if opts.lazy_details == true then
        table.insert(result_lines, '_Sub-agent result will be shown after this agent completes._')
      else
        append_body(result_lines, tostring(item), { min_heading_level = 2, max_heading_level = 6 })
      end
      table.insert(children, {
        header = header,
        label = label,
        title = label,
        lines = child_buffer_lines(label, { '## Main info' }, result_lines),
      })
    end
  end
  lines.__pi_subagent_children = children
  return lines
end

function M.raw_text_parent_lines(text)
  if vim.trim(normalize_line_endings(text)) == '' then
    return nil
  end
  local lines = { '#### Result', '', '##### subagent', '', '###### Main info' }
  local result_lines = {}
  append_body(result_lines, text, { min_heading_level = 2, max_heading_level = 6 })
  lines.__pi_subagent_children = {
    {
      header = '##### subagent',
      label = 'subagent',
      title = 'subagent',
      lines = child_buffer_lines('subagent', { '## Main info' }, result_lines, 'completed'),
    },
  }
  return lines
end

function M.lazy_result_placeholder()
  return { '_Sub-agent result will be shown after this agent completes._' }
end

function M.wrapped_result_lines(text)
  local lines = { '#### Result' }
  append_wrapped_text(lines, text, { min_heading_level = 6, max_heading_level = 6 })
  return lines
end

function M.title_text(title, depth)
  return 'Pi chat subagent (deep ' .. tostring(depth or 1) .. '): ' .. tostring(title or 'subagent')
end

function M.replace_title(lines, title, depth)
  local out = vim.deepcopy(lines or {})
  local heading = '# ' .. M.title_text(title, depth)
  if out[1] and tostring(out[1]):match('^#%s+Pi chat subagent') then
    out[1] = heading
  else
    table.insert(out, 1, '')
    table.insert(out, 1, heading)
  end
  return out
end

function M.ensure_view_buffer(view, ui_state, setup_buffer, output_filetype)
  if not view then
    return nil
  end
  if view.buf and vim.api.nvim_buf_is_valid(view.buf) then
    return view.buf
  end
  ui_state.subagent_counter = (ui_state.subagent_counter or 0) + 1
  view.buf = vim.api.nvim_create_buf(false, true)
  setup_buffer(view.buf, output_filetype)
  pcall(vim.api.nvim_buf_set_name, view.buf, 'pi-dev://subagent/' .. tostring(ui_state.subagent_counter))
  return view.buf
end

function M.child_from_buffer_lines(lines, line)
  local start_line
  local title
  for index = math.min(#lines, tonumber(line) or 1), 1, -1 do
    local candidate = tostring(lines[index] or '')
    local label = candidate:match('^#+%s+(Agent%s+%d+/%d+:.+)') or candidate:match('^#+%s+([^#].-subagent.-)$')
    if label then
      start_line = index
      title = vim.trim((label:gsub('%s+%-%s+.+$', ''):gsub('^Agent%s+%d+/%d+:%s*', '')))
      break
    end
    if candidate:match('^#%s+') then
      break
    end
  end
  if not start_line then
    return nil
  end
  local end_line = #lines
  for index = start_line + 1, #lines do
    if tostring(lines[index] or ''):match('^#+%s+Agent%s+%d+/%d+:') then
      end_line = index - 1
      break
    end
  end
  local header = tostring(lines[start_line] or '')
  local status = header:match('%s+%-%s+(.+)$')
  local normalized = { '> _Subagent started._' }
  local body = vim.list_slice(lines, start_line + 1, end_line)
  for _, raw_line in ipairs(body) do
    local line_text = tostring(raw_line or '')
    line_text = line_text:gsub('^######%s+', '## '):gsub('^#####%s+', '## ')
    line_text = notice_line(line_text)
    table.insert(normalized, line_text)
  end
  status = tostring(status or ''):lower()
  if status ~= '' and status ~= 'running' then
    if normalized[#normalized] ~= '' then
      table.insert(normalized, '')
    end
    table.insert(normalized, '> _Subagent done._')
  end
  return {
    title = title ~= '' and title or 'subagent',
    lines = normalized,
  }
end

function M.child_from_buffer(bufnr, line)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return M.child_from_buffer_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), line)
end

function M.resolve_children(block, children, buffer_lines)
  if not block then
    return
  end
  block.subagent_children = {}
  if type(children) ~= 'table' or #children == 0 then
    return
  end
  local resolved = {}
  local search_from = 1
  for _, child in ipairs(children) do
    local header = child.header
    if header then
      for index = search_from, #buffer_lines do
        if buffer_lines[index] == header then
          local resolved_child = vim.deepcopy(child)
          resolved_child.start_line = (block.start_line or 1) + index - 1
          resolved_child.end_line = block.end_line
          table.insert(resolved, resolved_child)
          search_from = index + 1
          break
        end
      end
    end
  end
  for index, child in ipairs(resolved) do
    if resolved[index + 1] and resolved[index + 1].start_line then
      child.end_line = resolved[index + 1].start_line - 1
    end
  end
  block.subagent_children = resolved
end

local function child_heading(line)
  local hashes, title = tostring(line or ''):match('^(#+)%s+(.+)$')
  if not hashes or #hashes < 5 then
    return nil
  end
  if title:match('^Agent%s+%d+/%d+:') or title:lower():find('subagent', 1, true) then
    return vim.trim(title:gsub('%s+%-%s+.+$', ''))
  end
  return nil
end

function M.child_detail_fold_key(line)
  local key = child_heading(line)
  return key and ('subagent:' .. key) or nil
end

function M.context_headers_from_view(view)
  if not view then
    return nil
  end
  local chain = {}
  local current = view
  while current do
    table.insert(chain, 1, current)
    current = current.parent_view
  end
  local headers = {}
  for index, item in ipairs(chain) do
    local level = math.min(5 + index - 1, 12)
    table.insert(headers, string.rep('#', level) .. ' ' .. tostring(item.title or item.label or 'subagent'))
  end
  return #headers > 0 and headers or nil
end

function M.permission_context_headers(block, permission_id, active_view)
  if not block then
    return M.context_headers_from_view(active_view)
  end
  block.subagent_permission_contexts = block.subagent_permission_contexts or {}
  local key = permission_id ~= nil and tostring(permission_id) or nil
  if key and block.subagent_permission_contexts[key] then
    return block.subagent_permission_contexts[key]
  end

  local headers = M.context_headers_from_view(active_view)
  if not headers then
    local candidates = {}
    for _, child in ipairs(block.subagent_children or {}) do
      if tostring(child.header or ''):lower():find('running', 1, true) then
        table.insert(candidates, child)
      end
    end
    if #candidates == 0 then
      for _, child in ipairs(block.subagent_children or {}) do
        table.insert(candidates, child)
      end
    end

    local child = nil
    if #candidates > 0 then
      local cursor = tonumber(block.subagent_permission_context_cursor) or 0
      child = candidates[(cursor % #candidates) + 1]
      block.subagent_permission_context_cursor = cursor + 1
    end
    headers = { child and child.header or '##### subagent' }
  end
  if key then
    block.subagent_permission_contexts[key] = headers
  end
  return headers
end

return M
