-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local buffer = require('pi-dev.renderer.buffer')
local folds = require('pi-dev.renderer.folds')
local live = require('pi-dev.renderer.live')
local config = require('pi-dev.config')
local format = require('pi-dev.format')
local markdown = require('pi-dev.markdown')
local message_content = require('pi-dev.message_content')
local pipeline = require('pi-dev.render_pipeline')
local subagent = require('pi-dev.compat.subagent')
local state = require('pi-dev.state')

local M = {}

local diff_ns = buffer.diff_namespace()
-- Tool updates are slightly less urgent because they can carry larger payloads
-- and replace a bounded tool object.
local TOOL_FLUSH_DELAY_MS = 33

local flush_live_render
local cancel_live_render_timer
local flush_pending_tool_renders

local function refresh_chrome()
  local ok, ui = pcall(require, 'pi-dev.ui')
  if ok and ui.refresh_chrome then
    vim.schedule(ui.refresh_chrome)
  end
end

local output_buf = buffer.output_buf
local with_output_buf = buffer.with_output_buf
local line_count = buffer.line_count
local output_has_focus = buffer.output_has_focus
local scroll_output_to_bottom = buffer.scroll_output_to_bottom

local function scroll_output_to_bottom_if_unfocused()
  scroll_output_to_bottom()
end

local normalize_line_endings = pipeline.normalize_line_endings
local is_blank_line = pipeline.is_blank_line
local markdown_fence_marker = pipeline.markdown_fence_marker
local markdown_fence_closes = pipeline.markdown_fence_closes
local strip_markdown_quote_markers = pipeline.strip_markdown_quote_markers
local markdown_quote_line = pipeline.markdown_quote_line
local thinking_quote_line = pipeline.thinking_quote_line
local is_thinking_heading_line = pipeline.is_thinking_heading_line

local highlight_diff_lines = buffer.highlight_diff_lines
local detail_fold_start = folds.detail_start
local detail_fold_end = folds.detail_end
local with_preserved_win_view = folds.with_preserved_win_view
local delete_fold_at = folds.delete_at
local clear_output_folds = folds.clear_output
local apply_thinking_fold = folds.apply_thinking
local apply_thinking_folds_in_lines = folds.apply_thinking_in_lines
local apply_tool_fold = folds.apply_tool

local function refresh_rendered_output()
  -- Output/session renders should follow new content only while the user is
  -- elsewhere. If the output pane is focused, preserve the user's reading
  -- position and let markdown refresh happen without cursor/scroll movement.
  scroll_output_to_bottom_if_unfocused()
  -- render-markdown.nvim can still be parsing a previous buffer state when
  -- Pi appends streamed text. A trailing refresh after the normal near-frame
  -- refresh keeps the chat surface rendered even when no later output arrives.
  markdown.refresh_output({ settle_ms = 150 })
end

local function mark_render_activity(kind, notice_text)
  if kind == 'notice' then
    state.render.last_render_block_kind = 'notice'
    state.render.last_notice_text = notice_text
  else
    state.render.last_render_block_kind = kind or 'lines'
    state.render.last_notice_text = nil
  end
end

local function append_render_block(block)
  block = block or {}
  local lines = block.lines or {}
  local inserted_start

  with_output_buf(function(bufnr)
    local last = line_count(bufnr)
    local last_line = vim.api.nvim_buf_get_lines(bufnr, math.max(0, last - 1), last, false)[1] or ''
    lines = pipeline.prepare_append_lines(lines, last_line, { raw_spacing = block.raw_spacing })
    if #lines == 0 then
      return
    end
    inserted_start = last + 1
    vim.api.nvim_buf_set_lines(bufnr, last, last, false, lines)
    highlight_diff_lines(bufnr, last, lines)
  end)
  if #lines == 0 or not inserted_start then
    return nil, {}
  end
  mark_render_activity(block.kind or 'lines', block.notice_text)
  if not block.skip_refresh then
    refresh_rendered_output()
  end
  return inserted_start, lines
end

local function append_lines(lines, opts)
  opts = opts or {}
  return append_render_block({
    kind = opts.kind or 'lines',
    lines = lines,
    raw_spacing = opts.raw_spacing,
    notice_text = opts.notice_text,
    skip_refresh = opts.skip_refresh,
  })
end

local function keep_session_header_user_line_in_header(lines)
  if not ((lines or {})[1] or ''):match('^#%s+Pi%.dev%s+') then
    return lines
  end
  local last_user_index
  for index = 2, math.min(#lines, 8) do
    if tostring(lines[index] or ''):match('^>%s+Last user:') then
      last_user_index = index
      break
    end
    if tostring(lines[index] or ''):match('^##%s+') then
      break
    end
  end
  if not last_user_index or last_user_index == 2 then
    return lines
  end
  local last_user_line = table.remove(lines, last_user_index)
  while lines[2] ~= nil and pipeline.is_blank_line(lines[2]) do
    table.remove(lines, 2)
  end
  table.insert(lines, 2, last_user_line)
  if lines[3] ~= nil and not pipeline.is_blank_line(lines[3]) then
    table.insert(lines, 3, '')
  end
  return lines
end

local function replace_output_contents(lines, opts)
  opts = opts or {}
  lines = pipeline.prepare_block_lines(lines, { raw_spacing = opts.raw_spacing })
  lines = keep_session_header_user_line_in_header(lines)
  with_output_buf(function(bufnr)
    if opts.clear_diff ~= false then
      vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, 0, -1)
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    highlight_diff_lines(bufnr, 0, lines)
  end)
  mark_render_activity(opts.kind or 'replace')
  if not opts.skip_refresh then
    refresh_rendered_output()
  end
  return lines
end

local function prepare_new_block_append_lines(bufnr, lines, opts)
  local last = line_count(bufnr)
  local last_line = vim.api.nvim_buf_get_lines(bufnr, math.max(0, last - 1), last, false)[1] or ''
  return pipeline.prepare_append_lines(lines, last_line, opts)
end

local function prepare_existing_block_replace_lines(bufnr, block, lines, opts)
  local previous_line = ''
  if block and block.start_line and block.start_line > 1 then
    previous_line = vim.api.nvim_buf_get_lines(bufnr, block.start_line - 2, block.start_line - 1, false)[1] or ''
  end
  return pipeline.prepare_append_lines(lines, previous_line, opts)
end

local function append_text(text, opts)
  opts = opts or {}
  if not text or text == '' then
    return nil, nil
  end

  local changed_start
  local changed_end
  with_output_buf(function(bufnr)
    local pieces = vim.split(normalize_line_endings(text), '\n', { plain = true })
    local last_index = line_count(bufnr) - 1
    changed_start = last_index + 1
    local last_line = vim.api.nvim_buf_get_lines(bufnr, last_index, last_index + 1, false)[1] or ''
    vim.api.nvim_buf_set_lines(bufnr, last_index, last_index + 1, false, { last_line .. pieces[1] })

    if #pieces > 1 then
      vim.api.nvim_buf_set_lines(bufnr, line_count(bufnr), line_count(bufnr), false, vim.list_slice(pieces, 2))
    end
    changed_end = line_count(bufnr)
  end)
  if changed_start then
    mark_render_activity('text')
  end
  if not opts.skip_refresh then
    refresh_rendered_output()
  end
  return changed_start, changed_end
end

local function append_text_as_new_paragraph(text, opts)
  opts = opts or {}
  text = normalize_line_endings(text or ''):gsub('^\n+', '')
  if text == '' then
    return nil, nil
  end
  local changed_start
  local changed_end
  with_output_buf(function(bufnr)
    local pieces = vim.split(text, '\n', { plain = true })
    local last = line_count(bufnr)
    local last_line = vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ''
    local insert = {}
    if not last_line:match('^%s*$') then
      table.insert(insert, '')
    end
    vim.list_extend(insert, pieces)
    vim.api.nvim_buf_set_lines(bufnr, last, last, false, insert)
    changed_start = last + 1
    changed_end = last + #insert
  end)
  if changed_start then
    mark_render_activity('text')
  end
  if not opts.skip_refresh then
    refresh_rendered_output()
  end
  return changed_start, changed_end
end

local function trim_trailing_blank_lines(max_blank)
  max_blank = max_blank or 0
  with_output_buf(function(bufnr)
    local total = vim.api.nvim_buf_line_count(bufnr)
    local line = total
    local trailing = 0
    while line >= 1 do
      local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ''
      if not tostring(text):match('^%s*$') then
        break
      end
      trailing = trailing + 1
      line = line - 1
    end
    local remove = trailing - max_blank
    if remove > 0 then
      vim.api.nvim_buf_set_lines(bufnr, total - remove, total, false, {})
    end
  end)
end

local function split_text_lines(text, opts)
  opts = opts or {}
  local lines = vim.split(normalize_line_endings(text), '\n', { plain = true })
  if opts.trim_trailing_blank ~= false then
    while #lines > 0 and tostring(lines[#lines] or ''):match('^%s*$') do
      table.remove(lines)
    end
  end
  return lines
end

local function demote_markdown_heading_line(line)
  local indent, hashes, title = tostring(line or ''):match('^(%s*)(#+)%s+(.+)$')
  if not hashes or #hashes > 6 then
    return line
  end
  title = title:gsub('%s+#+%s*$', '')
  return indent .. '###### ' .. title
end

local function demote_assistant_markdown_lines(lines, initial_fence)
  local fence = initial_fence
  local out = {}
  for _, line in ipairs(lines or {}) do
    local marker = markdown_fence_marker(line)
    if fence then
      table.insert(out, line)
      if markdown_fence_closes(marker, fence) then
        fence = nil
      end
    else
      if marker then
        fence = marker
        table.insert(out, line)
      else
        table.insert(out, demote_markdown_heading_line(line))
      end
    end
  end
  return out, fence
end

local function demote_assistant_markdown_buffer_range(start_line, end_line, initial_fence)
  start_line = tonumber(start_line)
  end_line = tonumber(end_line)
  if not start_line or not end_line or end_line < start_line then
    return initial_fence, initial_fence
  end

  local final_fence = initial_fence
  local fence_before_last = initial_fence
  with_output_buf(function(bufnr)
    local total = vim.api.nvim_buf_line_count(bufnr)
    start_line = math.max(1, math.min(start_line, total))
    end_line = math.max(start_line, math.min(end_line, total))
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    local fence = initial_fence
    for index, line in ipairs(lines) do
      if index == #lines then
        fence_before_last = fence
      end
      local marker = markdown_fence_marker(line)
      if fence then
        if markdown_fence_closes(marker, fence) then
          fence = nil
        end
      elseif marker then
        fence = marker
      else
        lines[index] = demote_markdown_heading_line(line)
      end
    end
    final_fence = fence
    vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, lines)
  end)
  return final_fence, fence_before_last
end

local function remember_user_message(text)
  local trimmed = vim.trim(tostring(text or ''))
  if trimmed == '' then
    return
  end
  state.render.user_messages = state.render.user_messages or {}
  if state.render.user_messages[#state.render.user_messages] == trimmed then
    return
  end
  table.insert(state.render.user_messages, trimmed)
end

local function content_opts(opts)
  return vim.tbl_extend('force', { show_thinking = config.options.ui.render.show_thinking }, opts or {})
end

local function content_to_text(content, opts)
  return message_content.render_text(content, content_opts(opts))
end

local function user_content_lines(text)
  return split_text_lines(pipeline.format_user_skill_calls(text))
end

local function compact_header_text(text, max_chars)
  text = tostring(text or ''):gsub('%s+', ' ')
  max_chars = max_chars or 120
  if vim.fn.strchars(text) <= max_chars then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(0, max_chars - 3)) .. '...'
end

local tools = require('pi-dev.renderer.tools')
local tool_events = require('pi-dev.renderer.tool_events')

local tool_path = tools.path
local tool_identity = require('pi-dev.tool_identity')
local is_subagent_tool = subagent.is_tool
local compact_tool_input = tools.compact_input
local tool_args_to_lines = tools.args_to_lines
local result_to_lines = tools.result_to_lines

local render_tool_object

local function message_content_to_text(message, opts)
  return message_content.message_render_text(message, content_opts(opts))
end

local function output_line_width()
  local width = format.window_text_width(state.ui.output_win)
  local total_width = vim.o.columns
  local win = state.ui.output_win
  if win and vim.api.nvim_win_is_valid(win) then
    total_width = vim.api.nvim_win_get_width(win)
  end
  -- Fold columns can appear only after a tool block is folded. If we use the
  -- smaller post-fold textoff for later live Assistant headers, their timestamp
  -- suffix drifts left while earlier headers in the same output keep the old
  -- column. Keep the widest text area seen for the current window width; reset
  -- this cache on full renders/clears and when the window width changes.
  if state.render.output_line_total_width ~= total_width then
    state.render.output_line_total_width = total_width
    state.render.output_line_text_width = width
  else
    state.render.output_line_text_width = math.max(tonumber(state.render.output_line_text_width) or width, width)
  end
  return math.max(1, state.render.output_line_text_width or width)
end

local function compact_session_title_text(text)
  text = pipeline.normalize_line_endings(text or ''):gsub('%s+', ' ')
  text = vim.trim(text)
  if text == '' then
    return nil
  end
  return text
end

local function compact_session_user_text(text)
  return compact_session_title_text(pipeline.skill_call_label(text or '') or pipeline.format_user_skill_calls(text or ''))
end

local function last_user_title_from_render_messages(messages)
  for index = #(messages or {}), 1, -1 do
    local message = messages[index]
    if type(message) == 'table' and message.role == 'user' then
      local title = compact_session_user_text(message_content_to_text(message))
      if title then
        return title
      end
    end
  end
  return nil
end

local function session_title_summary(title)
  local value = tostring(title or '')
  local summary = value:match('^Pi%.dev session:%s*(.+)$') or value:match('^Pi chat:%s*(.+)$')
  if summary then
    summary = summary:gsub('%s+|%s+.+$', '')
  end
  return compact_session_title_text(summary)
end

local function session_title_fraction()
  local configured = config.options.ui and tonumber(config.options.ui.session_title_branch_fraction)
  if not configured then
    return 0.6
  end
  return math.max(0.1, math.min(0.9, configured))
end

local function native_session_title(title, latest_user_title, opts)
  opts = opts or {}
  local branch = session_title_summary(title) or compact_session_title_text(title) or 'current session'
  local latest = compact_session_title_text(latest_user_title)
  local prefix = 'Pi chat: '
  local width = math.max(1, output_line_width() - 4)
  if not latest or (latest == branch and not opts.latest_user_distinct) then
    return format.prefixed_line(prefix, branch, '', width)
  end

  local body_width = math.max(1, width - vim.fn.strdisplaywidth(prefix))
  return format.prefixed_line(prefix, branch, ' | ' .. latest, width, {
    align_suffix = false,
    body_fraction = session_title_fraction(),
    gap_width = 0,
    min_body_width = math.max(12, math.floor(body_width * session_title_fraction())),
  })
end

local function session_header_lines(title, _last_user_title)
  return { '# ' .. (title or 'Pi.dev session'), '' }
end

local function session_title_has_summary(title)
  return session_title_summary(title) ~= nil
end

local function session_title_can_follow_branch_tail()
  local title = tostring(state.ui.output_title or '')
  return title:match('^Pi%.dev session:?') ~= nil
    or title:match('^Pi chat:?') ~= nil
    or title == 'Pi.dev new session'
    or title == 'Pi.dev reloaded session'
    or title == 'Pi.dev forked session'
end

local function lock_session_title_if_summarized(title)
  state.render.session_title_locked = session_title_has_summary(title)
end

function M.update_session_header_user(text)
  if not session_title_can_follow_branch_tail() then
    return false
  end
  state.render.session_latest_user_title = compact_session_user_text(text)
  state.render.session_latest_user_distinct = state.render.session_branch_title ~= nil
  state.ui.output_title = native_session_title(state.render.session_branch_title or state.ui.output_title, state.render.session_latest_user_title, {
    latest_user_distinct = state.render.session_latest_user_distinct,
  })
  refresh_chrome()
  return true
end

function M.update_session_title(text, opts)
  opts = opts or {}
  if not opts.force and (state.render.session_title_locked or not session_title_can_follow_branch_tail()) then
    return false
  end
  local summary = compact_session_title_text(text)
  if not summary then
    return false
  end
  local prefix = 'Pi.dev session: '
  local title = format.prefixed_line(prefix, summary, '', math.max(1, output_line_width() - 4))
  state.render.session_branch_title = title
  if opts.reset_latest ~= false then
    state.render.session_latest_user_title = nil
    state.render.session_latest_user_distinct = false
  end
  state.ui.output_title = native_session_title(title, state.render.session_latest_user_title, {
    latest_user_distinct = state.render.session_latest_user_distinct,
  })
  state.render.session_title_locked = true
  local runtime = state.active_rpc_runtime and state.active_rpc_runtime() or nil
  if runtime then
    runtime.label = title
    state.sync_active_rpc_runtime(runtime)
  end
  with_output_buf(function(bufnr)
    local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ''
    if first:match('^#%s+Pi%.dev%s+') then
      vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { '# ' .. title })
    end
  end)
  refresh_chrome()
  return true
end

local function message_timestamp_value(message)
  if type(message) ~= 'table' then
    return nil
  end
  return message.__pi_timestamp
    or message.timestamp
    or message.createdAt
    or message.created_at
    or message.time
    or message.date
end

local function message_timestamp_suffix(message)
  if config.options.ui.render.show_timestamps == false then
    return nil
  end
  local label = format.human_time_from_timestamp(message_timestamp_value(message))
  return label and ('(' .. label .. ')') or nil
end

local function live_timestamp(event)
  local message = event and event.message
  return message_timestamp_value(event or {}) or message_timestamp_value(message or {}) or os.time()
end

local function right_aligned_heading(level, title, suffix, opts)
  opts = opts or {}
  local prefix = string.rep('#', level) .. ' '
  -- Keep timestamp/clock suffix on the same physical and visual row. Markdown
  -- renderers may conceal heading markers, so align suffixes against the
  -- message-heading marker width (`## `) rather than the current heading level.
  local render_margin = 4
  local message_prefix_width = vim.fn.strdisplaywidth('## ')
  local suffix_shift = tonumber(opts.suffix_shift) or 0
  local target_width = output_line_width() - message_prefix_width - render_margin + suffix_shift
  -- Also leave a small raw-buffer cushion: conceal/rendering plugins can keep
  -- Neovim's wrap boundary tied to the unconcealed text even when the visible
  -- text would fit, so a suffix at the exact edge may still wrap visually.
  local raw_nowrap_width = output_line_width() - vim.fn.strdisplaywidth(prefix) - 2 + suffix_shift
  local width = math.max(1, math.min(target_width, raw_nowrap_width))
  return format.prefixed_line(prefix, title, suffix or '', vim.fn.strdisplaywidth(prefix) + width)
end

local function markdown_heading(level, title, message)
  return right_aligned_heading(level, title, message_timestamp_suffix(message))
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

local function event_timestamp_milliseconds(event, fields, fallback_to_event_timestamp)
  for _, field in ipairs(fields or {}) do
    local ms = timestamp_milliseconds(event and event[field])
    if ms then
      return ms
    end
  end
  if fallback_to_event_timestamp then
    return timestamp_milliseconds(message_timestamp_value(event or {}))
  end
  return nil
end

local function event_duration_milliseconds(event)
  for _, field in ipairs({ 'durationMs', 'duration_ms', 'elapsedMs', 'elapsed_ms', 'executionTimeMs', 'execution_time_ms' }) do
    local value = tonumber(event and event[field])
    if value and value >= 0 then
      return value
    end
  end
  for _, field in ipairs({ 'durationSeconds', 'duration_seconds', 'elapsedSeconds', 'elapsed_seconds' }) do
    local value = tonumber(event and event[field])
    if value and value >= 0 then
      return value * 1000
    end
  end
  return nil
end

local function local_milliseconds()
  return math.floor(vim.uv.hrtime() / 1000000)
end

local function permission_wait_overlap_milliseconds(start_ms, end_ms, clock)
  start_ms = tonumber(start_ms)
  end_ms = tonumber(end_ms)
  if not start_ms or not end_ms or end_ms <= start_ms then
    return 0
  end
  local total = 0
  for _, block in pairs(state.render.permission_blocks or {}) do
    local permission_start
    local permission_end
    if clock == 'event' then
      permission_start = tonumber(block.started_at_ms)
      permission_end = tonumber(block.finished_at_ms)
    else
      permission_start = tonumber(block.local_started_at_ms)
      permission_end = tonumber(block.local_finished_at_ms)
    end
    if permission_start then
      permission_end = permission_end or end_ms
      local overlap_start = math.max(start_ms, permission_start)
      local overlap_end = math.min(end_ms, permission_end)
      if overlap_end > overlap_start then
        total = total + (overlap_end - overlap_start)
      end
    end
  end
  return total
end

local function tool_duration_suffix(object)
  if config.options.ui.render.show_timestamps == false or (object and object.result_continuation) then
    return nil
  end
  local label = format.human_duration_from_milliseconds(object and object.duration_ms)
  return label and ('(' .. label .. ')') or nil
end

local function subtract_permission_wait_from_duration(duration, object)
  duration = tonumber(duration)
  if not duration or not object or not object.started_at_ms or not object.finished_at_ms then
    return duration
  end
  local clock = object.started_at_ms_reliable and object.finished_at_ms_reliable and 'event' or 'local'
  local wait_ms = permission_wait_overlap_milliseconds(object.started_at_ms, object.finished_at_ms, clock)
  if wait_ms <= 0 then
    return duration
  end
  return math.max(0, duration - wait_ms)
end

local function update_tool_duration_from_bounds(object)
  if not object or object.duration_ms ~= nil or not object.started_at_ms or not object.finished_at_ms then
    return
  end
  local duration = object.finished_at_ms - object.started_at_ms
  if duration >= 0 then
    object.duration_ms = subtract_permission_wait_from_duration(duration, object)
  end
end

local function decode_tool_arguments(args)
  if type(args) ~= 'string' then
    return args
  end
  local trimmed = vim.trim(args)
  if not trimmed:match('^[%{%[]') then
    return args
  end
  local ok, decoded = pcall(vim.json.decode, trimmed)
  return ok and decoded or args
end

local function restored_tool_raw_id(item)
  if type(item) ~= 'table' then
    return nil
  end
  local id = item.id or item.toolCallId or item.tool_call_id or item.callId or item.toolUseId or item.tool_use_id
  return id ~= nil and id ~= '' and tostring(id) or nil
end

local function restored_tool_call_id(item)
  local id = restored_tool_raw_id(item)
  if id then
    return '__restored_tool_' .. id
  end
  state.render.restored_tool_counter = (state.render.restored_tool_counter or 0) + 1
  return '__restored_tool_' .. tostring(state.render.restored_tool_counter)
end

local function restored_tool_result_key(message)
  if type(message) ~= 'table' then
    return nil
  end
  local id = message.toolCallId or message.tool_call_id or message.callId or message.toolUseId or message.tool_use_id or message.id
  return id ~= nil and id ~= '' and tostring(id) or nil
end

local function restored_tool_result_payload(message)
  if type(message) ~= 'table' then
    return nil
  end
  return {
    content = message.content,
    output = message.output,
    text = message.text,
    result = message.result,
  }
end

local function restored_tool_timing(raw_id, name, args)
  if not state.active_rpc_runtime then
    return nil
  end
  local runtime = state.active_rpc_runtime()
  if raw_id and runtime and runtime.tool_timings then
    local timing = runtime.tool_timings[tostring(raw_id)]
    if timing then
      return timing
    end
  end
  local by_signature = runtime and runtime.tool_timings_by_signature or nil
  return by_signature and by_signature[tool_identity.signature(name, args)] or nil
end

local function restored_tool_object_from_item(item, attached_result)
  if type(item) ~= 'table' then
    return nil
  end
  local item_type = item.type
  if item_type ~= 'toolCall' and item_type ~= 'tool_call' and item_type ~= 'tool_use' and item_type ~= 'function_call' then
    return nil
  end
  local fn = type(item['function']) == 'table' and item['function'] or {}
  local name = item.name or item.toolName or item.tool_name or fn.name or 'tool'
  local args = item.arguments or item.args or item.input or item.parameters or fn.arguments
  local object = {
    id = restored_tool_call_id(item),
    name = tostring(name or 'tool'),
    args = decode_tool_arguments(args),
    duration_ms = event_duration_milliseconds(item),
    started_at_ms = timestamp_milliseconds(item.__pi_started_at or item.startedAt or item.started_at),
    finished_at_ms = timestamp_milliseconds(item.__pi_finished_at or item.finishedAt or item.finished_at),
  }
  update_tool_duration_from_bounds(object)
  if attached_result then
    object.status = 'Finished'
    object.result = restored_tool_result_payload(attached_result)
  end
  return object
end

local function restored_tool_objects_from_message(message)
  if not message or message.role ~= 'assistant' or type(message.content) ~= 'table' then
    return {}
  end
  local objects = {}
  local attached = message.__pi_restored_tool_results or {}
  local tool_index = 0
  for _, item in ipairs(message.content) do
    local key = restored_tool_raw_id(item)
    local object = restored_tool_object_from_item(item)
    if object then
      tool_index = tool_index + 1
      local attached_result = (key and attached[key]) or attached[tool_index]
      object = restored_tool_object_from_item(item, attached_result)
      object.started_at_ms = timestamp_milliseconds(message_timestamp_value(message))
      if attached_result then
        object.finished_at_ms = timestamp_milliseconds(message_timestamp_value(attached_result))
        object.duration_ms = event_duration_milliseconds(attached_result)
        update_tool_duration_from_bounds(object)
      end
      local timing = restored_tool_timing(key, object.name, object.args)
      if timing then
        object.started_at_ms = timing.started_at_ms or object.started_at_ms
        object.finished_at_ms = timing.finished_at_ms or object.finished_at_ms
        object.duration_ms = timing.duration_ms or object.duration_ms
      end
      table.insert(objects, object)
    end
  end
  return objects
end

local function attach_restored_tool_results(messages)
  local out = {}
  local pending = {}
  for _, message in ipairs(messages or {}) do
    if type(message) == 'table' and message.role == 'toolResult' then
      local key = restored_tool_result_key(message)
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
      if target then
        target.message.__pi_restored_tool_results = target.message.__pi_restored_tool_results or {}
        target.message.__pi_restored_tool_results[target.ordinal] = message
        if target.key then
          target.message.__pi_restored_tool_results[target.key] = message
        end
      else
        table.insert(out, message)
      end
    else
      local copy = message
      if type(message) == 'table' and message.role == 'assistant' and type(message.content) == 'table' then
        local ordinal = 0
        for _, item in ipairs(message.content) do
          if restored_tool_object_from_item(item) then
            if copy == message then
              copy = vim.deepcopy(message)
            end
            ordinal = ordinal + 1
            table.insert(pending, {
              message = copy,
              ordinal = ordinal,
              key = restored_tool_raw_id(item),
            })
          end
        end
      end
      table.insert(out, copy)
    end
  end
  return out
end

local function message_title(message)
  local role = message and message.role or 'message'
  if role == 'user' then
    return markdown_heading(2, 'User', message)
  end
  if role == 'assistant' then
    return markdown_heading(2, 'Assistant', message)
  end
  if role == 'toolResult' then
    local name = tostring(message.toolName or 'tool')
    return right_aligned_heading(3, 'Tool result: ' .. name, message_timestamp_suffix(message), { suffix_shift = -1 })
  end
  if role == 'bashExecution' then
    return right_aligned_heading(3, 'Tool: bash', message_timestamp_suffix(message), { suffix_shift = -1 })
  end
  if role == 'compactionSummary' then
    return markdown_heading(1, 'Compaction summary', message)
  end
  if role == 'branchSummary' then
    return markdown_heading(1, 'Branch summary', message)
  end
  if role == 'custom' and message.customType then
    return markdown_heading(1, '/' .. tostring(message.customType), message)
  end
  return markdown_heading(1, role:gsub('^%l', string.upper), message)
end

local function ensure_live_thinking_block()
  if state.render.assistant_thinking_block then
    return state.render.assistant_thinking_block
  end
  local block = {}
  with_output_buf(function(bufnr)
    local last = line_count(bufnr)
    local last_line = vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ''
    if last_line:match('^%s*$') then
      vim.api.nvim_buf_set_lines(bufnr, last - 1, last, false, { '> Thinking' })
      block.header_line = last
    else
      vim.api.nvim_buf_set_lines(bufnr, last, last, false, { '> Thinking' })
      block.header_line = last + 1
    end
    block.end_line = block.header_line
    block.body_at_line_start = true
  end)
  state.render.assistant_thinking_block = block
  return block
end

local function thinking_continuation_text(piece)
  local stripped, had_quote = strip_markdown_quote_markers(piece)
  return had_quote and stripped or tostring(piece or '')
end

local function cleanup_live_thinking_quote_lines(block, opts)
  opts = opts or {}
  local bufnr = output_buf()
  if not block or not block.end_line or not block.header_line or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if block.fold_start_line then
    delete_fold_at(block.fold_start_line)
  end
  with_output_buf(function(buf)
    local line = block.header_line + 1
    local last = math.min(block.end_line, vim.api.nvim_buf_line_count(buf))
    local cleanup_last = opts.keep_last_incomplete and math.max(block.header_line, last - 1) or last
    while line <= cleanup_last do
      local text = (vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''):gsub('[ \t]+$', '')
      if text:match('^%s*>%s*$') then
        vim.api.nvim_buf_set_lines(buf, line - 1, line, false, {})
        last = last - 1
        cleanup_last = cleanup_last - 1
      else
        vim.api.nvim_buf_set_lines(buf, line - 1, line, false, { text })
        line = line + 1
      end
    end
    block.end_line = last
    block.fold_start_line = nil
    block.fold_end_line = nil
  end)
end

local function append_live_thinking_text(text, opts)
  opts = opts or {}
  local block = ensure_live_thinking_block()
  local normalized = normalize_line_endings(text or '')
  if normalized == '' then
    return
  end
  with_output_buf(function(bufnr)
    local pieces = vim.split(normalized, '\n', { plain = true })
    local insert = {}
    local append_to_last = nil
    local at_line_start = block.body_at_line_start ~= false
    for index, piece in ipairs(pieces) do
      local starts_new_line = index > 1 or at_line_start
      if starts_new_line then
        if not is_thinking_heading_line(piece) then
          local quoted = thinking_quote_line(piece)
          if quoted and index == #pieces and normalized:sub(-1) ~= '\n' then
            quoted = markdown_quote_line(piece, '> ')
          end
          if quoted and not quoted:gsub('[ \t]+$', ''):match('^%s*>%s*$') then
            table.insert(insert, quoted)
          end
        end
      elseif piece ~= '' then
        append_to_last = (append_to_last or '') .. thinking_continuation_text(piece)
      end
    end
    if append_to_last and append_to_last ~= '' and block.end_line and block.end_line <= vim.api.nvim_buf_line_count(bufnr) then
      local last = vim.api.nvim_buf_get_lines(bufnr, block.end_line - 1, block.end_line, false)[1] or ''
      vim.api.nvim_buf_set_lines(bufnr, block.end_line - 1, block.end_line, false, { last .. append_to_last })
    end
    if #insert > 0 then
      if block.end_line == block.header_line then
        table.insert(insert, 1, '')
      end
      vim.api.nvim_buf_set_lines(bufnr, line_count(bufnr), line_count(bufnr), false, insert)
      block.end_line = (block.end_line or block.header_line) + #insert
    end
    block.body_at_line_start = normalized:sub(-1) == '\n'
  end)
  if normalized:find('\n', 1, true) then
    cleanup_live_thinking_quote_lines(block, { keep_last_incomplete = not block.body_at_line_start })
  end
  if not opts.defer_fold then
    apply_thinking_fold(block)
  end
  if not opts.skip_refresh then
    refresh_rendered_output()
  end
end

local function shift_blocks_after(line, delta, except_id)
  if delta == 0 then
    return
  end
  for id, block in pairs(state.render.tool_blocks) do
    if id ~= except_id and block.start_line and block.start_line > line then
      block.start_line = block.start_line + delta
      block.end_line = block.end_line + delta
      if block.fold_start_line then
        block.fold_start_line = block.fold_start_line + delta
        block.fold_end_line = block.fold_end_line + delta
      end
      for _, child in ipairs(block.child_folds or {}) do
        if child.start_line then
          child.start_line = child.start_line + delta
          child.end_line = child.end_line + delta
        end
      end
      for _, child in ipairs(block.subagent_children or {}) do
        if child.start_line then
          child.start_line = child.start_line + delta
          child.end_line = child.end_line + delta
        end
      end
    end
  end
  for _, block in pairs(state.render.permission_blocks or {}) do
    if block.start_line and block.start_line > line then
      block.start_line = block.start_line + delta
      block.end_line = block.end_line + delta
      if block.fold_start_line then
        block.fold_start_line = block.fold_start_line + delta
        block.fold_end_line = block.fold_end_line + delta
      end
    end
  end
end

local function delete_folds_in_range(win, start_line, end_line)
  local bufnr = output_buf()
  if not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  start_line = math.max(1, tonumber(start_line) or 1)
  end_line = math.min(total, tonumber(end_line) or start_line)
  if end_line < start_line then
    return
  end
  with_preserved_win_view(win, function()
    pcall(vim.cmd, string.format('%d,%dfolddelete!', start_line, end_line))
  end)
end

local function child_fold_states(block)
  local states = {}
  local win = state.ui.output_win
  if not block or not win or not vim.api.nvim_win_is_valid(win) then
    return states
  end
  vim.api.nvim_win_call(win, function()
    for _, child in ipairs(block.child_folds or {}) do
      if child.key and child.start_line and vim.fn.foldlevel(child.start_line) > 0 then
        states[child.key] = vim.fn.foldclosed(child.start_line) ~= -1
      end
    end
    for _, child in ipairs(block.child_detail_folds or {}) do
      if child.key and child.start_line and vim.fn.foldlevel(child.start_line) > 0 then
        states['details:' .. child.key] = vim.fn.foldclosed(child.start_line) ~= -1
      end
    end
  end)
  return states
end

local function apply_child_tool_folds(block, previous_states)
  if not block then
    return
  end
  if not block.child_folds_enabled then
    block.child_folds = nil
    return
  end
  local win = state.ui.output_win
  local bufnr = output_buf()
  if not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(1, tonumber(block.start_line) or 1)
  local end_line = math.min(total, tonumber(block.end_line) or start_line)
  if end_line <= start_line then
    block.child_folds = {}
    return
  end

  if not block.fold_start_line then
    delete_folds_in_range(win, start_line, end_line)
  end

  local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local headings = {}
  for offset, line in ipairs(buffer_lines) do
    local key = subagent.child_detail_fold_key(line)
    if key then
      table.insert(headings, { key = key, line = start_line + offset - 1 })
    end
  end
  block.child_folds = {}
  block.child_detail_folds = {}
  if #headings == 0 then
    return
  end

  with_preserved_win_view(win, function()
    vim.wo[win].foldmethod = 'manual'
    for index, heading in ipairs(headings) do
      local fold_start = heading.line + 1
      local fold_end = (headings[index + 1] and headings[index + 1].line - 1) or end_line
      while fold_end >= fold_start do
        local text = vim.api.nvim_buf_get_lines(bufnr, fold_end - 1, fold_end, false)[1] or ''
        if not is_blank_line(text) then
          break
        end
        fold_end = fold_end - 1
      end
      local detail_heading
      for line_number = heading.line + 1, fold_end do
        local text = vim.api.nvim_buf_get_lines(bufnr, line_number - 1, line_number, false)[1] or ''
        if text:match('^#####%#?%s+Details%s*$') then
          detail_heading = line_number
          break
        end
      end
      local detail_start = detail_heading and detail_heading + 1 or nil
      if detail_start and detail_start <= fold_end then
        local detail_key = 'details:' .. heading.key
        table.insert(block.child_detail_folds, { key = heading.key, start_line = detail_start, end_line = fold_end })
        if pcall(vim.cmd, string.format('%d,%dfold', detail_start, fold_end)) then
          pcall(vim.api.nvim_win_set_cursor, win, { detail_start, 0 })
          if previous_states and previous_states[detail_key] == false then
            vim.cmd('silent! normal! zo')
          else
            vim.cmd('silent! normal! zc')
          end
        end
      end
    end
  end)
end

local function replace_tool_block(tool_call_id, lines, opts)
  opts = opts or {}
  local block
  local previous_closed = nil
  local previous_child_states = nil
  with_output_buf(function(bufnr)
    block = state.render.tool_blocks[tool_call_id]
    if not block then
      local insert_lines = prepare_new_block_append_lines(bufnr, lines)
      local start_line = line_count(bufnr) + 1
      local start_index = line_count(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, start_index, start_index, false, insert_lines)
      highlight_diff_lines(bufnr, start_index, insert_lines)
      block = {
        start_line = start_line,
        end_line = start_line + #insert_lines - 1,
        always_fold = opts.always_fold == true,
        detail_offset = opts.detail_offset,
        child_folds_enabled = opts.child_folds == true,
      }
      state.render.tool_blocks[tool_call_id] = block
      return
    end

    previous_child_states = child_fold_states(block)
    if block.child_folds_enabled then
      delete_folds_in_range(state.ui.output_win, block.start_line, block.end_line)
    end
    if block.fold_start_line then
      local win = state.ui.output_win
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function()
          if vim.fn.foldlevel(block.fold_start_line) > 0 then
            previous_closed = vim.fn.foldclosed(block.fold_start_line) ~= -1
          end
        end)
      end
      delete_fold_at(block.fold_start_line)
    end

    block.always_fold = opts.always_fold == true
    block.detail_offset = opts.detail_offset
    block.child_folds_enabled = opts.child_folds == true
    local replace_lines = prepare_existing_block_replace_lines(bufnr, block, lines)
    local old_count = block.end_line - block.start_line + 1
    vim.api.nvim_buf_clear_namespace(bufnr, diff_ns, block.start_line - 1, block.end_line)
    vim.api.nvim_buf_set_lines(bufnr, block.start_line - 1, block.end_line, false, replace_lines)
    highlight_diff_lines(bufnr, block.start_line - 1, replace_lines)
    block.end_line = block.start_line + #replace_lines - 1
    shift_blocks_after(block.start_line, #replace_lines - old_count, tool_call_id)
  end)

  mark_render_activity('tool')
  if opts.skip_tool_fold == true then
    block.fold_start_line = nil
    block.fold_end_line = nil
    block.last_applied_fold_closed = nil
  else
    apply_tool_fold(block, previous_closed, { suppress_auto_close = opts.suppress_auto_fold == true })
  end
  local bufnr = output_buf()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and block and block.start_line and block.end_line then
    subagent.resolve_children(block, opts.subagent_children, vim.api.nvim_buf_get_lines(bufnr, block.start_line - 1, block.end_line, false))
  end
  apply_child_tool_folds(block, previous_child_states)
  if opts.child_folds == true and block and block.subagent_children then
    local ok, ui = pcall(require, 'pi-dev.ui')
    if ok and ui.refresh_subagent_view_from_parent then
      ui.refresh_subagent_view_from_parent(tool_call_id, block.subagent_children)
    end
  end
  refresh_rendered_output()
end

local function permission_id(id)
  if id ~= nil and id ~= '' then
    return tostring(id)
  end
  state.render.anonymous_permission_counter = (state.render.anonymous_permission_counter or 0) + 1
  return '__anonymous_permission_' .. tostring(state.render.anonymous_permission_counter)
end

local function permission_timestamp_milliseconds(opts, fields)
  opts = opts or {}
  for _, field in ipairs(fields or {}) do
    local value = opts[field]
    local ms = timestamp_milliseconds(value)
    if ms then
      return ms
    end
  end
  return timestamp_milliseconds(opts.timestamp)
end

local function permission_duration_milliseconds(block)
  if not block then
    return nil
  end
  local started = tonumber(block.started_at_ms)
  local finished = tonumber(block.finished_at_ms)
  if started and finished and finished >= started then
    return finished - started
  end
  local local_started = tonumber(block.local_started_at_ms)
  if local_started then
    local local_finished = tonumber(block.local_finished_at_ms) or local_milliseconds()
    if local_finished >= local_started then
      return local_finished - local_started
    end
  end
  if started then
    local now_epoch_ms = os.time() * 1000
    if now_epoch_ms >= started then
      return now_epoch_ms - started
    end
  end
  return nil
end

local function permission_duration_suffix(block)
  local duration = permission_duration_milliseconds(block)
  if not duration or duration < 1000 then
    return nil
  end
  local label = format.human_duration_from_milliseconds(duration)
  return label and ('(' .. label .. ')') or nil
end

local function cancel_permission_timer(id)
  local timers = state.render.permission_timers or {}
  local timer = timers[id]
  if timer then
    pcall(vim.fn.timer_stop, timer)
    timers[id] = nil
  end
end

local schedule_permission_timer

local function latest_subagent_permission_context_headers(permission_id)
  local id = state.render.last_tool_id
  local object = id and state.render.tool_objects and state.render.tool_objects[id]
  local block = id and state.render.tool_blocks and state.render.tool_blocks[id]
  if not (object and is_subagent_tool(object.name)) then
    block = nil
  end
  return subagent.permission_context_headers(block, permission_id, state.ui.subagent_view)
end

local function render_permission_block(block)
  local context_headers = block.subagent_context_headers or (block.subagent_context_header and { block.subagent_context_header }) or nil
  local header_level = '####'
  if context_headers and #context_headers > 0 then
    local parent_level = tostring(context_headers[#context_headers]):match('^(#+)') or '#####'
    header_level = string.rep('#', math.min(#parent_level + 1, 12))
  end
  local title = tostring(block.title or 'Permission request')
  if block.summary and block.summary ~= '' then
    title = title .. ': ' .. block.summary
  end
  if block.result and block.result ~= '' then
    title = title .. ' - ' .. compact_header_text(block.result)
  end
  local duration_suffix = permission_duration_suffix(block)
  local header = duration_suffix and right_aligned_heading(#header_level, title, duration_suffix, { suffix_shift = -1 })
    or (header_level .. ' ' .. title)
  local lines = { '' }
  for _, context_header in ipairs(context_headers or {}) do
    table.insert(lines, context_header)
    table.insert(lines, '')
  end
  table.insert(lines, header)
  if block.details and #block.details > 0 then
    table.insert(lines, '')
    vim.list_extend(lines, block.details)
  end
  return lines
end

local function fold_permission_block(block)
  local win = state.ui.output_win
  local bufnr = output_buf()
  if not block or not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local start_line = detail_fold_start(block)
  local end_line = detail_fold_end(block, start_line)
  if not start_line or not end_line or end_line <= start_line then
    return
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  if start_line > total then
    block.fold_start_line = nil
    block.fold_end_line = nil
    return
  end
  end_line = math.min(end_line, total)
  if end_line < start_line then
    block.fold_start_line = nil
    block.fold_end_line = nil
    return
  end

  block.fold_start_line = start_line
  block.fold_end_line = end_line
  with_preserved_win_view(win, function()
    vim.wo[win].foldmethod = 'manual'
    if pcall(vim.cmd, string.format('%d,%dfold', start_line, end_line)) then
      pcall(vim.api.nvim_win_set_cursor, win, { start_line, 0 })
      if state.render.auto_fold_suppressed == true then
        vim.cmd('silent! normal! zo')
      else
        vim.cmd('silent! normal! zc')
      end
    end
  end)
end

local function replace_permission_block(id, lines, should_fold)
  local block
  id = permission_id(id)
  with_output_buf(function(bufnr)
    state.render.permission_blocks = state.render.permission_blocks or {}
    block = state.render.permission_blocks[id]
    if not block or not block.start_line then
      local insert_lines = prepare_new_block_append_lines(bufnr, lines)
      local start_line = line_count(bufnr) + 1
      local start_index = line_count(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, start_index, start_index, false, insert_lines)
      block = block or {}
      block.start_line = start_line
      block.end_line = start_line + #insert_lines - 1
      state.render.permission_blocks[id] = block
      return
    end

    if block.fold_start_line then
      delete_fold_at(block.fold_start_line)
    end
    local replace_lines = prepare_existing_block_replace_lines(bufnr, block, lines)
    local old_count = block.end_line - block.start_line + 1
    vim.api.nvim_buf_set_lines(bufnr, block.start_line - 1, block.end_line, false, replace_lines)
    block.end_line = block.start_line + #replace_lines - 1
    shift_blocks_after(block.start_line, #replace_lines - old_count, nil)
  end)
  mark_render_activity('permission')
  if should_fold then
    fold_permission_block(block)
  end
  refresh_rendered_output()
  return id
end

schedule_permission_timer = function(id)
  id = permission_id(id)
  state.render.permission_timers = state.render.permission_timers or {}
  if state.render.permission_timers[id] then
    return
  end
  state.render.permission_timers[id] = vim.fn.timer_start(1000, function()
    state.render.permission_timers[id] = nil
    local block = state.render.permission_blocks and state.render.permission_blocks[id]
    if not block or block.result ~= nil then
      return
    end
    replace_permission_block(id, render_permission_block(block), false)
    schedule_permission_timer(id)
  end)
end

function M.subagent_child_at_line(line)
  line = tonumber(line)
  if not line then
    return nil
  end
  for id, block in pairs(state.render.tool_blocks or {}) do
    for _, child in ipairs(block.subagent_children or {}) do
      if child.start_line and child.end_line and line >= child.start_line and line <= child.end_line then
        local resolved = vim.deepcopy(child)
        resolved.parent_tool_call_id = id
        return resolved
      end
    end
  end
  return nil
end

function M.set_auto_fold_suppressed(suppressed)
  state.render.auto_fold_suppressed = suppressed == true
end

function M.auto_fold_suppressed()
  return state.render.auto_fold_suppressed == true
end

local function reset_render_state()
  cancel_live_render_timer()
  state.render.live_pending_segments = {}
  state.render.live_pending_bytes = 0
  state.render.pending_tool_flushes = {}
  state.render.output_scroll_pending = false
  state.render.output_line_total_width = nil
  state.render.output_line_text_width = nil
  for id in pairs(state.render.permission_timers or {}) do
    cancel_permission_timer(id)
  end
  state.render.permission_timers = {}
  state.render.tool_blocks = {}
  state.render.tool_objects = {}
  state.render.permission_blocks = {}
  state.render.anonymous_permission_counter = 0
  state.render.anonymous_tool_counter = 0
  state.render.last_tool_id = nil
  state.render.user_messages = {}
  state.render.pending_assistant_header = false
  state.render.pending_assistant_timestamp = nil
  state.render.assistant_title_text = nil
  state.render.assistant_has_content = false
  state.render.assistant_markdown_fence = nil
  state.render.assistant_markdown_fence_before_last_line = nil
  state.render.assistant_last_line = nil
  state.render.assistant_thinking_active = false
  state.render.assistant_thinking_at_line_start = true
  state.render.assistant_thinking_block = nil
  state.render.thinking_fold_starts = {}
  state.render.restored_tool_counter = 0
  state.render.last_render_block_kind = nil
  state.render.last_notice_text = nil
  state.render.session_title_locked = false
  state.render.session_header_last_user_text = nil
  state.render.session_latest_user_title = nil
  state.render.session_latest_user_distinct = false
  state.render.session_branch_title = nil
end

local function close_subagent_views_for_parent_render()
  local ok, ui = pcall(require, 'pi-dev.ui')
  if ok and ui.close_all_subagent_views then
    ui.close_all_subagent_views({ restore_buffer = false, restore_title = false })
  else
    state.ui.subagent_view = nil
  end
end

function M.clear(title)
  close_subagent_views_for_parent_render()
  state.ui.output_title = title or 'Pi chat'
  refresh_chrome()
  state.render.chunk_generation = (state.render.chunk_generation or 0) + 1
  reset_render_state()
  lock_session_title_if_summarized(state.ui.output_title)
  clear_output_folds()
  replace_output_contents({ '# ' .. (title or 'Pi chat'), '' })
end

local function apply_restored_tool_blocks(tool_blocks)
  local bufnr = output_buf()
  for _, spec in ipairs(tool_blocks or {}) do
    if spec.start_line and spec.line_count and spec.line_count > 0 then
      local block = {
        start_line = spec.start_line,
        end_line = spec.start_line + spec.line_count - 1,
        always_fold = spec.always_fold == true,
        detail_offset = spec.detail_offset,
        child_folds_enabled = spec.child_folds == true,
      }
      state.render.tool_blocks[spec.id] = block
      apply_tool_fold(block, nil)
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        subagent.resolve_children(block, spec.subagent_children, vim.api.nvim_buf_get_lines(bufnr, block.start_line - 1, block.end_line, false))
      end
      apply_child_tool_folds(block, nil)
    end
  end
end

local function is_restored_tool_boundary(line)
  line = tostring(line or '')
  return line:match('^#%s+') ~= nil or line:match('^##%s+') ~= nil or line:match('^###%s+Tool') ~= nil
end

local function restored_tool_end_index(lines, header_index)
  local fence = nil
  local index = header_index + 1
  while index <= #(lines or {}) do
    local line = lines[index]
    local marker = markdown_fence_marker(line)
    if fence then
      if markdown_fence_closes(marker, fence) then
        fence = nil
      end
    elseif marker then
      fence = marker
    elseif is_restored_tool_boundary(line) then
      local end_index = index - 1
      while end_index > header_index and is_blank_line(lines[end_index]) do
        end_index = end_index - 1
      end
      return end_index
    end
    index = index + 1
  end
  return #(lines or {})
end

local function resolve_restored_tool_blocks(tool_blocks, rendered_lines, base_line)
  base_line = base_line or 0
  local resolved = {}
  local search_start = 1
  for _, spec in ipairs(tool_blocks or {}) do
    local header_index
    if spec.header_text then
      for index = search_start, #(rendered_lines or {}) do
        if rendered_lines[index] == spec.header_text then
          header_index = index
          break
        end
      end
      if not header_index then
        for index, line in ipairs(rendered_lines or {}) do
          if line == spec.header_text then
            header_index = index
            break
          end
        end
      end
    end

    local copy = vim.deepcopy(spec)
    if header_index then
      local end_index = restored_tool_end_index(rendered_lines, header_index)
      copy.start_line = base_line + header_index
      copy.line_count = math.max(1, end_index - header_index + 1)
      search_start = header_index + 1
    elseif copy.start_line then
      copy.start_line = base_line + copy.start_line
    end
    table.insert(resolved, copy)
  end
  return resolved
end

local message_to_lines

local function append_message_render(lines, tool_blocks, message)
  local base = #lines
  local message_lines, message_tool_blocks = message_to_lines(message)
  vim.list_extend(lines, message_lines)
  for _, spec in ipairs(message_tool_blocks or {}) do
    spec.start_line = base + spec.rel_start
    table.insert(tool_blocks, spec)
  end
end

message_to_lines = function(message)
  local restored_tools = restored_tool_objects_from_message(message)
  local text = message_content_to_text(message, { skip_tool_calls = #restored_tools > 0 })
  local content_lines = split_text_lines(text)
  if message and message.role == 'assistant' then
    content_lines = demote_assistant_markdown_lines(content_lines)
  end
  if message and message.role == 'user' then
    remember_user_message(text)
    content_lines = user_content_lines(text)
  end
  if message and message.role == 'assistant' and #content_lines == 0 and #restored_tools == 0 then
    return {}, {}
  end
  if message and (message.role == 'thinking' or message.role == 'reasoning') then
    return content_lines, {}
  end
  if message and message.role == 'permission' then
    local lines = { '' }
    local details = type(message.__pi_permission_details) == 'table' and message.__pi_permission_details or nil
    local heading = markdown_heading(4, 'Permission request: ' .. text, message)
    table.insert(lines, heading)
    if details and #details > 0 then
      table.insert(lines, '')
      for _, detail in ipairs(details) do
        table.insert(lines, detail)
      end
    end
    return lines, {}
  end

  local lines = { '', message_title(message), '' }
  vim.list_extend(lines, content_lines)
  local tool_blocks = {}
  for _, object in ipairs(restored_tools) do
    if render_tool_object then
      local tool_lines = render_tool_object(object)
      local rel_start = #lines + 1
      vim.list_extend(lines, tool_lines)
      local header_text
      for _, line in ipairs(tool_lines) do
        if tostring(line or ''):match('^###%s+Tool:') then
          header_text = line
          break
        end
      end
      table.insert(tool_blocks, {
        id = object.id,
        rel_start = rel_start,
        line_count = #tool_lines,
        always_fold = is_subagent_tool(object.name),
        detail_offset = nil,
        header_text = header_text,
        child_folds = is_subagent_tool(object.name),
        subagent_children = tool_lines.__pi_subagent_children,
      })
    end
  end
  return lines, tool_blocks
end

function M.render_messages(messages, title, opts)
  close_subagent_views_for_parent_render()
  opts = opts or {}
  state.render.session_branch_title = title or 'Pi.dev session'
  state.render.session_latest_user_title = opts.last_user_title or last_user_title_from_render_messages(messages)
  state.render.session_latest_user_distinct = opts.last_user_distinct == true
  state.ui.output_title = native_session_title(state.render.session_branch_title, state.render.session_latest_user_title, {
    latest_user_distinct = state.render.session_latest_user_distinct,
  })
  refresh_chrome()
  state.render.chunk_generation = (state.render.chunk_generation or 0) + 1
  reset_render_state()
  state.render.session_branch_title = title or 'Pi.dev session'
  state.render.session_latest_user_title = opts.last_user_title or last_user_title_from_render_messages(messages)
  state.render.session_latest_user_distinct = opts.last_user_distinct == true
  if opts.lock_session_title == false then
    state.render.session_title_locked = false
  else
    lock_session_title_if_summarized(state.render.session_branch_title)
  end
  clear_output_folds()
  messages = attach_restored_tool_results(messages or {})
  opts.last_user_title = state.render.session_latest_user_title
  local lines = session_header_lines(title, opts.last_user_title)
  local tool_blocks = {}
  for _, message in ipairs(messages or {}) do
    append_message_render(lines, tool_blocks, message)
  end
  lines = replace_output_contents(lines, { skip_refresh = true })
  tool_blocks = resolve_restored_tool_blocks(tool_blocks, lines, 0)
  apply_restored_tool_blocks(tool_blocks)
  apply_thinking_folds_in_lines(lines, 1)
  refresh_rendered_output()
end

function M.render_messages_chunked(messages, title, opts)
  close_subagent_views_for_parent_render()
  opts = opts or {}
  state.render.session_branch_title = title or 'Pi.dev session'
  state.render.session_latest_user_title = opts.last_user_title or last_user_title_from_render_messages(messages)
  state.render.session_latest_user_distinct = opts.last_user_distinct == true
  state.ui.output_title = native_session_title(state.render.session_branch_title, state.render.session_latest_user_title, {
    latest_user_distinct = state.render.session_latest_user_distinct,
  })
  refresh_chrome()
  state.render.chunk_generation = (state.render.chunk_generation or 0) + 1
  local generation = state.render.chunk_generation
  reset_render_state()
  state.render.session_branch_title = title or 'Pi.dev session'
  state.render.session_latest_user_title = opts.last_user_title or last_user_title_from_render_messages(messages)
  state.render.session_latest_user_distinct = opts.last_user_distinct == true
  if opts.lock_session_title == false then
    state.render.session_title_locked = false
  else
    lock_session_title_if_summarized(state.render.session_branch_title)
  end
  clear_output_folds()
  messages = attach_restored_tool_results(messages or {})
  opts.last_user_title = state.render.session_latest_user_title
  local header = session_header_lines(title, opts.last_user_title)
  if opts.notice and opts.notice ~= '' then
    vim.list_extend(header, vim.split(opts.notice, '\n', { plain = true }))
    table.insert(header, '')
  end
  header = replace_output_contents(header)

  local index = 1
  local chunk_size = math.max(1, tonumber(opts.chunk_size) or 100)
  local delay = math.max(0, tonumber(opts.chunk_delay_ms) or 0)
  local budget_ms = math.max(0, tonumber(opts.chunk_budget_ms) or 8)
  local done = false
  local function finish()
    if done or generation ~= state.render.chunk_generation then
      return
    end
    done = true
    if opts.on_done then
      opts.on_done()
    end
    if flush_pending_tool_renders then
      flush_pending_tool_renders()
    end
    if opts.open_auto_folds_on_done == true and M.open_latest_auto_folds then
      M.open_latest_auto_folds()
    end
    if opts.scroll_to_bottom_on_done then
      scroll_output_to_bottom({ force = true })
    end
  end
  local function render_one_chunk()
    local stop = math.min(#messages, index + chunk_size - 1)
    local chunk = {}
    local tool_blocks = {}
    for i = index, stop do
      append_message_render(chunk, tool_blocks, messages[i])
    end
    local inserted_start, inserted_lines = append_lines(chunk, { skip_refresh = true })
    if inserted_start then
      tool_blocks = resolve_restored_tool_blocks(tool_blocks, inserted_lines, inserted_start - 1)
      apply_restored_tool_blocks(tool_blocks)
      apply_thinking_folds_in_lines(inserted_lines, inserted_start)
      refresh_rendered_output()
    end
    index = stop + 1
  end
  local function step()
    if generation ~= state.render.chunk_generation then
      return
    end
    if index > #messages then
      finish()
      return
    end
    local started = vim.uv.hrtime() / 1e6
    repeat
      render_one_chunk()
    until index > #messages or budget_ms == 0 or ((vim.uv.hrtime() / 1e6) - started) >= budget_ms
    if index <= #messages then
      vim.defer_fn(step, delay)
    else
      finish()
    end
  end
  if delay == 0 then
    step()
  else
    vim.defer_fn(step, delay)
  end
end

local function append_notice(text)
  local notice_text = pipeline.normalize_line_endings(text or '')
  if state.render.last_render_block_kind == 'notice' and state.render.last_notice_text == notice_text then
    return
  end
  append_lines(pipeline.notice_lines(notice_text), { kind = 'notice', notice_text = notice_text })
end

local function mcp_auth_notice(event)
  local server = tostring(event and event.server or 'server')
  local url = tostring(event and event.url or '')
  if url == '' then
    return nil
  end
  local complete = string.format(
    [[mcp({ action: "auth-complete", server: "%s", args: '{"redirectUrl":"PASTE_REDIRECT_URL_HERE"}' })]],
    server:gsub('"', '\\"')
  )
  return table.concat({
    'MCP OAuth required for `' .. server .. '`.',
    '',
    'Open this URL in your browser:',
    url,
    '',
    'After approval, copy the final localhost redirect URL from the browser address bar and send it back with:',
    complete,
  }, '\n')
end

local function update_notice_from_event(event)
  if type(event) ~= 'table' then
    return nil
  end
  local text = event.message or event.text or event.notice
  if type(text) == 'string' and pipeline.is_pi_update_notice(text) then
    return text
  end
  local release = type(event.release) == 'table' and event.release or type(event.data) == 'table' and event.data.release or nil
  local version = release and release.version or event.version
  if version then
    local lines = { 'Update Available', 'New version ' .. tostring(version) .. ' is available. Run pi update' }
    local note = release and release.note or event.note
    if type(note) == 'string' and vim.trim(note) ~= '' then
      table.insert(lines, vim.trim(note))
    end
    table.insert(lines, 'Changelog: https://pi.dev/changelog')
    return table.concat(lines, '\n')
  end
  local packages = event.packages or (type(event.data) == 'table' and event.data.packages or nil)
  if type(packages) == 'table' and #packages > 0 then
    return 'Package updates are available. Run pi update\nPackages:\n- ' .. table.concat(vim.tbl_map(tostring, packages), '\n- ')
  end
  return nil
end

function M.append_user(text, timestamp)
  flush_live_render()
  if flush_pending_tool_renders then
    flush_pending_tool_renders()
  end
  local formatted_user_text = pipeline.format_user_skill_calls(text or '')
  local title_updated = M.update_session_title(formatted_user_text)
  if not title_updated then
    M.update_session_header_user(text or '')
  end
  state.render.last_user_text = vim.trim(formatted_user_text)
  state.render.pending_assistant_header = false
  state.render.assistant_has_content = false
  remember_user_message(text)
  local lines = pipeline.message_block(message_title({ role = 'user', __pi_timestamp = timestamp or os.time() }), user_content_lines(text))
  append_lines(lines, { kind = 'message' })
end

function M.append_system(text)
  flush_live_render()
  if flush_pending_tool_renders then
    flush_pending_tool_renders()
  end
  append_notice(tostring(text or ''))
end

function M.append_user_cancelled()
  append_notice('_User cancelled._')
end

local function upsert_permission_block(id, spec, opts)
  opts = opts or {}
  spec = spec or {}
  id = permission_id(id)
  state.render.permission_blocks = state.render.permission_blocks or {}
  local block = state.render.permission_blocks[id] or {}
  block.title = spec.title
  block.summary = spec.summary
  block.started_at_ms = block.started_at_ms or permission_timestamp_milliseconds(opts, { 'startedAt', 'started_at', 'startTime', 'start_time' })
  block.local_started_at_ms = block.local_started_at_ms or tonumber(opts.local_started_at_ms) or local_milliseconds()
  block.finished_at_ms = spec.finished and (permission_timestamp_milliseconds(opts, { 'finishedAt', 'finished_at', 'endedAt', 'ended_at', 'endTime', 'end_time' }) or block.finished_at_ms) or nil
  block.local_finished_at_ms = spec.finished and (tonumber(opts.local_finished_at_ms) or local_milliseconds()) or nil
  block.subagent_context_headers = block.subagent_context_headers or latest_subagent_permission_context_headers(id)
  block.subagent_context_header = block.subagent_context_headers and block.subagent_context_headers[1] or block.subagent_context_header
  if type(spec.details) == 'table' then
    block.details = spec.details
  else
    block.details = vim.split(tostring(spec.details or ''), '\n', { plain = true })
  end
  block.result = spec.result
  state.render.permission_blocks[id] = block
  replace_permission_block(id, render_permission_block(block), spec.fold == true)
  return id
end

function M.append_permission_request(id, summary, details, opts)
  opts = opts or {}
  flush_live_render()
  if flush_pending_tool_renders then
    flush_pending_tool_renders()
  end
  M.update_session_title('Permission: ' .. tostring(summary or ''))
  id = upsert_permission_block(id, {
    title = 'Permission request',
    summary = summary,
    details = details,
    result = nil,
    finished = false,
    fold = false,
  }, opts)
  if schedule_permission_timer then
    schedule_permission_timer(id)
  end
  return id
end

function M.finish_permission_request(id, result, opts)
  opts = opts or {}
  flush_live_render()
  if flush_pending_tool_renders then
    flush_pending_tool_renders()
  end
  id = permission_id(id)
  local block = state.render.permission_blocks and state.render.permission_blocks[id]
  if not block then
    return false
  end
  cancel_permission_timer(id)
  block.result = tostring(result or '')
  block.finished_at_ms = permission_timestamp_milliseconds(opts, { 'finishedAt', 'finished_at', 'endedAt', 'ended_at', 'endTime', 'end_time' }) or block.finished_at_ms
  block.local_finished_at_ms = tonumber(opts.local_finished_at_ms) or local_milliseconds()
  replace_permission_block(id, render_permission_block(block), true)
  return true
end

local function append_detail(lines, body)
  if not body or #body == 0 then
    return
  end
  if #lines > 0 and lines[#lines] ~= '' then
    table.insert(lines, '')
  end
  vim.list_extend(lines, body)
  if body.__pi_subagent_children then
    lines.__pi_subagent_children = body.__pi_subagent_children
  end
end

local function tool_title_and_truncation(tool_name, summary, suffix)
  local title = string.format('Tool: %s', tool_name or 'tool')
  local heading_opts = { suffix_shift = suffix and suffix ~= '' and -1 or -5 }
  if not summary or summary == '' then
    return right_aligned_heading(3, title, suffix, heading_opts), false
  end

  local text = vim.trim(pipeline.normalize_line_endings(summary):gsub('%s+', ' '))
  local line, meta = right_aligned_heading(3, title .. ' ' .. text, suffix, heading_opts)
  return line, meta and meta.body_truncated == true
end

local function tool_status_label(status)
  if status == 'Running' then
    return 'run'
  end
  if status == 'Finished' then
    return 'done'
  end
  return status
end

render_tool_object = function(object, opts)
  opts = opts or {}
  local show_args = config.options.ui.render.show_tool_arguments ~= false
  local summary, input_lines, omit_input_detail
  if show_args then
    summary, input_lines, omit_input_detail = compact_tool_input(object.name, object.args)
  end
  local title, summary_truncated
  local duration_suffix = tool_duration_suffix(object)
  if object.result_continuation then
    title = right_aligned_heading(4, 'Result:', duration_suffix)
    summary_truncated = false
    omit_input_detail = false
  else
    title, summary_truncated = tool_title_and_truncation(object.name, summary, duration_suffix)
  end

  local lines = { '', title }
  local display_status = tool_status_label(object.status)
  if display_status and display_status ~= '' then
    table.insert(lines, '_' .. display_status .. '_')
  end
  if show_args and object.args ~= nil and (summary_truncated or not omit_input_detail) then
    append_detail(lines, input_lines or tool_args_to_lines(object.name, object.args))
  end
  if object.partial_result ~= nil then
    append_detail(lines, result_to_lines(object.partial_result, object.name, object.args, {
      lazy_subagent_details = opts.lazy_subagent_details == true,
      subagent_parent_summary_only = is_subagent_tool(object.name),
    }))
  end
  if object.result ~= nil then
    append_detail(lines, result_to_lines(object.result, object.name, object.args, {
      lazy_subagent_details = opts.lazy_subagent_details == true,
      subagent_parent_summary_only = is_subagent_tool(object.name),
    }))
  end
  return lines
end

local function render_tool_object_by_id(id)
  local object = id and state.render.tool_objects and state.render.tool_objects[id]
  if not object then
    return
  end
  local running_bash = tostring(object.name or '') == 'bash' and object.status == 'Running'
  local subagent_tool = is_subagent_tool(object.name)
  local block = state.render.tool_blocks and state.render.tool_blocks[id]
  local lazy_subagent_details = subagent_tool and object.status == 'Running' and not (block and block.force_open)
  local lines = render_tool_object(object, { lazy_subagent_details = lazy_subagent_details })
  local signature = table.concat(lines, '\n')
  if block and block.last_render_signature == signature then
    return
  end
  local skip_running_subagent_fold = subagent_tool and object.status == 'Running' and object.partial_result ~= nil
  replace_tool_block(id, lines, {
    always_fold = subagent_tool and object.status ~= 'Running',
    detail_offset = nil,
    suppress_auto_fold = running_bash or subagent_tool,
    child_folds = subagent_tool,
    skip_tool_fold = skip_running_subagent_fold,
    subagent_children = lines.__pi_subagent_children,
  })
  block = state.render.tool_blocks and state.render.tool_blocks[id]
  if block then
    block.last_render_signature = signature
  end
end

local function clear_pending_tool_flush(id)
  local pending = state.render.pending_tool_flushes and state.render.pending_tool_flushes[id]
  if pending then
    pending.scheduled = false
    state.render.pending_tool_flushes[id] = nil
  end
end

flush_pending_tool_renders = function()
  local pending = state.render.pending_tool_flushes or {}
  local ids = {}
  for id, item in pairs(pending) do
    if item and item.scheduled then
      table.insert(ids, id)
    end
  end
  for _, id in ipairs(ids) do
    clear_pending_tool_flush(id)
    render_tool_object_by_id(id)
  end
end

function M.flush_pending_tool_renders()
  flush_pending_tool_renders()
end

local function rough_value_size(value, limit)
  limit = limit or 100000
  local kind = type(value)
  if kind == 'string' then
    return math.min(#value, limit)
  end
  if kind ~= 'table' then
    return 0
  end
  local total = 0
  for key, item in pairs(value) do
    total = total + rough_value_size(key, limit - total) + rough_value_size(item, limit - total)
    if total >= limit then
      return limit
    end
  end
  return total
end

local function tool_object_flush_delay(object)
  if is_subagent_tool(object and object.name) then
    return subagent.tool_flush_delay_ms
  end
  local size = rough_value_size(object and (object.partial_result or object.result))
  if size > 100000 then
    return 1000
  end
  if size > 20000 then
    return 250
  end
  return TOOL_FLUSH_DELAY_MS
end

local function schedule_tool_object_flush(id, delay_ms)
  state.render.pending_tool_flushes = state.render.pending_tool_flushes or {}
  local pending = state.render.pending_tool_flushes[id]
  if pending and pending.scheduled then
    return
  end
  pending = pending or {}
  pending.scheduled = true
  state.render.pending_tool_flushes[id] = pending
  vim.defer_fn(function()
    local current = state.render.pending_tool_flushes and state.render.pending_tool_flushes[id]
    if not current or not current.scheduled then
      return
    end
    state.render.pending_tool_flushes[id] = nil
    render_tool_object_by_id(id)
  end, delay_ms or TOOL_FLUSH_DELAY_MS)
end

local function related_permission_block_exists(summary, tool_call_id)
  if not summary or summary == '' then
    return false
  end
  local tool_block = tool_call_id and state.render.tool_blocks and state.render.tool_blocks[tool_call_id]
  for _, block in pairs(state.render.permission_blocks or {}) do
    if block.summary == summary then
      if not (tool_block and tool_block.start_line and block.start_line) or block.start_line > tool_block.start_line then
        return true
      end
    end
  end
  return false
end

local function maybe_append_permission_denial_block(tool_call_id, object, event)
  if not (event and event.result ~= nil and object) then
    return false
  end
  local ok, permission_system = pcall(require, 'pi-dev.compat.pi_permission_system')
  if not (ok and permission_system.denial_block_from_result) then
    return false
  end
  local block = permission_system.denial_block_from_result(event.result, object.name, object.args)
  if not block or not block.summary or block.summary == '' then
    return false
  end
  if related_permission_block_exists(block.summary, tool_call_id) then
    return false
  end
  local id = '__auto_permission_block_' .. tostring(tool_call_id or block.summary)
  upsert_permission_block(id, {
    title = block.title or 'Permission blocked',
    summary = block.summary,
    result = block.result or 'blocked',
    details = block.details,
    finished = true,
    fold = true,
  }, {
    timestamp = event.timestamp or event.createdAt or event.created_at or event.time or event.date,
    finishedAt = event.finishedAt or event.finished_at or event.endedAt or event.ended_at or event.endTime or event.end_time,
  })
  return true
end

local function update_tool_object(event, status)
  local id, object, created = tool_events.object_from_event(event)
  state.render.last_tool_id = id
  object.status = status

  local start_ms = event_timestamp_milliseconds(event, { 'startedAt', 'started_at', 'startTime', 'start_time' }, status == 'Running')
  local end_ms = event_timestamp_milliseconds(event, { 'endedAt', 'ended_at', 'finishedAt', 'finished_at', 'completedAt', 'completed_at', 'endTime', 'end_time' }, true)
  if status == 'Running' and not object.started_at_ms then
    object.started_at_ms = start_ms or math.floor(vim.uv.hrtime() / 1000000)
    object.started_at_ms_reliable = start_ms ~= nil
  elseif status == 'Finished' then
    if not object.started_at_ms and start_ms then
      object.started_at_ms = start_ms
      object.started_at_ms_reliable = true
    end
    object.finished_at_ms = end_ms or math.floor(vim.uv.hrtime() / 1000000)
    object.finished_at_ms_reliable = end_ms ~= nil
    object.duration_ms = subtract_permission_wait_from_duration(event_duration_milliseconds(event), object)
    update_tool_duration_from_bounds(object)
  end

  if event.partialResult ~= nil then
    object.partial_result = event.partialResult
  end
  if event.result ~= nil then
    object.result = event.result
    object.partial_result = nil
  end
  if status == 'Finished' and event.result ~= nil then
    maybe_append_permission_denial_block(id, object, event)
  end
  if created and status == 'Finished' and event.result ~= nil then
    local parent_id = tool_events.duplicate_permission_interrupted_tool_id(id, object)
    if parent_id then
      object.result_continuation = true
      object.result_continuation_of = parent_id
      local parent = state.render.tool_objects[parent_id]
      if parent then
        object.started_at_ms = object.started_at_ms or parent.started_at_ms
        object.started_at_ms_reliable = object.started_at_ms_reliable or parent.started_at_ms_reliable
        update_tool_duration_from_bounds(object)
      end
      if parent and parent.status == 'Running' then
        parent.status = nil
        clear_pending_tool_flush(parent_id)
        local parent_subagent_tool = is_subagent_tool(parent.name)
        local parent_lines = render_tool_object(parent, {
          lazy_subagent_details = parent_subagent_tool and parent.status == 'Running' and not (state.render.tool_blocks[parent_id] and state.render.tool_blocks[parent_id].force_open),
        })
        replace_tool_block(parent_id, parent_lines, {
          always_fold = parent_subagent_tool and parent.status ~= 'Running',
          detail_offset = nil,
          suppress_auto_fold = parent_subagent_tool,
          child_folds = parent_subagent_tool,
          skip_tool_fold = parent_subagent_tool and parent.status == 'Running',
          subagent_children = parent_lines.__pi_subagent_children,
        })
      end
    end
  end
  if status == 'Running' and event.partialResult ~= nil and event.result == nil then
    schedule_tool_object_flush(id, tool_object_flush_delay(object))
    return
  end
  clear_pending_tool_flush(id)
  render_tool_object_by_id(id)
end

local open_block_fold = folds.open_block
local latest_render_block = folds.latest_block

local function subagent_tool_block_at_line(line)
  line = tonumber(line)
  if not line then
    return nil, nil, nil
  end
  for id, block in pairs(state.render.tool_blocks or {}) do
    if block and block.start_line and block.end_line and line >= block.start_line and line <= block.end_line then
      local object = state.render.tool_objects and state.render.tool_objects[id]
      if object and is_subagent_tool(object.name) then
        return id, block, object
      end
    end
  end
  return nil, nil, nil
end

local function line_targets_subagent_details(block, line)
  if not block or not line then
    return false
  end
  if block.fold_start_line and line >= block.fold_start_line and line <= (block.fold_end_line or block.fold_start_line) then
    return true
  end
  for _, child in ipairs(block.child_detail_folds or {}) do
    local start_line = tonumber(child.start_line)
    local end_line = tonumber(child.end_line)
    if start_line and end_line and line >= start_line - 1 and line <= end_line then
      return true
    end
  end
  return false
end

function M.materialize_subagent_details_at_cursor()
  local win = state.ui.output_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local id, block = subagent_tool_block_at_line(line)
  if not id or not block or block.force_open or not line_targets_subagent_details(block, line) then
    return false
  end
  block.force_open = true
  block.last_render_signature = nil
  render_tool_object_by_id(id)
  return true
end

function M.open_last_tool_fold()
  local id = state.render.last_tool_id
  if not id then
    return false
  end
  local block = state.render.tool_blocks[id]
  if not block then
    return false
  end
  if not block.force_open then
    block.forced_previous_closed = nil
    if block.fold_start_line then
      local win = state.ui.output_win
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function()
          if vim.fn.foldlevel(block.fold_start_line) > 0 then
            block.forced_previous_closed = vim.fn.foldclosed(block.fold_start_line) ~= -1
          end
        end)
      end
    end
  end
  block.force_open = true
  local object = state.render.tool_objects and state.render.tool_objects[id]
  if object and is_subagent_tool(object.name) then
    block.last_render_signature = nil
    render_tool_object_by_id(id)
    block = state.render.tool_blocks[id] or block
  end
  return open_block_fold(block)
end

function M.open_latest_tool_fold()
  return open_block_fold(latest_render_block(state.render.tool_blocks))
end

function M.open_latest_permission_fold()
  return open_block_fold(latest_render_block(state.render.permission_blocks))
end

function M.open_latest_auto_folds()
  local opened_tool = M.open_latest_tool_fold()
  local opened_permission = M.open_latest_permission_fold()
  return opened_tool or opened_permission
end

function M.foldtext()
  return folds.foldtext()
end

function M.release_forced_tool_fold()
  local id = state.render.last_tool_id
  local block = id and state.render.tool_blocks[id] or nil
  if block then
    local should_close = block.forced_previous_closed ~= false
    block.force_open = false
    block.forced_previous_closed = nil
    if should_close and block.fold_start_line then
      local win = state.ui.output_win
      if win and vim.api.nvim_win_is_valid(win) then
        with_preserved_win_view(win, function()
          if vim.fn.foldlevel(block.fold_start_line) > 0 then
            pcall(vim.api.nvim_win_set_cursor, win, { block.fold_start_line, 0 })
            vim.cmd('silent! normal! zc')
          end
        end)
      end
    end
  end
end

cancel_live_render_timer = function()
  live.cancel_timer()
end

local function ensure_assistant_content_for_live_text()
  if state.render.assistant_has_content then
    return true
  end
  append_lines({ '', message_title({ role = 'assistant', __pi_timestamp = state.render.pending_assistant_timestamp or os.time() }), '', '' }, {
    raw_spacing = true,
    skip_refresh = true,
  })
  state.render.assistant_has_content = true
  state.render.pending_assistant_header = false
  state.render.pending_assistant_timestamp = nil
  state.render.assistant_markdown_fence = nil
  state.render.assistant_markdown_fence_before_last_line = nil
  state.render.assistant_last_line = nil
  state.render.assistant_thinking_active = false
  state.render.assistant_thinking_at_line_start = true
  state.render.assistant_thinking_block = nil
  return true
end

local function append_live_assistant_text_now(text)
  text = tostring(text or '')
  if text == '' then
    return false
  end
  local creating_content = not state.render.assistant_has_content
  if creating_content and vim.trim(text) == '' then
    return false
  end
  if creating_content then
    text = normalize_line_endings(text)
    local removed
    repeat
      text, removed = text:gsub('^[ \t]*\n', '')
    until removed == 0
  end
  ensure_assistant_content_for_live_text()

  local after_thinking = state.render.assistant_thinking_active == true
  if after_thinking then
    cleanup_live_thinking_quote_lines(state.render.assistant_thinking_block)
    apply_thinking_fold(state.render.assistant_thinking_block)
    state.render.assistant_thinking_active = false
    state.render.assistant_thinking_at_line_start = true
  end

  local changed_start, changed_end
  if after_thinking then
    changed_start, changed_end = append_text_as_new_paragraph(text, { skip_refresh = true })
  else
    changed_start, changed_end = append_text(text, { skip_refresh = true })
  end
  if changed_start and changed_end then
    local initial_fence = state.render.assistant_markdown_fence
    if state.render.assistant_last_line and changed_start <= state.render.assistant_last_line then
      initial_fence = state.render.assistant_markdown_fence_before_last_line
    end
    local final_fence, fence_before_last = demote_assistant_markdown_buffer_range(changed_start, changed_end, initial_fence)
    state.render.assistant_markdown_fence = final_fence
    state.render.assistant_markdown_fence_before_last_line = fence_before_last
    state.render.assistant_last_line = changed_end
  end
  return true
end

local function append_live_assistant_thinking_now(text)
  text = tostring(text or '')
  if text == '' then
    return false
  end
  if not state.render.assistant_has_content and vim.trim(text) == '' then
    return false
  end
  ensure_assistant_content_for_live_text()
  state.render.assistant_thinking_active = true
  append_live_thinking_text(text, { defer_fold = true, skip_refresh = true })
  return true
end

flush_live_render = function(opts)
  opts = opts or {}
  local pending = live.take_pending()
  if #pending == 0 then
    return false
  end

  local changed = false
  for _, segment in ipairs(pending) do
    if segment.kind == 'thinking' then
      changed = append_live_assistant_thinking_now(segment.text) or changed
    else
      changed = append_live_assistant_text_now(segment.text) or changed
    end
  end

  if changed then
    if state.render.assistant_thinking_active and state.render.assistant_thinking_block then
      apply_thinking_fold(state.render.assistant_thinking_block)
    end
    trim_trailing_blank_lines(1)
    refresh_rendered_output()
  end
  return changed
end

function M.flush_live_render(opts)
  return flush_live_render(opts)
end

local function schedule_live_render_flush()
  live.schedule_flush(flush_live_render)
end

local function append_assistant_delta(text, opts)
  opts = opts or {}
  text = tostring(text or '')
  if text == '' then
    return
  end
  if not opts.thinking then
    state.render.assistant_title_text = (state.render.assistant_title_text or '') .. text
  end
  local kind = opts.thinking and 'thinking' or 'text'
  if live.enqueue(kind, text) then
    flush_live_render()
  else
    schedule_live_render_flush()
  end
end

function M.handle_event(event)
  if not event or not event.type then
    return
  end
  if event.__pi_runtime_key and event.__pi_runtime_key ~= state.rpc.active_key then
    return
  end

  local delta = event.type == 'message_update' and event.assistantMessageEvent or nil
  local is_stream_delta = delta and (delta.type == 'text_delta' or delta.type == 'thinking_delta' or delta.type == 'reasoning_delta')
  if not is_stream_delta then
    flush_live_render()
    if event.type ~= 'tool_execution_start' and event.type ~= 'tool_execution_update' and event.type ~= 'tool_execution_end' then
      flush_pending_tool_renders()
    end
  end

  if event.type == 'agent_start' then
    append_notice('_Agent start._')
  elseif event.type == 'agent_end' then
    append_notice('_Agent done._')
  elseif event.type == 'message_start' then
    local role = event.message and event.message.role
    if role == 'assistant' then
      state.render.pending_assistant_header = true
      state.render.assistant_has_content = false
      state.render.pending_assistant_timestamp = live_timestamp(event)
      state.render.assistant_title_text = ''
      state.render.assistant_thinking_active = false
      state.render.assistant_thinking_at_line_start = true
      state.render.assistant_thinking_block = nil
    elseif role == 'user' then
      local text = content_to_text(event.message and event.message.content or '')
      local trimmed = vim.trim(pipeline.format_user_skill_calls(text or ''))
      if trimmed == '' then
        return
      end
      if state.render.last_user_text and trimmed == state.render.last_user_text then
        state.render.last_user_text = nil
        return
      end
      M.append_user(text, live_timestamp(event))
    end
  elseif event.type == 'message_update' then
    if not delta then
      return
    end
    if delta.type == 'text_delta' then
      append_assistant_delta(delta.delta or '')
    elseif (delta.type == 'thinking_delta' or delta.type == 'reasoning_delta') and config.options.ui.render.show_thinking then
      append_assistant_delta(delta.delta or '', { thinking = true })
    elseif delta.type == 'toolcall_start' then
      -- Pi also emits tool_execution_start with the concrete tool name and
      -- arguments. Rendering both creates duplicate "Tool call: tool" noise.
      return
    end
  elseif event.type == 'tool_execution_start' then
    update_tool_object(event, 'Running')
  elseif event.type == 'tool_execution_update' then
    update_tool_object(event, 'Running')
  elseif event.type == 'tool_execution_end' then
    update_tool_object(event, 'Finished')
  elseif event.type == 'queue_update' then
    append_notice(string.format('_Queue: %d steering, %d follow-up_', #(event.steering or {}), #(event.followUp or {})))
  elseif event.type == 'compaction_start' then
    append_notice(string.format('_Compact start: %s_', event.reason or 'manual'))
  elseif event.type == 'compaction_end' then
    append_notice(string.format('_Compact done: %s_', event.reason or 'manual'))
  elseif event.type == 'auto_retry_start' then
    append_notice(string.format('_Retry %s/%s in %sms: %s_', event.attempt or '?', event.maxAttempts or '?', event.delayMs or '?', event.errorMessage or ''))
  elseif event.type == 'auto_retry_end' then
    append_notice(string.format('_Retry done: %s_', event.success and 'success' or 'failed'))
  elseif event.type == 'mcp_auth_url' then
    local notice = mcp_auth_notice(event)
    if notice then
      append_notice(notice)
    end
  elseif event.type == 'service_notice' or event.type == 'service_message' or event.type == 'notification' or event.type == 'notice' or event.type == 'update_available' then
    local notice = update_notice_from_event(event)
    if notice then
      append_notice(notice)
    end
  elseif event.type == 'extension_error' then
    append_notice('**Extension error:** ' .. tostring(event.error or vim.inspect(event)))
  elseif event.type == 'protocol_error' then
    append_notice('**Protocol error:** ' .. tostring(event.error or event.line or vim.inspect(event)))
  elseif event.type == 'error' or event.type == 'provider_error' then
    append_notice('**Error:** ' .. tostring(event.error or event.message or vim.inspect(event)))
  end
end

return M
