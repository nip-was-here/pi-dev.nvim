-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local buffers = require('pi-dev.ui.buffers')
local format = require('pi-dev.format')
local state = require('pi-dev.state')

local M = {}

local interaction_ns = vim.api.nvim_create_namespace('pi-dev-interaction')
local interaction_selected_ns = vim.api.nvim_create_namespace('pi-dev-interaction-selected')

local valid_win = buffers.valid_win
local valid_buf = buffers.valid_buf
local lock_window_buffer = buffers.lock_window_buffer
local unlock_window_buffer = buffers.unlock_window_buffer

local function interaction_buffer(interaction)
  if interaction and interaction.surface == 'output' then
    return state.ui.tree_buf
  end
  return state.ui.interaction_buf
end

local function interaction_window(interaction)
  if interaction and interaction.surface == 'output' then
    return state.ui.output_win
  end
  return state.ui.input_win
end

local function clear_window_folds(win)
  if not valid_win(win) then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd('silent! normal! zE')
  end)
end

local function snapshot_closed_folds(win, bufnr)
  if not valid_win(win) or not valid_buf(bufnr) then
    return {}
  end
  local folds = {}
  vim.api.nvim_win_call(win, function()
    local line = 1
    local total = vim.api.nvim_buf_line_count(bufnr)
    while line <= total do
      local start_line = vim.fn.foldclosed(line)
      if start_line ~= -1 and start_line == line then
        local end_line = vim.fn.foldclosedend(line)
        if end_line and end_line >= start_line then
          table.insert(folds, { start_line = start_line, end_line = end_line })
          line = end_line + 1
        else
          line = line + 1
        end
      else
        line = line + 1
      end
    end
  end)
  return folds
end

local function restore_closed_folds(win, bufnr, folds)
  if not valid_win(win) or not valid_buf(bufnr) or not folds or #folds == 0 then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.wo[win].foldmethod = 'manual'
    local total = vim.api.nvim_buf_line_count(bufnr)
    for _, fold in ipairs(folds) do
      local start_line = math.max(1, math.min(tonumber(fold.start_line) or 1, total))
      local end_line = math.max(start_line, math.min(tonumber(fold.end_line) or start_line, total))
      if end_line > start_line then
        vim.cmd(string.format('%d,%dfold', start_line, end_line))
        pcall(vim.api.nvim_win_set_cursor, win, { start_line, 0 })
        vim.cmd('silent! normal! zc')
      end
    end
  end)
end

local function restore_output_interaction(interaction)
  if not interaction or interaction.surface ~= 'output' or not interaction.restore_output then
    return
  end
  if valid_win(state.ui.output_win) and valid_buf(state.ui.output_buf) then
    unlock_window_buffer(state.ui.output_win)
    pcall(vim.api.nvim_win_set_buf, state.ui.output_win, state.ui.output_buf)
    lock_window_buffer(state.ui.output_win)
  end
  state.ui.output_title = interaction.restore_output.title or 'Pi chat'
end

local function interaction_item_line(interaction, index)
  index = tonumber(index)
  if not index then
    return nil
  end
  if interaction.item_line_by_index and interaction.item_line_by_index[index] then
    return interaction.item_line_by_index[index]
  end
  return (interaction.item_start_line or 1) + index - 1
end

local function apply_interaction_folds(interaction)
  local bufnr = interaction_buffer(interaction)
  local win = interaction_window(interaction)
  if not interaction or not valid_buf(bufnr) or not valid_win(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  local folds = interaction.folds or {}
  interaction.fold_start_lines = {}
  interaction.fold_ranges = {}
  interaction.fold_labels = {}
  if #folds == 0 then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.wo[win].foldmethod = 'manual'
    vim.wo[win].foldenable = true
    vim.cmd('silent! normal! zE')
    local closed_starts = {}
    local ordered_folds = vim.deepcopy(folds)
    table.sort(ordered_folds, function(a, b)
      local a_start = tonumber(a.start_line) or interaction_item_line(interaction, a.start_index) or 0
      local a_end = tonumber(a.end_line) or interaction_item_line(interaction, a.end_index) or a_start
      local b_start = tonumber(b.start_line) or interaction_item_line(interaction, b.start_index) or 0
      local b_end = tonumber(b.end_line) or interaction_item_line(interaction, b.end_index) or b_start
      local a_size = a_end - a_start
      local b_size = b_end - b_start
      if a_size == b_size then
        return a_start > b_start
      end
      return a_size < b_size
    end)
    for _, fold in ipairs(ordered_folds) do
      local start_line = tonumber(fold.start_line) or interaction_item_line(interaction, fold.start_index)
      local end_line = tonumber(fold.end_line) or interaction_item_line(interaction, fold.end_index)
      if start_line and end_line and end_line > start_line and end_line <= vim.api.nvim_buf_line_count(bufnr) then
        interaction.fold_start_lines[start_line] = true
        if fold.label and fold.label ~= '' then
          interaction.fold_labels[start_line] = tostring(fold.label)
        end
        table.insert(interaction.fold_ranges, {
          start_line = start_line,
          end_line = end_line,
          start_index = fold.start_index,
          end_index = fold.end_index,
        })
        vim.cmd(string.format('%d,%dfold', start_line, end_line))
        if fold.closed ~= false then
          table.insert(closed_starts, start_line)
        end
      end
    end
    vim.cmd('silent! normal! zR')
    table.sort(closed_starts, function(a, b)
      return a > b
    end)
    for _, start_line in ipairs(closed_starts) do
      pcall(vim.api.nvim_win_set_cursor, win, { start_line, 0 })
      vim.cmd('silent! normal! zc')
    end
  end)
end

local function render_interaction()
  local interaction = state.ui.interaction
  local bufnr = interaction_buffer(interaction)
  if not interaction or not valid_buf(bufnr) then
    return
  end

  local plain = interaction.filetype == 'text' or interaction.markdown == false
  local numbered = interaction.numbered ~= false
  local title = interaction.title or 'Pi interaction'
  local lines = { plain and title or ('#### ' .. title), '' }
  if interaction.message and interaction.message ~= '' then
    vim.list_extend(lines, vim.split(interaction.message, '\n', { plain = true }))
    table.insert(lines, '')
  end

  local meta_ranges = {}
  local selected_ranges = {}
  local show_selection_marker = interaction.selection_marker ~= false
  interaction.item_start_line = #lines + 1
  interaction.item_line_by_index = {}
  interaction.line_to_item = {}
  for index, item in ipairs(interaction.items or {}) do
    for _, before_line in ipairs(item.before_lines or {}) do
      table.insert(lines, before_line)
    end
    local label = item.label or ''
    local meta = item.meta or item.date_text
    local selectable = item.selectable ~= false
    local selected = selectable and index == interaction.selected
    local line
    if plain then
      line = show_selection_marker and ((selected and '> ' or '  ') .. label) or label
    elseif selected and numbered then
      line = string.format('- **%d.** %s', index, label)
    elseif selected then
      line = '- **' .. label .. '**'
    elseif numbered then
      line = string.format('- %d. %s', index, label)
    else
      line = '- ' .. label
    end
    if meta and meta ~= '' then
      local meta_text = tostring(meta)
      local win = interaction_window(interaction)
      local max_width = format.window_text_width(win, vim.o.columns)
      line = format.right_suffix(line, meta_text, max_width)
      if line:sub(-#meta_text) == meta_text then
        table.insert(meta_ranges, { line = #lines, start_col = math.max(0, #line - #meta_text), end_col = #line })
      end
    end
    table.insert(lines, line)
    interaction.item_line_by_index[index] = #lines
    interaction.line_to_item[#lines] = selectable and index or nil
    if selected then
      table.insert(selected_ranges, { line = #lines - 1, end_col = #line })
    end
  end

  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, interaction_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, interaction_selected_ns, 0, -1)
  for _, range in ipairs(meta_ranges) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, interaction_ns, range.line, range.start_col, {
      end_col = range.end_col,
      hl_group = 'Comment',
    })
  end
  for _, range in ipairs(selected_ranges) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, interaction_selected_ns, range.line, 0, {
      end_col = math.max(1, range.end_col),
      hl_group = interaction.selected_hl or 'CursorLine',
      hl_eol = true,
    })
  end
  vim.bo[bufnr].modifiable = false
  if interaction.surface ~= 'output' then
    vim.bo[bufnr].readonly = true
  else
    clear_window_folds(state.ui.output_win)
  end

  apply_interaction_folds(interaction)

  local win = interaction_window(interaction)
  if valid_win(win) and vim.api.nvim_win_get_buf(win) == bufnr then
    local row = interaction.item_line_by_index and interaction.item_line_by_index[interaction.selected]
    row = row or math.min(#lines, math.max(1, (interaction.item_start_line or 1) + (interaction.selected or 1) - 1))
    pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
  end
end

local function interaction_item_is_visible(interaction, index)
  local win = interaction_window(interaction)
  local bufnr = interaction_buffer(interaction)
  local row = interaction_item_line(interaction, index)
  if not row or not valid_win(win) or not valid_buf(bufnr) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return true
  end
  local closed = vim.fn.foldclosed(row)
  return closed == -1 or closed == row
end

local function sync_interaction_selection_from_cursor()
  local interaction = state.ui.interaction
  local bufnr = interaction_buffer(interaction)
  local win = interaction_window(interaction)
  if not interaction or not valid_win(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  local count = #(interaction.items or {})
  if count == 0 then
    return
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local closed = vim.fn.foldclosed(row)
  if closed ~= -1 then
    row = closed
  end
  local index = interaction.line_to_item and interaction.line_to_item[row]
  if index and index >= 1 and index <= count then
    interaction.selected = index
  end
end

local function refresh_selection_highlight(interaction)
  local bufnr = interaction_buffer(interaction)
  local win = interaction_window(interaction)
  if not interaction or not valid_buf(bufnr) then
    return false
  end
  local row = interaction.item_line_by_index and interaction.item_line_by_index[interaction.selected]
  if not row then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  vim.api.nvim_buf_clear_namespace(bufnr, interaction_selected_ns, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, interaction_selected_ns, row - 1, 0, {
    end_col = math.max(1, #line),
    hl_group = interaction.selected_hl or 'CursorLine',
    hl_eol = true,
  })
  if valid_win(win) and vim.api.nvim_win_get_buf(win) == bufnr then
    pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
  end
  return true
end

local function update_selected_item(interaction, previous)
  if interaction.selected == previous then
    if refresh_selection_highlight(interaction) then
      return
    end
  elseif interaction.surface == 'output' or interaction.selection_marker == false then
    if refresh_selection_highlight(interaction) then
      return
    end
  end
  render_interaction()
end

local function move_interaction(delta)
  local interaction = state.ui.interaction
  if not interaction then
    return
  end
  sync_interaction_selection_from_cursor()
  local count = #(interaction.items or {})
  if count == 0 then
    return
  end
  local selected = interaction.selected
  local previous = selected
  for _ = 1, count do
    selected = ((selected - 1 + delta) % count) + 1
    local item = interaction.items[selected]
    if item and item.selectable ~= false and interaction_item_is_visible(interaction, selected) then
      interaction.selected = selected
      break
    end
  end
  update_selected_item(interaction, previous)
end

local function focus_interaction_boundary(direction)
  local interaction = state.ui.interaction
  if not interaction then
    return
  end
  local count = #(interaction.items or {})
  if count == 0 then
    return
  end
  local start_index = direction == 'last' and count or 1
  local stop_index = direction == 'last' and 1 or count
  local step = direction == 'last' and -1 or 1
  local previous = interaction.selected
  for index = start_index, stop_index, step do
    local item = interaction.items[index]
    if item and item.selectable ~= false and interaction_item_is_visible(interaction, index) then
      interaction.selected = index
      break
    end
  end
  update_selected_item(interaction, previous)
end


M.buffer = interaction_buffer
M.window = interaction_window
M.clear_window_folds = clear_window_folds
M.snapshot_closed_folds = snapshot_closed_folds
M.restore_closed_folds = restore_closed_folds
M.restore_output = restore_output_interaction
M.item_line = interaction_item_line
M.apply_folds = apply_interaction_folds
M.render = render_interaction
M.item_is_visible = interaction_item_is_visible
M.sync_selection_from_cursor = sync_interaction_selection_from_cursor
M.refresh_selection_highlight = refresh_selection_highlight
M.move = move_interaction
M.focus_boundary = focus_interaction_boundary

return M
