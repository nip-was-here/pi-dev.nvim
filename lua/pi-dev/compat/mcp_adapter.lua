-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local config = require('pi-dev.config')
local renderer = require('pi-dev.renderer')

local M = {}

local override = nil

local function enabled()
  local compat = config.options.compat
  if compat == false then
    return false
  end
  local opts = compat and compat.mcp_adapter
  return not (opts and opts.enable == false)
end

local function trim(text)
  return vim.trim(tostring(text or ''))
end

local function normalize_name(name)
  return trim(name):lower()
end

local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local lines = vim.fn.readfile(path)
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))
  if ok and type(decoded) == 'table' then
    return decoded
  end
  return {}
end

local function home_path(path)
  return vim.fn.fnamemodify(path, ':p')
end

local function agent_dir()
  return vim.env.PI_CODING_AGENT_DIR or home_path('~/.pi/agent')
end

local function sha256_hex(value)
  local ok, hashed = pcall(vim.fn.sha256, tostring(value or ''))
  if ok and type(hashed) == 'string' and hashed ~= '' then
    return hashed
  end
  return nil
end

local function append_unique(list, seen, path)
  path = trim(path)
  if path ~= '' and not seen[path] then
    table.insert(list, path)
    seen[path] = true
  end
end

local function oauth_base_dirs()
  local dirs = {}
  local seen = {}
  append_unique(dirs, seen, vim.env.MCP_OAUTH_DIR or '')
  append_unique(dirs, seen, agent_dir() .. '/mcp-oauth')
  append_unique(dirs, seen, agent_dir() .. '/mcp-auth')
  return dirs
end

local function pi_global_config_path()
  return agent_dir() .. '/mcp.json'
end

local function config_sources(cwd)
  cwd = cwd or vim.uv.cwd()
  return {
    {
      id = 'shared-global',
      label = 'user-global standard MCP',
      read_path = home_path('~/.config/mcp/mcp.json'),
      kind = 'import',
    },
    {
      id = 'pi-global',
      label = 'Pi global override',
      read_path = pi_global_config_path(),
      kind = 'user',
    },
    {
      id = 'shared-project',
      label = 'project standard MCP',
      read_path = cwd .. '/.mcp.json',
      kind = 'project',
    },
    {
      id = 'pi-project',
      label = 'project Pi override',
      read_path = cwd .. '/.pi/mcp.json',
      kind = 'project',
    },
  }
end

local function servers_from(raw)
  local servers = raw and (raw.mcpServers or raw['mcp-servers'])
  if type(servers) == 'table' then
    return servers
  end
  return {}
end

local function disabled_servers_from(raw)
  local servers = raw and (raw.disabledMcpServers or raw.disabled_mcp_servers or raw['disabled-mcp-servers'])
  if type(servers) == 'table' then
    return servers
  end
  return {}
end

local import_paths = {
  cursor = { '~/.cursor/mcp.json' },
  ['claude-code'] = { '~/.claude/mcp.json', '~/.claude.json', '~/.claude/claude_desktop_config.json' },
  ['claude-desktop'] = { '~/Library/Application Support/Claude/claude_desktop_config.json' },
  codex = { '~/.codex/config.json' },
  windsurf = { '~/.windsurf/mcp.json' },
  vscode = { '.vscode/mcp.json' },
}

local function import_path(kind, cwd)
  for _, candidate in ipairs(import_paths[kind] or {}) do
    local path = candidate:sub(1, 1) == '.' and (cwd .. '/' .. candidate) or home_path(candidate)
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end
  return nil
end

local function imported_servers(raw, cwd)
  local result = {}
  if type(raw.imports) ~= 'table' then
    return result
  end
  for _, kind in ipairs(raw.imports) do
    local path = import_path(kind, cwd)
    if path then
      local imported = read_json(path)
      for name, definition in pairs(servers_from(imported)) do
        if not result[name] then
          result[name] = definition
        end
      end
    end
  end
  return result
end

local function collect_servers(cwd)
  local by_normalized = {}
  local ordered = {}
  for _, source in ipairs(config_sources(cwd)) do
    local raw = read_json(source.read_path)
    local merged = imported_servers(raw, cwd)
    for name, definition in pairs(disabled_servers_from(raw)) do
      merged[name] = vim.tbl_extend('force', type(definition) == 'table' and definition or {}, { __pi_disabled = true })
    end
    for name, definition in pairs(servers_from(raw)) do
      merged[name] = definition
    end
    for name, definition in pairs(merged) do
      local key = normalize_name(name)
      local disabled = type(definition) == 'table' and definition.__pi_disabled == true
      local entry = {
        name = name,
        definition = definition,
        source = source,
        config_disabled = disabled,
        config_direct = not disabled and type(definition) == 'table' and (definition.directTools == true or type(definition.directTools) == 'table'),
      }
      if not by_normalized[key] then
        table.insert(ordered, key)
      end
      by_normalized[key] = entry
    end
  end
  return by_normalized, ordered
end

local function edit_distance(left, right, max_distance)
  left = normalize_name(left)
  right = normalize_name(right)
  if left == right then
    return 0
  end
  if left == '' or right == '' then
    return math.max(#left, #right)
  end
  if max_distance and math.abs(#left - #right) > max_distance then
    return max_distance + 1
  end
  local previous = {}
  for j = 0, #right do
    previous[j] = j
  end
  for i = 1, #left do
    local current = { [0] = i }
    local row_min = current[0]
    local left_char = left:sub(i, i)
    for j = 1, #right do
      local cost = left_char == right:sub(j, j) and 0 or 1
      current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      row_min = math.min(row_min, current[j])
    end
    if max_distance and row_min > max_distance then
      return max_distance + 1
    end
    previous = current
  end
  return previous[#right]
end

local function resolve_server_entry(name, opts)
  opts = opts or {}
  local by_normalized, ordered = collect_servers(opts.cwd or vim.uv.cwd())
  local normalized = normalize_name(name)
  if by_normalized[normalized] then
    return by_normalized[normalized]
  end
  if opts.fuzzy == false or normalized == '' then
    return nil
  end
  local best
  local best_distance = math.min(2, math.max(1, math.floor(#normalized / 3)))
  for _, key in ipairs(ordered) do
    local distance = edit_distance(normalized, key, best_distance)
    if distance <= best_distance then
      if best and distance == best.distance then
        best.ambiguous = true
      elseif not best or distance < best.distance then
        best = { entry = by_normalized[key], distance = distance, ambiguous = false }
      end
    end
  end
  return best and not best.ambiguous and best.entry or nil
end

local function token_expired(value)
  local expires = tonumber(value)
  if not expires then
    return false
  end
  if expires > 100000000000 then
    expires = expires / 1000
  end
  return expires > 0 and expires <= os.time()
end

local function token_payload_status(payload)
  if type(payload) ~= 'table' then
    return 'invalid'
  end
  local tokens = type(payload.tokens) == 'table' and payload.tokens or payload
  local access = tokens.accessToken or tokens.access_token or tokens.token
  if not access or access == '' then
    return 'invalid'
  end
  if token_expired(tokens.expiresAt or tokens.expires_at or tokens.expires) then
    return 'expired'
  end
  return 'ok'
end

local function oauth_token_status(server_name)
  local candidates = {}
  local seen = {}
  local names = { tostring(server_name), normalize_name(server_name) }
  for _, base in ipairs(oauth_base_dirs()) do
    for _, name in ipairs(names) do
      append_unique(candidates, seen, base .. '/' .. name .. '/tokens.json')
      local hashed = sha256_hex(name)
      if hashed then
        append_unique(candidates, seen, base .. '/sha256-' .. hashed .. '/tokens.json')
      end
    end
  end
  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 then
      return token_payload_status(read_json(path))
    end
  end
  local legacy = read_json(agent_dir() .. '/mcp-oauth-tokens.json')
  local legacy_payload = type(legacy) == 'table' and (legacy[server_name] or legacy[normalize_name(server_name)]) or nil
  if legacy_payload then
    return token_payload_status(legacy_payload)
  end
  return 'missing'
end

local function auth_status(entry)
  if not entry or entry.config_disabled then
    return '-'
  end
  local definition = type(entry.definition) == 'table' and entry.definition or {}
  local auth = type(definition.auth) == 'string' and definition.auth:lower() or definition.auth
  if auth == false or auth == vim.NIL then
    return '-'
  end
  if definition.bearerToken or definition.bearer_token then
    return 'bearer'
  end
  if definition.bearerTokenEnv or definition.bearer_token_env then
    local env_name = definition.bearerTokenEnv or definition.bearer_token_env
    return vim.env[env_name] and vim.env[env_name] ~= '' and 'bearer' or 'missing'
  end
  if auth == 'bearer' then
    return 'missing'
  end
  if auth == 'oauth' or type(definition.oauth) == 'table' then
    return oauth_token_status(entry.name)
  end
  if definition.url then
    local status = oauth_token_status(entry.name)
    return status ~= 'missing' and status or 'auto'
  end
  return '-'
end

local function configured_direct_set(cwd)
  local by_normalized = collect_servers(cwd)
  local set = {}
  for key, entry in pairs(by_normalized) do
    if entry.config_direct then
      set[key] = entry.name
    end
  end
  return set
end

local function current_set(cwd)
  if override ~= nil then
    return vim.deepcopy(override)
  end
  return configured_direct_set(cwd)
end

local function same_set(left, right)
  for key, value in pairs(left or {}) do
    if (right or {})[key] ~= value then
      return false
    end
  end
  for key, value in pairs(right or {}) do
    if (left or {})[key] ~= value then
      return false
    end
  end
  return true
end

local function sorted_values(set)
  local values = {}
  for _, name in pairs(set or {}) do
    table.insert(values, name)
  end
  table.sort(values, function(a, b)
    return a:lower() < b:lower()
  end)
  return values
end

local function set_env_from_override()
  if override == nil then
    return nil
  end
  local values = sorted_values(override)
  if #values == 0 then
    return '__none__'
  end
  return table.concat(values, ',')
end

local function result(action)
  return {
    action = action,
    changed = false,
    enabled = {},
    disabled_servers = {},
    disabled_all = false,
    already = {},
    already_off = {},
    unknown = {},
    local_only = true,
  }
end

function M.is_enabled()
  return enabled()
end

function M.rpc_env()
  if not enabled() then
    return nil
  end
  local value = set_env_from_override()
  if not value then
    return nil
  end
  return { MCP_DIRECT_TOOLS = value }
end

function M.snapshot_override()
  return {
    has_override = override ~= nil,
    value = override ~= nil and vim.deepcopy(override) or nil,
  }
end

function M.restore_override(snapshot)
  if snapshot and snapshot.has_override then
    override = vim.deepcopy(snapshot.value or {})
  else
    override = nil
  end
end

function M.canonical_name(name, opts)
  if not enabled() then
    return nil
  end
  local entry = resolve_server_entry(name, opts)
  return entry and entry.name or nil
end

function M.server_items(base, opts)
  if not enabled() then
    return {}
  end
  opts = opts or {}
  base = normalize_name(base or '')
  local cwd = opts.cwd or vim.uv.cwd()
  local by_normalized, ordered = collect_servers(cwd)
  local effective = current_set(cwd)
  table.sort(ordered, function(a, b)
    return by_normalized[a].name:lower() < by_normalized[b].name:lower()
  end)
  local items = {}
  for _, key in ipairs(ordered) do
    local entry = by_normalized[key]
    if base == '' or key:find(base, 1, true) == 1 then
      local status = effective[key] and 'on' or (entry.config_disabled and 'off' or 'lazy')
      table.insert(items, {
        word = entry.name,
        abbr = entry.name,
        menu = '[mcp ' .. status .. ', auth ' .. auth_status(entry) .. ']',
        info = entry.source and entry.source.label or '',
        kind = 'Value',
      })
    end
  end
  return items
end

function M.extract_directives(text)
  if not enabled() then
    return trim(text), {}
  end
  local directives = {}
  local kept = {}
  for _, line in ipairs(vim.split(tostring(text or ''):gsub('\r\n', '\n'):gsub('\r', '\n'), '\n', { plain = true })) do
    local command, name = line:match('^%s*/[mM][cC][pP]%s+([oO][nN])%s+(.+)%s*$')
    if not command then
      command, name = line:match('^%s*/[mM][cC][pP]%s+([oO][fF][fF])%s*(.-)%s*$')
    end
    if command then
      command = command:lower()
    end
    if command and (command == 'off' or trim(name) ~= '') then
      table.insert(directives, { action = command, name = trim(name) })
    else
      table.insert(kept, line)
    end
  end
  return trim(table.concat(kept, '\n')), directives
end

function M.apply_directives(directives, opts)
  if not enabled() then
    local disabled = result('disabled')
    disabled.unknown = vim.tbl_map(function(directive)
      return directive.name or directive.action
    end, directives or {})
    return disabled
  end
  opts = opts or {}
  local cwd = opts.cwd or vim.uv.cwd()
  local before = current_set(cwd)
  local next_set = vim.deepcopy(before)
  local summary = result('mixed')

  for _, directive in ipairs(directives or {}) do
    if directive.action == 'on' then
      local entry = resolve_server_entry(directive.name, { cwd = cwd })
      if not entry then
        table.insert(summary.unknown, directive.name)
      elseif next_set[normalize_name(entry.name)] then
        table.insert(summary.already, entry.name)
      else
        next_set[normalize_name(entry.name)] = entry.name
        table.insert(summary.enabled, entry.name)
      end
    elseif directive.action == 'off' then
      if directive.name == nil or directive.name == '' then
        if next(next_set) == nil then
          summary.disabled_all = true
        else
          for _, name in pairs(next_set) do
            table.insert(summary.disabled_servers, name)
          end
          summary.disabled_all = true
          next_set = {}
        end
      else
        local entry = resolve_server_entry(directive.name, { cwd = cwd })
        if not entry then
          table.insert(summary.unknown, directive.name)
        elseif next_set[normalize_name(entry.name)] then
          next_set[normalize_name(entry.name)] = nil
          table.insert(summary.disabled_servers, entry.name)
        else
          table.insert(summary.already_off, entry.name)
        end
      end
    end
  end

  summary.changed = not same_set(before, next_set)
  if summary.changed then
    override = next_set
  end
  return summary
end

local function join_or_dash(items)
  return #items > 0 and table.concat(items, ', ') or '-'
end

local function table_cell(text)
  text = trim(tostring(text or '')):gsub('[\r\n]', ' '):gsub('%s+', ' '):gsub('|', '\\|')
  return text ~= '' and text or '-'
end

function M.append_status(opts)
  if not enabled() then
    return false
  end
  opts = opts or {}
  local cwd = opts.cwd or vim.uv.cwd()
  local by_normalized, ordered = collect_servers(cwd)
  local effective = current_set(cwd)
  local lines = { 'MCP Server Status:', '' }
  if #ordered == 0 then
    table.insert(lines, 'No MCP servers configured')
  else
    table.sort(ordered, function(a, b)
      return by_normalized[a].name:lower() < by_normalized[b].name:lower()
    end)
    table.insert(lines, '| mcp name | status | auth |')
    table.insert(lines, '|---|---|---|')
    for _, key in ipairs(ordered) do
      local entry = by_normalized[key]
      local status = effective[key] and 'on' or (entry.config_disabled and 'off' or 'lazy')
      table.insert(lines, string.format('| `%s` | %s | %s |', table_cell(entry.name), status, table_cell(auth_status(entry))))
    end
  end
  renderer.append_system(table.concat(lines, '\n'))
  return true
end

function M.append_apply_result(summary)
  if not enabled() then
    return false
  end
  local lines = {
    'MCP context update:',
    '- enabled: ' .. join_or_dash(summary.enabled),
    '- disabled: ' .. (summary.disabled_all and 'all' or join_or_dash(summary.disabled_servers)),
    '- already on: ' .. join_or_dash(summary.already),
    '- already off: ' .. join_or_dash(summary.already_off),
    '- unknown: ' .. join_or_dash(summary.unknown),
    '- config: unchanged',
  }
  renderer.append_system(table.concat(lines, '\n'))
  return true
end

return M
