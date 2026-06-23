-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')

local M = {}

function M.response_runtime(response)
  local key = response and response.__pi_runtime_key
  return key and state.ensure_rpc_runtime(key) or state.active_rpc_runtime()
end

function M.response_is_active(response)
  return not (response and response.__pi_runtime_key) or response.__pi_runtime_key == state.rpc.active_key
end

function M.badge(runtime)
  if not runtime then
    return nil
  end
  local status = rpc.runtime_status(runtime)
  if status == 'not connected' then
    return nil
  end
  if statusline.short_status_label then
    status = statusline.short_status_label(status)
  end
  return '[' .. status .. ']'
end

function M.refresh_context()
  rpc.request({ type = 'get_state' }, function(response)
    if response and response.success and response.data then
      local runtime = M.response_runtime(response)
      if response.data.sessionFile then
        runtime.session_file = response.data.sessionFile
        state.sync_active_rpc_runtime(runtime)
        if M.response_is_active(response) then
          state.session.current_file = response.data.sessionFile
        end
      end
      statusline.update_from_state(response.data, { runtime = runtime })
      if M.response_is_active(response) then
        require('pi-dev.ui').refresh_chrome()
      end
    end
  end)
  rpc.request({ type = 'get_session_stats' }, function(response)
    if response and response.success and response.data then
      statusline.update_from_stats(response.data, { runtime = M.response_runtime(response) })
      if M.response_is_active(response) then
        require('pi-dev.ui').refresh_chrome()
      end
    end
  end)
end

return M
