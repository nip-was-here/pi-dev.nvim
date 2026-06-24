-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {
  rpc = {
    active_key = 'default',
    runtimes = {},
    job_id = nil,
    stderr = {},
    buffer = '',
    next_id = 0,
    pending = {},
  },
  ui = {
    output_buf = nil,
    input_buf = nil,
    interaction_buf = nil,
    tree_buf = nil,
    output_win = nil,
    input_win = nil,
    status_buf = nil,
    status_win = nil,
    file_win = nil,
    visible = false,
    statuses = {},
    widgets = {},
    interaction = nil,
    interaction_queue = {},
    output_title = 'Pi chat',
    input_title = 'Pi input',
    input_hint = 'normal <CR> / insert <C-s> submit',
    input_recall_index = nil,
    input_recall_text = nil,
    subagent_view = nil,
    subagent_counter = 0,
  },
  session = {
    current_cwd = nil,
    runtime_cwd = nil,
    current_file = nil,
    auto_loaded_cwd = nil,
  },
  render = {
    tool_blocks = {},
    tool_objects = {},
    permission_blocks = {},
    anonymous_permission_counter = 0,
    anonymous_tool_counter = 0,
    last_tool_id = nil,
    last_user_text = nil,
    chunk_generation = 0,
    user_messages = {},
  },
  statusline = {
    status = 'not connected',
    active = false,
    waiting_input = false,
    loading = false,
    error = nil,
    model = nil,
    thinking_level = nil,
    cost = nil,
    tokens = nil,
    context_usage = nil,
  },
}

local function runtime_defaults(key)
  return {
    key = key or 'default',
    job_id = nil,
    stderr = {},
    buffer = '',
    next_id = 0,
    pending = {},
    status = 'not connected',
    active = false,
    waiting_input = false,
    loading = false,
    loading_lock = false,
    error = nil,
    session_file = nil,
    branch_root = nil,
    branch_entry_id = nil,
    label = nil,
    idle_timer = nil,
    pending_extension_ui_request = nil,
    current_extension_interaction = nil,
    pending_mcp_auth_server = nil,
    interaction_queue = {},
    cleared_extension_ui_requests = {},
    input_text = '',
    editor_text = '',
    model = nil,
    thinking_level = nil,
    cost = nil,
    tokens = nil,
    context_usage = nil,
    tool_timings = {},
    tool_timings_by_signature = {},
    permission_waits = {},
  }
end

local function sync_statusline_from_runtime(runtime)
  if not runtime or runtime.key ~= M.rpc.active_key then
    return
  end
  local loading = runtime.loading == true and runtime.status == 'loading'
  M.statusline.status = loading and 'loading' or (runtime.status or (runtime.job_id and 'idle' or 'not connected'))
  M.statusline.active = runtime.active == true
  M.statusline.waiting_input = runtime.waiting_input == true
  M.statusline.loading = loading
  M.statusline.error = runtime.error
  M.statusline.model = runtime.model
  M.statusline.thinking_level = runtime.thinking_level
  M.statusline.cost = runtime.cost
  M.statusline.tokens = runtime.tokens
  M.statusline.context_usage = runtime.context_usage
end

local function sync_active_runtime(runtime)
  runtime = runtime or M.rpc.runtimes[M.rpc.active_key]
  if not runtime then
    return
  end
  M.rpc.job_id = runtime.job_id
  M.rpc.stderr = runtime.stderr
  M.rpc.buffer = runtime.buffer
  M.rpc.next_id = runtime.next_id
  M.rpc.pending = runtime.pending
  sync_statusline_from_runtime(runtime)
end

function M.ensure_rpc_runtime(key)
  key = tostring(key or M.rpc.active_key or 'default')
  local runtime = M.rpc.runtimes[key]
  if not runtime then
    runtime = runtime_defaults(key)
    M.rpc.runtimes[key] = runtime
  end
  return runtime
end

function M.active_rpc_runtime()
  return M.ensure_rpc_runtime(M.rpc.active_key or 'default')
end

function M.set_active_rpc_runtime(key)
  key = tostring(key or 'default')
  M.rpc.active_key = key
  local runtime = M.ensure_rpc_runtime(key)
  sync_active_runtime(runtime)
  return runtime
end

function M.sync_active_rpc_runtime(runtime)
  if runtime and runtime.key == M.rpc.active_key then
    sync_active_runtime(runtime)
  end
end

function M.set_runtime_loading(runtime, loading, opts)
  opts = opts or {}
  runtime = runtime or M.active_rpc_runtime()
  if not runtime then
    return nil
  end
  runtime.loading = loading == true
  if runtime.loading then
    runtime.loading_lock = opts.lock_input ~= false
    runtime.status = 'loading'
    runtime.waiting_input = false
    runtime.error = nil
  else
    runtime.loading_lock = false
  end
  if not runtime.loading and runtime.status == 'loading' then
    if runtime.active then
      runtime.status = 'running'
    elseif M.is_job_running(runtime) then
      runtime.status = 'idle'
    else
      runtime.status = 'not connected'
    end
  end
  M.sync_active_rpc_runtime(runtime)
  return runtime
end

-- Internal test/support seam for simulating runtime-pool removal.
function M.remove_rpc_runtime(key)
  key = tostring(key or M.rpc.active_key or 'default')
  local runtime = M.rpc.runtimes[key]
  if runtime and runtime.idle_timer then
    pcall(vim.fn.timer_stop, runtime.idle_timer)
  end
  M.rpc.runtimes[key] = nil
  if M.rpc.active_key == key then
    M.rpc.active_key = 'default'
    sync_active_runtime(M.ensure_rpc_runtime('default'))
  end
end

function M.is_job_running(runtime)
  runtime = runtime or M.active_rpc_runtime()
  local job_id = runtime and runtime.job_id or nil
  if not job_id or job_id <= 0 then
    return false
  end
  return vim.fn.jobwait({ job_id }, 0)[1] == -1
end

function M.rpc_runtime_count(opts)
  opts = opts or {}
  local count = 0
  for _, runtime in pairs(M.rpc.runtimes or {}) do
    if opts.running_only then
      if M.is_job_running(runtime) then
        count = count + 1
      end
    elseif runtime.job_id or runtime.status ~= 'not connected' then
      count = count + 1
    end
  end
  return count
end

function M.clear_ui_statuses()
  M.ui.statuses = {}
  M.ui.widgets = {}
end

function M.recheck_rpc_runtimes()
  local changed = false
  local active_key = tostring(M.rpc.active_key or 'default')
  local stopped = {}
  for key, runtime in pairs(M.rpc.runtimes or {}) do
    if runtime.job_id and not M.is_job_running(runtime) then
      table.insert(stopped, { key = key, runtime = runtime })
    end
  end

  for _, item in ipairs(stopped) do
    if item.key == active_key then
      M.reset_rpc_runtime(item.runtime, false)
    else
      M.reset_rpc_runtime(item.runtime, true)
    end
    changed = true
  end

  if not M.rpc.runtimes[active_key] then
    M.rpc.active_key = 'default'
  end
  sync_active_runtime(M.ensure_rpc_runtime(M.rpc.active_key))
  return changed
end

function M.next_request_id(runtime)
  runtime = runtime or M.active_rpc_runtime()
  runtime.next_id = (runtime.next_id or 0) + 1
  M.sync_active_rpc_runtime(runtime)
  return 'pi-dev-' .. tostring(runtime.next_id)
end

function M.reset_rpc_runtime(runtime, remove)
  runtime = runtime or M.active_rpc_runtime()
  if runtime.idle_timer then
    pcall(vim.fn.timer_stop, runtime.idle_timer)
    runtime.idle_timer = nil
  end
  runtime.job_id = nil
  runtime.stderr = {}
  runtime.buffer = ''
  runtime.pending = {}
  runtime.active = false
  runtime.waiting_input = false
  runtime.loading = false
  runtime.loading_lock = false
  runtime.status = 'not connected'
  runtime.error = nil
  runtime.pending_extension_ui_request = nil
  runtime.current_extension_interaction = nil
  runtime.pending_mcp_auth_server = nil
  runtime.interaction_queue = {}
  runtime.cleared_extension_ui_requests = {}
  runtime.input_text = ''
  runtime.editor_text = ''
  runtime.model = nil
  runtime.thinking_level = nil
  runtime.cost = nil
  runtime.tokens = nil
  runtime.context_usage = nil
  runtime.tool_timings = {}
  runtime.tool_timings_by_signature = {}
  runtime.permission_waits = {}
  if remove and runtime.key then
    M.rpc.runtimes[runtime.key] = nil
  end
  M.sync_active_rpc_runtime(runtime)
end

return M
