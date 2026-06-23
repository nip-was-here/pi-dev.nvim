-- SPDX-License-Identifier: Apache-2.0
-- Copyright (c) 2026 nip
local state = require('pi-dev.state')

local M = {}

-- Keep live assistant text near-frame-rate responsive without going back to
-- one-buffer-write/one-scroll per token.
local LIVE_FLUSH_DELAY_MS = 16
local LIVE_FLUSH_MAX_BYTES = 4096

function M.cancel_timer()
  state.render.live_flush_token = (state.render.live_flush_token or 0) + 1
  state.render.live_flush_scheduled = false
end

function M.take_pending()
  local pending = state.render.live_pending_segments or {}
  if #pending == 0 then
    M.cancel_timer()
    return {}
  end
  M.cancel_timer()
  state.render.live_pending_segments = {}
  state.render.live_pending_bytes = 0
  return pending
end

function M.enqueue(kind, text)
  text = tostring(text or '')
  if text == '' then
    return false
  end
  kind = kind or 'text'
  state.render.live_pending_segments = state.render.live_pending_segments or {}
  local last = state.render.live_pending_segments[#state.render.live_pending_segments]
  if last and last.kind == kind then
    last.text = last.text .. text
  else
    table.insert(state.render.live_pending_segments, { kind = kind, text = text })
  end
  state.render.live_pending_bytes = (state.render.live_pending_bytes or 0) + #text
  return state.render.live_pending_bytes >= LIVE_FLUSH_MAX_BYTES
end

function M.schedule_flush(flush_callback)
  if state.render.live_flush_scheduled then
    return
  end
  state.render.live_flush_scheduled = true
  local token = (state.render.live_flush_token or 0) + 1
  state.render.live_flush_token = token
  vim.defer_fn(function()
    if state.render.live_flush_token ~= token then
      return
    end
    state.render.live_flush_scheduled = false
    flush_callback()
  end, LIVE_FLUSH_DELAY_MS)
end

return M
