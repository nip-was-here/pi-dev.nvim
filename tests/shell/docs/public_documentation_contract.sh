#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

require_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "$file is missing public contract text: $needle" >&2
    exit 1
  fi
}

require_contains doc/adr/0001-establish-public-documentation-and-test-baseline.md '`tests/run.sh` is the public regression suite entrypoint'
require_contains doc/adr/0001-establish-public-documentation-and-test-baseline.md 'requires them to be readable and user-executable'
require_contains doc/adr/0001-establish-public-documentation-and-test-baseline.md 'executes each test file directly'
require_contains doc/adr/0001-establish-public-documentation-and-test-baseline.md 'Wire the public regression runner into `pre-commit` as a local hook'
require_contains README.md 'git commit` runs the public regression suite under `tests/`'
require_contains doc/pi-dev.txt ':checkhealth pi-dev'
require_contains doc/pi-dev.txt 'git commit'
require_contains .pre-commit-config.yaml 'id: regression-suite'
require_contains .pre-commit-config.yaml 'name: Regression Suite'
require_contains .pre-commit-config.yaml 'entry: ./tests/run.sh'

if grep -Fq 'pre-commit run --all-files' README.md doc/pi-dev.txt doc/adr/0001-establish-public-documentation-and-test-baseline.md; then
  echo 'public docs should not instruct separate pre-commit run invocations' >&2
  exit 1
fi

if [[ ! -x tests/run.sh ]]; then
  echo 'tests/run.sh must be user-executable' >&2
  exit 1
fi
