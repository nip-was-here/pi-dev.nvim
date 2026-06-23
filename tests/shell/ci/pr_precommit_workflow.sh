#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"
source "$ROOT_DIR/tests/support/shell-test.sh"

workflow=".github/workflows/ci.yml"
requirements=".github/requirements-ci.txt"

if [[ ! -r "$workflow" ]]; then
  echo "Missing CI workflow: $workflow" >&2
  exit 1
fi

if [[ ! -r "$requirements" ]]; then
  echo "Missing CI Python requirements: $requirements" >&2
  exit 1
fi

require_contains() {
  local needle="$1"
  if ! grep -Fq -- "$needle" "$workflow"; then
    echo "CI workflow does not contain: $needle" >&2
    exit 1
  fi
}

push_branch_rows="$(awk '
  /^  push:/ { in_push = 1; next }
  in_push && /^  [A-Za-z_]+:/ { in_push = 0 }
  in_push && /^[[:space:]]+- / { print }
' "$workflow")"
if [[ "$push_branch_rows" != "      - master" ]]; then
  echo "CI push trigger should list only the release branch" >&2
  printf '%s\n' "$push_branch_rows" >&2
  exit 1
fi

require_contains "pull_request:"
require_contains "- opened"
require_contains "- synchronize"
require_contains "- reopened"
require_contains "- ready_for_review"
require_contains "cancel-in-progress: true"
require_contains "Install shell test tooling"
require_contains "adr-tools"
require_contains "coreutils"
require_contains "findutils"
require_contains "gawk"
require_contains "Set up Neovim"
require_contains "Install pre-commit"
require_contains "cache-dependency-path: .github/requirements-ci.txt"
require_contains "python -m pip install --upgrade -r .github/requirements-ci.txt"
require_contains "Verify CI tooling"
require_contains "adr help list >/dev/null"
require_contains "Run pre-commit"
require_contains "PIDEV_TEST_TIMEOUT_SCALE: '3'"
require_contains "pre-commit run --all-files"

if ! grep -Eq '^pre-commit==[0-9]+[.][0-9]+[.][0-9]+$' "$requirements"; then
  echo "CI Python requirements should pin pre-commit exactly" >&2
  exit 1
fi

if grep -Fq -- "Run shell regression suite" "$workflow" || grep -Fq -- "./tests/run.sh" "$workflow"; then
  echo "CI workflow should let pre-commit run the regression suite once" >&2
  exit 1
fi
