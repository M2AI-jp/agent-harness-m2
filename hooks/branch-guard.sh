#!/usr/bin/env bash
# Agent Harness M2 — branch gate.
# Refuses Edit/Write on main/master and refuses any Edit/Write whose
# file_path lives under the hook-managed .agent-harness/.gates/ directory.
set -u

input="$(cat 2>/dev/null || true)"

if command -v jq >/dev/null 2>&1; then
  file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
else
  file_path="$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

# Reject edits into the trusted sentinel dir from any tool — only
# PostToolUse(Skill) is allowed to write there.
if [ -n "$file_path" ]; then
  rel_path="${file_path#./}"
  if [ "${rel_path#/}" != "$rel_path" ]; then
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$git_root" ] && rel_path="${rel_path#$git_root/}"
  fi
  case "$rel_path" in
    .agent-harness/.gates/*)
      echo "M2 branch gate: $rel_path is hook-managed. Edits to .agent-harness/.gates/ are not permitted." >&2
      exit 2
      ;;
    .agent-harness/user-prompt.txt)
      echo "M2 branch gate: $rel_path is integrity-critical. Update it via the /branch skill heredoc, not Edit/Write." >&2
      exit 2
      ;;
    .agent-harness/current-task.json)
      echo "M2 branch gate: $rel_path is integrity-critical. Update it via a /branch or /translate skill STATE heredoc, not Edit/Write." >&2
      exit 2
      ;;
  esac
fi

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
case "$branch" in
  main|master)
    echo "Agent Harness M2 blocked this edit: create a working branch before editing ${branch}." >&2
    exit 2
    ;;
esac

exit 0
