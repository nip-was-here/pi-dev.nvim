-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local config = require('pi-dev.config')

local M = {}

local active_watch

local function watcher_options()
  local defaults = config.defaults.compat.subagent.transcript
  local compat = config.options.compat
  local subagent = type(compat) == 'table' and compat.subagent or nil
  local configured = type(subagent) == 'table' and subagent.transcript or nil
  configured = type(configured) == 'table' and configured or {}
  local max_bytes = tonumber(configured.max_bytes) or defaults.max_bytes
  local poll_interval_ms = tonumber(configured.poll_interval_ms) or defaults.poll_interval_ms
  local debounce_ms = tonumber(configured.debounce_ms) or defaults.debounce_ms
  return {
    max_bytes = max_bytes > 0 and max_bytes or defaults.max_bytes,
    poll_interval_ms = poll_interval_ms > 0 and poll_interval_ms or defaults.poll_interval_ms,
    debounce_ms = debounce_ms >= 0 and debounce_ms or defaults.debounce_ms,
  }
end

local function close_handle(handle)
  if not handle then
    return
  end
  pcall(function()
    if not handle:is_closing() then
      handle:close()
    end
  end)
end

local function stop_watch(watch)
  if not watch or watch.stopped then
    return
  end
  watch.stopped = true
  for _, handle in ipairs({ watch.debounce, watch.poll, watch.event }) do
    if handle then
      pcall(handle.stop, handle)
      close_handle(handle)
    end
  end
  if active_watch == watch then
    active_watch = nil
  end
end

function M.stop()
  stop_watch(active_watch)
end

local function decode_records(data)
  local records = {}
  for line in tostring(data or ''):gmatch('[^\r\n]+') do
    local ok, record = pcall(vim.json.decode, line)
    if ok and type(record) == 'table' then
      table.insert(records, record)
    end
  end
  return records
end

local function read_transcript(watch)
  if watch.stopped or watch.reading then
    return
  end
  watch.reading = true
  vim.uv.fs_stat(watch.path, function(stat_error, stat)
    if watch.stopped then
      watch.reading = false
      return
    end
    if stat_error or not stat or stat.type ~= 'file' or not stat.size or stat.size <= 0 or stat.size > watch.max_bytes then
      watch.reading = false
      return
    end
    local signature = table.concat({ tostring(stat.size), tostring(stat.mtime and stat.mtime.sec or 0), tostring(stat.mtime and stat.mtime.nsec or 0) }, ':')
    if signature == watch.signature then
      watch.reading = false
      return
    end
    vim.uv.fs_open(watch.path, 'r', 438, function(open_error, fd)
      if open_error or not fd then
        watch.reading = false
        return
      end
      vim.uv.fs_read(fd, stat.size, 0, function(read_error, data)
        vim.uv.fs_close(fd, function() end)
        watch.reading = false
        if watch.stopped or read_error or type(data) ~= 'string' or data == '' then
          return
        end
        vim.schedule(function()
          if watch.stopped or active_watch ~= watch or not watch.is_current() then
            if not watch.stopped and not watch.is_current() then
              stop_watch(watch)
            end
            return
          end
          watch.signature = signature
          watch.on_records(decode_records(data))
        end)
      end)
    end)
  end)
end

local function schedule_read(watch)
  if watch.stopped then
    return
  end
  watch.debounce = watch.debounce or vim.uv.new_timer()
  watch.debounce:stop()
  watch.debounce:start(watch.debounce_ms, 0, function()
    read_transcript(watch)
  end)
end

function M.watch(opts)
  opts = opts or {}
  local path = type(opts.path) == 'string' and opts.path or nil
  if not path or path == '' or type(opts.on_records) ~= 'function' or type(opts.is_current) ~= 'function' then
    return false
  end
  M.stop()
  local watcher = watcher_options()
  local watch = {
    path = path,
    on_records = opts.on_records,
    is_current = opts.is_current,
    max_bytes = watcher.max_bytes,
    poll_interval_ms = watcher.poll_interval_ms,
    debounce_ms = watcher.debounce_ms,
    stopped = false,
    reading = false,
  }
  active_watch = watch
  watch.event = vim.uv.new_fs_event()
  local directory = vim.fn.fnamemodify(path, ':h')
  local filename = vim.fn.fnamemodify(path, ':t')
  local event_ok = pcall(function()
    watch.event:start(directory, {}, function(error, changed)
      if not error and (changed == nil or tostring(changed) == filename) then
        schedule_read(watch)
      end
    end)
  end)
  if not event_ok then
    close_handle(watch.event)
    watch.event = nil
  end
  watch.poll = vim.uv.new_timer()
  watch.poll:start(watch.poll_interval_ms, watch.poll_interval_ms, function()
    schedule_read(watch)
  end)
  schedule_read(watch)
  return true
end

return M
