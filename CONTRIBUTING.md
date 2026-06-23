<!--
SPDX-License-Identifier: Apache-2.0
Copyright (c) 2026 nip
-->
# Contributing

Thanks for helping improve `pi-dev.nvim`. This repository uses a small, release-oriented contributor workflow: keep changes focused, name branches and pull requests clearly, and make sure the final commits carry the release impact that automation needs.

## Before you start

- Open an issue or discussion first for broad UI changes, public API changes, compatibility behavior, release workflow changes, or anything likely to require multiple pull requests.
- Keep each pull request focused on one behavior, bug, documentation area, or test improvement.
- Avoid bundling unrelated cleanup with functional changes. Send follow-up cleanup separately when possible.

## Branch names

Use short, lower-case, kebab-case branch names that start with the kind of work:

```text
<type>/<short-topic>
```

Examples:

```text
fix/renderer-fold-state
docs/contributing-guide
ci/release-permissions
test/session-restore-tools
```

Use the same type vocabulary as commit messages when it fits: `feat`, `fix`, `perf`, `docs`, `test`, `refactor`, `build`, or `ci`. Prefer a topic that names the affected area or user-visible problem. Avoid generic names such as `updates`, `fixes`, `misc`, or only an issue number.

Open ordinary pull requests against `master` unless a maintainer asks for a different target branch. Backports, release-candidate fixes, and long-lived feature branches should be discussed with maintainers before opening the PR.

## Commit messages

Commits that may reach a release branch must follow Angular-style conventional commits:

```text
<type>(<scope>): <short summary>
```

`type` and summary are mandatory. `scope` is optional but recommended when it clarifies the affected area.

Allowed types:

- `feat` - user-visible new behavior.
- `fix` - bug fix.
- `perf` - performance improvement.
- `docs` - documentation-only change.
- `test` - test-only change.
- `refactor` - code change that neither fixes a bug nor adds a feature.
- `build` - build system or external dependency change.
- `ci` - CI or release workflow change.

Do not use `chore`; choose the closest allowed type instead.

Preferred scopes include repository areas such as `api`, `rpc`, `runtime`, `ui`, `renderer`, `sessions`, `compat`, `mcp`, `permissions`, `status`, `config`, `health`, `docs`, `adr`, `tests`, `ci`, `release`, and `workflow`.

Good examples:

```text
fix(renderer): preserve tool fold state across updates
feat(ui): add waiting-branch switcher
docs(contributing): document pull request workflow
test(sessions): cover current-directory restore
ci(release): run semantic-release on master
```

Summary rules:

- Use imperative present tense: `preserve`, not `preserved` or `preserves`.
- Start with a lower-case letter.
- Do not end with a period.

Body and footer rules:

- Add a body for non-trivial changes, and for all non-`docs` changes unless the reason is genuinely obvious.
- Use the body to explain why the change exists and, when helpful, compare previous and new behavior.
- Use `BREAKING CHANGE:` in the footer for incompatible public API, config, command, keymap, help/documentation contract, session format, or workflow changes. Include migration notes.
- Put issue references such as `Fixes #123` or `Closes #123` in the footer, after any breaking-change notes.

Release automation reads commit messages. Under the current release setup, `fix` and `perf` normally produce patch releases, `feat` produces a minor release, and `BREAKING CHANGE:` produces a major release.

## Fixup commits during review

It is fine to use fixup commits while a pull request is under review:

```sh
git commit --fixup <commit-sha>
```

Fixup commits make review updates easy to inspect. Before merge, either autosquash them locally or make sure the final squash/rebase result has a clean conventional commit message:

```sh
git rebase --autosquash -i master
```

The final commit history that reaches `master` must not depend on temporary `fixup!` subjects for release metadata.

## Pull request titles and descriptions

Prefer a pull request title that can become the final squash commit title. In most cases, use the same conventional-commit format:

```text
fix(renderer): preserve tool fold state across updates
```

For multi-commit PRs, choose the primary release impact for the title and keep secondary details in the description.

A useful PR description includes:

- the problem or motivation;
- the approach taken;
- focused validation commands or manual checks performed;
- screenshots or short recordings for visible UI changes;
- release impact: patch, minor, major, or no release-impacting change;
- linked issues, using `Fixes #123` when the PR should close an issue.

Use GitHub draft PRs for work in progress. Prefer draft status over adding `[WIP]` to the title. Mark the PR ready for review only after the branch is rebased or merged with the current target branch, focused checks pass, and the description says what was validated.

## Validation

Run focused checks for the files you changed. The public regression suite entrypoint is:

```sh
./tests/run.sh
```

With repository hooks installed, `git commit` runs the public regression suite and repository documentation/license checks automatically. CI runs the same gate for pull requests.

## Public documentation

Keep user-facing behavior synchronized across the public docs that describe it:

- `README.md` for quick-start and overview;
- `doc/pi-dev.txt` for complete Neovim help;
- `doc/adr/` for durable architecture and workflow decisions;
- `tests/` for public regression coverage.
