# Current DoneAudit integration checkpoint

- CURRENT_GOAL: resume existing persistent context and integrate the single DoneAudit engine; governance-only.
- CURRENT_BRANCH: resolve `git branch --show-current`; CURRENT_HEAD: resolve `git rev-parse HEAD`. Integration input: `9f1bf8a1ca0d51ff45d0db88446630223888e04d`.
- LAST_VERIFIED_STATE: accepted product evidence below is CARRIED_FORWARD, not rerun. Scope/source-bound current proof is `.doneaudit/evidence/result.json`; absent or stale receipts are INSUFFICIENT EVIDENCE.
- COMPLETED: previous governance commit retained; installer/configuration wired to source pin `2900f2dec4c8f6905412e23e8947b45eb1071bd2` (unreleased source, not npm 0.1.0).
- ACTIVE_WORK: governance integration only; no product flow is being executed.
- LOCKED_DECISIONS: Keep Python 3.11 standard-library offline default and explicit optional adapters; no hidden fallback; Apache-2.0 applies to project code only. DoneAudit governance scope never replaces product acceptance or the final reviewer.
- KNOWN_BLOCKERS: DONEAUDIT_BLOCKED / VALIDATION_TOOL_DEFECT: integration commit d419db37281c7d85f7cdbdedf0fa701ab2449313 triggers 11 findings in the existing public security scanner. Public CI run 34254667212 reports 128 unit tests and fixture demo/validation passing, but security scan fails on pinned vendor metadata/code and doneaudit.config.json. No scanner exclusions, vendor edits or product-code repairs are authorized by this checkpoint. Live provider quality, rights clearance and commercial acceptance remain unsupported.
- EVENT_PENDING: EVENT_PENDING: separately authorized next product or release task; none selected. Central portable source is not a published npm/Marketplace release.
- UNVERIFIED: all product behavior not covered by the carried-forward evidence; this task performs no new runtime/Production acceptance.
- NEXT_SINGLE_ACTION: Owner must authorize a bounded compatibility decision for the existing public scanner and canonical DoneAudit distribution; preserve both checks and pinned vendor bytes until then. Re-run `node .doneaudit/tool/bin/doneaudit.js run` after an approved fix; required public-security evidence must pass without blanket exclusions. Product resumption remains NONE_ASSIGNED.

OLD_BASELINE: previous governance-only proof at d419db3 was valid only for references, source pin and diff scope. NEW_EVIDENCE: https://github.com/kafidog/ai-content-factory/actions/runs/34254667212 proves the integration violates the existing scanner gate. SUPERSEDED_DECISION: safe integration is BLOCKED, not VERIFIED. The existing security command is now required in DoneAudit, so earlier narrow green receipts cannot override this regression. Local ignored proof receipts produce additional scanner findings; they are not tracked or published. Findings are redacted; do not copy matched tokens into reports.

`doneaudit.config.json` lists actual reference, pinned-byte and exact-diff allowlist checks, not product test/build substitutes. One installer-owned completion block is in AGENTS.md. CI re-executes the same governance commands with a proof-only Node bootstrap. A later product Issue must select its real product checks and acceptance scope; never reuse this governance-only result as product completion.

## Carried-forward project truth


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
