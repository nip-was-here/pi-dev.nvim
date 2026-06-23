# 8. Use compatibility modules for extension-specific UI

Date: 2026-06-18

## Status

Accepted

## Context

Pi RPC exposes a generic extension UI protocol for `select`, `confirm`, `input`, `editor`, notifications, status widgets, and related methods. Protocol-level handling is enough for unknown extensions, but some extensions have recognizable semantics that need better native UX.

`@gotgenes/pi-permission-system` uses generic select and follow-up input requests for permission decisions around tools, bash commands, MCP targets, skills, paths, and external directory access. Those prompts need concise summaries and stable answer handling without polluting the generic extension UI adapter.

## Decision

Keep extension-specific behavior in compatibility modules under `lua/pi-dev/compat/`.

The generic extension UI handler first offers a request to enabled compatibility modules. If none claim it, it handles the request using protocol-level generic behavior.

For `@gotgenes/pi-permission-system`, detect permission selects by title/options shape and render a permission-specific interaction:

- show a short command/tool/path/external-directory summary in the interaction surface;
- return exact original option values in `extension_ui_response`;
- mirror request context to the chat surface as a bounded permission object whose header includes the same short summary;
- do not duplicate selectable answer options in the chat surface when they already live in the interaction surface;
- render long quoted request targets, such as bash commands and MCP targets, in fenced blocks instead of embedding them inside prose;
- fold answered permission objects under their `#### Permission request: ...` header so the decision stays visible and details remain available;
- summarize denial reasons in the permission header instead of rendering noisy denial-only tool output;
- handle follow-up denial reasons through the separate text interaction surface;
- avoid user-facing package/repository names for the permission extension;
- depend only on observed public UI strings/protocol shape, not extension internals.

Compatibility modules are configurable and can be disabled per module.

## Consequences

The generic RPC UI adapter stays protocol-focused while richer UX for known extensions evolves independently.

String-shape detection remains a compatibility risk. Compatibility modules must read defensively, fail open to generic handling where possible, and be covered by focused smoke tests.
