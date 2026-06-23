#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmpdir="$(mktemp -d)"
fake_pi="$tmpdir/fake-pi-rpc.py"
cat > "$fake_pi" <<'PY'
#!/usr/bin/env python3
import json
import sys

current_model = {"provider": "fake", "id": "model"}
current_thinking = "low"

print(json.dumps({"type": "agent_start"}), flush=True)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception as exc:
        print(json.dumps({"type": "protocol_error", "error": str(exc)}), flush=True)
        continue
    response = {
        "type": "response",
        "id": msg.get("id"),
        "command": msg.get("type"),
        "success": True,
        "data": {"echo": msg},
    }
    if msg.get("type") == "get_state":
        response["data"] = {
            "model": current_model,
            "thinkingLevel": current_thinking,
            "isStreaming": False,
            "sessionFile": "./tmp/pi-dev-test/fake-session.jsonl",
        }
    elif msg.get("type") == "set_model":
        if msg.get("modelId") == "broken":
            response["success"] = False
            response["error"] = "Model not found: fake/broken"
            response.pop("data", None)
        else:
            current_model = {"provider": msg.get("provider"), "id": msg.get("modelId")}
            response["data"] = current_model
    elif msg.get("type") == "get_session_stats":
        response["data"] = {
            "tokens": {"total": 42},
            "cost": 0.01,
            "contextUsage": {"tokens": 21, "contextWindow": 100, "percent": 21},
        }
    elif msg.get("type") == "prompt" and str(msg.get("message", "")).startswith("/model "):
        model_id = str(msg.get("message")).split(" ", 1)[1]
        current_model = {"provider": "slash", "id": model_id}
    print(json.dumps(response), flush=True)
PY
chmod +x "$fake_pi"

output="$({
  pidev_nvim_output \
    +"lua require('pi-dev').setup({ exec = { bin = '$fake_pi', args = {} }, keymaps = { enable = false }, auto_resume_last_session = false })" \
    +"lua local events = require('pi-dev.events'); local saw_start = false; events.on('agent_start', function() saw_start = true end); local api = require('pi-dev.api'); api.start(); assert(vim.wait(1000, function() return saw_start end), 'fake RPC agent_start event not received')" \
    +"lua local api = require('pi-dev.api'); local response; api.prompt('hello fake rpc', nil, function(resp) response = resp end); assert(vim.wait(1000, function() return response ~= nil end), 'prompt response not received'); assert(response.success == true); assert(response.command == 'prompt'); assert(response.data.echo.message == 'hello fake rpc')" \
    +"lua local api = require('pi-dev.api'); local got_state; api.get_state(function(resp) got_state = resp end); assert(vim.wait(1000, function() return got_state ~= nil end), 'get_state response not received'); assert(require('pi-dev.state').statusline.model == 'fake/model')" \
    +"lua local api = require('pi-dev.api'); local slash_response; api.prompt('/model via-slash', nil, function(resp) slash_response = resp end); assert(vim.wait(1000, function() return slash_response ~= nil and require('pi-dev.state').statusline.model == 'slash/via-slash' end), 'slash prompt should refresh status from real get_state'); local line = require('pi-dev.statusline').render_for_width(120); assert(line:find('slash/via-slash', 1, true), line)" \
    +"lua local api = require('pi-dev.api'); local changed; api.set_model('fake', 'new-model', function(resp) changed = resp end); assert(vim.wait(1000, function() return changed ~= nil and require('pi-dev.state').statusline.model == 'fake/new-model' end), 'set_model should refresh status model'); local line = require('pi-dev.statusline').render_for_width(120); assert(line:find('fake/new-model', 1, true), line)" \
    +"lua local api = require('pi-dev.api'); local failed; api.set_model('fake', 'broken', function(resp) failed = resp end); assert(vim.wait(1000, function() return failed ~= nil and require('pi-dev.state').statusline.status == 'error' end), 'set_model error should update status'); local line = require('pi-dev.statusline').render_for_width(120); assert(line:find('Model not found', 1, true), line)" \
    +"lua local api = require('pi-dev.api'); local state = require('pi-dev.state'); api.hide(); assert(state.is_job_running(), 'hiding UI must not stop RPC process'); local hidden_response; api.prompt('after hide', nil, function(resp) hidden_response = resp end); assert(vim.wait(1000, function() return hidden_response ~= nil end), 'RPC should still respond while UI is hidden'); assert(hidden_response.data.echo.message == 'after hide')"
} 2>&1)" || {
  printf '%s\n' "$output"
  rm -rf "$tmpdir"
  exit 1
}

rm -rf "$tmpdir"

pidev_assert_no_nvim_errors "$output"
