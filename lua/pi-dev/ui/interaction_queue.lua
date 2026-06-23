-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local state = require('pi-dev.state')

local M = {}

function M.runtime_for(opts)
  opts = opts or {}
  return state.ensure_rpc_runtime(opts.runtime_key or state.rpc.active_key)
end

function M.for_runtime(runtime)
  runtime = runtime or state.active_rpc_runtime()
  runtime.interaction_queue = runtime.interaction_queue or {}
  return runtime.interaction_queue
end

function M.request_exists(runtime, request_id)
  if not request_id or request_id == '' then
    return false
  end
  runtime = runtime or state.active_rpc_runtime()
  local key = runtime and runtime.key or state.rpc.active_key
  local visible = state.ui.interaction
  if visible and visible.request_id == request_id and tostring(visible.runtime_key or state.rpc.active_key) == tostring(key) then
    return true
  end
  local current = runtime and runtime.current_extension_interaction
  if current and current.opts and current.opts.request_id == request_id then
    return true
  end
  for _, item in ipairs(M.for_runtime(runtime)) do
    if item.opts and item.opts.request_id == request_id then
      return true
    end
  end
  return false
end

function M.enqueue(kind, opts)
  local runtime = M.runtime_for(opts)
  if opts and M.request_exists(runtime, opts.request_id) then
    return false
  end
  table.insert(M.for_runtime(runtime), { kind = kind, opts = opts })
  if opts and opts.request_id and runtime.pending_extension_ui_request and runtime.pending_extension_ui_request.id == opts.request_id then
    runtime.pending_extension_ui_request = nil
  end
  return false
end

function M.priority(kind)
  if kind == 'waiting' then
    return 30
  end
  if kind == 'tree' then
    return 20
  end
  return 10
end

function M.visible_priority()
  local interaction = state.ui.interaction
  return interaction and M.priority(interaction.kind) or 0
end

return M
