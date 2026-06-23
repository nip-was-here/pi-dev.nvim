-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local buffers = require('pi-dev.ui.buffers')
local state = require('pi-dev.state')

local M = {}

function M.locked()
  if state.ui.subagent_view ~= nil then
    return true
  end
  local runtime = state.rpc.runtimes[state.rpc.active_key or 'default']
  return runtime and runtime.loading == true and runtime.loading_lock == true and runtime.status == 'loading'
end

function M.apply_lock()
  if not buffers.valid_buf(state.ui.input_buf) then
    return
  end
  if M.locked() then
    vim.bo[state.ui.input_buf].modifiable = false
    vim.bo[state.ui.input_buf].readonly = true
  else
    vim.bo[state.ui.input_buf].readonly = false
    vim.bo[state.ui.input_buf].modifiable = true
  end
end

function M.normalize_text(text)
  return tostring(text or ''):gsub('\r\n', '\n'):gsub('\r', '\n')
end

function M.text_lines(text)
  local lines = vim.split(M.normalize_text(text), '\n', { plain = true })
  if #lines == 0 then
    return { '' }
  end
  return lines
end

function M.set_buffer_text(text)
  buffers.ensure()
  buffers.set_modifiable(state.ui.input_buf, true)
  vim.api.nvim_buf_set_lines(state.ui.input_buf, 0, -1, false, M.text_lines(text))
  M.apply_lock()
end

function M.save_active_runtime_input()
  if not buffers.valid_buf(state.ui.input_buf) then
    return
  end
  local runtime = state.active_rpc_runtime()
  runtime.input_text = table.concat(vim.api.nvim_buf_get_lines(state.ui.input_buf, 0, -1, false), '\n')
end

function M.restore_active_runtime_input()
  local runtime = state.active_rpc_runtime()
  M.set_buffer_text(runtime.input_text or '')
end

function M.set_text(text)
  local normalized = M.normalize_text(text)
  local runtime = state.active_rpc_runtime()
  runtime.input_text = normalized
  buffers.ensure()
  state.ui.input_recall_index = nil
  state.ui.input_recall_text = nil
  M.set_buffer_text(normalized)
end

function M.get_text()
  buffers.ensure()
  return table.concat(vim.api.nvim_buf_get_lines(state.ui.input_buf, 0, -1, false), '\n')
end

function M.set_active_editor_interaction_text(text)
  buffers.ensure()
  local interaction = state.ui.interaction
  if not interaction or interaction.kind ~= 'editor' or not interaction.input_start then
    return false
  end
  local normalized = M.normalize_text(text)
  buffers.set_modifiable(state.ui.interaction_buf, true)
  vim.api.nvim_buf_set_lines(state.ui.interaction_buf, interaction.input_start - 1, -1, false, M.text_lines(normalized))
  if buffers.valid_win(state.ui.input_win) and vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.interaction_buf then
    vim.api.nvim_set_current_win(state.ui.input_win)
    vim.api.nvim_win_set_cursor(state.ui.input_win, { interaction.input_start, 0 })
  end
  return true
end

function M.set_editor_text(text)
  local normalized = M.normalize_text(text)
  local runtime = state.active_rpc_runtime()
  runtime.editor_text = normalized
  if M.set_active_editor_interaction_text(normalized) then
    return 'interaction'
  end
  return 'stored'
end

function M.clear()
  local runtime = state.active_rpc_runtime()
  runtime.input_text = ''
  buffers.ensure()
  state.ui.input_recall_index = nil
  state.ui.input_recall_text = nil
  M.set_buffer_text('')
end

function M.recall_user_message(delta)
  if state.ui.interaction then
    return false
  end

  local history = {}
  local ok_sessions, sessions = pcall(require, 'pi-dev.sessions')
  if ok_sessions and sessions.current_branch_user_messages then
    history = sessions.current_branch_user_messages()
  end
  local seen = {}
  for _, text in ipairs(history) do
    seen[text] = true
  end
  for _, text in ipairs(state.render.user_messages or {}) do
    if text ~= '' and not seen[text] then
      table.insert(history, text)
      seen[text] = true
    end
  end
  if #history == 0 then
    return false
  end

  local current = M.get_text()
  local active = state.ui.input_recall_index ~= nil and current == (state.ui.input_recall_text or '')
  if vim.trim(current) ~= '' and not active then
    return false
  end

  local empty_index = #history + 1
  local index = state.ui.input_recall_index
  if not active or not index then
    index = delta < 0 and #history or 1
  else
    local next_index = index + delta
    if next_index < 1 or next_index > empty_index then
      return false
    end
    index = next_index
  end

  local text = index == empty_index and '' or history[index]
  M.set_text(text)
  state.ui.input_recall_index = index
  state.ui.input_recall_text = text

  if buffers.valid_win(state.ui.input_win) and vim.api.nvim_win_get_buf(state.ui.input_win) == state.ui.input_buf then
    local lines = vim.api.nvim_buf_get_lines(state.ui.input_buf, 0, -1, false)
    local row = math.max(1, #lines)
    local col = #(lines[row] or '')
    pcall(vim.api.nvim_win_set_cursor, state.ui.input_win, { row, col })
  end

  return true
end

return M
