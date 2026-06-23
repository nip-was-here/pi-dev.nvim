#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$ROOT_DIR/tests/shell"
TIMEOUT_FILE="$ROOT_DIR/tests/shell-timeouts.tsv"

cd "$ROOT_DIR"

source "$ROOT_DIR/tests/support/test-env.sh"

if [[ ! -d "$TEST_DIR" ]]; then
  echo "No test directory: ${TEST_DIR#$ROOT_DIR/}" >&2
  exit 1
fi

mapfile -t test_files < <(find "$TEST_DIR" -type f -name '*.sh' | sort)

if [[ ${#test_files[@]} -eq 0 ]]; then
  echo "No shell tests found in ${TEST_DIR#$ROOT_DIR/}" >&2
  exit 1
fi

not_runnable=()
for test_file in "${test_files[@]}"; do
  if [[ ! -r "$test_file" || ! -x "$test_file" ]]; then
    not_runnable+=("${test_file#$ROOT_DIR/}")
  fi
done

if [[ ${#not_runnable[@]} -gt 0 ]]; then
  echo "Shell tests must be readable and user-executable:" >&2
  printf '  %s\n' "${not_runnable[@]}" >&2
  echo "Fix with: chmod u+rx tests/shell/**/*.sh" >&2
  exit 1
fi

if [[ ! -r "$TIMEOUT_FILE" ]]; then
  echo "Missing readable timeout map: ${TIMEOUT_FILE#$ROOT_DIR/}" >&2
  exit 1
fi

relative_test_name() {
  local test_file="$1"
  printf '%s' "${test_file#$TEST_DIR/}"
}

declare -A known_tests=()
for test_file in "${test_files[@]}"; do
  known_tests["$(relative_test_name "$test_file")"]=1
done

declare -A test_timeouts=()
while IFS=$'\t' read -r timeout_name timeout_value extra; do
  if [[ -z "${timeout_name:-}" || "$timeout_name" == \#* ]]; then
    continue
  fi
  if [[ -n "${extra:-}" || -z "${timeout_value:-}" ]]; then
    echo "Invalid timeout row in ${TIMEOUT_FILE#$ROOT_DIR/}: $timeout_name" >&2
    exit 1
  fi
  if [[ -z "${known_tests[$timeout_name]:-}" ]]; then
    echo "Timeout row references unknown test: $timeout_name" >&2
    exit 1
  fi
  if [[ ! "$timeout_value" =~ ^[0-9]+([.][0-9]+)?[smhd]?$ ]]; then
    echo "Invalid timeout duration for $timeout_name: $timeout_value" >&2
    exit 1
  fi
  test_timeouts["$timeout_name"]="$timeout_value"
done < "$TIMEOUT_FILE"

timeout_for() {
  local test_name="$1"
  local test_timeout="${test_timeouts[$test_name]:-}"
  if [[ -z "$test_timeout" ]]; then
    echo "Missing timeout for $test_name in ${TIMEOUT_FILE#$ROOT_DIR/}" >&2
    exit 1
  fi
  printf '%s' "$test_timeout"
}

TIMEOUT_SCALE="${PIDEV_TEST_TIMEOUT_SCALE:-1}"
if [[ ! "$TIMEOUT_SCALE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Invalid PIDEV_TEST_TIMEOUT_SCALE: $TIMEOUT_SCALE" >&2
  exit 1
fi

now_ms() {
  local raw="${EPOCHREALTIME/./}"
  printf '%d' "$((10#$raw / 1000))"
}

duration_centiseconds() {
  local duration="$1"
  local unit="s"
  local number="$duration"
  if [[ "$duration" =~ [smhd]$ ]]; then
    unit="${duration: -1}"
    number="${duration%?}"
  fi

  local whole="${number%%.*}"
  local fraction=""
  if [[ "$number" == *.* ]]; then
    fraction="${number#*.}"
  fi
  fraction="${fraction}00"
  fraction="${fraction:0:2}"

  local centiseconds=$((10#$whole * 100 + 10#$fraction))
  case "$unit" in
    s) ;;
    m) centiseconds=$((centiseconds * 60)) ;;
    h) centiseconds=$((centiseconds * 3600)) ;;
    d) centiseconds=$((centiseconds * 86400)) ;;
  esac
  printf '%d' "$centiseconds"
}

format_centiseconds() {
  local centiseconds="$1"
  printf '%3d.%02ds' "$((centiseconds / 100))" "$((centiseconds % 100))"
}

format_elapsed_ms() {
  local elapsed_ms="$1"
  format_centiseconds "$(((elapsed_ms + 5) / 10))"
}

scale_duration() {
  local duration="$1"
  local centiseconds
  centiseconds="$(duration_centiseconds "$duration")"
  awk -v centiseconds="$centiseconds" -v scale="$TIMEOUT_SCALE" 'BEGIN { printf "%.2fs", (centiseconds * scale) / 100 }'
}

printf 'Running %d tests from %s\n' "${#test_files[@]}" "${ROOT_DIR##*/}"
for test_file in "${test_files[@]}"; do
  test_name="$(relative_test_name "$test_file")"
  test_timeout="$(scale_duration "$(timeout_for "$test_name")")"
  timeout_display="$(format_centiseconds "$(duration_centiseconds "$test_timeout")")"
  test_artifact_name="${test_name//\//__}"

  stdout_file="$(mktemp "$TMPDIR/${test_artifact_name}.stdout.XXXXXX")"
  stderr_file="$(mktemp "$TMPDIR/${test_artifact_name}.stderr.XXXXXX")"

  start_ms="$(now_ms)"
  set +e
  timeout --foreground --kill-after=2s "$test_timeout" "$test_file" >"$stdout_file" 2>"$stderr_file"
  status=$?
  set -e
  elapsed_display="$(format_elapsed_ms "$(($(now_ms) - start_ms))")"
  echo "${elapsed_display} / ${timeout_display} ==> ${test_file#$ROOT_DIR/}"

  if [[ $status -ne 0 ]]; then
    if [[ $status -eq 124 || $status -eq 137 ]]; then
      echo "Test timed out after ${elapsed_display} / ${timeout_display}: ${test_file#$ROOT_DIR/}" >&2
    else
      echo "Test failed with exit code $status after ${elapsed_display} / ${timeout_display}: ${test_file#$ROOT_DIR/}" >&2
    fi
    if [[ -s "$stdout_file" ]]; then
      echo "--- stdout: ${test_file#$ROOT_DIR/} ---" >&2
      cat "$stdout_file" >&2
    fi
    if [[ -s "$stderr_file" ]]; then
      echo "--- stderr: ${test_file#$ROOT_DIR/} ---" >&2
      cat "$stderr_file" >&2
    fi
    echo "Captured stdout: $stdout_file" >&2
    echo "Captured stderr: $stderr_file" >&2
    exit "$status"
  fi

  if [[ -s "$stdout_file" ]]; then
    cat "$stdout_file"
  fi
  if [[ -s "$stderr_file" ]]; then
    cat "$stderr_file" >&2
  fi
  rm -f "$stdout_file" "$stderr_file"

done

echo "All tests passed."
