# 10. Use conventional commits for release automation

Date: 2026-06-21

## Status

Accepted

## Context

The repository has a GitHub Actions release workflow that runs `semantic-release` on `master`, the release branch. The project is a GitHub-hosted Neovim plugin rather than an npm package, so the workflow must explicitly pass only `@semantic-release/commit-analyzer`, `@semantic-release/release-notes-generator`, and `@semantic-release/github` instead of semantic-release's default npm publishing plugin set.

`semantic-release` uses commit messages to determine the next semantic version and generate release notes. Its default analyzer and release-notes generator use the Angular commit message convention. If commits are free-form, the release workflow can silently skip releases, publish the wrong release class, or omit important changes from generated notes.

Release-impact information needs to survive normal contributor commits and any later squash, rebase, or merge path into the release branch.

## Decision

Use Angular-style conventional commits for every commit that may reach `master` or another future release branch.

The required header format is:

```text
<type>(<scope>): <short summary>
```

`type` and summary are mandatory. `scope` is optional but recommended when it clarifies the affected area. The allowed types are:

- `feat` - user-visible new behavior;
- `fix` - bug fix;
- `perf` - performance improvement;
- `docs` - documentation-only change;
- `test` - test-only change;
- `refactor` - code change that neither fixes a bug nor adds a feature;
- `build` - build system or external dependency change;
- `ci` - CI/release workflow change.

Do not use `chore`; choose the closest allowed type instead.

Write summaries in imperative present tense, with a lower-case first letter and no trailing period, for example `fix(renderer): preserve tool fold state across updates`.

Use a commit body for non-trivial commits, and for all non-`docs` commits unless the change is genuinely self-evident. The body should explain why the change exists and, when useful, compare previous behavior with the new behavior.

Use footer trailers for release metadata:

- `BREAKING CHANGE:` starts a breaking-change section and must include migration notes when public behavior, API, config, command/keymap semantics, documented workflow, or persisted session behavior changes incompatibly.
- Issue references such as `Fixes #123` or `Closes #123` belong in the footer, after breaking-change notes.

Under the default semantic-release behavior, `fix` and `perf` commits trigger patch releases, `feat` commits trigger minor releases, and any commit with a `BREAKING CHANGE:` footer triggers a major release. Other allowed types normally improve history and generated notes without forcing a release unless release configuration changes later.

Preferred scopes for this repository are areas such as `api`, `rpc`, `runtime`, `ui`, `renderer`, `sessions`, `compat`, `mcp`, `permissions`, `status`, `config`, `health`, `docs`, `adr`, `tests`, `ci`, `release`, and `workflow`.

If commits are squashed or rebased before they reach the release branch, the resulting commit message must preserve the correct conventional type, scope, summary, body, and breaking-change footer.

Contributor-facing branch and pull request practices should preserve that final release signal. Branch names use short kebab-case `<type>/<short-topic>` names, ordinary pull requests target the release branch unless a maintainer asks otherwise, pull request titles should normally be valid conventional-commit headers, and temporary `fixup!` commits are acceptable during review only when the final merged or squashed commit restores a clean conventional commit message.

The release workflow intentionally invokes `semantic-release` through `npx` without a repository-local package lock and uses bare version tags such as `1.2.3` rather than `v1.2.3`. The workflow writes a temporary inline `release.config.cjs` during the release job to keep the GitHub-only semantic-release plugin list and GitHub plugin options in workflow YAML: npm publishing stays disabled, and GitHub issue/PR comments and labels stay disabled so releases do not require repository label setup. If release reproducibility or tag shape becomes a problem, update the dedicated release workflow configuration in the same ADR/workflow change.

## Consequences

The release workflow can infer versions and release notes from Git history without manual version bumping or hand-maintained changelogs.

All contributors must treat commit messages as part of the release contract. A technically correct code change can still be release-incorrect if its final commit message has the wrong type or omits a breaking-change footer.

History becomes easier to scan and automate, but contributors need to learn the limited type set and avoid free-form commit titles. Contributor workflow documentation should carry the concrete commit-writing checklist so the convention is preserved consistently.
