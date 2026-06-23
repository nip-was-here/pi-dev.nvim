#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

for name in TMPDIR TMP TEMP; do
  value="${!name}"
  case "$value" in
    "$ROOT_DIR"/tmp/tests/tmp) ;;
    *)
      echo "$name must stay under ./tmp/tests/tmp, got: $value" >&2
      exit 1
      ;;
  esac
done

case "$PIDEV_TEST_TMP" in
  "$ROOT_DIR"/tmp/pi-dev-test) ;;
  *)
    echo "PIDEV_TEST_TMP must stay under ./tmp/pi-dev-test, got: $PIDEV_TEST_TMP" >&2
    exit 1
    ;;
esac

case "${PIDEV_TEST_BIN:-}" in
  "$ROOT_DIR"/tmp/tests/bin) ;;
  *)
    echo "PIDEV_TEST_BIN must stay under ./tmp/tests/bin, got: ${PIDEV_TEST_BIN:-}" >&2
    exit 1
    ;;
esac

if [[ "$(command -v pi)" != "$PIDEV_TEST_BIN/pi" ]]; then
  echo "test PATH must prefer the repository-local fake pi, got: $(command -v pi || true)" >&2
  exit 1
fi

case "${NVIM_LOG_FILE:-}" in
  "$ROOT_DIR"/tmp/tests/tmp/nvim.log) ;;
  *)
    echo "NVIM_LOG_FILE must stay under ./tmp/tests/tmp, got: ${NVIM_LOG_FILE:-}" >&2
    exit 1
    ;;
esac

if [[ ! -d "$TMPDIR" ]]; then
  echo "TMPDIR was not created: $TMPDIR" >&2
  exit 1
fi

while IFS= read -r test_file; do
  if ! grep -Fq 'tests/support/shell-test.sh' "$test_file"; then
    echo "Shell test must source tests/support/shell-test.sh: ${test_file#$ROOT_DIR/}" >&2
    exit 1
  fi
done < <(find tests/shell -type f -name '*.sh' | sort)

if ! grep -Fq 'source "$ROOT_DIR/tests/support/test-env.sh"' tests/run.sh; then
  echo "tests/run.sh must source tests/support/test-env.sh" >&2
  exit 1
fi

if ! grep -Fq 'source "$ROOT_DIR/tests/support/test-env.sh"' tests/support/shell-test.sh; then
  echo "tests/support/shell-test.sh must source tests/support/test-env.sh" >&2
  exit 1
fi

vim_temp_report="$(mktemp)"
env -u TMPDIR -u TMP -u TEMP bash -c '
  set -euo pipefail
  ROOT_DIR="$1"
  report="$2"
  source "$ROOT_DIR/tests/support/test-env.sh"
  PI_DEV_TMP_REPORT="$report" nvim --headless -u NONE -i NONE \
    +"lua local p=vim.fn.tempname(); assert(p:sub(1, #vim.env.TMPDIR) == vim.env.TMPDIR, p); assert(vim.env.NVIM_LOG_FILE:sub(1, #vim.env.TMPDIR) == vim.env.TMPDIR, vim.env.NVIM_LOG_FILE); assert(vim.env.NVIM_LOG_FILE:match([[nvim%.log$]]), vim.env.NVIM_LOG_FILE); vim.fn.writefile({p}, vim.env.PI_DEV_TMP_REPORT)" \
    +qa
  test ! -e "$ROOT_DIR/.nvimlog"
' _ "$ROOT_DIR" "$vim_temp_report"
vim_temp_name="$(cat "$vim_temp_report")"
case "$vim_temp_name" in
  "$ROOT_DIR"/tmp/tests/tmp/*) ;;
  *)
    echo "vim.fn.tempname after test-env escaped ./tmp: $vim_temp_name" >&2
    exit 1
    ;;
esac

scratch="$(env -u TMPDIR -u TMP -u TEMP -u XDG_STATE_HOME -u XDG_CACHE_HOME -u XDG_DATA_HOME bash -c '
  set -euo pipefail
  ROOT_DIR="$1"
  source "$ROOT_DIR/tests/support/test-env.sh"
  file="$(mktemp)"
  case "$file" in "$ROOT_DIR"/tmp/tests/tmp/*) ;; *) echo "$file"; exit 2;; esac
  printf "%s" "$file"
' _ "$ROOT_DIR")"

case "$scratch" in
  "$ROOT_DIR"/tmp/tests/tmp/*) ;;
  *)
    echo "mktemp after test-env escaped ./tmp: $scratch" >&2
    exit 1
    ;;
esac
