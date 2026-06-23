-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local state = require('pi-dev.state')

local M = {}

function M.reopen_runtime_interaction(runtime)
  if not runtime then
    return
  end
  local ui = require('pi-dev.ui')
  local request = runtime.pending_extension_ui_request
  if runtime.key == state.rpc.active_key and runtime.current_extension_interaction then
    ui.process_next_interaction()
  elseif request and runtime.key == state.rpc.active_key then
    runtime.pending_extension_ui_request = nil
    if state.ui.input_win and vim.api.nvim_win_is_valid(state.ui.input_win) then
      pcall(vim.api.nvim_set_current_win, state.ui.input_win)
    end
    require('pi-dev.extension_ui').handle_request(request)
  elseif runtime.key == state.rpc.active_key then
    ui.process_next_interaction()
  end
  vim.schedule(function()
    require('pi-dev.renderer').open_latest_auto_folds()
    ui.refresh_chrome()
  end)
end

function M.runtime_has_interaction(runtime)
  if not runtime or not runtime.key or not state.is_job_running(runtime) then
    return false
  end
  if runtime.waiting_input ~= true and runtime.status ~= 'waiting input' then
    return false
  end
  return runtime.pending_extension_ui_request ~= nil
    or runtime.current_extension_interaction ~= nil
    or (runtime.interaction_queue and #runtime.interaction_queue > 0)
end

return M
