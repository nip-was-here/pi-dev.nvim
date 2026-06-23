#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

python3 - <<'PY'
from pathlib import Path

roots = [
    Path('lua'),
    Path('plugin'),
    Path('doc'),
    Path('tests'),
    Path('README.md'),
    Path('.github'),
    Path('.pre-commit-config.yaml'),
]

skip_suffixes = {'.gif', '.png', '.jpg', '.jpeg', '.webp'}
violations = []
for root in roots:
    paths = [root] if root.is_file() else [p for p in root.rglob('*') if p.is_file()]
    for path in paths:
        if path.suffix.lower() in skip_suffixes:
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        for line_no, raw_line in enumerate(data.splitlines(), 1):
            if any(byte > 0x7F for byte in raw_line):
                violations.append(f'{path}:{line_no}')
                break

if violations:
    raise SystemExit('Non-ASCII bytes found in plugin-owned files:\n' + '\n'.join(violations))
PY
