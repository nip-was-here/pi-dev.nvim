-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local rpc = require('pi-dev.rpc')
local state = require('pi-dev.state')
local store = require('pi-dev.sessions.store')

local M = {}

local function normalize_path(path)
  return store.normalize_path(path)
end

function M.runtime_is_non_idle(runtime)
  if not runtime or not state.is_job_running(runtime) then
    return false
  end
  local status = rpc.runtime_status and rpc.runtime_status(runtime) or runtime.status
  return status ~= 'idle' and status ~= 'not connected'
end

function M.runtime_has_local_draft(runtime)
  return runtime and ((runtime.input_text and runtime.input_text ~= '') or (runtime.editor_text and runtime.editor_text ~= ''))
end

function M.destructive_runtimes()
  state.recheck_rpc_runtimes()
  local ok_ui, ui = pcall(require, 'pi-dev.ui')
  if ok_ui and ui.save_active_runtime_input then
    ui.save_active_runtime_input()
  end
  local runtimes = {}
  for _, runtime in pairs(state.rpc.runtimes or {}) do
    if state.is_job_running(runtime) and (M.runtime_is_non_idle(runtime) or M.runtime_has_local_draft(runtime)) then
      table.insert(runtimes, runtime)
    end
  end
  table.sort(runtimes, function(a, b)
    return tostring(a.key or '') < tostring(b.key or '')
  end)
  return runtimes
end

function M.same_session_path(left, right)
  local normalized_left = normalize_path(left)
  local normalized_right = normalize_path(right)
  return normalized_left and normalized_right and normalized_left == normalized_right
end

local function comparable_session_root(path, root_session_file)
  path = normalize_path(path)
  if not path then
    return nil
  end
  return normalize_path(root_session_file(path) or path)
end

function M.same_session_root(left, right, root_session_file)
  local left_root = comparable_session_root(left, root_session_file)
  local right_root = comparable_session_root(right, root_session_file)
  return left_root and right_root and left_root == right_root
end

function M.same_runtime_key(left, right)
  if left == nil or right == nil then
    return false
  end
  return tostring(left) == tostring(right)
end

local function runtime_pool_has_session_context()
  for _, runtime in pairs(state.rpc.runtimes or {}) do
    if runtime.session_file or runtime.branch_root or runtime.branch_entry_id then
      return true
    end
  end
  return false
end

function M.target_changes_root(target_path, root_session_file)
  if not target_path or target_path == '' then
    return true
  end
  if not state.session.current_file or state.session.current_file == '' then
    return runtime_pool_has_session_context()
  end
  if M.same_session_path(target_path, state.session.current_file) then
    return false
  end
  if M.same_session_root(target_path, state.session.current_file, root_session_file) then
    return false
  end
  return true
end

function M.reset_runtime_pool_if_connected(reason)
  local count = state.rpc_runtime_count and state.rpc_runtime_count({ running_only = true }) or (state.is_job_running() and 1 or 0)
  if count <= 0 then
    return 0
  end
  rpc.stop_all()
  if reason then
    require('pi-dev.renderer').append_system(string.format(reason, count, count == 1 and '' or 's'))
  end
  return count
end

local function same_branch_target(active_runtime, opts)
  if not opts.branch_entry_id or not active_runtime or not active_runtime.branch_entry_id then
    return false
  end
  if tostring(opts.branch_entry_id) ~= tostring(active_runtime.branch_entry_id) then
    return false
  end
  local target_root = normalize_path(opts.tree_root_file or opts.branch_root)
  local active_root = normalize_path(active_runtime.branch_root)
  if not target_root or not active_root then
    return false
  end
  return target_root == active_root
end

function M.target_is_current(path, opts)
  opts = opts or {}
  if opts.force_switch == true then
    return false
  end

  local active_runtime = state.active_rpc_runtime()
  local active_running = active_runtime and state.is_job_running(active_runtime)
  if active_running and same_branch_target(active_runtime, opts) then
    return true, 'Pi branch is already current.'
  end
  if active_running and M.same_session_path(path, active_runtime.session_file) then
    return true, 'Pi session is already current.'
  end
  return false, nil
end

function M.confirm_running_switch(target_path, on_confirm, on_cancel, opts, root_session_file)
  opts = opts or {}
  local root_changes = M.target_changes_root(target_path, root_session_file)
  if opts.confirm_running_rpc == false or not root_changes then
    return false, on_confirm()
  end

  local runtimes = M.destructive_runtimes()
  local same_context = (opts.confirm_same_session ~= true and M.same_session_path(target_path, state.session.current_file))
    or (opts.confirm_same_root ~= true and M.same_session_root(target_path, state.session.current_file, root_session_file))
  if same_context then
    return false, on_confirm()
  end
  if #runtimes == 0 then
    if root_changes then
      M.reset_runtime_pool_if_connected('Stopped %d idle Pi RPC runtime%s before switching root session trees.')
    end
    return false, on_confirm()
  end

  local target_label = target_path and vim.fn.fnamemodify(target_path, ':t') or 'new session'
  local prompt = string.format(
    'Switching Pi session will stop %d Pi RPC runtime%s and discard their volatile runtime-local state. Continue?',
    #runtimes,
    #runtimes == 1 and '' or 's'
  )
  local choices = {
    { label = 'Cancel - keep current Pi RPC work and drafts', confirm = false },
    { label = 'Stop Pi RPC runtimes and switch to ' .. target_label, confirm = true },
  }

  vim.schedule(function()
    vim.ui.select(choices, {
      prompt = prompt,
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      local renderer = require('pi-dev.renderer')
      if not (choice and choice.confirm) then
        renderer.append_system('Session switch cancelled; running Pi RPC work was kept.')
        if on_cancel then
          on_cancel({ success = false, cancelled = true, error = 'session switch cancelled' })
        end
        return
      end

      rpc.stop_all()
      renderer.append_system(string.format('Stopped %d running Pi RPC runtime%s before switching sessions. A fresh Pi RPC will be started for the selected session.', #runtimes, #runtimes == 1 and '' or 's'))
      on_confirm()
    end)
  end)
  return true
end

return M
