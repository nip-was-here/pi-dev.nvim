# 2. Use Lua-first dependency-light Neovim plugin architecture

Date: 2026-06-18

## Status

Accepted

## Context

`pi-dev.nvim` integrates Pi.dev with native Neovim commands, keymaps, buffers, windows, jobs, completion, and health checks. Neovim's plugin API is Lua-first, and the plugin should remain inspectable and easy to install before the first major release.

Comparable Neovim plugins may inform user-experience trade-offs. They are not codebases to copy from: Pi.dev has its own RPC protocol, session model, extension UI, and compatibility needs.

## Decision

Implement the plugin as a Lua-first Neovim plugin:

- `plugin/pi-dev.lua` is the lightweight loader that applies `vim.g.pi_dev_nvim` defaults.
- `lua/pi-dev/init.lua` is the public API entrypoint with `setup(opts)` and command/keymap registration.
- Internal modules under `lua/pi-dev/` own configuration, RPC transport, runtime state, sessions, UI, rendering, status, completion, health, and compatibility layers.
- Extension-specific behavior belongs under `lua/pi-dev/compat/`.

Use built-in Neovim APIs for commands, buffers, jobs, windows, keymaps, health, and completion. Do not add runtime dependencies unless a later ADR accepts them. Optional integrations, such as `render-markdown.nvim`, must remain optional.

Expose plugin behavior through both Neovim user commands and callable Lua functions. The stable public Lua surface is intentionally small: `require("pi-dev").setup(opts)` plus documented top-level convenience methods returned from `require("pi-dev")`. The broader `require("pi-dev").api` table remains an advanced integration surface and is not a stability promise until specific functions are documented as public.

Use comparable implementations only for design inspiration. Do not blindly copy external plugins or revive obsolete prototype implementation patterns.

## Consequences

The plugin works in minimal Neovim environments and can be installed by standard plugin managers. The code remains small enough to audit while still allowing native UI, RPC transport, session navigation, and extension compatibility to evolve independently.

Large future integrations must justify their dependency cost through an ADR.
