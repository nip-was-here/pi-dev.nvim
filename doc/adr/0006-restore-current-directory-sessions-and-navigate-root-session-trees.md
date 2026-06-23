# 6. Restore current-directory sessions and navigate root session trees

Date: 2026-06-18

## Status

Accepted

## Context

Pi sessions are persisted as JSONL files with session headers, cwd metadata, timestamps, message entries, and branch/session relationships. The Neovim UI should restore the right current-directory session quickly without blocking on large transcripts.

Users also need to navigate and fork within a full root session tree, not just the current branch file.

## Decision

On opening the Pi UI, load the newest current-directory session: a Pi session whose header `cwd` matches the effective Neovim cwd. If no current-directory session exists, open an empty chat surface and let the first user prompt create the new Pi session through the normal prompt path instead of issuing an eager `new_session` RPC request. The effective cwd respects Neovim's current working directory behavior, not only the process/global cwd.

When `DirChanged` fires and Pi is running without volatile runtime-local state, stop old idle Pi RPC runtimes, reload the current-directory session list, and restore that cwd's newest session. If no current-directory session exists for the new cwd, do not show a stop/restart warning; show the empty chat surface and let the first user prompt create the new Pi session. If any connected runtime has active work, live/respondable interaction state, or unsent runtime-local drafts, do not stop runtimes automatically from the autocmd; warn that reload was deferred so the user can finish or explicitly stop that state before adopting the new cwd.

Rank candidate sessions by activity time: the maximum of file mtime and the timestamp of the latest session entry. Read only a bounded tail of each candidate file when finding the latest timestamp.

For restored-history display, read the session file directly instead of using a full RPC `get_messages` call. Render only a configurable recent page and pace it in deferred chunks. Pi's live context is still switched through RPC `switch_session`; display paging does not truncate agent context.

Default display pacing is:

- `session_render.max_messages = 100` (render the latest 100 restored messages by default)
- `session_render.include_tool_results = true`
- `session_render.max_text_chars = 8000`
- `session_render.chunk_size = 100`
- `session_render.chunk_delay_ms = 0`
- `session_render.chunk_budget_ms = 8`

Starting a new render invalidates pending old chunks. Restored-history chunks render within an approximate per-tick work budget so large chat surfaces stay responsive without deliberately pacing every message. Setting `session_render.max_messages` to `0` or `false` disables the restored-history message-count limit. Restored timestamps are read from common JSONL fields, parsed as timezone-aware values when possible, and displayed in the host local timezone.

The native chat title summarizes branch context as `Pi chat: <branch point> | <latest user>` instead of using only the in-buffer markdown heading. The branch-point part uses the first meaningful user chat prompt after a `parentSession` branch point when available, falling back to the first meaningful user chat prompt in the session. Response text must not become the chat title. When the latest user message for that branch differs from that branch-point summary, the latest-user part is appended after `|`. Both parts use compact skill-call labeling where applicable and are truncated independently; `ui.session_title_branch_fraction` controls the fraction of title width reserved for the branch-point part, defaulting to `0.6`.

Resume (`/resume`) groups current-directory session files by root session tree in the large native chat interaction and renders only root rows. Each root row is selectable, shows branch count followed by `Last: <last interaction time>`, hides internal helper run sessions, and is fitted into the available text width. Rows are sorted by most recent interaction, and selecting a root resumes the newest branch in that root tree. This keeps branch-heavy histories responsive and avoids delegating large session lists to `vim.ui.select` implementations that may block the editor.

Tree navigation (`/tree`) uses the root session file plus known descendants or shared-prefix branch files for the same cwd. It follows `parentSession` links and falls back to shared message IDs when needed, keeping the selector anchored to the whole session tree while still refreshing new messages appended to the active branch session file. After choosing or forking any tree point, the UI remembers the original root session file so reopening `/tree` still shows the whole session tree.

Response entries are labeled with meaningful answer text. Tool-only response turns are skipped. If the last real step in a branch is a permission request with no later visible user/response pair, show that terminal permission request so waiting branches are visible.

Provide `/waiting` as a waiting-selectable tree view: waiting rows and their ancestor tree rows remain visible as branch context, but unrelated non-waiting sub-branches are pruned. Only rows whose attached branch runtime has live/respondable waiting interaction state are selectable. Waiting interaction state includes a pending extension UI request, a saved visible extension interaction, or a runtime-local queued interaction. If no waiting rows exist, show only a notification and do not open or leave a waiting interaction buffer. Restored JSONL-only permission records remain history artifacts and are not actionable waiting rows. Selecting a waiting row switches to that runtime and reopens its pending/current/queued interaction instead of forking.

Render `/tree` and `/waiting` entries as plain-text interactions in the large chat/session surface, not in the small lower input pane, so large branch trees are navigable without cramped wrapping. Opening the tree must leave `pi-dev://input` visible and preserve any draft input. Visual numeric prefixes are omitted. Cursor movement, search, Enter, and selection shortcuts remain available; `/waiting` initially focuses the first/current waiting row rather than a non-waiting context row. Rows use a compact git-log-like branch prefix plus connector rows. Branch detail folds start after the first visible row in each branch, so the branch's first message stays visible while later rows may collapse; folded text uses the last row inside the folded block instead of repeating the branch's first row. Branch ordering should preserve topology, order sibling branches at every fork point by latest visible interaction time descending, ignore hidden tool-result and other non-tree rows for recency, use active-branch membership only as a tie-breaker, and keep each branch's linear continuation together.

Each visible user/response row includes a human timestamp. When opened, the selector focuses the current visible session position and honors native cursor movement/search by syncing selection from the cursor before Enter submits.

User-message selections use Pi RPC `fork` semantics so the selected prompt can be edited. Response-row selections do not fill `Pi input`; they navigate to the selected response by switching to the right branch/root or preparing a branch file. When tree selection creates or switches to a branch session file, set that file's Pi session display name from the first meaningful user message after the parent-session branch point once that message exists; do not name the branch from the selected pre-branch row. This makes branch files recognizable in Pi TUI `/resume` instead of showing only the root session name.

Before selecting an arbitrary user tree entry, switch Pi RPC back to that root session file so the entry ID exists in Pi's active `SessionManager`; then render the active fork context via RPC `get_messages` rather than re-reading the whole session file. Non-waiting tree-selected branch rendering may cap the general restored-history profile with `tree.branch_render.*` defaults (`max_messages = 30`, `include_tool_results = false`, `max_text_chars = 1200`) so large tool-heavy branches open quickly while Pi keeps the full branch context internally; lower user-configured `session_render.*` limits still win. Other RPC `get_messages` renders continue to use the general `session_render.max_messages`, tool-result filtering, text truncation, and chunk pacing profile unless they explicitly opt into a narrower branch display profile.

## Consequences

Opening or navigating large sessions should not freeze Neovim. Users see recent context quickly while Pi retains full session context.

Tree and waiting views remain anchored to the root session tree and branch runtimes, but the implementation must carefully track root files, active branch files, runtime attachment, render generation, and destructive-switch safety.
