-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local config = require('pi-dev.config')
local state = require('pi-dev.state')

local M = {}

function M.valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function M.valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

function M.lock_window_buffer(win)
  if M.valid_win(win) then
    -- Neovim window-local guard: file pickers should not replace Pi-owned
    -- buffers inside the Pi panel. Plugin-owned code may temporarily unlock
    -- only when it intentionally restores a Pi buffer.
    pcall(function()
      vim.wo[win].winfixbuf = true
    end)
  end
end

function M.unlock_window_buffer(win)
  if M.valid_win(win) then
    pcall(function()
      vim.wo[win].winfixbuf = false
    end)
  end
end

function M.setup_buffer(bufnr, filetype)
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype
end

function M.set_modifiable(bufnr, modifiable)
  if M.valid_buf(bufnr) then
    if modifiable then
      vim.bo[bufnr].readonly = false
    end
    vim.bo[bufnr].modifiable = modifiable
  end
end

function M.set_readonly(bufnr, readonly)
  if M.valid_buf(bufnr) then
    vim.bo[bufnr].readonly = readonly
  end
end

function M.ensure()
  local opts = config.options

  if not M.valid_buf(state.ui.output_buf) then
    state.ui.output_buf = vim.api.nvim_create_buf(false, true)
    M.setup_buffer(state.ui.output_buf, opts.ui.output_filetype)
    vim.api.nvim_buf_set_name(state.ui.output_buf, 'pi-dev://chat')
    vim.api.nvim_buf_set_lines(state.ui.output_buf, 0, -1, false, { '# Pi chat', '' })
    M.set_modifiable(state.ui.output_buf, false)
  end

  if not M.valid_buf(state.ui.input_buf) then
    state.ui.input_buf = vim.api.nvim_create_buf(false, true)
    M.setup_buffer(state.ui.input_buf, opts.ui.input_filetype)
    vim.api.nvim_buf_set_name(state.ui.input_buf, 'pi-dev://input')
  end

  if not M.valid_buf(state.ui.interaction_buf) then
    state.ui.interaction_buf = vim.api.nvim_create_buf(false, true)
    M.setup_buffer(state.ui.interaction_buf, 'markdown')
    vim.api.nvim_buf_set_name(state.ui.interaction_buf, 'pi-dev://interaction')
    M.set_modifiable(state.ui.interaction_buf, false)
    M.set_readonly(state.ui.interaction_buf, true)
  end

  if not M.valid_buf(state.ui.tree_buf) then
    state.ui.tree_buf = vim.api.nvim_create_buf(false, true)
    M.setup_buffer(state.ui.tree_buf, 'text')
    vim.api.nvim_buf_set_name(state.ui.tree_buf, 'pi-dev://tree')
    M.set_modifiable(state.ui.tree_buf, false)
  end

  if not M.valid_buf(state.ui.status_buf) then
    state.ui.status_buf = vim.api.nvim_create_buf(false, true)
    M.setup_buffer(state.ui.status_buf, 'markdown')
    vim.api.nvim_buf_set_name(state.ui.status_buf, 'pi-dev://status-separator')
    vim.api.nvim_buf_set_lines(state.ui.status_buf, 0, -1, false, { '' })
    M.set_modifiable(state.ui.status_buf, false)
  end
end

return M
