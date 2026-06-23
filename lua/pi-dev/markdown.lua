-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local state = require('pi-dev.state')

local M = {}

local pending = {}
local settle_pending = {}

local REFRESH_DELAY_MS = 30

local function valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_markdown(bufnr)
  if not valid_buf(bufnr) then
    return false
  end
  local filetype = vim.bo[bufnr].filetype or ''
  return filetype == 'markdown' or filetype:match('%.markdown$') ~= nil or filetype:match('markdown') ~= nil
end

local function in_window(win, callback)
  if valid_win(win) then
    return pcall(vim.api.nvim_win_call, win, callback)
  end
  return pcall(callback)
end

local function run_refresh(bufnr, win)
  if not is_markdown(bufnr) then
    return
  end

  if vim.fn.exists(':RenderMarkdown') == 2 then
    in_window(win, function()
      if valid_buf(bufnr) and (not valid_win(win) or vim.api.nvim_win_get_buf(win) == bufnr) then
        vim.cmd('silent! RenderMarkdown buf_enable')
      end
    end)
  end

  local ok, render_markdown = pcall(require, 'render-markdown')
  if not ok or type(render_markdown) ~= 'table' then
    return
  end

  if type(render_markdown.set_buf) == 'function' then
    in_window(win, function()
      if valid_buf(bufnr) and (not valid_win(win) or vim.api.nvim_win_get_buf(win) == bufnr) then
        pcall(render_markdown.set_buf, true)
      end
    end)
  elseif type(render_markdown.buf_enable) == 'function' then
    in_window(win, function()
      if valid_buf(bufnr) and (not valid_win(win) or vim.api.nvim_win_get_buf(win) == bufnr) then
        pcall(render_markdown.buf_enable)
      end
    end)
  end

  if type(render_markdown.render) == 'function' and valid_win(win) and vim.api.nvim_win_get_buf(win) == bufnr then
    pcall(render_markdown.render, { buf = bufnr, win = win, event = 'PiDevRefresh' })
  end
end

function M.refresh(bufnr, win, opts)
  opts = opts or {}
  bufnr = bufnr or state.ui.output_buf
  win = win or state.ui.output_win
  if not is_markdown(bufnr) then
    return
  end

  local key = tostring(bufnr) .. ':' .. tostring(win or 0)
  local settle_ms = tonumber(opts.settle_ms) or 0
  if settle_ms > 0 and not settle_pending[key] then
    settle_pending[key] = true
    vim.defer_fn(function()
      settle_pending[key] = nil
      run_refresh(bufnr, win)
    end, settle_ms)
  end

  if pending[key] then
    return
  end
  pending[key] = true
  vim.defer_fn(function()
    pending[key] = nil
    run_refresh(bufnr, win)
  end, REFRESH_DELAY_MS)
end

function M.refresh_output(opts)
  M.refresh(state.ui.output_buf, state.ui.output_win, opts)
end

return M
