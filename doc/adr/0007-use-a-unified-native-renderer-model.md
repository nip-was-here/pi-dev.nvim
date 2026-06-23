# 7. Use a unified native renderer model

Date: 2026-06-18

## Status

Accepted

## Context

Pi output reaches Neovim from restored JSONL sessions, live RPC events, direct user echoes, service notices, tool updates, permission objects, and full-buffer session renders. These paths need consistent normalization, Markdown fence handling, heading spacing, fold ranges, diff highlighting, and markdown-refresh behavior.

## Decision

Render Pi RPC output into native Neovim buffers with a unified Markdown-oriented model.

Restored history and live events share the same promoted hierarchy. Plugin-owned conversation headings use `## User`, `## Assistant`, `### Tool`, and `#### Permission request`, with right-aligned timestamps when available. Message headers display timestamps in the host local timezone.

Service notices such as user aborts, queue updates, compaction/retry lifecycle messages, stderr, protocol errors, provider/model errors, extension errors, and local command notices render as Markdown blockquotes instead of message-like headings. Message and section headers have exactly one blank line before and after them for visual consistency.

Markdown headings inside message bodies are demoted below plugin-owned headings while respecting fenced code blocks and nested shorter fences. Subagent request/result sections and their nested Markdown headings are likewise rendered deeper than normal Pi tool and permission headings, so nested subagent content remains visible without competing with the main conversation hierarchy.

Thinking/reasoning content, including restored top-level fields and standalone thinking-role messages, renders as Markdown blockquotes under a visible `> Thinking` header. Thinking bodies are manual fold blocks under that visible header; they stay open at or below 8 rendered detail lines and auto-close only when they exceed 8 rendered detail lines, while preserving streamed whitespace and trimming trailing quoted blank lines before the final answer.

Render each tool execution as one bounded object keyed by tool call ID and update it in place. Restored assistant `toolCall` content blocks render as the same compact `### Tool: ...` objects. When the matching following `toolResult` exists, pair it into the same object so restored history resembles live completed execution.

Tool headings show the tool name and the primary short input inline when available, such as the full bash command or a file path, truncated to fit the output pane header on one line. Keep that heading text plain rather than wrapping the tool name or input in inline-code delimiters, because optional Markdown rendering may conceal those delimiters and shift the apparent suffix column. Completed live tool objects, including subagent-like tools, show their locally measured execution duration right-aligned near the conversation timestamp suffix column, one display cell to its left for better visual balance; restored tool objects show the duration when paired result timestamps, explicit duration fields, or retained runtime-local live tool timing are available, even if branch/session loading hides tool result bodies. The duration suffix column stays stable even when Markdown rendering conceals heading markers. Do not render separate Input or Output headings for normal tool details. Diff-like content remains in a standard `diff` fenced block, with Pi-owned extmarks only on actual added/deleted lines, not file headers, hunk headers, or unchanged context neighbors.

Manual folds apply only to detail/body ranges. Tool, thinking, and permission headings stay visible. Every tool detail/body range is a manual fold block even when it remains open by default, so users can collapse any tool output on demand. The blank line directly under a foldable heading belongs to the folded detail range; trailing blank separators before the next header remain outside the fold. Fenced tool output, including read/write/edit renderings and restored read results, keeps its opening fence, body, and closing fence inside the same fold even when contents look like Markdown.

Auto-close tool and permission detail/body ranges only when they exceed `ui.render.fold_tool_output_over`, defaulting to 20 rendered lines. Thinking detail/body ranges use the fixed 8 rendered-line auto-close threshold described above. Keep live `bash` tool details open while the command is still running, even when streamed output already exceeds the threshold; apply the normal threshold fold after the `bash` tool finishes. Closed Pi output folds render consistently as `details - N lines`. Preserve user fold intent across tool updates: opened folds stay open and closed folds stay closed. When focus is outside the output pane and automatic folding collapses a large bottom block, scroll back to the visible closed fold header; when focus is inside output, preserve the user's view and cursor.

Keep pure renderer preparation helpers in `lua/pi-dev/render_pipeline.lua` and stateful Neovim rendering in `lua/pi-dev/renderer.lua`. The pure pipeline owns normalization, Markdown fence detection, quote/thinking predicates, section spacing, boundary normalization, fenced block construction, and common notice/message builders. The renderer owns buffer mutation, extmarks, folds, scroll/view preservation, live assistant streaming state, tool/permission object ranges, and markdown refresh scheduling.

Use the chat buffer's Markdown filetype and document `render-markdown.nvim` as an optional renderer. The dependency remains optional.

## Consequences

The chat surface is readable, foldable, and consistent across live and restored paths. The renderer must protect CRLF/control-output hygiene, fence-aware spacing, heading hierarchy, fold boundaries, diff extmarks, user fold state, and chunked rendering cancellation.
