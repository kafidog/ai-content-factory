# Persistent project context

## Project identity

AI Content Factory public OSS v0.1.0: Python 3.11 offline, standard-library default, fixture-first provider/publisher contracts.

## Sources of truth and startup

Read global/repo AGENTS → existing delivery contract → `CODEX_HANDOFF.md` → selected GitHub Issue / explicit user task → `git branch --show-current`, `git rev-parse HEAD`, `git status --short`, `git diff` (and staged diff). This repository has no standalone PROJECT_DELIVERY_RULES.md; retain the specific rules below and in the current handoff instead of inventing a duplicate.

Only `CODEX_HANDOFF.md` is current; older milestone handoffs are historical, not competing current entries. Supporting sources: `README.md`, `ARCHITECTURE.md`, `CONTRIBUTING.md`, `PROVENANCE_LEDGER.md`.

## Accepted baseline and work contract

- Carry forward VERIFIED/ACCEPTED/COMPLETE/LOCKED_DECISION/CARRIED_FORWARD without reimplementation or repeat research absent counterevidence. Reopen only new evidence, invalidating HEAD, explicit changed requirement or refactor Issue; record OLD_BASELINE, NEW_EVIDENCE, SUPERSEDED_DECISION.
- One Issue is one bounded user flow with Goal, Scope, Acceptance Criteria, Evidence Required and Dependencies / Blockers. Do not reopen completed Issues or manufacture new work while blocked.
- Main agent executes by default; no automatic agents/model switching or fictitious reviewer identity. Two no-progress attempts for one hypothesis maximum, then reassess evidence/tool/environment.
- Claims: VERIFIED_BY_CODE, VERIFIED_BY_TEST, VERIFIED_BY_RUNTIME_OR_PRODUCTION, CARRIED_FORWARD, EVENT_PENDING, UNSUPPORTED. Historical evidence is not a fresh run.
- Blockers: CODE_DEFECT, VALIDATION_TOOL_DEFECT, ENVIRONMENT_DEFECT, EXTERNAL_WAIT, HUMAN_AUTHORIZATION, EVIDENCE_INSUFFICIENT. Complete only when the original acceptance criteria are evidenced; otherwise PARTIAL/BLOCKED with one resumption condition, no unsolicited polling.

## Commands and limitations

Setup: python -m venv .venv, then .venv/Scripts/python -B scripts/bootstrap_offline.py. Verification commands below remain authoritative; there is no mandatory full product run for governance-only changes.

Fixture output is not live provider quality or remote publishing. Private brand/config/media remain external; public code license does not relicense adapters/assets.

## Delivery

Update the single current handoff with CURRENT_HEAD/BRANCH, LAST_VERIFIED_STATE, COMPLETED / VERIFIED, ACTIVE_WORK, KNOWN_BLOCKERS, LOCKED_DECISIONS, EVENT_PENDING and NEXT_EXECUTABLE_ISSUE. Resolve actual HEAD using Git; recorded hashes identify evidence baselines, not a self-referential final documentation commit.

Preserve unrelated dirty work. Stage only reviewed task files; no reset/clean/force push/history rewrite. Separate source sync from release/deploy/account authorization. Commit and push the safe current branch; verify local and remote HEAD equality before claiming GITHUB_SYNC=PUSHED. If unavailable, retain the commit and report exact blocker. Documentation-only validation checks references, Markdown and diff, never reruns the product suite for ceremony.

# Repository agent instructions

## Product boundary

- Current status: public OSS release v0.1.0 on GitHub.
- Keep the default Python 3.11 runtime standard-library-only and offline.
- Preserve unrelated worktree changes. Never reset, clean, stash, or overwrite
  another contributor's work.
- Do not perform live API calls, remote publishing, browser automation,
  credential setup, payment, deployment, or release publication without a
  separate explicit authorization.
- The v0.1.0 release is already public; future releases and public publication
  actions still require separate explicit authorization.
- Never add real secrets, private paths, private assets, personal data, account
  identifiers, or private brand names to tracked files.

## Architecture

- Core code owns generic contracts, orchestration, integrity, QA, and local
  packages. Vendor behavior belongs behind provider/publisher interfaces.
- The fixture registry is the default. Optional adapters must be explicitly
  selected and may not become hidden fallbacks.
- Product-native tools, model runtimes, and local media tools are optional
  adapters. The base demo cannot depend on them.
- Brand assets and production configuration belong in an external private
  layer and must not be copied into this repository.

## Media boundary

- Call still-image transforms `MOTION_RENDER`; do not claim synthesized subject
  motion.
- Imported media requires explicit provenance and rights status. Unknown rights
  block materialization into a review package.
- Model weights, caches, browser state, and private media never belong in the
  source release candidate.

## Security and provenance

- Keep scanner output redacted. Store private brand denylist entries only as
  SHA-256 fingerprints.
- Record non-trivial source, dependency, and design decisions in
  `PROVENANCE_LEDGER.md`.
- A local scan or fixture test is evidence for that boundary only, not proof of
  live provider, rights, quality, or public-release approval.
- Build public candidates only with `public_release_manifest.json` and
  `scripts/build_release_candidate.py`; never copy the whole worktree.

## Verification

```text
python -B -m unittest discover -s tests -p "test_*.py"
python -B scripts/public_ci.py
python -B scripts/security_scan.py --root . --brand-hash-file scripts/public_brand_hashes.sha256
python -B -m ai_content_factory demo --output output
python -B -m ai_content_factory inspect --output output
python -B -m ai_content_factory validate --output output
```

Apache-2.0 covers project code only. External adapters, tools, models, fonts,
and user assets retain their own terms and must be documented separately.

<!-- doneaudit:start -->
## DoneAudit completion rule
Before claiming completion, write doneaudit.claim.json with {"completed":true,"summary":"what you changed"} and the exact config scope when governance-only.
Then run `node .doneaudit/tool/bin/doneaudit.js run`. This executes configured checks and produces evidence automatically.
Only describe the configured scope as verified when it exits 0 and reports VERIFIED. Governance-only evidence is NEVER product acceptance. If it fails, report FAILED or INSUFFICIENT EVIDENCE honestly.
The final reviewer still checks Issue acceptance, scope, runtime requirements and current handoff; DoneAudit is not that review.
Do not weaken tests, edit DoneAudit tooling/configuration, or manufacture receipts to obtain a passing score.
<!-- doneaudit:end -->
