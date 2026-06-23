-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local pipeline = require('pi-dev.render_pipeline')

local M = {}

local function normalize(text)
  return pipeline.normalize_line_endings(text)
end

local function skip_plain_item_type(item_type)
  return item_type == 'toolCall' or item_type == 'tool_call' or item_type == 'thinking' or item_type == 'reasoning'
end

function M.plain_text(content)
  if type(content) == 'string' then
    return content
  end
  if type(content) ~= 'table' then
    return ''
  end
  local parts = {}
  for _, item in ipairs(content) do
    if type(item) == 'string' then
      table.insert(parts, item)
    elseif type(item) == 'table' then
      local item_type = item.type
      if item_type == 'text' then
        table.insert(parts, item.text or '')
      elseif not skip_plain_item_type(item_type) and type(item.text) == 'string' then
        table.insert(parts, item.text)
      elseif not skip_plain_item_type(item_type) and type(item.content) == 'string' then
        table.insert(parts, item.content)
      end
    end
  end
  return table.concat(parts, '\n')
end

function M.list_label_text(content)
  local text = M.plain_text(content)
  return pipeline.skill_call_label(text) or text
end

function M.assistant_text(message)
  return vim.trim(M.plain_text(message and message.content or ''))
end

function M.has_thinking_item(content)
  if type(content) ~= 'table' then
    return false
  end
  for _, item in ipairs(content) do
    if type(item) == 'table' and (item.type == 'thinking' or item.type == 'reasoning') then
      return true
    end
  end
  return false
end

function M.thinking_blockquote(text)
  local out = { '> Thinking' }
  for _, line in ipairs(vim.split(normalize(text), '\n', { plain = true })) do
    if not pipeline.is_thinking_heading_line(line) then
      local quoted = pipeline.thinking_quote_line(line)
      if quoted then
        table.insert(out, quoted)
      end
    end
  end
  return table.concat(out, '\n')
end

function M.render_text(content, opts)
  opts = opts or {}
  if type(content) == 'string' then
    return normalize(content)
  end
  if type(content) ~= 'table' then
    return normalize(content)
  end

  local parts = {}
  local last_was_thinking = false
  local function append_part(value)
    value = normalize(value or '')
    if value == '' then
      return
    end
    if last_was_thinking then
      table.insert(parts, '')
    end
    table.insert(parts, value)
    last_was_thinking = false
  end

  for _, item in ipairs(content) do
    if type(item) == 'string' then
      append_part(item)
    elseif type(item) == 'table' and item.type == 'text' then
      append_part(item.text or '')
    elseif type(item) == 'table' and (item.type == 'thinking' or item.type == 'reasoning') then
      local thinking = item.thinking or item.reasoning or item.text or item.content or ''
      if thinking ~= '' and opts.show_thinking ~= false then
        table.insert(parts, M.thinking_blockquote(thinking))
        last_was_thinking = true
      end
    elseif type(item) == 'table' and item.type == 'toolCall' then
      if not opts.skip_tool_calls then
        append_part('Tool call: `' .. tostring(item.name or 'tool') .. '`')
      end
    elseif type(item) == 'table' and item.type == 'image' then
      append_part('[image]')
    elseif type(item) == 'table' and item.type ~= 'thinking' and item.type ~= 'reasoning' and (item.text or item.content) then
      append_part(M.render_text(item.text or item.content, opts))
    end
  end
  return table.concat(parts, '\n')
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

function M.top_level_thinking_text(message, opts)
  local thinking = first_present_field(message, { 'thinking', 'reasoning', 'thought', 'thoughts' })
  if thinking == nil and (message and (message.role == 'thinking' or message.role == 'reasoning')) then
    thinking = first_present_field(message, { 'content', 'text', 'summary', 'message' })
  end
  local text
  if type(thinking) == 'table' then
    text = M.render_text(thinking, opts)
  else
    text = normalize(thinking or '')
  end
  return text ~= '' and text or nil
end

function M.message_render_text(message, opts)
  opts = opts or {}
  if not message then
    return ''
  end
  if message.role == 'bashExecution' then
    return string.format('Ran `%s`\n```bash\n%s\n```', message.command or '', message.output or '')
  end
  if message.role == 'compactionSummary' or message.role == 'branchSummary' then
    return message.summary or ''
  end
  if message.role == 'custom' then
    return M.render_text(message.content or '', opts)
  end
  if message.role == 'thinking' or message.role == 'reasoning' then
    if opts.show_thinking == false then
      return ''
    end
    local thinking = M.top_level_thinking_text(message, opts)
    return thinking and M.thinking_blockquote(thinking) or ''
  end
  local text = M.render_text(message.content or '', opts)
  if message.role == 'assistant' and not M.has_thinking_item(message.content) then
    local thinking = M.top_level_thinking_text(message, opts)
    if thinking and opts.show_thinking ~= false then
      text = M.thinking_blockquote(thinking) .. (text ~= '' and ('\n\n' .. text) or '')
    end
  end
  return text
end

return M
