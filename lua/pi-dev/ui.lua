-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local buffers = require('pi-dev.ui.buffers')
local input = require('pi-dev.ui.input')
local interaction_queue = require('pi-dev.ui.interaction_queue')
local interaction_view = require('pi-dev.ui.interaction_view')
local completion = require('pi-dev.completion')
local config = require('pi-dev.config')
local format = require('pi-dev.format')
local markdown = require('pi-dev.markdown')
local renderer = require('pi-dev.renderer')
local state = require('pi-dev.state')
local subagent = require('pi-dev.compat.subagent')
local statusline = require('pi-dev.statusline')

local M = {}

local panel_teardown = false
local visibility_listeners = {}

local function emit_visibility_changed(visible)
  for _, listener in ipairs(visibility_listeners) do
    pcall(listener, visible)
  end
end

local valid_win = buffers.valid_win
local valid_buf = buffers.valid_buf

local function is_pi_win(win)
  return win == state.ui.output_win or win == state.ui.input_win or win == state.ui.status_win
end

local function is_pi_buf(buf)
  return buf == state.ui.output_buf
    or buf == state.ui.input_buf
    or buf == state.ui.interaction_buf
    or buf == state.ui.tree_buf
    or buf == state.ui.status_buf
end

local lock_window_buffer = buffers.lock_window_buffer
local unlock_window_buffer = buffers.unlock_window_buffer
local set_buf_modifiable = buffers.set_modifiable
local set_buf_readonly = buffers.set_readonly
local ensure_buffers = buffers.ensure

local function size_arg(ratio, total)
  if type(ratio) == 'number' and ratio > 0 and ratio < 1 then
    return math.max(1, math.floor(total * ratio))
  end
  return math.max(1, tonumber(ratio) or 1)
end

local function output_title(win)
  local title = state.ui.output_title or 'Pi chat'
  local width = format.window_text_width(win) - 2
  return format.prefixed_line(' ', title, '', width + 1) .. ' '
end

local function input_title()
  local title = state.ui.input_title or 'Pi input'
  local hint = state.ui.input_hint
  local runtime = state.rpc.runtimes[state.rpc.active_key or 'default']
  if runtime and runtime.loading == true and runtime.loading_lock == true and runtime.status == 'loading' and not state.ui.interaction then
    hint = 'load session...'
  end
  if hint and hint ~= '' then
    return ' ' .. title .. '  (' .. hint .. ') '
  end
  return ' ' .. title .. ' '
end

local function set_window_title(win, title)
  pcall(function()
    vim.wo[win].winbar = title
  end)
end

local function current_window_for_buffer(bufnr)
  local current = vim.api.nvim_get_current_win()
  if valid_win(current) and vim.api.nvim_win_get_buf(current) == bufnr then
    return current
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if valid_win(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

local function fold_state(win)
  local state_info = { has_fold = false, has_closed = false }
  if not valid_win(win) then
    return state_info
  end
  pcall(vim.api.nvim_win_call, win, function()
    local bufnr = vim.api.nvim_win_get_buf(win)
    local total = vim.api.nvim_buf_line_count(bufnr)
    for line = 1, total do
      if vim.fn.foldlevel(line) > 0 then
        state_info.has_fold = true
      end
      if vim.fn.foldclosed(line) ~= -1 then
        state_info.has_closed = true
        state_info.has_fold = true
        break
      end
    end
  end)
  return state_info
end

local function run_fold_command(win, command)
  if not valid_win(win) then
    return
  end
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd('silent! normal! ' .. command)
  end)
end

local function close_all_folds(win)
  if not valid_win(win) then
    return
  end
  pcall(vim.api.nvim_win_call, win, function()
    local bufnr = vim.api.nvim_win_get_buf(win)
    local total = vim.api.nvim_buf_line_count(bufnr)
    local starts = {}
    for line = 1, total do
      if vim.fn.foldlevel(line) > 0 then
        table.insert(starts, line)
      end
    end
    vim.wo[win].foldenable = true
    for index = #starts, 1, -1 do
      pcall(vim.api.nvim_win_set_cursor, win, { starts[index], 0 })
      pcall(vim.cmd, 'silent! normal! zc')
    end
  end)
end

local function open_all_folds(win)
  run_fold_command(win, 'zR')
end

local function set_output_auto_fold_suppressed(bufnr, suppressed)
  if bufnr == state.ui.output_buf and renderer.set_auto_fold_suppressed then
    renderer.set_auto_fold_suppressed(suppressed)
  end
end

local function materialize_output_subagent_details(bufnr, command)
  if bufnr ~= state.ui.output_buf then
    return
  end
  if command ~= 'zo' and command ~= 'zO' and command ~= 'za' and command ~= 'zR' and command ~= 'zr' and command ~= 'zA' then
    return
  end
  if renderer.materialize_subagent_details_at_cursor then
    renderer.materialize_subagent_details_at_cursor()
  end
end

local function apply_counted_fold_command(bufnr, command, explicit_count)
  local win = current_window_for_buffer(bufnr)
  if not win then
    return
  end

  if command == 'zA' then
    local info = fold_state(win)
    if not info.has_fold then
      return
    end
    if info.has_closed then
      set_output_auto_fold_suppressed(bufnr, true)
      open_all_folds(win)
      materialize_output_subagent_details(bufnr, command)
    else
      set_output_auto_fold_suppressed(bufnr, false)
      close_all_folds(win)
    end
    return
  end

  local count = tonumber(explicit_count) or tonumber(vim.v.count) or 0
  if command == 'zR' or (command == 'zr' and count > 1) then
    set_output_auto_fold_suppressed(bufnr, true)
    open_all_folds(win)
    materialize_output_subagent_details(bufnr, command)
  elseif command == 'zM' or (command == 'zm' and count > 1) then
    set_output_auto_fold_suppressed(bufnr, false)
    close_all_folds(win)
  else
    run_fold_command(win, (count > 0 and tostring(count) or '') .. command)
    materialize_output_subagent_details(bufnr, command)
  end
end

local function set_fold_keymaps(bufnr)
  if not valid_buf(bufnr) then
    return
  end
  local specs = {
    { 'zo', 'open fold' },
    { 'zO', 'open folds recursively' },
    { 'zc', 'close fold' },
    { 'za', 'toggle fold' },
    { 'zr', 'open folds by count' },
    { 'zm', 'close folds by count' },
    { 'zR', 'open all folds' },
    { 'zM', 'close all folds' },
    { 'zA', 'toggle all folds in buffer' },
  }
  for _, spec in ipairs(specs) do
    local lhs = spec[1]
    vim.keymap.set('n', lhs, function()
      apply_counted_fold_command(bufnr, lhs)
    end, { buffer = bufnr, silent = true, desc = 'Pi.dev: ' .. spec[2] })
  end
end

local function set_output_options(win)
  vim.wo[win].wrap = true
  vim.wo[win].foldmethod = 'manual'
  vim.wo[win].foldenable = true
  vim.wo[win].foldtext = [[v:lua.require('pi-dev.renderer').foldtext()]]
  set_window_title(win, output_title(win))
  lock_window_buffer(win)
end

local function set_input_options(win)
  vim.wo[win].wrap = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  set_window_title(win, input_title())
  lock_window_buffer(win)
end

local function set_abort_keymap(bufnr)
  if not valid_buf(bufnr) then
    return
  end
  vim.keymap.set({ 'n', 'i' }, '<C-c>', function()
    require('pi-dev.api').abort()
  end, { buffer = bufnr, silent = true, desc = 'Pi.dev: cancel current work' })
end

local function set_input_keymaps(bufnr)
  completion.setup_buffer(bufnr)
  set_abort_keymap(bufnr)
  vim.keymap.set('n', '<CR>', function()
    require('pi-dev.api').submit_input()
  end, { buffer = bufnr, silent = true, desc = 'Pi.dev: submit input' })
  vim.keymap.set('n', '<PageUp>', function()
    require('pi-dev.ui').recall_user_message(-1)
  end, { buffer = bufnr, silent = true, desc = 'Pi.dev: recall older user message' })
  vim.keymap.set('n', '<PageDown>', function()
    require('pi-dev.ui').recall_user_message(1)
  end, { buffer = bufnr, silent = true, desc = 'Pi.dev: recall newer user message' })
  vim.keymap.set('n', '<kPageUp>', function()
    require('pi-dev.ui').recall_user_message(-1)
  end, { buffer = bufnr, silent = true, desc = 'Pi.dev: recall older user message' })
  vim.keymap.set('n', '<kPageDown>', function()
    require('pi-dev.ui').recall_user_message(1)
  end, { buffer = bufnr, silent = true, desc = 'Pi.dev: recall newer user message' })
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function()
    require('pi-dev.api').submit_input()
  end, { buffer = bufnr, silent = true, desc = 'Pi.dev: submit input' })
  vim.keymap.set('i', '/', function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col('.') - 1
    if line:sub(1, col):match('^%s*$') then
      return '/\24\21'
    end
    return '/'
  end, { buffer = bufnr, expr = true, desc = 'Pi.dev: slash command completion' })
  vim.keymap.set('i', '@', function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col('.') - 1
    local before = line:sub(1, col)
    if before == '' or before:match('%s$') then
      return '@\24\21'
    end
    return '@'
  end, { buffer = bufnr, expr = true, desc = 'Pi.dev: @file path completion' })
  vim.keymap.set('i', ':', function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col('.') - 1
    local before = line:sub(1, col)
    if before:match('^%s*/skill$') then
      return ':\24\21'
    end
    return ':'
  end, { buffer = bufnr, expr = true, desc = 'Pi.dev: skill completion' })
  vim.keymap.set('i', '!', function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col('.') - 1
    local before = line:sub(1, col)
    if before == '' or before:match('^%s*$') or before:match('^%s*!$') then
      return '!\24\21'
    end
    return '!'
  end, { buffer = bufnr, expr = true, desc = 'Pi.dev: shell command completion' })
  vim.keymap.set('i', ' ', function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col('.') - 1
    local before = line:sub(1, col)
    if before:match('^%s*/export$') then
      return ' \24\21'
    end
    return ' '
  end, { buffer = bufnr, expr = true, desc = 'Pi.dev: export path completion' })
end

local function clear_interaction_keymaps(bufnr)
  if not valid_buf(bufnr) then
    return
  end

  local keys = { '<CR>', 'j', 'k', '<Up>', '<Down>', '<Esc>', '<C-s>', '/', 'q', 'gg', 'G', 'zc', 'zo', 'za', 'zr', 'zm', 'zR', 'zM', 'zA' }
  for _, mode in ipairs({ 'n', 'i' }) do
    for _, key in ipairs(keys) do
      pcall(vim.keymap.del, mode, key, { buffer = bufnr })
    end
  end
  for index = 1, 9 do
    pcall(vim.keymap.del, 'n', tostring(index), { buffer = bufnr })
  end
end

local function update_status_separator_text()
  if not valid_buf(state.ui.status_buf) then
    return
  end
  local width = valid_win(state.ui.output_win) and vim.api.nvim_win_get_width(state.ui.output_win) or vim.o.columns
  local line = statusline.render_for_width(width)
  set_buf_modifiable(state.ui.status_buf, true)
  vim.api.nvim_buf_set_lines(state.ui.status_buf, 0, -1, false, { line })
  set_buf_modifiable(state.ui.status_buf, false)
end

local function apply_configured_panel_dimensions()
  local opts = config.options.ui
  if valid_win(state.ui.output_win) and opts.position ~= 'bottom' then
    local width = size_arg(opts.width, vim.o.columns)
    pcall(vim.api.nvim_win_set_width, state.ui.output_win, width)
    if valid_win(state.ui.input_win) then
      pcall(vim.api.nvim_win_set_width, state.ui.input_win, width)
    end
  end

  if valid_win(state.ui.input_win) then
    local height = math.max(1, tonumber(opts.input_height) or 8)
    pcall(vim.api.nvim_win_set_height, state.ui.input_win, height)
    pcall(function()
      vim.wo[state.ui.input_win].winfixheight = true
    end)
  end
end

local function preserve_manual_panel_dimensions()
  -- Configured width/height are initial layout defaults. Do not re-apply
  -- them during chrome refreshes: WinResized also fires while a user drags
  -- Pi panel split borders with the mouse, and forcing dimensions there makes
  -- the panel snap back while resizing.
  if valid_win(state.ui.input_win) then
    pcall(function()
      vim.wo[state.ui.input_win].winfixheight = true
    end)
  end
end

local function place_foreign_buffer(bufnr)
  if not valid_buf(bufnr) or is_pi_buf(bufnr) then
    return
  end
  local file_win = state.ui.file_win
  if valid_win(file_win) and not is_pi_win(file_win) then
    pcall(vim.api.nvim_win_set_buf, file_win, bufnr)
  end
end

local input_locked = input.locked
local apply_input_lock = input.apply_lock

function M.input_locked()
  return input_locked()
end

local function lower_buf()
  if state.ui.interaction and state.ui.interaction.surface ~= 'output' and valid_buf(state.ui.interaction_buf) then
    return state.ui.interaction_buf
  end
  return state.ui.input_buf
end

local function output_surface_buf()
  if state.ui.interaction and state.ui.interaction.surface == 'output' and valid_buf(state.ui.tree_buf) then
    return state.ui.tree_buf
  end
  if state.ui.subagent_view and valid_buf(state.ui.subagent_view.buf) then
    return state.ui.subagent_view.buf
  end
  return state.ui.output_buf
end

local function restore_panel_buffer(win, wanted_buf)
  if not valid_win(win) or not valid_buf(wanted_buf) then
    return
  end
  local current_buf = vim.api.nvim_win_get_buf(win)
  if current_buf ~= wanted_buf then
    unlock_window_buffer(win)
    pcall(vim.api.nvim_win_set_buf, win, wanted_buf)
    place_foreign_buffer(current_buf)
  end
  lock_window_buffer(win)
end

function M.remember_file_window(win)
  win = win or vim.api.nvim_get_current_win()
  if valid_win(win) and not is_pi_win(win) then
    state.ui.file_win = win
  end
end

function M.guard_panel_buffers()
  restore_panel_buffer(state.ui.output_win, output_surface_buf())
  restore_panel_buffer(state.ui.input_win, lower_buf())
  restore_panel_buffer(state.ui.status_win, state.ui.status_buf)
end

local function status_separator_enabled()
  local ui_opts = config.options.ui or {}
  local separator = ui_opts.status_separator or {}
  local legacy = ui_opts.statusline or {}
  return separator.enable ~= false and legacy.enable ~= false
end

local function open_status_separator()
  if not status_separator_enabled() or not valid_win(state.ui.output_win) or not valid_buf(state.ui.status_buf) then
    return
  end

  local width = vim.api.nvim_win_get_width(state.ui.output_win)
  local height = vim.api.nvim_win_get_height(state.ui.output_win)
  if width <= 0 or height <= 0 then
    return
  end

  update_status_separator_text()

  -- Anchor on the last output-window row so the separator sits one row above
  -- the lower input/interaction split instead of bleeding into that pane.
  local separator_row = math.max(0, height - 1)
  if valid_win(state.ui.status_win) then
    pcall(vim.api.nvim_win_set_config, state.ui.status_win, {
      relative = 'win',
      win = state.ui.output_win,
      row = separator_row,
      col = 0,
      width = width,
      height = 1,
    })
    return
  end

  state.ui.status_win = vim.api.nvim_open_win(state.ui.status_buf, false, {
    relative = 'win',
    win = state.ui.output_win,
    row = separator_row,
    col = 0,
    width = width,
    height = 1,
    style = 'minimal',
    focusable = false,
    noautocmd = true,
    zindex = 40,
  })
  pcall(function()
    vim.wo[state.ui.status_win].winbar = ''
    vim.wo[state.ui.status_win].number = false
    vim.wo[state.ui.status_win].relativenumber = false
    vim.wo[state.ui.status_win].foldcolumn = '0'
    vim.wo[state.ui.status_win].signcolumn = 'no'
    vim.wo[state.ui.status_win].winhl = 'Normal:StatusLine,EndOfBuffer:StatusLine'
  end)
  lock_window_buffer(state.ui.status_win)
end

function M.refresh_chrome()
  ensure_buffers()
  set_abort_keymap(state.ui.output_buf)
  set_abort_keymap(state.ui.input_buf)
  set_abort_keymap(state.ui.interaction_buf)
  set_abort_keymap(state.ui.tree_buf)
  set_abort_keymap(state.ui.status_buf)
  set_fold_keymaps(state.ui.output_buf)
  set_fold_keymaps(state.ui.interaction_buf)
  set_fold_keymaps(state.ui.tree_buf)
  M.guard_panel_buffers()
  preserve_manual_panel_dimensions()
  if valid_win(state.ui.output_win) then
    set_output_options(state.ui.output_win)
  end
  if valid_win(state.ui.input_win) then
    set_input_options(state.ui.input_win)
  end
  apply_input_lock()
  open_status_separator()
end

function M.align()
  M.refresh_chrome()
end

function M.equalize_windows()
  vim.cmd('wincmd =')
  if state.ui.visible and valid_win(state.ui.output_win) and valid_win(state.ui.input_win) then
    apply_configured_panel_dimensions()
    M.refresh_chrome()
  end
end

function M.show()
  ensure_buffers()

  if valid_win(state.ui.output_win) and valid_win(state.ui.input_win) then
    local changed = not state.ui.visible
    state.ui.visible = true
    M.refresh_chrome()
    markdown.refresh_output()
    if changed then
      emit_visibility_changed(true)
    end
    return
  end

  local opts = config.options
  local current_win = vim.api.nvim_get_current_win()
  M.remember_file_window(current_win)

  if opts.ui.position == 'bottom' then
    local total_height = size_arg(opts.ui.height, vim.o.lines)
    vim.cmd('botright ' .. total_height .. 'new')
    state.ui.output_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.ui.output_win, state.ui.output_buf)
    set_output_options(state.ui.output_win)

    vim.api.nvim_set_current_win(state.ui.output_win)
    vim.cmd('rightbelow ' .. opts.ui.input_height .. 'split')
    state.ui.input_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.ui.input_win, state.ui.input_buf)
    set_input_options(state.ui.input_win)
  else
    local width = size_arg(opts.ui.width, vim.o.columns)
    vim.cmd('botright vertical ' .. width .. 'new')
    state.ui.output_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.ui.output_win, state.ui.output_buf)
    set_output_options(state.ui.output_win)

    vim.api.nvim_set_current_win(state.ui.output_win)
    vim.cmd('rightbelow ' .. opts.ui.input_height .. 'split')
    state.ui.input_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.ui.input_win, state.ui.input_buf)
    set_input_options(state.ui.input_win)
  end

  apply_configured_panel_dimensions()
  set_input_keymaps(state.ui.input_buf)
  local changed = not state.ui.visible
  state.ui.visible = true
  M.refresh_chrome()
  markdown.refresh_output()
  if changed then
    emit_visibility_changed(true)
  end

  if valid_win(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
end

function M.hide()
  local changed = state.ui.visible
  panel_teardown = true
  if valid_win(state.ui.status_win) then
    pcall(vim.api.nvim_win_close, state.ui.status_win, true)
  end
  if valid_win(state.ui.input_win) then
    pcall(vim.api.nvim_win_close, state.ui.input_win, true)
  end
  if valid_win(state.ui.output_win) then
    pcall(vim.api.nvim_win_close, state.ui.output_win, true)
  end
  state.ui.input_win = nil
  state.ui.output_win = nil
  state.ui.status_win = nil
  state.ui.visible = false
  panel_teardown = false
  if changed then
    emit_visibility_changed(false)
  end
end

function M.handle_window_closed(win)
  win = tonumber(win)
  if not win then
    return false
  end
  if win == state.ui.status_win then
    state.ui.status_win = nil
    return true
  end
  if panel_teardown or not state.ui.visible then
    return false
  end
  if win ~= state.ui.output_win and win ~= state.ui.input_win then
    return false
  end

  vim.schedule(function()
    if panel_teardown then
      return
    end
    M.hide()
  end)
  return true
end

function M.on_visibility_changed(listener)
  if type(listener) ~= 'function' then
    return nil
  end
  table.insert(visibility_listeners, listener)
  return listener
end

function M.toggle()
  if state.ui.visible and valid_win(state.ui.output_win) then
    M.hide()
  else
    M.show()
  end
end

function M.focus_input()
  return M.focus_lower_panel({ startinsert = false })
end

function M.focus_lower_panel(opts)
  opts = opts or {}
  M.show()
  if not valid_win(state.ui.input_win) then
    return false
  end
  local ok_cwd, current_cwd = pcall(vim.fn.getcwd)
  if ok_cwd and current_cwd and current_cwd ~= '' then
    pcall(vim.api.nvim_win_call, state.ui.input_win, function()
      pcall(vim.cmd, 'silent! lcd ' .. vim.fn.fnameescape(current_cwd))
    end)
  end
  vim.api.nvim_set_current_win(state.ui.input_win)
  local bufnr = vim.api.nvim_win_get_buf(state.ui.input_win)
  if bufnr == state.ui.input_buf then
    if opts.startinsert == true and not input_locked() then
      vim.cmd('startinsert')
    else
      pcall(vim.cmd, 'stopinsert')
    end
  elseif state.ui.interaction and (state.ui.interaction.kind == 'text' or state.ui.interaction.kind == 'editor') then
    vim.cmd('startinsert')
  else
    pcall(vim.cmd, 'stopinsert')
  end
  return true
end

function M.save_active_runtime_input()
  return input.save_active_runtime_input()
end

function M.restore_active_runtime_input()
  return input.restore_active_runtime_input()
end

function M.set_input_text(text)
  return input.set_text(text)
end

function M.get_input_text()
  return input.get_text()
end

function M.set_active_editor_interaction_text(text)
  return input.set_active_editor_interaction_text(text)
end

function M.set_editor_text(text)
  return input.set_editor_text(text)
end

function M.clear_input()
  return input.clear()
end

function M.recall_user_message(delta)
  return input.recall_user_message(delta)
end

local interaction_buffer = interaction_view.buffer
local interaction_window = interaction_view.window
local clear_window_folds = interaction_view.clear_window_folds
local snapshot_closed_folds = interaction_view.snapshot_closed_folds
local restore_closed_folds = interaction_view.restore_closed_folds
local restore_output_interaction = interaction_view.restore_output
local interaction_item_line = interaction_view.item_line
local apply_interaction_folds = interaction_view.apply_folds
local render_interaction = interaction_view.render
local interaction_item_is_visible = interaction_view.item_is_visible
local sync_interaction_selection_from_cursor = interaction_view.sync_selection_from_cursor
local refresh_selection_highlight = interaction_view.refresh_selection_highlight
local move_interaction = interaction_view.move
local focus_interaction_boundary = interaction_view.focus_boundary

local function folded_tree_submit_index(interaction)
  if not interaction or interaction.kind ~= 'tree' or interaction.surface ~= 'output' then
    return nil
  end
  local win = interaction_window(interaction)
  local bufnr = interaction_buffer(interaction)
  if not valid_win(win) or not valid_buf(bufnr) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local closed_start = vim.fn.foldclosed(row)
  for _, range in ipairs(interaction.fold_ranges or {}) do
    local start_line = tonumber(range.start_line)
    local end_index = tonumber(range.end_index)
    if start_line and end_index then
      if closed_start == start_line then
        return end_index
      end
      local start_index = tonumber(range.start_index)
      local selected = tonumber(interaction.selected) or 0
      local selected_branch_has_closed_details = start_index
        and start_index == selected + 1
        and vim.fn.foldclosed(start_line) == start_line
      if selected_branch_has_closed_details then
        return end_index
      end
    end
  end
  return nil
end

local runtime_for_interaction = interaction_queue.runtime_for
local queue_for_runtime = interaction_queue.for_runtime
local interaction_request_exists = interaction_queue.request_exists
local enqueue_interaction = interaction_queue.enqueue
local interaction_priority = interaction_queue.priority
local visible_interaction_priority = interaction_queue.visible_priority

function M.interaction_request_exists(runtime_key, request_id)
  if not request_id or request_id == '' then
    return false
  end
  local runtime = runtime_for_interaction({ runtime_key = runtime_key })
  return interaction_request_exists(runtime, request_id)
end

local function show_queued_interaction(item)
  if item.kind == 'text' then
    M.show_text_interaction(item.opts)
  else
    M.show_interaction(item.opts)
  end
end

local function process_next_interaction()
  local runtime = state.active_rpc_runtime()
  if state.ui.interaction then
    return
  end
  if runtime.current_extension_interaction then
    local current = runtime.current_extension_interaction
    runtime.current_extension_interaction = nil
    vim.schedule(function()
      if runtime.key ~= state.rpc.active_key or state.ui.interaction then
        runtime.current_extension_interaction = current
        return
      end
      show_queued_interaction(current)
    end)
    return
  end
  local queue = queue_for_runtime(runtime)
  if #queue == 0 then
    return
  end
  local next_interaction = table.remove(queue, 1)
  vim.schedule(function()
    if runtime.key ~= state.rpc.active_key then
      table.insert(queue_for_runtime(runtime), 1, next_interaction)
      return
    end
    if state.ui.interaction then
      table.insert(queue_for_runtime(runtime), 1, next_interaction)
      return
    end
    show_queued_interaction(next_interaction)
  end)
end

function M.process_next_interaction()
  process_next_interaction()
end

function M.visible_extension_interaction_belongs_to(runtime_key)
  local interaction = state.ui.interaction
  return interaction
    and interaction.request_id ~= nil
    and tostring(interaction.runtime_key or state.rpc.active_key) == tostring(runtime_key or state.rpc.active_key)
end

function M.save_visible_runtime_interaction()
  local interaction = state.ui.interaction
  if not interaction or not interaction.request_id or not interaction.source_opts then
    return false
  end
  local runtime = runtime_for_interaction({ runtime_key = interaction.runtime_key })
  if interaction.input_start and valid_buf(state.ui.interaction_buf) then
    local value = table.concat(vim.api.nvim_buf_get_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false), '\n')
    interaction.source_opts.default = value
    if interaction.kind == 'editor' then
      runtime.editor_text = value
    end
  end
  runtime.current_extension_interaction = {
    kind = interaction.queue_kind or (interaction.input_start and 'text' or 'select'),
    opts = interaction.source_opts,
  }
  return true
end

function M.close_visible_extension_interaction_for_runtime(runtime_key)
  if M.visible_extension_interaction_belongs_to(runtime_key) then
    M.close_interaction({ process_queue = false })
    return true
  end
  return false
end

local function set_buffer_lines(bufnr, lines, filetype)
  if not valid_buf(bufnr) then
    return false
  end
  vim.bo[bufnr].filetype = filetype or 'markdown'
  set_buf_modifiable(bufnr, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  set_buf_modifiable(bufnr, false)
  set_buf_readonly(bufnr, true)
  return true
end

function M.close_subagent_view(opts)
  opts = opts or {}
  local view = state.ui.subagent_view
  if not view then
    return false
  end
  state.ui.subagent_view = opts.parent_view
  local target_buf = state.ui.output_buf
  local target_title = view.parent_title or 'Pi chat'
  if opts.parent_view then
    target_buf = opts.parent_view.buf
    target_title = opts.parent_view.output_title or target_title
  end
  state.ui.output_title = target_title
  if opts.restore_buffer ~= false and valid_win(state.ui.output_win) and valid_buf(target_buf) then
    unlock_window_buffer(state.ui.output_win)
    pcall(vim.api.nvim_win_set_buf, state.ui.output_win, target_buf)
    lock_window_buffer(state.ui.output_win)
  end
  M.refresh_chrome()
  return true
end

function M.close_all_subagent_views(opts)
  opts = opts or {}
  local changed = state.ui.subagent_view ~= nil
  state.ui.subagent_view = nil
  if opts.restore_title ~= false then
    state.ui.output_title = opts.title or state.ui.parent_output_title or state.ui.output_title
  end
  if opts.restore_buffer ~= false and valid_win(state.ui.output_win) and valid_buf(state.ui.output_buf) then
    unlock_window_buffer(state.ui.output_win)
    pcall(vim.api.nvim_win_set_buf, state.ui.output_win, state.ui.output_buf)
    lock_window_buffer(state.ui.output_win)
  end
  if changed then
    M.refresh_chrome()
  end
  return changed
end

local function refresh_subagent_view(view, tool_call_id, children)
  if not view or view.parent_tool_call_id ~= tool_call_id then
    return false
  end
  for _, child in ipairs(children or {}) do
    if child.header == view.child_header or child.title == view.title or child.label == view.title then
      view.title = child.title or child.label or view.title or 'subagent'
      view.child_header = child.header or view.child_header
      view.output_title = subagent.title_text(view.title, view.depth)
      local bufnr = subagent.ensure_view_buffer(view, state.ui, buffers.setup_buffer, config.options.ui.output_filetype)
      set_buffer_lines(bufnr, subagent.replace_title(child.lines or {}, view.title, view.depth), config.options.ui.output_filetype)
      return true
    end
  end
  return false
end

function M.refresh_subagent_view_from_parent(tool_call_id, children)
  local changed = false
  local view = state.ui.subagent_view
  while view do
    changed = refresh_subagent_view(view, tool_call_id, children) or changed
    view = view.parent_view
  end
  if changed then
    if state.ui.subagent_view and state.ui.subagent_view.output_title then
      state.ui.output_title = state.ui.subagent_view.output_title
    end
    M.refresh_chrome()
  end
  return changed
end

function M.open_subagent_at_cursor()
  local win = state.ui.output_win
  if not valid_win(win) then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local child
  if bufnr == state.ui.output_buf then
    local ok, renderer = pcall(require, 'pi-dev.renderer')
    if ok and renderer.subagent_child_at_line then
      child = renderer.subagent_child_at_line(line)
    end
  elseif state.ui.subagent_view and bufnr == state.ui.subagent_view.buf then
    child = subagent.child_from_buffer(bufnr, line)
  end
  if not child then
    vim.notify('No subagent block under cursor.', vim.log.levels.INFO)
    return false
  end
  local parent_view = state.ui.subagent_view
  local depth = (parent_view and parent_view.depth or 0) + 1
  local view = {
    parent_view = parent_view,
    parent_title = parent_view and parent_view.output_title or state.ui.output_title,
    depth = depth,
    title = child.title or child.label or 'subagent',
    parent_tool_call_id = child.parent_tool_call_id,
    child_header = child.header,
  }
  view.output_title = subagent.title_text(view.title, depth)
  local bufnr_new = subagent.ensure_view_buffer(view, state.ui, buffers.setup_buffer, config.options.ui.output_filetype)
  set_buffer_lines(bufnr_new, subagent.replace_title(child.lines or {}, view.title, depth), config.options.ui.output_filetype)
  state.ui.subagent_view = view
  state.ui.output_title = view.output_title
  M.show()
  if valid_win(state.ui.output_win) then
    unlock_window_buffer(state.ui.output_win)
    pcall(vim.api.nvim_win_set_buf, state.ui.output_win, bufnr_new)
    lock_window_buffer(state.ui.output_win)
    pcall(vim.api.nvim_set_current_win, state.ui.output_win)
  end
  M.refresh_chrome()
  return true
end

function M.return_to_parent_subagent()
  local view = state.ui.subagent_view
  if not view then
    vim.notify('Already at parent Pi chat.', vim.log.levels.INFO)
    return false
  end
  return M.close_subagent_view({ parent_view = view.parent_view })
end

function M.close_interaction(opts)
  opts = opts or {}
  local interaction = state.ui.interaction
  if not interaction then
    if opts.process_queue ~= false then
      process_next_interaction()
    end
    return
  end
  if opts.save_runtime_interaction then
    M.save_visible_runtime_interaction()
  elseif interaction.request_id and interaction.runtime_key then
    local runtime = state.ensure_rpc_runtime(interaction.runtime_key)
    if runtime.current_extension_interaction and runtime.current_extension_interaction.opts and runtime.current_extension_interaction.opts.request_id == interaction.request_id then
      runtime.current_extension_interaction = nil
    end
  end
  if state.ui.interaction_cursor_autocmd then
    pcall(vim.api.nvim_del_autocmd, state.ui.interaction_cursor_autocmd)
    state.ui.interaction_cursor_autocmd = nil
  end
  local bufnr = interaction_buffer(interaction)
  state.ui.interaction = nil
  clear_interaction_keymaps(bufnr)
  if interaction.surface == 'output' then
    restore_output_interaction(interaction)
    M.refresh_chrome()
    if opts.restore_focus ~= false and valid_win(interaction.restore_focus_win) then
      pcall(vim.api.nvim_set_current_win, interaction.restore_focus_win)
    end
  else
    state.ui.input_title = 'Pi input'
    state.ui.input_hint = 'normal <CR> / insert <C-s> submit'
    if valid_buf(state.ui.interaction_buf) then
      vim.bo[state.ui.interaction_buf].readonly = false
      vim.bo[state.ui.interaction_buf].modifiable = true
      vim.api.nvim_buf_set_lines(state.ui.interaction_buf, 0, -1, false, {})
      vim.bo[state.ui.interaction_buf].modifiable = false
      vim.bo[state.ui.interaction_buf].readonly = true
    end
    M.refresh_chrome()
    set_input_keymaps(state.ui.input_buf)
  end
  if opts.process_queue ~= false then
    process_next_interaction()
  end
end

function M.show_interaction(opts)
  opts = opts or {}
  local runtime = runtime_for_interaction(opts)
  opts.runtime_key = opts.runtime_key or (runtime and runtime.key) or state.rpc.active_key
  if opts.request_id and interaction_request_exists(runtime, opts.request_id) then
    return false
  end
  if tostring(opts.runtime_key or state.rpc.active_key) ~= tostring(state.rpc.active_key or 'default') then
    enqueue_interaction('select', opts)
    M.refresh_chrome()
    return false
  end
  local current_interaction = state.ui.interaction
  local current_priority = visible_interaction_priority()
  local new_priority = interaction_priority(opts.kind)
  if current_interaction then
    if current_priority > new_priority then
      if opts.defer_if_busy then
        return enqueue_interaction('select', opts)
      end
      return false
    end
    if current_priority == new_priority and opts.defer_if_busy then
      return enqueue_interaction('select', opts)
    end
  end
  local current_before = vim.api.nvim_get_current_win()
  local was_typing_in_input = current_before == state.ui.input_win
  local surface = opts.surface == 'output' and 'output' or nil
  ensure_buffers()
  M.show()
  if state.ui.interaction then
    local save_runtime_interaction = state.ui.interaction.request_id ~= nil and visible_interaction_priority() < new_priority
    M.close_interaction({ process_queue = false, save_runtime_interaction = save_runtime_interaction, restore_focus = false })
  end
  local bufnr = surface == 'output' and state.ui.tree_buf or state.ui.interaction_buf
  clear_interaction_keymaps(bufnr)

  local restore_output
  if surface == 'output' and valid_buf(state.ui.output_buf) then
    restore_output = {
      title = state.ui.output_title,
    }
    state.ui.output_title = opts.winbar_title or opts.title or 'Pi tree'
    if valid_win(state.ui.output_win) and valid_buf(state.ui.tree_buf) then
      unlock_window_buffer(state.ui.output_win)
      pcall(vim.api.nvim_win_set_buf, state.ui.output_win, state.ui.tree_buf)
      lock_window_buffer(state.ui.output_win)
    end
  else
    state.ui.input_title = opts.winbar_title or opts.title or 'Pi selection'
    state.ui.input_hint = opts.hint or 'j/k move, 1-9/Enter choose, Esc cancel'
  end
  M.refresh_chrome()
  local items = opts.items or {}
  local selected = math.max(1, math.min(#items, tonumber(opts.selected) or 1))
  if items[selected] and items[selected].selectable == false then
    for index, item in ipairs(items) do
      if item.selectable ~= false then
        selected = index
        break
      end
    end
  end
  state.ui.interaction = {
    runtime_key = opts.runtime_key or state.rpc.active_key,
    request_id = opts.request_id,
    queue_kind = 'select',
    source_opts = opts.request_id and opts or nil,
    title = opts.title,
    restore_focus_win = current_before,
    message = opts.message,
    items = items,
    surface = surface,
    restore_output = restore_output,
    selected = selected,
    filetype = opts.filetype,
    markdown = opts.markdown,
    numbered = opts.numbered,
    selection_marker = opts.selection_marker,
    selected_hl = opts.selected_hl,
    kind = opts.kind,
    folds = opts.folds,
    before_submit = opts.before_submit,
    on_submit = opts.on_submit,
    on_cancel = opts.on_cancel,
  }
  local interaction_buf = interaction_buffer(state.ui.interaction)
  if valid_buf(interaction_buf) then
    vim.bo[interaction_buf].filetype = opts.filetype or 'markdown'
  end

  local function submit(index)
    local interaction = state.ui.interaction
    if not interaction then
      return
    end
    sync_interaction_selection_from_cursor()
    index = index or folded_tree_submit_index(interaction) or interaction.selected
    local item = interaction.items[index]
    if not item or item.selectable == false then
      return
    end
    if interaction.before_submit and interaction.before_submit(item) == false then
      return
    end
    local on_submit = interaction.on_submit
    M.close_interaction()
    if on_submit then
      on_submit(item)
    end
  end

  local function cancel()
    local interaction = state.ui.interaction
    if not interaction then
      return
    end
    local on_cancel = interaction.on_cancel
    M.close_interaction()
    if on_cancel then
      on_cancel()
    end
  end

  M.refresh_chrome()
  render_interaction()
  interaction_buf = interaction_buffer(state.ui.interaction)
  state.ui.interaction_cursor_autocmd = vim.api.nvim_create_autocmd({ 'CursorMoved' }, {
    buffer = interaction_buf,
    callback = sync_interaction_selection_from_cursor,
  })
  vim.keymap.set('n', '<CR>', function()
    submit()
  end, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: choose interaction option' })
  vim.keymap.set('n', 'j', function()
    move_interaction(1)
  end, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: next interaction option' })
  vim.keymap.set('n', '<Down>', function()
    move_interaction(1)
  end, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: next interaction option' })
  vim.keymap.set('n', 'k', function()
    move_interaction(-1)
  end, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: previous interaction option' })
  vim.keymap.set('n', '<Up>', function()
    move_interaction(-1)
  end, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: previous interaction option' })
  vim.keymap.set('n', 'gg', function()
    focus_interaction_boundary('first')
  end, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: focus first interaction option' })
  vim.keymap.set('n', 'G', function()
    focus_interaction_boundary('last')
  end, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: focus last interaction option' })
  vim.keymap.set('n', '<Esc>', cancel, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: cancel interaction' })
  vim.keymap.set('n', 'q', cancel, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: close interaction' })
  local function containing_fold_start(interaction, row)
    local closed = vim.fn.foldclosed(row)
    if closed ~= -1 then
      return closed
    end
    local best_start
    local best_size
    for _, range in ipairs(interaction.fold_ranges or {}) do
      local start_line = tonumber(range.start_line)
      local end_line = tonumber(range.end_line)
      if start_line and end_line and start_line <= row and row <= end_line then
        local size = end_line - start_line
        if not best_size or size < best_size then
          best_start = start_line
          best_size = size
        end
      end
    end
    return best_start
  end
  local function fold_action(action)
    return function()
      local interaction = state.ui.interaction
      local win = interaction_window(interaction)
      if not interaction or not valid_win(win) or vim.api.nvim_win_get_buf(win) ~= interaction_buffer(interaction) then
        return
      end
      if action == 'zr' or action == 'zm' or action == 'zR' or action == 'zM' or action == 'zA' then
        apply_counted_fold_command(interaction_buffer(interaction), action)
      else
        local row = containing_fold_start(interaction, vim.api.nvim_win_get_cursor(win)[1])
        if not row or not (interaction.fold_start_lines and interaction.fold_start_lines[row]) then
          return
        end
        pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
        run_fold_command(win, ((tonumber(vim.v.count) or 0) > 0 and tostring(vim.v.count) or '') .. action)
      end
      sync_interaction_selection_from_cursor()
      refresh_selection_highlight(interaction)
    end
  end
  vim.keymap.set('n', 'zc', fold_action('zc'), { buffer = interaction_buf, silent = true, desc = 'Pi.dev: close interaction fold' })
  vim.keymap.set('n', 'zo', fold_action('zo'), { buffer = interaction_buf, silent = true, desc = 'Pi.dev: open interaction fold' })
  vim.keymap.set('n', 'za', fold_action('za'), { buffer = interaction_buf, silent = true, desc = 'Pi.dev: toggle interaction fold' })
  vim.keymap.set('n', 'zr', fold_action('zr'), { buffer = interaction_buf, silent = true, desc = 'Pi.dev: open interaction folds by count' })
  vim.keymap.set('n', 'zm', fold_action('zm'), { buffer = interaction_buf, silent = true, desc = 'Pi.dev: close interaction folds by count' })
  vim.keymap.set('n', 'zR', fold_action('zR'), { buffer = interaction_buf, silent = true, desc = 'Pi.dev: open all interaction folds' })
  vim.keymap.set('n', 'zM', fold_action('zM'), { buffer = interaction_buf, silent = true, desc = 'Pi.dev: close all interaction folds' })
  vim.keymap.set('n', 'zA', fold_action('zA'), { buffer = interaction_buf, silent = true, desc = 'Pi.dev: toggle all interaction folds' })

  local fold_commands_with_count_prefix = {
    zc = true,
    zo = true,
    za = true,
    zC = true,
    zO = true,
    zA = true,
    zr = true,
    zm = true,
    zR = true,
    zM = true,
  }
  local function getchar_nowait()
    local value = vim.fn.getchar(0)
    if value == 0 then
      return nil
    end
    if type(value) == 'number' then
      return vim.fn.nr2char(value)
    end
    return value
  end
  local function submit_or_counted_fold(index)
    return function()
      local count_text = tostring(index)
      local next_key = getchar_nowait()
      while type(next_key) == 'string' and next_key:match('^%d$') do
        count_text = count_text .. next_key
        next_key = getchar_nowait()
      end
      if next_key == 'z' then
        local suffix = getchar_nowait()
        local fold_command = type(suffix) == 'string' and ('z' .. suffix) or nil
        if fold_command and fold_commands_with_count_prefix[fold_command] then
          local interaction = state.ui.interaction
          local bufnr = interaction_buffer(interaction)
          apply_counted_fold_command(bufnr, fold_command, tonumber(count_text))
          sync_interaction_selection_from_cursor()
          refresh_selection_highlight(interaction)
          return
        end
      end
      submit(index)
    end
  end

  for index, item in ipairs(state.ui.interaction.items) do
    if index <= 9 and item.selectable ~= false then
      vim.keymap.set('n', tostring(index), submit_or_counted_fold(index), { buffer = interaction_buf, silent = true, desc = 'Pi.dev: choose option ' .. index })
    end
  end

  local focus_win = interaction_window(state.ui.interaction)
  if opts.focus ~= false and valid_win(focus_win) then
    if surface == 'output' or was_typing_in_input or opts.normal ~= false then
      vim.cmd('stopinsert')
    end
    vim.api.nvim_set_current_win(focus_win)
  end
end

function M.show_text_interaction(opts)
  opts = opts or {}
  local runtime = runtime_for_interaction(opts)
  opts.runtime_key = opts.runtime_key or (runtime and runtime.key) or state.rpc.active_key
  if opts.request_id and interaction_request_exists(runtime, opts.request_id) then
    return false
  end
  if tostring(opts.runtime_key or state.rpc.active_key) ~= tostring(state.rpc.active_key or 'default') then
    enqueue_interaction('text', opts)
    M.refresh_chrome()
    return false
  end
  local current_priority = visible_interaction_priority()
  local new_priority = interaction_priority(opts.kind or 'text')
  if state.ui.interaction then
    if current_priority > new_priority then
      if opts.defer_if_busy then
        return enqueue_interaction('text', opts)
      end
      return false
    end
    if current_priority == new_priority and opts.defer_if_busy then
      return enqueue_interaction('text', opts)
    end
  end
  ensure_buffers()
  M.show()
  if state.ui.interaction then
    local save_runtime_interaction = state.ui.interaction.request_id ~= nil and visible_interaction_priority() < new_priority
    M.close_interaction({ process_queue = false, save_runtime_interaction = save_runtime_interaction, restore_focus = false })
  end
  clear_interaction_keymaps(state.ui.interaction_buf)

  local message_lines = {}
  if opts.message and opts.message ~= '' then
    message_lines = vim.split(opts.message, '\n', { plain = true })
  end

  local lines = { opts.title or 'Pi input', '' }
  vim.list_extend(lines, message_lines)
  if #message_lines > 0 then
    table.insert(lines, '')
  end
  if opts.placeholder and opts.placeholder ~= '' then
    table.insert(lines, '_Placeholder: ' .. opts.placeholder .. '_')
    table.insert(lines, '')
  end
  local submit_hint = opts.submit_on_enter == false and 'Type below. Submit with <C-s>; cancel with <Esc>.'
    or 'Type below. Submit with <C-s> or normal <CR>; cancel with <Esc>.'
  table.insert(lines, submit_hint)
  table.insert(lines, '')
  local input_start = #lines + 1
  local default_text = tostring(opts.default or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
  local default_lines = vim.split(default_text, '\n', { plain = true })
  if #default_lines == 0 then
    default_lines = { '' }
  end
  vim.list_extend(lines, default_lines)

  state.ui.input_title = opts.winbar_title or opts.title or 'Pi input'
  state.ui.input_hint = opts.hint or '<C-s> / normal <CR> submit, Esc cancel'
  state.ui.interaction = {
    runtime_key = opts.runtime_key or state.rpc.active_key,
    request_id = opts.request_id,
    queue_kind = 'text',
    source_opts = opts.request_id and opts or nil,
    kind = opts.kind or 'text',
    title = opts.title,
    input_start = input_start,
    on_submit = opts.on_submit,
    on_cancel = opts.on_cancel,
  }
  M.refresh_chrome()

  local interaction_buf = state.ui.interaction_buf
  vim.bo[interaction_buf].filetype = 'text'
  vim.bo[interaction_buf].readonly = false
  vim.bo[interaction_buf].modifiable = true
  vim.api.nvim_buf_set_lines(interaction_buf, 0, -1, false, lines)

  local function submit()
    local interaction = state.ui.interaction
    if not interaction then
      return
    end
    local value_lines = vim.api.nvim_buf_get_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false)
    local value = table.concat(value_lines, '\n')
    local on_submit = interaction.on_submit
    M.close_interaction()
    if on_submit then
      on_submit(value)
    end
  end

  local function cancel()
    local interaction = state.ui.interaction
    if not interaction then
      return
    end
    local on_cancel = interaction.on_cancel
    M.close_interaction()
    if on_cancel then
      on_cancel()
    end
  end

  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: submit interaction input' })
  if opts.submit_on_enter ~= false then
    vim.keymap.set('n', '<CR>', submit, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: submit interaction input' })
  end
  vim.keymap.set('n', '<Esc>', cancel, { buffer = interaction_buf, silent = true, desc = 'Pi.dev: cancel interaction input' })

  if valid_win(state.ui.input_win) then
    vim.api.nvim_set_current_win(state.ui.input_win)
    vim.api.nvim_win_set_cursor(state.ui.input_win, { input_start, 0 })
    vim.cmd('startinsert')
  end
end

function M.submit_input()
  if state.ui.interaction or input_locked() then
    return false
  end
  local text = vim.trim(M.get_input_text())
  if text == '' then
    return false
  end
  M.clear_input()
  local api = require('pi-dev.api')
  return api.submit_text(text)
end

function M.set_status(key, text)
  if text == nil or text == vim.NIL then
    state.ui.statuses[key] = nil
  else
    state.ui.statuses[key] = text
  end
end

function M.set_widget(key, lines)
  if lines == nil or lines == vim.NIL then
    state.ui.widgets[key] = nil
  else
    state.ui.widgets[key] = lines
  end
end

return M
