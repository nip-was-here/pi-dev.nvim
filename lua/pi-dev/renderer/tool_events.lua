-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local state = require('pi-dev.state')
local tool_identity = require('pi-dev.tool_identity')

local M = {}

local function explicit_tool_id(event)
  local id = event.toolCallId or event.tool_call_id or event.callId or event.id or event.toolUseId
  if id ~= nil and id ~= '' then
    return tostring(id)
  end
  return nil
end

local function is_anonymous_tool_id(id)
  return tostring(id or ''):match('^__anonymous_tool_') ~= nil
end

local function tool_event_name(event)
  return event.toolName or event.tool_name or event.name or 'tool'
end

local function tool_event_has_name(event)
  return event.toolName ~= nil or event.tool_name ~= nil or event.name ~= nil
end

local function tool_event_matches_object(event, object)
  if not object or object.status ~= 'Running' then
    return false
  end
  if tool_event_has_name(event) and tostring(object.name or 'tool') ~= tostring(tool_event_name(event)) then
    return false
  end
  if event.args ~= nil and object.args ~= nil then
    return vim.deep_equal(event.args, object.args)
  end
  if event.args ~= nil and object.args == nil then
    return false
  end
  return true
end

local function latest_permission_after(line)
  local latest
  for _, block in pairs(state.render.permission_blocks or {}) do
    if block.start_line and block.start_line > line and (not latest or block.start_line > latest.start_line) then
      latest = block
    end
  end
  return latest
end

local function args_missing(args)
  return args == nil or args == vim.NIL
end

local function interrupted_candidate_line(id)
  local block = state.render.tool_blocks and state.render.tool_blocks[id]
  if block and block.start_line and latest_permission_after(block.start_line) then
    return block.start_line
  end
  return nil
end

local function latest_interrupted_match(current_id, predicate)
  local latest_id
  local latest_line = -1
  for id, candidate in pairs(state.render.tool_objects or {}) do
    if id ~= current_id and candidate.result == nil and predicate(candidate) then
      local line = interrupted_candidate_line(id)
      if line and line >= latest_line then
        latest_id = id
        latest_line = line
      end
    end
  end
  return latest_id
end

function M.duplicate_permission_interrupted_tool_id(current_id, object)
  local signature = tool_identity.signature(object.name, object.args)
  local exact = latest_interrupted_match(current_id, function(candidate)
    return tool_identity.signature(candidate.name, candidate.args) == signature
  end)
  if exact then
    return exact
  end

  -- Some Pi RPC permission flows emit the final tool result under a fresh
  -- explicit id without repeating the original tool arguments. In that shape
  -- the stable signature is unavailable, but the result still belongs to the
  -- latest unfinished tool of the same name that was followed by a permission
  -- prompt. Render it as a result continuation instead of a second top-level
  -- "Tool" block.
  if not args_missing(object.args) then
    return nil
  end
  local object_name = tostring(object.name or 'tool')
  return latest_interrupted_match(current_id, function(candidate)
    if object_name == 'tool' then
      return true
    end
    return tostring(candidate.name or 'tool') == object_name
  end)
end

local function matching_anonymous_tool_id(event)
  local latest_id
  local latest_line = -1
  for id, object in pairs(state.render.tool_objects or {}) do
    if is_anonymous_tool_id(id) and tool_event_matches_object(event, object) then
      local block = state.render.tool_blocks and state.render.tool_blocks[id]
      local line = block and block.start_line or 0
      if line >= latest_line then
        latest_id = id
        latest_line = line
      end
    end
  end
  return latest_id
end

local function tool_id_from_event(event)
  local id = explicit_tool_id(event)
  if id then
    return id
  end

  local matched = matching_anonymous_tool_id(event)
  if matched then
    return matched
  end

  state.render.anonymous_tool_counter = (state.render.anonymous_tool_counter or 0) + 1
  return '__anonymous_tool_' .. tostring(state.render.anonymous_tool_counter)
end

function M.object_from_event(event)
  local id = tool_id_from_event(event)
  state.render.tool_objects = state.render.tool_objects or {}
  local object = state.render.tool_objects[id]
  local created = false
  if not object then
    object = { id = id, name = tool_event_name(event) }
    state.render.tool_objects[id] = object
    created = true
  end
  if tool_event_has_name(event) or not object.name then
    object.name = tool_event_name(event) or object.name or 'tool'
  end
  if event.args ~= nil then
    object.args = event.args
  end
  return id, object, created
end

return M
