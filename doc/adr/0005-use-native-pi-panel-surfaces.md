# 5. Use native Pi panel surfaces

Date: 2026-06-18

## Status

Accepted

## Context

`pi-dev.nvim` needs a stable native Neovim layout for conversation output, prompt input, transient extension interactions, and runtime status. The desired UX is editor-native, not a clone of Pi's terminal UI.

The Pi panel contains separate concerns that should not overwrite each other: user-authored prompt text, transient extension/UI interactions, and operational status chrome.

## Decision

Use a native Pi panel with distinct surfaces:

- `pi-dev://chat` is the read-oriented chat surface for conversation, tool output, service notices, restored session history, and large tree/waiting navigators.
- `pi-dev://input` is the editable plain-text input surface for user prompts.
- `pi-dev://interaction` is the transient lower-pane interaction surface for permissions, selects, text interactions, and compact model/session controls.
- `pi-dev://status-separator` is non-focusable status separator chrome anchored between the output and lower surfaces.

The default layout is a right-side split with chat above and input/interaction below. A bottom layout remains configurable. Configured width and lower-pane height are initial layout defaults; after the panel opens, user-driven split resizes are preserved instead of being snapped back during resize or chrome refreshes.

The lower window swaps between the input and interaction surfaces. Draft input is preserved while an interaction is pending and restored after the interaction resolves. Normal Pi input drafts and extension editor text are stored separately per branch-bound runtime, so switching branches or opening overlays does not mix drafts across runtimes. Active editor interaction edits are snapshotted when switching away from a runtime and restored when returning. Select/permission interaction surfaces are read-only while pending; free-form text interactions are editable only where text is requested. Short generic input interactions may submit with normal `<CR>` or `<C-s>`; generic editor interactions are multiline and submit only through explicit `<C-s>` so normal-mode `<CR>` does not accidentally send an editor response. Extension `set_editor_text` never overwrites normal Pi input: it updates the active editor interaction when one is open, otherwise stores editor text on the active runtime for the next editor interaction.

Active user selection surfaces such as `/tree` or `/waiting` take priority over later permission prompts. Tree/waiting navigators render in the larger chat surface rather than the lower input pane, while preserving the lower input buffer and any draft text. Lower-priority permission interactions are queued on the active branch-bound runtime and shown only after that runtime's current interaction closes. Queued interactions from another runtime must not appear until that runtime becomes active. Extension-origin interactions are deduplicated by request ID across the visible interaction, saved current interaction, and runtime-local queue.

Pi panel windows are protected with `winfixbuf` where available. If a file picker or other plugin replaces a Pi-owned window buffer, the plugin restores the correct Pi buffer and redirects the foreign file buffer to the last known normal file window.

The status separator is not the Neovim statusline and not an editable pane. It shows operational state on the left plus compact metrics such as cost, tokens, context, and model when known. It stays free of conversation role labels and thinking/reasoning labels; those belong in the chat surface. Tool execution may show concise concrete work labels, but message-role and assistant-phase events keep the separator calm.

Pi-owned window titles and winbars should fit their pane width; long session titles are truncated with an ellipsis.

## Consequences

The plugin has predictable editor-native surfaces for chat, tools, input, status, permissions, session navigation, and branch multitasking. Prompt drafts survive permission/select flows, and status remains visual chrome rather than user-editable content.

The UI layer must explicitly guard buffers, preserve user sizing, prioritize interactions, and tolerate partially known runtime metrics.
