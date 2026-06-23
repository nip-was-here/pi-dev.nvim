-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local buffer = require('pi-dev.renderer.buffer')
local config = require('pi-dev.config')
local pipeline = require('pi-dev.render_pipeline')
local state = require('pi-dev.state')

local M = {}

local function output_buf()
  return buffer.output_buf()
end

local function is_blank_line(line)
  return pipeline.is_blank_line(line)
end

local function is_section_header_line(line)
  return pipeline.is_section_header_line(line)
end

local function is_thinking_heading_line(line)
  return pipeline.is_thinking_heading_line(line)
end

function M.detail_start(block)
  if not block or not block.start_line then
    return nil
  end
  if block.detail_offset then
    return block.start_line + block.detail_offset
  end
  local bufnr = output_buf()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and block.end_line then
    local lines = vim.api.nvim_buf_get_lines(bufnr, block.start_line - 1, block.end_line, false)
    for offset, line in ipairs(lines) do
      if is_section_header_line(line) then
        return block.start_line + offset
      end
    end
  end
  return block.start_line + 1
end

function M.detail_end(block, start_line)
  if not block or not block.end_line or not start_line then
    return nil
  end
  local bufnr = output_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return block.end_line
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local end_line = math.min(block.end_line, total)
  if end_line < start_line then
    return end_line
  end
  while end_line >= start_line do
    local line = vim.api.nvim_buf_get_lines(bufnr, end_line - 1, end_line, false)[1] or ''
    if not is_blank_line(line) then
      break
    end
    end_line = end_line - 1
  end
  return end_line
end

function M.with_preserved_win_view(win, callback)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local bufnr = output_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return false
  end
  local ok, err = pcall(vim.api.nvim_win_call, win, function()
    local view = vim.fn.winsaveview()
    local inner_ok, inner_err = pcall(callback)
    pcall(vim.fn.winrestview, view)
    if not inner_ok then
      error(inner_err)
    end
  end)
  if not ok then
    return false, err
  end
  return true
end

function M.delete_at(line)
  local win = state.ui.output_win
  local bufnr = output_buf()
  if not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not line then
    return
  end
  M.with_preserved_win_view(win, function()
    if line <= vim.api.nvim_buf_line_count(bufnr) and vim.fn.foldlevel(line) > 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
      vim.cmd('silent! normal! zD')
    end
  end)
end

function M.clear_output()
  local win = state.ui.output_win
  local bufnr = output_buf()
  if not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  M.with_preserved_win_view(win, function()
    vim.cmd('silent! normal! zE')
  end)
end

function M.thinking_end_from_buffer(header_line, fallback_end)
  local bufnr = output_buf()
  if not header_line or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return fallback_end
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local line = header_line + 1
  local end_line = fallback_end or header_line
  while line <= total do
    local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ''
    if text:match('^%s*>') then
      end_line = line
      line = line + 1
    elseif is_blank_line(text) then
      local lookahead = line + 1
      while lookahead <= total do
        local next_text = vim.api.nvim_buf_get_lines(bufnr, lookahead - 1, lookahead, false)[1] or ''
        if not is_blank_line(next_text) then
          break
        end
        lookahead = lookahead + 1
      end
      local next_text = lookahead <= total and (vim.api.nvim_buf_get_lines(bufnr, lookahead - 1, lookahead, false)[1] or '') or ''
      if line == header_line + 1 or next_text:match('^%s*>') then
        end_line = line
        line = line + 1
      else
        break
      end
    else
      break
    end
  end
  return end_line
end

local function auto_fold_suppressed()
  return state.render and state.render.auto_fold_suppressed == true
end

local function output_text_width(win)
  local width = vim.o.columns
  local textoff = 0
  if win and vim.api.nvim_win_is_valid(win) then
    width = vim.api.nvim_win_get_width(win)
    local info = vim.fn.getwininfo(win)[1]
    textoff = info and tonumber(info.textoff) or 0
  end
  return math.max(1, width - textoff)
end

local function display_line_count_exceeds(bufnr, start_line, end_line, win, threshold)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not start_line or not end_line or end_line < start_line then
    return false
  end
  threshold = tonumber(threshold) or 0
  local width = output_text_width(win)
  local count = 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  for _, line in ipairs(lines) do
    local display_width = vim.fn.strdisplaywidth(line or '')
    count = count + math.max(1, math.ceil(display_width / width))
    if count > threshold then
      return true
    end
  end
  return false
end

local thinking_auto_fold_over = 8

function M.apply_thinking(block)
  local win = state.ui.output_win
  local bufnr = output_buf()
  if not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not block then
    return
  end
  if block.fold_start_line then
    M.delete_at(block.fold_start_line)
  end
  local start_line = block.header_line and (block.header_line + 1) or nil
  local end_line = M.thinking_end_from_buffer(block.header_line, block.end_line)
  local total = vim.api.nvim_buf_line_count(bufnr)
  if not start_line or not end_line or start_line > total then
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
  block.end_line = end_line
  block.fold_start_line = start_line
  block.fold_end_line = end_line
  state.render.thinking_fold_starts = state.render.thinking_fold_starts or {}
  state.render.thinking_fold_starts[start_line] = true
  local should_close = false
  if not auto_fold_suppressed() then
    should_close = block.auto_fold_closed == true or display_line_count_exceeds(bufnr, start_line, end_line, win, thinking_auto_fold_over)
  end
  if should_close then
    block.auto_fold_closed = true
  end
  M.with_preserved_win_view(win, function()
    vim.wo[win].foldmethod = 'manual'
    if pcall(vim.cmd, string.format('%d,%dfold', start_line, end_line)) then
      pcall(vim.api.nvim_win_set_cursor, win, { start_line, 0 })
      if should_close then
        vim.cmd('silent! normal! zc')
      else
        vim.cmd('silent! normal! zo')
      end
    end
  end)
end

function M.apply_thinking_in_lines(lines, base_line)
  local index = 1
  while index <= #(lines or {}) do
    local line = lines[index]
    if is_thinking_heading_line(line) then
      local stop = index
      if stop + 1 <= #lines and is_blank_line(lines[stop + 1]) then
        stop = stop + 1
      end
      while stop + 1 <= #lines and tostring(lines[stop + 1] or ''):match('^%s*>') do
        stop = stop + 1
      end
      if stop > index then
        M.apply_thinking({ header_line = base_line + index - 1, end_line = base_line + stop - 1 })
      end
      index = stop + 1
    else
      index = index + 1
    end
  end
end

function M.apply_tool(block, previous_closed, opts)
  opts = opts or {}
  local win = state.ui.output_win
  local bufnr = output_buf()
  if not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not block then
    return
  end

  local threshold = config.options.ui.render.fold_tool_output_over
  if threshold == nil then
    threshold = config.defaults.ui.render.fold_tool_output_over
  end
  if threshold == false or threshold == 0 then
    block.fold_start_line = nil
    block.fold_end_line = nil
    return
  end
  threshold = tonumber(threshold) or config.defaults.ui.render.fold_tool_output_over

  local start_line = M.detail_start(block)
  local end_line = M.detail_end(block, start_line)
  if not start_line or not end_line or end_line < start_line then
    block.fold_start_line = nil
    block.fold_end_line = nil
    return
  end

  if previous_closed ~= nil and block.last_applied_fold_closed ~= nil and previous_closed ~= block.last_applied_fold_closed then
    block.user_fold_closed = previous_closed
  end

  local should_auto_close = false
  if not opts.suppress_auto_close and not auto_fold_suppressed() then
    should_auto_close = display_line_count_exceeds(bufnr, start_line, end_line, win, threshold)
  end
  local should_close = should_auto_close
  if block.force_open then
    should_close = false
  elseif block.user_fold_closed ~= nil then
    should_close = block.user_fold_closed
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
  block.last_applied_fold_closed = should_close
  M.with_preserved_win_view(win, function()
    vim.wo[win].foldmethod = 'manual'
    if pcall(vim.cmd, string.format('%d,%dfold', start_line, end_line)) then
      pcall(vim.api.nvim_win_set_cursor, win, { start_line, 0 })
      if should_close then
        vim.cmd('silent! normal! zc')
      else
        vim.cmd('silent! normal! zo')
      end
    end
  end)
end

function M.open_block(block)
  local win = state.ui.output_win
  local bufnr = output_buf()
  if not block or not block.fold_start_line or not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local line = block.fold_start_line
  if line > vim.api.nvim_buf_line_count(bufnr) then
    return false
  end
  local opened = false
  M.with_preserved_win_view(win, function()
    if vim.fn.foldlevel(line) > 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
      vim.cmd('silent! normal! zO')
      opened = true
    end
  end)
  return opened
end

function M.latest_block(blocks)
  local latest
  for _, block in pairs(blocks or {}) do
    if block.start_line and (not latest or block.start_line > latest.start_line) then
      latest = block
    end
  end
  return latest
end

local function tree_foldtext(start_line, count)
  local bufnr = vim.api.nvim_get_current_buf()
  if bufnr ~= state.ui.tree_buf then
    return nil
  end
  local labels = state.ui.interaction and state.ui.interaction.fold_labels or nil
  local label = labels and labels[start_line]
  if not label then
    label = vim.api.nvim_buf_get_lines(bufnr, math.max(0, start_line - 1), start_line, false)[1] or ''
  end
  label = tostring(label):gsub('^%s+', ''):gsub('%s+$', '')
  if label == '' then
    return nil
  end
  return string.format('%s  (%d lines)', label, count)
end

function M.foldtext()
  local start_line = tonumber(vim.v.foldstart) or 0
  local end_line = tonumber(vim.v.foldend) or 0
  local count = math.max(0, end_line - start_line + 1)
  local tree_label = tree_foldtext(start_line, count)
  if tree_label then
    return tree_label
  end
  local thinking_fold = state.render.thinking_fold_starts and state.render.thinking_fold_starts[start_line]
  if not thinking_fold then
    local bufnr = vim.api.nvim_get_current_buf()
    local start_text = vim.api.nvim_buf_get_lines(bufnr, math.max(0, start_line - 1), start_line, false)[1] or ''
    local previous_text = vim.api.nvim_buf_get_lines(bufnr, math.max(0, start_line - 2), math.max(0, start_line - 1), false)[1] or ''
    thinking_fold = start_text:match('^%s*>') ~= nil or (is_blank_line(start_text) and is_thinking_heading_line(previous_text))
  end
  local prefix = thinking_fold and '  ' or ''
  return prefix .. string.format('details - %d lines', count)
end

return M
