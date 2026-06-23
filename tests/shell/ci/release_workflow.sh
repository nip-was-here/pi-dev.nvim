#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

workflow="$ROOT_DIR/.github/workflows/release.yml"

grep -q "workflow_run:" "$workflow" || {
  echo "release workflow must be triggered by completed CI workflow_run" >&2
  exit 1
}
grep -q "workflows:" "$workflow" && grep -q -- "- CI" "$workflow" || {
  echo "release workflow must name CI as the upstream workflow" >&2
  exit 1
}
grep -q "github.event.workflow_run.conclusion == 'success'" "$workflow" || {
  echo "release job must be gated on successful CI conclusion" >&2
  exit 1
}
grep -q "cat > release.config.cjs" "$workflow" || {
  echo "release workflow must write an inline semantic-release config" >&2
  exit 1
}
grep -q "tagFormat: '\${version}'" "$workflow" || {
  echo "release workflow config must use semantic-release bare version tag format" >&2
  exit 1
}
if grep -q -- "semantic-release[[:space:]]*-t" "$workflow"; then
  echo "release workflow must not use the short semantic-release -t option" >&2
  exit 1
fi

for plugin in "@semantic-release/commit-analyzer" "@semantic-release/release-notes-generator" "@semantic-release/github"; do
  grep -q -- "-p $plugin" "$workflow" || {
    echo "release workflow must install $plugin for npx" >&2
    exit 1
  }
  grep -q -- "$plugin" "$workflow" || {
    echo "release workflow config must include $plugin" >&2
    exit 1
  }
done

if grep -q "@semantic-release/npm" "$workflow"; then
  echo "release workflow must not include @semantic-release/npm for this GitHub-only Neovim plugin" >&2
  exit 1
fi

for option in "successComment: false" "failComment: false" "labels: false" "releasedLabels: false"; do
  grep -q "$option" "$workflow" || {
    echo "semantic-release GitHub config must include $option" >&2
    exit 1
  }
done

if grep -q "gh label create" "$workflow"; then
  echo "release workflow must not mutate repository labels" >&2
  exit 1
fi
