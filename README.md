# pi-dev.nvim

Use Pi.dev from native Neovim buffers.

`pi-dev.nvim` is a Lua-first, RPC-first Neovim frontend for Pi.dev. It starts
`pi --mode rpc`, renders streamed Pi conversations and tool activity in native
editor surfaces, and keeps concurrent Pi work isolated in branch-bound RPC
runtimes.

> [!WARNING]
> `pi-dev.nvim` is an early RPC-first MVP. It is intended to be usable, but the
> Pi RPC protocol and parts of this plugin UI may still change before the first
> major release.

For the complete manual, run `:help pi-dev`. Durable architecture decisions live
in [`doc/adr`](doc/adr).

## Requirements

- Neovim >= 0.10.
- Pi CLI available as `pi` on `$PATH`, or configured through `exec.bin`.
- Pi RPC support through `pi --mode rpc`.
- Optional: [`render-markdown.nvim`](https://github.com/MeanderingProgrammer/render-markdown.nvim)
  for richer Markdown rendering in the output surface.

Install and configure Pi.dev first:

```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
# or
curl -fsSL https://pi.dev/install.sh | sh
```

Then authenticate Pi in a terminal (`pi`, then `/login`) or configure a
supported provider API key. Confirm that RPC mode starts:

```sh
pi --mode rpc
```

Run `:checkhealth pi-dev` after installing the plugin.

## Installation

For lazy.nvim, the default setup is just the repository name:

```lua
'nip-was-here/pi-dev.nvim'
```

No explicit setup call is required for the default configuration. See
[Configuration](#configuration) for customization.

## Quick start

1. Install the plugin and make sure `pi` is available.
2. Run `:checkhealth pi-dev`.
3. Open the Pi panel with `:PiDev` or `<leader>ag`.
4. Type a prompt in the lower Pi input window.
5. Submit with insert-mode `<C-s>` or normal-mode `<CR>`.

If Pi is already processing a turn, submitting normal input sends steering text
instead of starting a second prompt.

## How the UI is organized

The Pi panel is a native Neovim layout. By default it opens on the right; a
bottom layout is also configurable.

- **Output surface**: conversation, restored session history, Pi responses, tool
  output, service notices, errors, and large tree/waiting/subagent views.
- **Input surface**: editable prompt buffer for normal user messages.
- **Interaction surface**: transient UI for permissions, selects, text/editor
  prompts, model/session controls, tree navigation, and waiting-branch
  navigation.
- **Status separator**: non-focusable chrome between output and lower surfaces.
  It shows compact state (`run`, `idle`, `wait`, `load`, etc.) plus metrics such
  as cost, tokens, context, and model.

Hiding the panel does not stop active RPC runtimes. Abort asks Pi to cancel the
current operation while keeping the runtime attached when possible, and clears
active permission or extension interaction prompts for that runtime. Stop/quit
kills the current branch runtime and discards its volatile runtime-local state.
`<C-W>=` restores the configured right-panel width; ordinary manual resizing is
preserved.

## Commands and keymaps

| Action | User command | Default key | Slash/input shortcut |
| --- | --- | --- | --- |
| Toggle UI / start RPC on first use | `:PiDev` | `<leader>ag` | - |
| Start RPC and show UI | `:PiDevOpen` | - | - |
| Hide Pi windows without stopping RPC | `:PiDevHide` | `<leader>aq` | - |
| Prompt via `vim.fn.input()` / command args | `:PiDevPrompt {prompt}` | `<leader>ap` | - |
| Focus Pi input buffer | `:PiDevFocus` | `<leader>ai` | - |
| Cancel current Pi operation without stopping RPC | `:PiDevAbort` | `<leader>ac` | `<C-c>` in Pi windows |
| Kill current branch Pi RPC process | `:PiDevStopRpc` / `:PiDevQuit` | `<leader>aK` | `/stop-rpc`, `/stop`, `/quit` |
| Cycle to next running branch RPC | `:PiDevNextRpc` | `<leader>aa` | `/next-rpc`, `/cycle-rpc` |
| Cycle to previous running branch RPC | `:PiDevPrevRpc` | `<leader>aA` | `/prev-rpc`, `/previous-rpc` |
| Set root Pi session name | `:PiDevName [name]` | - | `/name [name]` |
| Show current session details | `:PiDevSession` | - | `/session` |
| Compact current Pi context | `:PiDevCompact [instructions]` | - | `/compact [instructions]` |
| Export current session to HTML | `:PiDevExport [path]` | - | `/export [path]` |
| Show plugin hotkeys/commands | `:PiDevHotkeys` | - | `/hotkeys` |
| Start a new Pi session and reset old-root runtimes | `:PiDevNewSession` | `<leader>an` | `/new` |
| Resume a current-directory session | `:PiDevResume` | `<leader>ar` | `/resume` |
| Pick a Pi model when idle/waiting | `:PiDevModel` | `<leader>am` | `/model` |
| Restart active RPC runtime and reload session context | `:PiDevReload` | `<leader>aR` | `/reload` |
| Open tree/fork navigation | `:PiDevTree` | `<leader>at` | `/tree` |
| Open waiting-input branch navigation | `:PiDevWaiting` | `<leader>aw` | `/waiting` |
| Open focused subagent buffer | `:PiDevSubagentOpen` | `<leader>a]` | `/subagent-open` |
| Return to parent buffer | `:PiDevSubagentParent` | `<leader>a[` | `/subagent-parent` |

Only the toggle key (`<leader>ag` by default) stays mapped while the Pi panel is
closed. Other `<leader>a*` plugin keymaps become active after the panel opens and
are removed again when it is hidden or closed.

See `:help pi-dev-commands`, `:help pi-dev-slash-commands`, and
`:help pi-dev-input` for full behavior.

## Sessions, branches, and runtimes

On first open, pi-dev.nvim loads the newest Pi JSONL session whose header `cwd`
matches Neovim's effective cwd. If none exists, it opens an empty chat surface;
the first user prompt creates the new Pi session through the normal prompt path.
Restored history is rendered in paced chunks so large sessions do not block the
editor.

A **branch-bound runtime** is one `pi --mode rpc` process attached to one Pi
session branch. The local **runtime pool** lets background branches continue
running or waiting while another branch is active. Background idle runtimes with
no volatile runtime-local state expire after `rpc.idle_timeout_ms` once another
runtime exists; the sole idle runtime stays attached until explicit kill, reload,
cwd/session reset, or Neovim exit.

Useful navigation flows:

- `/resume` lists current-directory root session trees, sorted by most recent
  interaction, and resumes the newest branch in the chosen root tree.
- `/tree` shows the root session tree, supports folding large branch histories,
  opens a collapsed branch's last visible step with Enter, can fork from user
  messages, and can navigate back to response rows.
- `/waiting` shows only branches with live/respondable extension UI state and
  reopens the pending/current/queued interaction after switching.

Switching to a different root session tree resets old-root runtimes. pi-dev.nvim
asks first when connected runtimes have active work, live/respondable
interactions, or unsent runtime-local drafts. `/new` follows the same reset rule.
Explicit `/reload` asks only when the active runtime has volatile runtime-local
state; inactive branch runtimes remain attached.

Subagent tool output stays compact in the parent chat. Put the cursor on a child
subagent block and run `:PiDevSubagentOpen` or press `<leader>a]` to inspect that
child in an isolated output buffer. `:PiDevSubagentParent` or `<leader>a[`
returns one level up.

## Extension compatibility

pi-dev.nvim handles generic Pi RPC extension UI requests natively when possible:
notifications, status/widget updates, confirmations, selects, input prompts,
editor prompts, and editor-text updates.

Compatibility layers are enabled by default for:

- `pi-subagents`: compact parent-chat summaries, nested subagent drill-down
  buffers, and permission mirroring back into the parent/root chat.
- `@gotgenes/pi-permission-system`: native permission prompts with folded
  permission details and elapsed wait time mirrored in the output surface.
- `pi-mcp-adapter`: native `/mcp` status, context-local direct-tool toggles, and
  RPC-mode OAuth URL rendering for `/mcp-auth`.

`/mcp` shows direct-tool status plus a best-effort auth column. `/mcp on
<server>` and `/mcp off [server]` are context-local. They reload the active
runtime with `MCP_DIRECT_TOOLS` instead of editing MCP configuration files.
Server-name lookup for native `/mcp*` commands is case-insensitive and accepts a
unique close match; completion offers configured server names for `/mcp on`,
`/mcp off`, and `/mcp-auth`. In multiline prompts, beginning-of-line `/mcp
on/off` lines act as directives and are removed before the remaining prompt is
sent.

Other Pi plugins that use the generic Pi RPC extension UI protocol may work
through generic native handling. Custom extension TUIs beyond that protocol are
not fully native yet.

See `:help pi-dev-extension-ui` and `:help pi-dev-mcp` for details.

## Lua API

The stable Lua entrypoint is small:

```lua
local pi_dev = require('pi-dev')
pi_dev.setup({})
pi_dev.toggle()
pi_dev.prompt('Explain this buffer')
```

Documented top-level methods on `require('pi-dev')` are the public convenience
API; see `:help pi-dev-lua-api` for the full list. The broader
`require('pi-dev').api` table is available for advanced integration and tests,
but it is not a stability promise until specific functions are documented as
public.

## Configuration

To customize options with lazy.nvim, use `opts`:

```lua
{
  'nip-was-here/pi-dev.nvim',
  opts = {
    exec = { bin = 'pi' },
    keymaps = {
      prefix = '<leader>a',
    },
  },
}
```

If your plugin manager does not call Lua `setup(opts)` automatically, set global
options before the plugin loads:

```lua
vim.g.pi_dev_nvim = {
  exec = { bin = 'pi' },
  keymaps = {
    prefix = '<leader>a',
  },
}
```

Calling `require('pi-dev').setup(opts)` manually is supported and re-applies
configuration, commands, and keymaps idempotently.

Common options:

| Option | Default | Description |
| --- | --- | --- |
| `exec.bin` | `'pi'` | Pi executable name/path, or argv table when a wrapper command is needed. |
| `exec.args` | `{ '--mode', 'rpc' }` | Arguments used to start Pi RPC mode. |
| `cwd` | `nil` | Working directory for Pi RPC and current-directory session matching; defaults to Neovim cwd. |
| `session_render.max_messages` | `100` | Number of restored messages to render; `0` or `false` renders all history. |
| `rpc.pool_size` | `8` | Maximum branch-bound runtimes; values above 8 are capped. |
| `rpc.idle_timeout_ms` | `180000` | Background idle runtime stop delay; `0` disables idle expiry. |
| `ui.position` | `'right'` | Panel position: `'right'` or `'bottom'`. |
| `ui.width` | `100` | Initial width of the right-side panel; manual resizes are preserved. |
| `ui.status_separator.enable` | `true` | Show the plugin-owned status separator between output and input panes. |
| `ui.statusline.enable` | `true` | Legacy alias for `ui.status_separator.enable`. |
| `keymaps.prefix` | `'<leader>a'` | Prefix used for default normal-mode mappings. |

For the complete option reference, including all defaults, see
`:help pi-dev-configuration`.

## Health and troubleshooting

Run:

```vim
:checkhealth pi-dev
```

The health provider checks Neovim version, Pi executable availability, RPC
command shape, whether the RPC command can be spawned and stays running, session
root existence, and optional Markdown renderer availability.

If the panel is open but behavior looks stale, try `/session` to inspect the
current runtime and `/reload` to restart RPC for the current branch/session
context.

## Development checks

Project checks are wired into `pre-commit`. With the hook installed,
`git commit` runs the public regression suite under `tests/` plus repository
formatting/documentation checks automatically.

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch names, commit messages, pull
request titles, and validation expectations.

## Markdown rendering

The output buffer uses Markdown filetype by default. For rich Markdown rendering:

```lua
{
  'MeanderingProgrammer/render-markdown.nvim',
  opts = {
    file_types = { 'markdown' },
  },
  ft = { 'markdown' },
}
```

The plugin loads without this optional dependency.

## License

This project is licensed under the Apache License 2.0 - see the
[LICENSE](./LICENSE) file for details.
