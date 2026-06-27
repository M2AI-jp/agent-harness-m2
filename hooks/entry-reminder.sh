#!/usr/bin/env bash
set -u

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ -n "$branch" ]; then
  echo "Agent Harness M2 required steps before editing: /branch -> /map -> /translate. scope-guard is enforced automatically. branch=${branch}"
else
  echo "Agent Harness M2 required steps before editing: /branch -> /map -> /translate. scope-guard is enforced automatically. non-git directory"
fi
echo "/branch must preserve the user's original prompt in the eventual Git commit body."
echo "/map must build a map (structure, entry points, dependencies, patterns, scope, stale context) before /translate and implementation."

exit 0
