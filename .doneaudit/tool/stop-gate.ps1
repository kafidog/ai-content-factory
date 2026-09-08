# stop-gate.ps1 - block "done" until it's proven.
#
# A Stop-event hook for Claude Code (and any harness with a stop/finish hook).
# It blocks the agent from ending its turn unless the MOST RECENT proof receipt
# (written by done-gate.ps1 or done-gate.sh) is a PASSING check that has not
# already been used to clear a previous stop. In plain terms:
#
#   "Your last recorded check must be a fresh, green one - or you can't say done."
#
# This is a FORCING FUNCTION, not a semantic oracle: it confirms a check ran and
# passed since your previous completion. It does not judge whether it was the
# RIGHT check - you choose that. (Semantic binding is on the v0.2 roadmap.)
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
#     "command": "powershell -NoProfile -File \"$env:CLAUDE_PROJECT_DIR\stop-gate.ps1\"" }] }] }
#
# Bypass (escape hatch): set AGENT_DONE_OFF=1
#
# Knobs: AGENT_DONE_TTL (default 3600s), AGENT_DONE_MAX_RETRIES (default 10),
#        AGENT_DONE_DIR (default <repo>/.agent-proof).
#
# Exits:  0 = allow (disabled, verified receipt, or anti-loop safety valve).
#         2 = block.

$ErrorActionPreference = 'Stop'

function Write-Stderr {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Get-Utf8NoBom {
    return (New-Object System.Text.UTF8Encoding($false))
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Value
    )
    [System.IO.File]::WriteAllText($Path, $Value, (Get-Utf8NoBom))
}

function Test-ValidName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name.Contains('..')) { return $false }
    return ($Name -match '^[A-Za-z0-9._-]+$')
}

function Rec-Field {
    param(
        [string]$Line,
        [string]$Pattern
    )
    $m = [regex]::Match($Line, $Pattern)
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Receipt-ExitCode {
    param([string]$Line)
    return (Rec-Field $Line '"exit_code":([0-9]+)')
}

function Receipt-Epoch {
    param([string]$Line)
    return (Rec-Field $Line '"epoch":([0-9]+)')
}

function Receipt-Sha {
    param([string]$Line)
    return (Rec-Field $Line '"sha256":"([0-9a-f]+)"')
}

function Get-UnixEpoch {
    return ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
}

function Get-ScriptDir {
    return (Split-Path -Parent $MyInvocation.ScriptName)
}

function Get-Root {
    if ($env:CLAUDE_PROJECT_DIR) { return $env:CLAUDE_PROJECT_DIR }
    try {
        $root = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $root) {
            return ([string]$root).Trim()
        }
    } catch {
    }
    return $script:SCRIPT_DIR
}

function Get-ProofDir {
    if ($env:AGENT_DONE_DIR) { return $env:AGENT_DONE_DIR }
    if ($env:CLAUDE_PROJECT_DIR) { return (Join-Path $env:CLAUDE_PROJECT_DIR '.agent-proof') }
    try {
        $root = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $root) {
            return (Join-Path ([string]$root).Trim() '.agent-proof')
        }
    } catch {
    }
    return (Join-Path $script:SCRIPT_DIR '.agent-proof')
}

function Extract-JsonString {
    param(
        [string]$Payload,
        [string]$Key
    )
    $flat = $Payload -replace "[`r`n]", ' '
    $pattern = '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]*)"'
    return (Rec-Field $flat $pattern)
}

function Extract-JsonBool {
    param(
        [string]$Payload,
        [string]$Key
    )
    $flat = $Payload -replace "[`r`n]", ' '
    $pattern = '"' + [regex]::Escape($Key) + '"\s*:\s*(true|false)'
    return (Rec-Field $flat $pattern)
}

function Set-Session {
    param([string]$SessionId)
    $safe = $SessionId -replace '[^A-Za-z0-9._-]', '_'
    if ($safe.Length -gt 128) { $safe = $safe.Substring(0, 128) }
    if ([string]::IsNullOrEmpty($safe)) { $safe = '_nosession' }
    $script:SESSION = $safe
    $script:RETRY_FILE = Join-Path $script:GATE_DIR ('retries.' + $safe)
}

function Deny {
    param([string]$Reason)

    if ([string]::IsNullOrEmpty($script:GATE_DIR)) {
        $script:GATE_DIR = Join-Path (Join-Path $script:SCRIPT_DIR '.agent-proof') '.gate'
    }
    if ([string]::IsNullOrEmpty($script:RETRY_FILE)) {
        Set-Session '_nosession'
    }

    $max = 10
    if ($env:AGENT_DONE_MAX_RETRIES) {
        $parsedMax = 0
        if ([int]::TryParse($env:AGENT_DONE_MAX_RETRIES, [ref]$parsedMax)) { $max = $parsedMax }
    }

    $n = 0
    try {
        New-Item -ItemType Directory -Force -Path $script:GATE_DIR | Out-Null
        if (Test-Path -LiteralPath $script:RETRY_FILE) {
            $raw = Get-Content -Raw -LiteralPath $script:RETRY_FILE
            $digits = $raw -replace '[^0-9]', ''
            if (-not [string]::IsNullOrEmpty($digits)) { $n = [int]$digits }
        }
        $n += 1
        $tmp = $script:RETRY_FILE + '.' + $PID + '.tmp'
        Write-TextFile $tmp ($n.ToString() + [Environment]::NewLine)
        Move-Item -Force -LiteralPath $tmp -Destination $script:RETRY_FILE
    } catch {
        $n += 1
    }

    if ($max -gt 0 -and $n -ge $max) {
        Write-Stderr ("stop-gate: WARNING - {0} consecutive blocks; failing OPEN to avoid an" -f $n)
        Write-Stderr 'stop-gate: infinite stop loop. The agent is finishing WITHOUT proof.'
        Write-Stderr "stop-gate: reason was: $Reason"
        Write-Stderr 'stop-gate: fix your check, or set AGENT_DONE_OFF=1 to silence this gate.'
        exit 0
    }

    Write-Stderr "stop-gate: BLOCKED - $Reason"
    Write-Stderr 'stop-gate: prove your work first:'
    Write-Stderr 'stop-gate:   pwsh -File done-gate.ps1 capture --label check -- <your test/build/run command>'
    Write-Stderr 'stop-gate: then finish. (escape hatch: set AGENT_DONE_OFF=1)'
    exit 2
}

function Allow {
    param([string]$Reason)
    try {
        if (-not [string]::IsNullOrEmpty($script:RETRY_FILE)) {
            Remove-Item -Force -LiteralPath $script:RETRY_FILE -ErrorAction SilentlyContinue
        }
    } catch {
    }
    Write-Stderr "stop-gate: OK - $Reason"
    exit 0
}

$script:SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:GATE_DIR = ''
$script:SESSION = ''
$script:RETRY_FILE = ''

try {
    if ($env:AGENT_DONE_OFF -eq '1') { exit 0 }

    $payload = ''
    if ([Console]::IsInputRedirected) {
        $payload = [Console]::In.ReadToEnd()
    }
    if ([string]::IsNullOrEmpty($payload)) { exit 0 }

    $proofDir = Get-ProofDir
    $script:GATE_DIR = Join-Path $proofDir '.gate'

    $sessionId = Extract-JsonString $payload 'session_id'
    Set-Session $sessionId
    $stopHookActive = Extract-JsonBool $payload 'stop_hook_active'
    [void]$stopHookActive

    $latestPtr = Join-Path $proofDir 'latest'
    if (-not (Test-Path -LiteralPath $latestPtr)) { Deny 'no proof receipt found for this project' }

    $run = (Get-Content -Raw -LiteralPath $latestPtr) -replace '\s+', ''
    if ([string]::IsNullOrEmpty($run)) { Deny 'proof pointer is empty/unreadable' }
    if (-not (Test-ValidName $run)) { Deny 'proof pointer has an unsafe run id' }

    $ledger = Join-Path (Join-Path $proofDir $run) 'ledger.jsonl'
    if (-not (Test-Path -LiteralPath $ledger)) { Deny "proof pointer found (run=$run) but ledger is missing" }

    $allLines = @(Get-Content -LiteralPath $ledger)
    $lines = @($allLines | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) { Deny 'proof ledger is empty - no checks were captured' }
    $lastLine = [string]$lines[$lines.Count - 1]

    $exitCode = Receipt-ExitCode $lastLine
    $sha = Receipt-Sha $lastLine
    $recEpoch = Receipt-Epoch $lastLine

    if ([string]::IsNullOrEmpty($exitCode)) { Deny 'most recent receipt is unparseable (no exit_code)' }
    if ([string]::IsNullOrEmpty($sha)) { Deny 'most recent receipt is unparseable (no sha256)' }
    if ([string]::IsNullOrEmpty($recEpoch)) { Deny 'most recent receipt is unparseable (no epoch)' }

    # Only v2+ capture writes a `disposition`, always "reexecuted"; the CLAIM/VERDICT
    # dispositions are "asserted"/"unparsed". A receipt is proof unless it carries a
    # disposition that is not "reexecuted". Keyed on the disposition field itself (not
    # a parsed schema_version, which [int] could overflow). v0/v1 (no disposition) are
    # unaffected.
    $recDisp = Rec-Field $lastLine '"disposition":"([a-z]+)"'
    if ($recDisp -and $recDisp -ne 'reexecuted') {
        Deny "most recent receipt is a claim/verdict record (disposition=$recDisp) - an asserted claim cannot satisfy the gate"
    }

    if ($exitCode -ne '0') { Deny "your most recent check FAILED (exit=$exitCode) - fix it, don't ship it" }

    $ttl = 3600
    if ($env:AGENT_DONE_TTL) {
        $parsedTtl = 0
        if (-not [int64]::TryParse($env:AGENT_DONE_TTL, [ref]$parsedTtl)) {
            Deny 'AGENT_DONE_TTL is not an integer'
        }
        $ttl = $parsedTtl
    }
    $now = Get-UnixEpoch
    $epochValue = 0
    if (-not [int64]::TryParse($recEpoch, [ref]$epochValue)) {
        Deny 'most recent receipt is unparseable (bad epoch)'
    }
    if (($now - $epochValue) -gt $ttl) {
        Deny "latest proof is older than ${ttl}s (stale) - run your check again"
    }

    # --- required-checks policy: the Stop gate must be as strict as `assert` ---
    # If a policy file exists, EVERY required label must have a fresh passing
    # receipt. Delegate to done-gate.ps1 assert (single source of truth); FAIL
    # CLOSED if a policy is present but cannot be evaluated.
    $root = Get-Root
    $policyFile = ''
    if ($env:AGENT_DONE_POLICY) {
        $policyFile = $env:AGENT_DONE_POLICY
    } elseif ($root -and (Test-Path -LiteralPath (Join-Path $root 'agent-done.json'))) {
        $policyFile = (Join-Path $root 'agent-done.json')
    }
    if ($policyFile -and (Test-Path -LiteralPath $policyFile)) {
        $gate = Join-Path $script:SCRIPT_DIR 'done-gate.ps1'
        if (-not (Test-Path -LiteralPath $gate)) {
            Deny "policy $policyFile present but done-gate.ps1 is not next to stop-gate.ps1 - cannot verify required checks"
        }
        $psExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $prevDir = $env:AGENT_DONE_DIR; $prevTtl = $env:AGENT_DONE_TTL
        $env:AGENT_DONE_DIR = $proofDir; $env:AGENT_DONE_TTL = [string]$ttl
        # The delegated assert writes progress to stderr; under Windows PowerShell
        # 5.1 with EAP=Stop that stderr would raise a NativeCommandError (a false
        # "block"), so drop to Continue for the native call and rely on
        # $LASTEXITCODE for the real verdict.
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $psExe -NoProfile -ExecutionPolicy Bypass -File $gate assert --policy $policyFile > $null 2>&1
            $assertRc = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
            # Faithful restore: coercing $null into an env var yields '' rather than
            # a true unset, so remove it when it was previously unset.
            if ($null -eq $prevDir) { Remove-Item Env:AGENT_DONE_DIR -ErrorAction SilentlyContinue } else { $env:AGENT_DONE_DIR = $prevDir }
            if ($null -eq $prevTtl) { Remove-Item Env:AGENT_DONE_TTL -ErrorAction SilentlyContinue } else { $env:AGENT_DONE_TTL = $prevTtl }
        }
        if ($assertRc -ne 0) {
            Deny "required checks in $(Split-Path -Leaf $policyFile) are not all fresh & passing - run every required check, then finish"
        }
    }

    # --- state binding: a passing receipt captured against different code -------
    # Advisory by default; set AGENT_DONE_BIND_STATE=1 to make drift a hard block.
    # Uses the receipt's RECORDED commit/dirty (not a fresh status) so a proof
    # captured against a dirty tree is not re-flagged; only a new commit or edits
    # after a CLEAN capture count. In hard mode a receipt with no commit binding
    # is itself drift.
    $bindState = ($env:AGENT_DONE_BIND_STATE -eq '1')
    $recCommit = Rec-Field $lastLine '"commit":"([0-9a-f]*)"'
    $recDirty = Rec-Field $lastLine '"dirty":(true|false)'
    if ($root) {
        # Native `git` under WinPS 5.1 + EAP=Stop can throw on any stderr; drop to
        # Continue and rely on $LASTEXITCODE, same as the policy delegation above.
        $prevEapD = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $headCommit = ''
        try {
            $headCommit = (& git -C $root rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $headCommit) { $headCommit = ([string]$headCommit).Trim() } else { $headCommit = '' }
        } catch { $headCommit = '' }
        $drift = ''
        if ($headCommit) {
            if ([string]::IsNullOrEmpty($recCommit)) {
                if ($bindState) { $drift = 'receipt has no commit binding (captured before state binding or outside git)' }
            } elseif ($recCommit -ne $headCommit) {
                $drift = "proof captured at $($recCommit.Substring(0, [Math]::Min(7, $recCommit.Length))) but HEAD is now $($headCommit.Substring(0, [Math]::Min(7, $headCommit.Length)))"
            } elseif ($recDirty -eq 'false') {
                $porcelain = ''
                try { $porcelain = (& git -C $root status --porcelain 2>$null) } catch { $porcelain = '' }
                if ($porcelain) { $drift = 'working tree changed since the (clean) proof was captured' }
            }
        }
        $ErrorActionPreference = $prevEapD
        if ($drift) {
            if ($bindState) {
                Deny "$drift (AGENT_DONE_BIND_STATE=1) - re-run your check against the current code"
            } else {
                Write-Stderr "stop-gate: WARNING - $drift - proof may not reflect the current code"
            }
        }
    }

    $count = $allLines.Count
    $token = $run + ':' + $count
    $consumedFile = Join-Path $script:GATE_DIR 'consumed'
    $consumed = ''
    if (Test-Path -LiteralPath $consumedFile) {
        $consumed = (Get-Content -Raw -LiteralPath $consumedFile) -replace '\s+', ''
    }
    if ($token -eq $consumed) {
        Deny 'no NEW passing check since your last completion - re-verify this change'
    }

    try {
        New-Item -ItemType Directory -Force -Path $script:GATE_DIR | Out-Null
        $tmp = $consumedFile + '.' + $PID + '.tmp'
        Write-TextFile $tmp ($token + [Environment]::NewLine)
        Move-Item -Force -LiteralPath $tmp -Destination $consumedFile
    } catch {
        Deny "could not record proof consumption (cannot write $script:GATE_DIR) - refusing to allow"
    }

    Allow "verified by a fresh passing receipt (sha256=$sha)"
} catch {
    try {
        Deny ('unexpected error: ' + $_.Exception.Message)
    } catch {
        # Deny must never leak a non-blocking exit code; fail closed as a last resort.
        try { [Console]::Error.WriteLine('stop-gate: BLOCKED - fatal error in gate') } catch {}
        exit 2
    }
}
