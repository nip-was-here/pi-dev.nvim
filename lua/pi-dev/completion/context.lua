-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {}

local function context(kind, before, start_index)
  if not start_index then
    return nil
  end
  return {
    kind = kind,
    before = before,
    base = before:sub(start_index),
    start_col = start_index - 1,
  }
end

local function mcp_context(before)
  return context('mcp-server', before, before:match('^%s*/[mM][cC][pP]%s+[oO][nN]%s+()%S*$'))
    or context('mcp-server', before, before:match('^%s*/[mM][cC][pP]%s+[oO][nN]%s+()$'))
    or context('mcp-server', before, before:match('^%s*/[mM][cC][pP]%s+[oO][fF][fF]%s+()%S*$'))
    or context('mcp-server', before, before:match('^%s*/[mM][cC][pP]%s+[oO][fF][fF]%s+()$'))
    or context('mcp-server', before, before:match('^%s*/[mM][cC][pP]%-[aA][uU][tT][hH]%s+()%S*$'))
    or context('mcp-server', before, before:match('^%s*/[mM][cC][pP]%-[aA][uU][tT][hH]%s+()$'))
end

local function export_context(before)
  return context('path', before, before:match('^%s*/export%s+()%S*$'))
    or context('path', before, before:match('^%s*/export%s+()$'))
end

local function shell_context(before)
  local shell_text = before:match('^%s*!!?%s*(.*)$')
  if shell_text == nil then
    return nil
  end
  local start_index = before:match('^%s*!!?%s*()%S*$')
    or before:match('^%s*!!?.-%s+()%S*$')
    or before:match('^%s*!!?.-%s+()$')
    or before:match('^%s*!!?%s*()$')
  local kind = shell_text:match('^%S*$') and 'shell-command' or 'path'
  return context(kind, before, start_index)
end

local function slash_context(before)
  return context('slash-command', before, before:match('^%s*()/%S*$'))
end

local function skill_context(before)
  local start_index = before:match('^%s*()/skill:%S*$')
  if start_index then
    return context('skill-command', before, start_index)
  end
  return nil
end

local function at_file_context(before)
  local start_index = before:match('()@%S*$')
  if not start_index then
    return nil
  end
  local previous = start_index > 1 and before:sub(start_index - 1, start_index - 1) or ''
  if previous ~= '' and not previous:match('%s') then
    return nil
  end
  return context('at-file', before, start_index)
end

function M.parse(line, col)
  line = tostring(line or '')
  col = tonumber(col) or #line
  local before = line:sub(1, col)
  return mcp_context(before)
    or export_context(before)
    or skill_context(before)
    or shell_context(before)
    or slash_context(before)
    or at_file_context(before)
end

return M
