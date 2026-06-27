#!/usr/bin/env bash
# Agent Harness M2 — regression test for the bypass-defense layers.
#
# Spins up a throw-away git repo with a synthetic harness state, then runs
# each guard hook against a series of probe commands that correspond to
# specific red-team findings closed by commits 0c9a7e1, 2c9263b, 81d9c6b,
# and 48932fa. Every probe prints PASS/FAIL based on whether the hook's
# exit code matches the expectation.
#
# Usage: tests/verify-bypass-defenses.sh [hooks_dir]
#   hooks_dir defaults to the canonical <repo>/hooks
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="${1:-$REPO_ROOT/hooks}"

[ -d "$HOOKS" ] || { echo "FAIL: hooks dir not found: $HOOKS" >&2; exit 1; }
for h in branch-guard map-guard translate-guard scope-guard bash-protect skill-postrun; do
  [ -x "$HOOKS/$h.sh" ] || { echo "FAIL: $HOOKS/$h.sh missing or not executable" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
git init -q
# CI runners have no global git identity; without this the bootstrap commit
# fails ("Author identity unknown"), leaving an unborn HEAD where
# `git rev-parse --abbrev-ref HEAD` errors. The guards then see an empty branch,
# every sentinel branch-check (^branch=$) mismatches, and the allow-cases block.
git config user.email "ci@agent-harness.invalid"
git config user.name "agent-harness-ci"
git commit --allow-empty -m bootstrap -q 2>/dev/null
git checkout -b test-branch -q

mkdir -p .agent-harness/.gates
printf 'test prompt\n' > .agent-harness/user-prompt.txt
HASH="$(shasum -a 256 .agent-harness/user-prompt.txt | awk '{print $1}')"

# A PATH carrying bash-protect's required externals but NOT jq, so the no-jq
# branch can be exercised even on machines that have jq. Symlinking the real
# tools (instead of stripping jq's dir from PATH) stays correct even when jq
# shares a directory with grep/sed (e.g. /usr/bin on CI runners).
NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
for _t in bash cat grep sed head; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -s "$_p" "$NOJQ_BIN/$_t"
done

writestate() {
  local scope_files_json="$1"
  local new_allowed="${2:-true}"
  cat > .agent-harness/current-task.json <<JSON
{"schema":1,"branch":"test-branch","prompt_hash":"sha256:$HASH","phase":{"branch":"done","map":"done","translate":"done"},"scope":{"files":$scope_files_json,"new_files_allowed":$new_allowed}}
JSON
}
writesentinels() {
  for g in branch map translate; do
    printf 'skill=%s\nprompt_hash=sha256:%s\nbranch=test-branch\n' "$g" "$HASH" > ".agent-harness/.gates/${g}.done"
  done
}
restore_prompt() {
  printf 'test prompt\n' > .agent-harness/user-prompt.txt
}

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }

probe_bash_expect() {
  local label="$1" expect_exit="$2" cmd="$3"
  local actual_exit
  actual_exit="$(printf '%s' "{\"tool_input\":{\"command\":$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}" \
    | bash "$HOOKS/bash-protect.sh" >/dev/null 2>&1; echo $?)"
  if [ "$actual_exit" = "$expect_exit" ]; then
    pass
  else
    fail "$label  expected exit=$expect_exit, got $actual_exit  cmd: $cmd"
  fi
}
probe_edit_expect() {
  local label="$1" expect_exit="$2" file="$3" hook="$4"
  local actual_exit
  actual_exit="$(printf '%s' "{\"tool_input\":{\"file_path\":\"$file\"}}" \
    | bash "$HOOKS/$hook" >/dev/null 2>&1; echo $?)"
  if [ "$actual_exit" = "$expect_exit" ]; then
    pass
  else
    fail "$label  expected exit=$expect_exit, got $actual_exit  file: $file  hook: $hook"
  fi
}
probe_skill_expect() {
  local label="$1" expect_exit="$2" skill="$3"
  local actual_exit
  actual_exit="$(printf '%s' "{\"tool_input\":{\"skill\":\"$skill\"}}" \
    | bash "$HOOKS/skill-postrun.sh" >/dev/null 2>&1; echo $?)"
  if [ "$actual_exit" = "$expect_exit" ]; then
    pass
  else
    fail "$label  expected exit=$expect_exit, got $actual_exit  skill: $skill"
  fi
}
# Run bash-protect.sh with jq forced absent (PATH limited to NOJQ_BIN) to
# exercise its no-jq sed-fallback / fail-closed path.
probe_bash_nojq_expect() {
  local label="$1" expect_exit="$2" cmd="$3"
  local payload actual_exit
  payload="{\"tool_input\":{\"command\":$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}}"
  actual_exit="$(printf '%s' "$payload" | PATH="$NOJQ_BIN" bash "$HOOKS/bash-protect.sh" >/dev/null 2>&1; echo $?)"
  if [ "$actual_exit" = "$expect_exit" ]; then
    pass
  else
    fail "$label  expected exit=$expect_exit, got $actual_exit  cmd: $cmd"
  fi
}

# ---------------------------------------------------------------------------
# Round 1 fixes
# ---------------------------------------------------------------------------
writestate '["foo.txt"]'; writesentinels

# A — delete user-prompt.txt then /map should refuse to mint a new sentinel
rm -f .agent-harness/user-prompt.txt
rm -f .agent-harness/.gates/map.done
probe_skill_expect "R1-A: skill-postrun refuses without user-prompt.txt" 0 map
[ ! -f .agent-harness/.gates/map.done ] || fail "R1-A: map.done minted despite missing user-prompt.txt"
restore_prompt; writesentinels

# B — guards refuse Edit when user-prompt.txt missing
rm -f .agent-harness/user-prompt.txt
probe_edit_expect "R1-B: map-guard refuses (no user-prompt.txt)"       2 foo.txt map-guard.sh
probe_edit_expect "R1-B: translate-guard refuses (no user-prompt.txt)" 2 foo.txt translate-guard.sh
restore_prompt

# C — bash-protect refuses cp/ln/install/dd into .gates/
probe_bash_expect "R1-C: bash-protect refuses cp into .gates/"      2 'cp /tmp/forged .agent-harness/.gates/branch.done'
probe_bash_expect "R1-C: bash-protect refuses ln into .gates/"      2 'ln -s /tmp/forged .agent-harness/.gates/branch.done'
probe_bash_expect "R1-C: bash-protect refuses install into .gates/" 2 'install -m 644 /tmp/forged .agent-harness/.gates/branch.done'
probe_bash_expect "R1-C: bash-protect refuses dd into .gates/"      2 'dd if=/tmp/forged of=.agent-harness/.gates/branch.done'

# D — bash-protect refuses variable expansion / command substitution / backticks
probe_bash_expect "R1-D: var-rm \$path"  2 'p=.agent-harness/.gates/branch.done; rm $p'
probe_bash_expect "R1-D: var-cp \$path"  2 'p=.agent-harness/.gates; cp /tmp/forged $p/branch.done'
probe_bash_expect "R1-D: cmd-substitution" 2 'f=$(echo .agent-harness/.gates/branch.done); rm $f'
probe_bash_expect "R1-D: backtick"       2 'rm `echo .agent-harness/.gates/branch.done`'

# E — user-prompt.txt is intentionally NOT bash-protected (the /branch deadlock
# fix): bash-protect must ALLOW /branch to write and hash it, while .gates stays
# locked. The file's integrity moved to the commit-msg hook (Round 4).
probe_bash_expect "R1-E: bash-protect allows /branch to write user-prompt.txt" 0 'printf %s "$P" > .agent-harness/user-prompt.txt'
probe_bash_expect "R1-E: bash-protect allows hashing user-prompt.txt"          0 'h=$(shasum -a 256 .agent-harness/user-prompt.txt)'
probe_bash_expect "R1-E: .gates stays locked after narrowing"                  2 'rm .agent-harness/.gates/branch.done'

# F — scope-guard refuses stale translate.done replay (prompt_hash mismatch)
writesentinels
printf 'NEW prompt\n' > .agent-harness/user-prompt.txt
NEW_HASH="$(shasum -a 256 .agent-harness/user-prompt.txt | awk '{print $1}')"
cat > .agent-harness/current-task.json <<JSON
{"schema":1,"branch":"test-branch","prompt_hash":"sha256:$NEW_HASH","phase":{"branch":"done","map":"done","translate":"done"},"scope":{"files":["foo.txt"],"new_files_allowed":true}}
JSON
probe_edit_expect "R1-F: scope-guard refuses stale sentinel replay" 2 foo.txt scope-guard.sh
restore_prompt; writestate '["foo.txt"]'; writesentinels

# G — phase_done refuses top-level "map":"done" forge
cat > .agent-harness/current-task.json <<JSON
{"schema":1,"branch":"test-branch","prompt_hash":"sha256:$HASH","phase":{"branch":"done"},"map":"done","scope":{"files":["foo.txt"],"new_files_allowed":true}}
JSON
probe_edit_expect "R1-G: map-guard refuses top-level sibling phase forge" 2 foo.txt map-guard.sh
writestate '["foo.txt"]'; writesentinels

# H — scope-guard refuses '..' path traversal
probe_edit_expect "R1-H: scope-guard refuses .. traversal"      2 "foo.txt/../etc/passwd" scope-guard.sh
probe_edit_expect "R1-H: scope-guard refuses leading .." 2 "../outside.txt"        scope-guard.sh

# I — scope-guard refuses symlinks
ln -s /tmp/anywhere link-foo.txt 2>/dev/null
probe_edit_expect "R1-I: scope-guard refuses symlink target" 2 link-foo.txt scope-guard.sh

# J — sanity: in-scope edits pass
probe_edit_expect "R1-J: map-guard allows in-scope file"       0 foo.txt map-guard.sh
probe_edit_expect "R1-J: translate-guard allows in-scope file" 0 foo.txt translate-guard.sh
probe_edit_expect "R1-J: scope-guard allows in-scope file"     0 foo.txt scope-guard.sh

# ---------------------------------------------------------------------------
# Round 2 fixes
# ---------------------------------------------------------------------------
# K — bash-protect refuses glob inside .agent-harness/
probe_bash_expect "R2-K: rm .agent-harness/*"         2 'rm .agent-harness/*'
probe_bash_expect "R2-K: rm -rf .agent-harness/.*"    2 'rm -rf .agent-harness/.*'
probe_bash_expect "R2-K: rm .agent-harness/?ates"     2 'rm -rf .agent-harness/?ates'
probe_bash_expect "R2-K: rm .agent-harness/[ug]*"     2 'rm .agent-harness/[ug]*'

# L — branch-guard refuses Edit/Write to user-prompt.txt
probe_edit_expect "R2-L: branch-guard refuses Edit of user-prompt.txt" 2 ".agent-harness/user-prompt.txt" branch-guard.sh

# M — translate-guard refuses when only branch.done present
rm -f .agent-harness/.gates/map.done
probe_edit_expect "R2-M: translate-guard refuses without map.done" 2 foo.txt translate-guard.sh
writesentinels

# N/O — scope-guard refuses bare/leading-glob scope.files patterns
writestate '["*"]';     probe_edit_expect "R2-N: scope=['*'] rejected"     2 anything.txt scope-guard.sh
writestate '["*.ts"]';  probe_edit_expect "R2-O: scope=['*.ts'] rejected" 2 anything.ts  scope-guard.sh
writestate '["foo.txt"]'

# P — sanity: legitimate dir-anchored glob works
writestate '["src/*.ts"]'
mkdir -p src
probe_edit_expect "R2-P: scope=['src/*.ts'] allows src/foo.ts" 0 src/foo.ts scope-guard.sh
writestate '["foo.txt"]'

# ---------------------------------------------------------------------------
# Round 3 fixes
# ---------------------------------------------------------------------------
# Q — find with -exec / -delete / -name on .agent-harness/ rejected
probe_bash_expect "R3-Q: find -exec rm"     2 'find .agent-harness -type f -exec rm {} \;'
probe_bash_expect "R3-Q: find -delete"      2 'find .agent-harness -delete'
probe_bash_expect "R3-Q: find -name -exec" 2 'find .agent-harness -name "*.done" -exec rm {} \;'

# R — xargs near .agent-harness/ rejected
probe_bash_expect "R3-R: ls piped to xargs" 2 'ls .agent-harness | xargs rm'

# S/T — scope patterns that match outside their directory are rejected
writestate '["src**"]';  probe_edit_expect "R3-S: scope=['src**'] rejected"  2 srcfoo/secret.ts scope-guard.sh
writestate '["src*"]';   probe_edit_expect "R3-T: scope=['src*'] rejected"  2 srcfoo.ts        scope-guard.sh

# U — scope with slash before glob works
writestate '["src/*.ts"]'
probe_edit_expect "R3-U: scope=['src/*.ts'] allows src/foo.ts" 0 src/foo.ts scope-guard.sh

# V — branch-guard refuses Edit/Write to current-task.json
probe_edit_expect "R3-V: branch-guard refuses Edit of current-task.json" 2 ".agent-harness/current-task.json" branch-guard.sh

# ---------------------------------------------------------------------------
# Round 4 — commit-msg integrity (user-prompt.txt's defense moved here once
# bash-protect stopped guarding the file so the /branch deadlock could be fixed)
# ---------------------------------------------------------------------------
COMMIT_MSG="$REPO_ROOT/hooks/commit-msg.sh"
# W — appends the prompt when user-prompt.txt matches current-task.json hash
printf 'real prompt\n' > .agent-harness/user-prompt.txt
H4="$(shasum -a 256 .agent-harness/user-prompt.txt | awk '{print $1}')"
cat > .agent-harness/current-task.json <<JSON
{"schema":1,"branch":"test-branch","prompt_hash":"sha256:$H4","phase":{"branch":"done","map":"done","translate":"done"},"scope":{"files":["foo.txt"],"new_files_allowed":true}}
JSON
printf 'feat: x\n' > msg-match
bash "$COMMIT_MSG" msg-match >/dev/null 2>&1
if grep -q '^User prompt: real prompt' msg-match; then pass; else fail "R4-W: commit-msg should append a hash-matching prompt"; fi
# X — refuses a swapped (hash-mismatched) prompt, so no forge reaches history
printf 'FORGED prompt\n' > .agent-harness/user-prompt.txt
printf 'feat: y\n' > msg-forge
bash "$COMMIT_MSG" msg-forge >/dev/null 2>&1
if grep -q '^User prompt:' msg-forge; then fail "R4-X: commit-msg appended a forged (mismatched) prompt"; else pass; fi

# ---------------------------------------------------------------------------
# Round 5 — empty scope.files must fail closed (no silent fall-open). The old
# `[ -z "$scope_files" ] && exit 0` turned the 4th gate into a no-op whenever
# /translate recorded an empty scope.
# ---------------------------------------------------------------------------
restore_prompt; writestate '["foo.txt"]'; writesentinels
touch existing-in-scope.txt
writestate '[]' true
probe_edit_expect "R5-Z1: empty scope blocks edit of existing file"           2 existing-in-scope.txt scope-guard.sh
writestate '[]' false
probe_edit_expect "R5-Z2: empty scope blocks new file when !new_allowed"       2 brand-new.txt        scope-guard.sh
writestate '[]' true
probe_edit_expect "R5-Z3: empty scope still allows a new file w/ new_allowed"   0 brand-new-2.txt      scope-guard.sh
writestate '["foo.txt"]'

# ---------------------------------------------------------------------------
# Round 6 — environment-dependent fail-open fixes (jq absence, repo-external
# absolute paths). These close the High findings where a guard's protection
# silently weakened depending on the environment it ran in.
# ---------------------------------------------------------------------------
restore_prompt; writestate '["foo.txt"]' true; writesentinels

# AA — bash-protect must fail closed (not fall open) when jq is absent and the
# payload targets .gates/. Old behavior: no jq -> command_str="" -> exit 0.
probe_bash_nojq_expect "R6-AA: no-jq fail-closed on rm into .gates/"          2 'rm .agent-harness/.gates/branch.done'
probe_bash_nojq_expect "R6-AA: no-jq fail-closed on cp into .gates/"          2 'cp /tmp/forged .agent-harness/.gates/translate.done'
# AB — the no-jq sed fallback still restores the glob defense (.agent-harness/*).
probe_bash_nojq_expect "R6-AB: no-jq still blocks glob in .agent-harness/"     2 'rm -rf .agent-harness/*'
# AC — the fail-closed is scoped to .gates only, so /branch's jq-less write and
# hash of user-prompt.txt must still be allowed (else /branch breaks without jq).
probe_bash_nojq_expect "R6-AC: no-jq allows /branch write of user-prompt.txt"  0 'printf %s "$P" > .agent-harness/user-prompt.txt'
probe_bash_nojq_expect "R6-AC: no-jq allows hashing user-prompt.txt"           0 'shasum -a 256 .agent-harness/user-prompt.txt'

# AD — scope-guard must block a repo-external absolute path, not silently treat
# it as a brand-new in-scope file. Old behavior allowed it when new_files_allowed.
probe_edit_expect "R6-AD: scope-guard blocks repo-external absolute path"      2 "/tmp/ah-outside-probe.txt" scope-guard.sh
# AE — sanity: an absolute path INSIDE the repo still normalizes and passes.
GITROOT="$(git rev-parse --show-toplevel)"
probe_edit_expect "R6-AE: scope-guard allows in-repo absolute path"            0 "$GITROOT/foo.txt" scope-guard.sh
writestate '["foo.txt"]'

# ---------------------------------------------------------------------------
echo
echo "tests passed: $PASS"
echo "tests failed: $FAIL"
[ "$FAIL" = "0" ] && { echo "ALL GREEN"; exit 0; } || { echo "FAILURES"; exit 1; }
