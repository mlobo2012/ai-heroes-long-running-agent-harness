#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-eval-loop.sh [--dry-run] <sprint-slug> <brief-path|->

Spawns the Codex generator for a sprint and pins telemetry at:
  .claude/goal-state/codex-spawn-<sprint-slug>.log

After it returns, invoke a fresh-context evaluator with the acceptance
criteria and evidence paths. Only a PASS from that evaluator can justify
flipping test-results.json.
USAGE
}

dry_run=0
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --dry-run)
    dry_run=1
    shift
    ;;
esac

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 64
fi

sprint_slug="$1"
brief_path="$2"

case "$sprint_slug" in
  ""|*[!A-Za-z0-9._-]*)
    echo "build-eval-loop: sprint slug must contain only letters, numbers, dot, underscore, or dash" >&2
    exit 64
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
codex_spawn="$repo_root/bin/codex-spawn.sh"
log_dir="$repo_root/.claude/goal-state"
spawn_log="$log_dir/codex-spawn-${sprint_slug}.log"

if [ ! -x "$codex_spawn" ]; then
  echo "build-eval-loop: missing executable $codex_spawn" >&2
  exit 66
fi

if [ "$brief_path" = "-" ]; then
  brief="$(cat)"
else
  if [ ! -r "$brief_path" ]; then
    echo "build-eval-loop: brief is not readable: $brief_path" >&2
    exit 66
  fi
  brief="$(<"$brief_path")"
fi

if ! printf '%s' "$brief" | grep -q '[^[:space:]]'; then
  echo "build-eval-loop: empty sprint brief" >&2
  exit 65
fi

mkdir -p "$log_dir"

args=()
if [ "$dry_run" -eq 1 ]; then
  args+=(--dry-run)
fi

set +e
CODEX_SPAWN_WORKDIR="${CODEX_SPAWN_WORKDIR:-$repo_root}" \
  "$codex_spawn" "${args[@]}" - >"$spawn_log" 2>&1 <<<"$brief"
status=$?
set -e

if [ "$status" -ne 0 ]; then
  echo "build-eval-loop: codex spawn failed with exit $status; see $spawn_log" >&2
  exit "$status"
fi

if [ ! -s "$spawn_log" ]; then
  echo "build-eval-loop: expected spawn log was not written: $spawn_log" >&2
  exit 70
fi

cat <<EOF
Codex generator complete.
Spawn log: $spawn_log

Next steps for the orchestrator:
1. Open the sprint evidence files and the spawn log.
2. Invoke a fresh-context evaluator with the acceptance criteria and evidence paths.
3. Only after an evaluator PASS, flip the matching row(s) in test-results.json.
EOF
