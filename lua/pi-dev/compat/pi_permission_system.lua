-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local config = require('pi-dev.config')
local format = require('pi-dev.format')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local M = {}

-- Compatibility layer for @gotgenes/pi-permission-system.
--
-- That Pi extension prompts through the generic Pi extension UI protocol:
--   select("Permission Required\n...", { "Yes", session label, "No", "No, provide reason" })
-- and, when the user chooses "No, provide reason", follows up with input(...).
-- Keeping this detection/rendering in a dedicated compat module makes it clear
-- which behavior exists for that external plugin and keeps generic extension UI
-- handling free from plugin-specific string heuristics.
local PLUGIN_NAME = '@gotgenes/pi-permission-system'
local DENY_WITH_REASON = 'No, provide reason'

local pending_denial_reason = false
local pending_permission_id = nil

local function enabled()
  local compat = config.options.compat
  if compat == false then
    return false
  end
  local opts = compat and compat.pi_permission_system
  return not (opts and opts.enable == false)
end

local function should_focus_permission()
  local input_win = state.ui.input_win
  return input_win and vim.api.nvim_win_is_valid(input_win) and vim.api.nvim_get_current_win() == input_win
end

local function labels(options)
  local result = {}
  for _, option in ipairs(options or {}) do
    table.insert(result, tostring(option))
  end
  return result
end

local function has_label(items, label)
  for _, item in ipairs(items) do
    if item == label then
      return true
    end
  end
  return false
end

local function has_session_label(items)
  for _, item in ipairs(items) do
    if item ~= 'Yes' and item ~= 'No' and item ~= DENY_WITH_REASON then
      return true
    end
  end
  return false
end

local function normalize_line_endings(text)
  return tostring(text or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
end

local function title_text(request)
  return normalize_line_endings(request.title or request.message or '')
end

function M.is_permission_select_request(request)
  if type(request) ~= 'table' or request.method ~= 'select' then
    return false
  end

  local option_labels = labels(request.options)
  if not has_label(option_labels, 'Yes') or not has_label(option_labels, 'No') then
    return false
  end

  if has_label(option_labels, DENY_WITH_REASON) and has_session_label(option_labels) then
    return true
  end

  return title_text(request):find('Permission Required', 1, true) ~= nil
end

local function split_title(request)
  local lines = vim.split(title_text(request), '\n', { plain = true })
  local title = lines[1] or 'Permission Required'
  local message = table.concat(vim.list_slice(lines, 2), '\n')
  return title, message
end

local function strip_ansi(text)
  return normalize_line_endings(text):gsub('\27%[[0-9;:]*m', '')
end

local function truncate(text, max_chars)
  text = tostring(text or ''):gsub('%s+', ' ')
  max_chars = max_chars or 96
  if vim.fn.strchars(text) <= max_chars then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(0, max_chars - 3)) .. '...'
end

local function session_pattern(options)
  for _, option in ipairs(options or {}) do
    local text = tostring(option)
    local tool, pattern = text:match('allow ([^%s"]+) "([^"]+)" for this session')
    if tool and pattern then
      return tool, pattern
    end
  end
  return nil, nil
end

local function external_access_context(text)
  text = strip_ansi(text)
  local cwd, path = text:match("outside working directory '([^']+)':%s*(.-)%.%s*Allow")
  if path and vim.trim(path) ~= '' then
    return { cwd = cwd, path = vim.trim(path) }
  end

  path, cwd = text:match("for path '([^']+)' outside working directory '([^']+)'")
  if path and vim.trim(path) ~= '' then
    return { cwd = cwd, path = vim.trim(path) }
  end

  if text:find('external directory access', 1, true) or text:find('outside working directory', 1, true) then
    return {}
  end
  return nil
end

local function external_path_summary(text)
  local context = external_access_context(text)
  if not context then
    return nil
  end
  if context.path and context.path ~= '' then
    return 'External directory access: `' .. truncate(context.path, 70) .. '`'
  end
  return 'External directory access requested'
end

local function permission_summary(request)
  local text = strip_ansi(table.concat({ title_text(request), normalize_line_endings(request.message or '') }, '\n'))

  local external = external_path_summary(text)
  if external then
    return external
  end

  local tool, pattern = session_pattern(request.options)
  if tool and pattern then
    return tostring(tool) .. ' `' .. truncate(pattern, 70) .. '`'
  end

  local bash = M.bash_command_text(text)
  if bash then
    return 'bash `' .. truncate(bash, 80) .. '`'
  end

  local mcp = text:match("requested MCP target '([^']+)'")
  if mcp then
    return 'MCP `' .. truncate(mcp, 80) .. '`'
  end

  local skill = text:match("requested skill '([^']+)'") or text:match("access to skill '([^']+)'")
  if skill then
    return 'skill `' .. truncate(skill, 80) .. '`'
  end

  local path = text:match("requested access to .- via '([^']+)'")
  if path then
    return 'path `' .. truncate(path, 80) .. '`'
  end

  local tool_name = text:match("requested tool '([^']+)'")
  if tool_name then
    return 'tool `' .. truncate(tool_name, 80) .. '`'
  end

  local _, message = split_title(request)
  return truncate(message ~= '' and message or title_text(request), 96)
end

local function permission_answer_summary(option)
  local text = tostring(option or '')
  if text == 'Yes' then
    return 'Yes'
  end
  if text == 'No' then
    return 'No'
  end
  if text == DENY_WITH_REASON then
    return 'No, with reason'
  end
  if text:match('^Yes') and text:lower():find('session', 1, true) then
    return 'Yes, for session'
  end
  return truncate(text, 90)
end

local function denial_reason_summary(reason)
  local text = normalize_line_endings(reason or ''):gsub('%s+', ' ')
  text = vim.trim(text)
  return 'No, with reason: "' .. text:gsub('"', '\\"') .. '"'
end

local function option_label(option)
  return permission_answer_summary(option)
end

local function interaction_width()
  local width = config.options.ui and config.options.ui.width or vim.o.columns
  if state.ui.input_win and vim.api.nvim_win_is_valid(state.ui.input_win) then
    width = format.window_text_width(state.ui.input_win, width)
  end
  return math.max(20, width)
end

local function truncate_code_summary(summary, max_width)
  summary = tostring(summary or '')
  max_width = math.max(1, tonumber(max_width) or 1)
  if vim.fn.strdisplaywidth(summary) <= max_width then
    return summary
  end

  local before, code, after = summary:match('^(.-`)(.-)(`.*)$')
  if before and code and after then
    local fixed_width = vim.fn.strdisplaywidth(before) + vim.fn.strdisplaywidth(after)
    local code_width = max_width - fixed_width
    if code_width >= 4 then
      return before .. format.truncate_display(code, code_width) .. after
    end
  end

  return format.truncate_display(summary, max_width)
end

local function permission_interaction_summary(summary)
  local request_prefix = '**Request:** '
  local width = interaction_width()
  local available = width - vim.fn.strdisplaywidth(request_prefix)
  return truncate_code_summary(summary, math.max(12, available))
end

local function permission_interaction_item_label(option)
  local numbered_prefix_width = vim.fn.strdisplaywidth('- **4.** ')
  local max_width = math.max(8, interaction_width() - numbered_prefix_width)
  return format.truncate_display(option_label(option), max_width)
end

local function fence_for_text(text)
  local longest = 2
  for run in tostring(text or ''):gmatch('`+') do
    longest = math.max(longest, #run)
  end
  return string.rep('`', longest + 1)
end

local function fenced_detail_lines(lang, text)
  local value = normalize_line_endings(text or '')
  local fence = fence_for_text(value)
  local lines = { fence .. (lang or '') }
  vim.list_extend(lines, vim.split(value, '\n', { plain = true }))
  table.insert(lines, fence)
  return lines
end

local function strip_permission_metadata(text)
  text = tostring(text or '')
  text = text:gsub('%s*%([Mm]atched%s+[^)]-%)', '')
  text = text:gsub('%s*%([Ff]ull command:%s*[^)]-%)', '')
  text = text:gsub('%s*%([Ff]ull input:%s*[^)]-%)', '')
  text = text:gsub('%s*%([Ff]ull tool input:%s*[^)]-%)', '')
  return text
end

local function allow_question(text)
  text = normalize_line_endings(text or '')
  local start = text:match('()[Aa]llow ')
  if not start then
    return nil
  end
  local question = vim.trim(text:sub(start):gsub('^allow ', 'Allow '))
  if question == '' then
    return nil
  end
  local end_at = question:find('?', 1, true)
  if end_at then
    question = question:sub(1, end_at)
  end
  return question
end

local function strip_followup(text)
  local question = allow_question(text)
  if question then
    return question
  end
  text = strip_permission_metadata(text):gsub('^%s*[%.,:]%s*', '')
  return vim.trim(text)
end

local function prose_label(text)
  text = vim.trim(tostring(text or ''))
  text = text:gsub('%s+', ' ')
  text = text:gsub('%s+via$', '')
  if text == '' then
    return nil
  end
  if not text:match('[%.%!%?]$') then
    text = text .. '.'
  end
  return text
end

local extract_bash_command_detail

local function append_quoted_detail(lines, prose, value, lang, followup, opts)
  opts = opts or {}
  prose = prose_label(prose)
  followup = strip_followup(followup)
  if opts.omit_value then
    if prose then
      table.insert(lines, prose)
    end
    if followup ~= '' then
      table.insert(lines, followup)
    end
    return
  end
  if prose then
    table.insert(lines, prose)
    table.insert(lines, '')
  end
  vim.list_extend(lines, fenced_detail_lines(lang, value))
  if followup ~= '' then
    table.insert(lines, '')
    table.insert(lines, followup)
  end
end

local function normalize_detail_value(value)
  return vim.trim(normalize_line_endings(value or ''))
end

local function extract_mcp_detail(line)
  return line:match("^(.-requested MCP [^']- )'([^']+)'(.*)$")
end

local function extract_path_detail(line)
  return line:match("^(.-requested access to .- via )'([^']+)'(.*)$")
end

local function is_short_pattern(value)
  value = tostring(value or '')
  return value:find('%*') ~= nil or value:find('...', 1, true) ~= nil
end

local function candidate_matches_short_pattern(pattern, candidate)
  pattern = tostring(pattern or '')
  candidate = tostring(candidate or '')
  local prefix = pattern:match('^(.-)%*') or pattern:match('^(.-)%.%.%.')
  prefix = prefix and vim.trim(prefix) or ''
  return prefix ~= '' and candidate:find(prefix, 1, true) ~= nil
end

local function standalone_detail_candidate(line)
  local text = vim.trim(strip_permission_metadata(normalize_line_endings(line or '')))
  if text == '' then
    return nil
  end
  if text:match('^#+%s+') or text:match('^%*%*.-%*%*$') then
    return nil
  end
  if text:match('^[Aa]llow%s+') or text:match('^[Aa]llow%?') or text:match('^[Aa]llow it%??$') then
    return nil
  end
  local legacy_request_prefix = '^[Cc]urrent ' .. 'agent ' .. 'requested '
  if text:match(legacy_request_prefix) or text:match('^Pi requested ') then
    return nil
  end
  if text:match('^Permission Required') then
    return nil
  end
  return text
end

local function permission_detail_context(message)
  local lines = vim.split(message or '', '\n', { plain = true })
  local bash_values = {}
  local mcp_values = {}
  local path_values = {}
  local standalone = {}

  for _, line in ipairs(lines) do
    local _, bash = extract_bash_command_detail(line)
    if bash and normalize_detail_value(bash) ~= '' then
      table.insert(bash_values, normalize_detail_value(bash))
    end
    local _, mcp = extract_mcp_detail(line)
    if mcp and normalize_detail_value(mcp) ~= '' then
      table.insert(mcp_values, normalize_detail_value(mcp))
    end
    local _, path = extract_path_detail(line)
    if path and normalize_detail_value(path) ~= '' then
      table.insert(path_values, normalize_detail_value(path))
    end
    local candidate = standalone_detail_candidate(line)
    if candidate then
      table.insert(standalone, candidate)
    end
  end

  local function preferred(values)
    for _, candidate in ipairs(standalone) do
      for _, value in ipairs(values) do
        if candidate ~= value and is_short_pattern(value) and candidate_matches_short_pattern(value, candidate) then
          return candidate
        end
      end
    end
    for _, value in ipairs(values) do
      if not is_short_pattern(value) then
        return value
      end
    end
    return values[1]
  end

  return {
    bash = preferred(bash_values),
    mcp = preferred(mcp_values),
    path = preferred(path_values),
  }
end

local function should_skip_duplicate_detail_line(line, context)
  local candidate = standalone_detail_candidate(line)
  if not candidate then
    return false
  end
  return candidate == context.bash or candidate == context.mcp or candidate == context.path
end

function M.bash_command_text(text)
  for _, line in ipairs(vim.split(normalize_line_endings(strip_permission_metadata(text)), '\n', { plain = true })) do
    local value = line:match("requested bash command '(.*)'%s*%.?%s*Allow .*$")
      or line:match('requested bash command%s*:?%s*"(.*)"%s*%.?%s*Allow .*$')
      or line:match('requested bash command%s*:?%s*`(.*)`%s*%.?%s*Allow .*$')
      or line:match("requested bash command '([^']+)'")
      or line:match('requested bash command%s*:?%s*"([^"]+)"')
      or line:match('requested bash command%s*:?%s*`([^`]+)`')
    if value and vim.trim(value) ~= '' then
      return vim.trim(value)
    end
  end
  return nil
end

extract_bash_command_detail = function(line)
  local before, value, after = line:match("^(.-requested bash command )'(.*)'(%s*%.?%s*Allow .*)$")
  if value then
    return before, value, after
  end

  before, value, after = line:match('^(.-requested bash command%s*:?%s*)"(.*)"(%s*%.?%s*Allow .*)$')
  if value then
    return before, value, after
  end

  before, value, after = line:match('^(.-requested bash command%s*:?%s*)`(.*)`(%s*%.?%s*Allow .*)$')
  if value then
    return before, value, after
  end

  before, value, after = line:match("^(.-requested bash command )'([^']+)'(.*)$")
  if value then
    return before, value, after
  end

  before, value, after = line:match('^(.-requested bash command%s*:?%s*)"([^"]+)"(.*)$')
  if value then
    return before, value, after
  end

  before, value, after = line:match('^(.-requested bash command%s*:?%s*)`([^`]+)`(.*)$')
  if value then
    return before, value, after
  end

  before, value, after = line:match('^(.-requested bash command%s*:%s*)(.-)(%s+Allow .*)$')
  if value and vim.trim(value) ~= '' then
    return before, vim.trim(value), after
  end

  return nil, nil, nil
end

local function append_formatted_permission_line(lines, line, context)
  line = normalize_line_endings(line)
  context = context or {}
  if should_skip_duplicate_detail_line(line, context) then
    return
  end

  local before, value, after = extract_bash_command_detail(line)
  if value then
    append_quoted_detail(lines, before, context.bash or value, 'bash', after, { omit_value = context.bash ~= nil })
    return
  end

  before, value, after = extract_mcp_detail(line)
  if value then
    append_quoted_detail(lines, before, context.mcp or value, '', after, { omit_value = context.mcp ~= nil })
    return
  end

  before, value, after = extract_path_detail(line)
  if value then
    append_quoted_detail(lines, before, context.path or value, '', after, { omit_value = context.path ~= nil })
    return
  end

  table.insert(lines, line)
end

local function actor_for_message(message)
  if tostring(message or ''):match('[Cc]urrent%s+agent%s+requested') then
    return 'Current agent'
  end
  return 'Pi'
end

local function bash_essence_detail_lines(message)
  local lines = {
    actor_for_message(message) .. ' requested bash command.',
  }
  local question = allow_question(message) or 'Allow this command?'
  if question ~= '' then
    table.insert(lines, question)
  end
  return lines
end

local function external_essence_detail_lines(message, context)
  context = context or external_access_context(message) or {}
  local lines = {}
  local cwd = context.cwd and vim.trim(context.cwd) or ''
  if cwd ~= '' then
    table.insert(lines, actor_for_message(message) .. ' requested external directory access outside working directory `' .. cwd .. '`.')
  else
    table.insert(lines, actor_for_message(message) .. ' requested external directory access.')
  end
  if context.path and context.path ~= '' then
    table.insert(lines, 'Path: `' .. context.path .. '`')
  end
  local question = allow_question(message) or 'Allow this external directory access?'
  if question ~= '' then
    table.insert(lines, question)
  end
  return lines
end

local function permission_detail_lines(message)
  message = normalize_line_endings(message or '')
  local external = external_access_context(message)
  if external then
    return external_essence_detail_lines(message, external)
  end
  if message:find('requested bash command', 1, true) then
    return bash_essence_detail_lines(message)
  end

  local lines = {}
  local context = permission_detail_context(message)
  for _, line in ipairs(vim.split(message, '\n', { plain = true })) do
    append_formatted_permission_line(lines, line, context)
  end
  return lines
end

function M.detail_lines(request)
  local title, message = split_title(request)
  if request and request.title and request.message and request.message ~= vim.NIL then
    local extra = normalize_line_endings(request.message)
    if extra ~= '' and not title_text(request):find(extra, 1, true) then
      message = message ~= '' and (message .. '\n' .. extra) or extra
    end
  end

  local lines = {
    ('**%s**'):format(title),
  }

  if message ~= '' then
    table.insert(lines, '')
    vim.list_extend(lines, permission_detail_lines(message))
  end

  return lines
end

local function append_permission_request(request, summary)
  renderer.append_permission_request(request.id, summary, M.detail_lines(request), {
    timestamp = request.timestamp or request.createdAt or request.created_at or request.time or request.date,
    scroll_to_bottom_if_unfocused = true,
  })
end

local function append_permission_result(id, text)
  renderer.finish_permission_request(id, text)
end

function M.summary(request)
  return permission_summary(request)
end

function M.request_from_entry(entry)
  if type(entry) ~= 'table' then
    return nil
  end
  local request = entry
  if type(entry.request) == 'table' then
    request = entry.request
  elseif type(entry.event) == 'table' then
    request = entry.event
  elseif type(entry.payload) == 'table' then
    request = entry.payload
  end
  if request.type ~= 'extension_ui_request' and entry.type ~= 'extension_ui_request' then
    return nil
  end
  if request.method ~= 'select' then
    return nil
  end
  if M.is_permission_select_request(request) then
    return request
  end
  local title = tostring(request.title or request.message or '')
  if title:find('Permission Required', 1, true) then
    return request
  end
  return nil
end

function M.request_summary(request)
  local title = tostring(request and (request.title or request.message) or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  local command = M.bash_command_text(title) or title:match("requested bash command '([^']+)'")
  if command and vim.fn.strdisplaywidth(command) <= 80 then
    return 'bash `' .. command:gsub('%s+', ' ') .. '`'
  end
  if M.is_permission_select_request(request) then
    return M.summary(request)
  end
  if command then
    return 'bash `' .. command:gsub('%s+', ' ') .. '`'
  end
  local mcp = title:match("requested MCP target '([^']+)'")
  if mcp then
    return 'MCP `' .. mcp:gsub('%s+', ' ') .. '`'
  end
  local path = title:match("requested access to .- via '([^']+)'")
  if path then
    return 'path `' .. path:gsub('%s+', ' ') .. '`'
  end
  return vim.trim((title:match('\n(.+)$') or title):gsub('%s+', ' '))
end

function M.request_tree_summary(request)
  local title = tostring(request and (request.title or request.message) or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  local command = M.bash_command_text(title) or title:match("requested bash command '([^']+)'")
  if command then
    return 'bash `' .. command:gsub('%s+', ' ') .. '`'
  end
  local mcp = title:match("requested MCP target '([^']+)'")
  if mcp then
    return 'MCP `' .. mcp:gsub('%s+', ' ') .. '`'
  end
  local path = title:match("requested access to .- via '([^']+)'")
  if path then
    return 'path `' .. path:gsub('%s+', ' ') .. '`'
  end
  return M.request_summary(request)
end

local function tool_result_texts(value, out, seen)
  out = out or {}
  seen = seen or {}
  if type(value) == 'string' then
    table.insert(out, value)
  elseif type(value) == 'table' and not seen[value] then
    seen[value] = true
    for _, field in ipairs({ 'stdout', 'stderr', 'output', 'text', 'result', 'response', 'content' }) do
      if value[field] ~= nil and value[field] ~= vim.NIL then
        tool_result_texts(value[field], out, seen)
      end
    end
    if vim.islist and vim.islist(value) then
      for _, item in ipairs(value) do
        tool_result_texts(item, out, seen)
      end
    end
  end
  return out
end

local function tool_result_denial_lines(result)
  local lines = {}
  for _, text in ipairs(tool_result_texts(result)) do
    for _, line in ipairs(vim.split(normalize_line_endings(text), '\n', { plain = true })) do
      if M.is_denial_line(line) then
        table.insert(lines, line)
      end
    end
  end
  return lines
end

local function tool_args_summary(tool_name, args, fallback_line)
  args = type(args) == 'table' and args or {}
  local name = tostring(tool_name or '')
  if name == 'bash' and args.command and args.command ~= '' then
    return 'bash `' .. truncate(args.command, 80) .. '`'
  end
  local path = args.path or args.file or args.filePath or args.file_path
  if path and tostring(path) ~= '' then
    if tostring(fallback_line or ''):find('external directory access', 1, true) then
      return 'External directory access: `' .. truncate(path, 70) .. '`'
    end
    return tostring(name ~= '' and name or 'tool') .. ' `' .. truncate(path, 80) .. '`'
  end
  return 'permission-system block'
end

local function denial_details(kind, data)
  local lines = {}
  if kind == 'auto_rule' then
    table.insert(lines, 'Blocked by permission-system rule.')
    if data.rule and data.rule ~= '' then
      table.insert(lines, 'Rule: `' .. data.rule .. '`')
    end
    if data.tool and data.tool ~= '' then
      table.insert(lines, 'Tool: `' .. data.tool .. '`')
    end
    if data.command and data.command ~= '' then
      table.insert(lines, '')
      table.insert(lines, 'Command:')
      vim.list_extend(lines, fenced_detail_lines(data.tool == 'bash' and 'bash' or '', data.command))
    end
  elseif kind == 'user_denied' then
    table.insert(lines, 'Denied by permission-system response.')
    if data.reason and data.reason ~= '' then
      table.insert(lines, 'Reason: ' .. data.reason)
    end
  else
    table.insert(lines, 'Blocked by permission-system response.')
  end
  return lines
end

local function parse_denial_line(line, tool_name, args)
  local tool, command, rule = line:match("^%[pi%-permission%-system%]%s+is not permitted to run '([^']+)' command '(.*)' %([Mm]atched '([^']+)'%)%.?%s*$")
  if tool and command then
    return {
      title = 'Permission blocked',
      summary = tostring(tool) .. ' `' .. truncate(command, 80) .. '`',
      result = rule and ('rule `' .. rule .. '`') or 'blocked',
      details = denial_details('auto_rule', { tool = tool, command = command, rule = rule }),
      automatic = true,
    }
  end

  command, rule = line:match("^%[pi%-permission%-system%]%s+is not permitted to run .- command '(.*)' %([Mm]atched '([^']+)'%)%.?%s*$")
  if command then
    local name = tostring(tool_name or 'tool')
    return {
      title = 'Permission blocked',
      summary = name .. ' `' .. truncate(command, 80) .. '`',
      result = rule and ('rule `' .. rule .. '`') or 'blocked',
      details = denial_details('auto_rule', { tool = name, command = command, rule = rule }),
      automatic = true,
    }
  end

  command, rule = line:match("^%[pi%-permission%-system%]%s+is not permitted .- '(.*)' %([Mm]atched '([^']+)'%)%.?%s*$")
  if command then
    return {
      title = 'Permission blocked',
      summary = tool_args_summary(tool_name, args, line),
      result = rule and ('rule `' .. rule .. '`') or 'blocked',
      details = denial_details('auto_rule', { tool = tostring(tool_name or 'tool'), command = command, rule = rule }),
      automatic = true,
    }
  end

  local denied_command, reason = line:match("^%[pi%-permission%-system%]%s+User denied bash command '(.*)'%.%s+Reason:%s*(.-)%s*$")
  denied_command = denied_command or line:match("^%[pi%-permission%-system%]%s+User denied bash command '(.*)'%.?%s*$")
  if denied_command then
    local result = reason and reason ~= '' and denial_reason_summary(reason) or 'No'
    return {
      title = 'Permission denied',
      summary = 'bash `' .. truncate(denied_command, 80) .. '`',
      result = result,
      details = denial_details('user_denied', { reason = reason }),
      automatic = false,
    }
  end

  local denied_tool, denied_path = line:match("^%[pi%-permission%-system%]%s+User denied external directory access for tool '([^']+)' path '([^']+)'%.?%s*$")
  if denied_tool and denied_path then
    return {
      title = 'Permission denied',
      summary = 'External directory access: `' .. truncate(denied_path, 70) .. '`',
      result = 'No',
      details = denial_details('user_denied', {}),
      automatic = false,
    }
  end

  if M.is_denial_line(line) then
    return {
      title = line:find('User denied', 1, true) and 'Permission denied' or 'Permission blocked',
      summary = tool_args_summary(tool_name, args, line),
      result = line:find('User denied', 1, true) and 'No' or 'blocked',
      details = denial_details('unknown', {}),
      automatic = line:find('User denied', 1, true) == nil,
    }
  end
  return nil
end

function M.denial_block_from_result(result, tool_name, args)
  for _, line in ipairs(tool_result_denial_lines(result)) do
    local block = parse_denial_line(line, tool_name, args)
    if block then
      return block
    end
  end
  return nil
end

function M.is_denial_line(line)
  return tostring(line or ''):match('^%[pi%-permission%-system%]%s+User denied ') ~= nil
    or tostring(line or ''):match('^%[pi%-permission%-system%]%s+is not permitted ') ~= nil
end

function M.strip_denials_with_status(text)
  local kept = {}
  local stripped = false
  for _, line in ipairs(vim.split(tostring(text or ''), '\n', { plain = true })) do
    if M.is_denial_line(line) then
      stripped = true
    else
      table.insert(kept, line)
    end
  end
  return vim.trim(table.concat(kept, '\n')), stripped
end

function M.strip_denials(text)
  local stripped = M.strip_denials_with_status(text)
  return stripped
end

function M.clear_pending_state()
  pending_denial_reason = false
  pending_permission_id = nil
end

function M.handle_request(request, respond)
  if not enabled() then
    return false
  end

  if M.is_permission_select_request(request) then
    local function show_permission_select(reprompt)
      vim.schedule(function()
        ui.show()
        local summary = permission_summary(request)
        if not reprompt then
          append_permission_request(request, summary)
          renderer.open_last_tool_fold()
        end

        local items = {}
        for _, option in ipairs(request.options or {}) do
          table.insert(items, { label = permission_interaction_item_label(option), value = option })
        end

        ui.show_interaction({
          runtime_key = request.__pi_runtime_key,
          request_id = request.id,
          title = 'Permission Required',
          winbar_title = 'Pi permission',
          kind = 'permission',
          defer_if_busy = true,
          hint = 'j/k move, 1-4/Enter choose, Esc/q re-prompt',
          filetype = 'markdown',
          message = '**Request:** ' .. permission_interaction_summary(summary),
          focus = should_focus_permission(),
          items = items,
          on_submit = function(item)
            if item == nil then
              show_permission_select(true)
              return
            end

            local selected = tostring(item.value)
            pending_denial_reason = selected == DENY_WITH_REASON
            pending_permission_id = pending_denial_reason and request.id or nil
            if pending_denial_reason then
              respond(request.id, { value = item.value })
              return
            end
            renderer.release_forced_tool_fold()
            append_permission_result(request.id, permission_answer_summary(selected))
            respond(request.id, { value = item.value })
          end,
          on_cancel = function()
            pending_denial_reason = false
            pending_permission_id = nil
            show_permission_select(true)
          end,
        })
      end)
    end

    show_permission_select(false)
    return true
  end

  if pending_denial_reason and (request.method == 'input' or request.method == 'editor') then
    local function show_denial_reason(reprompt)
      vim.schedule(function()
        ui.show_text_interaction({
          runtime_key = request.__pi_runtime_key,
          request_id = request.id,
          title = 'Pi permission denial reason',
          winbar_title = 'Pi permission reason',
          defer_if_busy = true,
          hint = '<C-s> / normal <CR> send reason, Esc re-prompt',
          message = title_text(request),
          placeholder = request.placeholder or request.prefill or '',
          on_submit = function(value)
            local permission_id = pending_permission_id or request.id
            pending_denial_reason = false
            pending_permission_id = nil
            renderer.release_forced_tool_fold()
            append_permission_result(permission_id, denial_reason_summary(value))
            respond(request.id, { value = value })
          end,
          on_cancel = function()
            show_denial_reason(true)
          end,
        })
      end)
    end

    show_denial_reason(false)
    return true
  end

  return false
end

return M
