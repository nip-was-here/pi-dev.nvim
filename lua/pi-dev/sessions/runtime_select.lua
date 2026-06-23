-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local state = require('pi-dev.state')

local M = {}

function M.has_branch_attachment(runtime)
  return runtime
    and ((runtime.session_file and runtime.session_file ~= '')
      or (runtime.branch_root and runtime.branch_root ~= '')
      or (runtime.branch_entry_id and runtime.branch_entry_id ~= ''))
end

function M.cycle_candidates()
  state.recheck_rpc_runtimes()
  local runtimes = {}
  for _, runtime in pairs(state.rpc.runtimes or {}) do
    if state.is_job_running(runtime) and M.has_branch_attachment(runtime) then
      table.insert(runtimes, runtime)
    end
  end
  table.sort(runtimes, function(a, b)
    return tostring(a.key or '') < tostring(b.key or '')
  end)
  return runtimes
end

function M.waiting_count(has_waiting_interaction)
  state.recheck_rpc_runtimes()
  local count = 0
  for _, runtime in pairs(state.rpc.runtimes or {}) do
    if has_waiting_interaction(runtime) then
      count = count + 1
    end
  end
  return count
end

return M
