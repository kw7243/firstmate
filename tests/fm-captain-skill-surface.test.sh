#!/usr/bin/env bash
# Static tests for the captain-facing skill invocation surface.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

README="$ROOT/README.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"

test_readme_documents_codex_skill_invocation() {
  local builtins
  builtins=$(awk '/^## Built-in skills$/{capture=1; next} capture && /^## /{exit} capture' "$README")

  assert_contains "$builtins" 'Codex uses `$` skill invocations' \
    "README must tell captains that Codex uses dollar-prefixed skill invocations"
  assert_contains "$builtins" 'type `$bearings` or `$stow`' \
    "README must show the working Codex bearings and stow invocations"
  assert_contains "$builtins" 'native `/bearings` and `/stow` are not repo-defined Codex commands' \
    "README must explain why slash commands fail in Codex"
  assert_contains "$builtins" '| `bearings`' \
    "README built-in table must name bearings without implying one universal prefix"
  assert_contains "$builtins" '| `stow`' \
    "README built-in table must name stow without implying one universal prefix"
  assert_contains "$builtins" '| `/bearings`' \
    "README built-in table must preserve slash invocation for slash-skill harnesses"
  assert_contains "$builtins" '| `$bearings`' \
    "README built-in table must include the Codex bearings invocation"
  assert_contains "$builtins" '| `/stow`' \
    "README built-in table must preserve slash invocation for slash-skill harnesses"
  assert_contains "$builtins" '| `$stow`' \
    "README built-in table must include the Codex stow invocation"
  pass "README documents the supported Codex skill invocation surface for bearings and stow"
}

test_internal_harness_contract_keeps_codex_boundary() {
  assert_grep 'codex: `$<skill>`' "$HARNESS" \
    "harness-adapters must retain Codex's skill invocation form"
  assert_grep 'codex rejects it as "Unrecognized command"' "$HARNESS" \
    "harness-adapters must retain the Codex slash-command rejection fact"
  pass "harness-adapters keeps the verified Codex slash boundary"
}

test_public_skills_include_stow_and_bearings() {
  local bearings stow
  bearings="$ROOT/skills/bearings/SKILL.md"
  stow="$ROOT/skills/stow/SKILL.md"

  assert_present "$stow" "public stow skill is missing"
  assert_present "$bearings" "public bearings skill is missing"
  assert_grep 'name: stow' "$stow" "public stow skill has the wrong name"
  assert_grep 'name: bearings' "$bearings" "public bearings skill has the wrong name"
  assert_grep 'user-invocable: true' "$stow" "public stow skill must be user-invocable"
  assert_grep 'user-invocable: true' "$bearings" "public bearings skill must be user-invocable"
  assert_grep 'invoke it as `$stow`' "$stow" "public stow skill must document the Codex invocation"
  assert_grep 'invoke it as `$bearings`' "$bearings" "public bearings skill must document the Codex invocation"
  assert_no_grep 'invokes /stow' "$stow" "public stow skill must not advertise slash invocation as the generic trigger"
  assert_no_grep 'metadata:' "$stow" "public stow skill must not carry internal metadata"
  assert_no_grep 'metadata:' "$bearings" "public bearings skill must not carry internal metadata"
  assert_no_grep 'FM_HOME' "$bearings" "public bearings skill must not depend on a firstmate home"
  assert_no_grep 'bin/fm-bearings-snapshot.sh' "$bearings" "public bearings skill must not call firstmate-private scripts"
  pass "public stow and bearings skills are present and standalone"
}

test_internal_skills_keep_normal_text_triggers() {
  local bearings stow
  bearings="$ROOT/.agents/skills/bearings/SKILL.md"
  stow="$ROOT/.agents/skills/stow/SKILL.md"

  assert_grep 'Use when the captain invokes /bearings' "$bearings" \
    "internal bearings skill must keep the slash trigger for messages that reach the agent"
  assert_grep 'where did I leave off' "$bearings" \
    "internal bearings skill must keep natural-language catch-up triggers"
  assert_grep 'what'\''s in the works' "$bearings" \
    "internal bearings skill must keep natural-language work-status triggers"
  assert_grep 'Use when the captain invokes /stow' "$stow" \
    "internal stow skill must keep the slash trigger for messages that reach the agent"
  assert_grep 'stow what you'\''ve learned' "$stow" \
    "internal stow skill must keep the natural-language stow trigger"
  pass "internal Firstmate skills keep their normal-text triggers"
}

test_readme_public_skill_tier_lists_both_public_skills() {
  local layout
  layout=$(awk '/^### Two-tier skill layout$/{capture=1; next} capture && /^## /{exit} capture' "$README")

  assert_contains "$layout" '`skills/stow`' \
    "README public skill tier must mention the public stow skill"
  assert_contains "$layout" '`skills/bearings`' \
    "README public skill tier must mention the public bearings skill"
  assert_contains "$layout" 'intentionally share no code with the firstmate-internal' \
    "README must keep public and internal skill responsibilities separate"
  pass "README records both public skills and the two-tier separation"
}

test_readme_documents_codex_skill_invocation
test_internal_harness_contract_keeps_codex_boundary
test_public_skills_include_stow_and_bearings
test_internal_skills_keep_normal_text_triggers
test_readme_public_skill_tier_lists_both_public_skills
