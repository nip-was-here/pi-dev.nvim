-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {
  listeners = {},
}

function M.on(event_type, callback)
  M.listeners[event_type] = M.listeners[event_type] or {}
  table.insert(M.listeners[event_type], callback)
  return function()
    local listeners = M.listeners[event_type] or {}
    for index, listener in ipairs(listeners) do
      if listener == callback then
        table.remove(listeners, index)
        return true
      end
    end
    return false
  end
end

function M.emit(event_type, payload)
  local listeners = M.listeners[event_type] or {}
  for _, listener in ipairs(listeners) do
    local ok, err = pcall(listener, payload)
    if not ok then
      vim.schedule(function()
        vim.notify('pi-dev.nvim event handler failed: ' .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
end

return M
