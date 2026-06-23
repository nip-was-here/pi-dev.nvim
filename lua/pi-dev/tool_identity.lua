-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {}

function M.path(args)
  if type(args) ~= 'table' then
    return nil
  end
  return args.path or args.file or args.filePath
end

function M.signature(name, args)
  local key = tostring(name or 'tool')
  if type(args) == 'table' then
    if args.command then
      return key .. '\0command\0' .. tostring(args.command)
    end
    local path = M.path(args)
    if path then
      return key .. '\0path\0' .. tostring(path)
    end
    local ok, encoded = pcall(vim.json.encode, args)
    return key .. '\0args\0' .. (ok and encoded or vim.inspect(args))
  end
  return key .. '\0args\0' .. tostring(args or '')
end

return M
