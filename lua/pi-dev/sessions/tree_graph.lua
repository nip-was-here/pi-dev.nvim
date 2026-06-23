-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local M = {}

function M.tokens(graph)
  local tokens = {}
  for token in tostring(graph or ''):gmatch('[|*]') do
    table.insert(tokens, token)
  end
  return tokens
end

function M.star_lane(graph)
  for lane, token in ipairs(M.tokens(graph)) do
    if token == '*' then
      return lane
    end
  end
  return nil
end

function M.connector_line(parent_graph, child_graph)
  if not parent_graph or not child_graph or parent_graph == child_graph then
    return nil
  end
  local parent_lane = M.star_lane(parent_graph)
  local child_lane = M.star_lane(child_graph)
  if not parent_lane or not child_lane or child_lane <= parent_lane then
    return nil
  end
  return string.rep('| ', math.max(0, parent_lane - 1)) .. '|\\ '
end

function M.return_connector_line(previous_graph, current_graph)
  if not previous_graph or not current_graph or previous_graph == current_graph then
    return nil
  end
  local previous_tokens = M.tokens(previous_graph)
  local current_tokens = M.tokens(current_graph)
  if #previous_tokens == 0 or #current_tokens == 0 then
    return nil
  end
  local previous_lane = M.star_lane(previous_graph)
  local current_lane = M.star_lane(current_graph)
  if not previous_lane or not current_lane then
    return nil
  end
  if #previous_tokens <= #current_tokens and previous_lane <= current_lane then
    return nil
  end
  return string.rep('| ', math.max(0, current_lane - 1)) .. '|/ '
end

function M.branch_folds(messages, opts)
  opts = opts or {}
  local protected_ids = opts.protected_ids or {}
  local auto_close_leaf = opts.auto_close_leaf == true
  local index_by_id = {}
  local children_by_parent = {}
  local root_children = {}
  for index, message in ipairs(messages or {}) do
    if message.entryId then
      index_by_id[tostring(message.entryId)] = index
    end
  end
  for _, message in ipairs(messages or {}) do
    if message.entryId then
      local entry_id = tostring(message.entryId)
      local parent_id = message.displayParentId or message.parentId
      local parent_index = parent_id and index_by_id[tostring(parent_id)]
      if parent_index then
        local key = tostring(parent_id)
        children_by_parent[key] = children_by_parent[key] or {}
        table.insert(children_by_parent[key], entry_id)
      else
        table.insert(root_children, entry_id)
      end
    end
  end

  local branch_roots = {}
  for _, entry_id in ipairs(root_children) do
    branch_roots[entry_id] = true
  end
  for _, children in pairs(children_by_parent) do
    if #children > 1 then
      for _, entry_id in ipairs(children) do
        branch_roots[entry_id] = true
      end
    end
  end

  local branch_off_memo = {}
  local branch_off_visiting = {}
  local function has_branch_off(entry_id)
    local key = tostring(entry_id)
    if branch_off_memo[key] ~= nil then
      return branch_off_memo[key]
    end
    if branch_off_visiting[key] then
      return false
    end
    branch_off_visiting[key] = true
    local children = children_by_parent[key] or {}
    local result = #children > 1
    if not result then
      for _, child_id in ipairs(children) do
        if has_branch_off(child_id) then
          result = true
          break
        end
      end
    end
    branch_off_visiting[key] = nil
    branch_off_memo[key] = result
    return result
  end

  local protected_memo = {}
  local protected_visiting = {}
  local function contains_protected_entry(entry_id)
    local key = tostring(entry_id)
    if protected_memo[key] ~= nil then
      return protected_memo[key]
    end
    if protected_visiting[key] then
      return false
    end
    protected_visiting[key] = true
    local result = protected_ids[key] == true
    if not result then
      for _, child_id in ipairs(children_by_parent[key] or {}) do
        if contains_protected_entry(child_id) then
          result = true
          break
        end
      end
    end
    protected_visiting[key] = nil
    protected_memo[key] = result
    return result
  end

  local memo = {}
  local visiting = {}
  local function last_descendant_index(entry_id)
    local key = tostring(entry_id)
    if memo[key] then
      return memo[key]
    end
    if visiting[key] then
      return index_by_id[key] or 0
    end
    visiting[key] = true
    local last = index_by_id[key] or 0
    for _, child_id in ipairs(children_by_parent[key] or {}) do
      last = math.max(last, last_descendant_index(child_id))
    end
    visiting[key] = nil
    memo[key] = last
    return last
  end

  local folds = {}
  for entry_id in pairs(branch_roots) do
    local branch_start_index = index_by_id[entry_id]
    local start_index = branch_start_index and (branch_start_index + 1) or nil
    local end_index = last_descendant_index(entry_id)
    if start_index and end_index and end_index > start_index then
      local auto_closed = auto_close_leaf and not has_branch_off(entry_id) and not contains_protected_entry(entry_id)
      table.insert(folds, {
        start_index = start_index,
        end_index = end_index,
        closed = auto_closed == true,
        auto_closed = auto_closed,
      })
    end
  end
  table.sort(folds, function(a, b)
    local a_size = (a.end_index or 0) - (a.start_index or 0)
    local b_size = (b.end_index or 0) - (b.start_index or 0)
    if a_size == b_size then
      return (a.start_index or 0) < (b.start_index or 0)
    end
    return a_size > b_size
  end)
  return folds
end

return M
