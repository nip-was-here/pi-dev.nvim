-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local config = require('pi-dev.config')
local message_content = require('pi-dev.message_content')
local pipeline = require('pi-dev.render_pipeline')
local subagent = require('pi-dev.compat.subagent')
local tool_identity = require('pi-dev.tool_identity')

local M = {}

local normalize_line_endings = pipeline.normalize_line_endings
local fenced_lines = pipeline.fenced_lines

local function content_to_text(content, opts)
  return message_content.render_text(
    content,
    vim.tbl_extend('force', { show_thinking = config.options.ui.render.show_thinking }, opts or {})
  )
end

local function looks_like_diff(text)
  text = tostring(text or '')
  return text:find('\ndiff %-%-git ', 1, false) ~= nil
    or text:find('^diff %-%-git ', 1, false) ~= nil
    or text:find('\n@@ ', 1, true) ~= nil
    or text:find('^@@ ', 1, true) ~= nil
    or text:find('\n%+%+%+ ', 1, false) ~= nil
    or text:find('\n%-%-%- ', 1, false) ~= nil
end

local function diff_fenced_lines(text)
  return fenced_lines('diff', text)
end

local function diff_lines_from_texts(old_text, new_text)
  local body = {}
  for _, line in ipairs(vim.split(normalize_line_endings(old_text), '\n', { plain = true })) do
    table.insert(body, '-' .. line)
  end
  for _, line in ipairs(vim.split(normalize_line_endings(new_text), '\n', { plain = true })) do
    table.insert(body, '+' .. line)
  end
  return diff_fenced_lines(table.concat(body, '\n'))
end

local function tool_path(args)
  return tool_identity.path(args)
end

local function first_bash_arg(args)
  if type(args) ~= 'table' then
    return nil
  end
  for _, field in ipairs({ 'args', 'arguments', 'argv', 'commandArgs', 'command_args' }) do
    local value = args[field]
    if type(value) == 'table' then
      for _, item in ipairs(value) do
        if item ~= nil and item ~= vim.NIL and tostring(item) ~= '' then
          return tostring(item)
        end
      end
    elseif type(value) == 'string' and value ~= '' then
      return value
    end
  end
  return nil
end

local function command_runs_shell_script(command)
  command = tostring(command or '')
  return command:match('%.sh$') ~= nil or command:match('%.sh%s') ~= nil or command:match('%.sh["\']') ~= nil
end

local function bash_summary(args)
  local command = tostring(args.command or '')
  local arg = first_bash_arg(args)
  if arg and arg ~= '' and command_runs_shell_script(command) and not command:find(arg, 1, true) then
    return command .. ' ' .. arg
  end
  return command
end

local pretty_json_lines
local pretty_json_lines_from_text

local function compact_empty_section_line(label)
  return { tostring(label or 'Value') .. ': `empty`' }
end

local function compact_tool_input(tool_name, args)
  if type(args) ~= 'table' then
    local text = normalize_line_endings(args or '')
    if vim.trim(text) == '' then
      return nil, compact_empty_section_line('Input'), false
    end
    return nil, pretty_json_lines_from_text(text) or fenced_lines('', vim.inspect(args)), false
  end

  if subagent.is_tool(tool_name) then
    return subagent.summary(args), nil, false
  end

  local path = tool_path(args)
  if tool_name == 'bash' and args.command then
    local command = tostring(args.command)
    local summary = bash_summary(args)
    return summary, fenced_lines('bash', command), false
  end

  if path then
    local has_detail = type(args.edits) == 'table'
      or args.oldText ~= nil
      or args.old_text ~= nil
      or args.newText ~= nil
      or args.new_text ~= nil
      or args.before ~= nil
      or args.after ~= nil
      or args.content ~= nil
      or args.text ~= nil
      or args.data ~= nil
    return tostring(path), nil, not has_detail
  end

  return nil, nil, false
end

local function tool_args_to_lines(tool_name, args)
  if type(args) ~= 'table' then
    local text = normalize_line_endings(args or '')
    if vim.trim(text) == '' then
      return compact_empty_section_line('Input')
    end
    return pretty_json_lines_from_text(text) or fenced_lines('', vim.inspect(args))
  end

  if next(args) == nil then
    return compact_empty_section_line('Input')
  end

  if type(args.edits) == 'table' then
    local lines = {}
    for index, edit in ipairs(args.edits) do
      local old_text = edit.oldText or edit.old_text or edit.before
      local new_text = edit.newText or edit.new_text or edit.after
      if old_text ~= nil or new_text ~= nil then
        if #lines > 0 and lines[#lines] ~= '' then
          table.insert(lines, '')
        end
        if #args.edits > 1 then
          table.insert(lines, '**Edit ' .. index .. '**')
          table.insert(lines, '')
        end
        vim.list_extend(lines, diff_lines_from_texts(old_text or '', new_text or ''))
      end
    end
    if #lines > 0 then
      return lines
    end
  end

  local old_text = args.oldText or args.old_text or args.before
  local new_text = args.newText or args.new_text or args.after
  if old_text ~= nil or new_text ~= nil then
    return diff_lines_from_texts(old_text or '', new_text or '')
  end

  local diff = args.diff or args.patch
  if type(diff) == 'string' then
    return diff_fenced_lines(diff)
  end

  if tool_name == 'bash' and args.command then
    return fenced_lines('bash', tostring(args.command))
  end

  if subagent.is_tool(tool_name) then
    return subagent.args_to_lines(args)
  end

  if tool_name == 'read' then
    return {}
  end

  if tool_name == 'write' then
    local lines = {}
    local content = args.content or args.text or args.data
    if content ~= nil then
      local text = normalize_line_endings(content)
      if vim.trim(text) == '' then
        return compact_empty_section_line('Input')
      end
      vim.list_extend(lines, pretty_json_lines_from_text(text) or fenced_lines('text', tostring(content), { trim_final_empty = true }))
      return lines
    end
  end

  return pretty_json_lines(args)
end

local function decode_json_text(text)
  text = vim.trim(normalize_line_endings(text))
  if not (text:sub(1, 1) == '{' or text:sub(1, 1) == '[') then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if ok then
    return decoded
  end
  return nil
end

local function is_json_null(value)
  return value == vim.NIL
end

local function json_scalar(value)
  if is_json_null(value) then
    return 'null'
  end
  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return encoded
  end
  return vim.json.encode(tostring(value))
end

local function is_array_table(value)
  if type(value) ~= 'table' then
    return false
  end
  if vim.islist then
    return vim.islist(value)
  end
  local count = 0
  local max_index = 0
  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    max_index = math.max(max_index, key)
  end
  return count > 0 and count == max_index
end

local function pretty_json_value(value, depth)
  depth = depth or 0
  if type(value) ~= 'table' or is_json_null(value) then
    return json_scalar(value)
  end

  local indent = string.rep('  ', depth)
  local child_indent = string.rep('  ', depth + 1)
  if is_array_table(value) then
    if #value == 0 then
      return '[]'
    end
    local items = {}
    for index = 1, #value do
      table.insert(items, child_indent .. pretty_json_value(value[index], depth + 1))
    end
    return '[\n' .. table.concat(items, ',\n') .. '\n' .. indent .. ']'
  end

  local keys = {}
  for key in pairs(value) do
    table.insert(keys, key)
  end
  if #keys == 0 then
    return '{}'
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local fields = {}
  for _, key in ipairs(keys) do
    table.insert(fields, child_indent .. json_scalar(tostring(key)) .. ': ' .. pretty_json_value(value[key], depth + 1))
  end
  return '{\n' .. table.concat(fields, ',\n') .. '\n' .. indent .. '}'
end

pretty_json_lines = function(value)
  return fenced_lines('json', pretty_json_value(value), { trim_final_empty = true })
end

pretty_json_lines_from_text = function(text)
  local decoded = decode_json_text(text)
  if type(decoded) == 'table' then
    return pretty_json_lines(decoded)
  end
  return nil
end

local function strip_permission_system_denials(text)
  local ok, permission_system = pcall(require, 'pi-dev.compat.pi_permission_system')
  if ok and permission_system.strip_denials_with_status then
    return permission_system.strip_denials_with_status(text)
  end
  return vim.trim(tostring(text or '')), false
end

local function readable_bash_result(result, text)
  local lines = {}
  local denied = false
  if type(result) == 'table' and (result.stdout ~= nil or result.stderr ~= nil) then
    local stdout, stdout_denied = strip_permission_system_denials(result.stdout)
    local stderr, stderr_denied = strip_permission_system_denials(result.stderr)
    denied = stdout_denied or stderr_denied
    if result.stdout ~= nil and stdout ~= '' then
      table.insert(lines, '**stdout:**')
      vim.list_extend(lines, pretty_json_lines_from_text(stdout) or fenced_lines('bash', stdout, { trim_final_empty = true }))
    end
    if result.stderr ~= nil and stderr ~= '' then
      if #lines > 0 then
        table.insert(lines, '')
      end
      table.insert(lines, '**stderr:**')
      vim.list_extend(lines, pretty_json_lines_from_text(stderr) or fenced_lines('bash', stderr, { trim_final_empty = true }))
    end
    if #lines > 0 then
      return lines
    end
    if denied then
      return {}
    end
  end
  text, denied = strip_permission_system_denials(text)
  if text and normalize_line_endings(text) ~= '' then
    return pretty_json_lines_from_text(text) or fenced_lines('bash', text, { trim_final_empty = true })
  end
  if denied then
    return {}
  end
  return nil
end

local function readable_tool_result(tool_name, result, args, text, opts)
  opts = opts or {}
  local decoded = decode_json_text(text)
  local source = type(decoded) == 'table' and decoded or (type(result) == 'table' and result or {})
  args = type(args) == 'table' and args or {}

  if tool_name == 'bash' then
    return readable_bash_result(result, text)
  end

  if subagent.is_tool(tool_name) then
    local details = type(result) == 'table' and type(result.details) == 'table' and result.details or nil
    if not details and type(source) == 'table' and type(source.details) == 'table' then
      details = source.details
    end
    local readable = subagent.result_to_lines(details or source, text, {
      lazy_details = opts.lazy_subagent_details == true,
      parent_only = opts.subagent_parent_summary_only == true,
    })
    if readable then
      return readable
    end
    if args.action ~= nil and args.tasks == nil and args.chain == nil and args.task == nil and args.agent == nil then
      if vim.trim(normalize_line_endings(text)) ~= '' then
        return subagent.wrapped_result_lines(text)
      end
      return compact_empty_section_line('Output')
    end
    if opts.subagent_parent_summary_only == true then
      readable = subagent.raw_text_parent_lines(text)
      if readable then
        return readable
      end
    end
    if vim.trim(normalize_line_endings(text)) == '' then
      if type(result) == 'table' and next(result) ~= nil then
        return pretty_json_lines(result)
      end
      return compact_empty_section_line('Output')
    end
    if opts.lazy_subagent_details == true then
      return subagent.lazy_result_placeholder()
    end
    return subagent.wrapped_result_lines(text)
  end

  if tool_name == 'read' then
    local content = source.content or source.text or source.output or text
    if type(content) == 'table' then
      content = content_to_text(content)
    end
    local denied
    content, denied = strip_permission_system_denials(content)
    if content == '' then
      return denied and {} or compact_empty_section_line('Output')
    end
    return pretty_json_lines_from_text(content) or fenced_lines('text', tostring(content or ''), { trim_final_empty = true })
  end

  if tool_name == 'write' then
    local path = source.path or source.file or source.filePath or args.path or args.file or args.filePath
    local bytes = source.bytes or source.bytesWritten or source.size
    local message = path and ('Successfully wrote ' .. tostring(path) .. '.') or 'Write completed.'
    if bytes then
      message = message .. ' ' .. tostring(bytes) .. ' bytes.'
    end
    return { '_' .. message .. '_' }
  end

  if tool_name == 'edit' and looks_like_diff(text) then
    return diff_fenced_lines(text)
  end

  return nil
end

local function result_to_lines(result, tool_name, args, opts)
  opts = opts or {}
  local text = content_to_text(result and result.content or '')
  if text == '' and type(result) == 'table' then
    text = content_to_text(result.output or result.text or result.result or '')
  end
  local denied
  text, denied = strip_permission_system_denials(text)
  local readable = readable_tool_result(tool_name, result, args, text, opts)
  if readable then
    return readable
  end
  if text == '' and type(result) == 'table' then
    for _, field in ipairs({ 'output', 'text', 'result', 'response', 'data' }) do
      if type(result[field]) == 'table' then
        return pretty_json_lines(result[field])
      end
    end
    if result.content == nil and result.stdout == nil and result.stderr == nil and next(result) ~= nil then
      return pretty_json_lines(result)
    end
  end
  if text == '' then
    return denied and {} or compact_empty_section_line('Output')
  end
  if looks_like_diff(text) then
    return diff_fenced_lines(text)
  end
  local pretty = pretty_json_lines_from_text(text)
  if pretty then
    return pretty
  end
  if type(result) == 'table' then
    for _, field in ipairs({ 'output', 'text', 'result', 'response', 'data' }) do
      if type(result[field]) == 'table' then
        return pretty_json_lines(result[field])
      end
    end
    if result.content == nil and result.stdout == nil and result.stderr == nil then
      return pretty_json_lines(result)
    end
  end
  return vim.split(normalize_line_endings(text), '\n', { plain = true })
end


M.path = tool_path
M.compact_input = compact_tool_input
M.args_to_lines = tool_args_to_lines
M.result_to_lines = result_to_lines

return M
