-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {}

function M.truncate_display(text, max_width)
  text = tostring(text or '')
  max_width = math.max(1, tonumber(max_width) or 1)
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  local marker = '...'
  local marker_width = vim.fn.strdisplaywidth(marker)
  if max_width <= marker_width then
    return marker:sub(1, max_width)
  end
  local out = {}
  local width = 0
  local index = 0
  local limit = max_width - marker_width
  local chars = vim.fn.strchars(text)
  while index < chars do
    local char = vim.fn.strcharpart(text, index, 1)
    local char_width = vim.fn.strdisplaywidth(char)
    if width + char_width > limit then
      break
    end
    table.insert(out, char)
    width = width + char_width
    index = index + 1
  end
  return table.concat(out) .. marker
end

local function display_width(text)
  return vim.fn.strdisplaywidth(tostring(text or ''))
end

function M.prefixed_line(prefix, body, suffix, max_width, opts)
  opts = opts or {}
  prefix = tostring(prefix or '')
  body = tostring(body or '')
  suffix = tostring(suffix or '')
  max_width = math.max(1, tonumber(max_width) or 1)

  local meta = {
    body_truncated = false,
    suffix_visible = suffix == '',
    suffix_truncated = false,
  }

  local prefix_width = display_width(prefix)
  if prefix_width >= max_width then
    meta.body_truncated = body ~= ''
    meta.suffix_visible = false
    return M.truncate_display(prefix, max_width), meta
  end

  local body_width = max_width - prefix_width
  if suffix == '' then
    local rendered_body = M.truncate_display(body, body_width)
    meta.body_truncated = rendered_body ~= body
    return prefix .. rendered_body, meta
  end

  local gap_width = math.max(0, tonumber(opts.gap_width) or 1)
  local suffix_width = display_width(suffix)
  local preserve_suffix = opts.preserve_suffix ~= false
  local body_display_width = display_width(body)

  if body_display_width + gap_width + suffix_width <= body_width then
    local gap = gap_width
    if opts.align_suffix ~= false then
      gap = math.max(gap_width, max_width - prefix_width - body_display_width - suffix_width)
    end
    meta.suffix_visible = true
    return prefix .. body .. string.rep(' ', gap) .. suffix, meta
  end

  if opts.body_fraction and preserve_suffix then
    local fraction = math.max(0.1, math.min(0.9, tonumber(opts.body_fraction) or 0.5))
    local body_budget = math.floor((body_width - gap_width) * fraction)
    body_budget = math.max(1, body_budget)
    if opts.min_body_width then
      body_budget = math.max(body_budget, tonumber(opts.min_body_width) or body_budget)
    end
    body_budget = math.min(body_budget, math.max(1, body_width - gap_width - 1))
    local suffix_budget = math.max(1, body_width - body_budget - gap_width)
    local rendered_body = M.truncate_display(body, body_budget)
    local rendered_suffix = M.truncate_display(suffix, suffix_budget)
    local gap = gap_width
    if opts.align_suffix ~= false then
      gap = math.max(gap_width, max_width - prefix_width - display_width(rendered_body) - display_width(rendered_suffix))
    end
    meta.body_truncated = rendered_body ~= body
    meta.suffix_visible = true
    meta.suffix_truncated = rendered_suffix ~= suffix
    return prefix .. rendered_body .. string.rep(' ', gap) .. rendered_suffix, meta
  end

  if suffix_width + gap_width >= body_width then
    if preserve_suffix and body_width > gap_width then
      local min_body_width = math.max(0, tonumber(opts.min_body_width) or 0)
      min_body_width = math.min(min_body_width, math.max(0, body_width - gap_width - 1))
      if min_body_width > 0 and body ~= '' then
        local rendered_body = M.truncate_display(body, min_body_width)
        local suffix_budget = math.max(1, body_width - display_width(rendered_body) - gap_width)
        local rendered_suffix = M.truncate_display(suffix, suffix_budget)
        local gap = math.max(gap_width, max_width - prefix_width - display_width(rendered_body) - display_width(rendered_suffix))
        meta.body_truncated = rendered_body ~= body
        meta.suffix_visible = true
        meta.suffix_truncated = rendered_suffix ~= suffix
        return prefix .. rendered_body .. string.rep(' ', gap) .. rendered_suffix, meta
      end

      local rendered_suffix = M.truncate_display(suffix, body_width - gap_width)
      local gap = math.max(gap_width, max_width - prefix_width - display_width(rendered_suffix))
      meta.body_truncated = body ~= ''
      meta.suffix_visible = true
      meta.suffix_truncated = rendered_suffix ~= suffix
      return prefix .. string.rep(' ', gap) .. rendered_suffix, meta
    end

    local rendered_body = M.truncate_display(body, body_width)
    meta.body_truncated = rendered_body ~= body
    meta.suffix_visible = false
    return prefix .. rendered_body, meta
  end

  local rendered_body = M.truncate_display(body, body_width - suffix_width - gap_width)
  local gap = math.max(gap_width, max_width - prefix_width - display_width(rendered_body) - suffix_width)
  meta.body_truncated = rendered_body ~= body
  meta.suffix_visible = true
  return prefix .. rendered_body .. string.rep(' ', gap) .. suffix, meta
end

function M.right_suffix(label, suffix, max_width)
  local line = M.prefixed_line('', label, suffix, max_width, { preserve_suffix = false })
  return line
end

local function timezone_offset_seconds(tz)
  if tz == 'Z' or tz == 'z' or tz == nil or tz == '' then
    return 0
  end
  local sign, hours, minutes = tz:match('^([+-])(%d%d):?(%d%d)$')
  if not sign then
    return 0
  end
  local offset = (tonumber(hours) or 0) * 3600 + (tonumber(minutes) or 0) * 60
  if sign == '-' then
    offset = -offset
  end
  return offset
end

local function utc_epoch(parts)
  local local_epoch = os.time(parts)
  if not local_epoch then
    return nil
  end
  local utc_parts = os.date('!*t', local_epoch)
  if not utc_parts then
    return local_epoch
  end
  utc_parts.isdst = nil
  local utc_as_local = os.time(utc_parts)
  if not utc_as_local then
    return local_epoch
  end
  local local_offset = os.difftime(local_epoch, utc_as_local)
  return local_epoch + local_offset
end

function M.timestamp_seconds(value)
  if type(value) ~= 'string' then
    return nil
  end
  local year, month, day, hour, minute, second, tz = value:match(
    '^(%d%d%d%d)%-(%d%d)%-(%d%d)[T%s](%d%d):(%d%d):(%d%d)%.?%d*([Zz]?)$'
  )
  if not year then
    year, month, day, hour, minute, second, tz = value:match(
      '^(%d%d%d%d)%-(%d%d)%-(%d%d)[T%s](%d%d):(%d%d):(%d%d)%.?%d*([+-]%d%d:?%d%d)$'
    )
  end
  if year then
    local parts = {
      year = tonumber(year),
      month = tonumber(month),
      day = tonumber(day),
      hour = tonumber(hour),
      min = tonumber(minute),
      sec = tonumber(second),
      isdst = nil,
    }
    if tz and tz ~= '' then
      return utc_epoch(parts) - timezone_offset_seconds(tz)
    end
  end

  local normalized = value:gsub('%.%d+', ''):gsub('Z$', '')
  local ok, parsed = pcall(vim.fn.strptime, '%Y-%m-%dT%H:%M:%S', normalized)
  if ok and parsed and parsed > 0 then
    return parsed
  end
  return nil
end

function M.human_time_from_epoch(epoch)
  epoch = tonumber(epoch)
  if not epoch or epoch <= 0 then
    return nil
  end
  local now = os.time()
  if os.date('%Y-%m-%d', epoch) == os.date('%Y-%m-%d', now) then
    return os.date('%H:%M', epoch)
  end
  if os.date('%Y', epoch) == os.date('%Y', now) then
    return os.date('%b %d %H:%M', epoch)
  end
  return os.date('%Y-%m-%d %H:%M', epoch)
end

function M.human_time_from_timestamp(timestamp)
  if type(timestamp) == 'number' then
    if timestamp > 100000000000 then
      timestamp = math.floor(timestamp / 1000)
    end
    return M.human_time_from_epoch(timestamp)
  end
  if type(timestamp) ~= 'string' then
    return nil
  end
  return M.human_time_from_epoch(M.timestamp_seconds(timestamp))
end

function M.human_duration_from_milliseconds(milliseconds)
  local ms = tonumber(milliseconds)
  if not ms or ms < 0 then
    return nil
  end
  ms = math.floor(ms + 0.5)
  if ms < 1000 then
    return tostring(ms) .. 'ms'
  end

  local seconds = ms / 1000
  if seconds < 10 then
    local text = string.format('%.2fs', seconds)
    return text:gsub('0+s$', 's'):gsub('%.s$', 's')
  end
  if seconds < 60 then
    local text = string.format('%.1fs', seconds)
    return text:gsub('%.0s$', 's')
  end

  local whole_seconds = math.floor(seconds + 0.5)
  if whole_seconds < 3600 then
    return string.format('%dm %02ds', math.floor(whole_seconds / 60), whole_seconds % 60)
  end
  return string.format('%dh %02dm', math.floor(whole_seconds / 3600), math.floor((whole_seconds % 3600) / 60))
end

function M.window_text_width(win, fallback_width)
  local width = tonumber(fallback_width) or vim.o.columns
  local textoff = 0
  if win == 0 then
    win = vim.api.nvim_get_current_win()
  end
  if win and vim.api.nvim_win_is_valid(win) then
    width = vim.api.nvim_win_get_width(win)
    local info = vim.fn.getwininfo(win)[1]
    textoff = info and tonumber(info.textoff) or 0
  end
  width = math.min(width, vim.o.columns) - textoff
  return math.max(1, width)
end

return M
