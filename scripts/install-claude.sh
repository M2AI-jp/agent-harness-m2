#!/usr/bin/env bash
set -eu

force=0
target=""
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    *) target="$arg" ;;
  esac
done
target="${target:-.}"
root="$(cd "$(dirname "$0")/.." && pwd)"
target_abs="$(cd "$target" && pwd)"

mkdir -p "$target_abs/.claude/skills" "$target_abs/.claude/hooks"

# Refuse to clobber an existing UNMANAGED file unless --force; with --force (or
# for an already-M2-managed file) back it up first. Default is fail-not-clobber,
# so installing M2 never silently overwrites another harness's hooks/settings/
# commit-msg. $2 overrides the "looks M2-managed" regex for non-hook files.
back_up_or_refuse() {
  local dest="$1" managed_re="${2:-Agent Harness M2|agent-harness}" rel="${1#$target_abs/}"
  [ -f "$dest" ] || return 0
  grep -Eq "$managed_re" "$dest" && return 0
  if [ "$force" != "1" ]; then
    echo "Error: existing unmanaged file: $rel" >&2
    echo "M2 will not overwrite it by default. Re-run with --force to back it up and replace, or merge it yourself." >&2
    exit 1
  fi
  cp "$dest" "$dest.bak"
  echo "Backed up existing $rel -> $rel.bak"
}

install_hook() {
  back_up_or_refuse "$2"
  cp "$1" "$2"
}

render_template() {
  local placeholder="$1"
  local value="$2"
  local src="$3"
  local dest="$4"
  local json_value
  local sed_value

  json_value="$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  sed_value="$(printf '%s' "$json_value" | sed 's/[&|]/\\&/g')"
  sed "s|$placeholder|$sed_value|g" "$src" > "$dest"
}

for skill in branch map translate; do
  rm -rf "$target_abs/.claude/skills/$skill"
  mkdir -p "$target_abs/.claude/skills/$skill"
  cp "$root/skills/$skill/SKILL.md" "$target_abs/.claude/skills/$skill/SKILL.md"
done

# Remove artifacts from older Agent Harness M2 installs.
rm -rf "$target_abs/.claude/skills/orient"
rm -rf "$target_abs/.claude/skills/verify-done"
rm -rf "$target_abs/.claude/skills/ship"
rm -rf "$target_abs/.agent-harness/verify"
rm -f "$target_abs/.agent-harness/map-done" "$target_abs/.agent-harness/translate-done"
rm -f "$target_abs/.claude/hooks/verify-done.sh" "$target_abs/.claude/hooks/strict-gate.sh"

install_hook "$root/hooks/entry-reminder.sh" "$target_abs/.claude/hooks/entry-reminder.sh"
install_hook "$root/hooks/branch-guard.sh" "$target_abs/.claude/hooks/branch-guard.sh"
install_hook "$root/hooks/map-guard.sh" "$target_abs/.claude/hooks/map-guard.sh"
install_hook "$root/hooks/translate-guard.sh" "$target_abs/.claude/hooks/translate-guard.sh"
install_hook "$root/hooks/scope-guard.sh" "$target_abs/.claude/hooks/scope-guard.sh"
install_hook "$root/hooks/skill-postrun.sh" "$target_abs/.claude/hooks/skill-postrun.sh"
install_hook "$root/hooks/bash-protect.sh" "$target_abs/.claude/hooks/bash-protect.sh"
chmod +x "$target_abs/.claude/hooks/"*.sh

claude_settings="$target_abs/.claude/settings.json"
back_up_or_refuse "$claude_settings" "agent-harness|\.claude/hooks/branch-guard\.sh"
render_template "__AGENT_HARNESS_CLAUDE_HOOK_ROOT__" "$target_abs/.claude/hooks" "$root/templates/claude/settings.json" "$claude_settings"

block_start="<!-- agent-harness-m2:start -->"
block_end="<!-- agent-harness-m2:end -->"
block_file="$(mktemp)"
{
  echo "$block_start"
  cat "$root/templates/claude/CLAUDE.md"
  echo "$block_end"
} > "$block_file"

claude="$target_abs/CLAUDE.md"
if [ -f "$claude" ] && grep -q "$block_start" "$claude"; then
  awk -v start="$block_start" -v end="$block_end" -v block="$block_file" '
    $0 == start { while ((getline line < block) > 0) print line; skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$claude" > "$claude.tmp"
  mv "$claude.tmp" "$claude"
elif [ -f "$claude" ]; then
  {
    cat "$claude"
    echo
    cat "$block_file"
  } > "$claude.tmp"
  mv "$claude.tmp" "$claude"
else
  cp "$block_file" "$claude"
fi

rm -f "$block_file"

# Install Git commit-msg hook (auto-appends user prompt to commit body)
git_hooks_dir="$target_abs/.git/hooks"
if [ -d "$git_hooks_dir" ]; then
  back_up_or_refuse "$git_hooks_dir/commit-msg"
  cp "$root/hooks/commit-msg.sh" "$git_hooks_dir/commit-msg"
  chmod +x "$git_hooks_dir/commit-msg"
fi

# Ensure .agent-harness/ is gitignored (prompt file must not be committed)
gitignore="$target_abs/.gitignore"
if [ -f "$gitignore" ]; then
  grep -q "^\.agent-harness/" "$gitignore" || echo ".agent-harness/" >> "$gitignore"
else
  echo ".agent-harness/" > "$gitignore"
fi

echo "Installed Agent Harness M2 for Claude Code in $target_abs"
echo "Start a new Claude Code session and inspect hooks if needed."
