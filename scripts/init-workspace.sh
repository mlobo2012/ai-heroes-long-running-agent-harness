#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Idempotently seed a workspace with the files expected by a long-running goal.
# If the target is a clean git worktree, commit only the files this script
# created. Existing files are never overwritten.

WORKSPACE="${1:-.}"
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"
WORKSPACE="$(pwd -P)"

created_files=""

mark_created() {
  created_files="${created_files}${created_files:+
}$1"
}

write_if_missing() {
  path="$1"
  shift
  if [ -e "$path" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  "$@" > "$path"
  mark_created "$path"
}

write_progress() {
  cat <<'EOF'
<!-- Seeded by scripts/init-workspace.sh. Edit freely. -->

# PROGRESS

## Done

_Nothing yet._

## In progress

_Nothing yet._

## Next

_Nothing yet._

## Notes

_Nothing yet._
EOF
}

write_results() {
  cat <<'EOF'
{
  "goal": "Replace this placeholder with the long-running goal.",
  "items": []
}
EOF
}

write_steer() {
  cat <<'EOF'
# Operator steering notes. Leave empty unless you need to redirect the agent.
EOF
}

write_block_count() {
  printf '0\n'
}

git_clean_before="false"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -z "$(git status --porcelain --untracked-files=all)" ]; then
    git_clean_before="true"
  fi
fi

mkdir -p ".claude/goal-state"
write_if_missing "PROGRESS.md" write_progress
write_if_missing "test-results.json" write_results
write_if_missing "STEER.md" write_steer
write_if_missing ".claude/goal-state/block-count" write_block_count

if [ "$git_clean_before" = "true" ] && [ -n "$created_files" ]; then
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    git add -- "$file"
  done <<EOF
$created_files
EOF
  if ! git diff --cached --quiet; then
    git commit -m "init: seed workspace for long-running goal"
  fi
fi
