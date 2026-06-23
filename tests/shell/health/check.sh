#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

fake_bin_dir="$(pidev_tmp_dir)"
fake_pi="$fake_bin_dir/fake-pi-health"
cat > "$fake_pi" <<'FAKE'
#!/usr/bin/env bash
while IFS= read -r _line; do
  :
done
FAKE
chmod u+x "$fake_pi"

output="$({
  pidev_nvim_output \
    +"lua require('pi-dev').setup({ exec = { bin = '$fake_pi' }, keymaps = { enable = false } })" \
    +"lua require('pi-dev.health').check()"
} 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}

pidev_assert_no_nvim_errors "$output"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local health_mod = require('pi-dev.health')
local config = require('pi-dev.config')

local reports = {}
vim.health = {
  start = function(message) table.insert(reports, { kind = 'start', message = message }) end,
  ok = function(message) table.insert(reports, { kind = 'ok', message = message }) end,
  warn = function(message) table.insert(reports, { kind = 'warn', message = message }) end,
  error = function(message) table.insert(reports, { kind = 'error', message = message }) end,
  info = function(message) table.insert(reports, { kind = 'info', message = message }) end,
}

local original_executable = vim.fn.executable
local original_jobstart = vim.fn.jobstart
local original_jobstop = vim.fn.jobstop
local original_isdirectory = vim.fn.isdirectory

local function reset(opts)
  reports = {}
  vim.fn.executable = function()
    return 1
  end
  vim.fn.isdirectory = function()
    return 1
  end
  vim.fn.jobstop = function()
    return 1
  end
  config.setup(vim.tbl_deep_extend('force', { exec = { bin = 'pi-health-test' }, keymaps = { enable = false } }, opts or {}))
end

local function has(kind, needle)
  for _, report in ipairs(reports) do
    if report.kind == kind and tostring(report.message):find(needle, 1, true) then
      return true
    end
  end
  return false, vim.inspect(reports)
end

reset()
vim.fn.executable = function()
  return 0
end
health_mod.check()
assert(has('error', 'Pi executable not found'), vim.inspect(reports))
assert(has('ok', 'Neovim'), vim.inspect(reports))

reset({ exec = { args = { '--json' } } })
vim.fn.jobstart = function()
  return 0
end
health_mod.check()
assert(has('warn', 'does not include --mode rpc'), vim.inspect(reports))
assert(has('error', 'Failed to spawn Pi RPC command'), vim.inspect(reports))

reset()
vim.fn.jobstart = function(_, opts)
  if opts and opts.on_exit then
    opts.on_exit(1, 0)
  end
  return 42
end
health_mod.check()
assert(has('warn', 'exited immediately'), vim.inspect(reports))

reset()
vim.fn.jobstart = function(_, opts)
  if opts and opts.on_stderr then
    opts.on_stderr(1, { 'boom' })
  end
  if opts and opts.on_exit then
    opts.on_exit(1, 3)
  end
  return 43
end
health_mod.check()
assert(has('error', 'exited with code 3'), vim.inspect(reports))

vim.fn.executable = original_executable
vim.fn.jobstart = original_jobstart
vim.fn.jobstop = original_jobstop
vim.fn.isdirectory = original_isdirectory
LUA

output="$({
  pidev_nvim_output \
    +"luafile $tmp_lua"
} 2>&1)" || {
  printf '%s\n' "$output"
  rm -f "$tmp_lua"
  exit 1
}
rm -f "$tmp_lua"

pidev_assert_no_nvim_errors "$output"
