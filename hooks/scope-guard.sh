#!/usr/bin/env bash
# Agent Harness M2 — scope gate (4th gate).
# Blocks Edit/Write to files outside the /translate scope. Also enforces the
# platform-signed sentinel chain: branch -> map -> translate must all have
# fired the Skill tool. Without that, the scope field cannot be trusted.
set -u

state_file=".agent-harness/current-task.json"
gates_dir=".agent-harness/.gates"

input="$(cat 2>/dev/null || true)"

if command -v jq >/dev/null 2>&1; then
  file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
else
  file_path="$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

[ -z "$file_path" ] && exit 0

# Other guards handle missing state — fall open so we don't double-block.
[ -f "$state_file" ] || exit 0
# phase.translate must be done. Use jq if available; else awk-window inside
# the phase object body so a sibling top-level field cannot satisfy it.
if command -v jq >/dev/null 2>&1; then
  [ "$(jq -r '.phase.translate // ""' "$state_file" 2>/dev/null)" = "done" ] || exit 0
else
  awk '/"phase"[[:space:]]*:[[:space:]]*\{/,/\}/' "$state_file" |
    grep -Eq '"translate"[[:space:]]*:[[:space:]]*"done"' || exit 0
fi

block() {
  echo "$1" >&2
  exit 2
}

# Insist on the trusted sentinel chain. translate-guard already verifies
# branch.done and map.done; here we add translate.done because *scope is
# only meaningful once /translate actually ran via the Skill tool*.
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
sentinel="$gates_dir/translate.done"
[ -f "$sentinel" ] ||
  block "M2 scope gate: platform-signed sentinel for /translate is missing. Run /translate."
if [ -n "$branch" ]; then
  grep -q "^branch=${branch}$" "$sentinel" 2>/dev/null ||
    block "M2 scope gate: translate.done sentinel does not match current branch (${branch}). Run /translate."
fi
# Also check that the sentinel matches the current prompt_hash, to defeat
# replay of a stale translate.done from an earlier task on the same branch.
expected_prompt_hash="$(sed -nE 's/.*"prompt_hash"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$state_file" | head -n 1)"
if [ -n "$expected_prompt_hash" ]; then
  grep -q "^prompt_hash=${expected_prompt_hash}$" "$sentinel" 2>/dev/null ||
    block "M2 scope gate: translate.done sentinel does not match current prompt_hash. Run /translate."
fi

# Extract scope files
if command -v jq >/dev/null 2>&1; then
  scope_files="$(jq -r '.scope.files[]? // empty' "$state_file" 2>/dev/null)"
  new_allowed="$(jq -r '.scope.new_files_allowed // false' "$state_file" 2>/dev/null)"
else
  scope_files="$(awk '
    /"files"[[:space:]]*:[[:space:]]*\[/ { inarr=1; next }
    inarr && /\]/ { inarr=0 }
    inarr && match($0, /"[^"]+"/) {
      s = substr($0, RSTART+1, RLENGTH-2); print s
    }
  ' "$state_file")"
  new_allowed="$(sed -nE 's/.*"new_files_allowed"[[:space:]]*:[[:space:]]*(true|false).*/\1/p' "$state_file" | head -1)"
  [ -z "$new_allowed" ] && new_allowed="false"
fi

# Normalize the target path. An absolute path must resolve inside the repo; a
# repo-external absolute path is blocked outright rather than left as-is, where
# the scope / new_files_allowed branches below would silently treat it as a
# brand-new in-scope file. Non-absolute input is taken as repo-relative.
case "$file_path" in
  /*)
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$git_root" ] ||
      block "M2 scope gate: absolute path is not allowed outside a git repo: $file_path"
    case "$file_path" in
      "$git_root"/*) rel_path="${file_path#"$git_root"/}" ;;
      *) block "M2 scope gate: absolute path outside the repo is not allowed: $file_path" ;;
    esac
    ;;
  *)
    rel_path="${file_path#./}"
    ;;
esac

# Reject path traversal and newlines before any pattern matching.
case "$rel_path" in
  *..*|*$'\n'*)
    block "M2 scope gate: rejected path with '..' or newline: $rel_path"
    ;;
esac
# Reject symlinks; scope.files patterns describe real targets, not links.
if [ -L "$rel_path" ]; then
  block "M2 scope gate: $rel_path is a symlink; symlinks are not editable through scope."
fi

# .agent-harness/.gates/ is always forbidden — beats everything else.
case "$rel_path" in
  .agent-harness/.gates/*)
    block "M2 scope gate: $rel_path is hook-managed. Edits to .agent-harness/.gates/ are not permitted."
    ;;
esac

# .agent-harness/ (other than .gates/) is allowed: that is the harness's own
# state and the skills need to write it.
case "$rel_path" in
  .agent-harness/*) exit 0 ;;
esac

# Empty scope fails closed (previously fell open, silently disabling the gate).
# A declared task must name the files it edits; a brand-new file is allowed only
# when /translate explicitly set new_files_allowed.
if [ -z "$scope_files" ]; then
  if [ ! -f "$rel_path" ] && [ "$new_allowed" = "true" ]; then
    exit 0
  fi
  block "M2 scope gate: this task declared an empty scope.files. Re-run /translate to record the file(s) you intend to edit."
fi

# Match against declared scope (exact or glob). Reject scope patterns that
# could match outside their intended directory. The rule: if a pattern
# contains any glob char (*, ?, [) at all, the first such char must be
# preceded by at least one '/' so the pattern is directory-anchored.
# 'src/*.ts'  OK  — slash precedes *
# 'src/*'     OK
# 'src*'      REJECT — no slash before the glob, matches 'srcfoo'
# 'src**'     REJECT
# '*.ts'      REJECT
# 'foo.ts'    OK   — no glob at all (exact)
# '/abs'      REJECT — absolute
match=false
while IFS= read -r pattern; do
  [ -z "$pattern" ] && continue
  case "$pattern" in
    /*)
      block "M2 scope gate: scope.files pattern '$pattern' must be a repo-relative path." ;;
  esac
  case "$pattern" in
    *[*?\[]*)
      # Pattern has at least one glob char. Require '/' before the first one.
      prefix="$(printf '%s' "$pattern" | sed -E 's/[*?[].*//')"
      case "$prefix" in
        */*) ;;  # slash precedes glob → directory-anchored, OK
        *)
          block "M2 scope gate: scope.files pattern '$pattern' is not directory-anchored — anchor with a '/' before any *, ?, or [." ;;
      esac
      ;;
  esac
  case "$rel_path" in
    $pattern) match=true; break ;;
  esac
  case "$pattern" in
    *\*) ;;
    */)
      case "$rel_path" in
        ${pattern}*) match=true; break ;;
      esac
      ;;
  esac
done <<EOF
$scope_files
EOF

if [ "$match" = true ]; then
  exit 0
fi

# Out of scope: allow if it's a brand-new file and new_files_allowed=true.
if [ ! -f "$rel_path" ] && [ "$new_allowed" = "true" ]; then
  exit 0
fi

{
  echo "M2 scope gate: $rel_path is outside the /translate scope."
  echo "Declared scope:"
  printf '%s\n' "$scope_files" | sed 's/^/  - /'
  echo "To extend scope, re-run /translate so it can record the new file."
} >&2
exit 2
