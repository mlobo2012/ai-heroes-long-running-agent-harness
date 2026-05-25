#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
DEST_DIR="${HARNESS_INSTALL_DIR:-$HOME/.claude/plugins/discord-long-running-harness}"

if ! command -v rsync >/dev/null 2>&1; then
  echo "sync-to-install: rsync is required" >&2
  exit 2
fi

mkdir -p "$DEST_DIR"

sync_dir() {
  local rel="$1"
  mkdir -p "$DEST_DIR/$rel"
  rsync -a --delete "$SRC_DIR/$rel/" "$DEST_DIR/$rel/"
}

sync_file() {
  local rel="$1"
  if [ -f "$SRC_DIR/$rel" ]; then
    mkdir -p "$DEST_DIR/$(dirname "$rel")"
    rsync -a "$SRC_DIR/$rel" "$DEST_DIR/$rel"
  fi
}

scaffold_dir_tree() {
  local rel="$1"
  [ -d "$SRC_DIR/$rel" ] || return 0
  while IFS= read -r dir; do
    mkdir -p "$DEST_DIR/${dir#"$SRC_DIR/"}"
  done < <(find "$SRC_DIR/$rel" -type d -print)
}

scaffold_git_root() {
  if [ -f "$SRC_DIR/.git" ]; then
    rm -rf "$DEST_DIR/.git"
    sync_file .git
    return 0
  fi
  [ -d "$SRC_DIR/.git" ] || return 0
  rm -rf "$DEST_DIR/.git"
  mkdir -p "$DEST_DIR/.git"
  while IFS= read -r path; do
    rel="${path#"$SRC_DIR/"}"
    if [ -d "$path" ]; then
      mkdir -p "$DEST_DIR/$rel"
    elif [ -f "$path" ] && [ "$(dirname "$rel")" = ".git" ]; then
      : > "$DEST_DIR/$rel"
    fi
  done < <(find "$SRC_DIR/.git" -maxdepth 1 -print)
}

for rel in hooks scripts agents bin docs; do
  sync_dir "$rel"
done

for rel in \
  .claude-plugin/plugin.json \
  README.md \
  CHANGELOG.md \
  CLAUDE.md \
  LICENSE \
  SYNC.md \
  .gitignore
do
  sync_file "$rel"
done

# Prune retired top-level package files from the install while leaving live
# workspace state, tests, and git metadata alone. Those paths are intentionally
# excluded from the final diff check in the release gate.
for path in "$DEST_DIR"/* "$DEST_DIR"/.[!.]* "$DEST_DIR"/..?*; do
  [ -e "$path" ] || continue
  base="$(basename "$path")"
  case "$base" in
    hooks|scripts|agents|bin|docs|.claude-plugin|README.md|CHANGELOG.md|CLAUDE.md|LICENSE|SYNC.md|.gitignore)
      ;;
    .git|tests|evidence|test-results.json|PROGRESS.md|STEER.md|node_modules|.claude)
      ;;
    *)
      rm -rf "$path"
      ;;
  esac
done

# `diff -rq` reports a top-level "Only in ...: evidence" line before grep can
# filter nested workspace-only paths. Create empty comparison scaffolding so the
# release-gate filter sees nested paths such as `evidence/sprint-1/...` and
# `tests/cap/...` without copying artifact contents into the installed plugin.
scaffold_dir_tree evidence
scaffold_dir_tree tests
scaffold_dir_tree .claude/goal-state
scaffold_git_root
sync_file .claude/.evidence-reads

echo "synced $SRC_DIR -> $DEST_DIR"
