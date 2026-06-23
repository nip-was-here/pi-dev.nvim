#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

session_root="$(mktemp -d)"
project_cwd="$(mktemp -d)"
other_cwd="$(mktemp -d)"
mkdir -p "$session_root/a" "$session_root/b" "$session_root/c"
{
  printf '%s\n' "{\"type\":\"session\",\"version\":3,\"id\":\"old\",\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"cwd\":\"$project_cwd\"}"
  printf '%s\n' "{\"type\":\"message\",\"id\":\"m1\",\"parentId\":null,\"timestamp\":\"2026-01-04T00:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":\"Latest by message timestamp\"}}"
} > "$session_root/a/old.jsonl"
printf '%s\n' "{\"type\":\"session\",\"version\":3,\"id\":\"new\",\"timestamp\":\"2026-01-02T00:00:00.000Z\",\"cwd\":\"$project_cwd\"}" > "$session_root/b/new.jsonl"
printf '%s\n' "{\"type\":\"session\",\"version\":3,\"id\":\"other\",\"timestamp\":\"2026-01-03T00:00:00.000Z\",\"cwd\":\"$other_cwd\"}" > "$session_root/c/other.jsonl"
touch -t 202601010000 "$session_root/a/old.jsonl"
touch -t 202601020000 "$session_root/b/new.jsonl"
touch -t 202601030000 "$session_root/c/other.jsonl"

output="$({
  pidev_nvim_output \
    +"lua require('pi-dev').setup({ keymaps = { enable = false }, session_root = '$session_root', cwd = '$project_cwd' })" \
    +"lua local sessions = require('pi-dev.sessions'); local list = sessions.list(); assert(#list == 2, 'must list only current-directory sessions'); assert(list[1].path:find('old%.jsonl$'), 'latest current-directory session should prefer last entry timestamp over file mtime')" \
    +"lua local sessions = require('pi-dev.sessions'); local sent = {}; local rpc = require('pi-dev.rpc'); rpc.request = function(message, cb) table.insert(sent, message); if cb then cb({ type = 'response', success = true, data = { messages = {} } }) end; return message.type end; sessions.load_latest_or_new(); assert(sent[1].type == 'switch_session'); assert(sent[1].sessionPath:find('old%.jsonl$'))" \
    +"lua local api = require('pi-dev.api'); local hit = nil; api.model_picker = function() hit = 'model' end; api.resume = function() hit = 'resume' end; api.reload = function() hit = 'reload' end; api.tree = function() hit = 'tree' end; api.waiting = function() hit = 'waiting' end; api.next_rpc = function() hit = 'next-rpc' end; assert(api.handle_slash_command('/model') and hit == 'model'); assert(api.handle_slash_command('/resume') and hit == 'resume'); assert(api.handle_slash_command('/reload') and hit == 'reload'); assert(api.handle_slash_command('/tree') and hit == 'tree'); assert(api.handle_slash_command('/waiting') and hit == 'waiting'); assert(api.handle_slash_command('/next-rpc') and hit == 'next-rpc'); assert(api.handle_slash_command('/cycle-rpc') and hit == 'next-rpc'); assert(not api.handle_slash_command('/unknown'))" \
    +"lua local api = require('pi-dev.api'); local state = require('pi-dev.state'); local rpc = require('pi-dev.rpc'); state.session.auto_loaded_cwd = nil; local sent = {}; rpc.start = function() return 42 end; rpc.request = function(message, cb) table.insert(sent, message); if cb then cb({ type = 'response', success = true, data = { messages = {} } }) end; return message.type end; api.toggle(); assert(vim.wait(1000, function() return sent[1] ~= nil end), 'toggle/open must auto-restore a current-directory session'); assert(sent[1].type == 'switch_session' and sent[1].sessionPath:find('old%.jsonl$'))" \
    +"lua local completion = require('pi-dev.completion'); local items = completion.items('mo'); assert(#items >= 1 and items[1].word == '/model')" \
    +"lua local sessions = require('pi-dev.sessions'); local state = require('pi-dev.state'); vim.o.columns = 80; vim.wo.number = true; vim.wo.numberwidth = 4; vim.ui.select = function() error('resume must use the native root-session picker') end; local sent = {}; require('pi-dev.rpc').request = function(message, cb) table.insert(sent, message); if cb then cb({ success = true, data = {} }) end; return message.type end; sessions.pick(); assert(vim.wait(1000, function() return state.ui.interaction ~= nil end), 'resume picker should open'); assert(state.ui.interaction.surface == 'output', 'resume should use the large output surface'); assert(#state.ui.interaction.items == 2, vim.inspect(state.ui.interaction.items)); local first = state.ui.interaction.items[1]; assert(first.label:find('^%* '), first.label); assert(first.label:find('Last:', 1, true), first.label); assert(not first.label:find('old%.jsonl'), first.label); assert(first.meta == nil, vim.inspect(first)); vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'xt', false); assert(vim.wait(1000, function() return sent[1] ~= nil end), 'resume selection should switch session'); assert(sent[1].type == 'switch_session' and sent[1].sessionPath:find('old%.jsonl$'))"
} 2>&1)" || {
  printf '%s\n' "$output"
  rm -rf "$session_root" "$project_cwd" "$other_cwd"
  exit 1
}

rm -rf "$session_root" "$project_cwd" "$other_cwd"

pidev_assert_no_nvim_errors "$output"
