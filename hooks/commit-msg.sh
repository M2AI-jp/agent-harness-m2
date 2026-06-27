#!/usr/bin/env bash
# Git commit-msg hook: append the verbatim user prompt from
# .agent-harness/user-prompt.txt to the commit body, but ONLY when the file
# still hashes to the prompt_hash recorded in .agent-harness/current-task.json.
# That hash is the anchor every guard already trusts; verifying it here is the
# one place user-prompt.txt's integrity is enforced now that bash-protect guards
# only .agent-harness/.gates/. A prompt swapped out of band therefore never
# reaches history. Human commits with no harness state pass through untouched.
set -u

commit_msg_file="$1"
source="${2:-}"
prompt_file=".agent-harness/user-prompt.txt"
state_file=".agent-harness/current-task.json"

# Skip merge commits
[ "$source" = "merge" ] && exit 0

# Nothing to append, or already appended
[ -f "$prompt_file" ] || exit 0
grep -q "^User prompt:" "$commit_msg_file" && exit 0

# Integrity gate: trust user-prompt.txt only if it matches the recorded hash.
# No state file, no recorded hash, or no sha256 tool => do not append.
[ -f "$state_file" ] || exit 0
expected="$(sed -nE 's/.*"prompt_hash"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$state_file" | head -n 1)"
[ -n "$expected" ] || exit 0
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$prompt_file" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$prompt_file" | awk '{print $1}')"
else
  exit 0
fi
[ "$expected" = "sha256:$actual" ] || exit 0

# Auto-append the verified user prompt
{
  echo ""
  printf "User prompt: "
  cat "$prompt_file"
  echo ""
} >> "$commit_msg_file"

exit 0
