#!/usr/bin/env bash
# stop-gate.sh — block "done" until it's proven.
#
# A Stop-event hook for Claude Code (and any harness with a stop/finish hook).
# It blocks the agent from ending its turn unless the MOST RECENT proof receipt
# (written by done-gate.sh) is a PASSING check that has not already been used to
# clear a previous stop. In plain terms:
#
#   "Your last recorded check must be a fresh, green one — or you can't say done."
#
# This is a FORCING FUNCTION, not a semantic oracle: it confirms a check ran and
# passed since your previous completion. It does not judge whether it was the
# RIGHT check — you choose that. (Semantic binding is on the v0.2 roadmap.)
#
# Trust model (hardened after independent review):
#   * FAIL CLOSED. Once a Stop payload is present, any missing / empty /
#     unparseable / stale proof state BLOCKS. Only an explicit disable, a
#     verified fresh passing receipt, or the anti-loop safety valve exits 0.
#   * No loop-guard bypass. We do NOT blanket-allow on stop_hook_active (that
#     would let the gate no-op after one block). Instead we bound consecutive
#     blocks per session with a counter; after AGENT_DONE_MAX_RETRIES we fail
#     OPEN with a loud warning purely to avoid an infinite stop loop.
#   * Freshness uses the epoch RECORDED IN the receipt, not the ledger's file
#     mtime (which `touch` could forge).
#   * Consume-on-allow persistence is MANDATORY: if we cannot record that a
#     receipt was used, we block rather than risk it being reused.
#
# Enable (Claude Code settings.json):
#   "hooks": { "Stop": [{ "hooks": [{ "type": "command",
#     "command": "bash \"$CLAUDE_PROJECT_DIR/stop-gate.sh\"" }] }] }
#
# Bypass (escape hatch): export AGENT_DONE_OFF=1
#
# Knobs: AGENT_DONE_TTL (default 3600s), AGENT_DONE_MAX_RETRIES (default 10),
#        AGENT_DONE_DIR (default <repo>/.agent-proof).
#
# Exits:  0 = allow (disabled, verified receipt, or anti-loop safety valve).
#         2 = block.
set -uo pipefail

normalize_path() {
  case "$1" in
    [A-Za-z]:/*)
      if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1"
      else
        printf '%s' "$1"
      fi
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- escape hatch -------------------------------------------------------------
[ "${AGENT_DONE_OFF:-0}" = "1" ] && exit 0

# --- read the hook payload (empty stdin => not gating anything, allow) --------
payload=""
if [ ! -t 0 ]; then
  payload="$(cat 2>/dev/null || true)"
fi
[ -z "$payload" ] && exit 0

# Extract a JSON boolean (true) for a key without jq.
extract_bool() {
  printf '%s' "$payload" | tr '\r\n' '  ' \
    | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*true" | head -n1 \
    | grep -c 'true' 2>/dev/null || true
}
# Extract a JSON string value for a key (best-effort, no jq).
extract_str() {
  printf '%s' "$payload" | tr '\r\n' '  ' \
    | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 \
    | sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/" || true
}

# --- locate the proof dir -----------------------------------------------------
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  root="$(normalize_path "$CLAUDE_PROJECT_DIR")"
else
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] || root="$(cd "$(dirname "$0")" && pwd)"
  root="$(normalize_path "$root")"
fi
proof_dir="${AGENT_DONE_DIR:-$root/.agent-proof}"
latest_ptr="$proof_dir/latest"
gate_dir="$proof_dir/.gate"

# Session id scopes the retry counter (sanitised to a safe filename).
session="$(extract_str session_id | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128)"
[ -n "$session" ] || session="_nosession"
retry_file="$gate_dir/retries.$session"

# deny(): the single blocking path. Bounds consecutive blocks per session so a
# genuinely un-satisfiable check cannot loop forever; only that safety valve
# (or the escape hatch) ever lets an unproven stop through.
deny() {
  local reason="$1" max n
  max="${AGENT_DONE_MAX_RETRIES:-10}"
  mkdir -p "$gate_dir" 2>/dev/null || true
  n=0
  [ -f "$retry_file" ] && n="$(tr -cd '0-9' < "$retry_file" 2>/dev/null || printf '0')"
  [ -n "$n" ] || n=0
  n=$((n + 1))
  printf '%s\n' "$n" > "$retry_file.$$.tmp" 2>/dev/null \
    && mv -f "$retry_file.$$.tmp" "$retry_file" 2>/dev/null || true

  if [ "$max" -gt 0 ] 2>/dev/null && [ "$n" -ge "$max" ] 2>/dev/null; then
    {
      printf 'stop-gate: WARNING — %d consecutive blocks; failing OPEN to avoid an\n' "$n"
      printf 'stop-gate: infinite stop loop. The agent is finishing WITHOUT proof.\n'
      printf 'stop-gate: reason was: %s\n' "$reason"
      printf 'stop-gate: fix your check, or set AGENT_DONE_OFF=1 to silence this gate.\n'
    } 1>&2
    exit 0
  fi

  {
    printf 'stop-gate: BLOCKED — %s\n' "$reason"
    printf 'stop-gate: prove your work first:\n'
    printf 'stop-gate:   bash done-gate.sh capture --label check -- <your test/build/run command>\n'
    printf 'stop-gate: then finish. (escape hatch: export AGENT_DONE_OFF=1)\n'
  } 1>&2
  exit 2
}

# allow(): reset the session retry counter and exit 0.
allow() {
  rm -f "$retry_file" 2>/dev/null || true
  printf 'stop-gate: OK — %s\n' "$1" >&2
  exit 0
}

# --- fail closed on any missing / malformed proof state -----------------------
[ -f "$latest_ptr" ] || deny "no proof receipt found for this project"
run="$(cat "$latest_ptr" 2>/dev/null | tr -d '[:space:]' || true)"
[ -n "$run" ] || deny "proof pointer is empty/unreadable"
case "$run" in *..*|*/*|*[!A-Za-z0-9._-]*) deny "proof pointer has an unsafe run id" ;; esac
ledger="$proof_dir/$run/ledger.jsonl"
[ -f "$ledger" ] || deny "proof pointer found (run=$run) but ledger is missing"

last_line="$(grep -E '.' "$ledger" 2>/dev/null | tail -n1 || true)"
[ -n "$last_line" ] || deny "proof ledger is empty — no checks were captured"

exit_code="$(printf '%s' "$last_line" | grep -oE '"exit_code":[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"
sha="$(printf '%s' "$last_line" | grep -oE '"sha256":"[0-9a-f]+"' | head -n1 | sed -E 's/.*"([0-9a-f]+)".*/\1/' || true)"
rec_epoch="$(printf '%s' "$last_line" | grep -oE '"epoch":[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"

# Unparseable receipt → fail closed (do NOT trust it).
[ -n "$exit_code" ] || deny "most recent receipt is unparseable (no exit_code)"
[ -n "$sha" ]       || deny "most recent receipt is unparseable (no sha256)"
[ -n "$rec_epoch" ] || deny "most recent receipt is unparseable (no epoch)"

# Only v2+ capture writes a `disposition`, always "reexecuted"; the CLAIM/VERDICT
# dispositions are "asserted"/"unparsed". A receipt is proof unless it carries a
# disposition that is not "reexecuted". Keyed on the disposition field itself (not
# a parsed schema_version integer, which an oversized value could overflow past).
# v0/v1 receipts (no disposition) are unaffected.
rec_disp="$(printf '%s' "$last_line" | grep -oE '"disposition":"[a-z]+"' | head -n1 | sed -E 's/.*"([a-z]+)".*/\1/' || true)"
if [ -n "$rec_disp" ] && [ "$rec_disp" != "reexecuted" ]; then
  deny "most recent receipt is a claim/verdict record (disposition=$rec_disp) — an asserted claim cannot satisfy the gate"
fi

# --- loop-guard awareness (informational, not a bypass) -----------------------
# stop_hook_active just tells us this is a retry; the retry COUNTER (in deny)
# does the loop protection. We never short-circuit to allow on this flag.
_=$(extract_bool stop_hook_active)

# --- most recent check must be PASSING ----------------------------------------
[ "$exit_code" = "0" ] || deny "your most recent check FAILED (exit=$exit_code) — fix it, don't ship it"

# --- freshness: use the epoch recorded in the receipt, not file mtime ---------
ttl="${AGENT_DONE_TTL:-3600}"
if [ "$ttl" -gt 0 ] 2>/dev/null; then
  now="$(date +%s 2>/dev/null || printf '0')"
  if [ "$now" -gt 0 ] 2>/dev/null && [ "$((now - rec_epoch))" -gt "$ttl" ] 2>/dev/null; then
    deny "latest proof is older than ${ttl}s (stale) — run your check again"
  fi
fi

# --- required-checks policy: the Stop gate must be as strict as `assert` -------
# If a policy file exists, a single fresh passing receipt of ANY label is NOT
# enough — EVERY required label must have a fresh passing receipt. Policy logic
# lives in done-gate.sh assert (single source of truth); we delegate to it and
# FAIL CLOSED if a policy is present but cannot be evaluated.
policy_file=""
if [ -n "${AGENT_DONE_POLICY:-}" ]; then
  policy_file="$AGENT_DONE_POLICY"
elif [ -f "$root/agent-done.json" ]; then
  policy_file="$root/agent-done.json"
fi
if [ -n "$policy_file" ] && [ -f "$policy_file" ]; then
  gate="$(cd "$(dirname "$0")" && pwd)/done-gate.sh"
  if [ ! -f "$gate" ]; then
    deny "policy $policy_file present but done-gate.sh is not next to stop-gate.sh — cannot verify required checks"
  fi
  if ! AGENT_DONE_DIR="$proof_dir" AGENT_DONE_TTL="$ttl" bash "$gate" assert --policy "$policy_file" >/dev/null 2>&1; then
    deny "required checks in $(basename "$policy_file") are not all fresh & passing — run every required check, then finish"
  fi
fi

# --- state binding: a passing receipt captured against different code is stale -
# Advisory by default; set AGENT_DONE_BIND_STATE=1 to make drift a hard block.
# Uses the receipt's RECORDED commit/dirty (not a fresh `git status`), so a proof
# legitimately captured against a dirty tree is not re-flagged — only a new commit
# or edits after a CLEAN capture count as drift. In hard mode a receipt with no
# commit binding is itself drift (it cannot be proven fresh against the source).
bind_state="${AGENT_DONE_BIND_STATE:-0}"
rec_commit="$(printf '%s' "$last_line" | grep -oE '"commit":"[0-9a-f]*"' | head -n1 | sed -E 's/.*"([0-9a-f]*)".*/\1/' || true)"
rec_dirty="$(printf '%s' "$last_line" | grep -oE '"dirty":(true|false)' | head -n1 | sed -E 's/.*:(true|false)/\1/' || true)"
head_commit="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
if [ -n "$head_commit" ]; then
  drift=""
  if [ -z "$rec_commit" ]; then
    [ "$bind_state" = "1" ] && drift="receipt has no commit binding (captured before state binding or outside git)"
  elif [ "$rec_commit" != "$head_commit" ]; then
    drift="proof captured at $(printf '%s' "$rec_commit" | cut -c1-7) but HEAD is now $(printf '%s' "$head_commit" | cut -c1-7)"
  elif [ "$rec_dirty" = "false" ] && [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
    drift="working tree changed since the (clean) proof was captured"
  fi
  if [ -n "$drift" ]; then
    if [ "$bind_state" = "1" ]; then
      deny "$drift (AGENT_DONE_BIND_STATE=1) — re-run your check against the current code"
    else
      printf 'stop-gate: WARNING — %s — proof may not reflect the current code\n' "$drift" >&2
    fi
  fi
fi

# --- consume-on-allow: require a NEW passing receipt since the last stop -------
# Identify "newness" by run id + receipt count, NOT by the output hash: two
# passing checks with identical output (e.g. a deterministic "5 passed") would
# otherwise collide and wrongly block a legitimate re-run.
count="$(grep -cE '.' "$ledger" 2>/dev/null || printf '0')"
token="$run:$count"
consumed_file="$gate_dir/consumed"
consumed=""
[ -f "$consumed_file" ] && consumed="$(cat "$consumed_file" 2>/dev/null | tr -d '[:space:]' || true)"
[ "$token" = "$consumed" ] && deny "no NEW passing check since your last completion — re-verify this change"

# Persist the consume token. This MUST succeed; if it cannot, block rather than
# risk the same receipt clearing a future stop.
tmp="$consumed_file.$$.tmp"
trap 'rm -f "$tmp" 2>/dev/null || true' EXIT
if ! mkdir -p "$gate_dir" 2>/dev/null \
   || ! printf '%s\n' "$token" > "$tmp" 2>/dev/null \
   || ! mv -f "$tmp" "$consumed_file" 2>/dev/null; then
  deny "could not record proof consumption (cannot write $gate_dir) — refusing to allow"
fi

allow "verified by a fresh passing receipt (sha256=$sha)"
