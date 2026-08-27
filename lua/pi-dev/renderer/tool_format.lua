-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local pipeline = require('pi-dev.render_pipeline')

local M = {}

local function normalize_line_endings(text)
  return pipeline.normalize_line_endings(text)
end

function M.inline_code(text)
  text = tostring(text or '')
  if text:find('`', 1, true) then
    return '`` ' .. text .. ' ``'
  end
  return '`' .. text .. '`'
end

function M.compact_text(text, max_chars)
  text = normalize_line_endings(text or ''):gsub('%s+', ' ')
  text = vim.trim(text)
  max_chars = tonumber(max_chars) or 120
  if vim.fn.strchars(text) <= max_chars then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(0, max_chars - 3)) .. '...'
end

function M.first_present(tbl, fields)
  if type(tbl) ~= 'table' then
    return nil
  end
  for _, field in ipairs(fields or {}) do
    local value = tbl[field]
    if value ~= nil and value ~= vim.NIL and value ~= '' then
      return value
    end
  end
  return nil
end

function M.is_array(value)
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

function M.string_list(value)
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

function M.list_preview(values, opts)
  opts = opts or {}
  local max_items = tonumber(opts.max_items) or 3
  local max_chars = tonumber(opts.max_chars) or 80
  local out = {}
  for index, value in ipairs(M.string_list(values)) do
    if index > max_items then
      break
    end
    table.insert(out, M.inline_code(M.compact_text(value, max_chars)))
  end
  local total = #(type(values) == 'table' and values or out)
  if total > max_items then
    table.insert(out, '+' .. tostring(total - max_items) .. ' more')
  end
  return table.concat(out, ', ')
end

function M.count_lines(text)
  text = normalize_line_endings(text or '')
  text = text:gsub('^%s+', ''):gsub('%s+$', '')
  if text == '' then
    return 0
  end
  local count = 1
  for _ in text:gmatch('\n') do
    count = count + 1
  end
  return count
end

function M.json_inline(value, max_chars)
  local ok, encoded = pcall(vim.json.encode, value)
  local text = ok and encoded or vim.inspect(value)
  return M.inline_code(M.compact_text(text, max_chars or 160))
end

function M.json_lines(value)
  local ok, encoded = pcall(vim.json.encode, value)
  return pipeline.fenced_lines('json', ok and encoded or vim.inspect(value), { trim_final_empty = true })
end

function M.section(title, body)
  body = body or {}
  local lines = { '#### ' .. tostring(title or 'Details') }
  if #body > 0 then
    vim.list_extend(lines, body)
  end
  return lines
end

return M
