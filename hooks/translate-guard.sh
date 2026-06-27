#!/usr/bin/env bash
# Agent Harness M2 — translate gate.
# Blocks Edit/Write unless:
#   1. current-task.json is well-formed and matches the current branch / prompt
#   2. the platform-signed sentinels .agent-harness/.gates/{branch,map}.done
#      both exist and match the current branch + prompt_hash
#   3. JSON phase.translate is "done"
# Also refuses Edit/Write whose file_path lives under .gates/.
set -u

state_file=".agent-harness/current-task.json"
prompt_file=".agent-harness/user-prompt.txt"
gates_dir=".agent-harness/.gates"

block() {
  echo "$1" >&2
  exit 2
}

escape_ere() {
  printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

state_value() {
  local key="$1"
  sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$state_file" | head -n 1
}

hash_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    return 1
  fi
}

phase_done() {
  local phase="$1"
  if command -v jq >/dev/null 2>&1; then
    [ "$(jq -r ".phase.$phase // \"\"" "$state_file" 2>/dev/null)" = "done" ]
    return
  fi
  awk '/"phase"[[:space:]]*:[[:space:]]*\{/,/\}/' "$state_file" |
    grep -Eq "\"$phase\"[[:space:]]*:[[:space:]]*\"done\""
}

input="$(cat 2>/dev/null || true)"
if command -v jq >/dev/null 2>&1; then
  file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
else
  file_path="$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

if [ -n "$file_path" ]; then
  rel_path="${file_path#./}"
  if [ "${rel_path#/}" != "$rel_path" ]; then
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$git_root" ] && rel_path="${rel_path#$git_root/}"
  fi
  case "$rel_path" in
    .agent-harness/.gates/*)
      block "M2 translate gate: $rel_path is hook-managed. Edits to .agent-harness/.gates/ are not permitted."
      ;;
  esac
fi

[ -f "$state_file" ] || block "M2 blocked Edit: current-task.json is missing. Run /branch -> /map -> /translate."

grep -Eq '"schema"[[:space:]]*:[[:space:]]*1' "$state_file" ||
  block "M2 blocked Edit: current-task.json has no supported schema. Run /branch."

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ -n "$branch" ]; then
  branch_re="$(escape_ere "$branch")"
  grep -Eq "\"branch\"[[:space:]]*:[[:space:]]*\"$branch_re\"" "$state_file" ||
    block "M2 blocked Edit: current-task branch does not match ${branch}. Run /branch."
fi

expected_prompt_hash="$(state_value prompt_hash)"
[ -n "$expected_prompt_hash" ] || block "M2 blocked Edit: prompt_hash missing from current-task.json. Run /branch."
[ -f "$prompt_file" ] || block "M2 blocked Edit: user-prompt.txt missing (integrity check required). Run /branch."
actual_prompt_hash="$(hash_file "$prompt_file")" ||
  block "M2 blocked Edit: cannot verify prompt_hash; install sha256sum or shasum."
[ "$expected_prompt_hash" = "sha256:$actual_prompt_hash" ] ||
  block "M2 blocked Edit: prompt hash mismatch for current task. Run /branch."

# Sentinel check (bypass defense): /branch, /map AND /translate must have
# actually been invoked via the Skill tool, not faked via JSON tampering.
# (Including translate.done here is defense-in-depth alongside scope-guard.)
for prev in branch map translate; do
  sentinel="$gates_dir/${prev}.done"
  [ -f "$sentinel" ] ||
    block "M2 translate gate: platform-signed sentinel for /${prev} is missing. The skill must actually be invoked. Run /${prev}."
  grep -q "^branch=${branch}$" "$sentinel" 2>/dev/null ||
    block "M2 translate gate: ${prev}.done sentinel does not match current branch (${branch}). Run /${prev}."
  if [ -n "$expected_prompt_hash" ]; then
    grep -q "^prompt_hash=${expected_prompt_hash}$" "$sentinel" 2>/dev/null ||
      block "M2 translate gate: ${prev}.done sentinel does not match current prompt_hash. Run /${prev}."
  fi
done

phase_done translate || block "M2 blocked Edit: translate is not done for current task. Run /translate."

exit 0
