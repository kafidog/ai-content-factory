# subagent-audit.ps1 — audit a subagent's summary before the parent trusts it.
#
# Native PowerShell port of subagent-audit.sh. A SubagentStop-event hook: when a
# subagent finishes, it runs `done-gate.ps1 audit` over the subagent's transcript
# and BLOCKS (exit 2) if the subagent's CLAIMS are not backed by the receipt
# ledger (UNBACKED / MISREPORTED / INTEGRITY_MISMATCH).
#
# Trust model — deliberately FAIL-OPEN (unlike stop-gate.ps1): a subagent hook
# must never wedge a session on an ambiguous payload. If we cannot read the
# payload/transcript, or there is no ledger to audit against, we ALLOW (exit 0).
# We only BLOCK on a clean audit that returns a real finding. Loop-guarded via
# stop_hook_active.
#
# Exits: 0 = allow (disabled, ambiguous, no ledger, or all claims backed).
#        2 = block (a subagent claim is unbacked / misreported / integrity-mismatch).

$ErrorActionPreference = 'Stop'

# --- escape hatch -------------------------------------------------------------
if ($env:AGENT_DONE_OFF -eq '1') { exit 0 }

# --- read the payload (empty stdin => nothing to audit, allow) ----------------
$payload = ''
try { $payload = [Console]::In.ReadToEnd() } catch { $payload = '' }
if ([string]::IsNullOrWhiteSpace($payload)) { exit 0 }

$flat = ($payload -replace '[\r\n]', ' ')

function Get-JsonBool {
    param([string]$Key)
    return [regex]::IsMatch($flat, '"' + [regex]::Escape($Key) + '"\s*:\s*true')
}
function Get-JsonStr {
    param([string]$Key)
    $m = [regex]::Match($flat, '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# --- loop guard ---------------------------------------------------------------
if (Get-JsonBool 'stop_hook_active') { exit 0 }

# --- locate the transcript (fail OPEN if absent) ------------------------------
$transcript = Get-JsonStr 'transcript_path'
if ([string]::IsNullOrEmpty($transcript)) { exit 0 }
if (-not (Test-Path -LiteralPath $transcript)) { exit 0 }

# --- locate the engine (fail OPEN if absent) ----------------------------------
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$gate = Join-Path $here 'done-gate.ps1'
if (-not (Test-Path -LiteralPath $gate)) { exit 0 }

# proof dir: prefer CLAUDE_PROJECT_DIR, else the git root, else the script dir.
if ($env:CLAUDE_PROJECT_DIR) {
    $root = $env:CLAUDE_PROJECT_DIR
} else {
    $root = ''
    try { $r = (& git rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -eq 0 -and $r) { $root = ([string]$r).Trim() } } catch {}
    if ([string]::IsNullOrEmpty($root)) { $root = $here }
}
$proofDir = if ($env:AGENT_DONE_DIR) { $env:AGENT_DONE_DIR } else { Join-Path $root '.agent-proof' }

# --- run the audit as a CHILD process (done-gate.ps1 calls exit) --------------
# audit exit codes: 0 = all backed; 1 = a real finding; 2 = usage/no-ledger. Block
# ONLY on 1; fail OPEN on 0 and 2.
$exe = $null
try { $exe = (Get-Process -Id $PID).Path } catch {}
if ([string]::IsNullOrEmpty($exe)) {
    $exe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe
$psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $gate + '" audit --transcript "' + $transcript + '"'
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.EnvironmentVariables['AGENT_DONE_DIR'] = $proofDir

$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
[void]$p.Start()
$out = $p.StandardOutput.ReadToEnd()
$err = $p.StandardError.ReadToEnd()
$p.WaitForExit()
$rc = $p.ExitCode

if ($rc -eq 1) {
    [Console]::Error.WriteLine('subagent-audit: BLOCKED - this subagent made claims not backed by the receipt ledger.')
    foreach ($line in (($out + "`n" + $err) -split "`n")) {
        if ($line -match 'UNBACKED|MISREPORTED|INTEGRITY_MISMATCH') { [Console]::Error.WriteLine($line.TrimEnd()) }
    }
    [Console]::Error.WriteLine('subagent-audit: capture the checks (done-gate.ps1 capture --label ... -- <cmd>) or correct the summary.')
    [Console]::Error.WriteLine('subagent-audit: (escape hatch: $env:AGENT_DONE_OFF=1)')
    exit 2
}

# rc 0 (all backed) or rc 2 (no ledger / usage — ambiguous) => allow.
exit 0
