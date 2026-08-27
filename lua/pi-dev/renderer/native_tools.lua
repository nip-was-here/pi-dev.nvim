-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local fmt = require('pi-dev.renderer.tool_format')
local pipeline = require('pi-dev.render_pipeline')

local M = {}

local function normalize_name(tool_name)
  return tostring(tool_name or ''):lower()
end

local native_tools = {
  mcp = true,
  mcpscript = true,
  web_search = true,
  fetch_content = true,
  source_check = true,
  get_search_content = true,
}

function M.is_native(tool_name)
  return native_tools[normalize_name(tool_name)] == true
end

local function compact(value, max_chars)
  return fmt.compact_text(value, max_chars or 120)
end

local function add_line(lines, label, value)
  if value ~= nil and value ~= vim.NIL and tostring(value) ~= '' then
    table.insert(lines, tostring(label) .. ': ' .. tostring(value))
  end
end

local function mcp_target(args)
  args = type(args) == 'table' and args or {}
  if args.tool then
    local target = 'call ' .. compact(args.tool, 80)
    if args.server then
      target = target .. ' @' .. compact(args.server, 48)
    end
    return target
  end
  for _, pair in ipairs({
    { 'search', 'search' },
    { 'describe', 'describe' },
    { 'instructions', 'instructions' },
    { 'connect', 'connect' },
    { 'action', 'action' },
    { 'server', 'server' },
  }) do
    local field, label = pair[1], pair[2]
    if args[field] ~= nil and args[field] ~= vim.NIL and tostring(args[field]) ~= '' then
      local value = compact(args[field], 90)
      if field == 'action' and args.server then
        value = value .. ' ' .. compact(args.server, 64)
      end
      return label .. ' ' .. value
    end
  end
  return 'status'
end

local function mcp_visible_lines(args)
  args = type(args) == 'table' and args or {}
  local lines = {}
  if args.tool then
    add_line(lines, 'target', fmt.inline_code(args.tool))
  end
  if args.server then
    add_line(lines, 'server', fmt.inline_code(args.server))
  end
  if args.action then
    add_line(lines, 'action', fmt.inline_code(args.action))
  end
  if args.search then
    add_line(lines, 'query', fmt.inline_code(compact(args.search, 120)))
  end
  if args.describe then
    add_line(lines, 'describe', fmt.inline_code(compact(args.describe, 120)))
  end
  if args.args ~= nil and args.args ~= vim.NIL then
    add_line(lines, 'args', fmt.json_inline(args.args, 180))
  end
  return lines
end

local function js_string_at(source, start_index)
  local quote = source:sub(start_index, start_index)
  if quote ~= '"' and quote ~= "'" and quote ~= '`' then
    return nil
  end
  local escaped = false
  local out = {}
  local index = start_index + 1
  while index <= #source do
    local char = source:sub(index, index)
    if escaped then
      local replacements = { n = '\n', r = '\r', t = '\t' }
      table.insert(out, replacements[char] or char)
      escaped = false
    elseif char == '\\' then
      escaped = true
    elseif char == quote then
      return table.concat(out)
    else
      table.insert(out, char)
    end
    index = index + 1
  end
  return nil
end

local function first_quoted_field(body, field)
  local start_at = 1
  while true do
    local key_start, key_end = body:find(field .. '%s*:%s*', start_at)
    if not key_start then
      return nil
    end
    local quote_index = key_end + 1
    while quote_index <= #body and body:sub(quote_index, quote_index):match('%s') do
      quote_index = quote_index + 1
    end
    local value = js_string_at(body, quote_index)
    if value then
      return value
    end
    start_at = key_end + 1
  end
end

local function mcp_script_calls(code)
  code = tostring(code or '')
  local calls = {}
  local function append(text)
    if text and text ~= '' then
      table.insert(calls, text)
    end
  end
  for body in code:gmatch('tools%.search%s*%((.-)%)') do
    local query = first_quoted_field(body, 'query')
    append(query and ('search "' .. compact(query, 60) .. '"') or 'search')
  end
  for body in code:gmatch('tools%.describe%s*%((.-)%)') do
    local target = first_quoted_field(body, 'path') or first_quoted_field(body, 'name') or first_quoted_field(body, 'tool')
    append(target and ('describe ' .. compact(target, 80)) or 'describe')
  end
  for _, target in code:gmatch('tools%.call%s*%(%s*(["\'`])([^"\'`]+)%1') do
    append('call ' .. compact(target, 80))
  end
  return calls
end

local function mcp_script_summary(args)
  args = type(args) == 'table' and args or {}
  local calls = mcp_script_calls(args.code)
  if #calls > 0 then
    if #calls == 1 then
      return calls[1]
    end
    return calls[1] .. ' +' .. tostring(#calls - 1) .. ' calls'
  end
  local count = fmt.count_lines(args.code)
  return count > 0 and ('script ' .. tostring(count) .. ' lines') or 'script'
end

local function mcp_script_visible_lines(args)
  args = type(args) == 'table' and args or {}
  local lines = {}
  local count = fmt.count_lines(args.code)
  if count > 0 then
    add_line(lines, 'script', fmt.inline_code(tostring(count) .. ' lines'))
  end
  local calls = mcp_script_calls(args.code)
  if #calls > 0 then
    local visible = {}
    for index = 1, math.min(#calls, 3) do
      table.insert(visible, fmt.inline_code(calls[index]))
    end
    if #calls > 3 then
      table.insert(visible, '+' .. tostring(#calls - 3) .. ' more')
    end
    add_line(lines, 'planned', table.concat(visible, ', '))
  end
  if args.timeoutMs or args.timeout_ms then
    add_line(lines, 'timeout', fmt.inline_code(tostring(args.timeoutMs or args.timeout_ms) .. ' ms'))
  end
  return lines
end

local function one_or_many_summary(args, single_field, list_field, singular, plural)
  args = type(args) == 'table' and args or {}
  local list = fmt.string_list(args[list_field])
  if #list > 0 then
    if #list == 1 then
      return compact(list[1], 100)
    end
    return tostring(#list) .. ' ' .. plural
  end
  local single = args[single_field]
  if single ~= nil and single ~= vim.NIL and tostring(single) ~= '' then
    return compact(single, 100)
  end
  return singular
end

local function search_visible_lines(args)
  args = type(args) == 'table' and args or {}
  local lines = {}
  local queries = fmt.string_list(args.queries)
  if #queries > 0 then
    add_line(lines, 'queries', fmt.list_preview(queries, { max_items = 3, max_chars = 80 }))
  elseif args.query then
    add_line(lines, 'query', fmt.inline_code(compact(args.query, 120)))
  end
  if args.numResults then
    add_line(lines, 'results', fmt.inline_code(tostring(args.numResults) .. ' per query'))
  end
  if args.provider then
    add_line(lines, 'provider', fmt.inline_code(args.provider))
  end
  return lines
end

local function fetch_visible_lines(args)
  args = type(args) == 'table' and args or {}
  local lines = {}
  local urls = fmt.string_list(args.urls)
  if #urls > 0 then
    add_line(lines, 'urls', fmt.list_preview(urls, { max_items = 3, max_chars = 90 }))
  elseif args.url then
    add_line(lines, 'url', fmt.inline_code(compact(args.url, 140)))
  end
  if args.mode then
    add_line(lines, 'mode', fmt.inline_code(args.mode))
  end
  if args.prompt then
    add_line(lines, 'prompt', fmt.inline_code(compact(args.prompt, 120)))
  end
  return lines
end

local function source_visible_lines(args)
  args = type(args) == 'table' and args or {}
  local lines = {}
  if args.claim then
    add_line(lines, 'claim', fmt.inline_code(compact(args.claim, 160)))
  end
  local queries = fmt.string_list(args.queries)
  if #queries > 0 then
    add_line(lines, 'queries', fmt.list_preview(queries, { max_items = 3, max_chars = 80 }))
  end
  if args.numResults then
    add_line(lines, 'results', fmt.inline_code(tostring(args.numResults) .. ' per query'))
  end
  return lines
end

local function stored_content_visible_lines(args)
  args = type(args) == 'table' and args or {}
  local lines = {}
  if args.responseId then
    add_line(lines, 'response', fmt.inline_code(args.responseId))
  end
  if args.url then
    add_line(lines, 'url', fmt.inline_code(compact(args.url, 140)))
  elseif args.query then
    add_line(lines, 'query', fmt.inline_code(compact(args.query, 120)))
  end
  local find = fmt.string_list(args.findText)
  if #find > 0 then
    add_line(lines, 'find', fmt.list_preview(find, { max_items = 3, max_chars = 80 }))
  end
  return lines
end

local function result_text(result)
  if type(result) == 'string' then
    return result
  end
  if type(result) ~= 'table' then
    return ''
  end
  for _, field in ipairs({ 'output', 'text', 'result', 'response', 'data' }) do
    local value = result[field]
    if type(value) == 'string' and vim.trim(value) ~= '' then
      return value
    end
  end
  if type(result.content) == 'table' then
    local parts = {}
    for _, item in ipairs(result.content) do
      if type(item) == 'table' and type(item.text) == 'string' then
        table.insert(parts, item.text)
      elseif type(item) == 'string' then
        table.insert(parts, item)
      end
    end
    return table.concat(parts, '\n')
  end
  return ''
end

local function decoded_result(result)
  local text = vim.trim(pipeline.normalize_line_endings(result_text(result)))
  if text ~= '' and text:match('^[%{%[]') then
    local ok, decoded = pcall(vim.json.decode, text)
    if ok then
      return decoded
    end
  end
  if type(result) == 'table' and result.content == nil then
    return result
  end
  return nil
end

local function result_summary(result)
  local decoded = decoded_result(result)
  local source = type(decoded) == 'table' and decoded or type(result) == 'table' and result or nil
  if type(source) ~= 'table' then
    local lines = fmt.count_lines(result_text(result))
    return lines > 0 and (tostring(lines) .. (lines == 1 and ' line' or ' lines')) or nil
  end
  if source.ok == false or source.success == false then
    return 'error'
  end
  local total = tonumber(source.total or source.count or (type(source.data) == 'table' and (source.data.total or source.data.count) or nil))
  local items = type(source.items) == 'table' and source.items or type(source.data) == 'table' and source.data.items or nil
  if items and #items > 0 then
    return tostring(total or #items) .. ' ' .. ((total or #items) == 1 and 'item' or 'items')
  end
  if total then
    return tostring(total) .. ' ' .. (total == 1 and 'item' or 'items')
  end
  if source.responseId or source.response_id then
    return 'response ' .. tostring(source.responseId or source.response_id)
  end
  local text_lines = fmt.count_lines(result_text(result))
  if text_lines > 0 then
    return tostring(text_lines) .. (text_lines == 1 and ' line' or ' lines')
  end
  return next(source) and 'ok' or nil
end

function M.compact_input(tool_name, args)
  local name = normalize_name(tool_name)
  if not M.is_native(name) or type(args) ~= 'table' then
    return nil, nil, false
  end
  if name == 'mcp' then
    return mcp_target(args), M.args_to_lines(tool_name, args), false
  elseif name == 'mcpscript' then
    return mcp_script_summary(args), M.args_to_lines(tool_name, args), false
  elseif name == 'web_search' then
    return one_or_many_summary(args, 'query', 'queries', 'query', 'queries'), M.args_to_lines(tool_name, args), false
  elseif name == 'fetch_content' then
    return one_or_many_summary(args, 'url', 'urls', 'url', 'urls'), M.args_to_lines(tool_name, args), false
  elseif name == 'source_check' then
    return args.claim and compact(args.claim, 100) or one_or_many_summary(args, 'query', 'queries', 'claim', 'queries'), M.args_to_lines(tool_name, args), false
  elseif name == 'get_search_content' then
    return args.responseId and compact(args.responseId, 100) or 'stored content', M.args_to_lines(tool_name, args), false
  end
  return nil, nil, false
end

function M.visible_summary_lines(tool_name, args, result)
  local name = normalize_name(tool_name)
  if not M.is_native(name) or type(args) ~= 'table' then
    return nil
  end
  local lines
  if name == 'mcp' then
    lines = mcp_visible_lines(args)
  elseif name == 'mcpscript' then
    lines = mcp_script_visible_lines(args)
  elseif name == 'web_search' then
    lines = search_visible_lines(args)
  elseif name == 'fetch_content' then
    lines = fetch_visible_lines(args)
  elseif name == 'source_check' then
    lines = source_visible_lines(args)
  elseif name == 'get_search_content' then
    lines = stored_content_visible_lines(args)
  else
    lines = {}
  end
  local summary = result ~= nil and result_summary(result) or nil
  if summary then
    add_line(lines, name == 'mcpscript' and 'emitted' or 'result', fmt.inline_code(summary))
  end
  return #lines > 0 and lines or nil
end

function M.args_to_lines(tool_name, args)
  local name = normalize_name(tool_name)
  if not M.is_native(name) then
    return nil
  end
  args = type(args) == 'table' and args or {}
  if name == 'mcpscript' then
    local lines = {}
    if args.code ~= nil and args.code ~= vim.NIL and tostring(args.code) ~= '' then
      vim.list_extend(lines, fmt.section('Script', pipeline.fenced_lines('javascript', tostring(args.code), { trim_final_empty = true })))
    end
    local options = vim.deepcopy(args)
    options.code = nil
    if next(options) ~= nil then
      if #lines > 0 then
        table.insert(lines, '')
      end
      vim.list_extend(lines, fmt.section('Options', fmt.json_lines(options)))
    end
    return #lines > 0 and lines or fmt.section('Script', { 'Input: `empty`' })
  end
  local title = name == 'mcp' and 'MCP request' or 'Request'
  return fmt.section(title, fmt.json_lines(args))
end

function M.result_to_lines(tool_name, lines)
  if not M.is_native(tool_name) or type(lines) ~= 'table' or #lines == 0 then
    return lines
  end
  for _, line in ipairs(lines) do
    if tostring(line or ''):match('^%s*#+%s+') then
      return lines
    end
  end
  return fmt.section('Output', lines)
end

return M
