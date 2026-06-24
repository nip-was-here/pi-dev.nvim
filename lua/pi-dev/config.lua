-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {}

M.defaults = {
  exec = {
    bin = 'pi',
    args = { '--mode', 'rpc' },
  },
  cwd = nil,
  env = nil,
  session_root = '~/.pi/agent/sessions',
  auto_resume_last_session = true,
  session_render = {
    max_messages = 100,
    include_tool_results = true,
    max_text_chars = false,
    chunk_size = 100,
    chunk_delay_ms = 0,
    chunk_budget_ms = 8,
  },

  tree = {
    assistant_responses = 'last_per_user', -- 'last_per_user' | 'all'
    branch_render = {
      max_messages = 30,
      include_tool_results = false,
      max_text_chars = false,
    },
  },

  rpc = {
    restart_on_exit = false,
    pool_size = 8,
    idle_timeout_ms = 180000,
  },

  compat = {
    pi_permission_system = {
      enable = true,
    },
    mcp_adapter = {
      enable = true,
    },
  },

  ui = {
    position = 'right', -- 'right' | 'bottom'
    width = 100,
    height = 0.35,
    input_height = 10,
    output_filetype = 'markdown',
    input_filetype = 'text',
    title = 'Pi.dev',
    session_title_branch_fraction = 0.6,
    status_separator = {
      enable = true,
    },
    statusline = {
      enable = true,
    },
    render = {
      fold_tool_output_over = 20,
      show_timestamps = true,
      show_thinking = true,
      show_tool_arguments = true,
      show_stderr = true,
    },
  },

  keymaps = {
    enable = true,
    prefix = '<leader>a',
    mappings = {
      toggle = 'g',
      prompt = 'p',
      focus_input = 'i',
      hide = 'q',
      abort = 'c',
      stop_current_rpc = 'K',
      cycle_rpc = 'a',
      cycle_rpc_reverse = 'A',
      new_session = 'n',
      resume = 'r',
      reload = 'R',
      model = 'm',
      tree = 't',
      waiting = 'w',
      subagent_open = ']',
      subagent_parent = '[',
    },
  },

  commands = {
    enable = true,
  },
}

M.options = vim.deepcopy(M.defaults)

local function validate(opts)
  if opts.executable ~= nil then
    error('pi-dev.nvim: executable was renamed to exec.bin')
  end
  if opts.args ~= nil then
    error('pi-dev.nvim: args was renamed to exec.args')
  end
  if opts.rpc and opts.rpc.args ~= nil then
    error('pi-dev.nvim: rpc.args was renamed to exec.args')
  end
  if opts.exec ~= nil and type(opts.exec) ~= 'table' then
    error('pi-dev.nvim: exec must be a table')
  end
  local exec = opts.exec or {}
  if exec.bin ~= nil and type(exec.bin) ~= 'string' and type(exec.bin) ~= 'table' then
    error('pi-dev.nvim: exec.bin must be a string or argv table')
  end
  if exec.args ~= nil and type(exec.args) ~= 'table' then
    error('pi-dev.nvim: exec.args must be a list')
  end
end

function M.setup(opts)
  opts = opts or {}
  validate(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
  return M.options
end

function M.command(extra_args)
  local opts = M.options
  local cmd = {}

  local exec = opts.exec or {}
  if type(exec.bin) == 'table' then
    vim.list_extend(cmd, exec.bin)
  else
    table.insert(cmd, exec.bin)
  end

  vim.list_extend(cmd, exec.args or {})
  vim.list_extend(cmd, extra_args or {})

  return cmd
end

return M
