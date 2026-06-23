# 3. Use Pi RPC as the primary integration transport

Date: 2026-06-18

## Status

Accepted

## Context

Pi supports multiple run modes, but a native Neovim frontend needs structured bidirectional control over prompts, steering and follow-up queues, aborts, sessions, model changes, streamed events, tool execution, and extension UI requests. Terminal or TUI scraping would make these features fragile.

## Decision

Use `pi --mode rpc` as the primary integration transport.

The transport uses Neovim jobs and strict LF-delimited JSONL parsing. Requests are correlated by ID, streamed events are dispatched through the plugin event bus, and user commands, keymaps, slash commands, and Lua API calls route through a shared API layer.

RPC state belongs to Pi RPC runtimes. Each runtime owns its job id, request table, stream buffer, status, metrics, current session metadata, idle timer, and pending extension UI state.

Slash-command completion queries RPC `get_commands` when available, merges returned commands with local integration commands, removes duplicates, and keeps local fallbacks usable when RPC command discovery is unavailable. Completion also supports local context forms such as `/skill:`, `@file`, `/export` paths, and shell command forms.

Reloads and compatibility settings that require a restart must restart the intended runtime path with the effective environment overrides, then restore the current session or branch before continuing queued user input. MCP direct-tool context changes are one such restart source.

Interactive terminal mode is not the primary integration path.

## Consequences

The plugin can render structured Pi events natively without terminal scraping. It can support prompts, steering, follow-up, abort, sessions, model changes, queue and retry events, compaction, tool progress, extension UI, and compatibility modules.

Pi extensions that use `ctx.ui.confirm`, `select`, `input`, `editor`, `notify`, `setStatus`, `setWidget`, `setTitle`, or `setEditorText` are handled through the RPC extension UI protocol.

The transport/API layer must absorb protocol changes without leaking protocol details throughout the UI.
