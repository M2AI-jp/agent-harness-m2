#!/usr/bin/env bash
# Agent Harness M2 — PostToolUse(Skill) sentinel writer.
# Fires only when Claude actually invokes the Skill tool. The AI cannot
# forge this firing — it is the platform's own event. So the sentinel
# this hook writes is the trusted record that a gate skill ran for this
# (branch, prompt_hash) pair.
#
# Guards downstream MUST consult the sentinel, not the JSON phase field
# alone, otherwise the harness is trivially bypassable by `cat > json`.
set -u

input="$(cat)"

if command -v jq >/dev/null 2>&1; then
  skill="$(printf '%s' "$input" | jq -r '.tool_input.skill // empty' 2>/dev/null)"
else
  skill="$(printf '%s' "$input" | sed -n 's/.*"skill"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

case "$skill" in
  branch|map|translate) ;;
  *) exit 0 ;;
esac

state_file=".agent-harness/current-task.json"
prompt_file=".agent-harness/user-prompt.txt"

# /branch is what creates the state file in the first place. If it isn't there
# yet (i.e. the user just kicked off /branch), give the skill a brief grace
# window: the SKILL.md writes state synchronously before its last tool call.
[ -f "$state_file" ] || exit 0

if command -v jq >/dev/null 2>&1; then
  prompt_hash="$(jq -r '.prompt_hash // empty' "$state_file" 2>/dev/null)"
  branch="$(jq -r '.branch // empty' "$state_file" 2>/dev/null)"
else
  prompt_hash="$(sed -nE 's/.*"prompt_hash"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$state_file" | head -1)"
  branch="$(sed -nE 's/.*"branch"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$state_file" | head -1)"
fi

# Mandatory integrity check: prompt_hash must be present and the
# user-prompt.txt file must exist and hash to the recorded value. The
# previous "if file exists then check" allowed bypass-by-deletion.
if [ -z "$prompt_hash" ]; then
  echo "M2 skill-postrun: prompt_hash missing in state; refusing to mint sentinel." >&2
  exit 0
fi
if [ ! -f "$prompt_file" ]; then
  echo "M2 skill-postrun: user-prompt.txt missing; refusing to mint sentinel. Run /branch." >&2
  exit 0
fi
if command -v sha256sum >/dev/null 2>&1; then
  actual_hash="$(sha256sum "$prompt_file" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  actual_hash="$(shasum -a 256 "$prompt_file" | awk '{print $1}')"
else
  echo "M2 skill-postrun: no sha256 tool available; refusing to mint sentinel." >&2
  exit 0
fi
if [ "$prompt_hash" != "sha256:$actual_hash" ]; then
  echo "M2 skill-postrun: refusing to mint sentinel; prompt_hash in state disagrees with user-prompt.txt." >&2
  exit 0
fi

mkdir -p .agent-harness/.gates
sentinel=".agent-harness/.gates/${skill}.done"
{
  printf 'skill=%s\n' "$skill"
  printf 'prompt_hash=%s\n' "$prompt_hash"
  printf 'branch=%s\n' "$branch"
  printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$sentinel"

# /branch resetting a session must invalidate the downstream sentinels —
# otherwise running /branch alone on a new task would leave stale
# map.done / translate.done behind.
if [ "$skill" = "branch" ]; then
  rm -f .agent-harness/.gates/map.done .agent-harness/.gates/translate.done
fi
if [ "$skill" = "map" ]; then
  rm -f .agent-harness/.gates/translate.done
fi

exit 0
