#!/usr/bin/env bash
set -u

target="${1:-.}"
target_abs="$(cd "$target" && pwd)"
fail=0

check_file() {
  local file="$1"
  if [ -f "$target_abs/$file" ]; then
    echo "ok: $file"
  else
    echo "missing: $file"
    fail=1
  fi
}

check_absent() {
  local file="$1"
  if [ -e "$target_abs/$file" ]; then
    echo "legacy artifact present: $file"
    fail=1
  else
    echo "ok absent: $file"
  fi
}

check_exec() {
  local file="$1"
  if [ -x "$target_abs/$file" ]; then
    echo "ok executable: $file"
  else
    echo "missing executable: $file"
    fail=1
  fi
}

check_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if [ -f "$target_abs/$file" ] && grep -Fq "$needle" "$target_abs/$file"; then
    echo "ok: $label"
  else
    echo "missing: $label"
    fail=1
  fi
}

mentions_four_gates() {
  local file="$1"
  grep -Fq "/branch" "$file" &&
    grep -Fq "/map" "$file" &&
    grep -Fq "/translate" "$file" &&
    grep -Fq "scope-guard" "$file" &&
    grep -Fq "prompt" "$file"
}

check_doc_contract() {
  local file="$1"
  check_file "$file"
  if [ -f "$target_abs/$file" ] && mentions_four_gates "$target_abs/$file"; then
    echo "ok: $file mentions the four-gate contract"
  else
    echo "missing four-gate mention in $file (branch/map/translate/scope-guard + prompt)"
    fail=1
  fi
}

check_skill_set() {
  local skill_root="$1"
  local label="$2"

  for skill in branch map translate; do
    check_file "$skill_root/$skill/SKILL.md"
  done

  check_absent "$skill_root/orient"
  check_absent "$skill_root/verify-done"
  check_absent "$skill_root/ship"
  check_contains "$skill_root/branch/SKILL.md" ".agent-harness/current-task.json" "$label branch creates current-task.json"
  check_contains "$skill_root/branch/SKILL.md" ".agent-harness/current-task.md" "$label branch creates current-task.md"
  check_contains "$skill_root/branch/SKILL.md" ".agent-harness/user-prompt.txt" "$label branch preserves user prompt"
  check_contains "$skill_root/map/SKILL.md" '"map": "done"' "$label map marks phase.map done"
  check_contains "$skill_root/translate/SKILL.md" "phase.translate" "$label translate marks phase.translate done"
  check_contains "$skill_root/translate/SKILL.md" "scope.files" "$label translate records scope.files"
}

check_hook_set() {
  local hook_root="$1"
  local config_file="$2"
  local label="$3"
  local reminder

  check_file "$config_file"
  check_exec "$hook_root/entry-reminder.sh"
  check_exec "$hook_root/branch-guard.sh"
  check_exec "$hook_root/map-guard.sh"
  check_exec "$hook_root/translate-guard.sh"
  check_exec "$hook_root/scope-guard.sh"
  check_exec "$hook_root/skill-postrun.sh"
  check_exec "$hook_root/bash-protect.sh"
  check_absent "$hook_root/verify-done.sh"
  check_absent "$hook_root/strict-gate.sh"
  check_absent "$hook_root/nirai-guard.sh"

  check_contains "$config_file" "$hook_root/branch-guard.sh" "$label branch-guard wired"
  check_contains "$config_file" "$hook_root/map-guard.sh" "$label map-guard wired"
  check_contains "$config_file" "$hook_root/translate-guard.sh" "$label translate-guard wired"
  check_contains "$config_file" "$hook_root/scope-guard.sh" "$label scope-guard wired"
  check_contains "$config_file" "$hook_root/skill-postrun.sh" "$label skill-postrun wired (PostToolUse Skill)"
  check_contains "$config_file" "$hook_root/bash-protect.sh" "$label bash-protect wired"
  check_contains "$config_file" "Skill" "$label PostToolUse Skill matcher present"
  check_contains "$hook_root/map-guard.sh" ".agent-harness/current-task.json" "$label map-guard checks current-task.json"
  check_contains "$hook_root/map-guard.sh" "prompt hash mismatch" "$label map-guard checks prompt hash"
  check_contains "$hook_root/map-guard.sh" ".gates/branch.done" "$label map-guard requires branch.done sentinel"
  check_contains "$hook_root/translate-guard.sh" ".agent-harness/current-task.json" "$label translate-guard checks current-task.json"
  check_contains "$hook_root/translate-guard.sh" "prompt hash mismatch" "$label translate-guard checks prompt hash"
  check_contains "$hook_root/translate-guard.sh" "branch map" "$label translate-guard checks both prior sentinels"
  check_contains "$hook_root/scope-guard.sh" "scope.files" "$label scope-guard enforces scope.files"
  check_contains "$hook_root/skill-postrun.sh" ".agent-harness/.gates" "$label skill-postrun writes sentinel dir"
  check_contains "$hook_root/bash-protect.sh" ".agent-harness/.gates" "$label bash-protect guards sentinel dir"

  reminder="$(cd "$target_abs" && bash "$target_abs/$hook_root/entry-reminder.sh" 2>/dev/null || true)"
  if printf "%s\n" "$reminder" | grep -Fq "/branch -> /map -> /translate"; then
    echo "ok: $label entry reminder emits /branch -> /map -> /translate"
  else
    echo "missing: $label entry reminder emits /branch -> /map -> /translate"
    fail=1
  fi
}

echo "Agent Harness M2 doctor for $target_abs"

if [ -f "$target_abs/AGENTS.md" ]; then
  check_doc_contract "AGENTS.md"
fi

if [ -f "$target_abs/CLAUDE.md" ]; then
  check_doc_contract "CLAUDE.md"
fi

if [ -d "$target_abs/.codex" ]; then
  check_skill_set ".agents/skills" "Codex"
  check_hook_set ".codex/hooks" ".codex/hooks.json" "Codex"
elif [ -f "$target_abs/AGENTS.md" ]; then
  echo "note: AGENTS.md present but .codex/ not installed (skipping Codex install check)"
fi

if [ -d "$target_abs/.claude" ]; then
  check_skill_set ".claude/skills" "Claude"
  check_hook_set ".claude/hooks" ".claude/settings.json" "Claude"
elif [ -f "$target_abs/CLAUDE.md" ]; then
  echo "note: CLAUDE.md present but .claude/ not installed (skipping Claude install check)"
fi

check_absent ".agent-harness/verify"
check_absent ".agent-harness/map-done"
check_absent ".agent-harness/translate-done"

if [ -d "$target_abs/.git/hooks" ]; then
  check_exec ".git/hooks/commit-msg"
  check_contains ".git/hooks/commit-msg" "agent-harness/user-prompt.txt" "Git commit-msg reads user prompt"
  check_contains ".git/hooks/commit-msg" "User prompt:" "Git commit-msg appends User prompt"
  check_contains ".git/hooks/commit-msg" 'grep -q "^User prompt:"' "Git commit-msg avoids duplicate User prompt"
fi

check_contains ".gitignore" ".agent-harness/" ".gitignore excludes .agent-harness/"

for d in .codex .claude; do
  for h in "$target_abs/$d/hooks/"*.sh; do
    [ -f "$h" ] || continue
    if bash -n "$h" 2>/dev/null; then
      echo "ok syntax: ${h#$target_abs/}"
    else
      echo "bad syntax: ${h#$target_abs/}"
      fail=1
    fi
  done
done

if [ -f "$target_abs/.git/hooks/commit-msg" ]; then
  if bash -n "$target_abs/.git/hooks/commit-msg" 2>/dev/null; then
    echo "ok syntax: .git/hooks/commit-msg"
  else
    echo "bad syntax: .git/hooks/commit-msg"
    fail=1
  fi
fi

if command -v jq >/dev/null 2>&1; then
  for j in ".codex/hooks.json" ".claude/settings.json"; do
    if [ -f "$target_abs/$j" ]; then
      if jq empty "$target_abs/$j" >/dev/null 2>&1; then
        echo "ok: $j valid JSON"
      else
        echo "invalid JSON: $j"
        fail=1
      fi
    fi
  done
fi

if [ -x "$target_abs/tests/verify-bypass-defenses.sh" ]; then
  if bash "$target_abs/tests/verify-bypass-defenses.sh" >/dev/null 2>&1; then
    echo "ok: tests/verify-bypass-defenses.sh passes"
  else
    echo "FAIL: tests/verify-bypass-defenses.sh — run it directly to see which probe failed"
    fail=1
  fi
else
  echo "note: tests/verify-bypass-defenses.sh not present or not executable"
fi

if [ "$fail" -eq 0 ]; then
  echo "DOCTOR: PASS"
else
  echo "DOCTOR: FAIL"
fi

exit "$fail"
