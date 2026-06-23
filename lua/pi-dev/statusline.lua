-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local format = require('pi-dev.format')
local state = require('pi-dev.state')

local M = {}

local function compact_model(model)
  if not model then
    return nil
  end
  if type(model) == 'string' then
    return model
  end
  if type(model) == 'table' then
    local id = model.id or model.modelId or model.name
    if model.provider and id then
      return string.format('%s/%s', model.provider, id)
    end
    return id
  end
  return tostring(model)
end

local function is_nil(value)
  return value == nil or value == vim.NIL
end

local function safe_tonumber(value)
  if is_nil(value) then
    return nil
  end
  local ok, number = pcall(tonumber, value)
  if ok then
    return number
  end
  return nil
end

local function round_decimal_places(number, places)
  local factor = 10 ^ places
  if number >= 0 then
    return math.floor(number * factor + 0.5) / factor
  end
  return math.ceil(number * factor - 0.5) / factor
end

local function format_cost(cost)
  if is_nil(cost) then
    return '$?'
  end
  if type(cost) == 'table' then
    cost = cost.total or cost.cost or cost.value
  end
  local number = safe_tonumber(cost)
  if not number then
    return tostring(cost)
  end
  if number == 0 then
    return '$0'
  end
  if number < 0.01 then
    return string.format('$%.4f', round_decimal_places(number, 4))
  end
  return string.format('$%.2f', round_decimal_places(number, 2))
end

local function format_tokens(tokens)
  local number = safe_tonumber(tokens)
  if not number then
    return '? tok'
  end
  if number >= 1000000 then
    return string.format('%.1fM tok', number / 1000000)
  end
  if number >= 1000 then
    return string.format('%.1fk tok', number / 1000)
  end
  return string.format('%d tok', number)
end

local function format_context(context)
  if type(context) ~= 'table' then
    return 'ctx ?'
  end
  if not is_nil(context.percent) then
    local percent = safe_tonumber(context.percent)
    if percent then
      return string.format('ctx %.0f%%', percent)
    end
  end
  if not is_nil(context.tokens) and not is_nil(context.contextWindow) then
    return string.format('ctx %s/%s', format_tokens(context.tokens) or context.tokens, format_tokens(context.contextWindow) or context.contextWindow)
  end
  return 'ctx ?'
end

local function is_generic_status(status)
  return status == nil or status == '' or status == 'running' or status == 'idle' or status == 'not connected'
end

local function has_pending_interaction(runtime)
  runtime = runtime or state.active_rpc_runtime()
  return runtime
    and (
      runtime.pending_extension_ui_request ~= nil
      or runtime.current_extension_interaction ~= nil
      or (runtime.interaction_queue and #runtime.interaction_queue > 0)
    )
end

local function is_interactive_extension_request(event)
  local method = event and event.method
  return method == 'confirm' or method == 'select' or method == 'input' or method == 'editor'
end

local function baseline_status()
  if state.statusline.waiting_input or has_pending_interaction() then
    return 'waiting input'
  end
  if state.statusline.active then
    return 'running'
  end
  if state.statusline.loading then
    return 'loading'
  end
  if not state.is_job_running() then
    return 'not connected'
  end
  return 'idle'
end

local function statusline_display_status(status)
  if status == 'user message' or status == 'assistant' or status == 'thinking' or status == 'answering' or status == 'tool call' then
    return 'running'
  end
  if tostring(status or ''):match('^tool%s+') then
    return 'running'
  end
  return status
end

local short_status_labels = {
  ['not connected'] = 'off',
  ['running'] = 'run',
  ['idle'] = 'idle',
  ['waiting input'] = 'wait',
  ['loading'] = 'load',
  ['compacting'] = 'compact',
  ['retrying'] = 'retry',
  ['queue update'] = 'queue',
  ['error'] = 'err',
}

local function short_status_label(status)
  status = statusline_display_status(status)
  return short_status_labels[status] or status
end

function M.short_status_label(status)
  return short_status_label(status)
end

local function runtime_status()
  if state.statusline.waiting_input or has_pending_interaction() then
    return 'waiting input'
  end
  if state.statusline.active then
    local status = statusline_display_status(state.statusline.status)
    if not is_generic_status(status) and status ~= 'waiting input' then
      return status
    end
    return 'running'
  end
  if state.statusline.loading then
    return 'loading'
  end
  if not state.is_job_running() then
    return 'not connected'
  end
  return 'idle'
end

local function append_error_notice(error_message)
  local message = error_message and tostring(error_message) or ''
  if message == '' then
    return
  end
  local ok, renderer = pcall(require, 'pi-dev.renderer')
  if ok and renderer.append_system then
    renderer.append_system('Error: ' .. message)
  end
end

local function sync_runtime_status(runtime)
  if runtime then
    state.sync_active_rpc_runtime(runtime)
  end
end

function M.set_status(status)
  local runtime = state.active_rpc_runtime()
  runtime.status = status or runtime_status()
  runtime.error = nil
  sync_runtime_status(runtime)
end

function M.set_error(error_message, opts)
  opts = opts or {}
  local runtime = state.active_rpc_runtime()
  runtime.active = false
  runtime.waiting_input = false
  runtime.loading = false
  runtime.status = 'error'
  runtime.error = error_message and tostring(error_message) or nil
  sync_runtime_status(runtime)
  if opts.notice ~= false then
    append_error_notice(state.statusline.error)
  end
end

function M.clear_error()
  local runtime = state.active_rpc_runtime()
  if runtime.error then
    runtime.error = nil
  end
  if runtime.status == 'error' then
    runtime.status = baseline_status()
  end
  sync_runtime_status(runtime)
end

local function target_runtime(opts)
  opts = opts or {}
  if opts.runtime then
    return opts.runtime
  end
  if opts.runtime_key then
    return state.ensure_rpc_runtime(opts.runtime_key)
  end
  return state.active_rpc_runtime()
end

local function clear_stats(target)
  if not target then
    return
  end
  target.cost = nil
  target.tokens = nil
  target.context_usage = nil
end

function M.update_from_state(data, opts)
  if type(data) ~= 'table' then
    return
  end
  opts = opts or {}
  local runtime = target_runtime(opts)
  if not opts.runtime and not opts.runtime_key and not state.is_job_running(runtime) and state.statusline.active then
    runtime.active = state.statusline.active == true
    runtime.waiting_input = state.statusline.waiting_input == true
    runtime.status = state.statusline.status
  end
  local model = compact_model(data.model)
  local thinking_level = data.thinkingLevel or data.thinking_level or data.reasoningLevel or data.reasoning_level
  if model then
    runtime.model = model
  end
  if thinking_level ~= nil and thinking_level ~= vim.NIL then
    runtime.thinking_level = thinking_level
  end
  if runtime.error and data.isStreaming ~= true and data.isCompacting ~= true then
    runtime.active = false
    runtime.waiting_input = false
    runtime.status = 'error'
    sync_runtime_status(runtime)
    return
  end
  if data.isStreaming == true then
    runtime.loading = false
    runtime.active = true
    runtime.waiting_input = has_pending_interaction(runtime)
  elseif data.isStreaming == false then
    runtime.loading = false
    runtime.active = false
    runtime.waiting_input = has_pending_interaction(runtime)
  end
  if data.isCompacting == true then
    if runtime.status ~= 'compacting' then
      runtime.compaction_previous_active = runtime.active == true
      runtime.compaction_previous_waiting_input = runtime.waiting_input == true
    end
    runtime.active = true
    runtime.waiting_input = false
    runtime.status = 'compacting'
    clear_stats(runtime)
  elseif data.isCompacting == false and runtime.status == 'compacting' then
    local streaming_known = not is_nil(data.isStreaming)
    local active = streaming_known and data.isStreaming == true or runtime.compaction_previous_active == true
    runtime.active = active
    runtime.waiting_input = active and runtime.compaction_previous_waiting_input == true or has_pending_interaction(runtime)
    runtime.compaction_previous_active = nil
    runtime.compaction_previous_waiting_input = nil
    runtime.status = runtime.waiting_input and 'waiting input' or (runtime.active and 'running' or (state.is_job_running(runtime) and 'idle' or 'not connected'))
  elseif data.isStreaming ~= nil or data.model ~= nil then
    runtime.status = runtime.waiting_input and 'waiting input' or (runtime.active and 'running' or (state.is_job_running(runtime) and 'idle' or 'not connected'))
  end
  sync_runtime_status(runtime)
end

function M.update_from_stats(data, opts)
  if type(data) ~= 'table' then
    return
  end
  local runtime = target_runtime(opts)
  if not is_nil(data.cost) then
    runtime.cost = data.cost
  end
  if not is_nil(data.contextUsage) then
    runtime.context_usage = data.contextUsage
  end
  if data.tokens == vim.NIL then
    runtime.tokens = nil
  elseif type(data.tokens) == 'table' then
    local total = data.tokens.total
    if is_nil(total) then
      total = data.tokens.totalTokens
    end
    if is_nil(total) then
      local input = safe_tonumber(data.tokens.inputTokens or data.tokens.input)
      local output = safe_tonumber(data.tokens.outputTokens or data.tokens.output)
      if input or output then
        total = (input or 0) + (output or 0)
      end
    end
    runtime.tokens = is_nil(total) and nil or total
  elseif not is_nil(data.tokens) then
    runtime.tokens = data.tokens
  end
  sync_runtime_status(runtime)
end

function M.handle_event(event)
  if not event or not event.type then
    return
  end
  if event.__pi_runtime_key and event.__pi_runtime_key ~= state.rpc.active_key then
    return
  end

  if event.type == 'start' then
    state.statusline.error = nil
    state.statusline.status = state.statusline.loading and 'loading' or 'idle'
  elseif event.type == 'exit' then
    state.statusline.active = false
    state.statusline.waiting_input = false
    state.statusline.loading = false
    state.statusline.status = 'not connected'
  elseif event.type == 'agent_start' then
    state.statusline.error = nil
    state.statusline.loading = false
    state.statusline.active = true
    state.statusline.waiting_input = false
    state.statusline.status = 'running'
  elseif event.type == 'agent_end' then
    state.statusline.active = false
    state.statusline.waiting_input = has_pending_interaction()
    state.statusline.compaction_previous_active = nil
    state.statusline.compaction_previous_waiting_input = nil
    state.statusline.status = state.statusline.waiting_input and 'waiting input' or 'idle'
  elseif event.type == 'compaction_start' then
    if state.statusline.status ~= 'compacting' then
      state.statusline.compaction_previous_active = state.statusline.active == true
      state.statusline.compaction_previous_waiting_input = state.statusline.waiting_input == true
    end
    state.statusline.active = true
    state.statusline.status = 'compacting'
    clear_stats(state.statusline)
    clear_stats(state.active_rpc_runtime())
  elseif event.type == 'compaction_end' then
    local streaming_known = not is_nil(event.isStreaming)
    local active = streaming_known and event.isStreaming == true or state.statusline.compaction_previous_active == true
    state.statusline.active = active
    state.statusline.waiting_input = active and state.statusline.compaction_previous_waiting_input == true or has_pending_interaction()
    state.statusline.compaction_previous_active = nil
    state.statusline.compaction_previous_waiting_input = nil
    state.statusline.status = baseline_status()
  elseif event.type == 'auto_retry_start' then
    state.statusline.active = true
    state.statusline.waiting_input = false
    state.statusline.status = 'retrying'
  elseif event.type == 'auto_retry_end' then
    state.statusline.status = baseline_status()
  elseif event.type == 'message_start' then
    local role = event.message and event.message.role
    if role == 'user' then
      M.clear_error()
    end
    if role == 'user' or role == 'assistant' then
      state.statusline.loading = false
      state.statusline.active = true
      state.statusline.waiting_input = false
      state.statusline.status = 'running'
    end
  elseif event.type == 'message_update' then
    state.statusline.active = true
    state.statusline.waiting_input = false
    state.statusline.status = 'running'
  elseif event.type == 'tool_execution_start' or event.type == 'tool_execution_update' then
    state.statusline.active = true
    state.statusline.waiting_input = false
    state.statusline.status = 'running'
  elseif event.type == 'tool_execution_end' then
    state.statusline.active = true
    state.statusline.waiting_input = false
    state.statusline.status = 'running'
  elseif event.type == 'queue_update' then
    state.statusline.status = state.statusline.active and 'queue update' or runtime_status()
  elseif event.type == 'extension_ui_request' then
    state.statusline.waiting_input = is_interactive_extension_request(event) and (state.statusline.active == true or state.is_job_running()) or false
    state.statusline.status = runtime_status()
  elseif event.type == 'extension_error' then
    M.set_error(event.error or 'extension error', { notice = false })
  end

  local runtime = state.active_rpc_runtime()
  runtime.status = state.statusline.status
  runtime.active = state.statusline.active == true
  runtime.waiting_input = state.statusline.waiting_input == true
  runtime.loading = state.statusline.loading == true
  runtime.error = state.statusline.error
  sync_runtime_status(runtime)
end

local function error_title(error_message)
  return tostring(error_message or '')
    :gsub('\r\n', '\n')
    :gsub('\r', '\n')
    :gsub('\n.*$', '')
    :gsub('[%z\1-\8\11\12\14-\31\127]', '')
end

local function runtime_badge_status(runtime)
  if not runtime then
    return 'not connected'
  end
  if runtime.error then
    return 'error'
  end
  if runtime.waiting_input then
    return 'waiting input'
  end
  if runtime.active then
    local status = statusline_display_status(runtime.status)
    if not is_generic_status(status) and status ~= 'waiting input' then
      return status
    end
    return 'running'
  end
  if runtime.loading and runtime.status == 'loading' then
    return 'loading'
  end
  if state.is_job_running(runtime) then
    local status = statusline_display_status(runtime.status)
    return status ~= 'not connected' and (status or 'idle') or 'idle'
  end
  return 'not connected'
end

local service_statuses = {
  ['loading'] = true,
  ['compacting'] = true,
  ['retrying'] = true,
  ['queue update'] = true,
}

local function is_service_status(status)
  return service_statuses[status] == true
end

local function add_detail_count(detail_counts, detail_order, status)
  if not detail_counts[status] then
    table.insert(detail_order, status)
    detail_counts[status] = 0
  end
  detail_counts[status] = detail_counts[status] + 1
end

local function aggregate_status_label(info)
  state.recheck_rpc_runtimes()
  local connected = 0
  local running = 0
  local idle = 0
  local waiting = 0
  local errors = 0
  local detail_counts = {}
  local detail_order = {}
  local sole_connected_status = nil
  for _, runtime in pairs(state.rpc.runtimes or {}) do
    local status = runtime_badge_status(runtime)
    if status ~= 'not connected' then
      connected = connected + 1
      sole_connected_status = status
      if runtime.error or status == 'error' then
        errors = errors + 1
      elseif runtime.waiting_input or status == 'waiting input' then
        waiting = waiting + 1
      elseif status == 'running' then
        running = running + 1
      elseif is_service_status(status) then
        add_detail_count(detail_counts, detail_order, status)
      elseif state.is_job_running(runtime) or status == 'idle' then
        idle = idle + 1
      end
    end
  end
  if connected <= 1 then
    if info.error then
      return short_status_label('error')
    end
    local active_status = runtime_badge_status(state.active_rpc_runtime())
    if active_status ~= 'not connected' then
      return short_status_label(active_status)
    end
    if sole_connected_status then
      return short_status_label(sole_connected_status)
    end
    return short_status_label(info.status or runtime_status())
  end
  local parts = {}
  local running_total = connected
  if running > 0 then
    table.insert(parts, string.format('run %d/%d', running, math.max(1, running_total)))
  elseif idle > 0 then
    table.insert(parts, string.format('idle %d', idle))
  end
  if waiting > 0 then
    table.insert(parts, string.format('wait %d', waiting))
  end
  if errors > 0 then
    table.insert(parts, string.format('err %d', errors))
  end
  for _, status in ipairs(detail_order) do
    table.insert(parts, string.format('%s %d', short_status_label(status), detail_counts[status]))
  end
  if #parts == 0 then
    return short_status_label(runtime_badge_status(state.active_rpc_runtime()))
  end
  return table.concat(parts, ', ')
end

local function render_left(prefix, info, max_width)
  local base = ' ' .. (prefix or 'Pi') .. ' ' .. aggregate_status_label(info)
  if info.error then
    local title = error_title(info.error)
    if title ~= '' then
      base = base .. ' ' .. title
    end
  end
  return format.truncate_display(base .. ' ', math.max(1, max_width))
end

local function render_parts(prefix, width)
  local info = state.statusline
  local right_parts = {}

  local cost = format_cost(info.cost)
  local tokens = format_tokens(info.tokens)
  local context = format_context(info.context_usage)

  if cost then
    table.insert(right_parts, cost)
  end
  if tokens then
    table.insert(right_parts, tokens)
  end
  if context then
    table.insert(right_parts, context)
  end
  if info.model then
    table.insert(right_parts, info.model)
  end

  width = width or vim.api.nvim_win_get_width(0)
  local right = table.concat(right_parts, ' | ')
  local right_width = vim.fn.strdisplaywidth(right)
  local left_width = width
  if right ~= '' and right_width + 12 < width then
    left_width = width - right_width - 1
  else
    right = ''
    right_width = 0
  end

  local left_full = render_left(prefix, info, 10000)
  if right:find('?', 1, true) and vim.fn.strdisplaywidth(left_full) > left_width then
    right = ''
    right_width = 0
    left_width = width
  end

  local left = render_left(prefix, info, left_width)
  if right == '' then
    return left
  end

  return format.prefixed_line('', left, right, width)
end

function M.render()
  return render_parts('Pi status:')
end

function M.render_for_width(width)
  return render_parts('Pi status:', width)
end

return M
