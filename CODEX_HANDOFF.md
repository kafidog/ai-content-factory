# Current recovery checkpoint — 2026-09-09

- CURRENT_HEAD: resolve `git rev-parse HEAD` at startup; governance baseline `1e537505a50c471fc113159dc55009a666cf82b1`. Documentation commits after that baseline do not imply a new product validation.
- CURRENT_BRANCH: `main`; confirm it with Git, do not silently switch branches.
- LAST_VERIFIED_STATE: Public OSS v0.1.0 baseline; no new product Issue selected by this migration.
- COMPLETED / VERIFIED: CARRIED_FORWARD: existing v0.1.0 release boundary from README/CHANGELOG. VERIFIED_BY_CODE: offline fixture/default contract and documented commands; no runtime or external provider test rerun.
- ACTIVE_WORK: governance-only context adoption; no product execution authorized by this checkpoint.
- KNOWN_BLOCKERS: No blocker for governance. UNSUPPORTED: live provider quality, rights clearance or commercial acceptance not proven by fixtures.
- LOCKED_DECISIONS: Keep Python 3.11 standard-library offline default and explicit optional adapters; no hidden fallback; Apache-2.0 applies to project code only.
- EVENT_PENDING: EVENT_PENDING: separately authorized next product or release task; none selected.
- NEXT_EXECUTABLE_ISSUE: NONE_ASSIGNED. Read the next owner-selected Issue with Goal, Scope, Acceptance Criteria, Evidence Required and Dependencies before changing product behavior.

Evidence/source references: `README.md`, `ARCHITECTURE.md`, `CONTRIBUTING.md`, `PROVENANCE_LEDGER.md` (paths relative to repository root). Preserve accepted evidence unless new evidence or explicit requirements invalidate it; record OLD_BASELINE / NEW_EVIDENCE / SUPERSEDED_DECISION when reopening. A fresh agent must read current Git state and the selected Issue, not infer completion from this summary.
