# 1. Establish public documentation and test baseline

Date: 2026-06-18

## Status

Accepted

## Context

`pi-dev.nvim` is being stabilized before its first major public release. Before the first manual `git push`, the public documentation, ADR set, and regression tests can be shaped as a clean baseline rather than preserving every early iteration as public history.

The public repository needs clear artifacts for three audiences:

- users who need installation, quick start, and feature discovery;
- Neovim users who expect a complete `:help pi-dev` manual;
- maintainers and contributors who need durable design rationale and a repeatable regression suite.

Early local notes and ignored experiments helped during exploration, but the public repository should expose only durable product decisions, user-facing documentation, and repeatable tests.

## Decision

Use the following public artifact model:

- `README.md` is the public quick-start and overview.
- `doc/pi-dev.txt` is the complete Neovim help manual.
- `doc/adr` contains durable architecture decisions grouped by architectural axis rather than by every bug fix.
- `doc/adr/README.md` is generated and must not be edited manually.
- `tests/run.sh` is the public regression suite entrypoint.
- `tests/shell/**/*.sh` contains executable shell/headless-Neovim regression tests grouped by topic.
- `tests/support/` contains tracked test support fixtures.

The public regression runner discovers shell tests recursively under `tests/shell/`, requires them to be readable and user-executable, changes to the repository root, prints each test path, and executes each test file directly. It reads calibrated per-test timeout budgets from `tests/shell-timeouts.tsv`; every shell test must have an explicit relative-path row so unexpected slowdown is visible as a timeout failure instead of being hidden by broad default buckets.

Wire the public regression runner into `pre-commit` as a local hook. With the hook installed, `git commit` runs the public regression suite along with repository formatting and documentation checks automatically, so contributors do not need separate manual test and pre-commit invocations before every commit.

## Consequences

Public docs stay focused on user and contributor behavior. Regression tests are tracked, structured, and ready for future CI without depending on ignored local paths.

The ADR set describes durable product and engineering decisions. Short-lived local notes and exploratory artifacts stay outside the public distribution unless they become stable user- or contributor-facing documentation.
