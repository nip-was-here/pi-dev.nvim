#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

expected="$(mktemp)"
actual="$(mktemp)"
trap 'rm -f "$expected" "$actual"' EXIT

{
  echo '# Architecture Decision Records'
  echo
  find doc/adr -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.md' | sort | while read -r adr_file; do
    title="$(head -n 1 "$adr_file" | sed 's/^# //')"
    number="${title%%.*}"
    text="${title#*. }"
    printf '* [%s. %s](%s)\n' "$number" "$text" "$(basename "$adr_file")"
  done
} > "$expected"

cp doc/adr/README.md "$actual"

diff -u "$expected" "$actual"
