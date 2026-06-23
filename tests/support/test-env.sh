#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
if [[ -z "${ROOT_DIR:-}" ]]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

export TMPDIR="$ROOT_DIR/tmp/tests/tmp"
export TMP="$TMPDIR"
export TEMP="$TMPDIR"
export XDG_STATE_HOME="$ROOT_DIR/tmp/tests/state"
export XDG_CACHE_HOME="$ROOT_DIR/tmp/tests/cache"
export XDG_DATA_HOME="$ROOT_DIR/tmp/tests/data"
export PIDEV_TEST_TMP="$ROOT_DIR/tmp/pi-dev-test"
export PIDEV_TEST_BIN="$ROOT_DIR/tmp/tests/bin"
export NVIM_LOG_FILE="$TMPDIR/nvim.log"

mkdir -p "$TMPDIR" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$PIDEV_TEST_TMP" "$PIDEV_TEST_BIN"

cat > "$PIDEV_TEST_BIN/pi" <<'PY'
#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
import json
import sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except Exception as exc:
        print(json.dumps({"type": "protocol_error", "error": str(exc)}), flush=True)
        continue

    kind = message.get("type")
    data = {"echo": message}
    if kind == "get_state":
        data = {"isStreaming": False}
    elif kind == "get_session_stats":
        data = {}
    elif kind == "get_messages":
        data = {"messages": []}
    elif kind == "get_fork_messages":
        data = {"messages": []}
    elif kind == "get_available_models":
        data = {"models": []}
    elif kind == "switch_session":
        data = {"cancelled": False}
    elif kind == "new_session":
        data = {"cancelled": False}

    print(json.dumps({
        "type": "response",
        "id": message.get("id"),
        "command": kind,
        "success": True,
        "data": data,
    }), flush=True)
PY
chmod u+x "$PIDEV_TEST_BIN/pi"
export PATH="$PIDEV_TEST_BIN:$PATH"
