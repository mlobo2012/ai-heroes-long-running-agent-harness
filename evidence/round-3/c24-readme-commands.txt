=== README slash-commands section ===
### Slash commands

When the plugin is loaded, six slash commands are available inside the Claude Code session:

| Command       | What it does |
|---------------|--------------|
| `/orient`     | Re-read BUILD_PLAN / PROGRESS / QA_REPORT / NEXT_FINDINGS / STEER / git log / smoke test. One-keystroke re-orientation. |
| `/blueprint`  | Invoke the planner subagent against an operator goal. |
| `/qa`         | Invoke the evaluator subagent against the current contract. |
| `/simplify`   | Wrapper for `scripts/re-simplify.sh` with every target's effect documented inline. |
| `/bench`      | Wrapper for `scripts/bench-harness.sh`. |
| `/round N`    | List artifacts under round-N directories and diff against round-(N-1). |

---

## Two ways to run the outer pulse

The watchdog must not depend on the process it watches. Claude Code is the worker. The outer pulse is the smoke alarm.

### Option A: standalone watchdog
