-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {}

local config = require('pi-dev.config')
local events = require('pi-dev.events')
local extension_ui = require('pi-dev.extension_ui')
local renderer = require('pi-dev.renderer')
local statusline = require('pi-dev.statusline')

M.api = require('pi-dev.api')

local registered = false
local chrome_refresh_pending = false
local mapped = {}
local created_commands = {}
local setup_keymaps

local function clear_keymaps()
  for _, item in ipairs(mapped) do
    pcall(vim.keymap.del, item.mode, item.lhs)
  end
  mapped = {}
end

local function clear_commands()
  for _, command in ipairs(created_commands) do
    pcall(vim.api.nvim_del_user_command, command)
  end
  created_commands = {}
end

local function map(mode, lhs, rhs, desc)
  if not lhs or lhs == '' then
    return
  end
  vim.keymap.set(mode, lhs, rhs, { silent = true, desc = desc })
  table.insert(mapped, { mode = mode, lhs = lhs })
end

local function with_prefix(suffix)
  return (config.options.keymaps.prefix or '') .. suffix
end

local action_specs = require('pi-dev.actions').command_specs(M.api)

local function setup_events()
  if registered then
    return
  end
  registered = true

  events.on('*', renderer.handle_event)
  events.on('*', statusline.handle_event)
  events.on('*', function()
    if chrome_refresh_pending then
      return
    end
    chrome_refresh_pending = true
    vim.defer_fn(function()
      chrome_refresh_pending = false
      require('pi-dev.ui').refresh_chrome()
    end, 16)
  end)
  local function refresh_active_runtime_status(event, delay_ms)
    if event.__pi_runtime_key and event.__pi_runtime_key ~= require('pi-dev.state').rpc.active_key then
      return
    end
    require('pi-dev.api').refresh_status(delay_ms or 0)
  end

  events.on('agent_end', function(event)
    refresh_active_runtime_status(event, 0)
  end)
  events.on('compaction_end', function(event)
    refresh_active_runtime_status(event, 50)
  end)
  events.on('extension_ui_request', extension_ui.handle_request)
  events.on('stderr', function(event)
    if event.__pi_runtime_key and event.__pi_runtime_key ~= require('pi-dev.state').rpc.active_key then
      return
    end
    if config.options.ui.render.show_stderr ~= false then
      renderer.append_system('stderr: `' .. tostring(event.text) .. '`')
    end
  end)

  local group = vim.api.nvim_create_augroup('PiDevLifecycle', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      require('pi-dev.api').stop()
    end,
  })
  vim.api.nvim_create_autocmd('DirChanged', {
    group = group,
    callback = function(event)
      if config.options.auto_resume_last_session ~= false then
        local cwd = event and event.file ~= '' and event.file or (vim.v.event and vim.v.event.cwd)
        require('pi-dev.api').reload_for_cwd(cwd)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufWinEnter' }, {
    group = group,
    callback = function()
      vim.schedule(function()
        local ui = require('pi-dev.ui')
        ui.remember_file_window()
        ui.guard_panel_buffers()
      end)
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(event)
      require('pi-dev.ui').handle_window_closed(event.match)
    end,
  })
  require('pi-dev.ui').on_visibility_changed(function()
    if setup_keymaps then
      setup_keymaps()
    end
  end)
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = group,
    callback = function()
      vim.schedule(function()
        require('pi-dev.ui').align()
      end)
    end,
  })
end

local function setup_commands()
  clear_commands()
  if not config.options.commands.enable then
    return
  end

  for _, spec in ipairs(action_specs) do
    vim.api.nvim_create_user_command(spec.command, function(command)
      spec.run(command)
    end, vim.tbl_extend('force', { force = true, desc = spec.command_desc }, spec.command_opts or {}))
    table.insert(created_commands, spec.command)
  end
end

setup_keymaps = function()
  clear_keymaps()
  if not config.options.keymaps.enable then
    return
  end

  local mappings = config.options.keymaps.mappings
  local panel_visible = require('pi-dev.state').ui.visible == true
  for _, spec in ipairs(action_specs) do
    local suffix = mappings[spec.id]
    if suffix and (spec.id == 'toggle' or panel_visible) then
      map('n', with_prefix(suffix), spec.key_run or spec.run, spec.key_desc or spec.command_desc)
    end
  end

  if vim.fn.maparg('<C-W>=', 'n') == '' then
    map('n', '<C-W>=', function()
      require('pi-dev.ui').equalize_windows()
    end, 'Pi.dev: equalize windows and restore configured panel width')
  end
end

function M.setup(opts)
  config.setup(opts)
  setup_events()
  setup_commands()
  setup_keymaps()
  return M
end

function M.start()
  return M.api.start()
end

function M.toggle()
  return M.api.toggle()
end

function M.prompt(message, opts, callback)
  return M.api.prompt(message, opts, callback)
end

function M.hide()
  return M.api.hide()
end

function M.abort(callback)
  return M.api.abort(callback)
end

function M.stop_current_rpc()
  return M.api.stop_current_rpc()
end

function M.next_rpc()
  return M.api.next_rpc()
end

function M.previous_rpc()
  return M.api.previous_rpc()
end

function M.new_session(callback)
  return M.api.new_session(callback)
end

function M.resume()
  return M.api.resume()
end

function M.model_picker()
  return M.api.model_picker()
end

function M.reload(callback)
  return M.api.reload(callback)
end

function M.tree()
  return M.api.tree()
end

function M.waiting()
  return M.api.waiting()
end

function M.delete_session(callback)
  return M.api.delete_session(callback)
end

function M.open_subagent_buffer()
  return M.api.open_subagent_buffer()
end

function M.return_to_parent_agent_buffer()
  return M.api.return_to_parent_agent_buffer()
end

return M
