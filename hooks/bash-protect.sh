#!/usr/bin/env bash
# Agent Harness M2 — PreToolUse(Bash) protector.
#
# Defends the one thing the anti-forge guarantee actually rests on:
#   - .agent-harness/.gates/     sentinels, minted by PostToolUse(Skill) only
# user-prompt.txt is intentionally NOT guarded here: /branch must (over)write it
# every task, and its integrity is enforced where it is actually consumed — the
# commit-msg hook verifies sha256(user-prompt.txt)==current-task.json.prompt_hash
# before trusting its bytes, so a rewrite cannot smuggle a false prompt anywhere.
#
# Strategy:
#   1) If the command does not mention any protected path, allow.
#   2) If it does, reject any shell construct that could hide the path
#      (variable expansion, command substitution, backticks, eval). This
#      defeats `path=...; rm $path` and `rm $(echo .../forged.done)` style
#      bypasses without trying to parse shell properly.
#   3) Reject the common write/copy/move/delete verbs against the protected
#      paths.
set -u

input="$(cat)"

# Defined before command extraction: the no-jq path below consults it to decide
# whether an unparseable payload must fail closed.
protected_re='\.agent-harness/\.gates'

command_str=""
if command -v jq >/dev/null 2>&1; then
  command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
else
  # No jq: sed cannot robustly unescape a JSON string, so a best-effort parse can
  # miss a protected path hidden after an escaped quote. If the raw payload refers
  # to the gates dir at all, fail closed rather than trust the parse. Scope the
  # fail-closed to the protected dir only, so /branch's legitimate jq-less writes
  # to .agent-harness/user-prompt.txt and current-task.json still go through.
  if printf '%s' "$input" | grep -qE "$protected_re"; then
    echo "M2 bash-protect: jq unavailable and payload references .agent-harness/.gates; refusing (cannot safely parse without jq)." >&2
    exit 2
  fi
  command_str="$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -z "$command_str" ] && exit 0

# Glob inside .agent-harness/ would expand to include protected paths at
# shell-execution time, so block it before the fast path. Match any glob
# metacharacter (*, ?, [) anywhere in the path segment that begins with
# .agent-harness/ — including patterns like .agent-harness/.*  which slip
# past a "char-immediately-after-slash" check.
if printf '%s' "$command_str" | grep -qE '\.agent-harness/[^[:space:]|;&"'"'"']*[*?\[]'; then
  echo "M2 bash-protect: glob inside .agent-harness/ could reach protected paths." >&2
  exit 2
fi

# find/xargs path-recursive deletion against .agent-harness/ bypasses the
# literal-path verb check by separating the rm from the protected name. Once
# .agent-harness is the search root, reject -exec/-delete/-print0/-name so
# the recursion cannot enumerate into protected files.
if printf '%s' "$command_str" | grep -qE 'find[[:space:]]+[^|;&]*\.agent-harness'; then
  if printf '%s' "$command_str" | grep -qE '(-exec|-delete|-print0|-name)'; then
    echo "M2 bash-protect: find with -exec/-delete/-print0/-name on .agent-harness/ is not permitted." >&2
    exit 2
  fi
fi
if printf '%s' "$command_str" | grep -qE '\.agent-harness'; then
  if printf '%s' "$command_str" | grep -qE '\bxargs\b'; then
    echo "M2 bash-protect: xargs in a command touching .agent-harness/ is not permitted." >&2
    exit 2
  fi
fi

# Fast path: command does not mention any protected resource.
printf '%s' "$command_str" | grep -qE "$protected_re" || exit 0

# Once a protected path is mentioned, refuse any shell construct that could
# hide the operand from the literal-grep checks below.
if printf '%s' "$command_str" | grep -qE '(\$\{?[A-Za-z_]|\$\(|`|\beval\b|\bxargs\b)'; then
  echo "M2 bash-protect: shell expansion or eval near protected harness paths is not permitted." >&2
  exit 2
fi

# Verbs that would write, copy, move, or delete a protected target.
verbs='(>|>>|tee[[:space:]]|cp[[:space:]]|install[[:space:]]|dd[[:space:]]|ln[[:space:]]|mv[[:space:]]|rm[[:space:]]|rmdir[[:space:]]|truncate[[:space:]]|shred[[:space:]])'

if printf '%s' "$command_str" | grep -qE "${verbs}[^|;&]*(${protected_re})"; then
  echo "M2 bash-protect: write/copy/move/delete against a protected harness path is hook-managed." >&2
  exit 2
fi

exit 0
