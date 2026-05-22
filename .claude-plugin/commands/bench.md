---
description: Run the bench rig against a pilot and write a score JSON. Use to measure whether a re-simplify override is safe to keep.
---

Invoke `scripts/bench-harness.sh` against a pilot in
`bench/pilots/`. The rig records wall-clock, rounds-to-pass,
false-pass status, and an I/O byte estimate to a score JSON.

Pair with `scripts/bench-score.py` to diff two runs:

```bash
scripts/bench-harness.sh --pilot express-server --workspace /tmp/bench-baseline
scripts/re-simplify.sh --target contract-reviewer --workspace /tmp/bench-w-override
scripts/bench-harness.sh --pilot express-server --workspace /tmp/bench-w-override
scripts/bench-score.py /tmp/bench-baseline/.claude/goal-state/bench-score.json \
                       /tmp/bench-w-override/.claude/goal-state/bench-score.json
```

Operator command: `scripts/bench-harness.sh $ARGUMENTS`
