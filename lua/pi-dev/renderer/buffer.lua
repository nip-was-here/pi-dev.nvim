-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local state = require('pi-dev.state')

local M = {}

local diff_ns = vim.api.nvim_create_namespace('pi_dev_diff_blocks')

function M.diff_namespace()
  return diff_ns
end

function M.output_buf()
  return state.ui.output_buf
end

function M.with_output_buf(callback)
  local bufnr = M.output_buf()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  callback(bufnr)
  vim.bo[bufnr].modifiable = was_modifiable
end

function M.line_count(bufnr)
  return vim.api.nvim_buf_line_count(bufnr)
end

function M.output_has_focus(win)
  return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win
end

local function keep_cursor_above_status_separator(win)
  local status_win = state.ui.status_win
  if not status_win or not vim.api.nvim_win_is_valid(status_win) then
    return
  end
  local ok, win_config = pcall(vim.api.nvim_win_get_config, status_win)
  if not ok or win_config.relative ~= 'win' or win_config.win ~= win then
    return
  end
  local first_covered_winline = tonumber(win_config.row)
  if not first_covered_winline or first_covered_winline <= 0 then
    return
  end
  local cursor_winline = vim.fn.winline()
  local scroll_delta = cursor_winline - first_covered_winline + 1
  if scroll_delta <= 0 then
    return
  end
  local view = vim.fn.winsaveview()
  view.topline = math.min(view.lnum, view.topline + scroll_delta)
  vim.fn.winrestview(view)
end

function M.scroll_output_to_bottom(opts)
  opts = opts or {}
  local force = opts.force == true
  local win = state.ui.output_win
  local bufnr = M.output_buf()
  if not win or not vim.api.nvim_win_is_valid(win) or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if (not force and M.output_has_focus(win)) or (state.render.output_scroll_pending and not force) then
    return
  end
  if not force then
    state.render.output_scroll_pending = true
  end
  vim.schedule(function()
    if not force then
      state.render.output_scroll_pending = false
    end
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(bufnr) or (not force and M.output_has_focus(win)) then
      return
    end
    local last = math.max(1, vim.api.nvim_buf_line_count(bufnr))
    vim.api.nvim_win_call(win, function()
      local target = last
      local folded = vim.fn.foldclosed(last)
      if folded ~= -1 then
        target = folded
      end
      pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
      vim.cmd('silent! normal! zb')
      keep_cursor_above_status_separator(win)
    end)
  end)
end

local function diff_line_hl(line, inside_hunk, saw_hunk)
  if line:sub(1, 3) == '+++' or line:sub(1, 3) == '---' then
    return nil
  end
  if line:sub(1, 1) ~= '+' and line:sub(1, 1) ~= '-' then
    return nil
  end
  if saw_hunk and not inside_hunk then
    return nil
  end
  return line:sub(1, 1) == '+' and 'DiffAdd' or 'DiffDelete'
end

function M.highlight_diff_lines(bufnr, start_index, lines)
  local diff_fence = nil
  local inside_hunk = false
  local saw_hunk = false
  for offset, line in ipairs(lines or {}) do
    local opener = line:match('^(`+)diff%s*$')
    if not diff_fence and opener then
      diff_fence = opener
      inside_hunk = false
      saw_hunk = false
    elseif diff_fence and line == diff_fence then
      diff_fence = nil
      inside_hunk = false
    elseif diff_fence then
      if line:sub(1, 2) == '@@' then
        inside_hunk = true
        saw_hunk = true
      elseif line:match('^diff %-%-git ') or line:match('^Index: ') then
        inside_hunk = false
      end
      local hl = diff_line_hl(line, inside_hunk, saw_hunk)
      if hl then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, diff_ns, start_index + offset - 1, 0, {
          line_hl_group = hl,
          hl_eol = true,
        })
      end
    end
  end
end

return M
