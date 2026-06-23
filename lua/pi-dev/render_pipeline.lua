-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {}

function M.normalize_line_endings(text)
  return tostring(text or '')
    :gsub('\r\n', '\n')
    :gsub('\r', '\n')
    :gsub('\27%[[0-9;:]*[ -/]*[@-~]', '')
    :gsub('[%z\1-\8\11\12\14-\31\127]', '')
end

function M.is_blank_line(line)
  return tostring(line or ''):match('^%s*$') ~= nil
end

function M.markdown_fence_marker(line)
  local text = tostring(line or '')
  return text:match('^%s*(```+)') or text:match('^%s*(~~~+)')
end

function M.markdown_fence_closes(marker, fence)
  if not marker or not fence then
    return false
  end
  return marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence
end

function M.strip_markdown_quote_markers(line)
  local rest = tostring(line or ''):gsub('^%s*', '')
  local had_quote = false
  while rest:sub(1, 1) == '>' do
    had_quote = true
    rest = rest:sub(2):gsub('^%s*', '')
  end
  return rest, had_quote
end

function M.markdown_quote_line(line, prefix)
  prefix = tostring(prefix or '> ')
  local rest, had_quote = M.strip_markdown_quote_markers(line)
  if had_quote then
    return rest == '' and '>' or ('> ' .. rest)
  end
  return prefix .. tostring(line or '')
end

function M.thinking_quote_line(line)
  local quoted = M.markdown_quote_line(line, '> '):gsub('[ \t]+$', '')
  if quoted:match('^%s*>%s*$') then
    return nil
  end
  return quoted
end

function M.is_thinking_heading_line(line)
  local rest = M.strip_markdown_quote_markers(line)
  rest = rest:gsub('^#+%s*', ''):gsub('^[-*_%s`]+', ''):gsub('[-*_%s`:]+$', ''):lower()
  return rest == 'thinking' or rest == 'reasoning' or rest == 'thoughts'
end

function M.is_section_header_line(line)
  line = tostring(line or '')
  return line:match('^%s*#+%s+') ~= nil or M.is_thinking_heading_line(line)
end

function M.sanitize_lines(lines)
  local sanitized = {}
  for _, line in ipairs(lines or {}) do
    local parts = vim.split(M.normalize_line_endings(line), '\n', { plain = true })
    vim.list_extend(sanitized, parts)
  end
  return sanitized
end

function M.normalize_section_spacing_lines(lines)
  local out = {}
  local index = 1
  local fence = nil
  while index <= #(lines or {}) do
    local line = lines[index]
    local marker = M.markdown_fence_marker(line)
    local in_fence = fence ~= nil
    if in_fence then
      table.insert(out, line)
      if M.markdown_fence_closes(marker, fence) then
        fence = nil
      end
      index = index + 1
    elseif marker then
      fence = marker
      table.insert(out, line)
      index = index + 1
    elseif M.is_section_header_line(line) then
      while #out > 0 and M.is_blank_line(out[#out]) do
        table.remove(out)
      end
      if #out > 0 then
        table.insert(out, '')
      end
      table.insert(out, line)
      index = index + 1
      while index <= #lines and M.is_blank_line(lines[index]) do
        index = index + 1
      end
      if index <= #lines then
        table.insert(out, '')
      end
    else
      table.insert(out, line)
      index = index + 1
    end
  end
  return out
end

function M.prepare_block_lines(lines, opts)
  opts = opts or {}
  if opts.raw_spacing then
    return M.sanitize_lines(lines)
  end
  return M.sanitize_lines(M.normalize_section_spacing_lines(lines))
end

function M.prepare_boundary_lines(lines, previous_line)
  local out = vim.deepcopy(lines or {})
  while #out > 0 and M.is_blank_line(previous_line) and M.is_blank_line(out[1]) do
    table.remove(out, 1)
  end
  if #out > 0 and not M.is_blank_line(previous_line) and not M.is_blank_line(out[1]) then
    table.insert(out, 1, '')
  end
  return out
end

function M.prepare_append_lines(lines, previous_line, opts)
  return M.prepare_boundary_lines(M.prepare_block_lines(lines, opts), previous_line)
end

function M.fence_for_text(text)
  local longest = 2
  for run in tostring(text or ''):gmatch('`+') do
    longest = math.max(longest, #run)
  end
  return string.rep('`', longest + 1)
end

function M.fenced_lines(lang, text, opts)
  opts = opts or {}
  local value = M.normalize_line_endings(text)
  local fence = M.fence_for_text(value)
  local lines = { fence .. (lang or '') }
  local body = vim.split(value, '\n', { plain = true })
  if opts.trim_final_empty and #body > 1 and body[#body] == '' then
    table.remove(body)
  end
  vim.list_extend(lines, body)
  table.insert(lines, fence)
  return lines
end

local function inline_code(text)
  text = tostring(text or '')
  if text:find('`', 1, true) then
    return '`` ' .. text .. ' ``'
  end
  return '`' .. text .. '`'
end

function M.skill_attrs(attr_text)
  local attrs = {}
  attr_text = tostring(attr_text or '')
  for key, value in attr_text:gmatch('([%w_:%-]+)%s*=%s*"([^"]*)"') do
    attrs[key] = value
  end
  for key, value in attr_text:gmatch("([%w_:%-]+)%s*=%s*'([^']*)'") do
    attrs[key] = value
  end
  return attrs
end

local function compact_skill_call_text(name, rest)
  name = vim.trim(tostring(name or ''))
  rest = vim.trim(M.normalize_line_endings(rest or ''))
  local title = name ~= '' and ('**Skill call:** ' .. inline_code(name)) or '**Skill call**'
  if rest == '' then
    return title
  end
  return title .. '\n' .. rest
end

function M.readable_skill_call_text(attr_text, _body, rest)
  local attrs = M.skill_attrs(attr_text)
  return compact_skill_call_text(attrs.name, rest)
end

local function format_xml_skill_calls(text)
  local out = {}
  local offset = 1
  while offset <= #text do
    local start_pos, end_pos, attr_text = text:find('<skill%s+([^>]*)>.-</skill>', offset)
    if not start_pos then
      table.insert(out, text:sub(offset))
      break
    end
    if start_pos > offset then
      table.insert(out, text:sub(offset, start_pos - 1))
    end
    local rest = text:sub(end_pos + 1)
    table.insert(out, M.readable_skill_call_text(attr_text, nil, rest))
    offset = #text + 1
  end
  return table.concat(out)
end

local function format_slash_skill_call(text)
  local name, rest = text:match('^%s*/skill:([^%s]+)%s*(.-)%s*$')
  if name then
    return compact_skill_call_text(name, rest)
  end
  return nil
end

function M.format_user_skill_calls(text)
  text = M.normalize_line_endings(text or '')
  return format_slash_skill_call(text) or format_xml_skill_calls(text)
end

function M.skill_call_label(text)
  text = M.normalize_line_endings(text or '')
  local slash_name, slash_rest = text:match('^%s*/skill:([^%s]+)%s*(.-)%s*$')
  if slash_name then
    local label = 'Skill: ' .. vim.trim(slash_name)
    slash_rest = vim.trim(slash_rest or ''):gsub('%s+', ' ')
    if slash_rest ~= '' then
      label = label .. ' ' .. slash_rest
    end
    return label
  end

  local start_pos, end_pos, attr_text = text:find('^%s*<skill%s+([^>]*)>.-</skill>')
  if not start_pos then
    return nil
  end
  local attrs = M.skill_attrs(attr_text)
  local name = vim.trim(attrs.name or '')
  local label = name ~= '' and ('Skill: ' .. name) or 'Skill call'
  local rest = vim.trim(text:sub(end_pos + 1)):gsub('%s+', ' ')
  if rest ~= '' then
    label = label .. ' ' .. rest
  end
  return label
end

function M.is_pi_update_notice(text)
  local normalized = M.normalize_line_endings(text):lower()
  return normalized:find('pi%s+update') ~= nil
end

function M.notice_lines(text)
  local lines = { '' }
  for _, line in ipairs(vim.split(M.normalize_line_endings(text), '\n', { plain = true })) do
    if line == '' then
      table.insert(lines, '>')
    else
      table.insert(lines, M.markdown_quote_line(line, '> '))
    end
  end
  table.insert(lines, '')
  return lines
end

function M.message_block(title, body_lines)
  local lines = { '', title, '' }
  vim.list_extend(lines, body_lines or {})
  return lines
end

return M
