-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local config = require('pi-dev.config')

local M = {}

local function health_api()
  local health = vim.health or require('health')
  return {
    start = health.start or health.report_start,
    ok = health.ok or health.report_ok,
    warn = health.warn or health.report_warn,
    error = health.error or health.report_error,
    info = health.info or health.report_info,
  }
end

local function command_executable()
  local bin = config.options.exec and config.options.exec.bin
  if type(bin) == 'table' then
    return bin[1]
  end
  return bin
end

local function rpc_command_string()
  return table.concat(vim.tbl_map(tostring, config.command()), ' ')
end

local function effective_env()
  local env = vim.deepcopy(config.options.env or {})
  local ok_mcp, mcp = pcall(require, 'pi-dev.compat.mcp_adapter')
  if ok_mcp and mcp.rpc_env then
    env = vim.tbl_extend('force', env, mcp.rpc_env() or {})
  end
  return next(env) and env or nil
end

local function check_neovim_version(health)
  local version = vim.version()
  if version.major > 0 or version.minor >= 10 then
    health.ok(string.format('Neovim %d.%d.%d', version.major, version.minor, version.patch))
  else
    health.error(string.format('Neovim >= 0.10 is required; found %d.%d.%d', version.major, version.minor, version.patch))
  end
end

local function check_pi_executable(health)
  local executable = command_executable()
  if type(executable) ~= 'string' or executable == '' then
    health.error('Pi executable is not configured')
    return false
  end
  if vim.fn.executable(executable) ~= 1 then
    health.error('Pi executable not found: ' .. executable)
    return false
  end
  health.ok('Pi executable found: ' .. executable)
  return true
end

local function check_rpc_command(health)
  local command = config.command()
  health.info('RPC command: ' .. rpc_command_string())
  local has_mode = false
  local has_rpc = false
  for _, arg in ipairs(command) do
    if arg == '--mode' then
      has_mode = true
    elseif has_mode and arg == 'rpc' then
      has_rpc = true
      break
    end
  end
  if has_rpc then
    health.ok('RPC mode is configured with --mode rpc')
  else
    health.warn('RPC command does not include --mode rpc; pi-dev.nvim expects Pi RPC mode')
  end
end

local function probe_rpc_spawn(health)
  local command = config.command()
  local stderr = {}
  local exited = false
  local exit_code = nil
  local job_id = vim.fn.jobstart(command, {
    cwd = config.options.cwd,
    env = effective_env(),
    stdin = 'pipe',
    stdout_buffered = false,
    stderr_buffered = false,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= '' then
          table.insert(stderr, line)
        end
      end
    end,
    on_exit = function(_, code)
      exited = true
      exit_code = code
    end,
  })
  if not job_id or job_id <= 0 then
    health.error('Failed to spawn Pi RPC command: ' .. rpc_command_string())
    return
  end
  vim.wait(500, function()
    return exited
  end, 20)
  if exited then
    local detail = #stderr > 0 and (': ' .. table.concat(stderr, '\n')) or ''
    if exit_code == 0 then
      health.warn('Pi RPC command exited immediately; expected a long-running RPC process' .. detail)
    else
      health.error('Pi RPC command exited with code ' .. tostring(exit_code) .. detail)
    end
    return
  end
  vim.fn.jobstop(job_id)
  health.ok('Pi RPC command can be spawned and stays running')
end

local function check_session_root(health)
  local root = vim.fn.expand(config.options.session_root or '~/.pi/agent/sessions')
  if vim.fn.isdirectory(root) == 1 then
    health.ok('Session root exists: ' .. root)
  else
    health.warn('Session root does not exist yet: ' .. root)
  end
end

local function check_optional_markdown(health)
  local ok = pcall(require, 'render-markdown')
  if ok then
    health.ok('Optional render-markdown.nvim is available')
  else
    health.info('Optional render-markdown.nvim is not installed')
  end
end

function M.check()
  local health = health_api()
  health.start('pi-dev.nvim')
  check_neovim_version(health)
  if check_pi_executable(health) then
    check_rpc_command(health)
    probe_rpc_spawn(health)
  else
    check_rpc_command(health)
  end
  check_session_root(health)
  check_optional_markdown(health)
end

return M
