#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 nip
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/tests/support/shell-test.sh"

tmp_lua="$(pidev_lua_file)"
cat > "$tmp_lua" <<'LUA'
local pipeline = require('pi-dev.render_pipeline')

local spaced = pipeline.prepare_block_lines({
  '# Title',
  '',
  '',
  'body',
  '',
  '```',
  '# fenced heading must not gain blanks',
  '```',
  '',
  '',
  '## Next',
  '',
  'tail',
})
local text = table.concat(spaced, '\n')
assert(text:find('# Title\n\nbody', 1, true), text)
assert(text:find('# fenced heading must not gain blanks', 1, true), text)
assert(text:find('```\n\n# fenced heading', 1, true) == nil, text)
assert(text:find('body\n\n```', 1, true), text)
assert(text:find('```\n\n## Next\n\ntail', 1, true), text)

local append = pipeline.prepare_append_lines({ '', '## Header', '', 'content' }, '', {})
assert(append[1] == '## Header', vim.inspect(append))
append = pipeline.prepare_append_lines({ '## Header', '', 'content' }, 'previous', {})
assert(append[1] == '' and append[2] == '## Header', vim.inspect(append))

local notice = table.concat(pipeline.notice_lines('one\n\ntwo'), '\n')
assert(notice == '\n> one\n>\n> two\n', vim.inspect(notice))

local fenced = pipeline.fenced_lines('text', 'a```b', { trim_final_empty = true })
assert(fenced[1] == '````text' and fenced[#fenced] == '````', vim.inspect(fenced))

local skill = [[<skill name="grill-with-docs" location="./tmp/pi-dev-test/skills/grill-with-docs/SKILL.md">
References are relative to ./tmp/pi-dev-test/skills/grill-with-docs.

Run a `/grilling` session, using the `/domain-modeling` skill.
</skill>

Fix the tree label.]]
local label = pipeline.skill_call_label(skill)
assert(label == 'Skill: grill-with-docs Fix the tree label.', label)
assert(label:find('<skill', 1, true) == nil and label:find('./tmp/pi-dev-test/skills', 1, true) == nil, label)
assert(label:find('/grilling', 1, true) == nil, label)
LUA

pidev_run_lua_file "$tmp_lua"
rm -f "$tmp_lua"
