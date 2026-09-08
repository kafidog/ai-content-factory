#!/usr/bin/env bash
# subagent-audit.sh — audit a subagent's summary before the parent trusts it.
#
# A SubagentStop-event hook for Claude Code. When a subagent finishes, it runs
# `done-gate.sh audit` over the subagent's transcript and BLOCKS (exit 2) if the
# subagent's CLAIMS are not backed by the receipt ledger — an UNBACKED,
# MISREPORTED, or INTEGRITY_MISMATCH claim. In plain terms:
#
#   "Before the parent session trusts this subagent's 'I ran X and it passed,'
#    check that a matching receipt actually exists."
#
# This is the direct answer to parent-trusts-subagent blindness: ~20–30% of
# subagent reports have been found to contain claims that don't match tool output.
#
# Trust model — deliberately FAIL-OPEN (unlike stop-gate.sh, which fails closed):
#   * A subagent hook must never wedge a session on an ambiguous payload. If we
#     cannot read the payload / transcript, or there is no ledger to audit
#     against, we ALLOW (exit 0). We only BLOCK on a clean audit that returns a
#     real finding.
#   * Loop-guarded: stop_hook_active => exit 0 (we already spoke once).
#   * Heuristic (inferred) claims are best-effort; the audit never fails its exit
#     code on unparsed claims, only on unbacked/misreported/integrity-mismatch.
#
# Enable (Claude Code settings.json / plugin hooks.json):
#   "hooks": { "SubagentStop": [{ "hooks": [{ "type": "command",
#     "command": "bash \"$CLAUDE_PROJECT_DIR/subagent-audit.sh\"" }] }] }
#
# Bypass (escape hatch): export AGENT_DONE_OFF=1
#
# Exits:  0 = allow (disabled, ambiguous payload, no ledger, or all claims backed).
#         2 = block (a subagent claim is unbacked / misreported / integrity-mismatch).
set -uo pipefail

normalize_path() {
  case "$1" in
    [A-Za-z]:/*)
      if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- escape hatch -------------------------------------------------------------
[ "${AGENT_DONE_OFF:-0}" = "1" ] && exit 0

# --- read the hook payload (empty stdin => nothing to audit, allow) -----------
payload=""
if [ ! -t 0 ]; then payload="$(cat 2>/dev/null || true)"; fi
[ -z "$payload" ] && exit 0

extract_bool() {
  printf '%s' "$payload" | tr '\r\n' '  ' \
    | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*true" | head -n1 \
    | grep -c 'true' 2>/dev/null || true
}
extract_str() {
  printf '%s' "$payload" | tr '\r\n' '  ' \
    | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 \
    | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/" || true
}

# --- loop guard: never audit our own retry --------------------------------------
[ "$(extract_bool stop_hook_active)" = "1" ] && exit 0

# --- locate the transcript to audit (fail OPEN if absent) ---------------------
transcript="$(extract_str transcript_path)"
[ -n "$transcript" ] || exit 0
transcript="$(normalize_path "$transcript")"
[ -f "$transcript" ] || exit 0

# --- locate the gate + proof dir ----------------------------------------------
gate="$(cd "$(dirname "$0")" && pwd)/done-gate.sh"
[ -f "$gate" ] || exit 0   # can't audit without the engine — fail open

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  root="$(normalize_path "$CLAUDE_PROJECT_DIR")"
else
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] || root="$(cd "$(dirname "$0")" && pwd)"
  root="$(normalize_path "$root")"
fi
proof_dir="${AGENT_DONE_DIR:-$root/.agent-proof}"

# --- run the audit ------------------------------------------------------------
# audit exit codes: 0 = all claims backed; 1 = a real finding; 2 = usage/no-ledger
# (ambiguous). We block ONLY on 1, and fail OPEN on 0 and 2.
out="$(AGENT_DONE_DIR="$proof_dir" bash "$gate" audit --transcript "$transcript" 2>&1)"
rc=$?

if [ "$rc" = "1" ]; then
  {
    printf 'subagent-audit: BLOCKED — this subagent made claims not backed by the receipt ledger.\n'
    printf '%s\n' "$out" | grep -E 'UNBACKED|MISREPORTED|INTEGRITY_MISMATCH' | head -n 20
    printf 'subagent-audit: capture the checks (done-gate.sh capture --label ... -- <cmd>) or correct the summary.\n'
    printf 'subagent-audit: (escape hatch: export AGENT_DONE_OFF=1)\n'
  } 1>&2
  exit 2
fi

# rc 0 (all backed) or rc 2 (no ledger / usage — ambiguous) => allow.
exit 0
