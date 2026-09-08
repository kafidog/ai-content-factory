#!/usr/bin/env bash
# done-gate.sh — proof receipts for AI coding agents.
#
# Your agent says "done." This makes it prove it. `capture` runs your real
# check, hashes the output, and records the command + exit code + SHA-256 in a
# tamper-evident ledger. Because capture EXITS WITH THE COMMAND'S OWN CODE, a
# failing check fails the receipt — green cannot be faked.
#
# Pairs with stop-gate.sh (the Stop hook). `assert` is the same idea for CI,
# pre-commit, and release scripts. Works with Claude Code, Cursor, and Codex.
#
# Subcommands:
#   capture --label L [--run R] [--json] -- CMD [ARGS...]
#       Run CMD, stream its output to the console AND a log file, then append a
#       JSONL receipt (label, command, exit_code, sha256, log, at, epoch,
#       session). Updates the latest-run pointer. Exits with CMD's own code.
#
#   assert [--label L ...] [--run R] [--ttl S] [--allow-command-regex RE]
#          [--policy FILE] [--no-policy] [--json]
#       Exit 0 iff every required label has a PASSING, FRESH receipt (and, if a
#       regex is given, the recorded command matches it). Resolution order:
#       explicit --label (legacy) > an agent-done.json policy (required labels +
#       per-label command_regex + ttl) > the most recent receipt. --no-policy
#       forces the legacy path. For CI / pre-commit gating.
#
#   verify --label L [--run R] [--json] --sha HEX
#       Exit 0 iff the ledger's recorded sha256 for L equals HEX.
#
#   show [--run R] [--json]
#       Print the ledger for the run (newest run if --run is omitted).
#
#   audit --transcript FILE|- [--run R] [--json]
#       Diff an agent's CLAIMS (structured <agent-done:claim> markers, with a
#       transcript-heuristic fallback) against the receipt ledger. Verdict per
#       claim: BACKED / UNBACKED / MISREPORTED / INTEGRITY_MISMATCH / UNPARSED.
#       Exits non-zero on any unbacked, misreported, or integrity-mismatch claim.
#
#   review-pr --body FILE|- [--commits [--base REF]] [--json]   ("PR Receipts")
#       Parse a PR description's testable claims ("tests pass", "lint clean",
#       "build succeeds"), auto-resolve the project's REAL commands from its
#       manifests, re-execute them, and print a receipt: RE-EXECUTED / ASSERTED /
#       UNPARSED. Never "VERIFIED". Exits non-zero if a re-executed claim fails.
#
# Receipts live under .agent-proof/<run>/ (add .agent-proof/ to .gitignore).
# The run id defaults to $AGENT_DONE_SESSION, else a UTC timestamp.
#
# Dependency-free: SHA via sha256sum | shasum -a 256 | python hashlib; the
# ledger is hand-written JSONL. No network, no LLM, no extra tooling.
set -euo pipefail

GATE_VERSION="0.13.1"

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

ROOT="$(normalize_path "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
PROOF_DIR="${AGENT_DONE_DIR:-$ROOT/.agent-proof}"

die() { printf 'done-gate: %s\n' "$1" >&2; exit 2; }

# Reject path-unsafe run ids / labels: they become directory and file names.
valid_name() {
  case "$1" in
    ''|*..*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

timestamp() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'; }
epoch()     { date +%s 2>/dev/null || printf '0'; }
run_stamp() { date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf 'run'; }

# Git state at capture time, so a receipt is bound to the source it verified.
# Emits three TAB-separated fields: <commit>\t<tree>\t<dirty>. commit/tree are
# empty outside a git repo; dirty is the JSON literal true/false. This is what
# lets the gate later say "this proof was captured against different code."
git_commit() { git rev-parse HEAD 2>/dev/null || printf ''; }
git_tree()   { git rev-parse 'HEAD^{tree}' 2>/dev/null || printf ''; }
git_dirty()  { [ -n "$(git status --porcelain 2>/dev/null)" ] && printf 'true' || printf 'false'; }
git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf ''; return; }
  git config --get remote.origin.url 2>/dev/null || printf ''
}
git_subject() { git log -1 --format=%s 2>/dev/null || printf ''; }
# Canonical host OS identity, so bash and the PowerShell port agree on the SAME
# vocabulary for the same machine. uname reports Git Bash as MINGW*/MSYS*, which
# is a Windows host — collapse those (and any *NT*) to 'windows'.
host_os() {
  local os
  os="$(uname -s 2>/dev/null || true)"
  case "$os" in
    Linux*)                             printf 'linux' ;;
    Darwin*)                            printf 'darwin' ;;
    MINGW*|MSYS*|CYGWIN*|Windows*|*NT*) printf 'windows' ;;
    *)                                  printf 'unknown' ;;
  esac
}

sha256_of_file() {
  local f="$1" c py=""
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    for c in python3 python py; do
      command -v "$c" >/dev/null 2>&1 && { py="$c"; break; }
    done
    [ -n "$py" ] || die "no sha256 tool found (need sha256sum, shasum, or python)"
    "$py" - "$f" <<'PY'
import hashlib, sys
with open(sys.argv[1], "rb") as fh:
    print(hashlib.sha256(fh.read()).hexdigest())
PY
  fi
}

# Minimal JSON string escaper for label/command/path fields. Escapes backslash
# and double-quote, then flattens EVERY C0 control character (U+0000–U+001F,
# which includes newline, CR, tab, form-feed, vertical-tab, backspace, …) to a
# space — raw control bytes are forbidden inside a JSON string, so this keeps the
# hand-built JSONL line parseable no matter what a commit subject or URL contains.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | LC_ALL=C tr '\000-\037' ' '
}

resolve_run_for_read() {
  local r="${1:-}"
  if [ -z "$r" ]; then
    [ -f "$PROOF_DIR/latest" ] && r="$(cat "$PROOF_DIR/latest")"
  fi
  printf '%s' "$r"
}

# --- ledger field extractors (operate on a single JSONL receipt line) ---------
rec_exit()    { printf '%s' "$1" | grep -oE '"exit_code":[0-9]+' | head -n1 | grep -oE '[0-9]+'; }
rec_epoch()   { printf '%s' "$1" | grep -oE '"epoch":[0-9]+' | head -n1 | grep -oE '[0-9]+'; }
rec_sha()     { printf '%s' "$1" | grep -oE '"sha256":"[0-9a-f]+"' | head -n1 | sed -E 's/.*"([0-9a-f]+)".*/\1/'; }
rec_command() { printf '%s' "$1" | sed -E 's/.*"command":"(.*)","exit_code":.*/\1/'; }
rec_commit()  { printf '%s' "$1" | grep -oE '"commit":"[0-9a-f]*"' | head -n1 | sed -E 's/.*"([0-9a-f]*)".*/\1/'; }
rec_dirty()   { printf '%s' "$1" | grep -oE '"dirty":(true|false)' | head -n1 | sed -E 's/.*:(true|false)/\1/'; }
rec_disp()    { printf '%s' "$1" | grep -oE '"disposition":"[a-z]+"' | head -n1 | sed -E 's/.*"([a-z]+)".*/\1/'; }

# An EXECUTION receipt is the only thing that can satisfy a gate. Only v2+ capture
# writes a `disposition`, and it is always "reexecuted"; the CLAIM/VERDICT
# dispositions are "asserted"/"unparsed". So the rule is keyed on the disposition
# field itself, NOT on schema_version: a line is proof unless it carries a
# disposition that is not "reexecuted". v0/v1 receipts (no disposition) are
# accepted as before. This deliberately avoids parsing schema_version as an
# integer, so an oversized/garbage schema_version can't overflow past the check.
# Returns 0 (proof) / 1 (claim/verdict — not proof). Fails CLOSED.
is_execution_receipt() {
  local disp; disp="$(rec_disp "$1")"
  [ -z "$disp" ] || [ "$disp" = "reexecuted" ]
}

# Compare a receipt's RECORDED git state to the working tree NOW. Echoes a short
# human reason if the proof no longer matches the code, else nothing. It uses the
# receipt's own recorded commit/dirty (not a fresh `git status`) so a proof that
# was legitimately captured against a dirty tree is NOT re-flagged as drift — only
# a real change is: a new commit, or edits after a CLEAN capture. Outside a git
# repo it is silent. $2 = bind flag: in hard mode a receipt with no commit
# binding is itself drift (it can't be proven fresh); in advisory mode it's silent
# so pre-binding receipts don't nag.
state_drift_reason() {
  local line="$1" bind="${2:-0}" rcommit rdirty head
  rcommit="$(rec_commit "$line" || true)"
  rdirty="$(rec_dirty "$line" || true)"
  head="$(git_commit)"
  [ -n "$head" ] || return 0
  if [ -z "$rcommit" ]; then
    [ "$bind" = "1" ] && printf 'receipt has no commit binding (captured before state binding or outside git)'
    return 0
  fi
  if [ "$rcommit" != "$head" ]; then
    printf 'proof captured at %s but HEAD is now %s' "$(printf '%s' "$rcommit" | cut -c1-7)" "$(printf '%s' "$head" | cut -c1-7)"
    return 0
  fi
  if [ "$rdirty" = "false" ] && [ "$(git_dirty)" = "true" ]; then
    printf 'working tree changed since the (clean) proof was captured'
  fi
  return 0
}

# Latest receipt line for a label (fixed-string match), or empty.
latest_for_label() {
  local ledger="$1" label="$2"
  grep -F "\"label\":\"$(json_escape "$label")\"" "$ledger" 2>/dev/null | tail -n1
}

# --- policy file (agent-done.json) --------------------------------------------
# Maintainer-authored config that says what "done" requires. Trusted at the same
# level as any workspace file. Parsed dependency-free (no jq): each entry in the
# "required" array is a FLAT object, so a brace-pair match isolates them safely.
resolve_policy_path() {
  local explicit="$1"
  if [ -n "$explicit" ]; then printf '%s' "$explicit"; return 0; fi
  if [ -n "${AGENT_DONE_POLICY:-}" ]; then printf '%s' "$AGENT_DONE_POLICY"; return 0; fi
  [ -f "$ROOT/agent-done.json" ] && printf '%s' "$ROOT/agent-done.json"
  return 0
}

# Emit one "label<TAB>command_regex" line per required entry (regex may be empty).
policy_entries() {
  local file="$1" obj label regex
  [ -f "$file" ] || return 0
  tr '\n\r' '  ' < "$file" 2>/dev/null | grep -oE '\{[^{}]*\}' | while IFS= read -r obj; do
    label="$(printf '%s' "$obj" | grep -oE '"label"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*"label"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
    [ -n "$label" ] || continue
    regex="$(printf '%s' "$obj" | grep -oE '"command_regex"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -E 's/.*"command_regex"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
    printf '%s\t%s\n' "$label" "$regex"
  done
  return 0
}

# Top-level "ttl" integer, or empty.
policy_ttl() {
  local file="$1"
  [ -f "$file" ] || return 0
  tr '\n\r' '  ' < "$file" 2>/dev/null | grep -oE '"ttl"[[:space:]]*:[[:space:]]*[0-9]+' | head -n1 | grep -oE '[0-9]+' || true
}

# Label strength taxonomy for the advisory wrong-check warning. WEAK labels are
# necessary but not sufficient on their own; unknown labels are treated STRONG so
# custom verifying commands are never nagged.
label_is_weak() {
  case "$1" in
    lint|format|fmt|style|manual|docs) return 0 ;;
    *) return 1 ;;
  esac
}

# Most recent receipt for a label across ALL runs (highest recorded epoch), or
# empty. Policy mode uses this so receipts captured in separate run dirs (the
# default when no AGENT_DONE_SESSION is set) still satisfy required labels.
latest_for_label_global() {
  local label="$1" pat f line ep best="" best_ep=-1
  pat="\"label\":\"$(json_escape "$label")\""
  for f in "$PROOF_DIR"/*/ledger.jsonl; do
    [ -f "$f" ] || continue
    line="$(grep -F "$pat" "$f" 2>/dev/null | tail -n1 || true)"
    [ -n "$line" ] || continue
    ep="$(printf '%s' "$line" | grep -oE '"epoch":[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"
    [ -n "$ep" ] || ep=0
    if [ "$ep" -gt "$best_ep" ] 2>/dev/null; then best_ep="$ep"; best="$line"; fi
  done
  printf '%s' "$best"
}

cmd_capture() {
  local label="" run="" json=0 ; local -a CMD=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) [ "$#" -ge 2 ] || die "capture: --label requires a value"; label="$2"; shift 2 ;;
      --run)   [ "$#" -ge 2 ] || die "capture: --run requires a value";   run="$2";   shift 2 ;;
      --json)  json=1; shift ;;
      --)      shift; CMD=("$@"); break ;;
      *)       die "capture: unexpected arg '$1' (did you forget '--' before the command?)" ;;
    esac
  done
  [ -n "$label" ] || die "capture: --label is required"
  [ "${#CMD[@]}" -ge 1 ] || die "capture: a command after '--' is required"
  valid_name "$label" || die "capture: --label must match [A-Za-z0-9._-] and contain no '..'"

  run="${run:-${AGENT_DONE_SESSION:-$(run_stamp)}}"
  valid_name "$run" || die "capture: run id must match [A-Za-z0-9._-] and contain no '..'"
  local dir="$PROOF_DIR/$run"
  mkdir -p "$dir"
  local log="$dir/$label.log"

  local rc
  set +e
  ( "${CMD[@]}" ) 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e

  local sha; sha="$(sha256_of_file "$log")"
  local commit tree dirty repo subject producer verifier os disposition
  commit="$(git_commit)"; tree="$(git_tree)"; dirty="$(git_dirty)"
  repo="$(git_repo)"; subject="$(git_subject)"
  producer="done-gate.sh@$GATE_VERSION"
  verifier="${AGENT_DONE_VERIFIER:-}"
  os="$(host_os)"
  disposition="reexecuted"
  # Provenance: was this captured by a CI runner, and against which ref? A verify
  # job re-captures fresh from pinned code, so ci=true marks a receipt CI produced
  # itself (vs one an agent committed). ref records the branch/PR ref under test.
  local ci="false" ref
  if [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${CI:-}" ]; then ci="true"; fi
  ref="${GITHUB_REF:-}"
  local receipt
  receipt="$(printf '{"label":"%s","command":"%s","exit_code":%s,"sha256":"%s","log":"%s","at":"%s","epoch":%s,"session":"%s","commit":"%s","tree":"%s","dirty":%s,"schema_version":2,"ci":%s,"ref":"%s","repo":"%s","subject":"%s","producer":"%s","verifier":"%s","host_os":"%s","disposition":"%s"}' \
    "$(json_escape "$label")" "$(json_escape "${CMD[*]}")" "$rc" "$sha" \
    "$(json_escape "${log#"$ROOT/"}")" "$(timestamp)" "$(epoch)" \
    "$(json_escape "${AGENT_DONE_SESSION:-}")" "$(json_escape "$commit")" "$(json_escape "$tree")" "$dirty" \
    "$ci" "$(json_escape "$ref")" "$(json_escape "$repo")" "$(json_escape "$subject")" \
    "$(json_escape "$producer")" "$(json_escape "$verifier")" "$(json_escape "$os")" "$(json_escape "$disposition")")"
  printf '%s\n' "$receipt" >> "$dir/ledger.jsonl"

  printf '%s\n' "$run" > "$PROOF_DIR/latest.$$.tmp" && mv -f "$PROOF_DIR/latest.$$.tmp" "$PROOF_DIR/latest"

  if [ "$json" = "1" ]; then
    printf '%s\n' "$receipt"
  fi
  printf 'done-gate: captured label=%s run=%s exit=%s sha256=%s\n' "$label" "$run" "$rc" "$sha" >&2
  return "$rc"
}

cmd_assert() {
  local run="" ttl="" regex="" json=0 policy_flag="" no_policy=0
  local -a LABELS=() LABEL_REGEXES=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) [ "$#" -ge 2 ] || die "assert: --label requires a value"; LABELS+=("$2"); shift 2 ;;
      --run)   [ "$#" -ge 2 ] || die "assert: --run requires a value";   run="$2";   shift 2 ;;
      --ttl)   [ "$#" -ge 2 ] || die "assert: --ttl requires a value";   ttl="$2";   shift 2 ;;
      --allow-command-regex) [ "$#" -ge 2 ] || die "assert: --allow-command-regex requires a value"; regex="$2"; shift 2 ;;
      --policy) [ "$#" -ge 2 ] || die "assert: --policy requires a value"; policy_flag="$2"; shift 2 ;;
      --no-policy) no_policy=1; shift ;;
      --json)  json=1; shift ;;
      *)       die "assert: unexpected arg '$1'" ;;
    esac
  done
  regex="${regex:-${AGENT_DONE_ALLOWED_COMMANDS:-}}"

  # Resolution order: explicit CLI --label (legacy) > policy file > latest receipt.
  # CLI labels override everything so existing call sites are unchanged.
  local policy_used="" policy_mode=0
  if [ "${#LABELS[@]}" -gt 0 ]; then
    local _l
    for _l in "${LABELS[@]}"; do LABEL_REGEXES+=("$regex"); done
  elif [ "$no_policy" != "1" ]; then
    local policy_path; policy_path="$(resolve_policy_path "$policy_flag")"
    if [ -n "$policy_path" ] && [ -f "$policy_path" ]; then
      policy_used="${policy_path#"$ROOT/"}"
      local _lbl _rx _pttl
      while IFS="$(printf '\t')" read -r _lbl _rx; do
        [ -n "$_lbl" ] || continue
        LABELS+=("$_lbl")
        if [ -n "$_rx" ]; then LABEL_REGEXES+=("$_rx"); else LABEL_REGEXES+=("$regex"); fi
      done <<EOF
$(policy_entries "$policy_path")
EOF
      # A policy file was explicitly present but yielded no parseable "required"
      # entries — FAIL CLOSED instead of silently degrading to the latest-receipt
      # path (a policy that says "do more" must never quietly do less).
      if [ "${#LABELS[@]}" -eq 0 ]; then
        [ "$json" = "1" ] && printf '{"ok":false,"reason":"policy present but no parseable required entries","policy":"%s","checks":[]}\n' "$(json_escape "$policy_used")"
        printf 'done-gate: assert FAIL — policy %s present but no parseable "required" entries (check for nested braces / quoting)\n' "$policy_used" >&2
        return 1
      fi
      policy_mode=1
      if [ -z "$ttl" ]; then _pttl="$(policy_ttl "$policy_path")"; [ -n "$_pttl" ] && ttl="$_pttl"; fi
    fi
  fi
  ttl="${ttl:-${AGENT_DONE_TTL:-3600}}"
  case "$ttl" in ''|*[!0-9]*) die "assert: --ttl must be a non-negative integer" ;; esac

  # Run-scoped modes need a resolved run + ledger. Policy mode searches all runs
  # per label, so it only needs the proof dir to contain at least one ledger.
  local ledger="" run_label="$run"
  if [ "$policy_mode" = "1" ]; then
    run_label="*"
    if [ -z "$(ls -1 "$PROOF_DIR"/*/ledger.jsonl 2>/dev/null || true)" ]; then
      [ "$json" = "1" ] && printf '{"ok":false,"reason":"no proof receipts found","policy":"%s","checks":[]}\n' "$(json_escape "$policy_used")"
      printf 'done-gate: assert FAIL — no proof receipts found (capture something first)\n' >&2
      return 1
    fi
  else
    run="$(resolve_run_for_read "$run")"
    if [ -z "$run" ]; then
      [ "$json" = "1" ] && printf '{"ok":false,"reason":"no proof run found","policy":"%s","checks":[]}\n' "$(json_escape "$policy_used")"
      printf 'done-gate: assert FAIL — no proof run found (capture something first)\n' >&2
      return 1
    fi
    valid_name "$run" || die "assert: invalid run id"
    ledger="$PROOF_DIR/$run/ledger.jsonl"
    run_label="$run"
    if [ ! -f "$ledger" ]; then
      [ "$json" = "1" ] && printf '{"ok":false,"reason":"ledger missing","run":"%s","policy":"%s","checks":[]}\n' "$(json_escape "$run")" "$(json_escape "$policy_used")"
      printf 'done-gate: assert FAIL — no ledger for run=%s\n' "$run" >&2
      return 1
    fi

    # With no explicit/policy labels, assert against the most recent receipt.
    if [ "${#LABELS[@]}" -eq 0 ]; then
      local last; last="$(grep -E '.' "$ledger" | tail -n1 || true)"
      [ -n "$last" ] || { printf 'done-gate: assert FAIL — empty ledger\n' >&2; return 1; }
      local lbl0; lbl0="$(printf '%s' "$last" | sed -E 's/.*"label":"([^"]*)".*/\1/')"
      LABELS=("$lbl0"); LABEL_REGEXES=("$regex")
    fi
  fi

  local now; now="$(epoch)"
  local bind_state="${AGENT_DONE_BIND_STATE:-0}"
  local overall=0 checks="" first=1 idx=0 lbl lrx line ec ep sha cmd fresh cmd_ok line_ok is_exec
  local any_pass=0 weak_only=1 warn_label="" drift="" drift_warn=""
  for lbl in "${LABELS[@]}"; do
    lrx="${LABEL_REGEXES[$idx]:-}"; idx=$((idx + 1))
    if [ "$policy_mode" = "1" ]; then line="$(latest_for_label_global "$lbl")"; else line="$(latest_for_label "$ledger" "$lbl")"; fi
    ec=""; ep=""; sha=""; cmd=""; fresh="false"; cmd_ok="true"; line_ok="false"; drift=""; is_exec="true"
    if [ -n "$line" ]; then
      ec="$(rec_exit "$line" || true)"; ep="$(rec_epoch "$line" || true)"
      sha="$(rec_sha "$line" || true)"; cmd="$(rec_command "$line" || true)"
      # A committed claim/verdict record (disposition!=reexecuted) is not proof.
      is_execution_receipt "$line" || is_exec="false"
      if [ "${ttl:-0}" -le 0 ] 2>/dev/null; then fresh="true"
      elif [ -n "$ep" ] && [ "$now" -gt 0 ] 2>/dev/null && [ "$((now - ep))" -le "$ttl" ] 2>/dev/null; then fresh="true"; fi
      if [ -n "$lrx" ]; then
        if printf '%s' "$cmd" | grep -Eq "$lrx" 2>/dev/null; then cmd_ok="true"; else cmd_ok="false"; fi
      fi
      if [ "$ec" = "0" ] && [ "$fresh" = "true" ] && [ "$cmd_ok" = "true" ] && [ "$is_exec" = "true" ]; then line_ok="true"; fi
      # State binding: a passing receipt captured against different code is stale.
      if [ "$line_ok" = "true" ]; then
        drift="$(state_drift_reason "$line" "$bind_state" || true)"
        if [ -n "$drift" ]; then
          [ -n "$drift_warn" ] || drift_warn="$drift"
          if [ "$bind_state" = "1" ]; then line_ok="false"; fi
        fi
      fi
    fi
    [ "$line_ok" = "true" ] || overall=1

    # advisory wrong-check bookkeeping (never affects the exit code)
    if [ "$line_ok" = "true" ]; then
      any_pass=1
      if label_is_weak "$lbl"; then warn_label="$lbl"; else weak_only=0; fi
    fi

    if [ "$json" = "1" ]; then
      [ "$first" = "1" ] || checks="$checks,"
      first=0
      checks="$checks{\"label\":\"$(json_escape "$lbl")\",\"found\":$([ -n "$line" ] && echo true || echo false),\"exit_code\":${ec:-null},\"fresh\":$fresh,\"command_allowed\":$cmd_ok,\"sha256\":\"$(json_escape "${sha:-}")\",\"drift\":\"$(json_escape "${drift:-}")\",\"ok\":$line_ok}"
    else
      if [ "$line_ok" = "true" ]; then
        printf 'done-gate: assert OK   label=%s exit=%s fresh=%s\n' "$lbl" "${ec:-?}" "$fresh" >&2
      else
        printf 'done-gate: assert FAIL label=%s found=%s exit=%s fresh=%s command_allowed=%s\n' \
          "$lbl" "$([ -n "$line" ] && echo yes || echo no)" "${ec:-?}" "$fresh" "$cmd_ok" >&2
        if [ -n "$line" ] && [ "$is_exec" = "false" ]; then
          printf 'done-gate: assert FAIL label=%s — receipt is a claim/verdict record (disposition!=reexecuted), not a re-executed check\n' "$lbl" >&2
        fi
      fi
    fi
  done

  if [ "$json" = "1" ]; then
    printf '{"ok":%s,"run":"%s","ttl":%s,"policy":"%s","state_drift":"%s","checks":[%s]}\n' \
      "$([ "$overall" = "0" ] && echo true || echo false)" "$(json_escape "$run_label")" "$ttl" "$(json_escape "$policy_used")" "$(json_escape "${drift_warn:-}")" "$checks"
  else
    if [ -n "$drift_warn" ]; then
      if [ "$bind_state" = "1" ]; then
        printf 'done-gate: assert FAIL — %s (AGENT_DONE_BIND_STATE=1)\n' "$drift_warn" >&2
      else
        printf 'done-gate: WARNING — %s — re-run your check\n' "$drift_warn" >&2
      fi
    fi
    if [ "$any_pass" = "1" ] && [ "$weak_only" = "1" ]; then
      printf 'done-gate: WARNING — latest proof is %s-only — this may not verify the requested behavior\n' "$warn_label" >&2
    fi
  fi
  return "$overall"
}

cmd_verify() {
  local label="" run="" sha="" json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --label) [ "$#" -ge 2 ] || die "verify: --label requires a value"; label="$2"; shift 2 ;;
      --run)   [ "$#" -ge 2 ] || die "verify: --run requires a value";   run="$2";   shift 2 ;;
      --sha)   [ "$#" -ge 2 ] || die "verify: --sha requires a value";   sha="$2";   shift 2 ;;
      --json)  json=1; shift ;;
      *)       die "verify: unexpected arg '$1'" ;;
    esac
  done
  [ -n "$label" ] || die "verify: --label is required"
  [ -n "$sha" ]   || die "verify: --sha is required"
  run="$(resolve_run_for_read "$run")"
  [ -n "$run" ] || die "verify: no run found (run a capture first or pass --run)"
  valid_name "$run" || die "verify: invalid run id"
  local ledger="$PROOF_DIR/$run/ledger.jsonl"
  [ -f "$ledger" ] || die "verify: no ledger at $ledger"

  local vline got
  vline="$(latest_for_label "$ledger" "$label")"
  # A claim/verdict record (disposition!=reexecuted) is not execution evidence,
  # so its recorded hash must never verify as a re-run output.
  is_execution_receipt "$vline" || vline=""
  got="$(printf '%s' "$vline" | grep -oE '"sha256":"[0-9a-f]+"' | sed -E 's/"sha256":"([0-9a-f]+)"/\1/')"
  local ok="false"
  [ -n "$got" ] && [ "$got" = "$sha" ] && ok="true"

  if [ "$json" = "1" ]; then
    printf '{"ok":%s,"label":"%s","run":"%s","recorded":"%s","expected":"%s"}\n' \
      "$ok" "$(json_escape "$label")" "$(json_escape "$run")" "$(json_escape "${got:-}")" "$(json_escape "$sha")"
  fi
  if [ "$ok" = "true" ]; then
    printf 'done-gate: verify OK label=%s run=%s sha256=%s\n' "$label" "$run" "$got" >&2
    return 0
  fi
  if [ -z "$got" ]; then
    printf 'done-gate: verify FAIL — no record for label=%s in run=%s\n' "$label" "$run" >&2
  else
    printf 'done-gate: verify MISMATCH label=%s run=%s recorded=%s expected=%s\n' "$label" "$run" "$got" "$sha" >&2
  fi
  return 1
}

cmd_show() {
  local run="" json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run)  [ "$#" -ge 2 ] || die "show: --run requires a value"; run="$2"; shift 2 ;;
      --json) json=1; shift ;;
      *)      die "show: unexpected arg '$1'" ;;
    esac
  done
  run="$(resolve_run_for_read "$run")"
  [ -n "$run" ] || die "show: no run found"
  valid_name "$run" || die "show: invalid run id"
  local ledger="$PROOF_DIR/$run/ledger.jsonl"
  [ -f "$ledger" ] || die "show: no ledger at $ledger"

  if [ "$json" = "1" ]; then
    local body first=1 ln
    body=""
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      [ "$first" = "1" ] || body="$body,"
      first=0
      body="$body$ln"
    done < "$ledger"
    printf '{"run":"%s","receipts":[%s]}\n' "$(json_escape "$run")" "$body"
  else
    printf '# proof ledger — run=%s\n' "$run"
    cat "$ledger"
  fi
}

# --- audit: diff an agent's CLAIMS against the receipt ledger ------------------
#
# Two claim sources, tried in order (the CLI tags each so a human can weight it):
#   1. Structured markers the agent is instructed to emit (the contract):
#        <agent-done:claim label="test" exit="0" sha256="9f2c…" />
#      Emitting a marker asserts the check PASSED; add exit="N" to claim a code.
#   2. Conservative transcript heuristics (fallback) for claim-shaped prose with
#      no marker. Heuristic claims are tagged `inferred` and never silently
#      upgraded to backed.
#
# Verdicts (per claim, joined to the ledger by label; only EXECUTION receipts can
# back a claim):
#   BACKED             matching receipt, exit + hash consistent.
#   UNBACKED           asserted, but no receipt exists.
#   MISREPORTED        claimed success (exit 0) but recorded exit is non-zero.
#   INTEGRITY_MISMATCH claimed a sha256 that != the recorded sha256.
#   UNPARSED           claim-shaped text with no bindable label — reported, never
#                      counted as backed.
# (Never "TAMPERED": a hash proves a mismatch, not who caused it.)
#
# Exit non-zero if any claim is UNBACKED, MISREPORTED, or INTEGRITY_MISMATCH.

marker_attr() {
  # marker_attr <marker-string> <attr-name>
  printf '%s' "$1" | grep -oE "$2=\"[^\"]*\"" | head -n1 | sed -E "s/^$2=\"([^\"]*)\"$/\1/" || true
}

audit_labels() {
  # distinct labels present in a ledger. LC_ALL=C so the sort order (which the
  # heuristic uses to pick the first matching label) is byte-ordinal — identical
  # to the PowerShell port's Ordinal sort, keeping --json byte-for-byte in sync.
  grep -oE '"label":"[^"]*"' "$1" 2>/dev/null | sed -E 's/"label":"([^"]*)"/\1/' | LC_ALL=C sort -u || true
}

# Regex-escape a label for use in an ERE (labels may contain '.'; '-'/'_' are
# literal outside a bracket expression).
audit_label_re() { printf '%s' "$1" | sed 's/\./\\./g'; }

audit_receipt() {
  # latest EXECUTION receipt for a label, or empty (a claim/verdict record cannot
  # back a claim)
  local ledger="$1" label="$2" line
  line="$(latest_for_label "$ledger" "$label")"
  [ -n "$line" ] || { printf ''; return; }
  is_execution_receipt "$line" || { printf ''; return; }
  printf '%s' "$line"
}

audit_verdict() {
  # audit_verdict <ledger> <label> <claimed_exit> <claimed_sha> -> VERDICT
  local ledger="$1" label="$2" cexit="$3" csha="$4" r rec_e rec_s eff claims_success
  [ -n "$label" ] || { printf 'UNPARSED'; return; }
  r="$(audit_receipt "$ledger" "$label")"
  [ -n "$r" ] || { printf 'UNBACKED'; return; }
  rec_e="$(rec_exit "$r" || true)"; rec_s="$(rec_sha "$r" || true)"
  # Does the claim assert success? A marker asserts success unless it explicitly
  # states a non-zero exit code. Normalize first so a zero-looking-but-not-"0"
  # value (00, " 0") or garbage ("fail") can't skip the MISREPORTED check and
  # launder a failing check into BACKED. Only a clean non-zero integer claims a
  # non-zero code.
  eff="$(printf '%s' "$cexit" | tr -d '[:space:]')"
  case "$eff" in
    ''|*[!0-9]*) claims_success=1 ;;   # absent or non-numeric -> asserts success
    *[!0]*)      claims_success=0 ;;   # a non-zero digit -> claims a non-zero code
    *)           claims_success=1 ;;   # all zeros -> success
  esac
  if [ "$claims_success" = "1" ] && [ -n "$rec_e" ] && [ "$rec_e" != "0" ]; then printf 'MISREPORTED'; return; fi
  if [ -n "$csha" ] && [ -n "$rec_s" ] && [ "$csha" != "$rec_s" ]; then printf 'INTEGRITY_MISMATCH'; return; fi
  printf 'BACKED'
}

# Conservative claim-shaped-line matcher for the heuristic fallback.
AUDIT_CLAIM_RE='[Tt]ests?[[:space:]]+(pass|passed|passing)|[Ll]int[[:space:]]+(clean|passes|passed)|[Bb]uild[[:space:]]+(succeed|succeeds|succeeded|passes|passed)|all[[:space:]]+(tests[[:space:]]+)?green|[Vv]erified|ran[[:space:]]+successfully|exit[[:space:]]+(code[[:space:]]+)?0'

cmd_audit() {
  local transcript="" run="" json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --transcript) [ "$#" -ge 2 ] || die "audit: --transcript requires a value"; transcript="$2"; shift 2 ;;
      --run)        [ "$#" -ge 2 ] || die "audit: --run requires a value";        run="$2";        shift 2 ;;
      --json)       json=1; shift ;;
      *)            die "audit: unexpected arg '$1'" ;;
    esac
  done
  [ -n "$transcript" ] || die "audit: --transcript <file|-> is required"

  run="$(resolve_run_for_read "$run")"
  [ -n "$run" ] || die "audit: no run found (run a capture first or pass --run)"
  valid_name "$run" || die "audit: invalid run id"
  local ledger="$PROOF_DIR/$run/ledger.jsonl"
  [ -f "$ledger" ] || die "audit: no ledger at $ledger"

  # NOTE: tmp is intentionally NOT `local` and cleaned on EXIT (not RETURN): a
  # RETURN trap is global and would re-fire on main()'s return, where a local
  # would be out of scope and trip `set -u`. EXIT fires once, after the value is
  # still readable, and also covers the die() error paths.
  tmp="$(mktemp -d 2>/dev/null)" || die "audit: cannot create a temp dir"
  trap 'rm -rf "${tmp:-}" 2>/dev/null || true' EXIT
  local src="$tmp/transcript" claims="$tmp/claims"
  # Field separator for the normalized claim rows: a Unit Separator (US, 0x1f).
  # It is NOT IFS-whitespace, so empty fields between separators are preserved
  # (a plain tab would collapse them and misalign the columns).
  local US; US=$'\037'
  if [ "$transcript" = "-" ]; then cat > "$src"; else [ -f "$transcript" ] || die "audit: transcript not found: $transcript"; cp "$transcript" "$src"; fi
  : > "$claims"

  # 1) structured markers (the contract). One normalized row per marker:
  #    label US claimed_exit US claimed_sha US source
  local marker label cexit csha
  # put each marker element on its own line first
  grep -oE '<agent-done:claim[^>]*>' "$src" 2>/dev/null > "$tmp/markers" || true
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    label="$(marker_attr "$marker" label)"
    cexit="$(marker_attr "$marker" exit)"
    csha="$(marker_attr "$marker" sha256)"
    printf '%s%s%s%s%s%smarker\n' "$label" "$US" "$cexit" "$US" "$csha" "$US" >> "$claims"
  done < "$tmp/markers"

  # set of labels already claimed by a marker (so heuristics don't double-count)
  local marked; marked="$(cut -d"$US" -f1 "$claims" 2>/dev/null | grep -v '^$' | sort -u || true)"

  # 2) heuristic fallback: claim-shaped lines with no marker. Bind to the first
  #    known ledger label the line mentions; otherwise record as unparsed. Each
  #    heuristic claim is tagged `inferred` and (per label) recorded at most once.
  local known; known="$(audit_labels "$ledger")"
  local line hit lbl seen_inferred=""
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qE "$AUDIT_CLAIM_RE" 2>/dev/null || continue
    if printf '%s' "$line" | grep -q '<agent-done:claim' 2>/dev/null; then continue; fi
    hit=""
    while IFS= read -r lbl; do
      [ -n "$lbl" ] || continue
      # Bind only on a WHOLE-token match: the label must be delimited by a
      # non-label character (or string end) on both sides. Prevents "test" from
      # binding "greatest"/"latest" and spuriously failing an honest report.
      if printf '%s' "$line" | grep -qE "(^|[^A-Za-z0-9._-])$(audit_label_re "$lbl")([^A-Za-z0-9._-]|\$)" 2>/dev/null; then hit="$lbl"; break; fi
    done <<EOF
$known
EOF
    if [ -n "$hit" ]; then
      if printf '%s\n' "$marked" | grep -qxF "$hit" 2>/dev/null; then continue; fi
      if printf '%s\n' "$seen_inferred" | grep -qxF "$hit" 2>/dev/null; then continue; fi
      seen_inferred="$seen_inferred
$hit"
      printf '%s%s%s%sinferred\n' "$hit" "$US" "$US" "$US" >> "$claims"
    else
      # claim-shaped but not bindable to a label -> UNPARSED (reported, not backed)
      printf '%s%s%sinferred\n' "$US" "$US" "$US" >> "$claims"
    fi
  done < "$src"

  # 3) compute verdicts + tallies
  local n=0 backed=0 unbacked=0 misrep=0 integ=0 unparsed=0 nmark=0 ninf=0
  local rows="" first=1 v r rexit rsha rowline
  local c_label c_exit c_sha c_src
  while IFS="$US" read -r c_label c_exit c_sha c_src; do
    [ -n "$c_label$c_exit$c_sha$c_src" ] || continue
    n=$((n+1))
    if [ "$c_src" = "marker" ]; then nmark=$((nmark+1)); else ninf=$((ninf+1)); fi
    v="$(audit_verdict "$ledger" "$c_label" "$c_exit" "$c_sha")"
    r="$(audit_receipt "$ledger" "$c_label")"
    rexit="$(printf '%s' "$r" | grep -oE '"exit_code":[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"
    rsha="$(printf '%s' "$r" | grep -oE '"sha256":"[0-9a-f]+"' | head -n1 | sed -E 's/.*"([0-9a-f]+)".*/\1/' || true)"
    case "$v" in
      BACKED) backed=$((backed+1)) ;;
      UNBACKED) unbacked=$((unbacked+1)) ;;
      MISREPORTED) misrep=$((misrep+1)) ;;
      INTEGRITY_MISMATCH) integ=$((integ+1)) ;;
      UNPARSED) unparsed=$((unparsed+1)) ;;
    esac
    if [ "$json" = "1" ]; then
      [ "$first" = "1" ] || rows="$rows,"
      first=0
      rows="$rows{\"label\":\"$(json_escape "$c_label")\",\"source\":\"$c_src\",\"verdict\":\"$v\",\"claimed_exit\":\"$(json_escape "${c_exit:-}")\",\"claimed_sha256\":\"$(json_escape "${c_sha:-}")\",\"recorded_exit\":${rexit:-null},\"recorded_sha256\":\"$(json_escape "${rsha:-}")\"}"
    else
      printf -v rowline '%-18s %-8s %-18s claimed[exit=%s sha=%.12s] recorded[exit=%s sha=%.12s]' \
        "${c_label:-<unparsed>}" "$c_src" "$v" "${c_exit:-0}" "${c_sha:-—}" "${rexit:-—}" "${rsha:-—}"
      rows="$rows$rowline"$'\n'
    fi
  done < "$claims"

  local ok=true
  if [ "$unbacked" -gt 0 ] || [ "$misrep" -gt 0 ] || [ "$integ" -gt 0 ]; then ok=false; fi

  if [ "$json" = "1" ]; then
    printf '{"run":"%s","transcript":"%s","ok":%s,"summary":{"claims":%s,"backed":%s,"unbacked":%s,"misreported":%s,"integrity_mismatch":%s,"unparsed":%s,"marker":%s,"inferred":%s},"claims":[%s]}\n' \
      "$(json_escape "$run")" "$(json_escape "$transcript")" "$ok" \
      "$n" "$backed" "$unbacked" "$misrep" "$integ" "$unparsed" "$nmark" "$ninf" "$rows"
  else
    printf '# claim audit — run=%s  transcript=%s\n' "$run" "$transcript"
    if [ "$n" = "0" ]; then
      printf 'done-gate: audit — no claims found (0 markers, no claim-shaped lines).\n'
    else
      printf '%s' "$rows"
    fi
    printf 'Summary: %s claim(s) — %s backed, %s unbacked, %s misreported, %s integrity-mismatch, %s unparsed (%s marker, %s inferred)\n' \
      "$n" "$backed" "$unbacked" "$misrep" "$integ" "$unparsed" "$nmark" "$ninf" >&2
    printf 'Coverage: audited against run=%s. Inferred claims are best-effort; unparsed claims are reported, never counted as backed.\n' "$run" >&2
    if [ "$ok" = "false" ]; then
      printf 'done-gate: audit FAIL — %s unbacked, %s misreported, %s integrity-mismatch\n' "$unbacked" "$misrep" "$integ" >&2
    else
      printf 'done-gate: audit OK — no unbacked, misreported, or integrity-mismatched claims\n' >&2
    fi
  fi

  [ "$ok" = "true" ]
}

# --- review-pr: re-execute an AI-authored PR's claimed checks ("PR Receipts") ---
#
# Parse the testable claims out of a PR description / commit messages ("tests
# pass", "lint clean", "build succeeds"), auto-resolve the project's REAL
# commands from its manifests, re-execute them, and print a receipt splitting
# claims into RE-EXECUTED / ASSERTED / UNPARSED. It never says "VERIFIED": a
# green re-run proves the command passed here and now, not that the PR is correct.
#
# SECURITY: the re-executed command is chosen ONLY from this file's fixed
# per-ecosystem resolution table — it is NEVER derived from PR text. The PR body
# selects which CATEGORY (test/lint/build) is claimed; it can never inject a
# command. Re-execution still runs the project's own code, so untrusted PRs
# belong in a CI sandbox with NO secrets and NOT pull_request_target — see
# docs/pr-receipts.md.

# Resolve category (test|lint|build) -> the project's real command, or empty.
# First matching manifest wins. Only well-known canonical commands, no guessing.
pr_resolve() {
  local cat="$1"
  if [ -f package.json ]; then
    case "$cat" in
      test)  grep -qE '"test"[[:space:]]*:'  package.json 2>/dev/null && printf 'npm test' ;;
      lint)  grep -qE '"lint"[[:space:]]*:'  package.json 2>/dev/null && printf 'npm run lint' ;;
      build) grep -qE '"build"[[:space:]]*:' package.json 2>/dev/null && printf 'npm run build' ;;
    esac
  elif [ -f pyproject.toml ]; then
    case "$cat" in
      test) printf 'pytest' ;;
      lint) printf 'ruff check .' ;;
      build) : ;;   # no single canonical Python build command -> asserted
    esac
  elif [ -f go.mod ]; then
    case "$cat" in
      test)  printf 'go test ./...' ;;
      lint)  printf 'go vet ./...' ;;
      build) printf 'go build ./...' ;;
    esac
  fi
}

# claim-shape patterns (matched case-insensitively, ERE)
PR_RE_TEST='tests?[[:space:]]+(pass|passed|passing|are[[:space:]]+green|succeed(s|ed)?)|(all[[:space:]]+)?tests?[[:space:]]+green|test[[:space:]]+suite[[:space:]]+pass'
PR_RE_LINT='lint(ing)?[[:space:]]+(clean|passes|passed|is[[:space:]]+clean)|no[[:space:]]+lint[[:space:]]+(error|warning)'
PR_RE_BUILD='builds?[[:space:]]+(succeed(s|ed)?|passes|passed|works|is[[:space:]]+green|clean(ly)?|success)|compiles?[[:space:]]+(clean(ly)?|success)'
# recognized-but-not-re-executable assertions
PR_RE_ASSERTED='no[[:space:]]+breaking[[:space:]]+changes|backwards?[[:space:]]+compatible|handles?[[:space:]]+(all[[:space:]]+)?edge[[:space:]]+cases|no[[:space:]]+regressions?|fully[[:space:]]+tested'
# vague merge-readiness phrases -> unparsed
PR_RE_UNPARSED='(ready|good)[[:space:]]+to[[:space:]]+(merge|go)|looks[[:space:]]+good|lgtm|should[[:space:]]+be[[:space:]]+(good|fine|ready)'

pr_match() { grep -ioE "$2" "$1" 2>/dev/null | head -n1 || true; }

cmd_review_pr() {
  local body="" commits=0 base="" json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body)    [ "$#" -ge 2 ] || die "review-pr: --body requires a value"; body="$2"; shift 2 ;;
      --commits) commits=1; shift ;;
      --base)    [ "$#" -ge 2 ] || die "review-pr: --base requires a value"; base="$2"; shift 2 ;;
      --json)    json=1; shift ;;
      *)         die "review-pr: unexpected arg '$1'" ;;
    esac
  done
  [ -n "$body" ] || die "review-pr: --body <file|-> is required"

  tmp="$(mktemp -d 2>/dev/null)" || die "review-pr: cannot create a temp dir"
  trap 'rm -rf "${tmp:-}" 2>/dev/null || true' EXIT
  local claimfile="$tmp/claims.txt"
  if [ "$body" = "-" ]; then cat > "$claimfile"; else [ -f "$body" ] || die "review-pr: body not found: $body"; cp "$body" "$claimfile"; fi
  # optionally fold in commit-message subjects/bodies from base..HEAD
  if [ "$commits" = "1" ]; then
    [ -n "$base" ] || base="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || printf 'origin/HEAD')"
    git log --format=%B "$base"..HEAD 2>/dev/null >> "$claimfile" || true
  fi
  # Normalize whitespace to single spaces BEFORE matching: a word-wrapped PR
  # description breaks a phrase across lines ("...and the\ntests pass..."). Folding
  # newlines/tabs to spaces (and squeezing runs) lets a wrapped claim match, AND
  # keeps this line-agnostic engine byte-identical with the PowerShell port, whose
  # .NET \s crosses newlines.
  LC_ALL=C tr '\r\n\t' '   ' < "$claimfile" | tr -s ' ' > "$claimfile.norm"
  claimfile="$claimfile.norm"

  local reexec="" asserted="" unparsed="" first_r=1 first_a=1 first_u=1
  local n_reexec=0 n_asserted=0 n_unparsed=0 overall=0
  local US; US=$'\037'

  # 1) re-executable categories: claimed -> resolve -> re-execute (or assert if
  #    no command resolves).
  local cat re claim cmd logf rc sha status
  for cat in test lint build; do
    case "$cat" in test) re="$PR_RE_TEST";; lint) re="$PR_RE_LINT";; build) re="$PR_RE_BUILD";; esac
    claim="$(pr_match "$claimfile" "$re")"
    [ -n "$claim" ] || continue
    cmd="$(pr_resolve "$cat" || true)"
    if [ -z "$cmd" ]; then
      # claimed, but nothing to re-execute against -> asserted (unverified)
      asserted="$asserted$claim${US}no $cat command resolved from the project's manifests$US"$'\n'
      n_asserted=$((n_asserted+1)); continue
    fi
    logf="$tmp/$cat.log"
    # NOTE: $cmd is a fixed internal string (see pr_resolve), never PR-derived.
    # A claimed check that FAILS on re-run is a real receipt, not a script error,
    # so disable set -e around it and capture the command's own exit code.
    # stdin is redirected from /dev/null so a check that reads stdin can't block.
    # timeout: prefer GNU `timeout`, then `gtimeout` (macOS/Homebrew coreutils).
    local to_bin=""
    command -v timeout  >/dev/null 2>&1 && to_bin="timeout"
    [ -n "$to_bin" ] || { command -v gtimeout >/dev/null 2>&1 && to_bin="gtimeout"; }
    set +e
    if [ -n "$to_bin" ]; then
      "$to_bin" "${AGENT_DONE_PR_TIMEOUT:-300}" sh -c "$cmd" > "$logf" 2>&1 < /dev/null; rc=$?
    else
      sh -c "$cmd" > "$logf" 2>&1 < /dev/null; rc=$?
    fi
    set -e
    sha="$(sha256_of_file "$logf" 2>/dev/null || printf '')"
    [ "$rc" = "0" ] && status="pass" || { status="fail"; overall=1; }
    reexec="$reexec$claim$US$cmd$US$rc$US$sha$US$status"$'\n'
    n_reexec=$((n_reexec+1))
  done

  # 2) recognized-but-not-re-executable assertions.
  local a_claim
  a_claim="$(pr_match "$claimfile" "$PR_RE_ASSERTED")"
  if [ -n "$a_claim" ]; then
    asserted="$asserted$a_claim${US}no command maps to this claim$US"$'\n'
    n_asserted=$((n_asserted+1))
  fi

  # 3) vague / unparsed claim-shaped phrases.
  local u_claim
  u_claim="$(pr_match "$claimfile" "$PR_RE_UNPARSED")"
  if [ -n "$u_claim" ]; then
    unparsed="$unparsed$u_claim"$'\n'
    n_unparsed=$((n_unparsed+1))
  fi

  if [ "$json" = "1" ]; then
    local rows_r="" rows_a="" rows_u="" c cm rc2 sh2 st2 cl rsn ph
    while IFS="$US" read -r c cm rc2 sh2 st2; do
      [ -n "$c$cm" ] || continue
      [ "$first_r" = "1" ] || rows_r="$rows_r,"; first_r=0
      rows_r="$rows_r{\"claim\":\"$(json_escape "$c")\",\"command\":\"$(json_escape "$cm")\",\"exit_code\":${rc2:-null},\"sha256\":\"$(json_escape "$sh2")\",\"status\":\"$st2\"}"
    done <<< "$reexec"
    while IFS="$US" read -r cl rsn; do
      [ -n "$cl$rsn" ] || continue
      [ "$first_a" = "1" ] || rows_a="$rows_a,"; first_a=0
      rows_a="$rows_a{\"claim\":\"$(json_escape "$cl")\",\"reason\":\"$(json_escape "$rsn")\"}"
    done <<< "$asserted"
    while IFS= read -r ph; do
      [ -n "$ph" ] || continue
      [ "$first_u" = "1" ] || rows_u="$rows_u,"; first_u=0
      rows_u="$rows_u\"$(json_escape "$ph")\""
    done <<< "$unparsed"
    printf '{"ok":%s,"summary":{"reexecuted":%s,"asserted":%s,"unparsed":%s},"reexecuted":[%s],"asserted":[%s],"unparsed":[%s]}\n' \
      "$([ "$overall" = "0" ] && echo true || echo false)" "$n_reexec" "$n_asserted" "$n_unparsed" "$rows_r" "$rows_a" "$rows_u"
  else
    printf '# PR Receipts\n\n'
    printf 'RE-EXECUTED (%s claim(s) re-run)\n' "$n_reexec"
    if [ "$n_reexec" = "0" ]; then printf '  (none)\n'; else
      while IFS="$US" read -r c cm rc2 sh2 st2; do
        [ -n "$c$cm" ] || continue
        if [ "$st2" = "pass" ]; then mark="PASS"; else mark="FAIL"; fi
        printf '  %-4s "%s"  -> %s  exit=%s  sha256=%.12s\n' "$mark" "$c" "$cm" "$rc2" "$sh2"
      done <<< "$reexec"
    fi
    printf '\nASSERTED (%s claim(s), no re-executable evidence)\n' "$n_asserted"
    if [ "$n_asserted" = "0" ]; then printf '  (none)\n'; else
      while IFS="$US" read -r cl rsn; do
        [ -n "$cl$rsn" ] || continue
        printf '  ?    "%s"  -- %s\n' "$cl" "$rsn"
      done <<< "$asserted"
    fi
    printf '\nUNPARSED (%s claim-like phrase(s), not confidently matched)\n' "$n_unparsed"
    if [ "$n_unparsed" = "0" ]; then printf '  (none)\n'; else
      while IFS= read -r ph; do [ -n "$ph" ] || continue; printf '  .    "%s"\n' "$ph"; done <<< "$unparsed"
    fi
    printf '\nA green re-run proves the command passed here and now, not that the PR is correct.\n' >&2
    if [ "$overall" = "0" ]; then
      printf 'done-gate: review-pr OK — %s re-executed claim(s) passed\n' "$n_reexec" >&2
    else
      printf 'done-gate: review-pr FAIL — a re-executed claim did not pass\n' >&2
    fi
  fi

  [ "$overall" = "0" ]
}

usage() {
  sed -n '2,52p' "$0"
}

main() {
  [ "$#" -ge 1 ] || { usage; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    capture)   cmd_capture "$@" ;;
    assert)    cmd_assert "$@" ;;
    verify)    cmd_verify "$@" ;;
    show)      cmd_show "$@" ;;
    audit)     cmd_audit "$@" ;;
    review-pr) cmd_review_pr "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown subcommand '$sub' (capture | assert | verify | show | audit | review-pr)" ;;
  esac
}

main "$@"
