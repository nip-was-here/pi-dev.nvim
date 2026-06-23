# 9. Support MCP adapter status and context-local direct-tool toggles

Date: 2026-06-18

## Status

Accepted

## Context

The `pi-mcp-adapter` extension registers `/mcp` commands and can promote MCP servers or tools to direct Pi tools. In the native Neovim frontend, users need MCP status and per-context direct-tool toggles without opening Pi's custom TUI panel or mutating shared MCP config files.

Direct tools are registered at Pi extension startup, so changing the effective direct-tool set may require restarting the relevant Pi RPC runtime while preserving the current session/branch context.

## Decision

Use a Neovim-side MCP compatibility module under `lua/pi-dev/compat/`, enabled by default through `compat.mcp_adapter.enable`.

Mirror the adapter's config discovery order:

1. `~/.config/mcp/mcp.json`
2. `<Pi agent dir>/mcp.json`
3. `.mcp.json`
4. `.pi/mcp.json`

Expose `/mcp` and `/mcp status` as native status renderers listing configured servers, whether each is enabled for direct tools in this Neovim Pi context, and a best-effort local auth status. Render status as a compact Markdown table with MCP name, effective status, and auth status. Effective status is `on` for direct tools loaded, `lazy` for configured but not direct, and `off` for disabled in MCP config. Auth status is derived without exposing credential contents from bearer-token config and known current hashed plus legacy pi-mcp-adapter OAuth token files.

Parse submitted user input for beginning-of-line `/mcp on <server>` and `/mcp off [server]` directives before sending the remaining prompt to Pi. Multiple directives may appear in one message; directive lines are removed from the prompt. Server name lookup is case-insensitive and may accept a unique close server-name match; the `/mcp`, `on`, `off`, and `status` command words are case-insensitive in the native compatibility layer.

Keep `/mcp on/off` context-local by maintaining a Neovim-side effective direct-server set and passing it to restarted Pi RPC through `MCP_DIRECT_TOOLS`. Use `MCP_DIRECT_TOOLS=__none__` for `/mcp off` with no server. Do not write `directTools` changes into `.mcp.json`, `.pi/mcp.json`, or Pi global MCP config files.

If a direct-tool context change is requested during active work, defer it and do not send the remaining prompt. If the active runtime is idle or waiting, reload the active runtime with the same active-runtime destructive confirmation used by `/reload`, then switch back to `state.session.current_file` before sending the remaining prompt. If the reload is cancelled, roll back the MCP direct-tool override and do not send the remaining prompt under the changed MCP context.

Unsupported `/mcp ...` subcommands remain available to Pi itself when they are not handled by the native compatibility layer. `/mcp-auth <server>` remains an adapter command, but the native compatibility layer canonicalizes configured server names before forwarding it. The Neovim RPC transport recognizes the adapter's non-JSON stdout line `MCP Auth: Open this URL to authenticate ...` plus the following authorization URL and renders it as a native chat notice with manual `mcp({ action: "auth-complete", ... })` instructions instead of surfacing protocol-error noise.

## Consequences

`/mcp` status works in the native panel, and users can enable or disable MCP direct tools inline with prompts without changing standalone Pi TUI configuration.

The compatibility module must stay aligned with `pi-mcp-adapter` config precedence and `MCP_DIRECT_TOOLS` semantics. The RPC transport also has a narrowly scoped adapter stdout exception for MCP OAuth URLs; other non-JSON stdout still remains a protocol error so genuine RPC framing regressions are visible.
