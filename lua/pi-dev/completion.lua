-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local actions = require('pi-dev.actions')
local completion_context = require('pi-dev.completion.context')
local mcp = require('pi-dev.compat.mcp_adapter')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')

local M = {
  commands = nil,
  loading = false,
  pending_callbacks = {},
}

local fallback_commands = actions.fallback_completion_commands()

local function add_command(out, seen, command, source)
  if type(command) ~= 'table' or not command.name or command.name == 'models' then
    return
  end
  if seen[command.name] then
    return
  end
  seen[command.name] = true
  table.insert(out, {
    name = command.name,
    description = command.description or '',
    source = command.source or source or 'pi',
  })
end

local function normalize(commands)
  local out = {}
  local seen = {}
  for _, command in ipairs(commands or {}) do
    add_command(out, seen, command)
  end
  for _, command in ipairs(fallback_commands) do
    add_command(out, seen, command, 'pi-dev')
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

function M.refresh(callback)
  if callback then
    table.insert(M.pending_callbacks, callback)
  end
  if M.loading then
    return
  end
  M.loading = true
  rpc.request({ type = 'get_commands' }, function(response)
    M.loading = false
    if response and response.success and response.data then
      M.commands = normalize(response.data.commands)
    else
      M.commands = normalize({})
    end
    local callbacks = M.pending_callbacks
    M.pending_callbacks = {}
    for _, pending_callback in ipairs(callbacks) do
      pending_callback(M.commands)
    end
  end)
end

local function current_commands()
  return M.commands or normalize({})
end

local function command_item(command, menu)
  return {
    word = '/' .. command.name,
    abbr = '/' .. command.name,
    menu = menu or ('[' .. (command.source or 'pi') .. ']'),
    info = command.description or '',
    kind = 'Command',
  }
end

function M.skill_items(base)
  base = (base or ''):gsub('^/', '')
  local items = {}
  for _, command in ipairs(current_commands()) do
    local name = tostring(command.name or '')
    local is_placeholder = name == 'skill:' and command.source == 'pi-dev'
    if not is_placeholder and name:match('^skill:') and vim.startswith(name, base) then
      table.insert(items, command_item(command, '[skill]'))
    end
  end
  if #items == 0 then
    table.insert(items, command_item({
      name = 'skill:',
      description = M.loading and 'Loading Pi skills from RPC...' or 'Run a Pi skill command; concrete skills appear after RPC discovery',
      source = 'pi-dev',
    }))
  end
  return items
end

function M.items(base)
  base = (base or ''):gsub('^/', '')
  if vim.startswith(base, 'skill:') then
    return M.skill_items(base)
  end
  local items = {}
  for _, command in ipairs(current_commands()) do
    if base == '' or vim.startswith(command.name, base) then
      table.insert(items, command_item(command))
    end
  end
  return items
end

local function glob_escape(text)
  return tostring(text or ''):gsub('([%[%]%*%?%{%,%}])', '\\%1')
end

local function relative_path(path)
  local rel = vim.fn.fnamemodify(path, ':.')
  if rel == '' then
    rel = path
  end
  return rel:gsub('^%./', '')
end

local function path_items(base, opts)
  opts = opts or {}
  local item_prefix = opts.item_prefix or ''
  local prefix = tostring(base or '')
  if item_prefix ~= '' then
    prefix = prefix:gsub('^' .. vim.pesc(item_prefix), '')
  end
  local patterns = {}
  local escaped = glob_escape(prefix)
  if prefix == '' then
    table.insert(patterns, '*')
  else
    table.insert(patterns, escaped .. '*')
    if not prefix:find('/', 1, true) then
      table.insert(patterns, '**/' .. escaped .. '*')
    end
  end

  local seen = {}
  local items = {}
  for _, pattern in ipairs(patterns) do
    for _, path in ipairs(vim.fn.globpath(vim.fn.getcwd(), pattern, false, true) or {}) do
      local rel = relative_path(path)
      if rel ~= '' and not seen[rel] then
        seen[rel] = true
        local is_dir = vim.fn.isdirectory(path) == 1
        local word = item_prefix .. rel .. (is_dir and '/' or '')
        table.insert(items, {
          word = word,
          abbr = word,
          menu = is_dir and '[dir]' or '[file]',
          kind = is_dir and 'Folder' or 'File',
        })
        if #items >= 100 then
          return items
        end
      end
    end
  end
  table.sort(items, function(a, b)
    return a.word < b.word
  end)
  return items
end

function M.file_items(base)
  return path_items(base, { item_prefix = '@' })
end

function M.path_items(base)
  return path_items(base)
end

function M.shell_items(base)
  base = tostring(base or '')
  if base:find('/', 1, true) then
    return M.path_items(base)
  end

  local items = {}
  local seen = {}
  for dir in tostring(vim.env.PATH or ''):gmatch('[^:]+') do
    for _, path in ipairs(vim.fn.globpath(dir, glob_escape(base) .. '*', false, true) or {}) do
      local name = vim.fn.fnamemodify(path, ':t')
      if name ~= '' and not seen[name] and vim.fn.executable(path) == 1 then
        seen[name] = true
        table.insert(items, {
          word = name,
          abbr = name,
          menu = '[cmd]',
          kind = 'Function',
        })
        if #items >= 100 then
          return items
        end
      end
    end
  end
  table.sort(items, function(a, b)
    return a.word < b.word
  end)
  return items
end

function M.mcp_items(base)
  return mcp.server_items(base)
end

local source_items

source_items = {
  ['at-file'] = function(base)
    return M.file_items(base)
  end,
  ['path'] = function(base)
    return M.path_items(base)
  end,
  ['shell-command'] = function(base)
    return M.shell_items(base)
  end,
  ['mcp-server'] = function(base)
    return M.mcp_items(base)
  end,
  ['skill-command'] = function(base)
    return M.skill_items(base)
  end,
  ['slash-command'] = function(base)
    if not M.commands and not M.loading and state.is_job_running() then
      vim.defer_fn(function()
        M.refresh()
      end, 10)
    end
    return M.items(base)
  end,
}

local function complete_context_for_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.fn.col('.') - 1
  return completion_context.parse(line, col)
end

function M.complete(findstart, base)
  local context = complete_context_for_cursor()

  if findstart == 1 then
    M.context = context and context.kind or nil
    M.context_info = context
    return context and context.start_col or -3
  end

  context = context or M.context_info
  local kind = context and context.kind or M.context
  if (not kind or kind == 'slash-command') and tostring(base or ''):sub(1, 1) == '@' then
    kind = 'at-file'
  elseif (not kind or kind == 'slash-command') and tostring(base or ''):gsub('^/', ''):match('^skill:') then
    kind = 'skill-command'
  end
  local source = source_items[kind or 'slash-command'] or source_items['slash-command']
  return source(base)
end

function M.setup_buffer(bufnr)
  _G.pi_dev_nvim_completefunc = function(findstart, base)
    return M.complete(findstart, base)
  end
  vim.bo[bufnr].completefunc = 'v:lua.pi_dev_nvim_completefunc'
  pcall(vim.api.nvim_set_option_value, 'completeopt', 'menu,menuone,noselect', { buf = bufnr })
end

return M
