# 4. Use branch-bound Pi RPC runtimes for multitasking

Date: 2026-06-18

## Status

Accepted

## Context

Users can navigate or fork several Pi session branches from one Neovim instance. A previous branch may still be streaming, waiting for permission input, or idle-but-reusable while the user inspects another branch. A single global RPC state would mix branch-local streams, queues, pending extension UI, and statuses.

The visible Pi panel has only one active output/input/interaction/status set, so inactive branches must not overwrite the active UI.

## Decision

Maintain a branch-bound Pi RPC runtime pool.

A Pi RPC runtime owns one `pi --mode rpc` job plus its request table, stream buffer, branch/session metadata, status, metrics, idle timer, pending extension UI request, runtime-local interaction queue, normal Pi input draft, and extension editor text. A branch-bound runtime is associated with one Pi session branch. The active branch points the visible Pi panel at one runtime; inactive runtimes may keep streaming, waiting, idling, or preserving their own drafts and queued interactions in the background.

The pool is configured by `rpc.pool_size`, defaulting to 8 and capped at 8. If switching or forking needs another runtime and the pool is exhausted, show a user-visible error telling the user to stop an idle branch RPC before switching.

Users can cancel the current operation through `:PiDevAbort`, `<leader>ac`, or `<C-c>` in Pi windows. Cancel requests use Pi's abort RPC message for the active Pi operation while keeping the current runtime attached when possible. It does not locally discard visible or queued extension interactions; if Pi cancels them, the normal RPC/event path clears or updates them.

Users can kill the current branch runtime process through `:PiDevStopRpc`, `<leader>aK`, `/stop-rpc`, `/stop`, or `/quit`. These explicit kill/stop commands do not ask for confirmation. Stopping a runtime closes any visible extension-origin interaction owned by that runtime and discards its runtime-local input draft, editor text, pending request, saved current interaction, and queued interactions.

Users can cycle through already-running attached branch runtimes through `:PiDevNextRpc`, `<leader>aa`, `/next-rpc`, or `/cycle-rpc`, and cycle in reverse through `:PiDevPrevRpc`, `<leader>aA`, `/prev-rpc`, or `/previous-rpc`. Cycling never starts a new runtime; it activates the adjacent connected branch runtime in the requested direction, re-renders that branch, and reopens its pending interaction if one exists.

After successful work ends, keep an idle runtime alive for `rpc.idle_timeout_ms` (default 180000 ms / 3 minutes). Expire only background idle runtimes with no volatile runtime-local state, and only when at least one other runtime is connected. A runtime with unsent Pi input draft, extension editor text, or live/respondable interaction state is not eligible for idle expiry. A sole idle runtime remains attached until explicit kill/stop, reload, cwd/session reset, or `VimLeavePre`. Setting the timeout to 0 disables idle expiry.

Only the active runtime may render conversation events, stderr, permission requests, queued interactions, or extension UI into the visible Pi panel. Inactive extension UI requests, runtime-local interaction queues, and runtime-local input/editor drafts are retained on their runtime and shown when the user returns to that branch.

The status separator summarizes the pool when useful with compact wording such as `running 2/3, waiting input 1`. The running denominator counts connected non-error work slots: running, waiting-input, and idle runtimes. Runtimes blocked on user input are also counted separately as `waiting input`. Avoid colon-separated, bracketed, or parenthesized aggregate counts.

Switching or resuming to a different root session tree resets the old runtime pool. If any connected runtime has active work, live/respondable interaction state, or unsent runtime-local drafts, ask for confirmation before that reset. Confirming stops all affected Pi RPC runtimes, discards their volatile runtime-local state, and starts one fresh RPC for the selected session. Idle connected runtimes with empty drafts and no live/respondable interaction state do not require confirmation, but they are still reset on different-root switches so stale branch runtimes from the previous root cannot remain attached. Moving inside the same root session tree is non-destructive and does not require confirmation. Tree/fork navigation routes through the same guard.

Creating a new session (`/new` / `:PiDevNewSession`) follows the same root-context reset rule before creating the fresh root session.

Explicit reload (`/reload` / `:PiDevReload`) is scoped to the active runtime. If the active runtime has volatile runtime-local state, ask for confirmation before stopping and reloading it. Inactive branch runtimes do not block active-runtime reload and remain attached.

Model changes are scoped to the active runtime. Allow model changes while the active runtime is idle or waiting on input, but reject them during active streaming, tool, compaction, or retry work so a model switch cannot be applied ambiguously mid-turn.

## Consequences

Users can keep several branch conversations alive without losing pending permission input or stream state. Background branches do not steal the visible Pi panel.

The implementation must keep runtime state isolated, route rendering only from the active runtime, track idle expiry, and make destructive root-session switches explicit.
