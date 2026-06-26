-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local config = require('pi-dev.config')
local format = require('pi-dev.format')
local message_content = require('pi-dev.message_content')
local runtime_select = require('pi-dev.sessions.runtime_select')
local renderer = require('pi-dev.renderer')
local pipeline = require('pi-dev.render_pipeline')
local rpc = require('pi-dev.rpc')
local runtime_status = require('pi-dev.runtime_status')
local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')
local store = require('pi-dev.sessions.store')
local switch_guard = require('pi-dev.sessions.switch_guard')
local tree_graph = require('pi-dev.sessions.tree_graph')
local waiting = require('pi-dev.sessions.waiting')
local ui = require('pi-dev.ui')

local M = {}

local function effective_cwd(cwd)
  return store.normalize_path(config.options.cwd or cwd or state.session.runtime_cwd or store.nvim_cwd())
end

function M.current_cwd()
  return effective_cwd()
end

local function set_runtime_cwd(cwd)
  local normalized = effective_cwd(cwd)
  state.session.runtime_cwd = normalized
  return normalized
end

local session_header_cache = {}

local function session_header_stat_token(path)
  local stat = path and vim.uv.fs_stat(path) or nil
  if not stat then
    return nil
  end
  return table.concat({
    tostring(stat.size or 0),
    tostring(stat.mtime and stat.mtime.sec or 0),
    tostring(stat.mtime and stat.mtime.nsec or 0),
  }, ':')
end

local function read_session_header(path)
  path = store.normalize_path(path)
  if not path or path == '' then
    return nil
  end
  local token = session_header_stat_token(path)
  if not token then
    session_header_cache[path] = nil
    return nil
  end
  local cached = session_header_cache[path]
  if cached and cached.token == token then
    return cached.header
  end
  local header = store.read_json_line(path, 1)
  session_header_cache[path] = { token = token, header = header }
  return header
end

local function text_from_content(content)
  return message_content.plain_text(content)
end

local function list_label_text_from_content(content)
  return message_content.list_label_text(content)
end

local function permission_request_from_entry(entry)
  local ok, permission = pcall(require, 'pi-dev.compat.pi_permission_system')
  if ok and permission.request_from_entry then
    return permission.request_from_entry(entry)
  end
  return nil
end

local function permission_request_summary(request)
  local ok, permission = pcall(require, 'pi-dev.compat.pi_permission_system')
  if ok and permission.request_summary then
    return permission.request_summary(request)
  end
  return ''
end

local function permission_request_tree_summary(request)
  local ok, permission = pcall(require, 'pi-dev.compat.pi_permission_system')
  if ok and permission.request_tree_summary then
    return permission.request_tree_summary(request)
  end
  return permission_request_summary(request)
end

local function compact_branch_title_text(text)
  text = pipeline.normalize_line_endings(text or ''):gsub('%s+', ' ')
  text = vim.trim(text)
  if text == '' then
    return nil
  end
  return text
end

local function branch_title_from_message(message)
  if type(message) ~= 'table' then
    return nil
  end
  local role = message.role
  if role == 'user' then
    return compact_branch_title_text(list_label_text_from_content(message.content))
  end
  if role == 'permission' then
    return compact_branch_title_text('Permission: ' .. tostring(message.content or ''))
  end
  if role == 'custom' or role == 'compactionSummary' or role == 'branchSummary' then
    return compact_branch_title_text(message.summary)
      or compact_branch_title_text(text_from_content(message.content))
      or compact_branch_title_text(message.text)
  end
  return nil
end

local function branch_title_from_messages(messages)
  for index, message in ipairs(messages or {}) do
    local title = branch_title_from_message(message)
    if title then
      return title, message.id or index
    end
  end
  return nil, nil
end

local function user_title_from_message(message)
  if type(message) ~= 'table' or message.role ~= 'user' then
    return nil
  end
  return compact_branch_title_text(list_label_text_from_content(message.content))
end

local function last_user_title_from_messages(messages)
  for index = #(messages or {}), 1, -1 do
    local message = messages[index]
    local title = user_title_from_message(message)
    if title then
      return title, message.id or index
    end
  end
  return nil, nil
end

local function branch_title_from_entry(entry)
  if type(entry) ~= 'table' then
    return nil
  end
  if entry.type == 'message' and type(entry.message) == 'table' then
    return branch_title_from_message(entry.message)
  end
  local request = permission_request_from_entry(entry)
  if request then
    return compact_branch_title_text('Permission: ' .. permission_request_summary(request))
  end
  if entry.type == 'extension_ui_request' or type(entry.request) == 'table' or type(entry.event) == 'table' or type(entry.payload) == 'table' then
    local generic_request = entry.request or entry.event or entry.payload or entry
    local method = generic_request and generic_request.method
    if method == 'confirm' or method == 'select' or method == 'input' or method == 'editor' then
      return compact_branch_title_text('Waiting: ' .. tostring(generic_request.title or generic_request.message or method))
    end
  end
  return nil
end

local function parent_entry_ids_from_file(path)
  return store.parent_entry_ids(path)
end

local function first_title_from_entries(entries, opts)
  opts = opts or {}
  local parent_ids = opts.parent_ids
  if parent_ids and next(parent_ids) ~= nil then
    for _, entry in ipairs(entries or {}) do
      if entry.id ~= nil and entry.id ~= '' and not parent_ids[tostring(entry.id)] then
        local title = branch_title_from_entry(entry)
        if title then
          return title, entry.id
        end
      end
    end
    return nil
  end

  for _, entry in ipairs(entries or {}) do
    local title = branch_title_from_entry(entry)
    if title then
      return title, entry and entry.id
    end
  end
  return nil
end

local function user_title_from_entry(entry)
  if type(entry) == 'table' and entry.type == 'message' and type(entry.message) == 'table' then
    return user_title_from_message(entry.message)
  end
  return nil
end

local function last_user_title_from_entries(entries, opts)
  opts = opts or {}
  local parent_ids = opts.parent_ids
  if parent_ids and next(parent_ids) ~= nil then
    for index = #(entries or {}), 1, -1 do
      local entry = entries[index]
      if entry and entry.id ~= nil and entry.id ~= '' and not parent_ids[tostring(entry.id)] then
        local title = user_title_from_entry(entry)
        if title then
          return title, entry.id
        end
      end
    end
  end

  for index = #(entries or {}), 1, -1 do
    local entry = entries[index]
    local title = user_title_from_entry(entry)
    if title then
      return title, entry and entry.id
    end
  end
  return nil
end

local function read_title_session_entries(path)
  path = store.normalize_path(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil, {}
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, {}
  end
  local header
  local entries = {}
  for _, line in ipairs(lines or {}) do
    local ok_json, entry = pcall(vim.json.decode, line)
    if ok_json and type(entry) == 'table' then
      if entry.type == 'session' then
        header = entry
      elseif entry.id then
        table.insert(entries, entry)
      end
    end
  end
  return header, entries
end

local function title_root_session_file(path)
  path = store.normalize_path(path)
  local seen = {}
  while path and path ~= '' and not seen[path] and vim.fn.filereadable(path) == 1 do
    seen[path] = true
    local header = read_session_header(path)
    local parent = header and store.normalize_path(header.parentSession) or nil
    if not parent or parent == '' then
      return path
    end
    path = parent
  end
  return path
end

local function title_session_reaches_root(path, root, headers)
  path = store.normalize_path(path)
  root = store.normalize_path(root)
  local seen = {}
  while path and path ~= '' and not seen[path] do
    if path == root then
      return true
    end
    seen[path] = true
    local header = headers and headers[path] or read_session_header(path)
    path = header and store.normalize_path(header.parentSession) or nil
  end
  return false
end

local function title_entries_share_id(entries, ids)
  if not ids or not next(ids) then
    return false
  end
  for _, entry in ipairs(entries or {}) do
    if entry.id and ids[tostring(entry.id)] then
      return true
    end
  end
  return false
end

local function latest_tree_branch_title_from_entries(path, current_entries, parent_ids)
  path = store.normalize_path(path)
  if not path then
    return nil
  end
  local root = title_root_session_file(path)
  if not root or root == '' then
    return nil
  end
  local root_header, root_entries = read_title_session_entries(root)
  if not root_header then
    return nil
  end
  local root_ids = {}
  for _, entry in ipairs(root_entries or {}) do
    if entry.id then
      root_ids[tostring(entry.id)] = true
    end
  end

  local candidates = {}
  local seen_candidates = {}
  local function add_candidate(candidate)
    candidate = store.normalize_path(candidate)
    if candidate and not seen_candidates[candidate] and vim.fn.filereadable(candidate) == 1 then
      seen_candidates[candidate] = true
      table.insert(candidates, candidate)
    end
  end
  add_candidate(root)
  local dir = vim.fn.fnamemodify(root, ':h')
  for _, candidate in ipairs(vim.fn.globpath(dir, '*.jsonl', false, true) or {}) do
    add_candidate(candidate)
  end
  add_candidate(path)

  local headers = {}
  local loaded = {}
  for _, candidate in ipairs(candidates) do
    local header, entries = read_title_session_entries(candidate)
    if header then
      headers[candidate] = header
      loaded[candidate] = entries
    end
  end

  local by_id = {}
  local current_by_id = {}
  local current_ids = {}
  local user_children_by_parent = {}
  local seen_user_child_ids = {}
  for candidate, entries in pairs(loaded) do
    if candidate == root or candidate == path or title_session_reaches_root(candidate, root, headers) or title_entries_share_id(entries, root_ids) then
      for _, entry in ipairs(entries or {}) do
        if entry.id then
          local id = tostring(entry.id)
          by_id[id] = by_id[id] or entry
          if candidate == path then
            current_by_id[id] = entry
            current_ids[id] = true
          end
          if user_title_from_entry(entry) and not seen_user_child_ids[id] then
            seen_user_child_ids[id] = true
            local parent = tostring(entry.parentId or '')
            user_children_by_parent[parent] = (user_children_by_parent[parent] or 0) + 1
          end
        end
      end
    end
  end

  local latest
  for _, entry in ipairs(current_entries or {}) do
    if entry.id then
      latest = entry
    end
  end
  if not latest or not latest.id then
    return nil
  end

  local chain = {}
  local seen_chain = {}
  local current = current_by_id[tostring(latest.id)] or latest
  while current and current.id and not seen_chain[tostring(current.id)] do
    local id = tostring(current.id)
    seen_chain[id] = true
    table.insert(chain, 1, current)
    current = current.parentId and (current_by_id[tostring(current.parentId)] or by_id[tostring(current.parentId)]) or nil
  end

  local latest_title
  local latest_title_id
  for _, entry in ipairs(chain) do
    local id = entry.id and tostring(entry.id) or nil
    local parent = tostring(entry.parentId or '')
    if id and current_ids[id] and (not parent_ids or not parent_ids[id]) and (user_children_by_parent[parent] or 0) > 1 then
      local title = user_title_from_entry(entry)
      if title then
        latest_title = title
        latest_title_id = entry.id
      end
    end
  end
  return latest_title, latest_title_id
end

local function branch_title_context_from_entries(entries, path)
  local header = nil
  for _, entry in ipairs(entries or {}) do
    if type(entry) == 'table' and entry.type == 'session' then
      header = entry
      break
    end
  end
  local parent_ids = header and parent_entry_ids_from_file(header.parentSession) or nil
  local tree_title, tree_title_id = latest_tree_branch_title_from_entries(path, entries, parent_ids)
  local first_title, first_title_id = first_title_from_entries(entries, { parent_ids = parent_ids })
  local last_user_title, last_user_id = last_user_title_from_entries(entries, { parent_ids = parent_ids })
  local branch_title = tree_title or first_title
  local branch_title_id = tree_title_id or first_title_id
  return {
    parent_ids = parent_ids,
    first_title = branch_title,
    first_title_id = branch_title_id,
    last_user_title = last_user_title,
    last_user_id = last_user_id,
    last_user_distinct = last_user_id ~= nil and branch_title_id ~= nil and tostring(last_user_id) ~= tostring(branch_title_id),
  }
end

local function session_render_options(render_opts)
  local opts = config.options.session_render or {}
  local override = render_opts and render_opts.session_render
  if type(override) ~= 'table' then
    return opts
  end

  local merged = vim.tbl_deep_extend('force', vim.deepcopy(opts), override)
  for _, key in ipairs({ 'max_messages', 'max_text_chars' }) do
    local base_value = tonumber(opts[key])
    local override_value = tonumber(override[key])
    if base_value and base_value > 0 and override_value and override_value > 0 then
      merged[key] = math.min(base_value, override_value)
    end
  end
  if opts.include_tool_results == false then
    merged.include_tool_results = false
  end
  return merged
end

local function tree_branch_render_options()
  local tree = config.options.tree or {}
  if type(tree.branch_render) == 'table' then
    return tree.branch_render
  end
  return nil
end

local function open_markdown_fence(text)
  local fence = nil
  for _, line in ipairs(vim.split(pipeline.normalize_line_endings(text), '\n', { plain = true })) do
    local marker = pipeline.markdown_fence_marker(line)
    if fence then
      if pipeline.markdown_fence_closes(marker, fence) then
        fence = nil
      end
    elseif marker then
      fence = marker
    end
  end
  return fence
end

local function truncate_text(text, render_opts)
  if type(text) ~= 'string' then
    return text
  end
  local ok_chars, char_count = pcall(vim.fn.strchars, text)
  if not ok_chars then
    return '[non-text tool result]'
  end
  local opts = session_render_options(render_opts)
  local max_chars = opts and opts.max_text_chars
  if type(max_chars) == 'number' and max_chars > 0 and char_count > max_chars then
    local ok_part, truncated = pcall(vim.fn.strcharpart, text, 0, math.max(0, max_chars - 3))
    if not ok_part then
      return text
    end
    local fence = open_markdown_fence(truncated)
    if fence then
      return truncated .. '\n...\n' .. fence
    end
    return truncated .. '\n...'
  end
  return text
end

local function normalize_message(message, render_opts)
  if type(message) ~= 'table' then
    return message
  end
  local copy = vim.deepcopy(message)
  if type(copy.content) == 'string' then
    copy.content = truncate_text(copy.content, render_opts)
  elseif type(copy.content) == 'table' then
    for _, item in ipairs(copy.content) do
      if type(item) == 'table' and item.text then
        item.text = truncate_text(item.text, render_opts)
      elseif type(item) == 'table' and item.thinking then
        item.thinking = truncate_text(item.thinking, render_opts)
      end
    end
  end
  return copy
end

local function tool_call_item_id(item)
  if type(item) ~= 'table' then
    return nil
  end
  local id = item.id or item.toolCallId or item.tool_call_id or item.callId or item.toolUseId or item.tool_use_id
  return id ~= nil and id ~= '' and tostring(id) or nil
end

local function tool_result_message_id(message)
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

local function timestamp_milliseconds(value)
  if type(value) == 'number' then
    if value > 100000000000 then
      return math.floor(value + 0.5)
    end
    return math.floor(value * 1000 + 0.5)
  end
  if type(value) ~= 'string' then
    return nil
  end
  local seconds = format.timestamp_seconds(value)
  if not seconds then
    return nil
  end
  local fraction = value:match('[T%s]%d%d:%d%d:%d%d%.(%d+)')
  local fraction_ms = 0
  if fraction and fraction ~= '' then
    local trimmed = fraction:sub(1, 3)
    fraction_ms = tonumber(trimmed .. string.rep('0', 3 - #trimmed)) or 0
  end
  return seconds * 1000 + fraction_ms
end

local function message_timestamp_value(message)
  if type(message) ~= 'table' then
    return nil
  end
  local value = message.__pi_timestamp
    or message.timestamp
    or message.createdAt
    or message.created_at
    or message.time
    or message.date
  return value ~= vim.NIL and value or nil
end

local function explicit_duration_milliseconds(message)
  for _, field in ipairs({ 'durationMs', 'duration_ms', 'elapsedMs', 'elapsed_ms', 'executionTimeMs', 'execution_time_ms' }) do
    local value = tonumber(message and message[field])
    if value and value >= 0 then
      return value
    end
  end
  for _, field in ipairs({ 'durationSeconds', 'duration_seconds', 'elapsedSeconds', 'elapsed_seconds' }) do
    local value = tonumber(message and message[field])
    if value and value >= 0 then
      return value * 1000
    end
  end
  return nil
end

local function annotate_tool_call_durations(raw_messages)
  local pending = {}
  for _, message in ipairs(raw_messages or {}) do
    if type(message) == 'table' and message.role == 'assistant' and type(message.content) == 'table' then
      local started_at = message_timestamp_value(message)
      local ordinal = 0
      for _, item in ipairs(message.content) do
        if is_tool_call_item(item) then
          ordinal = ordinal + 1
          table.insert(pending, {
            item = item,
            key = tool_call_item_id(item),
            ordinal = ordinal,
            started_at = started_at,
          })
        end
      end
    elseif type(message) == 'table' and message.role == 'toolResult' then
      local key = tool_result_message_id(message)
      local pending_index
      if key then
        for index, candidate in ipairs(pending) do
          if candidate.key == key then
            pending_index = index
            break
          end
        end
      end
      pending_index = pending_index or (#pending > 0 and 1 or nil)
      local target = pending_index and table.remove(pending, pending_index) or nil
      if target and type(target.item) == 'table' then
        local finished_at = message_timestamp_value(message)
        local duration = explicit_duration_milliseconds(message)
        local started_ms = timestamp_milliseconds(target.started_at)
        local finished_ms = timestamp_milliseconds(finished_at)
        if not duration and started_ms and finished_ms and finished_ms >= started_ms then
          duration = finished_ms - started_ms
        end
        target.item.__pi_started_at = target.item.__pi_started_at or target.started_at
        target.item.__pi_finished_at = target.item.__pi_finished_at or finished_at
        if duration and duration >= 0 then
          target.item.durationMs = target.item.durationMs or duration
        end
      end
    end
  end
  return raw_messages
end

local function limit_render_messages(raw_messages, render_opts)
  raw_messages = annotate_tool_call_durations(raw_messages)
  local opts = session_render_options(render_opts)
  local max_config = opts.max_messages
  local numeric_max = tonumber(max_config)
  local unlimited = max_config == false or numeric_max == 0
  local max_messages = nil
  if not unlimited then
    max_messages = math.max(1, numeric_max or 200)
  end
  local include_tool_results = opts.include_tool_results == true
  local messages = {}
  local total = 0
  for _, message in ipairs(raw_messages or {}) do
    total = total + 1
    if include_tool_results or message.role ~= 'toolResult' then
      table.insert(messages, normalize_message(message, render_opts))
      if max_messages and #messages > max_messages then
        table.remove(messages, 1)
      end
    end
  end
  return messages, total
end

local function message_timestamp_from_entry(entry)
  if type(entry) ~= 'table' then
    return nil
  end
  local message = type(entry.message) == 'table' and entry.message or {}
  local value = entry.timestamp
    or entry.createdAt
    or entry.created_at
    or entry.time
    or entry.date
    or message.timestamp
    or message.createdAt
    or message.created_at
  if value == vim.NIL or value == '' then
    return nil
  end
  return value
end

local function load_messages_from_file(path, opts)
  opts = opts or {}
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return {}, 0
  end
  local entries = {}
  for _, line in ipairs(lines or {}) do
    local ok_json, entry = pcall(vim.json.decode, line)
    if ok_json and type(entry) == 'table' then
      table.insert(entries, entry)
    end
  end
  local last_entry = entries[#entries]
  local raw_messages = {}
  for _, entry in ipairs(entries) do
    if entry.type == 'message' and entry.message then
      local message = vim.deepcopy(entry.message)
      message.__pi_timestamp = message_timestamp_from_entry(entry)
      table.insert(raw_messages, message)
    elseif entry == last_entry and permission_request_from_entry(entry) then
      local request = permission_request_from_entry(entry)
      local request_id = request and request.id or entry.id
      local skip_id = opts.skip_terminal_permission_id
      local skip_permission = opts.skip_terminal_permission == true
        or (skip_id ~= nil and request_id ~= nil and tostring(skip_id) == tostring(request_id))
      if not skip_permission then
        local detail_lines
        local ok_permission, permission = pcall(require, 'pi-dev.compat.pi_permission_system')
        if ok_permission and permission.detail_lines then
          detail_lines = permission.detail_lines(request)
        end
        table.insert(raw_messages, {
          role = 'permission',
          content = permission_request_summary(request),
          __pi_permission_details = detail_lines,
          __pi_timestamp = message_timestamp_from_entry(entry),
        })
      end
    end
  end
  local messages, total = limit_render_messages(raw_messages, opts)
  local title_context = branch_title_context_from_entries(entries, path)
  return messages, total, title_context.first_title, title_context.last_user_title, title_context.last_user_distinct
end

local function session_name_from_file(path)
  local explicit_name
  local entries = {}
  local ok, lines = pcall(vim.fn.readfile, path, '', 160)
  if not ok then
    return vim.fn.fnamemodify(path, ':t')
  end
  for _, line in ipairs(lines or {}) do
    local ok_json, entry = pcall(vim.json.decode, line)
    if ok_json and entry then
      if entry.type == 'session_info' and entry.name and entry.name ~= '' then
        explicit_name = entry.name
      end
      table.insert(entries, entry)
    end
  end
  local title_context = branch_title_context_from_entries(entries, path)
  local name = explicit_name or title_context.first_title
  if not name or name == '' then
    name = vim.fn.fnamemodify(path, ':t')
  end
  return name:gsub('\n.*$', '')
end

local root_session_file

local function resume_root_name_from_file(path)
  path = store.normalize_path(path)
  if not path or path == '' then
    return 'Pi session'
  end
  local ok, lines = pcall(vim.fn.readfile, path, '', 160)
  if not ok then
    return vim.fn.fnamemodify(path, ':t')
  end
  local first_user
  for _, line in ipairs(lines or {}) do
    local ok_json, entry = pcall(vim.json.decode, line)
    if ok_json and type(entry) == 'table' then
      if entry.type == 'session_info' and entry.name and entry.name ~= '' then
        return tostring(entry.name):gsub('\n.*$', '')
      end
      if not first_user and entry.type == 'message' and type(entry.message) == 'table' and entry.message.role == 'user' then
        first_user = compact_branch_title_text(list_label_text_from_content(entry.message.content))
      end
    end
  end
  return (first_user and first_user:gsub('\n.*$', '')) or vim.fn.fnamemodify(path, ':t')
end

local function strip_generic_session_label(label)
  label = vim.trim(tostring(label or '')):gsub('\r\n', '\n'):gsub('\r', '\n'):gsub('\n.*$', '')
  if label == '' then
    return nil
  end
  local session_name = label:match('^Pi%.dev session:%s*(.+)$')
  if session_name and vim.trim(session_name) ~= '' then
    return vim.trim(session_name)
  end
  if label == 'Pi.dev session' or label == 'Pi.dev reloaded session' or label == 'Pi.dev forked session' then
    return nil
  end
  return label
end

local function session_title_width()
  local fallback_width = config.options.ui and config.options.ui.width or vim.o.columns
  return math.max(1, format.window_text_width(state.ui.output_win, fallback_width) - 4)
end

local function session_title_from_summary(summary)
  local prefix = 'Pi.dev session: '
  return format.prefixed_line(prefix, compact_branch_title_text(summary) or 'current session', '', session_title_width())
end

local function root_session_title(path, fallback_name)
  local root = store.normalize_path(root_session_file and root_session_file(path) or path)
  local name = fallback_name
  if (not name or vim.trim(tostring(name)) == '') and root and root ~= '' and vim.fn.filereadable(root) == 1 then
    name = session_name_from_file(root)
  end
  name = vim.trim(tostring(name or ''))
  if name == '' then
    name = root and vim.fn.fnamemodify(root, ':t') or 'current session'
  end
  return session_title_from_summary(name:gsub('\n.*$', ''))
end

local function session_display_title(title, path, branch_title)
  if compact_branch_title_text(branch_title) then
    return session_title_from_summary(branch_title)
  end
  local label = vim.trim(tostring(title or ''))
  local explicit_name = label:match('^Pi%.dev session:%s*(.+)$')
  if explicit_name or label == '' or label == 'Pi.dev session' or label == 'Pi.dev reloaded session' or label == 'Pi.dev forked session' then
    return root_session_title(path or state.session.current_file or state.session.tree_root_file, explicit_name)
  end
  return title
end

local function runtime_display_name(runtime)
  local label = strip_generic_session_label(runtime and runtime.label)
  if label then
    return session_display_title('Pi.dev session: ' .. label, (runtime and (runtime.branch_root or runtime.session_file)) or nil)
  end
  if runtime and runtime.session_file and runtime.session_file ~= '' then
    return root_session_title(runtime.branch_root or runtime.session_file)
  end
  return runtime and (runtime.key or 'Pi runtime') or 'Pi runtime'
end

local function is_internal_run_session(path)
  path = tostring(path or ''):gsub('\\', '/')
  return path:match('/run%-%d+/session%.jsonl$') ~= nil
end

local function visible_user_session(path, header, cwd)
  return header
    and header.type == 'session'
    and store.normalize_path(header.cwd) == cwd
    and not is_internal_run_session(path)
    and not store.is_trash_path(path)
end

function M.list(cwd)
  cwd = store.normalize_path(cwd or effective_cwd())
  local root = store.root()
  local paths = vim.fn.globpath(root, '**/*.jsonl', false, true)
  local sessions = {}
  for _, path in ipairs(paths or {}) do
    local header = read_session_header(path)
    if visible_user_session(path, header, cwd) then
      table.insert(sessions, {
        path = path,
        cwd = cwd,
        id = header.id,
        parent_session = store.normalize_path(header.parentSession),
        mtime = store.stat_mtime(path),
        activity_time = store.activity_time(path),
        name = session_name_from_file(path),
      })
    end
  end
  table.sort(sessions, function(a, b)
    return (a.activity_time or a.mtime or 0) > (b.activity_time or b.mtime or 0)
  end)
  return sessions
end

function M.latest(cwd)
  cwd = store.normalize_path(cwd or effective_cwd())
  local root = store.root()
  local latest
  for _, path in ipairs(vim.fn.globpath(root, '**/*.jsonl', false, true) or {}) do
    local header = read_session_header(path)
    if visible_user_session(path, header, cwd) then
      local activity_time = store.activity_time(path)
      local candidate = {
        path = path,
        cwd = cwd,
        id = header.id,
        parent_session = store.normalize_path(header.parentSession),
        mtime = store.stat_mtime(path),
        activity_time = activity_time,
      }
      if not latest or (activity_time or candidate.mtime or 0) > (latest.activity_time or latest.mtime or 0) then
        latest = candidate
      end
    end
  end
  if latest then
    latest.name = session_name_from_file(latest.path)
  end
  return latest
end

local function session_time_label(session)
  return format.human_time_from_epoch(session and session.activity_time or 0)
end

local function resume_label_width()
  local win = vim.api.nvim_get_current_win()
  local width = format.window_text_width(win)
  if width < 20 then
    width = math.max(1, vim.o.columns - (vim.o.number and vim.o.numberwidth or 0))
  end
  return math.max(1, width - 6)
end

local function resume_row_label(prefix, body, suffix, time_label, max_width)
  max_width = math.max(1, tonumber(max_width) or resume_label_width())
  local suffix_parts = {}
  if suffix and suffix ~= '' then
    table.insert(suffix_parts, tostring(suffix))
  end
  if time_label and time_label ~= '' then
    table.insert(suffix_parts, 'Last: ' .. tostring(time_label))
  end
  return format.prefixed_line(tostring(prefix or ''), tostring(body or ''), table.concat(suffix_parts, ' '), max_width)
end

local function list_resume_roots(cwd)
  cwd = store.normalize_path(cwd or effective_cwd())
  local roots = {}
  local ordered = {}
  for _, path in ipairs(vim.fn.globpath(store.root(), '**/*.jsonl', false, true) or {}) do
    local header = read_session_header(path)
    if visible_user_session(path, header, cwd) then
      path = store.normalize_path(path)
      local root_path = store.normalize_path(root_session_file and root_session_file(path) or path) or path
      local activity_time = store.activity_time(path)
      local session = {
        path = path,
        cwd = cwd,
        id = header.id,
        parent_session = store.normalize_path(header.parentSession),
        mtime = store.stat_mtime(path),
        activity_time = activity_time,
      }
      local root = roots[root_path]
      if not root then
        root = {
          root_path = root_path,
          sessions = {},
          branch_count = 0,
          activity_time = 0,
        }
        roots[root_path] = root
        table.insert(ordered, root)
      end
      table.insert(root.sessions, session)
      if path ~= root_path then
        root.branch_count = root.branch_count + 1
      end
      if path == root_path then
        root.root_session = session
      end
      if not root.latest or (activity_time or session.mtime or 0) > (root.latest.activity_time or root.latest.mtime or 0) then
        root.latest = session
      end
      root.activity_time = math.max(root.activity_time or 0, activity_time or session.mtime or 0)
    end
  end

  for _, root in ipairs(ordered) do
    table.sort(root.sessions, function(a, b)
      return (a.activity_time or a.mtime or 0) > (b.activity_time or b.mtime or 0)
    end)
    root.latest = root.latest or root.sessions[1]
    local name_path = root.root_session and root.root_session.path or root.root_path or (root.latest and root.latest.path)
    root.name = name_path and resume_root_name_from_file(name_path) or (root.latest and vim.fn.fnamemodify(root.latest.path, ':t')) or 'Pi session'
  end

  table.sort(ordered, function(a, b)
    if (a.activity_time or 0) == (b.activity_time or 0) then
      return tostring(a.name or a.root_path) < tostring(b.name or b.root_path)
    end
    return (a.activity_time or 0) > (b.activity_time or 0)
  end)
  return ordered
end

local function notify_already_current(message)
  vim.notify(message or 'Pi target is already current.', vim.log.levels.INFO)
end

local function show_empty_current_directory_session(cwd, callback)
  cwd = set_runtime_cwd(cwd)
  state.session.current_cwd = cwd
  state.session.auto_loaded_cwd = cwd
  state.session.current_file = nil
  state.session.tree_root_file = nil
  renderer.clear('Pi.dev new session')
  if callback then
    callback({ success = true, data = { empty = true, deferred_until_prompt = true } })
  end
  return true
end

local function render_paged_messages(messages, total, title, render_opts)
  render_opts = render_opts or {}
  local opts = session_render_options(render_opts)
  title = session_display_title(title, render_opts.title_path or render_opts.root_file or state.session.current_file, render_opts.branch_title)
  local notices = {}
  if total > #messages then
    table.insert(notices, string.format('_Showing latest %d/%d rendered messages. Older history stays in the Pi session context._', #messages, total))
  end
  if opts.include_tool_results == false then
    table.insert(notices, '_Tool results are hidden in this view. Pi still keeps the full branch context._')
  end
  local notice = #notices > 0 and table.concat(notices, '\n') or nil
  renderer.render_messages_chunked(messages, title, {
    notice = notice,
    last_user_title = render_opts.last_user_title,
    last_user_distinct = render_opts.last_user_distinct == true,
    lock_session_title = render_opts.lock_session_title,
    chunk_size = opts.chunk_size,
    chunk_delay_ms = opts.chunk_delay_ms,
    chunk_budget_ms = opts.chunk_budget_ms,
    on_done = function()
      if render_opts.on_done then
        render_opts.on_done()
      end
      if M.preload_tree then
        M.preload_tree({ delay_ms = 250 })
      end
    end,
    open_auto_folds_on_done = render_opts.open_auto_folds_on_done == true,
    scroll_to_bottom_on_done = render_opts.scroll_to_bottom_on_done ~= false,
  })
end

function M.render_current(title, path, render_opts)
  render_opts = render_opts or {}
  if path == false then
    path = nil
  else
    path = path or state.session.current_file
  end
  if path and path ~= '' then
    render_opts = vim.tbl_extend('force', render_opts or {}, { title_path = path })
    local messages, total, branch_title, last_user_title, last_user_distinct = load_messages_from_file(path, render_opts)
    render_opts.branch_title = branch_title
    render_opts.last_user_title = last_user_title
    render_opts.last_user_distinct = last_user_distinct == true
    if render_opts.lock_session_title == nil then
      render_opts.lock_session_title = branch_title ~= nil
    end
    render_paged_messages(messages, total, title or 'Pi.dev session', render_opts)
    return
  end

  rpc.request({ type = 'get_messages' }, function(response)
    if response and response.success and response.data and runtime_status.response_is_active(response) then
      local messages, total = limit_render_messages(response.data.messages or {}, render_opts)
      local last_user_title, last_user_id = last_user_title_from_messages(messages)
      local first_title, first_title_id = branch_title_from_messages(messages)
      render_opts.last_user_title = last_user_title
      render_opts.last_user_distinct = last_user_id ~= nil and first_title_id ~= nil and tostring(last_user_id) ~= tostring(first_title_id)
      render_opts.branch_title = render_opts.prefer_last_user_title and (render_opts.last_user_title or first_title) or first_title
      if render_opts.prefer_last_user_title and render_opts.last_user_title then
        render_opts.last_user_distinct = false
      end
      if render_opts.lock_session_title == nil then
        render_opts.lock_session_title = render_opts.branch_title ~= nil
      end
      render_paged_messages(messages, total, title or 'Pi.dev session', render_opts)
    elseif render_opts and render_opts.on_done then
      render_opts.on_done()
    end
  end)
end

function M.switch_to(path, opts, callback)
  opts = opts or {}
  if not path or path == '' then
    if callback then
      callback({ success = false, error = 'missing session path' })
    end
    return nil
  end

  local is_current, current_message = switch_guard.target_is_current(path, opts)
  if is_current then
    notify_already_current(current_message)
    if opts.focus_lower_after_switch then
      ui.focus_lower_panel()
    end
    if callback then
      callback({ success = false, cancelled = true, current = true, error = current_message })
    end
    return nil
  end

  local function do_switch()
    local raw_title = opts.title or ('Restored Pi session: ' .. vim.fn.fnamemodify(path, ':t'))
    local title = session_display_title(raw_title, opts.tree_root_file or path)
    if opts.runtime_key then
      rpc.use_runtime(opts.runtime_key, {
        label = title,
        session_file = path,
        branch_root = opts.tree_root_file,
        branch_entry_id = opts.branch_entry_id,
      })
    elseif opts.bind_runtime ~= false and state.is_job_running() then
      local runtime = state.active_rpc_runtime()
      if runtime.key == 'default' and not runtime.session_file and not runtime.branch_entry_id and not runtime.branch_root then
        runtime.label = title
        runtime.session_file = path
        runtime.branch_root = opts.tree_root_file
        state.sync_active_rpc_runtime(runtime)
      else
        rpc.use_runtime(path, { label = title, session_file = path, branch_root = opts.tree_root_file })
      end
    end
    local loading_runtime = state.set_runtime_loading(state.active_rpc_runtime(), true)
    ui.refresh_chrome()
    return rpc.request({ type = 'switch_session', sessionPath = path }, function(response)
      local response_active = runtime_status.response_is_active(response)
      local response_runtime = runtime_status.response_runtime(response) or loading_runtime
      local function finish_switch_loading()
        state.set_runtime_loading(response_runtime, false)
        if response_active then
          ui.refresh_chrome()
        end
      end
      if response and response.success and not (response.data and response.data.cancelled) then
        if response_active then
          state.session.current_file = path
          state.session.tree_root_file = opts.tree_root_file
          renderer.append_system('Restored current-directory session: `' .. path .. '`')
          local switch_render_opts = vim.tbl_deep_extend('force', opts.render_opts or {}, {
            on_done = function()
              finish_switch_loading()
              if opts.focus_lower_after_switch then
                ui.focus_lower_panel()
              end
            end,
          })
          M.render_current(title, path, switch_render_opts)
          runtime_status.refresh_context()
        else
          finish_switch_loading()
        end
      else
        finish_switch_loading()
        if response_active and response and response.error then
          renderer.append_system('Failed to switch Pi session: ' .. response.error)
        end
      end
      if callback then
        callback(response)
      end
    end)
  end

  local deferred, request_id = switch_guard.confirm_running_switch(path, do_switch, callback, opts, root_session_file)
  if deferred then
    return nil
  end
  return request_id
end

function M.new_session(callback, opts)
  opts = opts or {}
  local function reset_old_runtime_pool()
    local running_count = state.rpc_runtime_count and state.rpc_runtime_count({ running_only = true }) or (state.is_job_running() and 1 or 0)
    if running_count > 0 then
      rpc.stop_all()
    end
  end
  local function do_new_session()
    reset_old_runtime_pool()
    local loading_runtime = state.set_runtime_loading(state.active_rpc_runtime(), true)
    ui.refresh_chrome()
    return rpc.request({ type = 'new_session' }, function(response)
      state.set_runtime_loading(loading_runtime, false)
      if response and response.success and not (response.data and response.data.cancelled) then
        state.session.current_file = nil
        state.session.tree_root_file = nil
        renderer.clear('Pi.dev new session')
        renderer.append_system('Started a new Pi session for current directory: `' .. effective_cwd() .. '`')
        runtime_status.refresh_context()
      end
      ui.refresh_chrome()
      if callback then
        callback(response)
      end
    end)
  end

  local deferred, request_id = switch_guard.confirm_running_switch(nil, do_new_session, callback, opts, root_session_file)
  if deferred then
    return nil
  end
  return request_id
end

function M.load_latest_or_new(opts)
  opts = opts or {}
  local cwd = set_runtime_cwd(opts.cwd)
  state.session.current_cwd = cwd
  local latest = M.latest(cwd)
  if latest then
    state.session.auto_loaded_cwd = cwd
    return M.switch_to(latest.path, { title = 'Pi.dev session: ' .. latest.name, confirm_running_rpc = opts.confirm_running_rpc }, opts.callback)
  end
  return show_empty_current_directory_session(cwd, opts.callback)
end

function M.pick()
  local roots = list_resume_roots()
  if #roots == 0 then
    vim.notify('No Pi sessions found for current directory', vim.log.levels.INFO)
    return show_empty_current_directory_session(effective_cwd())
  end

  local selected = 1
  local current_root = store.normalize_path(root_session_file and root_session_file(state.session.current_file) or state.session.current_file)
  local current_path = store.normalize_path(state.session.current_file)
  ui.show()
  local label_width = math.max(1, format.window_text_width(state.ui.output_win, vim.o.columns))
  local items = {}
  for _, root in ipairs(roots) do
    local root_index = #items + 1
    if current_root and root.root_path == current_root then
      selected = root_index
    elseif current_path and root.latest and root.latest.path == current_path then
      selected = root_index
    end
    local latest = root.latest or root.root_session or root.sessions[1]
    local root_graph = '* '
    local branch_count = tonumber(root.branch_count) or 0
    local root_suffix = string.format('%d branch%s', branch_count, branch_count == 1 and '' or 'es')
    local before_lines = #items > 0 and { '' } or {}
    table.insert(items, {
      label = resume_row_label(root_graph, root.name, root_suffix, session_time_label(root), label_width),
      before_lines = before_lines,
      root_path = root.root_path,
      session = latest,
      root_name = root.name,
    })
  end

  ui.show_interaction({
    title = 'Pi resume',
    winbar_title = 'Pi resume',
    kind = 'resume',
    hint = 'j/k, gg/G, or search move; Enter choose, Esc cancel',
    message = 'Choose a current-directory root session tree. Selecting a root resumes its newest branch; rows are sorted by last interaction time.',
    surface = 'output',
    filetype = 'text',
    markdown = false,
    numbered = false,
    selection_marker = false,
    selected_hl = 'Visual',
    items = items,
    selected = selected,
    on_submit = function(item)
      if item and item.session and item.session.path then
        M.switch_to(item.session.path, {
          title = 'Pi.dev session: ' .. tostring(item.root_name or item.session.name or 'current session'),
          tree_root_file = item.root_path,
          focus_lower_after_switch = true,
        })
      end
    end,
  })
end

function M.reload_for_cwd(cwd)
  local previous_cwd = state.session.current_cwd or state.session.auto_loaded_cwd
  local next_cwd = effective_cwd(cwd)
  if state.session.current_cwd == next_cwd and state.session.auto_loaded_cwd == next_cwd then
    return
  end
  local running_count = state.rpc_runtime_count and state.rpc_runtime_count({ running_only = true }) or (state.is_job_running() and 1 or 0)
  if running_count <= 0 then
    cwd = set_runtime_cwd(next_cwd)
    state.session.current_cwd = cwd
    state.session.auto_loaded_cwd = nil
    return
  end

  if config.options.cwd == nil then
    local volatile_runtimes = switch_guard.destructive_runtimes()
    if #volatile_runtimes > 0 then
      vim.notify(
        string.format(
          'pi-dev.nvim: Neovim cwd changed%s, but Pi has active work, live interactions, or unsent drafts; Pi reload for %s was deferred.',
          previous_cwd and previous_cwd ~= next_cwd and (' from ' .. previous_cwd) or '',
          next_cwd or 'the new directory'
        ),
        vim.log.levels.WARN
      )
      renderer.append_system(
        string.format(
          'Neovim cwd changed to `%s`; kept %d Pi RPC runtime%s attached because volatile runtime-local state exists. Stop or finish that state, then reload/resume Pi for the new directory.',
          next_cwd or 'unknown',
          #volatile_runtimes,
          #volatile_runtimes == 1 and '' or 's'
        )
      )
      return
    end

    cwd = set_runtime_cwd(next_cwd)
    state.session.current_cwd = cwd
    state.session.auto_loaded_cwd = nil
    if not M.latest(cwd) then
      rpc.stop_all()
      return show_empty_current_directory_session(cwd)
    end
    rpc.stop_all()
    vim.notify(
      string.format(
        'pi-dev.nvim: Neovim cwd changed%s; restarted Pi RPC and will restore a session for %s.',
        previous_cwd and previous_cwd ~= cwd and (' from ' .. previous_cwd) or '',
        cwd or 'the new directory'
      ),
      vim.log.levels.WARN
    )
    renderer.append_system(
      string.format(
        'Neovim cwd changed to `%s`; stopped %d Pi RPC runtime%s and started a fresh Pi RPC for this directory.',
        cwd or 'unknown',
        running_count,
        running_count == 1 and '' or 's'
      )
    )
    rpc.start()
  else
    cwd = set_runtime_cwd(next_cwd)
    state.session.current_cwd = cwd
    state.session.auto_loaded_cwd = nil
  end
  vim.defer_fn(function()
    M.load_latest_or_new({ confirm_running_rpc = false })
  end, 100)
end

root_session_file = function(path)
  path = store.normalize_path(path)
  local remembered_root = store.normalize_path(state.session.tree_root_file)
  if not path then
    return remembered_root
  end
  local seen = {}
  while path and path ~= '' and not seen[path] do
    seen[path] = true
    local header = read_session_header(path)
    if not header then
      if remembered_root and remembered_root ~= path and vim.fn.filereadable(remembered_root) == 1 then
        return remembered_root
      end
      return path
    end
    local parent = store.normalize_path(header.parentSession)
    if not parent or parent == '' then
      return path
    end
    path = parent
  end
  return path
end

function M.root_file(path)
  return root_session_file(path or state.session.current_file)
end

local function write_session_name(name, path, opts)
  opts = opts or {}
  path = store.normalize_path(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return false, 'session file is not readable'
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return false, lines
  end
  local encoded = vim.json.encode({ type = 'session_info', name = tostring(name or '') })
  local insert_at = 2
  for index, line in ipairs(lines or {}) do
    local ok_json, entry = pcall(vim.json.decode, line)
    if ok_json and type(entry) == 'table' then
      if entry.type == 'session_info' then
        if opts.only_if_missing and entry.name and entry.name ~= '' then
          return true, nil, false
        end
        lines[index] = encoded
        local write_ok, err = pcall(vim.fn.writefile, lines, path)
        return write_ok, write_ok and nil or tostring(err), write_ok
      elseif entry.type == 'session' then
        insert_at = index + 1
      end
    end
  end
  table.insert(lines, insert_at, encoded)
  local write_ok, err = pcall(vim.fn.writefile, lines, path)
  return write_ok, write_ok and nil or tostring(err), write_ok
end

function M.write_root_session_name(name, path)
  path = store.normalize_path(path or M.root_file())
  return write_session_name(name, path)
end

local function truncate_session_name(name)
  name = compact_branch_title_text(name)
  if not name then
    return nil
  end
  local max_chars = 120
  if vim.fn.strchars(name) <= max_chars then
    return name
  end
  return vim.fn.strcharpart(name, 0, max_chars - 3) .. '...'
end

local function branch_session_name(path)
  local header, entries = read_title_session_entries(path)
  local all_entries = {}
  if header then
    table.insert(all_entries, header)
  end
  vim.list_extend(all_entries, entries or {})
  local title_context = branch_title_context_from_entries(all_entries, path)
  return truncate_session_name(title_context.first_title)
end

local function session_has_explicit_name(path)
  path = store.normalize_path(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return false
  end
  local ok, lines = pcall(vim.fn.readfile, path, '', 160)
  if not ok then
    return false
  end
  for _, line in ipairs(lines or {}) do
    local ok_json, entry = pcall(vim.json.decode, line)
    if ok_json and type(entry) == 'table' and entry.type == 'session_info' and entry.name and entry.name ~= '' then
      return true
    end
  end
  return false
end

function M.auto_name_branch_session(path, _fallback_text, opts)
  opts = opts or {}
  path = store.normalize_path(path)
  local name = branch_session_name(path)
  if not path or not name or name == '' then
    return false
  end
  local root = store.normalize_path(root_session_file(path))
  if opts.allow_root ~= true and root and root == path then
    return false
  end
  if session_has_explicit_name(path) then
    return false
  end

  write_session_name(name, path, { only_if_missing = true })
  if opts.rpc ~= false then
    rpc.request({ type = 'set_session_name', name = name }, function() end)
  end
  return true, name
end

local function load_session_file_entries(path)
  return store.load_entries(path)
end

local function lineage_session_files(path)
  return store.lineage_files(path)
end

function M.current_branch_user_messages(path)
  path = store.normalize_path(path or state.session.current_file)
  if not path then
    return {}
  end

  local files = lineage_session_files(path)
  if #files == 0 then
    return {}
  end

  local by_id = {}
  local current_entries = {}
  for _, file in ipairs(files) do
    local _, entries = load_session_file_entries(file)
    for _, entry in ipairs(entries or {}) do
      if entry.id and not by_id[entry.id] then
        by_id[entry.id] = entry
      end
      if store.normalize_path(file) == path then
        table.insert(current_entries, entry)
      end
    end
  end

  local latest = current_entries[#current_entries]
  if not latest then
    return {}
  end

  local chain = {}
  local seen = {}
  local current = latest
  while current and current.id and not seen[current.id] do
    seen[current.id] = true
    table.insert(chain, 1, current)
    current = current.parentId and by_id[current.parentId] or nil
  end

  local messages = {}
  local last_text
  for _, entry in ipairs(chain) do
    if entry.type == 'message' and entry.message and entry.message.role == 'user' then
      local text = vim.trim(text_from_content(entry.message.content))
      if text ~= '' and text ~= last_text then
        table.insert(messages, text)
        last_text = text
      end
    end
  end
  return messages
end

local function assistant_text(message)
  return message_content.assistant_text(message)
end

local function tree_order_entries(entries, active_ids)
  local by_parent = {}
  local by_id = {}
  local original_index = {}
  for index, entry in ipairs(entries or {}) do
    if entry.id then
      by_id[entry.id] = entry
      original_index[entry.id] = index
      local parent = entry.parentId or ''
      by_parent[parent] = by_parent[parent] or {}
      table.insert(by_parent[parent], entry)
    end
  end

  -- Compute visible recency for every entry subtree before sorting each sibling
  -- bucket. Hidden tool results and other non-tree rows must not make an old
  -- branch look newer than a sibling with a recent visible interaction.
  local branch_activity_cache = {}
  local branch_activity_visiting = {}

  local function entry_activity_time(entry)
    local message = type(entry) == 'table' and type(entry.message) == 'table' and entry.message or nil
    local role = message and message.role or nil
    local visible = false
    if role == 'user' then
      visible = vim.trim(text_from_content(message.content)) ~= ''
    elseif role == 'assistant' then
      visible = assistant_text(message) ~= ''
    elseif permission_request_from_entry(entry) then
      visible = true
    end
    if not visible then
      return 0
    end
    local value = message_timestamp_from_entry(entry)
    return timestamp_milliseconds(value) or 0
  end

  local function branch_activity_time(entry)
    if not (entry and entry.id) then
      return 0
    end
    if branch_activity_cache[entry.id] ~= nil then
      return branch_activity_cache[entry.id]
    end
    if branch_activity_visiting[entry.id] then
      return entry_activity_time(entry)
    end
    branch_activity_visiting[entry.id] = true
    local latest = entry_activity_time(entry)
    for _, child in ipairs(by_parent[entry.id] or {}) do
      latest = math.max(latest, branch_activity_time(child))
    end
    branch_activity_visiting[entry.id] = nil
    branch_activity_cache[entry.id] = latest
    return latest
  end

  for _, children in pairs(by_parent) do
    table.sort(children, function(a, b)
      local a_activity = branch_activity_time(a)
      local b_activity = branch_activity_time(b)
      if a_activity ~= b_activity then
        return a_activity > b_activity
      end
      local a_active = active_ids and active_ids[a.id] or false
      local b_active = active_ids and active_ids[b.id] or false
      if a_active ~= b_active then
        return a_active
      end
      return (original_index[a.id] or 0) < (original_index[b.id] or 0)
    end)
  end

  local ordered = {}
  local visited = {}

  local function emit(entry)
    if not entry or visited[entry.id] then
      return false
    end
    visited[entry.id] = true
    table.insert(ordered, entry)
    return true
  end

  local visit
  -- Git's graph renderer consumes an already topologically ordered revision
  -- stream; keep a linear branch chain together before visiting sibling
  -- branches so independent session branches do not visually interleave.
  local function visit_block(entry)
    local current = entry
    local tail = nil
    while current and not visited[current.id] do
      emit(current)
      tail = current
      local children = by_parent[current.id] or {}
      if #children ~= 1 then
        break
      end
      current = children[1]
    end
    return tail
  end

  local function visit_children(entry)
    local children = by_parent[entry.id] or {}
    if #children <= 1 then
      visit(children[1])
      return
    end
    for _, child in ipairs(children) do
      local tail = visit_block(child)
      if tail then
        visit_children(tail)
      end
    end
  end

  visit = function(entry)
    if emit(entry) then
      visit_children(entry)
    end
  end

  for _, entry in ipairs(by_parent[''] or {}) do
    visit(entry)
  end
  for _, entry in ipairs(entries or {}) do
    if entry.id and not visited[entry.id] then
      if not entry.parentId or not by_id[entry.parentId] then
        visit(entry)
      end
    end
  end
  for _, entry in ipairs(entries or {}) do
    if entry.id and not visited[entry.id] then
      visit(entry)
    end
  end

  return ordered
end

local function tree_logical_prefixes(entries, visible_ids, by_id, nearest_visible_parent_id)
  local visible_user_children = {}
  for _, entry in ipairs(entries or {}) do
    if entry.id and visible_ids[entry.id] and entry.message and entry.message.role == 'user' then
      local parent_id = nearest_visible_parent_id(entry)
      local parent = parent_id and by_id[parent_id]
      if parent and parent.message and parent.message.role == 'assistant' then
        visible_user_children[parent_id] = (visible_user_children[parent_id] or 0) + 1
      end
    end
  end

  local depths = {}
  local prefixes = {}
  for _, entry in ipairs(entries or {}) do
    if entry.id and visible_ids[entry.id] then
      local parent_id = nearest_visible_parent_id(entry)
      local parent = parent_id and by_id[parent_id]
      local depth = parent_id and depths[parent_id] or 0
      if parent and parent.message and parent.message.role == 'assistant'
        and entry.message and entry.message.role == 'user'
        and (visible_user_children[parent_id] or 0) > 1 then
        depth = depth + 1
      end
      depths[entry.id] = depth
      prefixes[entry.id] = string.rep('| ', depth) .. '* '
    end
  end
  return prefixes
end

local function session_reaches_root(path, root, headers)
  path = store.normalize_path(path)
  root = store.normalize_path(root)
  local seen = {}
  while path and path ~= '' and not seen[path] do
    if path == root then
      return true
    end
    seen[path] = true
    local header = headers and headers[path] or read_session_header(path)
    path = header and store.normalize_path(header.parentSession)
  end
  return false
end

local tree_cache = nil
local tree_preload_pending = false
local session_signature_cache = nil
local assistant_response_mode

local function file_stat_signature(path)
  return store.file_stat_signature(path)
end

local function same_stat(left, right)
  return store.same_stat(left, right)
end

local function read_session_file_once(path)
  return store.read_once(path)
end

local function cache_stats_valid(cache)
  if not cache then
    return false
  end
  if not same_stat(file_stat_signature(cache.dir), cache.dir_stat) then
    return false
  end
  for path, stat in pairs(cache.stats or {}) do
    if not same_stat(file_stat_signature(path), stat) then
      return false
    end
  end
  return true
end

local function path_is_inside(path, dir)
  return store.path_is_inside(path, dir)
end

local function same_directory(path, dir)
  return store.same_directory(path, dir)
end

local function session_signature_from_paths(paths)
  local parts = {}
  for _, path in ipairs(paths or {}) do
    local stat = file_stat_signature(path) or {}
    table.insert(parts, table.concat({
      path,
      tostring(stat.size or 0),
      tostring(stat.mtime_sec or 0),
      tostring(stat.mtime_nsec or 0),
    }, ':'))
  end
  return table.concat(parts, '\n')
end

local function current_directory_session_paths(root_file)
  local root = store.root()
  if root_file and not path_is_inside(root_file, root) then
    return {}, ''
  end
  local root_dir = root_file and vim.fn.fnamemodify(root_file, ':h') or nil
  local cwd = effective_cwd()
  local paths = {}
  for _, path in ipairs(vim.fn.globpath(root, '**/*.jsonl', false, true) or {}) do
    local normalized = store.normalize_path(path)
    if normalized and not same_directory(normalized, root_dir) and not store.is_trash_path(normalized) then
      local header = read_session_header(normalized)
      if header and header.type == 'session' and store.normalize_path(header.cwd) == cwd then
        table.insert(paths, normalized)
      end
    end
  end
  table.sort(paths)
  return paths, session_signature_from_paths(paths)
end

local function session_root_directory_signature()
  local root = store.normalize_path(store.root())
  if not root then
    return ''
  end
  local parts = {}
  local function add_stat(path)
    local stat = file_stat_signature(path) or {}
    table.insert(parts, table.concat({
      path,
      tostring(stat.size or 0),
      tostring(stat.mtime_sec or 0),
      tostring(stat.mtime_nsec or 0),
    }, ':'))
  end
  add_stat(root)
  local scan = vim.uv.fs_scandir(root)
  if scan then
    while true do
      local name, kind = vim.uv.fs_scandir_next(scan)
      if not name then
        break
      end
      if kind == 'directory' then
        add_stat(vim.fs.joinpath(root, name))
      end
    end
  end
  table.sort(parts)
  return table.concat(parts, '\n')
end

local function current_directory_session_signature(root_file)
  local _, signature = current_directory_session_paths(root_file)
  return signature
end

local function cached_current_directory_session_signature(root_file)
  local root = store.normalize_path(store.root())
  local cwd = effective_cwd()
  local key = table.concat({ root or '', store.normalize_path(root_file) or '', cwd or '' }, '\n')
  local directory_signature = session_root_directory_signature()
  if session_signature_cache
    and session_signature_cache.key == key
    and session_signature_cache.directory_signature == directory_signature then
    return session_signature_cache.signature
  end
  local signature = current_directory_session_signature(root_file)
  session_signature_cache = {
    key = key,
    directory_signature = directory_signature,
    signature = signature,
  }
  return signature
end

local function cached_tree_result(root_file, current_path)
  root_file = store.normalize_path(root_file)
  current_path = store.normalize_path(current_path)
  local mode = assistant_response_mode()
  local cwd = effective_cwd()
  if tree_cache
    and tree_cache.root_file == root_file
    and tree_cache.current_path == current_path
    and tree_cache.assistant_mode == mode
    and tree_cache.cwd == cwd
    and tree_cache.session_signature == cached_current_directory_session_signature(root_file)
    and cache_stats_valid(tree_cache) then
    return tree_cache.messages, tree_cache.current_visible_entry_id
  end
  return nil, nil
end

local function store_tree_cache(root_file, current_path, dir, stats, messages, current_visible_entry_id, session_signature)
  local root = store.normalize_path(store.root())
  local cwd = effective_cwd()
  local normalized_root = store.normalize_path(root_file)
  local signature = session_signature or current_directory_session_signature(root_file)
  session_signature_cache = {
    key = table.concat({ root or '', normalized_root or '', cwd or '' }, '\n'),
    directory_signature = session_root_directory_signature(),
    signature = signature,
  }
  tree_cache = {
    root_file = normalized_root,
    current_path = store.normalize_path(current_path),
    cwd = cwd,
    assistant_mode = assistant_response_mode(),
    session_signature = signature,
    dir = store.normalize_path(dir),
    dir_stat = file_stat_signature(dir),
    stats = stats or {},
    messages = messages,
    current_visible_entry_id = current_visible_entry_id,
  }
end

local function session_shares_loaded_entry(loaded, root_entry_ids)
  if not loaded or not root_entry_ids or not next(root_entry_ids) then
    return false
  end
  for _, entry in ipairs(loaded.entries or {}) do
    if entry.id and root_entry_ids[entry.id] then
      return true
    end
  end
  return false
end

local function loaded_tree_context(root_file, current_path)
  root_file = store.normalize_path(root_file)
  current_path = store.normalize_path(current_path)
  if not root_file or root_file == '' then
    return nil
  end
  local dir = vim.fn.fnamemodify(root_file, ':h')
  local candidate_paths = {}
  local seen_candidates = {}
  local function add_candidate(path)
    path = store.normalize_path(path)
    if path and not seen_candidates[path] and vim.fn.filereadable(path) == 1 then
      seen_candidates[path] = true
      table.insert(candidate_paths, path)
    end
  end
  add_candidate(root_file)
  for _, path in ipairs(vim.fn.globpath(dir, '*.jsonl', false, true) or {}) do
    add_candidate(path)
  end
  local current_paths, session_signature = current_directory_session_paths(root_file)
  for _, path in ipairs(current_paths) do
    add_candidate(path)
  end
  add_candidate(current_path)

  local loaded_by_path = {}
  local headers = {}
  local stats = {}
  for _, path in ipairs(candidate_paths) do
    local loaded = read_session_file_once(path)
    if loaded and loaded.header and loaded.header.type == 'session' then
      loaded_by_path[path] = loaded
      headers[path] = loaded.header
      stats[path] = loaded.stat
    end
  end

  local root_loaded = loaded_by_path[root_file]
  if not root_loaded then
    return nil
  end
  local root_entry_ids = {}
  for _, entry in ipairs(root_loaded.entries or {}) do
    if entry.id then
      root_entry_ids[entry.id] = true
    end
  end

  local related = {}
  for path, loaded in pairs(loaded_by_path) do
    if path == root_file
      or path == current_path
      or session_reaches_root(path, root_file, headers)
      or session_shares_loaded_entry(loaded, root_entry_ids) then
      table.insert(related, loaded)
    end
  end
  table.sort(related, function(a, b)
    if a.path == root_file then
      return true
    end
    if b.path == root_file then
      return false
    end
    local a_mtime = a.stat and a.stat.mtime_sec or 0
    local b_mtime = b.stat and b.stat.mtime_sec or 0
    if a_mtime == b_mtime then
      return tostring(a.path) < tostring(b.path)
    end
    return a_mtime < b_mtime
  end)

  local merged = {}
  local seen_ids = {}
  local current_ids = {}
  local current_entries = {}
  for _, loaded in ipairs(related) do
    local is_current = store.normalize_path(loaded.path) == current_path
    for _, entry in ipairs(loaded.entries or {}) do
      if is_current then
        table.insert(current_entries, entry)
        if entry.id then
          current_ids[entry.id] = true
        end
      end
      if entry.id and not seen_ids[entry.id] then
        seen_ids[entry.id] = true
        table.insert(merged, entry)
      end
    end
  end

  return {
    dir = dir,
    stats = stats,
    entries = merged,
    current_ids = current_ids,
    current_entries = current_entries,
    session_signature = session_signature,
  }
end

assistant_response_mode = function()
  local tree_opts = config.options.tree or {}
  return tree_opts.assistant_responses or 'last_per_user'
end

local function assistant_has_later_response_before_user(entry, children_by_parent)
  local stack = vim.deepcopy(children_by_parent[entry.id] or {})
  while #stack > 0 do
    local child = table.remove(stack, 1)
    if child.type == 'message' and child.message then
      local role = child.message.role
      if role == 'user' then
        -- A user message starts the next block; response rows below it
        -- belong to that next user, not to this response block.
      elseif role == 'assistant' and assistant_text(child.message) ~= '' then
        return true
      else
        vim.list_extend(stack, children_by_parent[child.id] or {})
      end
    else
      vim.list_extend(stack, children_by_parent[child.id] or {})
    end
  end
  return false
end

local function assistant_entry_visible(entry, children_by_parent)
  if assistant_response_mode() == 'all' then
    return true
  end
  return not assistant_has_later_response_before_user(entry, children_by_parent)
end

local function tree_messages_from_file(path, current_path)
  local cached_messages, cached_current = cached_tree_result(path, current_path)
  if cached_messages then
    return cached_messages, cached_current
  end

  local context = loaded_tree_context(path, current_path)
  if not context or #(context.entries or {}) == 0 then
    return nil
  end
  local entries = tree_order_entries(context.entries, context.current_ids)
  local children_by_parent = {}
  local by_id = {}
  for _, entry in ipairs(entries) do
    if entry.id then
      by_id[entry.id] = entry
    end
  end
  for _, entry in ipairs(entries) do
    if entry.id then
      local parent = entry.parentId or ''
      children_by_parent[parent] = children_by_parent[parent] or {}
      table.insert(children_by_parent[parent], entry)
    end
  end
  local function has_later_visible_real_step(entry)
    local stack = vim.deepcopy(children_by_parent[entry.id] or {})
    while #stack > 0 do
      local child = table.remove(stack, 1)
      if child.type == 'message' and child.message then
        local role = child.message.role
        if role == 'user' and vim.trim(text_from_content(child.message.content)) ~= '' then
          return true
        end
        if role == 'assistant' and assistant_entry_visible(child, children_by_parent) and assistant_text(child.message) ~= '' then
          return true
        end
      elseif permission_request_from_entry(child) then
        return true
      end
      vim.list_extend(stack, children_by_parent[child.id] or {})
    end
    return false
  end

  local function is_visible_entry(entry)
    if not (entry and entry.id) then
      return false
    end
    if entry.type == 'message' and entry.message then
      local role = entry.message.role
      if role == 'user' then
        return vim.trim(text_from_content(entry.message.content)) ~= ''
      end
      return role == 'assistant' and assistant_entry_visible(entry, children_by_parent) and assistant_text(entry.message) ~= ''
    end
    return permission_request_from_entry(entry) ~= nil and not has_later_visible_real_step(entry)
  end

  local visible_ids = {}
  for _, entry in ipairs(entries) do
    if is_visible_entry(entry) then
      visible_ids[entry.id] = true
    end
  end

  local function nearest_visible_parent_id(entry)
    local parent_id = entry and entry.parentId
    while parent_id do
      if visible_ids[parent_id] then
        return parent_id
      end
      local parent = by_id[parent_id]
      parent_id = parent and parent.parentId or nil
    end
    return entry and entry.parentId or nil
  end

  local prefixes = tree_logical_prefixes(entries, visible_ids, by_id, nearest_visible_parent_id)

  local messages = {}
  for _, entry in ipairs(entries) do
    if is_visible_entry(entry) then
      local role = entry.message and entry.message.role or 'permission'
      if role == 'user' or role == 'assistant' or role == 'permission' then
        local text
        if role == 'assistant' then
          text = assistant_text(entry.message)
        elseif role == 'permission' then
          text = 'Permission: ' .. permission_request_tree_summary(permission_request_from_entry(entry))
        else
          text = list_label_text_from_content(entry.message.content)
        end
        text = vim.trim(text or '')
        if text ~= '' then
          local ancestor_ids = {}
          local ancestor = entry
          local seen_ancestors = {}
          while ancestor and ancestor.id and not seen_ancestors[ancestor.id] do
            seen_ancestors[ancestor.id] = true
            ancestor_ids[tostring(ancestor.id)] = true
            ancestor = ancestor.parentId and by_id[ancestor.parentId] or nil
          end
          table.insert(messages, {
            entryId = entry.id,
            parentId = entry.parentId,
            displayParentId = nearest_visible_parent_id(entry),
            ancestorIds = ancestor_ids,
            text = text,
            role = role,
            timestamp = entry.timestamp,
            graph = prefixes[entry.id] or '* ',
            session_path = entry.__pi_source_path,
          })
        end
      end
    end
  end

  local current_visible_id
  local current = context.current_entries and context.current_entries[#context.current_entries] or nil
  local seen_current = {}
  while current and current.id and not seen_current[current.id] do
    if visible_ids[current.id] then
      current_visible_id = current.id
      break
    end
    seen_current[current.id] = true
    current = current.parentId and by_id[current.parentId] or nil
  end
  store_tree_cache(path, current_path, context.dir, context.stats, messages, current_visible_id, context.session_signature)
  return messages, current_visible_id
end

local function random_session_id()
  local hex = vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring(math.random()) .. effective_cwd())
  return table.concat({ hex:sub(1, 8), hex:sub(9, 12), '4' .. hex:sub(14, 16), '8' .. hex:sub(18, 20), hex:sub(21, 32) }, '-')
end

local function branched_session_path(root_file, target_id)
  local header, entries = load_session_file_entries(root_file)
  if not header or not entries or not target_id then
    return nil, 'missing root session data'
  end
  local by_id = {}
  for _, entry in ipairs(entries) do
    by_id[entry.id] = entry
  end
  local path = {}
  local current = by_id[target_id]
  while current do
    table.insert(path, 1, current)
    current = current.parentId and by_id[current.parentId] or nil
  end
  if #path == 0 then
    return nil, 'entry not found in root session'
  end
  if path[#path].id == entries[#entries].id then
    return root_file, nil
  end
  local id = random_session_id()
  local timestamp = os.date('!%Y-%m-%dT%H:%M:%S.000Z')
  local branch_header = vim.tbl_extend('force', vim.deepcopy(header), {
    id = id,
    timestamp = timestamp,
    parentSession = root_file,
  })
  local out = { vim.json.encode(branch_header) }
  for _, entry in ipairs(path) do
    table.insert(out, vim.json.encode(entry))
  end
  local filename = timestamp:gsub('[:.]', '-') .. '_' .. id .. '.jsonl'
  local target_path = vim.fs.joinpath(vim.fn.fnamemodify(root_file, ':h'), filename)
  local ok, err = pcall(vim.fn.writefile, out, target_path)
  if not ok then
    return nil, tostring(err)
  end
  return target_path, nil
end

local function human_timestamp(timestamp)
  return format.human_time_from_timestamp(timestamp)
end

local function current_visible_entry_id(path, visible_ids)
  local _, entries = load_session_file_entries(path)
  if not entries then
    return nil
  end
  local by_id = {}
  for _, entry in ipairs(entries) do
    if entry.id then
      by_id[entry.id] = entry
    end
  end
  local current = entries[#entries]
  while current do
    if visible_ids[current.id] then
      return current.id
    end
    current = current.parentId and by_id[current.parentId] or nil
  end
  return nil
end

local function tree_label_width()
  local win = state.ui.output_win
  return math.max(1, format.window_text_width(win))
end

local function tree_row_label(prefix, body, badge, timestamp, max_width)
  max_width = math.max(1, tonumber(max_width) or 1)
  local time_label = human_timestamp(timestamp)
  local suffix_parts = {}
  if badge and badge ~= '' then
    table.insert(suffix_parts, tostring(badge))
  end
  if time_label and time_label ~= '' then
    table.insert(suffix_parts, '(' .. time_label .. ')')
  end
  return format.prefixed_line(tostring(prefix or ''), tostring(body or ''), table.concat(suffix_parts, ' '), max_width)
end

local function tree_runtime_links(messages, root_file)
  state.recheck_rpc_runtimes()
  local by_id = {}
  for _, message in ipairs(messages or {}) do
    if message.entryId then
      by_id[message.entryId] = message
    end
  end

  local function is_descendant(entry_id, ancestor_id)
    if not entry_id or not ancestor_id then
      return false
    end
    if tostring(entry_id) == tostring(ancestor_id) then
      return true
    end
    local current = by_id[entry_id]
    if current and current.ancestorIds and current.ancestorIds[tostring(ancestor_id)] then
      return true
    end
    local seen = {}
    while current and not seen[current.entryId] do
      seen[current.entryId] = true
      local parent_id = current.displayParentId or current.parentId
      if parent_id and tostring(parent_id) == tostring(ancestor_id) then
        return true
      end
      current = parent_id and by_id[parent_id] or nil
    end
    return false
  end

  local visible_ids = {}
  for _, message in ipairs(messages or {}) do
    if message.entryId then
      visible_ids[message.entryId] = true
    end
  end

  local function index_for_entry_id(entry_id)
    if not entry_id then
      return nil
    end
    for index, message in ipairs(messages or {}) do
      if tostring(message.entryId) == tostring(entry_id) then
        return index
      end
    end
    return nil
  end

  local function session_candidate_for_runtime(runtime)
    if not runtime or not runtime.session_file or runtime.session_file == '' then
      return nil
    end
    local session_file = store.normalize_path(runtime.session_file) or tostring(runtime.session_file)
    local current_entry_id = current_visible_entry_id(session_file, visible_ids)
    if current_entry_id and (not runtime.branch_entry_id or is_descendant(current_entry_id, runtime.branch_entry_id)) then
      local index = index_for_entry_id(current_entry_id)
      if index then
        return index
      end
    end

    local candidate
    for index, message in ipairs(messages or {}) do
      local message_path = store.normalize_path(message.session_path) or tostring(message.session_path or '')
      if message_path ~= '' and message_path == session_file and (not runtime.branch_entry_id or is_descendant(message.entryId, runtime.branch_entry_id)) then
        candidate = index
      end
    end
    return candidate
  end

  local badges = {}
  local runtimes = {}
  local function set_badge(runtime, candidate, allow_overwrite)
    local entry_id = candidate and messages[candidate] and messages[candidate].entryId
    local badge = entry_id and runtime_status.badge(runtime) or nil
    if not entry_id or not badge then
      return
    end
    local existing = runtimes[entry_id]
    if existing and allow_overwrite then
      local existing_branch = existing.branch_entry_id
      local next_branch = runtime and runtime.branch_entry_id
      if existing_branch and next_branch and tostring(existing_branch) ~= tostring(next_branch) then
        if is_descendant(existing_branch, next_branch) and not is_descendant(next_branch, existing_branch) then
          return
        end
      end
    end
    if allow_overwrite or not badges[entry_id] then
      badges[entry_id] = badge
      runtimes[entry_id] = runtime
    end
  end

  local exact_runtime_by_entry = {}
  for _, runtime in pairs(state.rpc.runtimes or {}) do
    if runtime.branch_entry_id then
      exact_runtime_by_entry[tostring(runtime.branch_entry_id)] = runtime
    end
  end

  for _, runtime in pairs(state.rpc.runtimes or {}) do
    if runtime.branch_entry_id then
      local candidate = session_candidate_for_runtime(runtime)
      local exact_candidate
      if not candidate then
        for index, message in ipairs(messages or {}) do
          if tostring(message.entryId) == tostring(runtime.branch_entry_id) then
            exact_candidate = index
          end
          if is_descendant(message.entryId, runtime.branch_entry_id) then
            candidate = index
          end
        end
      else
        exact_candidate = index_for_entry_id(runtime.branch_entry_id)
      end
      local candidate_entry = candidate and messages[candidate] and messages[candidate].entryId
      if candidate_entry and tostring(candidate_entry) ~= tostring(runtime.branch_entry_id) and exact_runtime_by_entry[tostring(candidate_entry)] then
        candidate = exact_candidate or candidate
      end
      set_badge(runtime, candidate, true)
    end
  end

  for _, runtime in pairs(state.rpc.runtimes or {}) do
    if not runtime.branch_entry_id then
      local candidate
      for index, message in ipairs(messages or {}) do
        if runtime.key == rpc.branch_key(root_file, message.entryId) then
          candidate = index
        end
      end
      set_badge(runtime, candidate, false)
    end
  end

  for _, runtime in pairs(state.rpc.runtimes or {}) do
    if not runtime.branch_entry_id then
      local session_file
      if runtime.session_file and runtime.session_file ~= '' then
        session_file = store.normalize_path(runtime.session_file) or tostring(runtime.session_file)
      elseif tostring(runtime.key or '') == tostring(state.rpc.active_key or 'default') and state.session.current_file and state.session.current_file ~= '' then
        -- The initial/default runtime can be waiting before it has been
        -- explicitly rebound to a branch key. If a root tree is already known,
        -- attach that runtime badge to the current visible tree row instead of
        -- rendering a confusing standalone "default" waiting row.
        session_file = store.normalize_path(state.session.current_file) or tostring(state.session.current_file)
      end
      if session_file and session_file ~= '' then
        local candidate
        local current_entry_id = current_visible_entry_id(session_file, visible_ids)
        if current_entry_id then
          for index, message in ipairs(messages or {}) do
            if tostring(message.entryId) == tostring(current_entry_id) then
              candidate = index
              break
            end
          end
        end
        if not candidate then
          for index, message in ipairs(messages or {}) do
            local message_path = store.normalize_path(message.session_path) or tostring(message.session_path or '')
            if message_path ~= '' and message_path == session_file then
              candidate = index
            end
          end
        end
        set_badge(runtime, candidate, false)
      end
    end
  end

  return { badges = badges, runtimes = runtimes }
end

local tree_connector_line = tree_graph.connector_line
local tree_return_connector_line = tree_graph.return_connector_line
local tree_branch_folds = tree_graph.branch_folds

local function reopen_pending_runtime_interaction(runtime)
  return waiting.reopen_runtime_interaction(runtime)
end

local function runtime_has_waiting_interaction(runtime)
  return waiting.runtime_has_interaction(runtime)
end

local function reusable_idle_active_runtime()
  local runtime = state.active_rpc_runtime()
  if not runtime or not state.is_job_running(runtime) then
    return nil
  end
  if switch_guard.runtime_is_non_idle(runtime) then
    return nil
  end
  if switch_guard.runtime_has_local_draft(runtime) then
    return nil
  end
  if runtime_has_waiting_interaction(runtime) or runtime.pending_extension_ui_request or runtime.current_extension_interaction then
    return nil
  end
  return runtime
end

local function runtime_tree_binding_snapshot(runtime)
  if not runtime then
    return nil
  end
  return {
    label = runtime.label,
    session_file = runtime.session_file,
    branch_root = runtime.branch_root,
    branch_entry_id = runtime.branch_entry_id,
  }
end

local function restore_runtime_tree_binding(runtime, snapshot)
  if not runtime or not snapshot then
    return nil
  end
  runtime.label = snapshot.label
  runtime.session_file = snapshot.session_file
  runtime.branch_root = snapshot.branch_root
  runtime.branch_entry_id = snapshot.branch_entry_id
  state.sync_active_rpc_runtime(runtime)
  return runtime
end

local function bind_runtime_to_tree_selection(runtime, opts)
  if not runtime then
    return nil
  end
  opts = opts or {}
  runtime.label = opts.label or runtime.label
  runtime.session_file = opts.session_file or runtime.session_file
  runtime.branch_root = opts.branch_root or runtime.branch_root
  runtime.branch_entry_id = opts.branch_entry_id or runtime.branch_entry_id
  state.sync_active_rpc_runtime(runtime)
  return runtime
end

local function render_switched_runtime(runtime, opts)
  opts = opts or {}
  if not runtime then
    return false
  end
  local pending_request = opts.pending_request or runtime.pending_extension_ui_request
  local render_path = false
  if not pending_request and not runtime.branch_entry_id and runtime.session_file and runtime.session_file ~= '' then
    render_path = runtime.session_file
  end
  if pending_request and render_path == false then
    renderer.clear(runtime_display_name(runtime))
    reopen_pending_runtime_interaction(runtime)
  end

  local render_opts = {
    root_file = opts.root_file or runtime.branch_root,
    skip_terminal_permission_id = pending_request and pending_request.id,
    on_done = function()
      reopen_pending_runtime_interaction(runtime)
      if opts.focus_lower_after_switch ~= false then
        ui.focus_lower_panel()
      end
      if opts.on_done then
        opts.on_done(runtime)
      end
    end,
  }
  if opts.session_render ~= nil then
    render_opts.session_render = opts.session_render
  end

  M.render_current(runtime_display_name(runtime), render_path, render_opts)
  if pending_request and opts.focus_lower_after_switch ~= false then
    ui.focus_lower_panel()
  end
  return true
end

local activate_existing_branch_runtime

local function tree_item_is_empty_root(item)
  return item
    and not item.runtime_only
    and not item.runtime_key
    and (item.entry_id == nil or item.entry_id == '')
    and vim.trim(tostring(item.text or '')) == ''
end

local function notify_empty_root_tree()
  vim.notify('empty root - no messages in history', vim.log.levels.INFO)
end

local function show_tree_messages(messages, root_file, current_entry_id, opts)
  opts = opts or {}
  messages = messages or {}
  if #messages == 0 and not opts.waiting_only then
    vim.notify(opts.empty_message or 'No messages available for Pi tree navigation', vim.log.levels.INFO)
    return
  end
  local runtime_links = tree_runtime_links(messages, root_file)
  local visible_messages = {}
  local waiting_message_ids = {}
  local linked_runtime_keys = {}
  for _, message in ipairs(messages) do
    local runtime = runtime_links.runtimes[message.entryId]
    local is_waiting = runtime_has_waiting_interaction(runtime)
    if runtime and runtime.key then
      linked_runtime_keys[runtime.key] = true
    end
    if is_waiting then
      waiting_message_ids[message.entryId] = true
    end
    -- /waiting remains a tree view: keep ordinary tree nodes visible as
    -- context/connectors, but only waiting nodes are selectable.
    if not opts.waiting_only or is_waiting then
      table.insert(visible_messages, message)
    end
  end
  if opts.waiting_only and next(waiting_message_ids) ~= nil then
    local keep_ids = {}
    for _, message in ipairs(messages) do
      if waiting_message_ids[message.entryId] then
        keep_ids[message.entryId] = true
        for ancestor_id in pairs(message.ancestorIds or {}) do
          keep_ids[ancestor_id] = true
        end
      end
    end
    visible_messages = {}
    for _, message in ipairs(messages) do
      if keep_ids[message.entryId] then
        table.insert(visible_messages, message)
      end
    end
  end
  local waiting_runtimes = {}
  if opts.waiting_only then
    state.recheck_rpc_runtimes()
    for _, runtime in pairs(state.rpc.runtimes or {}) do
      if runtime.key and not linked_runtime_keys[runtime.key] and runtime_has_waiting_interaction(runtime) then
        table.insert(waiting_runtimes, runtime)
      end
    end
    table.sort(waiting_runtimes, function(a, b)
      return tostring(a.label or a.session_file or a.key or '') < tostring(b.label or b.session_file or b.key or '')
    end)
  end
  if #visible_messages == 0 and #waiting_runtimes == 0 then
    if opts.waiting_only and state.ui.interaction and (state.ui.interaction.kind == 'waiting' or state.ui.interaction.title == (opts.title or 'Pi waiting input')) then
      ui.close_interaction({ process_queue = false })
    end
    vim.notify(opts.empty_message or 'No messages available for Pi tree navigation', vim.log.levels.INFO)
    return
  end

  -- Tree row labels are width-fitted before they are handed to the generic
  -- interaction renderer, so make sure the lower Pi pane exists first. When
  -- the panel was closed, using vim.o.columns here can produce rows wider
  -- than the actual right panel after it opens.
  ui.show()
  local items = {}
  local selected = 1
  local graph_by_id = {}
  for _, message in ipairs(messages) do
    if message.entryId then
      graph_by_id[message.entryId] = message.graph
    end
  end
  local max_label_width = tree_label_width()
  local badges = runtime_links.badges
  local row_by_entry_id = {}
  local previous_visible_graph = nil
  local selected_waiting = false
  local function tree_row_parts(message)
    local text = tostring(message.text or '')
    if message.role == 'user' then
      text = pipeline.skill_call_label(text) or text
    end
    text = text:gsub('\n', ' ')
    local prefix = message.graph or '* '
    local body = message.role == 'assistant' and ('Assistant: ' .. text) or text
    local badge = badges[message.entryId]
    return text, prefix, body, badge
  end
  for index, message in ipairs(visible_messages) do
    local text, prefix, body, badge = tree_row_parts(message)
    local runtime = runtime_links.runtimes[message.entryId]
    local is_waiting = not opts.waiting_only or waiting_message_ids[message.entryId] == true
    local label = tree_row_label(prefix, body, badge, message.timestamp, max_label_width)
    if message.entryId then
      row_by_entry_id[tostring(message.entryId)] = { prefix = prefix, body = body, badge = badge }
    end
    if opts.waiting_only then
      if is_waiting and (not selected_waiting or (runtime and runtime.key == state.rpc.active_key)) then
        selected = index
        selected_waiting = true
      end
    elseif current_entry_id and message.entryId == current_entry_id then
      selected = index
    end
    local before_lines = {}
    local connector = tree_connector_line(graph_by_id[message.displayParentId or message.parentId], message.graph)
    if not connector then
      connector = tree_return_connector_line(previous_visible_graph, message.graph)
    end
    if connector then
      table.insert(before_lines, connector)
    end
    previous_visible_graph = message.graph
    local runtime_key = runtime and runtime.key or nil
    if runtime_key and not opts.waiting_only and switch_guard.same_runtime_key(runtime_key, state.rpc.active_key) then
      runtime_key = nil
    end
    table.insert(items, {
      label = label,
      before_lines = before_lines,
      entry_id = message.entryId,
      role = message.role,
      text = text,
      session_path = message.session_path,
      runtime_key = runtime_key,
      selectable = not opts.waiting_only or is_waiting,
    })
  end
  for _, runtime in ipairs(waiting_runtimes) do
    local name = runtime_display_name(runtime)
    if runtime.key == state.rpc.active_key then
      selected = #items + 1
    end
    table.insert(items, {
      label = tree_row_label('* ', tostring(name), '[' .. (statusline.short_status_label and statusline.short_status_label('waiting input') or 'wait') .. ']', nil, max_label_width),
      runtime_key = runtime.key,
      role = 'runtime',
      text = tostring(name),
      session_path = runtime.session_file,
      runtime_only = true,
    })
  end
  local protected_ids = {}
  if current_entry_id then
    protected_ids[tostring(current_entry_id)] = true
  end
  for entry_id, runtime in pairs(runtime_links.runtimes or {}) do
    protected_ids[tostring(entry_id)] = true
    if runtime and runtime.branch_entry_id then
      protected_ids[tostring(runtime.branch_entry_id)] = true
    end
  end
  local folds = tree_branch_folds(visible_messages, {
    auto_close_leaf = not opts.waiting_only,
    protected_ids = protected_ids,
  })
  for _, fold in ipairs(folds) do
    local end_message = visible_messages[fold.end_index]
    local row = end_message and end_message.entryId and row_by_entry_id[tostring(end_message.entryId)]
    if row and end_message then
      fold.label = tree_row_label(row.prefix, row.body, row.badge, end_message.timestamp, max_label_width)
    end
  end

  ui.show_interaction({
    title = opts.title or 'Pi tree',
    kind = opts.waiting_only and 'waiting' or 'tree',
    surface = 'output',
    hint = 'j/k, gg/G, or search move; Enter choose, Esc cancel',
    message = opts.message or 'Choose a user message to fork from, or a response row to return to. Native / search, n/N, cursor movement, gg/G boundary jumps, and Enter are supported.',
    filetype = 'text',
    markdown = false,
    numbered = false,
    selection_marker = false,
    selected_hl = 'Visual',
    items = items,
    selected = selected,
    folds = folds,
    before_submit = function(item)
      if not item or opts.waiting_only then
        return true
      end
      if tree_item_is_empty_root(item) then
        notify_empty_root_tree()
        return false
      end
      local runtime_key = item.runtime_key
      local same_tree_position = current_entry_id and item.entry_id and tostring(item.entry_id) == tostring(current_entry_id)
      if not runtime_key and item.role == 'user' and (same_tree_position or not reusable_idle_active_runtime()) then
        runtime_key = rpc.branch_key(root_file, item.entry_id)
      end
      if runtime_key and not rpc.can_start_runtime(runtime_key) then
        rpc.notify_pool_exhausted({ append_to_output = false })
        return false
      end
      return true
    end,
    on_submit = function(item)
      if not item then
        return
      end
      if tree_item_is_empty_root(item) then
        notify_empty_root_tree()
        return
      end
      if opts.waiting_only then
        if not item.runtime_key then
          renderer.append_system('No waiting Pi runtime is attached to the selected tree row.')
          return
        end
        local runtime = state.ensure_rpc_runtime(item.runtime_key)
        if switch_guard.same_runtime_key(runtime.key, state.rpc.active_key) then
          notify_already_current('Pi RPC branch is already current.')
          ui.focus_lower_panel()
          return
        end
        if runtime.session_file and runtime.session_file ~= '' then
          state.session.current_file = runtime.session_file
          if root_file and root_file ~= '' then
            state.session.tree_root_file = root_file
          end
        end
        local pending_request = runtime.pending_extension_ui_request
        runtime = rpc.use_runtime(item.runtime_key, {
          label = runtime.label,
          session_file = runtime.session_file or item.session_path,
          branch_root = root_file or runtime.branch_root,
          branch_entry_id = runtime.branch_entry_id or item.entry_id,
          defer_pending_ui = true,
        })
        runtime_status.refresh_context()
        render_switched_runtime(runtime, {
          root_file = root_file or runtime.branch_root,
          pending_request = pending_request or runtime.pending_extension_ui_request,
        })
        return
      end
      if item.runtime_key and not opts.waiting_only then
        local runtime = state.ensure_rpc_runtime(item.runtime_key)
        if switch_guard.same_runtime_key(runtime.key, state.rpc.active_key) then
          notify_already_current('Pi RPC branch is already current.')
          ui.focus_lower_panel()
        elseif activate_existing_branch_runtime then
          activate_existing_branch_runtime(runtime)
        end
        return
      end

      local pending_fork_rollback_runtime = nil
      local pending_fork_rollback_snapshot = nil
      local function remember_fork_rollback(runtime, snapshot)
        pending_fork_rollback_runtime = runtime
        pending_fork_rollback_snapshot = snapshot
      end
      local function clear_fork_rollback()
        pending_fork_rollback_runtime = nil
        pending_fork_rollback_snapshot = nil
      end
      local function rollback_pending_fork_binding()
        if pending_fork_rollback_runtime and pending_fork_rollback_snapshot then
          restore_runtime_tree_binding(pending_fork_rollback_runtime, pending_fork_rollback_snapshot)
        end
        clear_fork_rollback()
      end

      local function render_forked_context(fork_response)
        local loading_runtime = runtime_status.response_runtime(fork_response)
        local fork_response_active = runtime_status.response_is_active(fork_response)
        if fork_response and fork_response.success and not (fork_response.data and fork_response.data.cancelled) then
          if not fork_response_active then
            rollback_pending_fork_binding()
            state.set_runtime_loading(loading_runtime, false)
            return
          end
          renderer.clear(root_session_title(root_file))
          if root_file and root_file ~= '' then
            state.session.tree_root_file = root_file
          end
          if fork_response.data and fork_response.data.text then
            ui.set_input_text(fork_response.data.text)
          end
          rpc.request({ type = 'get_state' }, function(state_response)
            if state_response and state_response.success and state_response.data then
              local runtime = runtime_status.response_runtime(state_response)
              statusline.update_from_state(state_response.data, { runtime = runtime })
              if state_response.data.sessionFile then
                runtime.session_file = state_response.data.sessionFile
                runtime.branch_root = root_file or runtime.branch_root
                runtime.branch_entry_id = item.entry_id or runtime.branch_entry_id
                state.sync_active_rpc_runtime(runtime)
                if runtime_status.response_is_active(state_response) then
                  clear_fork_rollback()
                  state.session.current_file = state_response.data.sessionFile
                end
              end
              if runtime_status.response_is_active(state_response) then
                if root_file and root_file ~= '' then
                  state.session.tree_root_file = root_file
                end
                ui.refresh_chrome()
              end
            end
            if runtime_status.response_is_active(state_response) then
              M.render_current(root_session_title(root_file), false, {
                root_file = root_file,
                session_render = tree_branch_render_options(),
                prefer_last_user_title = true,
                on_done = function()
                  state.set_runtime_loading(loading_runtime, false)
                  ui.refresh_chrome()
                  ui.focus_lower_panel()
                end,
              })
              M.auto_name_branch_session(state_response.data.sessionFile, item.text)
            else
              rollback_pending_fork_binding()
              state.set_runtime_loading(loading_runtime, false)
              ui.refresh_chrome()
            end
          end)
        else
          rollback_pending_fork_binding()
          state.set_runtime_loading(loading_runtime, false)
          if fork_response_active then
            ui.refresh_chrome()
            if fork_response and fork_response.success and fork_response.data and fork_response.data.cancelled then
              renderer.append_system('Pi tree fork cancelled.')
            elseif fork_response and fork_response.error then
              renderer.append_system('Failed to fork Pi session: ' .. fork_response.error)
            end
          end
        end
      end

      local function switch_to_entry_session(path, title, switch_opts)
        switch_opts = switch_opts or {}
        local opts_for_switch = {
          title = title,
          tree_root_file = root_file,
          branch_entry_id = item.entry_id,
          force_switch = item.entry_id and current_entry_id and tostring(item.entry_id) ~= tostring(current_entry_id),
          focus_lower_after_switch = true,
          render_opts = {
            session_render = tree_branch_render_options(),
          },
        }
        local reusable_runtime = switch_opts.reuse_idle_runtime and reusable_idle_active_runtime()
        local reusable_snapshot = nil
        if reusable_runtime then
          reusable_snapshot = runtime_tree_binding_snapshot(reusable_runtime)
          bind_runtime_to_tree_selection(reusable_runtime, {
            label = session_display_title(title or 'Pi.dev session', root_file or path),
            session_file = path,
            branch_root = root_file,
            branch_entry_id = item.entry_id,
          })
          opts_for_switch.bind_runtime = false
        else
          opts_for_switch.runtime_key = path
        end
        M.switch_to(path, opts_for_switch, function(response)
          if response and response.success and runtime_status.response_is_active(response) then
            M.auto_name_branch_session(path, item.text)
            ui.clear_input()
          elseif reusable_runtime then
            restore_runtime_tree_binding(reusable_runtime, reusable_snapshot)
          end
        end)
      end

      local function existing_same_root_branch_path()
        if item.role ~= 'user' then
          return nil
        end
        local path = store.normalize_path(item.session_path)
        if not path or path == '' then
          return nil
        end
        local current_path = store.normalize_path(state.session.current_file)
        if current_path and path == current_path then
          return nil
        end
        local root_path = store.normalize_path(root_file)
        if not root_path or root_path == '' then
          return nil
        end
        local item_root = store.normalize_path(root_session_file(path))
        if item_root and item_root == root_path then
          return path
        end
        return nil
      end

      local function select_assistant_or_response()
        if not root_file or root_file == '' then
          renderer.append_system('Cannot navigate to tree entry without a session file.')
          return
        end
        local source_path = item.session_path or root_file
        local target_path, err = branched_session_path(source_path, item.entry_id)
        if not target_path then
          renderer.append_system('Failed to prepare tree branch: ' .. tostring(err))
          return
        end
        switch_to_entry_session(target_path, 'Pi.dev session', { reuse_idle_runtime = true })
      end

      local function fork_selected()
        if item.role ~= 'user' then
          select_assistant_or_response()
          return
        end
        local existing_branch_path = reusable_idle_active_runtime() and existing_same_root_branch_path() or nil
        if existing_branch_path then
          switch_to_entry_session(existing_branch_path, 'Pi.dev session', { reuse_idle_runtime = true })
          return
        end
        rpc.request({ type = 'fork', entryId = item.entry_id }, render_forked_context)
      end

      local fork_source_path = item.session_path or root_file
      local function switch_source_and_fork()
        local existing_branch_path = reusable_idle_active_runtime() and existing_same_root_branch_path() or nil
        if existing_branch_path then
          switch_to_entry_session(existing_branch_path, 'Pi.dev session', { reuse_idle_runtime = true })
          return
        end
        local switch_runtime = nil
        local switch_runtime_snapshot = nil
        if item.role == 'user' then
          local same_tree_position = current_entry_id and item.entry_id and tostring(item.entry_id) == tostring(current_entry_id)
          local reusable_runtime = not same_tree_position and reusable_idle_active_runtime() or nil
          if reusable_runtime then
            switch_runtime = reusable_runtime
            switch_runtime_snapshot = runtime_tree_binding_snapshot(reusable_runtime)
            bind_runtime_to_tree_selection(reusable_runtime, {
              label = 'Pi.dev branch: ' .. tostring(item.entry_id or ''),
              session_file = fork_source_path,
              branch_root = root_file,
              branch_entry_id = item.entry_id,
            })
          else
            switch_runtime = rpc.use_runtime(rpc.branch_key(root_file, item.entry_id), {
              label = 'Pi.dev branch: ' .. tostring(item.entry_id or ''),
              session_file = fork_source_path,
              branch_root = root_file,
              branch_entry_id = item.entry_id,
            })
          end
        end
        if fork_source_path and fork_source_path ~= '' and item.role == 'user' then
          local loading_runtime = state.set_runtime_loading(state.active_rpc_runtime(), true)
          ui.refresh_chrome()
          rpc.request({ type = 'switch_session', sessionPath = fork_source_path }, function(switch_response)
            if not runtime_status.response_is_active(switch_response) then
              if switch_runtime and switch_runtime_snapshot then
                restore_runtime_tree_binding(switch_runtime, switch_runtime_snapshot)
              end
              state.set_runtime_loading(runtime_status.response_runtime(switch_response) or loading_runtime, false)
              return
            end
            if switch_response and switch_response.success and not (switch_response.data and switch_response.data.cancelled) then
              if switch_runtime and switch_runtime_snapshot then
                remember_fork_rollback(switch_runtime, switch_runtime_snapshot)
              else
                clear_fork_rollback()
              end
              fork_selected()
            else
              if switch_runtime and switch_runtime_snapshot then
                restore_runtime_tree_binding(switch_runtime, switch_runtime_snapshot)
              end
              state.set_runtime_loading(loading_runtime, false)
              ui.refresh_chrome()
              if switch_response and switch_response.error then
                renderer.append_system('Failed to load Pi tree root session: ' .. switch_response.error)
              end
            end
          end)
        else
          fork_selected()
        end
      end

      switch_guard.confirm_running_switch(fork_source_path or root_file, switch_source_and_fork, nil, nil, root_session_file)
    end,
  })
end

function M.preload_tree(opts)
  opts = opts or {}
  if tree_preload_pending then
    return false
  end
  local current_path = store.normalize_path(opts.current_path or state.session.current_file)
  local root_file = root_session_file(current_path)
  if not root_file or root_file == '' then
    return false
  end
  if cached_tree_result(root_file, current_path) then
    return true
  end
  tree_preload_pending = true
  vim.defer_fn(function()
    tree_preload_pending = false
    local active_current = store.normalize_path(opts.current_path or state.session.current_file)
    local active_root = root_session_file(active_current)
    if not active_root or active_root == '' then
      return
    end
    pcall(tree_messages_from_file, active_root, active_current)
  end, math.max(0, tonumber(opts.delay_ms) or 250))
  return true
end

local function show_tree_from_current_file(opts)
  opts = opts or {}
  local current_path = store.normalize_path(state.session.current_file)
  local root_file
  if tree_cache and tree_cache.current_path == current_path and cache_stats_valid(tree_cache) then
    root_file = tree_cache.root_file
  else
    root_file = root_session_file(current_path)
  end
  if root_file and root_file ~= '' then
    state.session.tree_root_file = root_file
  end
  local file_messages, current_id = tree_messages_from_file(root_file, state.session.current_file)
  if file_messages and #file_messages > 0 then
    show_tree_messages(file_messages, root_file, current_id, opts)
    return true
  end
  return false
end

local function show_tree_from_rpc_fallback(opts)
  rpc.request({ type = 'get_fork_messages' }, function(response)
    if runtime_status.response_is_active(response) then
      show_tree_messages(response and response.success and response.data and response.data.messages or {}, nil, nil, opts)
    end
  end)
end

function M.tree()
  if show_tree_from_current_file() then
    return
  end

  rpc.request({ type = 'get_state' }, function(response)
    if response and response.success and response.data and response.data.sessionFile and runtime_status.response_is_active(response) then
      state.session.current_file = response.data.sessionFile
      if show_tree_from_current_file() then
        return
      end
    end
    if runtime_status.response_is_active(response) then
      show_tree_from_rpc_fallback()
    end
  end)
end

local function cycle_candidate_runtimes()
  return runtime_select.cycle_candidates()
end

activate_existing_branch_runtime = function(runtime)
  if not runtime or not runtime.key then
    return false
  end
  if switch_guard.same_runtime_key(runtime.key, state.rpc.active_key) then
    notify_already_current('Pi RPC branch is already current.')
    ui.focus_lower_panel()
    return false
  end
  ui.show()
  if state.ui.interaction then
    ui.close_interaction({ process_queue = false, save_runtime_interaction = true })
  end
  if runtime.session_file and runtime.session_file ~= '' then
    state.session.current_file = runtime.session_file
  end
  if runtime.branch_root and runtime.branch_root ~= '' then
    state.session.tree_root_file = runtime.branch_root
  end
  local pending_request = runtime.pending_extension_ui_request
  runtime = rpc.use_runtime(runtime.key, {
    label = runtime.label,
    session_file = runtime.session_file,
    branch_root = runtime.branch_root,
    branch_entry_id = runtime.branch_entry_id,
    defer_pending_ui = true,
  })
  runtime_status.refresh_context()
  render_switched_runtime(runtime, {
    root_file = runtime.branch_root,
    pending_request = pending_request or runtime.pending_extension_ui_request,
  })
  return true
end

local function cycle_rpc_runtime(direction)
  local runtimes = cycle_candidate_runtimes()
  if #runtimes == 0 then
    vim.notify('No running Pi RPC branch runtimes to cycle.', vim.log.levels.INFO)
    return false
  end

  local active_key = tostring(state.rpc.active_key or 'default')
  local selected = 1
  local active_index = nil
  for index, runtime in ipairs(runtimes) do
    if tostring(runtime.key or '') == active_key then
      active_index = index
      break
    end
  end
  if active_index then
    if #runtimes == 1 then
      vim.notify('Only one running Pi RPC branch runtime is attached.', vim.log.levels.INFO)
      return false
    end
    if direction == 'previous' then
      selected = ((active_index - 2) % #runtimes) + 1
    else
      selected = (active_index % #runtimes) + 1
    end
  end

  return activate_existing_branch_runtime(runtimes[selected])
end

function M.next_rpc()
  return cycle_rpc_runtime('next')
end

function M.previous_rpc()
  return cycle_rpc_runtime('previous')
end

local function waiting_runtime_count()
  return runtime_select.waiting_count(runtime_has_waiting_interaction)
end

function M.waiting()
  local opts = {
    waiting_only = true,
    title = 'Pi waiting input',
    message = 'Choose a branch currently waiting for input. Enter switches to that branch and reopens its pending interaction.',
    empty_message = 'No Pi branches are currently waiting for input.',
  }
  if waiting_runtime_count() == 0 then
    if state.ui.interaction and (state.ui.interaction.kind == 'waiting' or state.ui.interaction.title == opts.title) then
      ui.close_interaction({ process_queue = false })
    end
    vim.notify(opts.empty_message, vim.log.levels.INFO)
    return
  end
  if show_tree_from_current_file(opts) then
    return
  end

  rpc.request({ type = 'get_state' }, function(response)
    if response and response.success and response.data and response.data.sessionFile and runtime_status.response_is_active(response) then
      state.session.current_file = response.data.sessionFile
      if show_tree_from_current_file(opts) then
        return
      end
    end
    if runtime_status.response_is_active(response) then
      show_tree_from_rpc_fallback(opts)
    end
  end)
end

return M
