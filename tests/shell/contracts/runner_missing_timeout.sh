#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

fixture="$(pidev_tmp_dir)"
mkdir -p "$fixture/tests/shell/example" "$fixture/tests/support"
cp tests/run.sh "$fixture/tests/run.sh"
cp tests/support/test-env.sh "$fixture/tests/support/test-env.sh"
chmod u+x "$fixture/tests/run.sh"
cat > "$fixture/tests/shell/example/missing_timeout.sh" <<'SH'
#!/usr/bin/env bash
echo 'SHOULD_NOT_RUN_MISSING_TIMEOUT_TEST'
SH
chmod u+x "$fixture/tests/shell/example/missing_timeout.sh"
cat > "$fixture/tests/shell-timeouts.tsv" <<'TSV'
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
TSV

set +e
output="$($fixture/tests/run.sh 2>&1)"
status=$?
set -e

if [[ $status -eq 0 ]]; then
  printf '%s\n' "$output" >&2
  echo 'tests/run.sh should fail when a discovered test has no timeout row' >&2
  exit 1
fi
if ! printf '%s\n' "$output" | grep -Fq 'Missing timeout for example/missing_timeout.sh in tests/shell-timeouts.tsv'; then
  printf '%s\n' "$output" >&2
  echo 'missing-timeout error was not reported clearly' >&2
  exit 1
fi
if printf '%s\n' "$output" | grep -Fq 'SHOULD_NOT_RUN_MISSING_TIMEOUT_TEST'; then
  printf '%s\n' "$output" >&2
  echo 'tests/run.sh should stop before executing a test with a missing timeout row' >&2
  exit 1
fi
if printf '%s\n' "$output" | grep -Fq 'invalid integer constant'; then
  printf '%s\n' "$output" >&2
  echo 'tests/run.sh should not continue into arithmetic with an empty timeout' >&2
  exit 1
fi
