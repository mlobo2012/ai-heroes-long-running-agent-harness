#!/usr/bin/env bash
# AI Heroes / Marco - discord-long-running-harness
#
# Closes the Bash-bypass gap in verify-gate.sh. The upstream verify-gate only
# fires on Write/Edit, so an agent could `sed`/`jq`/`python` rewrite of
# test-results.json would slip past it. This hook inspects PreToolUse Bash
# commands and blocks any command that writes to the results file unless the
# session has accumulated evidence.
#
# This is heuristic — a determined agent can obfuscate. Combined with the
# Read+Write gate it raises the floor without claiming to be a security
# boundary. The teaching-example caveat from upstream still applies.

set -u
log="${VERIFY_READ_LOG:-./.claude/.evidence-reads}"
results="${RESULTS_FILE:-test-results.json}"

input=$(cat)
cmd=$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# Bail unless the command mentions the results file by name.
case "$cmd" in
  *"$results"*) ;;
  *) exit 0 ;;
esac

# Read-only inspection commands are fine.
mentions_write=0
for needle in '>' '>>' 'tee' 'sed -i' 'sed --in-place' 'jq ' 'python ' 'python3 ' 'node ' 'mv ' 'cp ' 'cat <<' 'printf ' 'echo '; do
  case "$cmd" in
    *"$needle"*) mentions_write=1; break ;;
  esac
done
# Special-case: jq is read-only without redirect; only flag if combined with > or sponge.
case "$cmd" in
  *'jq '*'>'*"$results"*|*'jq '*"$results"*' >'*|*'jq '*"$results"*' | sponge '*|*'jq '*"$results"*' | tee '*) mentions_write=1 ;;
esac

# Pure cat/grep/head/tail/wc on the results file is read-only.
if [ "$mentions_write" = "0" ]; then
  exit 0
fi

if [ -s "$log" ]; then
  # Session-level: consume one evidence read.
  : > "$log"
  exit 0
fi

cat <<'JSON'
{"decision":"block","reason":"Cannot write to the results file via Bash without first opening evidence with the Read tool. The verify-gate-bash hook caught a write attempt (sed/jq/python/redirect) targeting test-results.json. Read the relevant evidence file first, then retry."}
JSON
exit 0
