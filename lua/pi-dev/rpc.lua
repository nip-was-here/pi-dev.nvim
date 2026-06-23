-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local config = require('pi-dev.config')
local events = require('pi-dev.events')
local format = require('pi-dev.format')
local state = require('pi-dev.state')
local tool_identity = require('pi-dev.tool_identity')

local M = {}

local function notify_error(message)
  vim.schedule(function()
    vim.notify(message, vim.log.levels.ERROR)
  end)
end

local function annotate(runtime, message)
  if type(message) ~= 'table' then
    return message
  end
  message.__pi_runtime_key = runtime and runtime.key or state.rpc.active_key
  message.__pi_active_runtime = message.__pi_runtime_key == state.rpc.active_key
  return message
end

local function emit(runtime, event_type, payload)
  local annotated = annotate(runtime, payload)
  events.emit(event_type, annotated)
  if event_type ~= '*' then
    events.emit('*', annotated)
  end
end

local function public_status(status)
  if tostring(status or ''):match('^tool%s+') then
    return 'running'
  end
  return status
end

local function has_pending_interaction(runtime)
  return runtime
    and (
      runtime.pending_extension_ui_request ~= nil
      or runtime.current_extension_interaction ~= nil
      or (runtime.interaction_queue and #runtime.interaction_queue > 0)
    )
end

local function is_interactive_extension_request(message)
  local method = message and message.method
  return method == 'confirm' or method == 'select' or method == 'input' or method == 'editor'
end

local function runtime_status(runtime)
  if runtime.error then
    return 'error'
  end
  if runtime.waiting_input or has_pending_interaction(runtime) then
    return 'waiting input'
  end
  if runtime.active then
    local status = public_status(runtime.status)
    if status and status ~= '' and status ~= 'idle' and status ~= 'not connected' and status ~= 'running' then
      return status
    end
    return 'running'
  end
  if runtime.loading and runtime.status == 'loading' then
    return 'loading'
  end
  if state.is_job_running(runtime) then
    local status = public_status(runtime.status)
    return status ~= 'not connected' and (status or 'idle') or 'idle'
  end
  return 'not connected'
end

function M.runtime_status(runtime)
  return runtime_status(runtime)
end

local function clear_idle_timer(runtime)
  if runtime and runtime.idle_timer then
    pcall(vim.fn.timer_stop, runtime.idle_timer)
    runtime.idle_timer = nil
  end
end

local function stop_runtime(runtime, opts)
  opts = opts or {}
  if not runtime then
    return
  end
  clear_idle_timer(runtime)
  local ok_ui, ui = pcall(require, 'pi-dev.ui')
  if ok_ui and ui.close_visible_extension_interaction_for_runtime then
    ui.close_visible_extension_interaction_for_runtime(runtime.key)
  end
  if state.is_job_running(runtime) then
    pcall(vim.fn.jobstop, runtime.job_id)
  end
  local pending = runtime.pending or {}
  state.reset_rpc_runtime(runtime, opts.remove == true)
  for _, request in pairs(pending) do
    if request.callback then
      vim.schedule(function()
        request.callback(annotate(runtime, { type = 'response', success = false, error = 'pi rpc process stopped' }))
      end)
    end
  end
end

local function has_local_draft(runtime)
  return runtime and ((runtime.input_text and runtime.input_text ~= '') or (runtime.editor_text and runtime.editor_text ~= ''))
end

local function idle_stop_eligible(runtime)
  return runtime
    and tostring(runtime.key or '') ~= tostring(state.rpc.active_key or 'default')
    and state.is_job_running(runtime)
    and runtime.active ~= true
    and runtime.waiting_input ~= true
    and not has_pending_interaction(runtime)
    and not has_local_draft(runtime)
    and not runtime.error
end

local function set_active_runtime(key)
  key = tostring(key or 'default')
  local previous_key = tostring(state.rpc.active_key or 'default')
  local previous_runtime = state.rpc.runtimes and state.rpc.runtimes[previous_key] or nil
  local ok_ui, ui = pcall(require, 'pi-dev.ui')
  if ok_ui and ui.save_active_runtime_input then
    ui.save_active_runtime_input()
  end
  if ok_ui and previous_key ~= key and ui.close_all_subagent_views then
    ui.close_all_subagent_views({ restore_title = false })
  end
  if ok_ui and state.ui.interaction and previous_key ~= key then
    ui.close_interaction({ process_queue = false, save_runtime_interaction = true })
  end
  local runtime = state.set_active_rpc_runtime(key)
  clear_idle_timer(runtime)
  if previous_runtime and previous_key ~= key and M.schedule_idle_stop then
    M.schedule_idle_stop(previous_runtime)
  end
  if ok_ui and ui.restore_active_runtime_input then
    ui.restore_active_runtime_input()
  end
  return runtime
end

function M.schedule_idle_stop(runtime)
  runtime = runtime or state.active_rpc_runtime()
  if not idle_stop_eligible(runtime) then
    return
  end
  clear_idle_timer(runtime)
  local timeout = tonumber(config.options.rpc and config.options.rpc.idle_timeout_ms) or 180000
  if timeout <= 0 then
    return
  end
  if state.rpc_runtime_count({ running_only = true }) <= 1 then
    return
  end
  runtime.idle_timer = vim.fn.timer_start(timeout, function()
    runtime.idle_timer = nil
    if not idle_stop_eligible(runtime) then
      return
    end
    if state.rpc_runtime_count({ running_only = true }) <= 1 then
      return
    end
    stop_runtime(runtime, { remove = true })
    vim.schedule(function()
      require('pi-dev.ui').refresh_chrome()
    end)
  end)
end

function M.schedule_background_idle_stops()
  if state.rpc_runtime_count({ running_only = true }) <= 1 then
    return
  end
  local active_key = tostring(state.rpc.active_key or 'default')
  for key, runtime in pairs(state.rpc.runtimes or {}) do
    if tostring(key) ~= active_key and idle_stop_eligible(runtime) then
      M.schedule_idle_stop(runtime)
    end
  end
end

local function tool_event_id(message)
  local id = message and (message.toolCallId or message.tool_call_id or message.callId or message.id or message.toolUseId or message.tool_use_id)
  return id ~= nil and id ~= '' and tostring(id) or nil
end

local function timestamp_milliseconds(value)
  if type(value) == 'number' then
    if value > 100000000000 then
      return math.floor(value + 0.5)
    end
    return math.floor(value * 1000 + 0.5)
  end
  if type(value) ~= 'string' then
    return nil
  end
  local seconds = format.timestamp_seconds(value)
  if not seconds then
    return nil
  end
  local fraction = value:match('[T%s]%d%d:%d%d:%d%d%.(%d+)')
  local fraction_ms = 0
  if fraction and fraction ~= '' then
    local trimmed = fraction:sub(1, 3)
    fraction_ms = tonumber(trimmed .. string.rep('0', 3 - #trimmed)) or 0
  end
  return seconds * 1000 + fraction_ms
end

local function message_timestamp_milliseconds(message)
  if type(message) ~= 'table' then
    return nil
  end
  return timestamp_milliseconds(message.timestamp or message.createdAt or message.created_at or message.time or message.date)
end

local function event_duration_milliseconds(message)
  for _, field in ipairs({ 'durationMs', 'duration_ms', 'elapsedMs', 'elapsed_ms', 'executionTimeMs', 'execution_time_ms' }) do
    local value = tonumber(message and message[field])
    if value and value >= 0 then
      return value
    end
  end
  for _, field in ipairs({ 'durationSeconds', 'duration_seconds', 'elapsedSeconds', 'elapsed_seconds' }) do
    local value = tonumber(message and message[field])
    if value and value >= 0 then
      return value * 1000
    end
  end
  return nil
end

local function local_milliseconds()
  return math.floor(vim.uv.hrtime() / 1000000)
end

local function permission_wait_id(message_or_id)
  if type(message_or_id) == 'table' then
    local id = message_or_id.id or message_or_id.requestId or message_or_id.request_id
    return id ~= nil and id ~= '' and tostring(id) or nil
  end
  return message_or_id ~= nil and message_or_id ~= '' and tostring(message_or_id) or nil
end

local function record_permission_wait_start(runtime, message)
  if not (runtime and is_interactive_extension_request(message)) then
    return
  end
  local id = permission_wait_id(message)
  if not id then
    return
  end
  runtime.permission_waits = runtime.permission_waits or {}
  local wait = runtime.permission_waits[id]
  if wait and wait.local_started_at_ms then
    return
  end
  runtime.permission_waits[id] = {
    id = id,
    started_at_ms = message_timestamp_milliseconds(message),
    local_started_at_ms = local_milliseconds(),
  }
end

local function finish_permission_wait(runtime, id)
  runtime = runtime or state.active_rpc_runtime()
  id = permission_wait_id(id)
  if not (runtime and id) then
    return false
  end
  runtime.permission_waits = runtime.permission_waits or {}
  local wait = runtime.permission_waits[id]
  if not wait then
    return false
  end
  wait.local_finished_at_ms = wait.local_finished_at_ms or local_milliseconds()
  return true
end

local function permission_wait_overlap_milliseconds(runtime, start_ms, end_ms, clock)
  start_ms = tonumber(start_ms)
  end_ms = tonumber(end_ms)
  if not runtime or not start_ms or not end_ms or end_ms <= start_ms then
    return 0
  end
  local total = 0
  for _, wait in pairs(runtime.permission_waits or {}) do
    local wait_start
    local wait_end
    if clock == 'event' then
      wait_start = tonumber(wait.started_at_ms)
      wait_end = tonumber(wait.finished_at_ms)
    else
      wait_start = tonumber(wait.local_started_at_ms)
      wait_end = tonumber(wait.local_finished_at_ms)
    end
    if wait_start then
      if clock == 'event' and not wait_end then
        wait_start = nil
      end
    end
    if wait_start then
      wait_end = wait_end or end_ms
      local overlap_start = math.max(start_ms, wait_start)
      local overlap_end = math.min(end_ms, wait_end)
      if overlap_end > overlap_start then
        total = total + (overlap_end - overlap_start)
      end
    end
  end
  return total
end

local function subtract_permission_wait(runtime, duration, timing, clock)
  duration = tonumber(duration)
  if not duration or not timing then
    return duration
  end
  local start_ms = clock == 'event' and timing.started_at_ms or timing.local_started_at_ms
  local end_ms = clock == 'event' and timing.finished_at_ms or timing.local_finished_at_ms
  local wait_ms = permission_wait_overlap_milliseconds(runtime, start_ms, end_ms, clock)
  if wait_ms <= 0 then
    return duration
  end
  return math.max(0, duration - wait_ms)
end

local function update_runtime_tool_timing(runtime, message)
  local id = tool_event_id(message)
  local name = message.toolName or message.tool_name or message.name
  local args = message.args
  local signature = tool_identity.signature(name, args)
  runtime.tool_timings = runtime.tool_timings or {}
  runtime.tool_timings_by_signature = runtime.tool_timings_by_signature or {}
  local timing = (id and runtime.tool_timings[id]) or runtime.tool_timings_by_signature[signature] or {}
  if id then
    runtime.tool_timings[id] = timing
  end
  runtime.tool_timings_by_signature[signature] = timing
  timing.name = name or timing.name
  timing.args = args or timing.args
  timing.signature = signature
  local now_ms = local_milliseconds()
  if message.type == 'tool_execution_start' then
    timing.started_at_ms = message_timestamp_milliseconds(message) or timing.started_at_ms
    timing.local_started_at_ms = timing.local_started_at_ms or now_ms
  elseif message.type == 'tool_execution_end' then
    timing.finished_at_ms = message_timestamp_milliseconds(message) or timing.finished_at_ms
    timing.local_finished_at_ms = timing.local_finished_at_ms or now_ms
    local duration = event_duration_milliseconds(message)
    local duration_clock = timing.local_started_at_ms and 'local' or nil
    if not duration and timing.started_at_ms and timing.finished_at_ms and timing.finished_at_ms >= timing.started_at_ms then
      duration = timing.finished_at_ms - timing.started_at_ms
      duration_clock = 'event'
    end
    if not duration and timing.local_started_at_ms then
      duration = now_ms - timing.local_started_at_ms
      duration_clock = 'local'
    elseif duration and timing.started_at_ms and timing.finished_at_ms then
      duration_clock = 'event'
    end
    if duration and duration >= 0 then
      timing.duration_ms = subtract_permission_wait(runtime, duration, timing, duration_clock)
    end
  end
end

local function update_runtime_from_event(runtime, message)
  if not runtime or type(message) ~= 'table' then
    return
  end
  if message.type == 'tool_execution_start' or message.type == 'tool_execution_end' then
    update_runtime_tool_timing(runtime, message)
  end
  if message.type == 'agent_start' then
    runtime.loading = false
    runtime.active = true
    runtime.waiting_input = false
    runtime.error = nil
    runtime.status = 'running'
    clear_idle_timer(runtime)
  elseif message.type == 'agent_end' then
    runtime.active = false
    if has_pending_interaction(runtime) then
      runtime.waiting_input = true
      runtime.status = 'waiting input'
    else
      runtime.waiting_input = false
      runtime.status = 'idle'
      M.schedule_idle_stop(runtime)
    end
  elseif message.type == 'message_start' then
    runtime.loading = false
    runtime.active = true
    runtime.waiting_input = false
    runtime.status = 'running'
    clear_idle_timer(runtime)
  elseif message.type == 'message_update' then
    runtime.active = true
    runtime.waiting_input = false
    runtime.status = 'running'
    clear_idle_timer(runtime)
  elseif message.type == 'tool_execution_start' or message.type == 'tool_execution_update' then
    runtime.active = true
    runtime.waiting_input = false
    runtime.status = 'running'
    clear_idle_timer(runtime)
  elseif message.type == 'tool_execution_end' then
    runtime.active = true
    runtime.waiting_input = false
    runtime.status = 'running'
    clear_idle_timer(runtime)
  elseif message.type == 'queue_update' then
    runtime.status = runtime.active and 'queue update' or runtime_status(runtime)
  elseif message.type == 'extension_ui_request' then
    record_permission_wait_start(runtime, message)
    runtime.waiting_input = is_interactive_extension_request(message) and (runtime.active == true or state.is_job_running(runtime)) or false
    runtime.status = runtime_status(runtime)
  elseif message.type == 'extension_error' or message.type == 'error' or message.type == 'provider_error' then
    runtime.loading = false
    runtime.error = message.error or message.message or 'Pi error'
    runtime.status = 'error'
  elseif message.type == 'compaction_start' or message.type == 'auto_retry_start' then
    runtime.active = true
    runtime.waiting_input = false
    runtime.status = message.type == 'compaction_start' and 'compacting' or 'retrying'
    if message.type == 'compaction_start' then
      runtime.cost = nil
      runtime.tokens = nil
      runtime.context_usage = nil
    end
    clear_idle_timer(runtime)
  elseif message.type == 'compaction_end' then
    if message.isStreaming ~= nil and message.isStreaming ~= vim.NIL then
      runtime.active = message.isStreaming == true
      runtime.waiting_input = runtime.active and runtime.waiting_input == true or has_pending_interaction(runtime)
    end
    runtime.status = runtime.active and 'running' or runtime_status(runtime)
  elseif message.type == 'auto_retry_end' then
    runtime.status = runtime_status(runtime)
  end
  state.sync_active_rpc_runtime(runtime)
end

local function handle_response(runtime, message)
  local id = message.id
  local pending = id and runtime.pending[id]
  if not pending then
    emit(runtime, 'response', message)
    return
  end

  runtime.pending[id] = nil
  if message.success and type(message.data) == 'table' then
    if message.data.sessionFile then
      runtime.session_file = message.data.sessionFile
    end
    if message.data.isStreaming == false and runtime.active then
      runtime.active = false
      if has_pending_interaction(runtime) then
        runtime.waiting_input = true
        runtime.status = 'waiting input'
      else
        runtime.waiting_input = false
        runtime.status = 'idle'
        M.schedule_idle_stop(runtime)
      end
    end
  end
  state.sync_active_rpc_runtime(runtime)
  emit(runtime, 'response', message)
  if pending.callback then
    vim.schedule(function()
      pending.callback(annotate(runtime, message))
    end)
  end
end

local function handle_mcp_auth_stdout_line(runtime, line)
  local server, inline_url = line:match('^MCP Auth:%s+Open this URL to authenticate%s+([^:]+):%s*(https?://%S+)%s*$')
  if server and inline_url then
    emit(runtime, 'mcp_auth_url', { type = 'mcp_auth_url', server = vim.trim(server), url = inline_url })
    return true
  end

  server = line:match('^MCP Auth:%s+Open this URL to authenticate%s+([^:]+):%s*$')
  if server then
    runtime.pending_mcp_auth_server = vim.trim(server)
    state.sync_active_rpc_runtime(runtime)
    return true
  end

  if runtime.pending_mcp_auth_server and line:match('^https?://') then
    emit(runtime, 'mcp_auth_url', { type = 'mcp_auth_url', server = runtime.pending_mcp_auth_server, url = vim.trim(line) })
    runtime.pending_mcp_auth_server = nil
    state.sync_active_rpc_runtime(runtime)
    return true
  end

  return false
end

local function handle_line(runtime, line)
  if line == '' then
    return
  end

  if handle_mcp_auth_stdout_line(runtime, line) then
    return
  end

  local ok, decoded = pcall(vim.json.decode, line)
  if not ok then
    emit(runtime, 'protocol_error', { line = line, error = decoded })
    return
  end

  if decoded.type == 'response' then
    handle_response(runtime, decoded)
    return
  end

  update_runtime_from_event(runtime, decoded)
  emit(runtime, decoded.type or 'event', decoded)
end

function M._handle_chunk(chunk, runtime)
  runtime = runtime or state.active_rpc_runtime()
  if not chunk or chunk == '' then
    return
  end

  runtime.buffer = (runtime.buffer or '') .. chunk
  state.sync_active_rpc_runtime(runtime)

  while true do
    local newline = runtime.buffer:find('\n', 1, true)
    if not newline then
      break
    end

    local line = runtime.buffer:sub(1, newline - 1)
    if line:sub(-1) == '\r' then
      line = line:sub(1, -2)
    end
    runtime.buffer = runtime.buffer:sub(newline + 1)
    state.sync_active_rpc_runtime(runtime)
    handle_line(runtime, line)
  end
end

local function on_stdout(runtime, _, data)
  if not data or #data == 0 then
    return
  end
  M._handle_chunk(table.concat(data, '\n'), runtime)
end

local function on_stderr(runtime, _, data)
  if not data or #data == 0 then
    return
  end
  local text = table.concat(data, '\n')
  if text ~= '' then
    table.insert(runtime.stderr, text)
    state.sync_active_rpc_runtime(runtime)
    emit(runtime, 'stderr', { text = text })
  end
end

local function pool_limit()
  return math.max(1, math.min(8, tonumber(config.options.rpc and config.options.rpc.pool_size) or 8))
end

local function pool_exhausted_message()
  return string.format('Pi RPC pool exhausted (%d/%d); stop an idle branch RPC before switching to another branch.', state.rpc_runtime_count({ running_only = true }), pool_limit())
end

function M.can_start_runtime(key)
  state.recheck_rpc_runtimes()
  local runtime = state.rpc.runtimes[tostring(key or state.rpc.active_key or 'default')]
  if runtime and state.is_job_running(runtime) then
    return true
  end
  return state.rpc_runtime_count({ running_only = true }) < pool_limit()
end

function M.notify_pool_exhausted(opts)
  opts = opts or {}
  local message = pool_exhausted_message()
  notify_error('pi-dev.nvim: ' .. message)
  if opts.append_to_output ~= false then
    local ok_renderer, renderer = pcall(require, 'pi-dev.renderer')
    if ok_renderer and renderer.append_system then
      renderer.append_system(message)
    end
  end
  return message
end

function M.start(key, opts)
  opts = opts or {}
  state.recheck_rpc_runtimes()
  local runtime = state.ensure_rpc_runtime(key or state.rpc.active_key)
  if opts.activate ~= false then
    runtime = set_active_runtime(runtime.key)
  end
  if state.is_job_running(runtime) then
    M.schedule_background_idle_stops()
    return runtime.job_id
  end

  if not M.can_start_runtime(runtime.key) then
    M.notify_pool_exhausted({ append_to_output = opts.append_pool_error_to_output ~= false and runtime.key == state.rpc.active_key })
    return nil
  end

  local conf = config.options
  local cmd = config.command()
  local cwd = conf.cwd or state.session.runtime_cwd or state.session.current_cwd
  if not cwd or cwd == '' then
    local ok_getcwd, current_cwd = pcall(vim.fn.getcwd)
    cwd = ok_getcwd and current_cwd or vim.uv.cwd()
  end
  local env = vim.deepcopy(conf.env or {})
  local ok_mcp, mcp = pcall(require, 'pi-dev.compat.mcp_adapter')
  if ok_mcp and mcp.rpc_env then
    env = vim.tbl_extend('force', env, mcp.rpc_env() or {})
  end

  runtime.buffer = ''
  runtime.stderr = {}
  runtime.active = false
  runtime.waiting_input = false
  runtime.pending_extension_ui_request = nil
  runtime.error = nil
  state.set_runtime_loading(runtime, true, { lock_input = false })

  local job_id = vim.fn.jobstart(cmd, {
    cwd = cwd,
    env = next(env) and env or nil,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(job, data)
      on_stdout(runtime, job, data)
    end,
    on_stderr = function(job, data)
      on_stderr(runtime, job, data)
    end,
    on_exit = function(_, code)
      local pending = runtime.pending
      state.reset_rpc_runtime(runtime)
      emit(runtime, 'exit', { code = code })
      for _, request in pairs(pending) do
        if request.callback then
          vim.schedule(function()
            request.callback(annotate(runtime, { type = 'response', success = false, error = 'pi rpc process exited' }))
          end)
        end
      end
      if conf.rpc.restart_on_exit then
        vim.schedule(function()
          M.start(runtime.key, { activate = runtime.key == state.rpc.active_key })
        end)
      end
    end,
  })

  if not job_id or job_id <= 0 then
    state.set_runtime_loading(runtime, false)
    notify_error('pi-dev.nvim: failed to start pi RPC process')
    return nil
  end

  runtime.job_id = job_id
  runtime.status = runtime.loading and 'loading' or 'idle'
  state.sync_active_rpc_runtime(runtime)
  emit(runtime, 'start', { job_id = job_id })
  M.schedule_background_idle_stops()
  return job_id
end

function M.stop(key, opts)
  local runtime = key and state.ensure_rpc_runtime(key) or state.active_rpc_runtime()
  stop_runtime(runtime, opts)
end

function M.stop_current()
  local runtime = state.active_rpc_runtime()
  local key = runtime.key
  stop_runtime(runtime, { remove = true })
  state.set_active_rpc_runtime('default')
  emit(runtime, 'exit', { code = 0, stopped = true, runtimeKey = key })
  return true
end

function M.stop_all()
  for _, runtime in pairs(vim.deepcopy(state.rpc.runtimes)) do
    local live = state.rpc.runtimes[runtime.key]
    if live then
      stop_runtime(live, { remove = true })
    end
  end
  state.clear_ui_statuses()
  state.set_active_rpc_runtime('default')
end

function M.write(message, opts)
  opts = opts or {}
  local runtime = opts.runtime or state.active_rpc_runtime()
  if not state.is_job_running(runtime) then
    if not M.start(runtime.key, { activate = runtime.key == state.rpc.active_key }) then
      return false
    end
    runtime = state.ensure_rpc_runtime(runtime.key)
  end

  local ok, encoded = pcall(vim.json.encode, message)
  if not ok then
    notify_error('pi-dev.nvim: failed to encode RPC message: ' .. tostring(encoded))
    return false
  end

  vim.fn.chansend(runtime.job_id, encoded .. '\n')
  return true
end

local function request_starts_work(message)
  local kind = type(message) == 'table' and message.type or nil
  return kind == 'prompt'
    or kind == 'steer'
    or kind == 'follow_up'
    or kind == 'fork'
    or kind == 'new_session'
    or kind == 'set_model'
    or kind == 'abort'
end

function M.request(message, callback, opts)
  opts = opts or {}
  local runtime = opts.runtime or state.active_rpc_runtime()
  message = vim.deepcopy(message)
  if request_starts_work(message) then
    clear_idle_timer(runtime)
  end
  message.id = message.id or state.next_request_id(runtime)
  if callback then
    runtime.pending[message.id] = { callback = callback }
    state.sync_active_rpc_runtime(runtime)
  end
  if not M.write(message, { runtime = runtime }) then
    runtime.pending[message.id] = nil
    state.sync_active_rpc_runtime(runtime)
    return nil
  end
  return message.id
end

function M.use_runtime(key, opts)
  opts = opts or {}
  key = tostring(key or 'default')
  local runtime = set_active_runtime(key)
  runtime.label = opts.label or runtime.label
  runtime.session_file = opts.session_file or runtime.session_file
  runtime.branch_root = opts.branch_root or runtime.branch_root
  runtime.branch_entry_id = opts.branch_entry_id or runtime.branch_entry_id
  M.start(runtime.key)
  if opts.defer_pending_ui then
    vim.schedule(function()
      require('pi-dev.ui').refresh_chrome()
    end)
    return runtime
  end
  vim.schedule(function()
    local request = runtime.pending_extension_ui_request
    local ui = require('pi-dev.ui')
    if runtime.key == state.rpc.active_key and runtime.current_extension_interaction then
      ui.process_next_interaction()
    elseif request and runtime.key == state.rpc.active_key then
      runtime.pending_extension_ui_request = nil
      require('pi-dev.extension_ui').handle_request(request)
    elseif runtime.key == state.rpc.active_key then
      ui.process_next_interaction()
    end
    ui.refresh_chrome()
  end)
  return runtime
end

function M.branch_key(root_file, entry_id)
  if root_file and root_file ~= '' and entry_id and entry_id ~= '' then
    return tostring(root_file) .. '#' .. tostring(entry_id)
  end
  return tostring(root_file or entry_id or 'default')
end

function M.finish_permission_wait(id, runtime)
  return finish_permission_wait(runtime or state.active_rpc_runtime(), id)
end

function M.set_active_waiting_input(waiting)
  local runtime = state.active_rpc_runtime()
  runtime.waiting_input = waiting == true and state.is_job_running(runtime)
  if waiting ~= true then
    runtime.pending_extension_ui_request = nil
  end
  runtime.status = runtime_status(runtime)
  state.sync_active_rpc_runtime(runtime)
end

return M
