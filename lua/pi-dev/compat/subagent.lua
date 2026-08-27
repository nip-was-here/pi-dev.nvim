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

local function current_tool_duration(progress)
  return type(progress) == 'table' and format_duration_ms(progress.currentToolDurationMs or progress.current_tool_duration_ms) or nil
end

local function current_tool_action(progress, max_chars)
  if type(progress) ~= 'table' or not progress.currentTool then
    return nil
  end
  local action = tostring(progress.currentTool)
  if progress.currentPath then
    action = action .. ' ' .. tostring(progress.currentPath)
  elseif progress.currentToolArgs then
    action = action .. ' ' .. compact_header_text(progress.currentToolArgs, max_chars or 120)
  end
  local duration = current_tool_duration(progress)
  if duration then
    action = action .. ' (' .. duration .. ')'
  end
  return action
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
    local duration = current_tool_duration(progress)
    if duration then
      current = current .. ' (' .. duration .. ')'
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

local known_statuses = {
  'timed out',
  'cancelled',
  'canceled',
  'completed',
  'complete',
  'detached',
  'failed',
  'failure',
  'interrupted',
  'running',
  'queued',
  'active',
  'done',
  'error',
}

local function escaped_pattern(text)
  return tostring(text or ''):gsub('([^%w])', '%%%1')
end

local function parse_status_suffix(rest)
  rest = tostring(rest or '')
  local head = rest:gsub(',.*$', '')
  local model
  local thinking
  local runtime = rest:match('%(([^%)]*)%)')
  if runtime then
    thinking = runtime:match('thinking%s+([^,]+)')
    local first = vim.trim(runtime:match('^([^,]+)') or '')
    if first ~= '' and not first:match('^thinking%s+') then
      model = first
    end
  end
  for _, status in ipairs(known_statuses) do
    local escaped = escaped_pattern(status)
    local agent = head:match('^(.-)%s+' .. escaped .. '%s*%(') or head:match('^(.-)%s+' .. escaped .. '$')
    if agent and vim.trim(agent) ~= '' then
      return vim.trim(agent), status, model, thinking
    end
  end
  return vim.trim(head), nil, model, thinking
end

local function parse_status_child_line(line)
  line = tostring(line or '')
  local index, total, rest = line:match('^Step%s+%S+%s+Agent%s+(%d+)/(%d+):%s+(.+)$')
  if not index then
    index, total, rest = line:match('^Agent%s+(%d+)/(%d+):%s+(.+)$')
  end
  if index then
    local agent, status, model, thinking = parse_status_suffix(rest)
    return {
      index = tonumber(index),
      total = tonumber(total),
      agent = agent ~= '' and agent or ('agent ' .. tostring(index)),
      status = status,
      model = model,
      thinking = thinking,
      raw = line,
    }
  end

  local key, name, agent, status = line:match('^Workflow child%s+([^:]+):%s+(.+)%s+%(([^%)]+)%)%s+([%w%s]+)')
  if key then
    status = vim.trim(status or '')
    return {
      agent = vim.trim(agent) ~= '' and vim.trim(agent) or vim.trim(name),
      status = status ~= '' and status or nil,
      raw = line,
    }
  end
  return nil
end

local function status_summary_lines(text)
  local lines = {}
  local allowed = {
    Run = true,
    State = true,
    Activity = true,
    Mode = true,
    Progress = true,
    Started = true,
    Updated = true,
    Dir = true,
    Output = true,
    Session = true,
    Log = true,
    Events = true,
  }
  for _, line in ipairs(vim.split(normalize_line_endings(text), '\n', { plain = true })) do
    local key, value = line:match('^([%w%s]+):%s*(.+)$')
    key = key and vim.trim(key) or nil
    if key and allowed[key] and vim.trim(value or '') ~= '' then
      table.insert(lines, ('**%s:** %s'):format(key, tostring(value)))
    end
  end
  return lines
end

local function child_action_from_details(details, status)
  for _, line in ipairs(details or {}) do
    local output = tostring(line or ''):match('^%s*Output:%s*(.+)$')
    if output then
      return output
    end
    local active = tostring(line or ''):match(',%s*(active.-)$')
    if active then
      return active
    end
  end
  return status or 'status'
end

function M.status_text_parent_lines(text)
  text = normalize_line_endings(text or '')
  if vim.trim(text) == '' then
    return nil
  end

  local parsed = {}
  local current
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local child = parse_status_child_line(line)
    if child then
      current = child
      current.details = {}
      table.insert(parsed, current)
    elseif current and line:match('^%s+') and vim.trim(line) ~= '' then
      table.insert(current.details, vim.trim(line))
    end
  end

  if #parsed == 0 then
    return nil
  end

  local lines = { '#### Result' }
  local summary = status_summary_lines(text)
  if #summary > 0 then
    table.insert(lines, '')
    vim.list_extend(lines, summary)
  end

  local children = {}
  for index, item in ipairs(parsed) do
    local label = item.total and ('Agent ' .. tostring(item.index or index) .. '/' .. tostring(item.total) .. ': ' .. item.agent) or item.agent
    local header = item.status and ('##### ' .. label .. ' - ' .. tostring(item.status)) or ('##### ' .. label)
    table.insert(lines, '')
    table.insert(lines, header)
    table.insert(lines, '')
    table.insert(lines, '###### Main info')
    table.insert(lines, '**Agent:** ' .. tostring(item.agent or 'unknown'))
    table.insert(lines, '**Status:** ' .. tostring(item.status or 'unknown'))
    if item.model then
      table.insert(lines, '**Model:** ' .. tostring(item.model))
    end
    if item.thinking then
      table.insert(lines, '**Thinking:** ' .. tostring(item.thinking))
    end
    table.insert(lines, '**Details:** ' .. item.raw)
    for _, detail in ipairs(item.details or {}) do
      table.insert(lines, '- ' .. detail)
    end

    local main_info = {
      '## Main info',
      '**Agent:** ' .. tostring(item.agent or 'unknown'),
      '**Status:** ' .. tostring(item.status or 'unknown'),
    }
    if item.model then
      table.insert(main_info, '**Model:** ' .. tostring(item.model))
    end
    if item.thinking then
      table.insert(main_info, '**Thinking:** ' .. tostring(item.thinking))
    end
    table.insert(main_info, '**Details:** ' .. item.raw)
    for _, detail in ipairs(item.details or {}) do
      table.insert(main_info, '- ' .. detail)
    end
    table.insert(children, {
      header = header,
      label = label,
      title = buffer_title(label),
      agent = item.agent,
      role = item.agent,
      status = item.status,
      action = child_action_from_details(item.details, item.status),
      lines = child_buffer_lines(buffer_title(label), main_info, {}, item.status),
    })
  end

  lines.__pi_subagent_children = children
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

local function string_list(value)
  if type(value) == 'string' and vim.trim(value) ~= '' then
    return { vim.trim(value) }
  end
  local values = {}
  for _, item in ipairs(type(value) == 'table' and value or {}) do
    if item ~= nil and item ~= vim.NIL and vim.trim(tostring(item)) ~= '' then
      table.insert(values, vim.trim(tostring(item)))
    end
  end
  return values
end

local function tool_args_summary(args)
  if args == nil or args == vim.NIL then
    return nil
  end
  if type(args) == 'string' then
    return compact_header_text(args, 220)
  end
  if type(args) ~= 'table' then
    return compact_header_text(tostring(args), 220)
  end
  for _, field in ipairs({ 'command', 'path', 'file', 'filePath', 'query', 'url', 'pattern', 'prompt' }) do
    local value = args[field]
    if value ~= nil and value ~= vim.NIL and tostring(value) ~= '' then
      return compact_header_text(tostring(value), 220)
    end
  end
  local ok, encoded = pcall(vim.json.encode, args)
  return compact_header_text(ok and encoded or vim.inspect(args), 220)
end

local function command_line(name, args)
  local line = tostring(name or 'tool')
  local summary = tool_args_summary(args)
  if summary and summary ~= '' then
    line = line .. ' ' .. summary
  end
  return line
end

local function command_summaries_from_messages(messages)
  local commands = {}
  for _, message in ipairs(type(messages) == 'table' and messages or {}) do
    if type(message) == 'table' and message.role == 'assistant' and type(message.content) == 'table' then
      for _, item in ipairs(message.content) do
        if is_tool_call_item(item) then
          table.insert(commands, command_line(tool_call_name(item), tool_call_args(item)))
        end
      end
    elseif type(message) == 'table' and (message.type == 'tool_execution_start' or message.type == 'tool_execution_update') then
      table.insert(commands, command_line(message.toolName or message.tool_name or message.name, message.args or message.arguments or message.input))
    end
  end
  return commands
end

local function live_progress_entries(source)
  source = type(source) == 'table' and (source.details or source) or nil
  if type(source) ~= 'table' then
    return {}
  end
  local entries = {}
  local seen = {}
  local function append(progress, key, index, agent)
    if type(progress) ~= 'table' or seen[progress] then
      return
    end
    seen[progress] = true
    table.insert(entries, { progress = progress, key = key, index = progress.index or index, agent = progress.agent or agent })
  end
  local function append_nested(items, parent_key)
    for index, item in ipairs(type(items) == 'table' and items or {}) do
      if type(item) == 'table' then
        local key = parent_key .. '/' .. tostring(item.runId or item.id or item.workflowKey or index)
        append(item, key, index - 1, item.agent)
        append_nested(item.children, key .. '/children')
        append_nested(item.steps, key .. '/steps')
      end
    end
  end
  for index, item in ipairs(type(source.results) == 'table' and source.results or {}) do
    local key = 'result-' .. tostring(index - 1)
    append(type(item) == 'table' and item.progress or nil, key, index - 1, type(item) == 'table' and item.agent or nil)
    if type(item) == 'table' then
      append_nested(item.children, key .. '/children')
      append_nested(item.steps, key .. '/steps')
    end
  end
  for index, progress in ipairs(type(source.progress) == 'table' and source.progress or {}) do
    append(progress, 'result-' .. tostring(index - 1), index - 1, type(progress) == 'table' and progress.agent or nil)
  end
  return entries
end

local function timing_tool_key(tool, args, end_ms)
  return table.concat({ tostring(tool or ''), tostring(args or ''), tostring(end_ms or '') }, '\0')
end

function M.has_running_tool(source)
  for _, entry in ipairs(live_progress_entries(source)) do
    if entry.progress.currentTool then
      return true
    end
  end
  return false
end

function M.enrich_live_tool_timings(block, source, now_ms)
  if not block or type(source) ~= 'table' then
    return source
  end
  local enriched = vim.deepcopy(source)
  block.subagent_live_tool_timings = block.subagent_live_tool_timings or {}
  for _, entry in ipairs(live_progress_entries(enriched)) do
    local progress = entry.progress
    local child_key = tostring(entry.key or (entry.index ~= nil and entry.index or entry.agent or 0))
    local timing = block.subagent_live_tool_timings[child_key] or { completed = {}, completed_tools = {}, completed_order = {} }
    timing.completed = timing.completed or {}
    timing.completed_tools = timing.completed_tools or {}
    timing.completed_order = timing.completed_order or {}
    local previous = timing.current
    local previous_completed = false
    local function matching_synthetic(tool)
      for index = #timing.completed_order, 1, -1 do
        local key = timing.completed_order[index]
        local candidate = timing.completed_tools[key]
        if candidate and candidate.__pi_synthetic == true
          and tostring(candidate.tool or candidate.name or candidate.toolName or '') == tostring(tool.tool or tool.name or tool.toolName or '')
          and tostring(candidate.args or '') == tostring(tool.args or '')
        then
          return key, candidate, index
        end
      end
    end
    local function remember_completed(tool, end_ms, duration_ms, synthetic)
      local old_key, old_tool, old_index
      if not synthetic then
        old_key, old_tool, old_index = matching_synthetic(tool)
      end
      if not duration_ms and old_tool and end_ms and tonumber(old_tool.__pi_started_at_ms) then
        duration_ms = math.max(0, end_ms - tonumber(old_tool.__pi_started_at_ms))
      end
      local key = timing_tool_key(tool.tool or tool.name or tool.toolName, tool.args, end_ms)
      if old_key and old_key ~= key then
        timing.completed[old_key] = nil
        timing.completed_tools[old_key] = nil
        table.remove(timing.completed_order, old_index)
      end
      if duration_ms then
        tool.durationMs = duration_ms
        timing.completed[key] = duration_ms
      end
      if synthetic then
        tool.__pi_synthetic = true
        tool.__pi_started_at_ms = previous and previous.started_at_ms or nil
      end
      if not timing.completed_tools[key] then
        if old_index then
          table.insert(timing.completed_order, old_index, key)
        else
          table.insert(timing.completed_order, key)
        end
      end
      timing.completed_tools[key] = vim.deepcopy(tool)
    end
    for _, tool in ipairs(type(progress.recentTools) == 'table' and progress.recentTools or {}) do
      if type(tool) == 'table' then
        local end_ms = tonumber(tool.endMs or tool.end_ms)
        local key = timing_tool_key(tool.tool or tool.name or tool.toolName, tool.args, end_ms)
        local duration_ms = tonumber(tool.durationMs or tool.duration_ms) or timing.completed[key]
        local matches_previous = previous
          and tostring(previous.tool or '') == tostring(tool.tool or tool.name or tool.toolName or '')
          and tostring(previous.args or '') == tostring(tool.args or '')
        if not duration_ms and matches_previous and end_ms then
          duration_ms = math.max(0, end_ms - previous.started_at_ms)
        end
        previous_completed = previous_completed or matches_previous == true
        remember_completed(tool, end_ms, duration_ms)
      end
    end
    local current_args = progress.currentToolArgs or progress.currentPath or ''
    local current_changed = previous and (not progress.currentTool
      or tostring(previous.tool) ~= tostring(progress.currentTool)
      or tostring(previous.args or '') ~= tostring(current_args))
    if current_changed and not previous_completed then
      local end_ms = tonumber(progress.currentToolStartedAt or progress.current_tool_started_at) or tonumber(now_ms)
      if end_ms then
        remember_completed({ tool = previous.tool, args = previous.args, endMs = end_ms }, end_ms, math.max(0, end_ms - previous.started_at_ms), true)
      end
    end
    if progress.currentTool then
      local started_at_ms = tonumber(progress.currentToolStartedAt or progress.current_tool_started_at)
      if previous and tostring(previous.tool) == tostring(progress.currentTool) and tostring(previous.args or '') == tostring(current_args) then
        started_at_ms = started_at_ms or previous.started_at_ms
      end
      started_at_ms = started_at_ms or tonumber(now_ms)
      timing.current = { tool = progress.currentTool, args = current_args, started_at_ms = started_at_ms }
      if tonumber(now_ms) and started_at_ms then
        progress.currentToolDurationMs = math.max(0, tonumber(now_ms) - started_at_ms)
      end
    else
      timing.current = nil
    end
    progress.completedTools = {}
    for _, key in ipairs(timing.completed_order) do
      local tool = vim.deepcopy(timing.completed_tools[key])
      tool.__pi_synthetic = nil
      tool.__pi_started_at_ms = nil
      table.insert(progress.completedTools, tool)
    end
    block.subagent_live_tool_timings[child_key] = timing
  end
  return enriched
end

local function command_summaries(item, progress)
  local commands = command_summaries_from_messages(type(item) == 'table' and item.messages or nil)
  if type(item) == 'table' and type(item.toolCalls) == 'table' then
    for _, tool in ipairs(item.toolCalls) do
      local text
      if type(tool) == 'table' then
        text = first_string_field(tool, { 'expandedText', 'expanded_text', 'text', 'summary' })
          or command_line(tool.name or tool.tool or tool.toolName, tool.args or tool.arguments or tool.input)
      elseif tool ~= nil and tool ~= vim.NIL then
        text = tostring(tool)
      end
      text = text and compact_header_text(text, 240) or nil
      if text and not vim.tbl_contains(commands, text) then
        table.insert(commands, text)
      end
    end
  end
  if type(progress) == 'table' then
    local completed = type(progress.completedTools) == 'table' and progress.completedTools or progress.recentTools
    for _, tool in ipairs(type(completed) == 'table' and completed or {}) do
      if type(tool) == 'table' then
        local name = tostring(tool.tool or tool.name or tool.toolName or 'tool')
        local args = tool.args and tool.args ~= '' and compact_header_text(tool.args, 220) or nil
        local duration = tool_duration(tool)
        local matched = false
        for index = #commands, 1, -1 do
          local command = tostring(commands[index])
          if command:find(name, 1, true) == 1 and (not args or command:find(args, 1, true)) then
            if duration and not command:match('%s+%([^)]-%)$') then
              commands[index] = command .. ' (' .. duration .. ')'
            end
            matched = true
            break
          end
        end
        if not matched then
          local line = name
          if args then line = line .. ' - ' .. args end
          if duration then line = line .. ' (' .. duration .. ')' end
          table.insert(commands, line)
        end
      end
    end
  end
  if type(progress) == 'table' and progress.currentTool then
    local current = current_tool_action(progress, 220)
    local running_suffix = current_tool_duration(progress) and ', running)' or ' (running)'
    if current_tool_duration(progress) then
      current = current:gsub('%)$', running_suffix)
    else
      current = current .. running_suffix
    end
    local matched = false
    for index, command in ipairs(commands) do
      if command == current or command == current:gsub('%s+%([^)]-running%)$', '') then
        commands[index] = current
        matched = true
        break
      end
    end
    if not matched then
      table.insert(commands, current)
    end
  end
  return commands
end

local function append_commands(lines, commands)
  if type(commands) ~= 'table' or #commands == 0 then
    return
  end
  table.insert(lines, '**Commands:**')
  table.insert(lines, '```text')
  for index, command in ipairs(commands) do
    table.insert(lines, tostring(index) .. '. ' .. tostring(command))
  end
  table.insert(lines, '```')
end

local function append_agent_info(lines, item, progress, status, agent, opts)
  opts = opts or {}
  local function field(label, value)
    if value ~= nil and value ~= vim.NIL and vim.trim(tostring(value)) ~= '' then
      table.insert(lines, ('**%s:** %s'):format(label, tostring(value)))
    end
  end
  field('Name', opts.name)
  field('Agent', agent)
  local role = type(item) == 'table' and first_string_field(item, { 'role' }) or nil
  if role and role ~= agent then
    field('Role', role)
  end
  local skills = string_list((type(item) == 'table' and item.skills) or (type(progress) == 'table' and progress.skills))
  if #skills > 0 then
    field('Skills', table.concat(skills, ', '))
  end
  field('Status', status)
  field('Model', (type(item) == 'table' and item.model) or (type(progress) == 'table' and progress.model))
  field('Thinking', (type(item) == 'table' and item.thinking) or (type(progress) == 'table' and progress.thinking))
  field('Session', type(item) == 'table' and item.sessionFile or nil)
  field('Transcript', type(item) == 'table' and item.transcriptPath or nil)
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

local function async_status_name(step, index)
  return first_string_field(step, { 'label', 'workflowKey', 'name', 'id' })
    or first_string_field(step, { 'agent', 'role' })
    or ('child-' .. tostring(index))
end

local function async_status_item(step, index, status)
  step = type(step) == 'table' and step or {}
  local role = first_string_field(step, { 'agent', 'role' })
  local name = async_status_name(step, index)
  local started_at = tonumber(step.startedAt or status.startedAt)
  local updated_at = tonumber(step.lastUpdate or status.lastUpdate or status.updatedAt)
  local tokens = step.tokens
  if type(tokens) == 'table' then
    tokens = tonumber(tokens.total or tokens.totalTokens)
  end
  local progress = {
    index = index - 1,
    agent = name,
    status = tostring(step.status or step.state or status.state or 'running'),
    task = first_string_field(step, { 'description', 'task', 'goal' }) or first_string_field(status, { 'description', 'task', 'goal' }),
    skills = string_list(step.skills),
    model = step.model,
    thinking = step.thinking,
    currentTool = step.currentTool,
    currentToolArgs = step.currentToolArgs,
    currentToolStartedAt = step.currentToolStartedAt,
    currentPath = step.currentPath,
    recentTools = type(step.recentTools) == 'table' and step.recentTools or {},
    recentOutput = type(step.recentOutput) == 'table' and step.recentOutput or {},
    toolCount = step.toolCount,
    turnCount = step.turnCount,
    tokens = tokens,
    durationMs = tonumber(step.durationMs) or (started_at and updated_at and math.max(0, updated_at - started_at) or nil),
  }
  return {
    index = index - 1,
    name = name,
    agent = name,
    role = role ~= name and role or nil,
    skills = string_list(step.skills),
    model = step.model,
    thinking = step.thinking,
    task = progress.task,
    status = progress.status,
    state = progress.status,
    progress = progress,
    children = type(step.children) == 'table' and step.children or nil,
    steps = type(step.steps) == 'table' and step.steps or nil,
    currentTool = step.currentTool,
    currentToolArgs = step.currentToolArgs,
    currentToolStartedAt = step.currentToolStartedAt,
    currentPath = step.currentPath,
    recentTools = type(step.recentTools) == 'table' and step.recentTools or {},
  }
end

function M.async_receipt(result)
  if type(result) ~= 'table' then
    return nil
  end
  local details = type(result.details) == 'table' and result.details or result
  local async_dir = first_string_field(details, { 'asyncDir', 'async_dir' })
  local async_id = first_string_field(details, { 'asyncId', 'async_id', 'runId', 'run_id' })
  if not async_dir or not async_id then
    return nil
  end
  return { id = async_id, dir = async_dir, mode = details.mode }
end

function M.async_status_result(status, receipt)
  if type(status) ~= 'table' then
    return nil
  end
  local steps = type(status.steps) == 'table' and status.steps or {}
  local results = {}
  for index, step in ipairs(steps) do
    table.insert(results, async_status_item(step, index, status))
  end
  if #results == 0 then
    local root = vim.deepcopy(status)
    if not root.agent and type(root.agents) == 'table' and #root.agents == 1 then
      root.agent = root.agents[1]
    end
    if not first_string_field(root, { 'agent', 'role', 'label', 'workflowKey', 'name', 'id' }) and not root.currentTool then
      return nil
    end
    table.insert(results, async_status_item(root, 1, status))
  end
  return {
    content = { { type = 'text', text = 'Async subagent status updated.' } },
    details = {
      mode = status.mode or (receipt and receipt.mode) or 'single',
      runId = status.runId or (receipt and receipt.id),
      asyncId = receipt and receipt.id or status.runId,
      asyncDir = receipt and receipt.dir or nil,
      results = results,
      progress = vim.tbl_map(function(item) return item.progress end, results),
    },
  }
end

function M.async_status_terminal(status)
  local value = type(status) == 'table' and tostring(status.state or status.status or ''):lower() or ''
  return value == 'complete'
    or value == 'completed'
    or value == 'cancelled'
    or value == 'canceled'
    or value == 'error'
    or value == 'failed'
    or value == 'paused'
    or value == 'stopped'
    or value == 'detached'
    or value == 'rejected'
    or value == 'timed out'
    or value == 'timeout'
end

local subagent_wait_statuses = {
  ['awaiting input'] = true,
  ['need decision'] = true,
  ['needs attention'] = true,
  ['needs decision'] = true,
  ['paused'] = true,
  ['waiting'] = true,
  ['waiting input'] = true,
}

local function normalized_status(value)
  value = tostring(value or ''):lower():gsub('_', ' '):gsub('%s+', ' ')
  return vim.trim(value)
end

local function value_marks_waiting(value)
  local status = normalized_status(value)
  return subagent_wait_statuses[status] == true
end

function M.has_waiting_child(source)
  local seen = {}
  local function scan(value)
    if type(value) ~= 'table' then
      return false
    end
    if seen[value] then
      return false
    end
    seen[value] = true

    if value.waitingInput == true or value.waiting_input == true or value.needsAttention == true or value.needs_attention == true then
      return true
    end
    for _, field in ipairs({ 'status', 'state', 'activityState', 'activity_state', 'controlState', 'control_state' }) do
      if value[field] ~= nil and value_marks_waiting(value[field]) then
        return true
      end
    end

    for _, field in ipairs({ 'progress', 'results', 'children', 'steps', 'tasks', 'details' }) do
      local child = value[field]
      if type(child) == 'table' and scan(child) then
        return true
      end
    end
    for _, child in pairs(value) do
      if type(child) == 'table' and scan(child) then
        return true
      end
    end
    return false
  end
  return scan(source)
end

function M.is_tool(tool_name)
  local lower = tostring(tool_name or ''):lower()
  return lower == 'agent'
    or lower == 'subagent'
    or lower:match('[_%-]agent$') ~= nil
    or lower:match('[_%-]subagent$') ~= nil
end

local workflow_run_descriptors

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
  if type(args.workflowScript) == 'string' then
    local descriptors = workflow_run_descriptors(args.workflowScript)
    if #descriptors > 1 then
      return 'workflow (' .. tostring(#descriptors) .. ' agents)'
    end
    return 'workflow'
  end
  if args.chain then
    return 'chain'
  end
  return nil
end

local function javascript_code_at(script, target)
  local quote
  local escaped = false
  local line_comment = false
  local block_comment = false
  local index = 1
  while index < target do
    local char = script:sub(index, index)
    local next_char = script:sub(index + 1, index + 1)
    if line_comment then
      if char == '\n' then line_comment = false end
    elseif block_comment then
      if char == '*' and next_char == '/' then
        block_comment = false
        index = index + 1
      end
    elseif quote then
      if escaped then
        escaped = false
      elseif char == '\\' then
        escaped = true
      elseif char == quote then
        quote = nil
      end
    elseif char == '/' and next_char == '/' then
      line_comment = true
      index = index + 1
    elseif char == '/' and next_char == '*' then
      block_comment = true
      index = index + 1
    elseif char == "'" or char == '"' or char == '`' then
      quote = char
    end
    index = index + 1
  end
  return not quote and not line_comment and not block_comment
end

local function code_matches(script, pattern)
  local matches = {}
  local search_from = 1
  while true do
    local found = { script:find(pattern, search_from) }
    local start_at = found[1]
    if not start_at then break end
    if javascript_code_at(script, start_at) then
      table.insert(matches, found)
    end
    search_from = math.max(start_at + 1, (found[2] or start_at) + 1)
  end
  return matches
end

workflow_run_descriptors = function(script)
  script = tostring(script or '')
  local descriptors = {}
  local seen = {}
  local command = #code_matches(script, 'runs%.all%s*%(') > 0 and 'runs.all'
    or #code_matches(script, 'runs%.run%s*%(') > 0 and 'runs.run'
    or 'workflow'
  local function quoted_field(body, field)
    local quote, value = (',' .. body):match('[,{]%s*' .. field .. "%s*:%s*(['\"])(.-)%1")
    if not quote then
      return nil
    end
    return value:gsub('\\n', '\n'):gsub('\\r', '\r'):gsub('\\t', '\t'):gsub('\\([\\\'\"])', '%1')
  end
  local function append(body, fallback_name)
    local agent = quoted_field(body, 'agent')
    local task = quoted_field(body, 'task')
    local name = quoted_field(body, 'key') or fallback_name or agent
    if not agent or seen[tostring(name) .. '\0' .. tostring(agent)] then
      return
    end
    seen[tostring(name) .. '\0' .. tostring(agent)] = true
    local skills = {}
    local skill_list = body:match('skills?%s*:%s*%[([^%]]*)%]')
    for skill in tostring(skill_list or ''):gmatch("'([^']+)'") do
      table.insert(skills, skill)
    end
    for skill in tostring(skill_list or ''):gmatch('"([^"]+)"') do
      table.insert(skills, skill)
    end
    if #skills == 0 then
      local skill = quoted_field(body, 'skills?')
      if skill then table.insert(skills, skill) end
    end
    table.insert(descriptors, {
      name = name,
      agent = agent,
      role = quoted_field(body, 'role') or agent,
      skills = skills,
      model = quoted_field(body, 'model'),
      thinking = quoted_field(body, 'thinking'),
      task = task,
      command = command,
    })
  end
  local arrays = {}
  for _, match in ipairs(code_matches(script, '([%a_$][%w_$]*)%s*=%s*%[(.-)%]%s*;')) do
    arrays[match[3]] = match[4]
  end
  for _, match in ipairs(code_matches(script, 'runs%.all%s*%(([^%)]-)%)')) do
    local argument = match[3]
    local body = arrays[vim.trim(argument)] or argument:match('^%s*%[(.*)%]%s*$')
    if body then
      for object in body:gmatch('{([^{}]-)}') do
        append(object)
      end
    end
  end
  for _, match in ipairs(code_matches(script, "runs%.run%s*%(%s*'([^']+)'%s*,%s*{([^{}]-)}")) do
    append(match[4], match[3])
  end
  for _, match in ipairs(code_matches(script, 'runs%.run%s*%(%s*"([^"]+)"%s*,%s*{([^{}]-)}')) do
    append(match[4], match[3])
  end
  return descriptors, command
end

local function request_children(args)
  if type(args) ~= 'table' or type(args.workflowScript) ~= 'string' then
    return {}
  end
  local descriptors = workflow_run_descriptors(args.workflowScript)
  local children = {}
  for index, item in ipairs(descriptors) do
    local main_info = { '## Main info' }
    append_agent_info(main_info, item, nil, 'running', item.agent, { name = item.name })
    if item.task and item.task ~= '' then
      table.insert(main_info, '**Task:** ' .. compact_header_text(item.task, 160))
    end
    table.insert(main_info, '**Command:** ' .. item.command)
    table.insert(children, {
      header = '##### Agent ' .. tostring(index) .. '/' .. tostring(#descriptors) .. ': ' .. tostring(item.name) .. ' - running',
      key = 'agent-' .. tostring(index),
      request_key = 'request-agent-' .. tostring(index) .. '-' .. tostring(item.name),
      label = item.name,
      name = item.name,
      title = item.name,
      agent = item.agent,
      role = item.role,
      skills = item.skills,
      status = 'running',
      active = true,
      action = item.command,
      request_main_info = main_info,
      lines = child_buffer_lines(item.name, main_info, { '_Sub-agent has not produced output yet._' }, 'running'),
    })
  end
  return children
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
  local children = request_children(args)
  if #children > 0 then
    for index, child in ipairs(children) do
      table.insert(lines, '')
      table.insert(lines, child.header)
      table.insert(lines, '')
      table.insert(lines, '###### Main info')
      vim.list_extend(lines, vim.list_slice(child.request_main_info or {}, 2))
    end
    lines.__pi_subagent_children = children
  end

  if #lines == 1 then
    local ok, encoded = pcall(vim.json.encode, args)
    return fenced_lines('json', ok and encoded or vim.inspect(args))
  end
  return lines
end

local nested_terminal_statuses = {
  cancelled = true,
  canceled = true,
  complete = true,
  completed = true,
  done = true,
  detached = true,
  error = true,
  failed = true,
  failure = true,
  interrupted = true,
  rejected = true,
  stopped = true,
  success = true,
  succeeded = true,
  ['timed out'] = true,
  timeout = true,
}

local function nested_action(item)
  if type(item) ~= 'table' then
    return 'idle'
  end
  return tostring(current_tool_action(item, 120) or item.activityState or item.state or item.status or 'idle')
end

local nested_child_from_summary

local function child_main_info_lines(child)
  local lines = {}
  local started = false
  for _, line in ipairs(child and child.lines or {}) do
    if tostring(line):match('^## Main info') then
      started = true
    elseif started and tostring(line):match('^## Result') then
      break
    elseif started and not tostring(line):match('^>%s+_Subagent done') then
      table.insert(lines, line)
    end
  end
  return lines
end

local function nested_children_from(item, parent_key)
  local children = {}
  local function append_summaries(summaries)
    for index, summary in ipairs(type(summaries) == 'table' and summaries or {}) do
      local child = nested_child_from_summary(summary, tostring(parent_key or 'child') .. '/' .. tostring(index))
      if child then
        table.insert(children, child)
      end
    end
  end
  append_summaries(type(item) == 'table' and item.children or nil)
  for index, step in ipairs(type(item) == 'table' and type(item.steps) == 'table' and item.steps or {}) do
    if type(step) == 'table' then
      local summary = vim.deepcopy(step)
      summary.runId = summary.runId or ((item.runId or item.agent or 'workflow') .. '/step-' .. tostring(index))
      local child = nested_child_from_summary(summary, tostring(parent_key or 'child') .. '/step-' .. tostring(index))
      if child then
        table.insert(children, child)
      end
    end
  end
  return children
end

nested_child_from_summary = function(item, stable_key)
  if type(item) ~= 'table' then
    return nil
  end
  local agent = first_string_field(item, { 'agent', 'role' })
  if not agent and type(item.agents) == 'table' and #item.agents == 1 then
    agent = tostring(item.agents[1])
  end
  local name = first_string_field(item, { 'runId', 'name', 'id' }) or agent or 'subagent'
  local status = tostring(item.state or item.status or 'running')
  local progress = {
    status = status,
    currentTool = item.currentTool,
    currentToolArgs = item.currentToolArgs,
    currentToolDurationMs = item.currentToolDurationMs,
    currentPath = item.currentPath,
    toolCount = item.toolCount,
    turnCount = item.turnCount,
    tokens = type(item.totalTokens) == 'number' and item.totalTokens or nil,
    model = item.model,
    thinking = item.thinking,
    recentTools = type(item.recentTools) == 'table' and item.recentTools or {},
  }
  local main_info = { '## Main info' }
  append_agent_info(main_info, item, progress, status, agent, { name = name })
  local task = first_present_field(item, { 'task', 'prompt', 'request', 'goal' })
  if task then
    table.insert(main_info, '**Task:** ' .. compact_header_text(task, 160))
  end
  local commands = command_summaries(item, progress)
  append_commands(main_info, commands)
  append_progress(main_info, progress, { include_recent_tools = #commands == 0 })
  local result_lines = transcript_lines_from_messages(item.messages, progress) or transcript_lines_from_progress(progress) or {}
  local body = first_string_field(item, { 'response', 'output', 'text', 'summary', 'final', 'finalOutput', 'finalResult', 'final_result', 'final_output', 'message' })
  if #result_lines == 0 and body then
    append_body(result_lines, body, { min_heading_level = 2, max_heading_level = 6 })
  end
  local children = nested_children_from(item, stable_key)
  if #children > 0 then
    table.insert(result_lines, '## Descendants')
    for index, child in ipairs(children) do
      table.insert(result_lines, '')
      table.insert(result_lines, '##### Agent ' .. tostring(index) .. '/' .. tostring(#children) .. ': ' .. tostring(child.name or child.title) .. ' - ' .. tostring(child.status or 'unknown'))
      table.insert(result_lines, '')
      table.insert(result_lines, '###### Main info')
      vim.list_extend(result_lines, child_main_info_lines(child))
    end
  end
  local latest_command = commands[#commands]
  if latest_command then
    latest_command = latest_command:gsub('%s+%(running%)$', '')
  end
  return {
    header = '##### ' .. name .. ' - ' .. status,
    key = stable_key,
    label = name,
    name = name,
    title = name,
    agent = agent,
    role = first_string_field(item, { 'role' }) or agent,
    skills = string_list(item.skills),
    status = status,
    action = item.currentTool and nested_action(item) or latest_command or nested_action(item),
    children = children,
    active = not nested_terminal_statuses[status:lower()],
    lines = child_buffer_lines(name, main_info, result_lines, status),
  }
end

local function append_nested_child_blocks(lines, children)
  if type(children) ~= 'table' or #children == 0 then
    return
  end
  table.insert(lines, '')
  table.insert(lines, '## Descendants')
  for index, child in ipairs(children) do
    table.insert(lines, '')
    table.insert(lines, '##### Agent ' .. tostring(index) .. '/' .. tostring(#children) .. ': ' .. tostring(child.name or child.title) .. ' - ' .. tostring(child.status or 'unknown'))
    table.insert(lines, '')
    table.insert(lines, '###### Main info')
    vim.list_extend(lines, child_main_info_lines(child))
  end
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
      append_agent_info(lines, item, progress, status, agent)
      append_agent_info(main_info, item, progress, status, agent)
      local task = first_present_field(item, { 'task', 'prompt', 'request' })
      local current_action = current_tool_action(progress, 80)
      if task then
        local task_line = '**Task:** ' .. compact_header_text(task, 160)
        table.insert(lines, task_line)
        table.insert(main_info, task_line)
      end
      local commands = command_summaries(item, progress)
      local latest_command = commands[#commands]
      if latest_command then
        latest_command = latest_command:gsub('%s+%(running%)$', '')
      end
      current_action = current_action or latest_command or (task and compact_header_text(task, 100)) or status
      append_commands(lines, commands)
      append_commands(main_info, commands)
      local progress_lines = {}
      append_progress(progress_lines, progress, { include_recent_output = false, include_recent_tools = #commands == 0 })
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
      local child_key = 'agent-' .. tostring(item.index or index)
      local nested_children = nested_children_from(item, child_key)
      append_nested_child_blocks(result_lines, nested_children)
      table.insert(children, {
        header = header,
        key = child_key,
        label = label,
        name = title,
        title = title,
        agent = agent,
        role = first_string_field(item, { 'role' }) or agent,
        skills = string_list(item.skills or (type(progress) == 'table' and progress.skills)),
        status = status,
        action = current_action,
        children = nested_children,
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
        agent = label,
        status = nil,
        action = 'result',
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
      agent = 'subagent',
      status = 'completed',
      action = 'completed',
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

local apply_permission_actions

local function merge_child_identity(previous, child)
  if not previous then
    return child
  end
  local merged = vim.deepcopy(child)
  local incoming_key = tostring(merged.key or '')
  local previous_key = tostring(previous.request_key or previous.key or '')
  if not (incoming_key:match('^agent%-%d+$') and previous_key:match('^request%-agent%-')) then
    return merged
  end
  for _, field in ipairs({ 'key', 'request_key', 'request_main_info', 'name', 'title', 'label' }) do
    if previous[field] ~= nil then
      merged[field] = vim.deepcopy(previous[field])
    end
  end
  for _, field in ipairs({ 'agent', 'role', 'skills', 'task', 'model', 'thinking' }) do
    if (merged[field] == nil or merged[field] == '' or (type(merged[field]) == 'table' and #merged[field] == 0)) and previous[field] ~= nil then
      merged[field] = vim.deepcopy(previous[field])
    end
  end
  local lines = merged.lines or {}
  local insert_at
  for index, line in ipairs(lines) do
    if tostring(line):match('^## Main info') then
      insert_at = index + 1
      while lines[insert_at] == '' do insert_at = insert_at + 1 end
      break
    end
  end
  if insert_at then
    local existing = '\n' .. table.concat(lines, '\n') .. '\n'
    local missing = {}
    for _, line in ipairs(previous.request_main_info or {}) do
      local label = tostring(line):match('^%*%*([^*]+):%*%*')
      if label and not existing:find('\n**' .. label .. ':**', 1, true) then
        table.insert(missing, line)
      end
    end
    for index = #missing, 1, -1 do
      table.insert(lines, insert_at, missing[index])
    end
    merged.lines = lines
  end
  return merged
end

function M.resolve_children(block, children, buffer_lines)
  if not block then
    return
  end
  local previous_children = block.subagent_children or {}
  block.subagent_children = {}
  if type(children) ~= 'table' or #children == 0 then
    return
  end
  local resolved = {}
  local search_from = 1
  for child_index, child in ipairs(children) do
    child = merge_child_identity(previous_children[child_index], child)
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
  apply_permission_actions(resolved, block.subagent_permission_actions)
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

local function child_identity_keys(child)
  if type(child) ~= 'table' then
    return {}
  end
  local keys = {}
  for _, value in ipairs({ child.key, child.header, child.name, child.title, child.label }) do
    if value ~= nil and value ~= vim.NIL and tostring(value) ~= '' then
      table.insert(keys, tostring(value))
    end
  end
  return keys
end

local function child_matches_view(child, view)
  if type(child) ~= 'table' or not view then
    return false
  end
  if view.child_key and child.key and tostring(view.child_key) == tostring(child.key) then
    return true
  end
  if view.child_header and child.header and tostring(view.child_header) == tostring(child.header) then
    return true
  end
  local title = tostring(view.title or '')
  return title ~= '' and (title == tostring(child.title or '') or title == tostring(child.label or '') or title == tostring(child.name or ''))
end

local function find_child_for_view(children, view)
  for _, child in ipairs(type(children) == 'table' and children or {}) do
    if child_matches_view(child, view) then
      return child
    end
    local nested = find_child_for_view(child.children, view)
    if nested then
      return nested
    end
  end
  return nil
end

local function child_is_active(child)
  if child and child.active ~= nil then
    return child.active == true
  end
  local status = vim.trim(tostring(child and child.status or '')):lower()
  return status == '' or not nested_terminal_statuses[status]
end

local function collect_permission_candidates(children, path, candidates)
  candidates = candidates or {}
  for _, child in ipairs(type(children) == 'table' and children or {}) do
    local child_path = vim.deepcopy(path or {})
    table.insert(child_path, child.header or ('##### ' .. tostring(child.title or child.label or child.name or 'subagent')))
    if child_is_active(child) then
      table.insert(candidates, { child = child, headers = child_path })
    end
    collect_permission_candidates(child.children, child_path, candidates)
  end
  return candidates
end

local function remember_permission_action(block, child, action, permission_id)
  if not (block and child and action and action ~= '') then
    return false
  end
  block.subagent_permission_actions = block.subagent_permission_actions or {}
  local entry = { action = action, permission_id = permission_id and tostring(permission_id) or nil }
  for _, key in ipairs(child_identity_keys(child)) do
    block.subagent_permission_actions[key] = entry
  end
  if child.permission_action ~= action then
    child.permission_previous_action = child.permission_previous_action or child.action
  end
  child.permission_request_id = permission_id and tostring(permission_id) or child.permission_request_id
  child.permission_action = action
  child.action = action
  return true
end

apply_permission_actions = function(children, actions)
  if type(actions) ~= 'table' then
    return
  end
  for _, child in ipairs(type(children) == 'table' and children or {}) do
    for _, key in ipairs(child_identity_keys(child)) do
      local entry = actions[key]
      if entry and entry.action and entry.action ~= '' then
        child.permission_action = entry.action
        child.action = entry.action
        break
      end
    end
    apply_permission_actions(child.children, actions)
  end
end

local function clear_permission_action_from_children(children, permission_id)
  local changed = false
  local target = tostring(permission_id)
  for _, child in ipairs(type(children) == 'table' and children or {}) do
    if tostring(child.permission_request_id or '') == target then
      child.action = child.permission_previous_action or child.status or child.action
      child.permission_action = nil
      child.permission_previous_action = nil
      child.permission_request_id = nil
      changed = true
    end
    changed = clear_permission_action_from_children(child.children, permission_id) or changed
  end
  return changed
end

function M.clear_permission_action(block, permission_id)
  if not (block and permission_id ~= nil) then
    return false
  end
  local removed = false
  local target = tostring(permission_id)
  for key, entry in pairs(block.subagent_permission_actions or {}) do
    if entry and tostring(entry.permission_id or '') == target then
      block.subagent_permission_actions[key] = nil
      removed = true
    end
  end
  return clear_permission_action_from_children(block.subagent_children, permission_id) or removed
end

function M.permission_context_headers(block, permission_id, active_view, action)
  if not block then
    return M.context_headers_from_view(active_view)
  end
  block.subagent_permission_contexts = block.subagent_permission_contexts or {}
  local key = permission_id ~= nil and tostring(permission_id) or nil
  if key and block.subagent_permission_contexts[key] then
    local child = find_child_for_view(block.subagent_children, active_view)
    if action then
      remember_permission_action(block, child, action, permission_id)
    end
    return block.subagent_permission_contexts[key], child
  end

  local headers = M.context_headers_from_view(active_view)
  local child = find_child_for_view(block.subagent_children, active_view)
  if not headers then
    local candidates = collect_permission_candidates(block.subagent_children)
    if #candidates == 0 then
      for _, candidate_child in ipairs(block.subagent_children or {}) do
        table.insert(candidates, { child = candidate_child, headers = { candidate_child.header or '##### subagent' } })
      end
    end

    if #candidates > 0 then
      local cursor = tonumber(block.subagent_permission_context_cursor) or 0
      local candidate = candidates[(cursor % #candidates) + 1]
      block.subagent_permission_context_cursor = cursor + 1
      child = candidate.child
      headers = candidate.headers
    else
      headers = { '##### subagent' }
    end
  end
  if action then
    remember_permission_action(block, child, action, permission_id)
  end
  if key then
    block.subagent_permission_contexts[key] = headers
  end
  return headers, child
end

return M
