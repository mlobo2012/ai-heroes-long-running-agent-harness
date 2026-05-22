S15_readme_honest_and_complete

Acceptance criterion verbatim:
- README.md has been audited. Every capability statement (e.g., the supervisor detects stalls within 20 minutes) either cites a test or verify-install check inline OR appears in a new Capabilities and where they're tested section.
- Honest about what is NOT enforced (e.g., the verify-gate Bash bypass is already disclosed — keep that).
- No missing-doc references — every doc link in README points at an existing file.

File-and-line citations:
- README.md:132-159 adds "Capabilities and where they are tested" and maps operational claims to tests, verify-install checks, or soft-boundary disclosures.
- README.md:71-79 keeps the Bash sed/jq bypass disclosure and hardening path.
- README.md:156-159 lists non-enforced/deferred areas and points to docs/parity-decisions.md.
- README.md:163-180 documents when to run scripts/sync-to-install.sh and the release diff command.
- README.md:214-220 qualifies plugin loading around --plugin-dir and says verify-install checks local CLI support.
- README.md:260-278 updates verify-install counts and final-gate checks.
- README.md:410-450 lists the new sync/audit scripts and parity-decisions doc in Components.
- README.md:492-501 documents rollback for workspace-to-install sync.
- scripts/audit-readme.sh:15-23 checks the capability map, sync instructions, and absence of unsourced platform-cap wording.
- scripts/audit-readme.sh:25-42 checks local README links point at existing files.

T1 spot-check:
Command: ./scripts/audit-readme.sh
Output: no output; exit 0.

T2 spot-check:
Command: bash -n scripts/audit-readme.sh
Output: no output; exit 0.

T3 spot-check:
Command: grep -q 'Capabilities' README.md && grep -q 'sync-to-install' README.md
Output: no output; exit 0.

T4 spot-check:
Command: scripts/verify-install.sh --scope all
Relevant output:
PASS - README capability map present
PASS - reversibility docs present
PASS - parity decisions rollup present

Self-grade:
PASS. README now has a capability-to-test map, keeps the important soft-boundary disclosures, documents sync, and the local-link audit passes.

