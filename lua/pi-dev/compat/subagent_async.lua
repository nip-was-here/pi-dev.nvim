-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {}

local MAX_STATUS_BYTES = 2 * 1024 * 1024
local POLL_MS = 1000
local DEBOUNCE_MS = 50
local watches = {}

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
  if watch.debounce then
    watch.debounce:stop()
  end
  if watch.poll then
    watch.poll:stop()
  end
  if watch.event then
    watch.event:stop()
  end
  close_handle(watch.debounce)
  close_handle(watch.poll)
  close_handle(watch.event)
  if watches[watch.key] == watch then
    watches[watch.key] = nil
  end
end

function M.stop(key)
  stop_watch(watches[tostring(key or '')])
end

function M.stop_all()
  local active = {}
  for _, watch in pairs(watches) do
    table.insert(active, watch)
  end
  for _, watch in ipairs(active) do
    stop_watch(watch)
  end
end

local function terminal_state(status)
  local state = type(status) == 'table' and tostring(status.state or status.status or ''):lower() or ''
  return state == 'complete'
    or state == 'completed'
    or state == 'cancelled'
    or state == 'canceled'
    or state == 'error'
    or state == 'failed'
    or state == 'paused'
    or state == 'stopped'
    or state == 'detached'
    or state == 'rejected'
    or state == 'timed out'
    or state == 'timeout'
end

local function read_status(watch)
  if watch.stopped or watch.reading then
    return
  end
  watch.reading = true
  vim.uv.fs_stat(watch.status_path, function(stat_error, stat)
    if watch.stopped then
      watch.reading = false
      return
    end
    if stat_error or not stat or stat.type ~= 'file' or not stat.size or stat.size <= 0 or stat.size > MAX_STATUS_BYTES then
      watch.reading = false
      return
    end
    vim.uv.fs_open(watch.status_path, 'r', 438, function(open_error, fd)
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
          if watch.stopped or watches[watch.key] ~= watch or not watch.is_current() then
            if not watch.stopped and not watch.is_current() then
              stop_watch(watch)
            end
            return
          end
          local ok, status = pcall(vim.json.decode, data)
          if not ok or type(status) ~= 'table' then
            return
          end
          local signature = data
          if signature == watch.signature then
            return
          end
          watch.signature = signature
          watch.on_status(status)
          if terminal_state(status) then
            stop_watch(watch)
          end
        end)
      end)
    end)
  end)
end

local function schedule_read(watch)
  if watch.stopped then
    return
  end
  if not watch.debounce then
    watch.debounce = vim.uv.new_timer()
  end
  watch.debounce:stop()
  watch.debounce:start(DEBOUNCE_MS, 0, function()
    read_status(watch)
  end)
end

function M.watch(opts)
  opts = opts or {}
  local key = tostring(opts.key or '')
  local async_dir = type(opts.async_dir) == 'string' and opts.async_dir or nil
  if key == '' or not async_dir or async_dir == '' or type(opts.on_status) ~= 'function' or type(opts.is_current) ~= 'function' then
    return false
  end
  M.stop(key)
  local watch = {
    key = key,
    status_path = async_dir .. '/status.json',
    is_current = opts.is_current,
    on_status = opts.on_status,
    stopped = false,
    reading = false,
  }
  watches[key] = watch
  watch.event = vim.uv.new_fs_event()
  local event_ok = pcall(function()
    watch.event:start(async_dir, {}, function(error, filename)
      if not error and (filename == nil or tostring(filename) == 'status.json') then
        schedule_read(watch)
      end
    end)
  end)
  if not event_ok then
    close_handle(watch.event)
    watch.event = nil
  end
  watch.poll = vim.uv.new_timer()
  watch.poll:start(POLL_MS, POLL_MS, function()
    schedule_read(watch)
  end)
  schedule_read(watch)
  return true
end

return M
