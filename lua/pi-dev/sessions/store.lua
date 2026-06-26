-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local config = require('pi-dev.config')
local format = require('pi-dev.format')

local M = {}

local parent_entry_ids_cache = {}

function M.root()
  return vim.fn.expand(config.options.session_root or '~/.pi/agent/sessions')
end

function M.normalize_path(path)
  if not path or path == '' then
    return nil
  end
  return vim.fn.fnamemodify(path, ':p'):gsub('/$', '')
end

function M.nvim_cwd()
  local ok, cwd = pcall(vim.fn.getcwd)
  if ok and cwd and cwd ~= '' then
    return cwd
  end
  return vim.uv.cwd()
end

function M.read_json_line(path, lnum)
  local ok, lines = pcall(vim.fn.readfile, path, '', lnum or 1)
  if not ok or not lines or not lines[lnum or 1] then
    return nil
  end
  local ok_json, decoded = pcall(vim.json.decode, lines[lnum or 1])
  if ok_json then
    return decoded
  end
  return nil
end

function M.stat_mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime and stat.mtime.sec or 0
end

function M.file_stat_signature(path)
  path = M.normalize_path(path)
  local stat = path and vim.uv.fs_stat(path) or nil
  if not stat then
    return nil
  end
  local mtime = stat.mtime or {}
  return {
    size = stat.size or 0,
    mtime_sec = mtime.sec or 0,
    mtime_nsec = mtime.nsec or 0,
  }
end

function M.same_stat(left, right)
  if left == nil or right == nil then
    return left == right
  end
  return left.size == right.size and left.mtime_sec == right.mtime_sec and left.mtime_nsec == right.mtime_nsec
end

function M.read_tail_lines(path, max_bytes)
  local file = io.open(path, 'rb')
  if not file then
    return nil
  end
  local size = file:seek('end') or 0
  local start = math.max(0, size - max_bytes)
  file:seek('set', start)
  local chunk = file:read('*a') or ''
  file:close()
  if start > 0 then
    chunk = chunk:gsub('^[^\n]*\n?', '')
  end
  local lines = vim.split(chunk, '\n', { plain = true })
  if lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

function M.last_entry_time(path)
  local lines = M.read_tail_lines(path, 64 * 1024)
  for index = #(lines or {}), 1, -1 do
    local line = (lines[index] or ''):gsub('\r$', '')
    local ok_json, entry = pcall(vim.json.decode, line)
    if ok_json and type(entry) == 'table' then
      local ts = format.timestamp_seconds(entry.timestamp)
      if ts then
        return ts
      end
    end
  end
  return 0
end

function M.activity_time(path)
  return math.max(M.stat_mtime(path), M.last_entry_time(path))
end

function M.load_entries(path, opts)
  opts = opts or {}
  path = M.normalize_path(path)
  if not path or path == '' then
    return nil, nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, nil
  end
  local header
  local entries = {}
  for _, line in ipairs(lines or {}) do
    local ok_json, entry = pcall(vim.json.decode, line)
    if ok_json and type(entry) == 'table' then
      if entry.type == 'session' then
        header = entry
      elseif entry.id then
        if opts.annotate_source then
          entry.__pi_source_path = path
        end
        table.insert(entries, entry)
      end
    end
  end
  return header, entries
end

function M.read_once(path)
  path = M.normalize_path(path)
  if not path or path == '' then
    return nil
  end
  local header, entries = M.load_entries(path, { annotate_source = true })
  if not header and not entries then
    return nil
  end
  return { path = path, header = header, entries = entries, stat = M.file_stat_signature(path) }
end

function M.lineage_files(path)
  path = M.normalize_path(path)
  if not path then
    return {}
  end
  local files = {}
  local seen = {}
  while path and path ~= '' and not seen[path] and vim.fn.filereadable(path) == 1 do
    seen[path] = true
    table.insert(files, 1, path)
    local header = M.read_json_line(path, 1)
    path = header and M.normalize_path(header.parentSession) or nil
  end
  return files
end

function M.parent_entry_ids(path)
  path = M.normalize_path(path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local stat = vim.uv.fs_stat(path)
  local signature = stat and table.concat({ stat.mtime and stat.mtime.sec or 0, stat.mtime and stat.mtime.nsec or 0, stat.size or 0 }, ':') or ''
  local cached = parent_entry_ids_cache[path]
  if cached and cached.signature == signature then
    return cached.ids
  end
  local ids = {}
  local _, entries = M.load_entries(path)
  for _, entry in ipairs(entries or {}) do
    if entry.id ~= nil and entry.id ~= '' then
      ids[tostring(entry.id)] = true
    end
  end
  parent_entry_ids_cache[path] = { signature = signature, ids = ids }
  return ids
end

function M.path_is_inside(path, dir)
  path = M.normalize_path(path)
  dir = M.normalize_path(dir)
  if not path or not dir then
    return false
  end
  return path == dir or vim.startswith(path, dir .. '/')
end

function M.same_directory(path, dir)
  path = M.normalize_path(path)
  dir = M.normalize_path(dir)
  return path ~= nil and dir ~= nil and M.normalize_path(vim.fn.fnamemodify(path, ':h')) == dir
end

function M.is_trash_path(path)
  local trash = M.normalize_path(vim.fs.joinpath(M.root(), '.trash'))
  path = M.normalize_path(path)
  return path ~= nil and trash ~= nil and M.path_is_inside(path, trash)
end

return M
