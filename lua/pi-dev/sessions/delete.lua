-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local renderer = require('pi-dev.renderer')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local store = require('pi-dev.sessions.store')

local M = {}

local function read_header(path)
  return store.read_json_line(path, 1)
end

local function root_file(path)
  local lineage = store.lineage_files(path)
  if #lineage > 0 then
    return lineage[1]
  end
  return store.normalize_path(path)
end

local function session_name(path)
  path = store.normalize_path(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return 'Pi session'
  end
  local ok, lines = pcall(vim.fn.readfile, path, '', 160)
  if ok then
    for _, line in ipairs(lines or {}) do
      local ok_json, entry = pcall(vim.json.decode, line)
      if ok_json and type(entry) == 'table' and entry.type == 'session_info' and entry.name and entry.name ~= '' then
        return tostring(entry.name):gsub('\n.*$', '')
      end
    end
    for _, line in ipairs(lines or {}) do
      local ok_json, entry = pcall(vim.json.decode, line)
      if ok_json and type(entry) == 'table' and entry.type == 'message' and type(entry.message) == 'table' and entry.message.role == 'user' then
        local content = entry.message.content
        local text = type(content) == 'string' and content or type(content) == 'table' and vim.inspect(content) or nil
        text = text and vim.trim(text:gsub('%s+', ' ')) or nil
        if text and text ~= '' then
          return text:gsub('\n.*$', '')
        end
      end
    end
  end
  return vim.fn.fnamemodify(path, ':t')
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
    local header = headers and headers[path] or read_header(path)
    path = header and store.normalize_path(header.parentSession) or nil
  end
  return false
end

local function session_shares_root_entry(path, root_ids)
  if not root_ids or not next(root_ids) then
    return false
  end
  local _, entries = store.load_entries(path)
  for _, entry in ipairs(entries or {}) do
    if entry.id and root_ids[tostring(entry.id)] then
      return true
    end
  end
  return false
end

local function root_entry_ids(root)
  local ids = {}
  local _, entries = store.load_entries(root)
  for _, entry in ipairs(entries or {}) do
    if entry.id then
      ids[tostring(entry.id)] = true
    end
  end
  return ids
end

local function related_session_files(root, current_path)
  root = store.normalize_path(root)
  current_path = store.normalize_path(current_path)
  if not root or vim.fn.filereadable(root) ~= 1 then
    return {}
  end
  local root_ids = root_entry_ids(root)
  local headers = {}
  local files = {}
  local seen = {}
  local function add(path)
    path = store.normalize_path(path)
    if path and not seen[path] and vim.fn.filereadable(path) == 1 then
      seen[path] = true
      table.insert(files, path)
    end
  end

  for _, path in ipairs(vim.fn.globpath(store.root(), '**/*.jsonl', false, true) or {}) do
    local normalized = store.normalize_path(path)
    if normalized and not store.is_trash_path(normalized) then
      local header = read_header(normalized)
      if header and header.type == 'session' then
        headers[normalized] = header
      end
    end
  end

  for path in pairs(headers) do
    if path == root or path == current_path or session_reaches_root(path, root, headers) or session_shares_root_entry(path, root_ids) then
      add(path)
    end
  end
  add(root)
  add(current_path)

  table.sort(files, function(a, b)
    if a == root then
      return true
    end
    if b == root then
      return false
    end
    return tostring(a) < tostring(b)
  end)
  return files
end

local function runtime_belongs_to_plan(runtime, plan, file_set)
  if not runtime or not plan then
    return false
  end
  local session_file = store.normalize_path(runtime.session_file)
  local branch_root = store.normalize_path(runtime.branch_root)
  if session_file and file_set[session_file] then
    return true
  end
  if branch_root and branch_root == plan.root_path then
    return true
  end
  return false
end

local function stop_related_runtimes(plan)
  local file_set = {}
  for _, path in ipairs(plan.files or {}) do
    file_set[path] = true
  end
  local keys = {}
  for key, runtime in pairs(state.rpc.runtimes or {}) do
    if runtime_belongs_to_plan(runtime, plan, file_set) then
      table.insert(keys, key)
    end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    rpc.stop(key, { remove = true })
  end
  if not state.rpc.runtimes[state.rpc.active_key or 'default'] then
    state.set_active_rpc_runtime('default')
  end
  return #keys
end

local function sanitize_name(value)
  value = tostring(value or 'session'):gsub('[^%w%._%-]+', '-')
  value = value:gsub('^%-+', ''):gsub('%-+$', '')
  if value == '' then
    value = 'session'
  end
  return value:sub(1, 80)
end

local function relative_to_session_root(path)
  local root = store.normalize_path(store.root())
  path = store.normalize_path(path)
  if root and path and store.path_is_inside(path, root) then
    return path:sub(#root + 2)
  end
  return vim.fn.fnamemodify(path, ':t')
end

function M.plan_root(root_path, opts)
  opts = opts or {}
  local root = store.normalize_path(root_path)
  if not root or root == '' or vim.fn.filereadable(root) ~= 1 then
    return nil, 'Pi session root file is not readable.'
  end
  local current = store.normalize_path(opts.current_path) or root
  local files = related_session_files(root, current)
  return {
    current_path = current,
    root_path = root,
    display_name = opts.display_name or session_name(root),
    files = files,
    source = opts.source,
  }
end

function M.plan_current()
  local current = store.normalize_path(state.session.current_file)
  if not current or current == '' or vim.fn.filereadable(current) ~= 1 then
    return nil, 'No Pi session is currently open.'
  end
  local root = root_file(current)
  if not root or root == '' or vim.fn.filereadable(root) ~= 1 then
    return nil, 'Current Pi session file is not readable.'
  end
  return M.plan_root(root, { current_path = current })
end

function M.plan_resume_selection()
  local interaction = state.ui.interaction
  if not interaction or interaction.kind ~= 'resume' or type(interaction.items) ~= 'table' then
    return nil
  end
  local item = interaction.items[tonumber(interaction.selected) or 1]
  if not item or not item.root_path then
    return nil
  end
  local current_path = item.session and item.session.path or item.root_path
  return M.plan_root(item.root_path, {
    current_path = current_path,
    display_name = item.root_name,
    source = 'resume',
  })
end

function M.plan_contextual()
  local plan, err = M.plan_resume_selection()
  if plan then
    return plan
  end
  if err then
    return nil, err
  end
  return M.plan_current()
end

local function ensure_parent(path)
  return vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p') == 1 or vim.fn.isdirectory(vim.fn.fnamemodify(path, ':h')) == 1
end

local function trash_dir_for(plan)
  local stamp = os.date('!%Y%m%d-%H%M%S')
  local name = sanitize_name(plan.display_name or vim.fn.fnamemodify(plan.root_path, ':t'))
  local base = vim.fs.joinpath(store.root(), '.trash', 'pi-dev', stamp .. '-' .. name)
  local candidate = base
  local suffix = 1
  while vim.fn.isdirectory(candidate) == 1 do
    suffix = suffix + 1
    candidate = base .. '-' .. tostring(suffix)
  end
  return candidate
end

local function write_manifest(plan, trash_dir, entries)
  local manifest = {
    deletedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    mode = 'trash',
    rootPath = plan.root_path,
    sessionName = plan.display_name,
    files = entries,
  }
  local path = vim.fs.joinpath(trash_dir, 'manifest.json')
  ensure_parent(path)
  return vim.fn.writefile(vim.split(vim.json.encode(manifest), '\n', { plain = true }), path) == 0
end

function M.move_to_trash(plan)
  local trash_dir = trash_dir_for(plan)
  local entries = {}
  for _, from in ipairs(plan.files or {}) do
    local rel = relative_to_session_root(from)
    local to = vim.fs.joinpath(trash_dir, 'files', rel)
    ensure_parent(to)
    local ok = vim.fn.rename(from, to) == 0
    if not ok then
      return nil, 'failed to move session file to trash: ' .. tostring(from)
    end
    table.insert(entries, { from = from, to = 'files/' .. rel })
  end
  write_manifest(plan, trash_dir, entries)
  return { mode = 'trash', count = #entries, trash_dir = trash_dir }
end

function M.full_delete(plan)
  local count = 0
  for _, path in ipairs(plan.files or {}) do
    if vim.fn.filereadable(path) == 1 then
      local ok = vim.fn.delete(path) == 0
      if not ok then
        return nil, 'failed to delete session file: ' .. tostring(path)
      end
      count = count + 1
    end
  end
  return { mode = 'delete', count = count }
end

local function clear_deleted_current_session(plan)
  local current_root = root_file(state.session.current_file)
  if store.normalize_path(state.session.current_file) == plan.current_path or store.normalize_path(current_root) == plan.root_path then
    state.session.current_file = nil
    state.session.tree_root_file = nil
    state.session.auto_loaded_cwd = nil
  end
end

local function finish_success(plan, result)
  clear_deleted_current_session(plan)
  renderer.clear('Pi session deleted')
  if result.mode == 'trash' then
    renderer.append_system(string.format('Moved Pi session tree to trash: %d file%s.\nTrash: `%s`', result.count, result.count == 1 and '' or 's', result.trash_dir))
  else
    renderer.append_system(string.format('Permanently deleted Pi session tree: %d file%s.', result.count, result.count == 1 and '' or 's'))
  end
  require('pi-dev.ui').refresh_chrome()
end

function M.delete_current(callback)
  local plan, err = M.plan_contextual()
  if not plan then
    vim.notify(err, vim.log.levels.INFO)
    renderer.append_system(err)
    if callback then
      callback({ success = false, error = err })
    end
    return false
  end

  local choices = {
    { label = 'No', action = 'cancel' },
    { label = 'Yes, move session tree to trash', action = 'trash' },
    { label = 'Yes, fully delete session tree', action = 'delete' },
  }
  vim.ui.select(choices, {
    prompt = string.format('Delete current Pi session tree "%s"? This affects %d session file%s.', plan.display_name, #plan.files, #plan.files == 1 and '' or 's'),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice or choice.action == 'cancel' then
      if callback then
        callback({ success = false, cancelled = true })
      end
      return
    end
    stop_related_runtimes(plan)
    local result
    local delete_err
    if choice.action == 'trash' then
      result, delete_err = M.move_to_trash(plan)
    else
      result, delete_err = M.full_delete(plan)
    end
    if not result then
      vim.notify('pi-dev.nvim: ' .. tostring(delete_err), vim.log.levels.ERROR)
      renderer.append_system('Failed to delete Pi session tree: ' .. tostring(delete_err))
      if callback then
        callback({ success = false, error = delete_err })
      end
      return
    end
    finish_success(plan, result)
    if plan.source == 'resume' then
      vim.schedule(function()
        require('pi-dev.sessions').pick()
      end)
    end
    if callback then
      callback(vim.tbl_extend('force', { success = true }, result))
    end
  end)
  return true
end

return M
