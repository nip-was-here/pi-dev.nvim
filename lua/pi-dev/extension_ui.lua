-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local pi_permission_system = require('pi-dev.compat.pi_permission_system')
local pipeline = require('pi-dev.render_pipeline')
local renderer = require('pi-dev.renderer')
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local ui = require('pi-dev.ui')

local M = {}

local function respond(id, payload)
  payload = payload or {}
  payload.type = 'extension_ui_response'
  payload.id = id
  if rpc.finish_permission_wait then
    rpc.finish_permission_wait(id)
  end
  rpc.write(payload)
  rpc.set_active_waiting_input(false)
  state.statusline.waiting_input = false
  state.statusline.status = state.statusline.active and 'running' or 'idle'
  ui.refresh_chrome()
end

local function as_lines(value)
  if type(value) == 'table' then
    return value
  end
  if value == nil or value == vim.NIL then
    return nil
  end
  return { tostring(value) }
end

local function is_interactive_method(method)
  return method == 'confirm' or method == 'select' or method == 'input' or method == 'editor'
end

local function notify_level(notify_type)
  local key = tostring(notify_type or 'info'):upper()
  if key == 'WARNING' then
    key = 'WARN'
  end
  return vim.log.levels[key] or vim.log.levels.INFO
end

local function request_already_tracked(runtime, request)
  local request_id = request and request.id
  if not runtime or not request_id or request_id == '' then
    return false
  end
  if runtime.cleared_extension_ui_requests and runtime.cleared_extension_ui_requests[request_id] then
    return true
  end
  if runtime.pending_extension_ui_request and runtime.pending_extension_ui_request.id == request_id then
    return true
  end
  if ui.interaction_request_exists and ui.interaction_request_exists(runtime.key, request_id) then
    return true
  end
  return false
end

local function remember_pending_interaction_request(request)
  if not request or not is_interactive_method(request.method) then
    return
  end
  local runtime = request.__pi_runtime_key and state.ensure_rpc_runtime(request.__pi_runtime_key) or state.active_rpc_runtime()
  request.__pi_runtime_key = request.__pi_runtime_key or runtime.key
  if request_already_tracked(runtime, request) then
    return
  end
  runtime.pending_extension_ui_request = request
  runtime.waiting_input = state.is_job_running(runtime)
  runtime.status = runtime.waiting_input and 'waiting input' or (state.is_job_running(runtime) and 'idle' or 'not connected')
  state.sync_active_rpc_runtime(runtime)
end

local function idle_status(runtime)
  if runtime and runtime.active == true then
    return 'running'
  end
  return state.is_job_running(runtime) and 'idle' or 'not connected'
end

local function remember_cleared_request_id(runtime, request_id)
  if not runtime or not request_id or request_id == '' then
    return
  end
  runtime.cleared_extension_ui_requests = runtime.cleared_extension_ui_requests or {}
  runtime.cleared_extension_ui_requests[request_id] = true
end

local function remember_cleared_interactions(runtime)
  remember_cleared_request_id(runtime, runtime.pending_extension_ui_request and runtime.pending_extension_ui_request.id)
  local current = runtime.current_extension_interaction
  remember_cleared_request_id(runtime, current and current.opts and current.opts.request_id)
  for _, item in ipairs(runtime.interaction_queue or {}) do
    remember_cleared_request_id(runtime, item and item.opts and item.opts.request_id)
  end
  local visible = state.ui.interaction
  if visible and tostring(visible.runtime_key or state.rpc.active_key) == tostring(runtime.key) then
    remember_cleared_request_id(runtime, visible.request_id)
  end
end

function M.clear_runtime_interactions(runtime_key)
  local runtime = runtime_key and state.ensure_rpc_runtime(runtime_key) or state.active_rpc_runtime()
  if not runtime then
    return false
  end

  remember_cleared_interactions(runtime)
  if ui.close_visible_extension_interaction_for_runtime then
    ui.close_visible_extension_interaction_for_runtime(runtime.key)
  end
  runtime.pending_extension_ui_request = nil
  runtime.current_extension_interaction = nil
  runtime.interaction_queue = {}
  runtime.editor_text = ''
  runtime.waiting_input = false
  if runtime.status == 'waiting input' then
    runtime.status = idle_status(runtime)
  end
  if pi_permission_system.clear_pending_state then
    pi_permission_system.clear_pending_state()
  end
  state.sync_active_rpc_runtime(runtime)
  if runtime.key == state.rpc.active_key then
    state.statusline.waiting_input = false
    state.statusline.status = runtime.status or idle_status(runtime)
    state.statusline.active = runtime.active == true
    state.statusline.loading = runtime.loading == true
    state.statusline.error = runtime.error
  end
  ui.refresh_chrome()
  return true
end

function M.handle_request(request)
  if request and request.__pi_runtime_key and request.__pi_runtime_key ~= state.rpc.active_key then
    if not is_interactive_method(request.method) then
      return
    end
    local runtime = state.ensure_rpc_runtime(request.__pi_runtime_key)
    if request_already_tracked(runtime, request) then
      return
    end
    runtime.pending_extension_ui_request = request
    runtime.waiting_input = state.is_job_running(runtime)
    runtime.status = runtime.waiting_input and 'waiting input' or (state.is_job_running(runtime) and 'idle' or 'not connected')
    state.sync_active_rpc_runtime(runtime)
    ui.refresh_chrome()
    return
  end

  if request and is_interactive_method(request.method) and request_already_tracked(state.active_rpc_runtime(), request) then
    return
  end

  local method = request.method
  remember_pending_interaction_request(request)

  if method == 'notify' then
    local message = request.message or ''
    vim.notify(message, notify_level(request.notifyType))
    if pipeline.is_pi_update_notice(message) then
      renderer.append_system(message)
    end
    return
  end

  if method == 'setStatus' then
    ui.set_status(request.statusKey or 'extension', request.statusText)
    return
  end

  if method == 'setWidget' then
    ui.set_widget(request.widgetKey or 'extension', as_lines(request.widgetLines))
    return
  end

  if method == 'setTitle' then
    if request.title then
      vim.o.titlestring = request.title
      state.ui.output_title = 'Pi chat: ' .. tostring(request.title)
      require('pi-dev.ui').refresh_chrome()
    end
    return
  end

  if method == 'set_editor_text' then
    local target = ui.set_editor_text(request.text or '')
    if target == 'interaction' then
      ui.focus_input()
    end
    return
  end

  if method == 'confirm' then
    vim.schedule(function()
      ui.show_interaction({
        runtime_key = request.__pi_runtime_key,
        request_id = request.id,
        defer_if_busy = true,
        title = request.title or 'Pi permission',
        message = request.message or '',
        items = {
          { label = 'Yes', confirmed = true },
          { label = 'No', confirmed = false },
        },
        on_submit = function(item)
          respond(request.id, { confirmed = item and item.confirmed == true, cancelled = false })
        end,
        on_cancel = function()
          respond(request.id, { confirmed = false, cancelled = true })
        end,
      })
    end)
    return
  end

  if method == 'select' then
    if pi_permission_system.handle_request(request, respond) then
      return
    end

    vim.schedule(function()
      local items = {}
      for _, option in ipairs(request.options or {}) do
        table.insert(items, { label = tostring(option), value = option })
      end
      ui.show_interaction({
        runtime_key = request.__pi_runtime_key,
        request_id = request.id,
        defer_if_busy = true,
        title = request.title or 'Pi selection',
        items = items,
        on_submit = function(item)
          if item == nil then
            respond(request.id, { cancelled = true })
          else
            respond(request.id, { value = item.value })
          end
        end,
        on_cancel = function()
          respond(request.id, { cancelled = true })
        end,
      })
    end)
    return
  end

  if method == 'input' or method == 'editor' then
    if pi_permission_system.handle_request(request, respond) then
      return
    end

    vim.schedule(function()
      ui.show_text_interaction({
        runtime_key = request.__pi_runtime_key,
        request_id = request.id,
        kind = method,
        defer_if_busy = true,
        title = request.title or (method == 'editor' and 'Pi editor' or 'Pi input'),
        message = request.message or request.description or '',
        placeholder = request.placeholder,
        default = request.prefill or request.default or request.value or request.text or (method == 'editor' and (state.active_rpc_runtime().editor_text or '') or ''),
        hint = method == 'editor' and '<C-s> submit editor input, Esc cancel' or nil,
        submit_on_enter = method ~= 'editor',
        on_submit = function(value)
          respond(request.id, { value = value })
        end,
        on_cancel = function()
          respond(request.id, { cancelled = true })
        end,
      })
    end)
    return
  end

  vim.notify('pi-dev.nvim: unsupported extension UI method: ' .. tostring(method), vim.log.levels.WARN)
  if request.id then
    respond(request.id, { cancelled = true })
  end
end

return M
