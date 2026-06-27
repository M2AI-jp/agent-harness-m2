# Changelog

## 0.3.1 - 2026-06-28

- Remove the experimental `/ship` skill and its default install wiring. M3 core is back to the 4-gate pre-work path: `/branch -> /map -> /translate -> scope-guard`.
- `README.md` / `docs/technical-notes.md`: align the documented core with the 4-gate structure and state that GitHub workflow behavior is detection/recommendation only, not execution.
- `skills/map/SKILL.md`: keep `push-candidate` / `merge-candidate` surfacing, but remove `/ship` references and clarify that `/map` never commits, pushes, opens a PR, or merges.
- `.github/workflows/ci.yml`: remove the `skills/ship/SKILL.md` line-count assertion and assert that `/ship` is absent from the current contract.
- `bash-protect`: close the no-jq fail-open. When `jq` was absent, `command_str` stayed empty and the hook `exit 0`'d on every command, leaving `.agent-harness/.gates/` unprotected on machines without `jq` (e.g. stock macOS). It now (a) falls back to a `sed` extraction so the glob/find/xargs checks still run, and (b) fails closed when `jq` is unavailable and the raw payload references `.agent-harness/.gates` — robust against `sed`'s incomplete JSON unescaping. The fail-closed is scoped to the gates dir, so `/branch`'s jq-less writes to `user-prompt.txt` / `current-task.json` still pass.
- `scope-guard`: block repo-external absolute paths instead of treating them as brand-new in-scope files. An absolute `file_path` outside the Git root previously survived normalization unchanged and, with `new_files_allowed`, slipped through the new-file branch. Absolute paths are now allowed only under the Git root (converted to repo-relative); anything outside — or a non-Git root — is blocked. The identical normalization in `branch`/`map`/`translate-guard` is only used for the `.gates/*` check and is not exploitable, so it is left unchanged.
- `templates/claude/CLAUDE.md` / `templates/codex/AGENTS.md` (and the dogfooding root `CLAUDE.md` / `AGENTS.md`): soften the absolute "AI は偽造できない" claim about the sentinels. The agent-facing text now says they cannot be forged by ordinary Edit/Write or JSON `phase` rewrites, but states the real boundary — M2 is not an OS sandbox; a `Bash`/interpreter write or hook disable can still bypass it, so it is a tamper-evident protocol, not containment — matching `docs/technical-notes.md`.
- `tests/verify-bypass-defenses.sh`: add Round 6 regression probes for both fixes — bash-protect's no-jq fail-closed / sed-fallback (exercised via a jq-free `PATH`) and scope-guard's repo-external absolute-path block.
- `scripts/install-claude.sh` / `scripts/install-codex.sh`: stop silently overwriting an existing **unmanaged** `.claude/settings.json` / `.codex/hooks.json`, hook, or `.git/hooks/commit-msg`. The default now fails with a clear message; `--force` backs up and replaces (the previous always-backup-then-overwrite behavior). Already-M2-managed files are still replaced in place. Centralized in a `back_up_or_refuse` helper.
- `README.md`: add a warning that the raw prompt is persisted verbatim into Git commit bodies — do not put secrets, credentials, customer data, or private logs in prompts.
- `tests/verify-bypass-defenses.sh`: default `hooks_dir` to the canonical `<repo>/hooks` (was `.claude/hooks`), so a clean clone runs the suite without first installing.
- Fix the CI `Behavioral checks` job: it set `phase.map` / `phase.translate` to `done` without minting the platform-signed `.agent-harness/.gates/*.done` sentinels, so the hardened `map-guard` / `translate-guard` (which require a matching sentinel) blocked where the job expected success. The job now mints `branch` / `map` / `translate` sentinels for the synthetic task, matching the real `skill-postrun` contract.
- `scope-guard`: an empty `scope.files` now fails closed instead of falling open. The previous `[ -z "$scope_files" ] && exit 0` silently turned the 4th gate into a no-op whenever `/translate` recorded an empty scope; a brand-new file is still allowed only when `new_files_allowed` is set. Added Round 5 regression probes to `tests/verify-bypass-defenses.sh`.
- Document the `disableAllHooks` self-disable vector in `docs/technical-notes.md`: an agent can switch off all hooks via a `Bash` write to settings (M2 does not guard that path), so real resistance requires managed-policy hooks and/or not auto-approving `Bash`.
- `tests/verify-bypass-defenses.sh`: give the throwaway repo a git identity (`user.email` / `user.name`) before the bootstrap commit. On CI runners (no global identity) that commit failed, leaving an unborn HEAD; the guards then saw an empty branch and blocked every allow-case (`R1-J`, `R2-P`, `R3-U`). This had kept the suite red on CI — hidden until the `Behavioral checks` fix let CI reach the suite step.

## 0.3.0 - 2026-06-25

- Restore the 4th gate (`scope-guard`) and add the platform-signed sentinel chain (`.agent-harness/.gates/<skill>.done`, minted only by the `PostToolUse(Skill)` hook `skill-postrun.sh`) so a gate cannot be marked done by editing `current-task.json` alone.
- Add `bash-protect.sh` (PreToolUse Bash) guarding the sentinel directory, and `skill-postrun.sh` which hash-verifies `user-prompt.txt` before minting.
- Fix the `/branch` bootstrap deadlock: `bash-protect` now guards only `.agent-harness/.gates/`, so `/branch` can write `user-prompt.txt`. Its integrity check moves to `commit-msg.sh`, which appends the prompt to the commit body only when it still hashes to `current-task.json.prompt_hash`.
- Ship the full hook set from both installers — `scope-guard.sh`, `skill-postrun.sh`, and `bash-protect.sh` were previously not copied.
- Run `tests/verify-bypass-defenses.sh` in CI; stop tracking generated `.claude/` install copies.
- Make `/map`'s `push-candidate` surfacing actually work: Step 1 now runs `git status --short --branch`, so an unpushed-commit / no-upstream branch is visible. It was defined but never detected (the commands only saw local state), which let the remote sit silently neglected.

## 0.2.0 - 2026-06-18

- Replace empty `map-done` / `translate-done` authorization files with task-aware `.agent-harness/current-task.json`.
- Add `.agent-harness/current-task.md` as the short LLM-readable task summary.
- Make guards verify current branch, prompt hash, schema, and phase state before allowing edits.
- Update skills, docs, doctor checks, installer cleanup, and CI behavior tests for the state-file contract.
