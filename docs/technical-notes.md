# Technical Notes

Agent Harness M2 is a pre-work protocol for Claude Code / Codex. It is not a replacement for the official product behavior, and it is not a standalone agent runtime.

M2 remains a pre-work protocol.
Its core path is:

```text
/branch -> /map -> /translate -> scope-guard
```

Less approval, not more autonomy: M2 reduces human confirmation by constraining the agent's pre-edit loop, not by granting broader authority.

## Protocol, Not Built-In Product Behavior

M2 uses standard building blocks:

- `CLAUDE.md` / `AGENTS.md`
- project-local hook settings
- hooks
- skills
- Git `commit-msg`

The harness value is the way these pieces are composed into one entry protocol:

```text
/branch -> /map -> /translate -> scope-guard
```

This means M2 is not just a convenience skill bundle. It defines the path an agent should take before editing code.

## Why The 3 Layers Matter

One layer alone is weak.

Hook output can become background information to the agent. Instruction files can be interpreted too broadly. Skills can sit unused if nothing points to them.

M2 keeps the protocol visible through three layers:

- `UserPromptSubmit` reminds the agent of `/branch -> /map -> /translate -> scope-guard` every turn.
- `CLAUDE.md` / `AGENTS.md` state that the steps are required before file reads, writes, commands, and commits.
- `SKILL.md` files define the concrete procedure for each step.
- `PreToolUse` guard hooks block Edit / Write when the current task state does not match the required phase.

The physical blocking boundary is intentionally narrow. M2 blocks Edit / Write style operations through project-local hooks. It does not provide an OS-level sandbox, and it does not completely forbid Read, Bash, or external operations. Treat the official Claude Code / Codex documentation as the source of truth for hook, skill, memory, and trust behavior.

M2 still has a sentinel boundary, but it is state-aware rather than empty-file based. The task state files are:

- `.agent-harness/current-task.json` for hook checks
- `.agent-harness/current-task.md` for a short human/LLM summary

`current-task.json` stays deliberately small: schema, task id, branch, prompt hash, phase map, scope hash, and updated time.
`/branch` creates or refreshes the state for the current prompt. `/map` marks `phase.map = done`. `/translate` marks `phase.translate = done` and records the scope hash.
The old `.agent-harness/map-done` and `.agent-harness/translate-done` files are legacy artifacts and should not be used for authorization.

## The Four Gates And The Platform-Signed Sentinel

The visible flow is three skills, but enforcement is four gates: `branch`, `map`, `translate` (skills the agent runs) plus `scope-guard` (a hook — the 4th gate — that blocks Edit/Write to any file outside the `scope.files` recorded by `/translate`).

The `phase` fields in `current-task.json` are not trusted on their own, because the agent can write that file. The trusted record is a per-skill sentinel at `.agent-harness/.gates/<skill>.done`, written only by `skill-postrun.sh` on the real `PostToolUse(Skill)` event — which the agent cannot fire without actually invoking the skill. Before minting, `skill-postrun` verifies `sha256(user-prompt.txt) == current-task.json.prompt_hash`; every guard then re-checks that the sentinel's branch and prompt hash match the current task. Marking a phase done by editing the JSON does not pass: the matching sentinel is missing.

`bash-protect.sh` (PreToolUse Bash) guards the one directory this rests on, `.agent-harness/.gates/`. It deliberately does not guard `user-prompt.txt`: `/branch` must write that file each task, and its integrity is enforced where it is consumed — the `commit-msg` hook appends the prompt to the commit body only when the file still hashes to `current-task.json.prompt_hash`.

### State Drift Recovery

If current-task state appears stale or inconsistent, do not patch it by hand into a done state.
Re-run `/branch -> /map -> /translate` for the current prompt.
Do not proceed based only on `git diff` or `git status` when gate state and the sentinel chain disagree.

This is a protocol, not a sandbox. `bash-protect` blocks the scripted bypasses the regression suite encodes; it does not try to stop a determined interpreter (`python -c`, `sed -i`, a `cd` into the directory) from writing files. The guarantee is "make the gate flow the default and block casual forgery," consistent with M2 not being an OS-level sandbox.

### The agent can disable the harness (`disableAllHooks`)

Every gate above is a Claude Code hook, and hooks answer to one switch the model can reach: `disableAllHooks: true` in any `.claude/settings.json` or `.claude/settings.local.json`. M2 guards `Edit`/`Write` and the `.gates/` directory, but it does **not** guard the settings file against a `Bash` write, and Claude Code reloads settings live with no review prompt. An agent that can run arbitrary `Bash` can therefore turn the whole harness off in one step — and set the flag back afterward. This is the same boundary as the `python -c` / `sed -i` write path: a same-privilege, in-session hook cannot constrain an agent that holds an unguarded interpreter.

The only documented way to make the gate flow resistant to agent self-disable is to install M2's hooks as **managed-policy hooks** (enterprise managed settings): a user/project-level `disableAllHooks` cannot switch off managed hooks. Even then the `Bash` write path to source files remains, so the real boundary is the permission system (do not auto-approve `Bash`) or an OS-level sandbox — not the hooks. Treat M2 as "make the gate flow the default and leave a tamper-evident record," not as a containment boundary against an adversarial agent.

## Why M2 Does Not Include Eval

M2 is not an eval runner.

Eval / test / review rules depend on the project:

- Web UI
- API
- CLI
- LLM agent
- data processing
- internal tools
- libraries
- infrastructure settings

If M2 tried to own these checks, it would duplicate existing CI, conflict with project-specific rules, and become a heavy workflow tool instead of a small entry harness.

M2 stops at pre-work intervention. It does not judge whether the implementation is correct. Use the target project's tests, CI, review process, and human judgment for that.

## Work Unit Surfacing

`/map` may surface whether the current work looks like `continue`, `commit-candidate`, `push-candidate`, or `merge-candidate`.

These surfacings are *detection*, not execution. They are an early warning that work may be getting too large, mixing topics, or ready for a human-directed GitHub workflow.
`/map` does not itself commit, push, create a PR, merge, or sync local branches.

## GitHub Workflow Is Outside M2 Core

`/map` can surface `push-candidate` or `merge-candidate` states.
Those are detection/recommendation only.
M2 does not own commit, push, PR creation, CI review, merge, or local sync.

Operational GitHub workflows are outside the M2 core path. They are not installed as skills, are not hook-enforced, and remain a human-directed handoff boundary.

## Canonical Source And Installed Copies

In this distribution repository, the canonical source is:

- `skills/`
- `hooks/`
- `templates/`
- `scripts/`
- `docs/`
- `README.md`

The installers copy those files into a target repository as project-local install artifacts:

- `.claude/skills/`
- `.claude/hooks/`
- `.claude/settings.json`
- `.agents/skills/`
- `.codex/hooks/`
- `.codex/hooks.json`
- managed blocks in `CLAUDE.md` / `AGENTS.md`
- `.git/hooks/commit-msg`

Generated hook settings use absolute paths to the installed hook directory.
This keeps a top-level install such as `dev/` callable from child work directories when that top-level hook config is loaded, instead of re-resolving hooks through the child directory's `pwd` or Git root.

Those installed copies are intentionally not tracked in this distribution repository. Keeping them out of Git avoids drift between the canonical source and generated target-repo state.

Root `CLAUDE.md` / `AGENTS.md` in this repository are dogfooding instruction files. Their managed blocks should match `templates/claude/CLAUDE.md` and `templates/codex/AGENTS.md`; the templates remain canonical.

## Raw Prompt Persistence

`/branch` writes the user's raw prompt to `.agent-harness/user-prompt.txt` immediately after the work branch is settled.

That file is a temporary buffer for Git history persistence. It is ignored by Git, and it is not the permanent record. The permanent record is the commit body entry appended by the Git `commit-msg` hook under `User prompt:`.

The raw prompt commit-body flow is part of M2's design contract and should not be removed or made optional. The `commit-msg` hook must not delete the buffer during a failed commit path, because losing the prompt before a successful commit would break that contract.

In non-Git directories, `/branch` still creates local task state so map/translate guards can work, but there is no Git branch to create and no Git commit body where the raw prompt can be persisted.
If the directory later becomes Git-managed, rerun `/branch` for the active task.

### Previous Prompt Retrieval (Step 2.5)

When `/branch` detects an existing work branch, it reads the most recent `User prompt:` entry from Git history using `git log --first-parent --grep='User prompt:'`. The result is truncated to the first 200 characters and reported as a `Previous:` line.

`--first-parent` prevents leaking prompts from merged feature branches into the current branch's context. The retrieved prompt is advisory context for `/map` and `/translate`, not a binding instruction. If `/map` needs the full text, it reads git log on demand.

## Coexisting With Other Harnesses

M2 is project-local. It writes into the target project path supplied to the installer.

It does not write to `~/.claude`.

M2 does not automatically integrate with an existing hook graph. If another harness already manages `.claude/settings.json`, `.codex/hooks.json`, `.claude/hooks/`, `.codex/hooks/`, `.claude/skills/`, `.agents/skills/`, or `.git/hooks/commit-msg`, installing M2 on top is not recommended by default.

The installers back up unmanaged files before replacing them. That backup is for recovery; it is not evidence that merge succeeded.

Pay special attention to:

- multiple `PreToolUse` hooks
- hook execution order
- which hook blocks which operation
- skill names that overlap with other harnesses
- global memory or instruction sources that enter the model context outside M2

For repos that already have a harness, prefer porting the `/branch -> /map -> /translate -> scope-guard` idea into that harness instead of layering M2 on top. M2 is designed for repos that do not yet have a harness and need a small pre-work protocol.

`scripts/doctor.sh` checks only the M2 installation state. It is unrelated to Claude Code's built-in `/doctor`.

## Official Documentation Is The Source Of Truth

M2 is built on top of Claude Code / Codex behavior. If the official behavior of hooks, skills, memory, or instruction files changes, follow the official documentation first and update M2 accordingly.

- Claude Code: https://code.claude.com/docs
- Codex: https://developers.openai.com/codex
