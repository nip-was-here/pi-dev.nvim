-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local defaults = require('pi-dev.config').defaults
local readme = table.concat(vim.fn.readfile('README.md'), '\n')
local help = table.concat(vim.fn.readfile('doc/pi-dev.txt'), '\n')

assert(readme:find('\n## License\n', 1, true), 'README.md must include a License section')
assert(readme:find('%[LICENSE%]%(%.%/LICENSE%)'), 'README.md License section must link to ./LICENSE')
local install_section = readme:match('\n## Installation\n(.-)\n## Quick start\n')
assert(install_section, 'README.md must contain Installation before Quick start')
local install_lua_blocks = select(2, install_section:gsub('```lua', ''))
assert(install_lua_blocks == 1, 'Installation should keep only the minimal lazy.nvim lua example')
assert(install_section:find('opts%s*=', 1, false) == nil, 'lazy.nvim opts example belongs in Configuration')
assert(install_section:find('vim%.g%.pi_dev_nvim') == nil, 'vim.g config example belongs in Configuration')

local section = readme:match('\n## Configuration\n(.-)\n## ')
assert(section, 'README.md must contain a ## Configuration section before the next ## section')
assert(section:find('opts%s*=', 1, false), 'Configuration should contain the lazy.nvim opts example')
assert(section:find('vim%.g%.pi_dev_nvim'), 'Configuration should contain the vim.g setup example')
assert(section:find(':help pi%-dev%-configuration'), 'README Configuration should link the complete option reference to :help pi-dev-configuration')
assert(section:find('Common options', 1, true), 'README Configuration should keep a compact common-options table')
assert(section:find('ui.status_separator.enable', 1, true), 'README should prefer status separator terminology')
assert(section:find('ui.statusline.enable', 1, true), 'README should document the legacy statusline alias')

local function is_array_like(value)
  if type(value) ~= 'table' then
    return false
  end
  if vim.tbl_isempty(value) then
    return true
  end
  local max = 0
  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
      return false
    end
    max = math.max(max, key)
    count = count + 1
  end
  return count == max
end

local expected = {}
local function flatten(prefix, value)
  if type(value) ~= 'table' or is_array_like(value) then
    table.insert(expected, prefix)
    return
  end
  for key, child in pairs(value) do
    flatten(prefix == '' and tostring(key) or (prefix .. '.' .. tostring(key)), child)
  end
end

for key, value in pairs(defaults) do
  flatten(tostring(key), value)
end

table.sort(expected)
local missing = {}
for _, option in ipairs(expected) do
  if not help:find(option, 1, true) then
    table.insert(missing, option)
  end
end

assert(#missing == 0, 'doc/pi-dev.txt configuration help is missing option rows: ' .. table.concat(missing, ', '))
