-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {}

function M.command_specs(api)
  return {
  {
    id = 'toggle',
    command = 'PiDev',
    command_desc = 'Toggle Pi.dev RPC UI',
    key_desc = 'Pi.dev: toggle UI',
    run = function()
      api.toggle()
    end,
    key_run = function()
      local was_visible = require('pi-dev.state').ui.visible
      api.toggle()
      if not was_visible and require('pi-dev.state').ui.visible then
        require('pi-dev.ui').focus_input()
      end
    end,
  },
  {
    id = 'open',
    command = 'PiDevOpen',
    command_desc = 'Start Pi.dev RPC and show UI',
    run = function()
      api.start()
    end,
  },
  {
    id = 'hide',
    command = 'PiDevHide',
    command_desc = 'Hide Pi.dev UI without stopping RPC',
    key_desc = 'Pi.dev: hide UI',
    run = function()
      api.hide()
    end,
  },
  {
    id = 'prompt',
    command = 'PiDevPrompt',
    command_desc = 'Send a prompt to Pi.dev RPC',
    command_opts = { nargs = '+' },
    key_desc = 'Pi.dev: prompt',
    run = function(command)
      api.prompt(command.args)
    end,
    key_run = function()
      api.prompt(vim.fn.input('Pi.dev prompt: '))
    end,
  },
  {
    id = 'focus_input',
    command = 'PiDevFocus',
    command_desc = 'Focus Pi.dev input buffer',
    key_desc = 'Pi.dev: focus input',
    run = function()
      api.focus_input()
    end,
  },
  {
    id = 'abort',
    command = 'PiDevAbort',
    command_desc = 'Cancel current Pi.dev operation',
    key_desc = 'Pi.dev: cancel current work',
    run = function()
      api.abort()
    end,
  },
  {
    id = 'stop_current_rpc',
    command = 'PiDevStopRpc',
    command_desc = 'Kill the current branch-bound Pi RPC process',
    key_desc = 'Pi.dev: kill current branch RPC process',
    run = function()
      api.stop_current_rpc()
    end,
  },
  {
    id = 'cycle_rpc',
    command = 'PiDevNextRpc',
    command_desc = 'Cycle to the next running branch Pi RPC runtime',
    key_desc = 'Pi.dev: next branch RPC runtime',
    run = function()
      api.next_rpc()
    end,
  },
  {
    id = 'cycle_rpc_reverse',
    command = 'PiDevPrevRpc',
    command_desc = 'Cycle to the previous running branch Pi RPC runtime',
    key_desc = 'Pi.dev: previous branch RPC runtime',
    run = function()
      api.previous_rpc()
    end,
  },
  {
    id = 'name',
    command = 'PiDevName',
    command_desc = 'Set current root Pi session display name',
    command_opts = { nargs = '*' },
    run = function(command)
      api.name_session(command.args)
    end,
  },
  {
    id = 'session',
    command = 'PiDevSession',
    command_desc = 'Show current Pi session details',
    run = function()
      api.show_session_info()
    end,
  },
  {
    id = 'compact',
    command = 'PiDevCompact',
    command_desc = 'Compact current Pi context',
    command_opts = { nargs = '*' },
    run = function(command)
      api.compact(command.args)
    end,
  },
  {
    id = 'export',
    command = 'PiDevExport',
    command_desc = 'Export current Pi session to HTML',
    command_opts = { nargs = '?' },
    run = function(command)
      api.export_session(command.args)
    end,
  },
  {
    id = 'hotkeys',
    command = 'PiDevHotkeys',
    command_desc = 'Show pi-dev.nvim commands and hotkeys',
    run = function()
      api.hotkeys()
    end,
  },
  {
    id = 'quit',
    command = 'PiDevQuit',
    command_desc = 'Kill the current branch Pi RPC process',
    run = function()
      api.stop_current_rpc()
    end,
  },
  {
    id = 'new_session',
    command = 'PiDevNewSession',
    command_desc = 'Start a new Pi.dev session',
    key_desc = 'Pi.dev: new session',
    run = function()
      api.new_session()
    end,
  },
  {
    id = 'resume',
    command = 'PiDevResume',
    command_desc = 'Resume a current-directory Pi.dev session',
    run = function()
      api.resume()
    end,
  },
  {
    id = 'model',
    command = 'PiDevModel',
    command_desc = 'Pick Pi.dev model',
    run = function()
      api.model_picker()
    end,
  },
  {
    id = 'reload',
    command = 'PiDevReload',
    command_desc = 'Reload Pi.dev RPC and current session',
    run = function()
      api.reload()
    end,
  },
  {
    id = 'tree',
    command = 'PiDevTree',
    command_desc = 'Navigate Pi.dev session tree',
    key_desc = 'Pi.dev: tree navigation',
    run = function()
      api.tree()
    end,
  },
  {
    id = 'waiting',
    command = 'PiDevWaiting',
    command_desc = 'Navigate Pi.dev branches waiting for input',
    key_desc = 'Pi.dev: waiting input navigation',
    run = function()
      api.waiting()
    end,
  },
  {
    id = 'delete_session',
    command = 'PiDevDeleteSession',
    command_desc = 'Delete or trash the current Pi session tree',
    run = function()
      api.delete_session()
    end,
  },
  {
    id = 'subagent_open',
    command = 'PiDevSubagentOpen',
    command_desc = 'Open the subagent chat buffer under the cursor',
    key_desc = 'Pi.dev: open subagent buffer',
    run = function()
      api.open_subagent_buffer()
    end,
  },
  {
    id = 'subagent_parent',
    command = 'PiDevSubagentParent',
    command_desc = 'Return from a subagent chat buffer to its parent',
    key_desc = 'Pi.dev: return to parent buffer',
    run = function()
      api.return_to_parent_agent_buffer()
    end,
  },
}

end


function M.slash_specs(api)
  return {
    { names = { 'name' }, takes_arg = true, run = function(arg) api.name_session(arg) end },
    { names = { 'session' }, run = function() api.show_session_info() end },
    { names = { 'compact' }, takes_arg = true, run = function(arg) api.compact(arg) end },
    { names = { 'export' }, takes_arg = true, run = function(arg) api.export_session(arg) end },
    { names = { 'hotkeys' }, run = function() api.hotkeys() end },
    { names = { 'quit' }, run = function() api.stop_current_rpc() end },
    { names = { 'model' }, run = function() api.model_picker() end },
    { names = { 'resume' }, run = function() api.resume() end },
    { names = { 'reload' }, run = function() api.reload() end },
    { names = { 'stop-rpc', 'stop' }, run = function() api.stop_current_rpc() end },
    { names = { 'tree' }, run = function() api.tree() end },
    { names = { 'waiting' }, run = function() api.waiting() end },
    { names = { 'next-rpc', 'cycle-rpc' }, run = function() api.next_rpc() end },
    { names = { 'prev-rpc', 'previous-rpc' }, run = function() api.previous_rpc() end },
    { names = { 'new' }, run = function() api.new_session() end },
    { names = { 'delete-session' }, run = function() api.delete_session() end },
    { names = { 'subagent-open' }, run = function() api.open_subagent_buffer() end },
    { names = { 'subagent-parent' }, run = function() api.return_to_parent_agent_buffer() end },
  }
end

function M.handle_slash(api, text)
  local trimmed = vim.trim(text or '')
  local function command_arg(name)
    return trimmed:match('^/' .. name .. '%s+(.+)$')
  end
  for _, spec in ipairs(M.slash_specs(api)) do
    for _, name in ipairs(spec.names or {}) do
      local arg = spec.takes_arg and command_arg(name) or nil
      if trimmed == '/' .. name or arg then
        spec.run(arg)
        return true
      end
    end
  end
  return false
end

function M.fallback_completion_commands()
  return {
    { name = 'model', description = 'Pick Pi model' },
    { name = 'resume', description = 'Resume/switch current-directory Pi session' },
    { name = 'reload', description = 'Reload Pi RPC and current-directory session' },
    { name = 'name', description = 'Set root Pi session display name' },
    { name = 'session', description = 'Show current Pi session and runtime details' },
    { name = 'compact', description = 'Compact current Pi context' },
    { name = 'export', description = 'Export current Pi session to HTML' },
    { name = 'hotkeys', description = 'Show pi-dev.nvim commands and hotkeys' },
    { name = 'quit', description = 'Kill the current branch Pi RPC process' },
    { name = 'skill:', description = 'Run a Pi skill command; concrete skills appear after RPC discovery' },
    { name = 'tree', description = 'Navigate/fork from current session tree' },
    { name = 'waiting', description = 'Navigate branches currently waiting for input' },
    { name = 'new', description = 'Create and switch to a new Pi session' },
    { name = 'stop-rpc', description = 'Kill the current branch Pi RPC process' },
    { name = 'delete-session', description = 'Delete or trash the current Pi session tree' },
    { name = 'next-rpc', description = 'Cycle to the next running branch Pi RPC runtime' },
    { name = 'cycle-rpc', description = 'Alias for next-rpc' },
    { name = 'prev-rpc', description = 'Cycle to the previous running branch Pi RPC runtime' },
    { name = 'previous-rpc', description = 'Alias for prev-rpc' },
    { name = 'subagent-open', description = 'Open the subagent chat buffer under the cursor' },
    { name = 'subagent-parent', description = 'Return from a subagent chat buffer to its parent' },
    { name = 'mcp', description = 'Show MCP status or enable MCP direct tools' },
    { name = 'mcp-auth', description = 'Authenticate with an MCP OAuth server' },
  }
end

return M
