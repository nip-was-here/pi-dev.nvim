-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local actions = require('pi-dev.actions')
local config = require('pi-dev.config')
local renderer = require('pi-dev.renderer')
local mcp = require('pi-dev.compat.mcp_adapter')
local rpc = require('pi-dev.rpc')
local sessions = require('pi-dev.sessions')
local state = require('pi-dev.state')
local statusline = require('pi-dev.statusline')
local ui = require('pi-dev.ui')

local M = {}

local first_open_status_rechecked = false

local function record_command_response(response)
  if response and response.__pi_runtime_key and response.__pi_runtime_key ~= state.rpc.active_key then
    return
  end
  if response and response.success == false then
    statusline.set_error(response.error or (response.command and (response.command .. ' failed')) or 'Pi command failed')
    ui.refresh_chrome()
  end
end

local function should_auto_load_session()
  return config.options.auto_resume_last_session ~= false and state.session.auto_loaded_cwd ~= sessions.current_cwd()
end

local function response_runtime(response)
  local key = response and response.__pi_runtime_key
  return key and state.ensure_rpc_runtime(key) or state.active_rpc_runtime()
end

local function response_is_active(response)
  return not (response and response.__pi_runtime_key) or response.__pi_runtime_key == state.rpc.active_key
end

local function refresh_after_user_message(response)
  if response and response.success ~= false then
    if sessions.auto_name_branch_session then
      local runtime = response_runtime(response)
      local session_file = response_is_active(response) and state.session.current_file or (runtime and runtime.session_file)
      sessions.auto_name_branch_session(session_file or (runtime and runtime.session_file))
    end
    M.refresh_status(100)
  end
end

local function begin_loading(runtime)
  runtime = state.set_runtime_loading(runtime or state.active_rpc_runtime(), true)
  ui.refresh_chrome()
  return runtime
end

local function finish_loading(runtime)
  runtime = state.set_runtime_loading(runtime or state.active_rpc_runtime(), false)
  ui.refresh_chrome()
  return runtime
end

local function recheck_status_on_first_open()
  if first_open_status_rechecked then
    return
  end
  first_open_status_rechecked = true
  M.refresh_status(0)
end

local function schedule_session_bootstrap()
  local runtime = begin_loading()
  vim.defer_fn(function()
    if should_auto_load_session() then
      sessions.load_latest_or_new({
        callback = function()
          finish_loading(runtime)
        end,
      })
    else
      local pending = 2
      local function done()
        pending = pending - 1
        if pending <= 0 then
          finish_loading(runtime)
        end
      end
      M.get_state(done)
      M.get_session_stats(done)
    end
  end, 100)
end

function M.start()
  local job_id = rpc.start()
  if job_id then
    ui.show()
    recheck_status_on_first_open()
    schedule_session_bootstrap()
  end
  return job_id
end

function M.toggle()
  local was_visible = state.ui.visible
  local job_id = rpc.start()
  ui.toggle()
  if job_id and not was_visible and state.ui.visible then
    recheck_status_on_first_open()
    schedule_session_bootstrap()
  end
end

function M.hide()
  ui.hide()
end

function M.focus_input()
  local job_id = rpc.start()
  ui.focus_input()
  if job_id then
    recheck_status_on_first_open()
    schedule_session_bootstrap()
  end
end

function M.submit_input()
  return ui.submit_input()
end

function M.prompt(message, opts, callback)
  rpc.start()
  statusline.clear_error()
  ui.refresh_chrome()
  return rpc.request(vim.tbl_extend('force', {
    type = 'prompt',
    message = message,
  }, opts or {}), function(response)
    record_command_response(response)
    refresh_after_user_message(response)
    if callback then
      callback(response)
    end
  end)
end

function M.steer(message, callback)
  rpc.start()
  statusline.clear_error()
  ui.refresh_chrome()
  return rpc.request({ type = 'steer', message = message }, function(response)
    record_command_response(response)
    refresh_after_user_message(response)
    if callback then
      callback(response)
    end
  end)
end

function M.follow_up(message, callback)
  rpc.start()
  statusline.clear_error()
  ui.refresh_chrome()
  return rpc.request({ type = 'follow_up', message = message }, function(response)
    record_command_response(response)
    refresh_after_user_message(response)
    if callback then
      callback(response)
    end
  end)
end

local function bash_result_text(data)
  if type(data) ~= 'table' then
    return ''
  end
  local chunks = {}
  if data.output and data.output ~= '' then
    table.insert(chunks, tostring(data.output))
  end
  if data.stdout and data.stdout ~= '' then
    table.insert(chunks, tostring(data.stdout))
  end
  if data.stderr and data.stderr ~= '' then
    table.insert(chunks, tostring(data.stderr))
  end
  return table.concat(chunks, '\n')
end

local function append_user_bash_result(command, data, opts)
  opts = opts or {}
  local lines = {
    opts.local_only and 'Local shell command finished. Output was not sent to Pi context.' or 'Shell command finished and was added to Pi context.',
    '',
    'Command:',
    '```bash',
    tostring(command or ''),
    '```',
  }
  local exit_code = type(data) == 'table' and (data.exitCode or data.code) or nil
  if exit_code ~= nil then
    table.insert(lines, '')
    table.insert(lines, 'Exit code: ' .. tostring(exit_code))
  end
  local output = bash_result_text(data)
  if output ~= '' then
    table.insert(lines, '')
    table.insert(lines, 'Output:')
    table.insert(lines, '```bash')
    vim.list_extend(lines, vim.split(output:gsub('\r\n', '\n'):gsub('\r', '\n'), '\n', { plain = true }))
    table.insert(lines, '```')
  end
  renderer.append_system(table.concat(lines, '\n'))
end

function M.bash(command, callback)
  command = vim.trim(tostring(command or ''))
  if command == '' then
    return false
  end
  rpc.start()
  statusline.clear_error()
  renderer.append_system('Running shell command in Pi context: `' .. command .. '`')
  return rpc.request({ type = 'bash', command = command }, function(response)
    record_command_response(response)
    if response_is_active(response) and response and response.success and response.data then
      append_user_bash_result(command, response.data)
      M.refresh_status(100)
    end
    if callback then
      callback(response)
    end
  end)
end

function M.local_bash(command, callback)
  command = vim.trim(tostring(command or ''))
  if command == '' then
    return false
  end
  renderer.append_system('Running local shell command without sending output to Pi: `' .. command .. '`')
  local shell = vim.o.shell ~= '' and vim.o.shell or (vim.env.SHELL or 'sh')
  vim.system({ shell, '-c', command }, { text = true }, function(result)
    vim.schedule(function()
      append_user_bash_result(command, {
        stdout = result.stdout,
        stderr = result.stderr,
        exitCode = result.code,
      }, { local_only = true })
      if callback then
        callback(result)
      end
    end)
  end)
  return true
end

local function mark_abort_idle(response)
  if not response_is_active(response) or not response or response.success == false then
    return
  end
  local data = type(response.data) == 'table' and response.data or {}
  if data.isStreaming == true or data.active == true then
    return
  end
  local runtime = response_runtime(response)
  runtime.active = false
  runtime.waiting_input = false
  runtime.loading = false
  if runtime.status ~= 'error' then
    runtime.status = state.is_job_running(runtime) and 'idle' or 'not connected'
  end
  state.sync_active_rpc_runtime(runtime)
  ui.refresh_chrome()
end

function M.abort(callback)
  require('pi-dev.extension_ui').clear_runtime_interactions(state.rpc.active_key)
  renderer.append_user_cancelled()
  return rpc.request({ type = 'abort' }, function(response)
    record_command_response(response)
    mark_abort_idle(response)
    M.refresh_status(50)
    if callback then
      callback(response)
    end
  end)
end

function M.stop_current_rpc()
  local stopped = rpc.stop_current()
  if stopped then
    state.statusline.active = false
    state.statusline.waiting_input = false
    state.statusline.status = state.is_job_running() and 'idle' or 'not connected'
    renderer.append_system('Killed current Pi RPC branch process.')
    ui.refresh_chrome()
  end
  return stopped
end

function M.name_session(name, callback)
  name = name and vim.trim(tostring(name)) or nil
  if not name or name == '' then
    vim.ui.input({ prompt = 'Pi root session name: ' }, function(value)
      if value and vim.trim(value) ~= '' then
        M.name_session(value, callback)
      end
    end)
    return nil
  end
  rpc.start()
  return rpc.request({ type = 'set_session_name', name = name }, function(response)
    if response_is_active(response) and response and response.success then
      local root = sessions.root_file and sessions.root_file(state.session.current_file) or state.session.current_file
      local updated, err = false, nil
      if sessions.write_root_session_name then
        updated, err = sessions.write_root_session_name(name, root)
      end
      local note = 'Session name set to `' .. name .. '`.'
      if updated and root then
        note = note .. '\nRoot session: `' .. root .. '`'
      elseif err then
        note = note .. '\nRoot session file was not updated locally: ' .. tostring(err)
      end
      renderer.append_system(note)
      M.refresh_status(50)
    else
      record_command_response(response)
    end
    if callback then
      callback(response)
    end
  end)
end

function M.show_session_info(callback)
  rpc.start()
  return rpc.request({ type = 'get_state' }, function(state_response)
    local function render(stats_response)
      if response_is_active(state_response) and response_is_active(stats_response) then
        local data = (state_response and state_response.success and state_response.data) or {}
        local stats = (stats_response and stats_response.success and stats_response.data) or {}
        local root = sessions.root_file and sessions.root_file(data.sessionFile or state.session.current_file) or state.session.current_file
        local lines = {
          'Pi session:',
          '- runtime: ' .. tostring(state.rpc.active_key or 'default'),
          '- status: ' .. tostring(state.statusline.status or 'unknown'),
          '- cwd: ' .. tostring(sessions.current_cwd()),
          '- session file: ' .. tostring(data.sessionFile or state.session.current_file or '-'),
          '- root session: ' .. tostring(root or '-'),
          '- session id: ' .. tostring(data.sessionId or stats.sessionId or '-'),
          '- session name: ' .. tostring(data.sessionName or '-'),
          '- model: ' .. tostring(state.statusline.model or '-'),
          '- thinking: ' .. tostring(state.statusline.thinking_level or '-'),
          '- messages: ' .. tostring(stats.totalMessages or data.messageCount or '-'),
          '- user/assistant/tool: ' .. tostring(stats.userMessages or '-') .. '/' .. tostring(stats.assistantMessages or '-') .. '/' .. tostring(stats.toolCalls or '-'),
          '- tokens: ' .. tostring(state.statusline.tokens or '-'),
          '- cost: ' .. tostring(state.statusline.cost or '-'),
        }
        if type(state.statusline.context_usage) == 'table' then
          table.insert(lines, '- context: ' .. tostring(state.statusline.context_usage.percent or '-') .. '%')
        end
        renderer.append_system(table.concat(lines, '\n'))
      end
      if callback then
        callback(state_response, stats_response)
      end
    end
    rpc.request({ type = 'get_session_stats' }, render)
  end)
end

function M.compact(custom_instructions, callback)
  rpc.start()
  statusline.clear_error()
  local message = { type = 'compact' }
  custom_instructions = custom_instructions and vim.trim(tostring(custom_instructions)) or ''
  if custom_instructions ~= '' then
    message.customInstructions = custom_instructions
  end
  renderer.append_system(custom_instructions ~= '' and 'Compacting Pi context with custom instructions.' or 'Compacting Pi context.')
  return rpc.request(message, function(response)
    if response_is_active(response) and response and response.success then
      local data = response.data or {}
      local lines = { 'Compaction finished.' }
      if data.summary and data.summary ~= '' then
        table.insert(lines, '')
        table.insert(lines, data.summary)
      end
      if data.tokensBefore then
        table.insert(lines, '')
        table.insert(lines, 'Tokens before: ' .. tostring(data.tokensBefore))
      end
      renderer.append_system(table.concat(lines, '\n'))
      M.refresh_status(100)
    else
      record_command_response(response)
    end
    if callback then
      callback(response)
    end
  end)
end

function M.export_session(path, callback)
  path = path and vim.trim(tostring(path)) or nil
  if not path or path == '' then
    vim.ui.input({ prompt = 'Export Pi session HTML path: ' }, function(value)
      M.export_session(value, callback)
    end)
    return nil
  end
  rpc.start()
  return rpc.request({ type = 'export_html', outputPath = path }, function(response)
    if response_is_active(response) and response and response.success then
      local out = response.data and response.data.path or path
      renderer.append_system('Exported Pi session HTML to `' .. tostring(out) .. '`.')
    else
      record_command_response(response)
    end
    if callback then
      callback(response)
    end
  end)
end

function M.hotkeys()
  local opts = config.options.keymaps or {}
  local prefix = opts.prefix or ''
  local mappings = opts.mappings or {}
  local lines = { 'pi-dev.nvim hotkeys:', '' }
  for _, action in ipairs(actions.command_specs(M)) do
    local suffix = mappings[action.id]
    local key = suffix and (prefix .. suffix) or '-'
    table.insert(lines, string.format('- `%s` / `:%s` - %s', key, action.command, action.command_desc))
  end
  table.insert(lines, '')
  table.insert(lines, 'Input buffer: normal `<CR>` or insert `<C-s>` submit; `<C-c>` cancels current Pi work; empty normal `<PageUp>`/`<PageDown>` recalls branch-local user prompts.')
  renderer.append_system(table.concat(lines, '\n'))
  return true
end

function M.new_session(callback)
  return sessions.new_session(callback)
end

function M.resume()
  rpc.start()
  return sessions.pick()
end

function M.tree()
  rpc.start()
  return sessions.tree()
end

function M.waiting()
  rpc.start()
  return sessions.waiting()
end

function M.delete_session(callback)
  return require('pi-dev.sessions.delete').delete_current(callback)
end

function M.open_subagent_buffer()
  return ui.open_subagent_at_cursor()
end

function M.return_to_parent_agent_buffer()
  return ui.return_to_parent_subagent()
end

function M.next_rpc()
  return sessions.next_rpc()
end

function M.previous_rpc()
  return sessions.previous_rpc()
end

local function restart_and_restore(current_file, callback)
  rpc.stop()
  rpc.start()
  ui.show()
  vim.defer_fn(function()
    if current_file then
      sessions.switch_to(current_file, { title = 'Pi.dev reloaded session', force_switch = true, confirm_running_rpc = false }, callback)
    else
      sessions.load_latest_or_new({ callback = callback })
    end
  end, 100)
end

local function active_runtime_has_active_work()
  local runtime = state.active_rpc_runtime()
  if not (runtime and state.is_job_running(runtime)) then
    return false
  end
  local status = rpc.runtime_status and rpc.runtime_status(runtime) or runtime.status
  if runtime.waiting_input == true or status == 'waiting input' then
    return false
  end
  return runtime.active == true
    or status == 'running'
    or status == 'compacting'
    or status == 'retrying'
    or tostring(status or ''):match('^tool%s+') ~= nil
end

local function active_runtime_has_reload_state()
  if ui.save_active_runtime_input then
    ui.save_active_runtime_input()
  end
  local runtime = state.active_rpc_runtime()
  if not runtime then
    return false
  end
  if (runtime.input_text and runtime.input_text ~= '') or (runtime.editor_text and runtime.editor_text ~= '') then
    return true
  end
  if not state.is_job_running(runtime) then
    return false
  end
  local status = rpc.runtime_status and rpc.runtime_status(runtime) or runtime.status
  return runtime.active == true
    or runtime.waiting_input == true
    or status == 'waiting input'
    or status == 'running'
    or status == 'compacting'
    or status == 'retrying'
    or tostring(status or ''):match('^tool%s+') ~= nil
end

local function confirm_active_runtime_reload(on_confirm, callback)
  if not active_runtime_has_reload_state() then
    return false, on_confirm()
  end
  local choices = {
    { label = 'Cancel - keep current Pi RPC work and drafts', confirm = false },
    { label = 'Stop active Pi RPC runtime and reload', confirm = true },
  }
  vim.schedule(function()
    vim.ui.select(choices, {
      prompt = 'Reloading Pi will stop the active Pi RPC runtime and discard its volatile runtime-local state. Continue?',
      format_item = function(item)
        return item.label
      end,
    }, function(choice)
      if not (choice and choice.confirm) then
        renderer.append_system('Reload cancelled; active Pi RPC work and drafts were kept.')
        if callback then
          callback({ success = false, cancelled = true, error = 'reload cancelled' })
        end
        return
      end
      on_confirm()
    end)
  end)
  return true
end

function M.reload(callback)
  local function do_reload()
    if state.is_job_running() then
      return rpc.request({ type = 'get_state' }, function(response)
        if response and response.success and response.data and response.data.sessionFile then
          state.session.current_file = response.data.sessionFile
        end
        restart_and_restore(state.session.current_file, callback)
      end)
    end
    restart_and_restore(state.session.current_file, callback)
  end

  local deferred, request_id = confirm_active_runtime_reload(do_reload, callback)
  if deferred then
    return nil
  end
  return request_id
end

function M.get_available_models(callback)
  rpc.start()
  return rpc.request({ type = 'get_available_models' }, callback)
end

local function reject_model_change_during_active_work(callback)
  local message = 'Model change is unavailable during active Pi work; try again after the current turn.'
  vim.notify(message, vim.log.levels.WARN)
  renderer.append_system(message)
  if callback then
    callback({ success = false, cancelled = true, error = 'model change unavailable during active work' })
  end
  return nil
end

function M.set_model(provider, model_id, callback)
  if active_runtime_has_active_work() then
    return reject_model_change_during_active_work(callback)
  end
  rpc.start()
  statusline.clear_error()
  ui.refresh_chrome()
  return rpc.request({ type = 'set_model', provider = provider, modelId = model_id }, function(response)
    if response and response.success and response.data then
      statusline.update_from_state({ model = response.data }, { runtime = response_runtime(response) })
      if response_is_active(response) then
        renderer.append_system('Model set to `' .. tostring(provider) .. '/' .. tostring(model_id) .. '`')
        ui.refresh_chrome()
      end
      M.refresh_status(50)
    elseif response and response.error then
      if response_is_active(response) then
        statusline.set_error(response.error)
        ui.refresh_chrome()
      end
    else
      record_command_response(response)
    end
    if callback then
      callback(response)
    end
  end)
end

function M.model_picker()
  if active_runtime_has_active_work() then
    return reject_model_change_during_active_work()
  end
  return M.get_available_models(function(response)
    local models = response and response.success and response.data and response.data.models or {}
    if #models == 0 then
      vim.notify('No Pi models available', vim.log.levels.WARN)
      return
    end
    table.sort(models, function(a, b)
      return tostring((a.provider or '') .. '/' .. (a.id or a.name or '')) < tostring((b.provider or '') .. '/' .. (b.id or b.name or ''))
    end)
    local labels = {}
    local by_label = {}
    for _, model in ipairs(models) do
      local label = tostring(model.provider or '?') .. '/' .. tostring(model.id or model.name or '?')
      table.insert(labels, label)
      by_label[label] = model
    end
    vim.ui.select(labels, { prompt = 'Pi model' }, function(choice)
      local model = choice and by_label[choice]
      if model then
        M.set_model(model.provider, model.id or model.name)
      end
    end)
  end)
end

function M.get_state(callback)
  return rpc.request({ type = 'get_state' }, function(response)
    if response and response.success and response.data then
      local runtime = response_runtime(response)
      if response.data.sessionFile then
        runtime.session_file = response.data.sessionFile
        state.sync_active_rpc_runtime(runtime)
        if response_is_active(response) then
          state.session.current_file = response.data.sessionFile
        end
      end
      statusline.update_from_state(response.data, { runtime = runtime })
      if response_is_active(response) then
        ui.refresh_chrome()
      end
    else
      record_command_response(response)
    end
    if callback then
      callback(response)
    end
  end)
end

local function send_user_text(message)
  if state.statusline.active then
    M.steer(message)
  else
    M.prompt(message)
  end
  renderer.append_user(message)
end

local function apply_mcp_and_continue(directives, remaining)
  if active_runtime_has_active_work() then
    renderer.append_system('MCP context change deferred; run `/mcp ...` or `/reload` after the current turn. Prompt was not sent.')
    return
  end
  local mcp_snapshot = mcp.snapshot_override and mcp.snapshot_override() or nil
  local result = mcp.apply_directives(directives)
  mcp.append_apply_result(result)
  local function continue_prompt()
    if remaining and remaining ~= '' then
      send_user_text(remaining)
    end
  end
  if result.changed then
    M.reload(function(response)
      if response and response.success and not (response.data and response.data.cancelled) then
        continue_prompt()
      else
        if mcp.restore_override then
          mcp.restore_override(mcp_snapshot)
        end
        renderer.append_system('MCP context change cancelled; prompt was not sent.')
      end
    end)
  else
    continue_prompt()
  end
end

function M.submit_text(text)
  text = vim.trim(text or '')
  if text == '' then
    return false
  end
  if M.handle_slash_command(text) then
    return true
  end
  local local_command = text:match('^!!%s*(.+)$')
  if local_command then
    return M.local_bash(local_command)
  end
  local context_command = text:match('^!%s*(.+)$')
  if context_command then
    return M.bash(context_command)
  end
  local remaining, directives = mcp.extract_directives(text)
  if #directives > 0 then
    apply_mcp_and_continue(directives, remaining)
    return true
  end
  send_user_text(text)
  return true
end

function M.get_session_stats(callback)
  return rpc.request({ type = 'get_session_stats' }, function(response)
    if response and response.success and response.data then
      statusline.update_from_stats(response.data, { runtime = response_runtime(response) })
      if response_is_active(response) then
        ui.refresh_chrome()
      end
    else
      record_command_response(response)
    end
    if callback then
      callback(response)
    end
  end)
end

function M.refresh_status(delay_ms)
  vim.defer_fn(function()
    if not state.is_job_running() then
      return
    end
    M.get_state()
    M.get_session_stats()
  end, delay_ms or 0)
end

function M.handle_slash_command(text)
  local trimmed = vim.trim(text or '')
  local lower_trimmed = trimmed:lower()
  if mcp.is_enabled() and (lower_trimmed == '/mcp' or lower_trimmed == '/mcp status') then
    mcp.append_status()
    return true
  end
  local mcp_on = mcp.is_enabled() and trimmed:match('^/[mM][cC][pP][ \t]+[oO][nN][ \t]+([^\r\n]+)$') or nil
  if mcp_on then
    apply_mcp_and_continue({ { action = 'on', name = mcp_on } }, '')
    return true
  end
  local mcp_off = mcp.is_enabled() and trimmed:match('^/[mM][cC][pP][ \t]+[oO][fF][fF][ \t]*([^\r\n]*)$') or nil
  if mcp_off ~= nil then
    apply_mcp_and_continue({ { action = 'off', name = mcp_off } }, '')
    return true
  end
  local mcp_auth = mcp.is_enabled() and trimmed:match('^/[mM][cC][pP]%-[aA][uU][tT][hH][ \t]+([^\r\n]+)$') or nil
  if mcp_auth then
    send_user_text('/mcp-auth ' .. (mcp.canonical_name(mcp_auth) or mcp_auth))
    return true
  end
  return actions.handle_slash(M, trimmed)
end

function M.reload_for_cwd(cwd)
  return sessions.reload_for_cwd(cwd)
end

function M.stop()
  rpc.stop_all()
end

return M
