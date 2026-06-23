#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

if [[ -z "${ROOT_DIR:-}" ]]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

cd "$ROOT_DIR"
source "$ROOT_DIR/tests/support/test-env.sh"

PIDEV_SHELL_TEST_ARTIFACTS=()
cleanup_pidev_shell_test_artifacts() {
  local status=$?
  if [[ $status -eq 0 ]]; then
    shopt -s nullglob
    local generated=("${PIDEV_SHELL_TEST_ARTIFACTS[@]}" "$TMPDIR"/pi-dev-lua.*.lua "$TMPDIR"/pi-dev-dir.* "$TMPDIR"/tmp.* "$TMPDIR"/nvim.* "${NVIM_LOG_FILE:-}")
    if [[ ${#generated[@]} -gt 0 ]]; then
      rm -rf "${generated[@]}"
    fi
    shopt -u nullglob
  fi
}
trap cleanup_pidev_shell_test_artifacts EXIT

pidev_lua_file() {
  local path
  path="$(mktemp "$TMPDIR/pi-dev-lua.XXXXXX.lua")"
  PIDEV_SHELL_TEST_ARTIFACTS+=("$path")
  printf '%s\n' "$path"
}

pidev_tmp_dir() {
  local path
  path="$(mktemp -d "$TMPDIR/pi-dev-dir.XXXXXX")"
  PIDEV_SHELL_TEST_ARTIFACTS+=("$path")
  printf '%s\n' "$path"
}

pidev_run_nvim() {
  local output
  set +e
  output="$(nvim --headless -u NONE -i NONE --cmd "set rtp+=$ROOT_DIR" "$@" +qa 2>&1)"
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    printf '%s\n' "$output"
    return "$status"
  fi
  if printf '%s\n' "$output" | grep -Eq 'Error detected|E[0-9]+:'; then
    printf '%s\n' "$output"
    return 1
  fi
}

pidev_nvim_output() {
  nvim --headless -u NONE -i NONE --cmd "set rtp+=$ROOT_DIR" "$@" +qa 2>&1
}

pidev_assert_no_nvim_errors() {
  local output="$1"
  if printf '%s\n' "$output" | grep -Eq 'Error detected|E[0-9]+:'; then
    printf '%s\n' "$output"
    return 1
  fi
}

pidev_run_lua_file() {
  local script="$1"
  pidev_run_nvim +"luafile $script"
}
