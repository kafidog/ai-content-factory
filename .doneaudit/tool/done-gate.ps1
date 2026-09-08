# done-gate.ps1 - proof receipts for AI coding agents.
#
# Native PowerShell port of done-gate.sh. Supports Windows PowerShell 5.1 and
# PowerShell 7+ with built-ins only.

$script:GATE_VERSION = '0.13.1'
$ErrorActionPreference = 'Stop'

function Write-Stderr {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Die {
    param([string]$Message)
    Write-Stderr "done-gate: $Message"
    exit 2
}

function Usage {
    @'
done-gate.ps1 - proof receipts for AI coding agents.

Subcommands:
  capture --label L [--run R] [--json] -- CMD [ARGS...]
  assert  [--label L ...] [--run R] [--ttl S] [--allow-command-regex RE] [--policy FILE] [--no-policy] [--json]
  verify  --label L [--run R] [--json] --sha HEX
  show    [--run R] [--json]
  -h | --help | help
'@
}

function Get-Root {
    $pwdPath = (Get-Location).ProviderPath
    try {
        $root = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $root) {
            return ([string]$root).Trim()
        }
    } catch {
    }
    return $pwdPath
}

# Git state at capture time, so a receipt is bound to the source it verified.
# Empty commit/tree outside a git repo; dirty is the JSON literal true/false.
function Get-GitCommit {
    try { $v = (& git rev-parse HEAD 2>$null); if ($LASTEXITCODE -eq 0 -and $v) { return ([string]$v).Trim() } } catch {}
    return ''
}
function Get-GitTree {
    try { $v = (& git rev-parse 'HEAD^{tree}' 2>$null); if ($LASTEXITCODE -eq 0 -and $v) { return ([string]$v).Trim() } } catch {}
    return ''
}
function Get-GitDirty {
    try { $v = (& git status --porcelain 2>$null); if ($LASTEXITCODE -eq 0 -and $v) { return 'true' } } catch {}
    return 'false'
}
function Get-GitRepo {
    try {
        $inside = (& git rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -eq 0 -and ([string]$inside).Trim() -eq 'true') {
            $v = (& git config --get remote.origin.url 2>$null)
            # Do NOT .Trim() the value — bash does not trim it either; both engines
            # let Json-Escape flatten any embedded control/whitespace so the two
            # ledgers stay byte-identical.
            if ($LASTEXITCODE -eq 0 -and $v) { return [string]$v }
        }
    } catch {}
    return ''
}
function Get-GitSubject {
    try { $v = (& git log -1 --format=%s 2>$null); if ($LASTEXITCODE -eq 0 -and $v) { return [string]$v } } catch {}
    return ''
}
# Canonical host OS identity, matching done-gate.sh's vocabulary. Windows
# PowerShell 5.1 does not define $IsLinux/$IsMacOS (Windows-only), so the
# Test-Path guards keep this correct on 5.1 and accurate on PowerShell 7+.
function Get-HostOs {
    if ((Test-Path variable:IsLinux) -and $IsLinux) { return 'linux' }
    if ((Test-Path variable:IsMacOS) -and $IsMacOS) { return 'darwin' }
    return 'windows'
}

function Test-ValidName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name.Contains('..')) { return $false }
    return ($Name -match '^[A-Za-z0-9._-]+$')
}

function Json-Escape {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    # Match the Bash ledger contract: escape slash/quote, then flatten EVERY C0
    # control character (U+0000–U+001F: newline, CR, tab, form-feed, …) to a
    # space. Raw control bytes are invalid inside a JSON string, so this keeps a
    # hand-built JSONL line parseable regardless of commit-subject/URL content.
    $Value = $Value -replace '\\', '\\'
    $Value = $Value -replace '"', '\"'
    $Value = $Value -replace '[\x00-\x1F]', ' '
    return $Value
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

function Append-TextLine {
    param(
        [string]$Path,
        [string]$Value
    )
    [System.IO.File]::AppendAllText($Path, $Value + [Environment]::NewLine, (Get-Utf8NoBom))
}

function Get-UtcStamp {
    return ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture))
}

function Get-RunStamp {
    return ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture))
}

function Get-UnixEpoch {
    param([DateTime]$UtcNow)
    $origin = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [int64][Math]::Floor(($UtcNow.ToUniversalTime() - $origin).TotalSeconds)
}

function Get-Sha256OfFile {
    param([string]$Path)
    return ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant())
}

function Get-RelativeLogPath {
    param(
        [string]$Root,
        [string]$LogPath
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $logFull = [IO.Path]::GetFullPath($LogPath)
    $relative = $logFull
    $prefix1 = $rootFull + [IO.Path]::DirectorySeparatorChar
    $prefix2 = $rootFull + [IO.Path]::AltDirectorySeparatorChar
    if ($logFull.StartsWith($prefix1, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $logFull.Substring($prefix1.Length)
    } elseif ($logFull.StartsWith($prefix2, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $logFull.Substring($prefix2.Length)
    }
    return ($relative -replace '\\', '/')
}

function Resolve-PolicyPath {
    param(
        [AllowNull()][string]$Explicit,
        [string]$Root
    )
    if (-not [string]::IsNullOrEmpty($Explicit)) { return $Explicit }
    if ($env:AGENT_DONE_POLICY) { return $env:AGENT_DONE_POLICY }
    $def = Join-Path $Root 'agent-done.json'
    if (Test-Path -LiteralPath $def) { return $def }
    return ''
}

# Emit one PSCustomObject per required entry with Label and Regex properties.
function Get-PolicyEntries {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    $raw = [System.IO.File]::ReadAllText($File, (Get-Utf8NoBom))
    # Flatten newlines as per spec
    $flat = $raw -replace "`r`n|`r|`n", ' '
    $entries = New-Object System.Collections.ArrayList
    $objMatches = [regex]::Matches($flat, '\{[^{}]*\}')
    foreach ($m in $objMatches) {
        $obj = $m.Value
        $labelM = [regex]::Match($obj, '"label"\s*:\s*"([^"]*)"')
        if (-not $labelM.Success) { continue }
        $lbl = $labelM.Groups[1].Value
        $rxM = [regex]::Match($obj, '"command_regex"\s*:\s*"([^"]*)"')
        $rx = if ($rxM.Success) { $rxM.Groups[1].Value } else { '' }
        [void]$entries.Add([pscustomobject]@{ Label = $lbl; Regex = $rx })
    }
    return @($entries)
}

# Top-level "ttl" integer from the policy file, or empty string.
function Get-PolicyTtl {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    $raw = [System.IO.File]::ReadAllText($File, (Get-Utf8NoBom))
    $flat = $raw -replace "`r`n|`r|`n", ' '
    $m = [regex]::Match($flat, '"ttl"\s*:\s*([0-9]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Label strength taxonomy
function Test-LabelWeak {
    param([string]$Label)
    return ($Label -in @('lint','format','fmt','style','manual','docs'))
}

# Most recent receipt for a label across ALL run dirs (highest epoch), or ''.
function Latest-ForLabelGlobal {
    param(
        [string]$ProofDir,
        [string]$Label
    )
    $needle = '"label":"' + (Json-Escape $Label) + '"'
    $bestEp = [int64]-1
    $best = ''
    foreach ($ledgerPath in (Get-ChildItem -Path $ProofDir -Recurse -Filter 'ledger.jsonl' -ErrorAction SilentlyContinue)) {
        $lines = @(Get-Content -LiteralPath $ledgerPath.FullName | Where-Object { $_.Contains($needle) })
        if ($lines.Count -eq 0) { continue }
        $line = [string]$lines[$lines.Count - 1]
        $epStr = (Rec-Field $line '"epoch":([0-9]+)')
        $ep = if ($epStr -match '^[0-9]+$') { [int64]$epStr } else { [int64]0 }
        if ($ep -gt $bestEp) { $bestEp = $ep; $best = $line }
    }
    return $best
}

function Resolve-RunForRead {
    param(
        [AllowNull()][string]$Run,
        [string]$ProofDir
    )
    if (-not [string]::IsNullOrEmpty($Run)) { return $Run }
    $latest = Join-Path $ProofDir 'latest'
    if (Test-Path -LiteralPath $latest) {
        return ((Get-Content -Raw -LiteralPath $latest) -replace "[`r`n]+$", '')
    }
    return ''
}

function Latest-ForLabel {
    param(
        [string]$Ledger,
        [string]$Label
    )
    if (-not (Test-Path -LiteralPath $Ledger)) { return '' }
    $needle = '"label":"' + (Json-Escape $Label) + '"'
    $matches = @(Get-Content -LiteralPath $Ledger | Where-Object { $_.Contains($needle) })
    if ($matches.Count -eq 0) { return '' }
    return [string]$matches[$matches.Count - 1]
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

function Receipt-Command {
    param([string]$Line)
    return (Rec-Field $Line '"command":"(.*)","exit_code":')
}

function Receipt-Label {
    param([string]$Line)
    return (Rec-Field $Line '"label":"([^"]*)"')
}

function Receipt-Commit {
    param([string]$Line)
    return (Rec-Field $Line '"commit":"([0-9a-f]*)"')
}

function Receipt-Dirty {
    param([string]$Line)
    return (Rec-Field $Line '"dirty":(true|false)')
}

function Receipt-Disposition {
    param([string]$Line)
    return (Rec-Field $Line '"disposition":"([a-z]+)"')
}

# An EXECUTION receipt is the only thing that can satisfy a gate. Only v2+ capture
# writes a `disposition`, always "reexecuted"; the CLAIM/VERDICT dispositions are
# "asserted"/"unparsed". A line is proof unless it carries a disposition that is
# not "reexecuted". Keyed on the disposition field itself (not a parsed
# schema_version, which [int] could overflow). v0/v1 (no disposition) pass as
# before. Mirrors done-gate.sh.
function Is-ExecutionReceipt {
    param([string]$Line)
    $disp = Receipt-Disposition $Line
    return ([string]::IsNullOrEmpty($disp) -or $disp -eq 'reexecuted')
}

# Reason a receipt no longer matches the working tree, else ''. Uses the receipt's
# RECORDED commit/dirty (not a fresh status) so a proof captured against a dirty
# tree is not re-flagged; only a new commit or edits after a CLEAN capture count.
# $Bind: in hard mode, a receipt with no commit binding is itself drift.
function Get-StateDriftReason {
    param([string]$Line, [bool]$Bind = $false)
    $rc = Receipt-Commit $Line
    $rdirty = Receipt-Dirty $Line
    $head = Get-GitCommit
    if ([string]::IsNullOrEmpty($head)) { return '' }
    if ([string]::IsNullOrEmpty($rc)) {
        if ($Bind) { return 'receipt has no commit binding (captured before state binding or outside git)' }
        return ''
    }
    if ($rc -ne $head) {
        return ('proof captured at {0} but HEAD is now {1}' -f `
            $rc.Substring(0, [Math]::Min(7, $rc.Length)), $head.Substring(0, [Math]::Min(7, $head.Length)))
    }
    if ($rdirty -eq 'false' -and (Get-GitDirty) -eq 'true') {
        return 'working tree changed since the (clean) proof was captured'
    }
    return ''
}

function Command-Text {
    param([string[]]$Command)
    return ($Command -join ' ')
}

function Capture-Command {
    param(
        [string[]]$Command,
        [string]$LogPath
    )
    $cmd = $Command[0]
    $cmdArgs = @()
    if ($Command.Count -gt 1) {
        $cmdArgs = @($Command[1..($Command.Count - 1)])
    }

    $writer = New-Object System.IO.StreamWriter($LogPath, $false, (Get-Utf8NoBom))
    try {
        # Run the native command directly so PowerShell preserves $LASTEXITCODE.
        # The pipeline tees combined stdout/stderr to the console and UTF-8 log.
        & $cmd @cmdArgs 2>&1 | ForEach-Object {
            $line = [string]$_
            [Console]::Out.WriteLine($line)
            $writer.WriteLine($line)
        }
        $rc = $LASTEXITCODE
        if ($null -eq $rc) {
            if ($?) { $rc = 0 } else { $rc = 1 }
        }
        return [int]$rc
    } finally {
        $writer.Close()
    }
}

function Cmd-Capture {
    param([string[]]$Argv)
    $label = ''
    $run = ''
    $json = $false
    $cmd = @()
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            '--label' {
                if ($i + 1 -ge $Argv.Count) { Die 'capture: --label requires a value' }
                $label = $Argv[$i + 1]; $i += 2
            }
            '--run' {
                if ($i + 1 -ge $Argv.Count) { Die 'capture: --run requires a value' }
                $run = $Argv[$i + 1]; $i += 2
            }
            '--json' {
                $json = $true; $i += 1
            }
            '--' {
                if ($i + 1 -lt $Argv.Count) {
                    $cmd = @($Argv[($i + 1)..($Argv.Count - 1)])
                } else {
                    $cmd = @()
                }
                $i = $Argv.Count
            }
            default {
                Die "capture: unexpected arg '$($Argv[$i])' (did you forget '--' before the command?)"
            }
        }
    }
    if ([string]::IsNullOrEmpty($label)) { Die 'capture: --label is required' }
    if ($cmd.Count -lt 1 -or [string]::IsNullOrEmpty($cmd[0])) { Die "capture: a command after '--' is required" }
    if (-not (Test-ValidName $label)) { Die "capture: --label must match [A-Za-z0-9._-] and contain no '..'" }

    if ([string]::IsNullOrEmpty($run)) {
        if ($env:AGENT_DONE_SESSION) { $run = $env:AGENT_DONE_SESSION } else { $run = Get-RunStamp }
    }
    if (-not (Test-ValidName $run)) { Die "capture: run id must match [A-Za-z0-9._-] and contain no '..'" }

    $dir = Join-Path $script:PROOF_DIR $run
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $log = Join-Path $dir ($label + '.log')

    $rc = Capture-Command -Command $cmd -LogPath $log
    $sha = Get-Sha256OfFile $log
    $now = [DateTime]::UtcNow
    $at = $now.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    $epoch = Get-UnixEpoch $now
    $logRel = Get-RelativeLogPath $script:ROOT $log

    $gitCommit = Get-GitCommit
    $gitTree = Get-GitTree
    $gitDirty = Get-GitDirty
    $gitRepo = Get-GitRepo
    $gitSubject = Get-GitSubject
    $producer = 'done-gate.ps1@' + $script:GATE_VERSION
    $verifier = if ($env:AGENT_DONE_VERIFIER) { $env:AGENT_DONE_VERIFIER } else { '' }
    $hostOs = Get-HostOs
    $disposition = 'reexecuted'
    # Provenance: was this captured by a CI runner, and against which ref? Mirrors
    # done-gate.sh so the receipt JSON stays byte-identical across engines.
    $ci = if ($env:GITHUB_ACTIONS -or $env:CI) { 'true' } else { 'false' }
    $ref = if ($env:GITHUB_REF) { $env:GITHUB_REF } else { '' }
    $receipt = ('{{"label":"{0}","command":"{1}","exit_code":{2},"sha256":"{3}","log":"{4}","at":"{5}","epoch":{6},"session":"{7}","commit":"{8}","tree":"{9}","dirty":{10},"schema_version":2,"ci":{11},"ref":"{12}","repo":"{13}","subject":"{14}","producer":"{15}","verifier":"{16}","host_os":"{17}","disposition":"{18}"}}' -f `
        (Json-Escape $label), (Json-Escape (Command-Text $cmd)), $rc, $sha, `
        (Json-Escape $logRel), $at, $epoch, (Json-Escape $env:AGENT_DONE_SESSION), `
        (Json-Escape $gitCommit), (Json-Escape $gitTree), $gitDirty, `
        $ci, (Json-Escape $ref), (Json-Escape $gitRepo), (Json-Escape $gitSubject), `
        (Json-Escape $producer), (Json-Escape $verifier), (Json-Escape $hostOs), `
        (Json-Escape $disposition))
    Append-TextLine (Join-Path $dir 'ledger.jsonl') $receipt

    $tmp = Join-Path $script:PROOF_DIR ('latest.' + $PID + '.tmp')
    Write-TextFile $tmp ($run + [Environment]::NewLine)
    Move-Item -Force -LiteralPath $tmp -Destination (Join-Path $script:PROOF_DIR 'latest')

    if ($json) { Write-Output $receipt }
    Write-Stderr "done-gate: captured label=$label run=$run exit=$rc sha256=$sha"
    exit $rc
}

function Cmd-Assert {
    param([string[]]$Argv)
    $run = ''
    $ttl = ''
    $regex = ''
    $json = $false
    $policyFlag = ''
    $noPolicy = $false
    $labels = New-Object System.Collections.ArrayList
    $labelRegexes = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            '--label' {
                if ($i + 1 -ge $Argv.Count) { Die 'assert: --label requires a value' }
                [void]$labels.Add($Argv[$i + 1]); $i += 2
            }
            '--run' {
                if ($i + 1 -ge $Argv.Count) { Die 'assert: --run requires a value' }
                $run = $Argv[$i + 1]; $i += 2
            }
            '--ttl' {
                if ($i + 1 -ge $Argv.Count) { Die 'assert: --ttl requires a value' }
                $ttl = $Argv[$i + 1]; $i += 2
            }
            '--allow-command-regex' {
                if ($i + 1 -ge $Argv.Count) { Die 'assert: --allow-command-regex requires a value' }
                $regex = $Argv[$i + 1]; $i += 2
            }
            '--policy' {
                if ($i + 1 -ge $Argv.Count) { Die 'assert: --policy requires a value' }
                $policyFlag = $Argv[$i + 1]; $i += 2
            }
            '--no-policy' {
                $noPolicy = $true; $i += 1
            }
            '--json' {
                $json = $true; $i += 1
            }
            default {
                Die "assert: unexpected arg '$($Argv[$i])'"
            }
        }
    }

    if ([string]::IsNullOrEmpty($regex) -and $env:AGENT_DONE_ALLOWED_COMMANDS) {
        $regex = $env:AGENT_DONE_ALLOWED_COMMANDS
    }

    # Resolution order: explicit CLI --label (legacy) > policy file > latest receipt.
    $policyUsed = ''
    $policyMode = $false

    if ($labels.Count -gt 0) {
        # Legacy CLI-label path: per-label regex = global --allow-command-regex
        foreach ($_ in $labels) { [void]$labelRegexes.Add($regex) }
    } elseif (-not $noPolicy) {
        $policyPath = Resolve-PolicyPath $policyFlag $script:ROOT
        if (-not [string]::IsNullOrEmpty($policyPath) -and (Test-Path -LiteralPath $policyPath)) {
            # Compute relative path for policyUsed (mirror bash: strip ROOT/ prefix)
            $rootFull = [IO.Path]::GetFullPath($script:ROOT).TrimEnd('\','/')
            $polFull  = [IO.Path]::GetFullPath($policyPath)
            $prefix1  = $rootFull + [IO.Path]::DirectorySeparatorChar
            $prefix2  = $rootFull + [IO.Path]::AltDirectorySeparatorChar
            if ($polFull.StartsWith($prefix1, [StringComparison]::OrdinalIgnoreCase)) {
                $policyUsed = ($polFull.Substring($prefix1.Length)) -replace '\\','/'
            } elseif ($polFull.StartsWith($prefix2, [StringComparison]::OrdinalIgnoreCase)) {
                $policyUsed = ($polFull.Substring($prefix2.Length)) -replace '\\','/'
            } else {
                $policyUsed = $policyPath -replace '\\','/'
            }

            $entries = @(Get-PolicyEntries $policyPath)
            foreach ($entry in $entries) {
                if ([string]::IsNullOrEmpty($entry.Label)) { continue }
                [void]$labels.Add($entry.Label)
                $entryRx = if (-not [string]::IsNullOrEmpty($entry.Regex)) { $entry.Regex } else { $regex }
                [void]$labelRegexes.Add($entryRx)
            }
            # Policy present but no parseable "required" entries - FAIL CLOSED
            # instead of silently degrading to latest-receipt (a policy that says
            # "do more" must never quietly do less).
            if ($labels.Count -eq 0) {
                if ($json) { Write-Output ('{{"ok":false,"reason":"policy present but no parseable required entries","policy":"{0}","checks":[]}}' -f (Json-Escape $policyUsed)) }
                Write-Stderr ('done-gate: assert FAIL - policy {0} present but no parseable "required" entries (check for nested braces / quoting)' -f $policyUsed)
                exit 1
            }
            $policyMode = $true
            if ([string]::IsNullOrEmpty($ttl)) {
                $pttl = Get-PolicyTtl $policyPath
                if (-not [string]::IsNullOrEmpty($pttl)) { $ttl = $pttl }
            }
        }
    }

    if ([string]::IsNullOrEmpty($ttl)) {
        if ($env:AGENT_DONE_TTL) { $ttl = $env:AGENT_DONE_TTL } else { $ttl = '3600' }
    }
    # Validate as a non-negative integer (mirror bash) so identical input yields
    # identical exit/JSON across engines.
    if ($ttl -notmatch '^[0-9]+$') { Die 'assert: --ttl must be a non-negative integer' }
    $ttlInt = [int64]$ttl

    # Run-scoped modes need a resolved run + ledger. Policy mode searches all runs.
    $ledger = ''
    $runLabel = $run

    if ($policyMode) {
        $runLabel = '*'
        $anyLedger = @(Get-ChildItem -Path $script:PROOF_DIR -Recurse -Filter 'ledger.jsonl' -ErrorAction SilentlyContinue)
        if ($anyLedger.Count -eq 0) {
            if ($json) { Write-Output ('{{"ok":false,"reason":"no proof receipts found","policy":"{0}","checks":[]}}' -f (Json-Escape $policyUsed)) }
            Write-Stderr 'done-gate: assert FAIL - no proof receipts found (capture something first)'
            exit 1
        }
    } else {
        $run = Resolve-RunForRead $run $script:PROOF_DIR
        if ([string]::IsNullOrEmpty($run)) {
            if ($json) { Write-Output ('{{"ok":false,"reason":"no proof run found","policy":"{0}","checks":[]}}' -f (Json-Escape $policyUsed)) }
            Write-Stderr 'done-gate: assert FAIL - no proof run found (capture something first)'
            exit 1
        }
        if (-not (Test-ValidName $run)) { Die 'assert: invalid run id' }
        $ledger = Join-Path (Join-Path $script:PROOF_DIR $run) 'ledger.jsonl'
        $runLabel = $run
        if (-not (Test-Path -LiteralPath $ledger)) {
            if ($json) { Write-Output ('{{"ok":false,"reason":"ledger missing","run":"{0}","policy":"{1}","checks":[]}}' -f (Json-Escape $run), (Json-Escape $policyUsed)) }
            Write-Stderr "done-gate: assert FAIL - no ledger for run=$run"
            exit 1
        }

        # With no explicit/policy labels, assert against the most recent receipt.
        if ($labels.Count -eq 0) {
            $lines = @(Get-Content -LiteralPath $ledger | Where-Object { $_ -ne '' })
            if ($lines.Count -eq 0) {
                if ($json) { Write-Output ('{{"ok":false,"run":"{0}","ttl":{1},"policy":"{2}","checks":[]}}' -f (Json-Escape $run), $ttlInt, (Json-Escape $policyUsed)) }
                Write-Stderr 'done-gate: assert FAIL - empty ledger'
                exit 1
            }
            $lastLabel = Receipt-Label ([string]$lines[$lines.Count - 1])
            [void]$labels.Add($lastLabel)
            [void]$labelRegexes.Add($regex)
        }
    }

    $nowEpoch = Get-UnixEpoch ([DateTime]::UtcNow)
    $bindState = ($env:AGENT_DONE_BIND_STATE -eq '1')
    $overall = 0
    $checks = New-Object System.Collections.ArrayList
    $anyPass = $false
    $weakOnly = $true
    $warnLabel = ''
    $driftWarn = ''

    for ($idx = 0; $idx -lt $labels.Count; $idx++) {
        $label = [string]$labels[$idx]
        $lrx = if ($idx -lt $labelRegexes.Count) { [string]$labelRegexes[$idx] } else { '' }

        if ($policyMode) {
            $line = Latest-ForLabelGlobal $script:PROOF_DIR $label
        } else {
            $line = Latest-ForLabel $ledger $label
        }

        $found = -not [string]::IsNullOrEmpty($line)
        $exitCode = ''
        $epochStr = ''
        $sha = ''
        $cmd = ''
        $fresh = $false
        $commandAllowed = $true
        $isExec = $true
        $ok = $false

        if ($found) {
            $exitCode = Receipt-ExitCode $line
            $epochStr = Receipt-Epoch $line
            $sha = Receipt-Sha $line
            $cmd = Receipt-Command $line
            # A committed claim/verdict record (disposition!=reexecuted) is not proof.
            $isExec = Is-ExecutionReceipt $line

            if ($ttlInt -le 0) {
                $fresh = $true
            } elseif ($epochStr -match '^[0-9]+$' -and (($nowEpoch - [int64]$epochStr) -le $ttlInt)) {
                $fresh = $true
            }

            if (-not [string]::IsNullOrEmpty($lrx)) {
                # An invalid regex must fail closed (not throw), mirroring bash's
                # `grep -Eq ... 2>/dev/null` which treats a bad pattern as no-match.
                try { $commandAllowed = ($cmd -match $lrx) } catch { $commandAllowed = $false }
            }

            if ($exitCode -eq '0' -and $fresh -and $commandAllowed -and $isExec) { $ok = $true }
        }

        # State binding: a passing receipt captured against different code is stale.
        $drift = ''
        if ($ok) {
            $drift = Get-StateDriftReason $line $bindState
            if (-not [string]::IsNullOrEmpty($drift)) {
                if ([string]::IsNullOrEmpty($driftWarn)) { $driftWarn = $drift }
                if ($bindState) { $ok = $false }
            }
        }

        if (-not $ok) { $overall = 1 }

        # Advisory wrong-check bookkeeping (never affects exit code)
        if ($ok) {
            $anyPass = $true
            if (Test-LabelWeak $label) { $warnLabel = $label } else { $weakOnly = $false }
        }

        if ($json) {
            $exitJson = 'null'
            if ($exitCode -match '^[0-9]+$') { $exitJson = $exitCode }
            $checkJson = ('{{"label":"{0}","found":{1},"exit_code":{2},"fresh":{3},"command_allowed":{4},"sha256":"{5}","drift":"{6}","ok":{7}}}' -f `
                (Json-Escape $label), $found.ToString().ToLowerInvariant(), $exitJson, `
                $fresh.ToString().ToLowerInvariant(), $commandAllowed.ToString().ToLowerInvariant(), `
                (Json-Escape $sha), (Json-Escape $drift), $ok.ToString().ToLowerInvariant())
            [void]$checks.Add($checkJson)
        } else {
            if ($ok) {
                Write-Stderr "done-gate: assert OK   label=$label exit=$exitCode fresh=$($fresh.ToString().ToLowerInvariant())"
            } else {
                $foundText = if ($found) { 'yes' } else { 'no' }
                $ecText = if ($exitCode) { $exitCode } else { '?' }
                Write-Stderr "done-gate: assert FAIL label=$label found=$foundText exit=$ecText fresh=$($fresh.ToString().ToLowerInvariant()) command_allowed=$($commandAllowed.ToString().ToLowerInvariant())"
                if ($found -and -not $isExec) {
                    Write-Stderr "done-gate: assert FAIL label=$label - receipt is a claim/verdict record (disposition!=reexecuted), not a re-executed check"
                }
            }
        }
    }

    if ($json) {
        $okText = if ($overall -eq 0) { 'true' } else { 'false' }
        Write-Output ('{{"ok":{0},"run":"{1}","ttl":{2},"policy":"{3}","state_drift":"{4}","checks":[{5}]}}' -f `
            $okText, (Json-Escape $runLabel), $ttlInt, (Json-Escape $policyUsed), (Json-Escape $driftWarn), ($checks -join ','))
    } else {
        if (-not [string]::IsNullOrEmpty($driftWarn)) {
            if ($bindState) {
                Write-Stderr "done-gate: assert FAIL - $driftWarn (AGENT_DONE_BIND_STATE=1)"
            } else {
                Write-Stderr "done-gate: WARNING - $driftWarn - re-run your check"
            }
        }
        if ($anyPass -and $weakOnly) {
            Write-Stderr "done-gate: WARNING - latest proof is $warnLabel-only - this may not verify the requested behavior"
        }
    }
    exit $overall
}

function Cmd-Verify {
    param([string[]]$Argv)
    $label = ''
    $run = ''
    $sha = ''
    $json = $false
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            '--label' {
                if ($i + 1 -ge $Argv.Count) { Die 'verify: --label requires a value' }
                $label = $Argv[$i + 1]; $i += 2
            }
            '--run' {
                if ($i + 1 -ge $Argv.Count) { Die 'verify: --run requires a value' }
                $run = $Argv[$i + 1]; $i += 2
            }
            '--sha' {
                if ($i + 1 -ge $Argv.Count) { Die 'verify: --sha requires a value' }
                $sha = $Argv[$i + 1]; $i += 2
            }
            '--json' {
                $json = $true; $i += 1
            }
            default {
                Die "verify: unexpected arg '$($Argv[$i])'"
            }
        }
    }
    if ([string]::IsNullOrEmpty($label)) { Die 'verify: --label is required' }
    if ([string]::IsNullOrEmpty($sha)) { Die 'verify: --sha is required' }
    if (-not (Test-ValidName $label)) { Die "verify: --label must match [A-Za-z0-9._-] and contain no '..'" }

    $run = Resolve-RunForRead $run $script:PROOF_DIR
    if ([string]::IsNullOrEmpty($run)) { Die 'verify: no run found (run a capture first or pass --run)' }
    if (-not (Test-ValidName $run)) { Die 'verify: invalid run id' }
    $ledger = Join-Path (Join-Path $script:PROOF_DIR $run) 'ledger.jsonl'
    if (-not (Test-Path -LiteralPath $ledger)) { Die "verify: no ledger at $ledger" }

    $line = Latest-ForLabel $ledger $label
    # A claim/verdict record (disposition!=reexecuted) is not execution evidence,
    # so its recorded hash must never verify as a re-run output.
    if ($line -and -not (Is-ExecutionReceipt $line)) { $line = '' }
    $got = ''
    if ($line) { $got = Receipt-Sha $line }
    $expected = $sha.ToLowerInvariant()
    $ok = (-not [string]::IsNullOrEmpty($got)) -and ($got -eq $expected)

    if ($json) {
        Write-Output ('{{"ok":{0},"label":"{1}","run":"{2}","recorded":"{3}","expected":"{4}"}}' -f `
            $ok.ToString().ToLowerInvariant(), (Json-Escape $label), (Json-Escape $run), (Json-Escape $got), (Json-Escape $expected))
    }
    if ($ok) {
        Write-Stderr "done-gate: verify OK label=$label run=$run sha256=$got"
        exit 0
    }
    if ([string]::IsNullOrEmpty($got)) {
        Write-Stderr "done-gate: verify FAIL - no record for label=$label in run=$run"
    } else {
        Write-Stderr "done-gate: verify MISMATCH label=$label run=$run recorded=$got expected=$expected"
    }
    exit 1
}

function Cmd-Show {
    param([string[]]$Argv)
    $run = ''
    $json = $false
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            '--run' {
                if ($i + 1 -ge $Argv.Count) { Die 'show: --run requires a value' }
                $run = $Argv[$i + 1]; $i += 2
            }
            '--json' {
                $json = $true; $i += 1
            }
            default {
                Die "show: unexpected arg '$($Argv[$i])'"
            }
        }
    }
    $run = Resolve-RunForRead $run $script:PROOF_DIR
    if ([string]::IsNullOrEmpty($run)) { Die 'show: no run found' }
    if (-not (Test-ValidName $run)) { Die 'show: invalid run id' }
    $ledger = Join-Path (Join-Path $script:PROOF_DIR $run) 'ledger.jsonl'
    if (-not (Test-Path -LiteralPath $ledger)) { Die "show: no ledger at $ledger" }

    if ($json) {
        $lines = @(Get-Content -LiteralPath $ledger | Where-Object { $_ -ne '' })
        Write-Output ('{{"run":"{0}","receipts":[{1}]}}' -f (Json-Escape $run), ($lines -join ','))
    } else {
        Write-Output ("# proof ledger {0} run={1}" -f ([char]0x2014), $run)
        Get-Content -LiteralPath $ledger
    }
}

# --- audit ----------------------------------------------------------------
#
# Two claim sources, tried in order (the CLI tags each so a human can weight it):
#   1. Structured markers the agent is instructed to emit (the contract):
#        <agent-done:claim label="test" exit="0" sha256="9f2c..." />
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
#   UNPARSED           claim-shaped text with no bindable label - reported, never
#                      counted as backed.
#
# Exit non-zero if any claim is UNBACKED, MISREPORTED, or INTEGRITY_MISMATCH.
# Mirrors done-gate.sh's cmd_audit/marker_attr/audit_labels/audit_receipt/audit_verdict.

# Conservative claim-shaped-line matcher for the heuristic fallback. Mirrors
# done-gate.sh's AUDIT_CLAIM_RE (POSIX [[:space:]] -> \s). Matched with -cmatch
# (case-sensitive), same as bash's `grep -qE` with no -i flag.
$script:AUDIT_CLAIM_RE = '[Tt]ests?\s+(pass|passed|passing)|[Ll]int\s+(clean|passes|passed)|[Bb]uild\s+(succeed|succeeds|succeeded|passes|passed)|all\s+(tests\s+)?green|[Vv]erified|ran\s+successfully|exit\s+(code\s+)?0'

function Get-MarkerAttr {
    param([string]$Marker, [string]$AttrName)
    $m = [regex]::Match($Marker, [regex]::Escape($AttrName) + '="([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Distinct labels present in a ledger, sorted like bash's `sort -u` (ordinal).
function Get-AuditLabels {
    param([string]$Ledger)
    if (-not (Test-Path -LiteralPath $Ledger)) { return @() }
    $labels = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $Ledger)) {
        foreach ($m in [regex]::Matches($line, '"label":"([^"]*)"')) {
            $labels.Add($m.Groups[1].Value)
        }
    }
    $arr = @($labels | Select-Object -Unique)
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return $arr
}

# Latest EXECUTION receipt for a label, or '' (a claim/verdict record cannot back
# a claim).
function Get-AuditReceipt {
    param([string]$Ledger, [string]$Label)
    $line = Latest-ForLabel $Ledger $Label
    if ([string]::IsNullOrEmpty($line)) { return '' }
    if (-not (Is-ExecutionReceipt $line)) { return '' }
    return $line
}

function Get-AuditVerdict {
    param([string]$Ledger, [string]$Label, [string]$CExit, [string]$CSha)
    if ([string]::IsNullOrEmpty($Label)) { return 'UNPARSED' }
    $r = Get-AuditReceipt $Ledger $Label
    if ([string]::IsNullOrEmpty($r)) { return 'UNBACKED' }
    $recE = Receipt-ExitCode $r
    $recS = Receipt-Sha $r
    # Does the claim assert success? Normalize first (mirrors done-gate.sh) so a
    # zero-looking-but-not-"0" value ("00", " 0") or garbage ("fail") can't skip
    # the MISREPORTED check and launder a failing check into BACKED. Only a clean
    # non-zero integer claims a non-zero code.
    $eff = ($CExit -replace '\s', '')
    $claimsSuccess = $true
    if ($eff -match '^[0-9]+$') { $claimsSuccess = -not ($eff -match '[^0]') }
    if ($claimsSuccess -and -not [string]::IsNullOrEmpty($recE) -and $recE -ne '0') { return 'MISREPORTED' }
    if (-not [string]::IsNullOrEmpty($CSha) -and -not [string]::IsNullOrEmpty($recS) -and $CSha -ne $recS) { return 'INTEGRITY_MISMATCH' }
    return 'BACKED'
}

function Cmd-Audit {
    param([string[]]$Argv)
    $transcript = ''
    $run = ''
    $json = $false
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            '--transcript' {
                if ($i + 1 -ge $Argv.Count) { Die 'audit: --transcript requires a value' }
                $transcript = $Argv[$i + 1]; $i += 2
            }
            '--run' {
                if ($i + 1 -ge $Argv.Count) { Die 'audit: --run requires a value' }
                $run = $Argv[$i + 1]; $i += 2
            }
            '--json' {
                $json = $true; $i += 1
            }
            default {
                Die "audit: unexpected arg '$($Argv[$i])'"
            }
        }
    }
    if ([string]::IsNullOrEmpty($transcript)) { Die 'audit: --transcript <file|-> is required' }

    $run = Resolve-RunForRead $run $script:PROOF_DIR
    if ([string]::IsNullOrEmpty($run)) { Die 'audit: no run found (run a capture first or pass --run)' }
    if (-not (Test-ValidName $run)) { Die 'audit: invalid run id' }
    $ledger = Join-Path (Join-Path $script:PROOF_DIR $run) 'ledger.jsonl'
    if (-not (Test-Path -LiteralPath $ledger)) { Die "audit: no ledger at $ledger" }

    if ($transcript -eq '-') {
        $srcText = [Console]::In.ReadToEnd()
    } else {
        if (-not (Test-Path -LiteralPath $transcript)) { Die "audit: transcript not found: $transcript" }
        $srcText = Get-Content -Raw -LiteralPath $transcript
    }
    if ($null -eq $srcText) { $srcText = '' }
    $lines = [regex]::Split($srcText, "\r\n|\r|\n")

    # 1) structured markers (the contract). One normalized claim per marker tag.
    $claims = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($line in $lines) {
        foreach ($mm in [regex]::Matches($line, '<agent-done:claim[^>]*>')) {
            $marker = $mm.Value
            $label = Get-MarkerAttr $marker 'label'
            $cexit = Get-MarkerAttr $marker 'exit'
            $csha = Get-MarkerAttr $marker 'sha256'
            [void]$claims.Add([pscustomobject]@{ Label = $label; Exit = $cexit; Sha = $csha; Source = 'marker' })
        }
    }

    # set of labels already claimed by a marker (so heuristics don't double-count)
    $marked = @($claims | Where-Object { -not [string]::IsNullOrEmpty($_.Label) } | ForEach-Object { $_.Label } | Select-Object -Unique)

    # 2) heuristic fallback: claim-shaped lines with no marker. Bind to the first
    #    known ledger label the line mentions; otherwise record as unparsed. Each
    #    heuristic claim is tagged `inferred` and (per label) recorded at most once.
    $known = Get-AuditLabels $ledger
    $seenInferred = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if (-not ($line -cmatch $script:AUDIT_CLAIM_RE)) { continue }
        if ($line.Contains('<agent-done:claim')) { continue }
        $hit = ''
        foreach ($lbl in $known) {
            if ([string]::IsNullOrEmpty($lbl)) { continue }
            # Bind only on a WHOLE-token match (mirrors done-gate.sh): the label
            # must be delimited by a non-label character (or string end) on both
            # sides, so "test" never binds "greatest"/"latest".
            if ([regex]::IsMatch($line, '(^|[^A-Za-z0-9._-])' + [regex]::Escape($lbl) + '([^A-Za-z0-9._-]|$)')) { $hit = $lbl; break }
        }
        if (-not [string]::IsNullOrEmpty($hit)) {
            if ($marked -contains $hit) { continue }
            if ($seenInferred -contains $hit) { continue }
            [void]$seenInferred.Add($hit)
            [void]$claims.Add([pscustomobject]@{ Label = $hit; Exit = ''; Sha = ''; Source = 'inferred' })
        } else {
            # claim-shaped but not bindable to a label -> UNPARSED
            [void]$claims.Add([pscustomobject]@{ Label = ''; Exit = ''; Sha = ''; Source = 'inferred' })
        }
    }

    # 3) compute verdicts + tallies
    $n = 0; $backed = 0; $unbacked = 0; $misrep = 0; $integ = 0; $unparsed = 0; $nmark = 0; $ninf = 0
    $jsonRows = New-Object System.Collections.Generic.List[string]
    $humanRows = New-Object System.Collections.Generic.List[string]
    foreach ($c in $claims) {
        $n++
        if ($c.Source -eq 'marker') { $nmark++ } else { $ninf++ }
        $v = Get-AuditVerdict $ledger $c.Label $c.Exit $c.Sha
        $r = Get-AuditReceipt $ledger $c.Label
        $rexit = if ($r) { Receipt-ExitCode $r } else { '' }
        $rsha = if ($r) { Receipt-Sha $r } else { '' }
        switch ($v) {
            'BACKED' { $backed++ }
            'UNBACKED' { $unbacked++ }
            'MISREPORTED' { $misrep++ }
            'INTEGRITY_MISMATCH' { $integ++ }
            'UNPARSED' { $unparsed++ }
        }
        if ($json) {
            $recordedExit = if ([string]::IsNullOrEmpty($rexit)) { 'null' } else { $rexit }
            $rowJson = ('{{"label":"{0}","source":"{1}","verdict":"{2}","claimed_exit":"{3}","claimed_sha256":"{4}","recorded_exit":{5},"recorded_sha256":"{6}"}}' -f `
                (Json-Escape $c.Label), $c.Source, $v, (Json-Escape $c.Exit), (Json-Escape $c.Sha), $recordedExit, (Json-Escape $rsha))
            [void]$jsonRows.Add($rowJson)
        } else {
            $labelDisp = if ([string]::IsNullOrEmpty($c.Label)) { '<unparsed>' } else { $c.Label }
            $exitDisp = if ([string]::IsNullOrEmpty($c.Exit)) { '0' } else { $c.Exit }
            $shaDisp = if ([string]::IsNullOrEmpty($c.Sha)) { [string][char]0x2014 } else { $c.Sha.Substring(0, [Math]::Min(12, $c.Sha.Length)) }
            $rexitDisp = if ([string]::IsNullOrEmpty($rexit)) { [string][char]0x2014 } else { $rexit }
            $rshaDisp = if ([string]::IsNullOrEmpty($rsha)) { [string][char]0x2014 } else { $rsha.Substring(0, [Math]::Min(12, $rsha.Length)) }
            $rowLine = ('{0,-18} {1,-8} {2,-18} claimed[exit={3} sha={4}] recorded[exit={5} sha={6}]' -f `
                $labelDisp, $c.Source, $v, $exitDisp, $shaDisp, $rexitDisp, $rshaDisp)
            [void]$humanRows.Add($rowLine)
        }
    }

    $ok = -not ($unbacked -gt 0 -or $misrep -gt 0 -or $integ -gt 0)
    $dash = [string][char]0x2014

    if ($json) {
        $okText = if ($ok) { 'true' } else { 'false' }
        $summaryJson = ('{{"claims":{0},"backed":{1},"unbacked":{2},"misreported":{3},"integrity_mismatch":{4},"unparsed":{5},"marker":{6},"inferred":{7}}}' -f `
            $n, $backed, $unbacked, $misrep, $integ, $unparsed, $nmark, $ninf)
        Write-Output ('{{"run":"{0}","transcript":"{1}","ok":{2},"summary":{3},"claims":[{4}]}}' -f `
            (Json-Escape $run), (Json-Escape $transcript), $okText, $summaryJson, ($jsonRows -join ','))
    } else {
        Write-Output ("# claim audit $dash run=$run  transcript=$transcript")
        if ($n -eq 0) {
            Write-Output "done-gate: audit $dash no claims found (0 markers, no claim-shaped lines)."
        } else {
            foreach ($row in $humanRows) { Write-Output $row }
        }
        Write-Stderr ("Summary: $n claim(s) $dash $backed backed, $unbacked unbacked, $misrep misreported, $integ integrity-mismatch, $unparsed unparsed ($nmark marker, $ninf inferred)")
        Write-Stderr ("Coverage: audited against run=$run. Inferred claims are best-effort; unparsed claims are reported, never counted as backed.")
        if (-not $ok) {
            Write-Stderr ("done-gate: audit FAIL $dash $unbacked unbacked, $misrep misreported, $integ integrity-mismatch")
        } else {
            Write-Stderr ("done-gate: audit OK $dash no unbacked, misreported, or integrity-mismatched claims")
        }
    }

    if ($ok) { exit 0 } else { exit 1 }
}

# --- review-pr: re-execute an AI-authored PR's claimed checks ("PR Receipts") ---
#
# Native port of done-gate.sh's cmd_review_pr. Parse the testable claims out of
# a PR description / commit messages ("tests pass", "lint clean", "build
# succeeds"), auto-resolve the project's REAL commands from its manifests,
# re-execute them, and print a receipt splitting claims into RE-EXECUTED /
# ASSERTED / UNPARSED. It never says "VERIFIED": a green re-run proves the
# command passed here and now, not that the PR is correct.
#
# SECURITY: the re-executed command is chosen ONLY from Resolve-PrCommand's
# fixed per-ecosystem resolution table -- it is NEVER derived from PR text.
# The PR body selects which CATEGORY (test/lint/build) is claimed; it can
# never inject a command.

# claim-shape patterns (matched case-insensitively). These are the bash
# PR_RE_* ERE patterns with POSIX [[:space:]] translated to \s for .NET regex.
$script:PR_RE_TEST = 'tests?\s+(pass|passed|passing|are\s+green|succeed(s|ed)?)|(all\s+)?tests?\s+green|test\s+suite\s+pass'
$script:PR_RE_LINT = 'lint(ing)?\s+(clean|passes|passed|is\s+clean)|no\s+lint\s+(error|warning)'
$script:PR_RE_BUILD = 'builds?\s+(succeed(s|ed)?|passes|passed|works|is\s+green|clean(ly)?|success)|compiles?\s+(clean(ly)?|success)'
# recognized-but-not-re-executable assertions
$script:PR_RE_ASSERTED = 'no\s+breaking\s+changes|backwards?\s+compatible|handles?\s+(all\s+)?edge\s+cases|no\s+regressions?|fully\s+tested'
# vague merge-readiness phrases -> unparsed
$script:PR_RE_UNPARSED = '(ready|good)\s+to\s+(merge|go)|looks\s+good|lgtm|should\s+be\s+(good|fine|ready)'

# First case-insensitive match of $Pattern in $Text, or '' - mirrors bash's
# `grep -ioE "$pattern" "$file" | head -n1`.
function Match-PrClaim {
    param([string]$Text, [string]$Pattern)
    $m = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) { return $m.Value }
    return ''
}

# Resolve category (test|lint|build) -> the project's real command, or ''.
# First matching manifest wins. Only well-known canonical commands, no
# guessing - mirrors bash's pr_resolve exactly, including the textual (not
# JSON-structural) package.json key check.
function Resolve-PrCommand {
    param([string]$Category)
    if (Test-Path -LiteralPath 'package.json' -PathType Leaf) {
        $content = Get-Content -LiteralPath 'package.json' -Raw
        switch ($Category) {
            'test'  { if ($content -match '"test"\s*:')  { return 'npm test' } }
            'lint'  { if ($content -match '"lint"\s*:')  { return 'npm run lint' } }
            'build' { if ($content -match '"build"\s*:') { return 'npm run build' } }
        }
        return ''
    } elseif (Test-Path -LiteralPath 'pyproject.toml' -PathType Leaf) {
        switch ($Category) {
            'test' { return 'pytest' }
            'lint' { return 'ruff check .' }
            # no single canonical Python build command -> asserted
            'build' { return '' }
        }
        return ''
    } elseif (Test-Path -LiteralPath 'go.mod' -PathType Leaf) {
        switch ($Category) {
            'test'  { return 'go test ./...' }
            'lint'  { return 'go vet ./...' }
            'build' { return 'go build ./...' }
        }
        return ''
    }
    return ''
}

# Re-execute $Command (a FIXED internal string - never PR-derived) as a child
# process, combined stdout+stderr redirected straight to $LogPath by cmd.exe
# itself (mirrors bash's `sh -c "$cmd" > "$logf" 2>&1`). Honors
# AGENT_DONE_PR_TIMEOUT (default 300s) on a best-effort basis: PowerShell 5.1
# has no built-in equivalent of coreutils `timeout`, so a timeout is enforced
# via WaitForExit + taskkill/Kill and reports rc=124 (matching GNU timeout's
# convention), same as bash's optional `timeout` wrapper.
function Invoke-ReviewPrCommand {
    param(
        [string]$Command,
        [string]$LogPath
    )
    $timeoutSeconds = 300
    if ($env:AGENT_DONE_PR_TIMEOUT) {
        $parsed = 0
        if ([int]::TryParse($env:AGENT_DONE_PR_TIMEOUT, [ref]$parsed) -and $parsed -gt 0) {
            $timeoutSeconds = $parsed
        }
    }

    # Windows PowerShell 5.1 does not define $IsWindows (it is Windows-only); PS7
    # does. Use cmd.exe on Windows and /bin/sh elsewhere so the same engine runs a
    # PR's real commands under pwsh on Linux/macOS too (mirrors bash's `sh -c`).
    $onWindows = (-not (Test-Path variable:IsWindows)) -or $IsWindows

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($onWindows) {
        $comspec = $env:ComSpec
        if ([string]::IsNullOrEmpty($comspec)) { $comspec = 'cmd.exe' }
        $psi.FileName = $comspec
        # stdin from NUL so a check that reads stdin can't block (mirrors bash).
        $psi.Arguments = '/c ' + $Command + ' > "' + $LogPath + '" 2>&1 < NUL'
    } else {
        $psi.FileName = '/bin/sh'
        [void]$psi.ArgumentList.Add('-c')
        [void]$psi.ArgumentList.Add("$Command > `"$LogPath`" 2>&1 < /dev/null")
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Get-Location).ProviderPath

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $exited = $proc.WaitForExit($timeoutSeconds * 1000)
    if (-not $exited) {
        try { & taskkill /PID $proc.Id /T /F 2>$null | Out-Null } catch {}
        try { $proc.Kill() } catch {}
        # [void]: WaitForExit(int) returns a Boolean; letting it leak would make the
        # function return @($true, 124), so exit_code renders as System.Object[] and
        # the JSON is invalid — exactly on the hang path the timeout guards.
        try { [void]$proc.WaitForExit(5000) } catch {}
        return 124
    }
    return [int]$proc.ExitCode
}

function Cmd-ReviewPr {
    param([string[]]$Argv)
    $body = ''
    $commits = $false
    $base = ''
    $json = $false
    $i = 0
    while ($i -lt $Argv.Count) {
        switch ($Argv[$i]) {
            '--body' {
                if ($i + 1 -ge $Argv.Count) { Die 'review-pr: --body requires a value' }
                $body = $Argv[$i + 1]; $i += 2
            }
            '--commits' { $commits = $true; $i += 1 }
            '--base' {
                if ($i + 1 -ge $Argv.Count) { Die 'review-pr: --base requires a value' }
                $base = $Argv[$i + 1]; $i += 2
            }
            '--json' { $json = $true; $i += 1 }
            default { Die "review-pr: unexpected arg '$($Argv[$i])'" }
        }
    }
    if ([string]::IsNullOrEmpty($body)) { Die 'review-pr: --body <file|-> is required' }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('done-gate-pr-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $overall = 0
    try {
        $claimFile = Join-Path $tmp 'claims.txt'
        if ($body -eq '-') {
            $stdinText = [Console]::In.ReadToEnd()
            Write-TextFile $claimFile $stdinText
        } else {
            if (-not (Test-Path -LiteralPath $body -PathType Leaf)) { Die "review-pr: body not found: $body" }
            Copy-Item -LiteralPath $body -Destination $claimFile -Force
        }

        # optionally fold in commit-message subjects/bodies from base..HEAD
        if ($commits) {
            if ([string]::IsNullOrEmpty($base)) {
                $upstreamRaw = $null
                try {
                    $upstreamRaw = (& git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null)
                    if ($LASTEXITCODE -ne 0) { $upstreamRaw = $null }
                } catch { $upstreamRaw = $null }
                if ($upstreamRaw) { $base = ([string]$upstreamRaw).Trim() } else { $base = 'origin/HEAD' }
            }
            try {
                $logOut = (& git log --format=%B "$base..HEAD" 2>$null)
                if ($LASTEXITCODE -eq 0 -and $logOut) {
                    $logText = (@($logOut) -join [Environment]::NewLine) + [Environment]::NewLine
                    [System.IO.File]::AppendAllText($claimFile, $logText, (Get-Utf8NoBom))
                }
            } catch {}
        }

        $claimText = Get-Content -LiteralPath $claimFile -Raw -ErrorAction SilentlyContinue
        if ($null -eq $claimText) { $claimText = '' }
        # Normalize whitespace to single spaces BEFORE matching (mirrors
        # done-gate.sh): so a word-wrapped claim matches, and so the two engines
        # agree — .NET \s crosses newlines but bash grep is line-oriented.
        $claimText = ($claimText -replace '\s+', ' ')

        $reexecRows = New-Object System.Collections.ArrayList
        $assertedRows = New-Object System.Collections.ArrayList
        $unparsedRows = New-Object System.Collections.ArrayList

        # 1) re-executable categories: claimed -> resolve -> re-execute (or
        #    assert if no command resolves).
        $categories = @(
            @{ Name = 'test'; Pattern = $script:PR_RE_TEST },
            @{ Name = 'lint'; Pattern = $script:PR_RE_LINT },
            @{ Name = 'build'; Pattern = $script:PR_RE_BUILD }
        )
        foreach ($catInfo in $categories) {
            $cat = $catInfo.Name
            $claim = Match-PrClaim $claimText $catInfo.Pattern
            if ([string]::IsNullOrEmpty($claim)) { continue }
            $cmdStr = Resolve-PrCommand $cat
            if ([string]::IsNullOrEmpty($cmdStr)) {
                # claimed, but nothing to re-execute against -> asserted (unverified)
                [void]$assertedRows.Add([pscustomobject]@{
                    Claim  = $claim
                    Reason = "no $cat command resolved from the project's manifests"
                })
                continue
            }
            $logf = Join-Path $tmp ($cat + '.log')
            # NOTE: $cmdStr is a fixed internal string (see Resolve-PrCommand),
            # never PR-derived. A claimed check that FAILS on re-run is a real
            # receipt, not a script error.
            $rc = Invoke-ReviewPrCommand -Command $cmdStr -LogPath $logf
            $sha = ''
            try { $sha = Get-Sha256OfFile $logf } catch { $sha = '' }
            if ($rc -eq 0) { $status = 'pass' } else { $status = 'fail'; $overall = 1 }
            [void]$reexecRows.Add([pscustomobject]@{
                Claim    = $claim
                Command  = $cmdStr
                ExitCode = $rc
                Sha256   = $sha
                Status   = $status
            })
        }

        # 2) recognized-but-not-re-executable assertions.
        $aClaim = Match-PrClaim $claimText $script:PR_RE_ASSERTED
        if (-not [string]::IsNullOrEmpty($aClaim)) {
            [void]$assertedRows.Add([pscustomobject]@{
                Claim  = $aClaim
                Reason = 'no command maps to this claim'
            })
        }

        # 3) vague / unparsed claim-shaped phrases.
        $uClaim = Match-PrClaim $claimText $script:PR_RE_UNPARSED
        if (-not [string]::IsNullOrEmpty($uClaim)) {
            [void]$unparsedRows.Add($uClaim)
        }

        $nReexec = $reexecRows.Count
        $nAsserted = $assertedRows.Count
        $nUnparsed = $unparsedRows.Count

        if ($json) {
            $rowsR = ($reexecRows | ForEach-Object {
                '{{"claim":"{0}","command":"{1}","exit_code":{2},"sha256":"{3}","status":"{4}"}}' -f `
                    (Json-Escape $_.Claim), (Json-Escape $_.Command), $_.ExitCode, (Json-Escape $_.Sha256), $_.Status
            }) -join ','
            $rowsA = ($assertedRows | ForEach-Object {
                '{{"claim":"{0}","reason":"{1}"}}' -f (Json-Escape $_.Claim), (Json-Escape $_.Reason)
            }) -join ','
            $rowsU = ($unparsedRows | ForEach-Object { '"{0}"' -f (Json-Escape $_) }) -join ','

            $okText = if ($overall -eq 0) { 'true' } else { 'false' }
            $receipt = ('{{"ok":{0},"summary":{{"reexecuted":{1},"asserted":{2},"unparsed":{3}}},"reexecuted":[{4}],"asserted":[{5}],"unparsed":[{6}]}}' -f `
                $okText, $nReexec, $nAsserted, $nUnparsed, $rowsR, $rowsA, $rowsU)
            Write-Output $receipt
        } else {
            $dash = [string][char]0x2014
            Write-Output '# PR Receipts'
            Write-Output ''
            Write-Output ("RE-EXECUTED ({0} claim(s) re-run)" -f $nReexec)
            if ($nReexec -eq 0) {
                Write-Output '  (none)'
            } else {
                foreach ($row in $reexecRows) {
                    $mark = if ($row.Status -eq 'pass') { 'PASS' } else { 'FAIL' }
                    $shaShort = $row.Sha256.Substring(0, [Math]::Min(12, $row.Sha256.Length))
                    Write-Output ('  {0,-4} "{1}"  -> {2}  exit={3}  sha256={4}' -f $mark, $row.Claim, $row.Command, $row.ExitCode, $shaShort)
                }
            }
            Write-Output ''
            Write-Output ("ASSERTED ({0} claim(s), no re-executable evidence)" -f $nAsserted)
            if ($nAsserted -eq 0) {
                Write-Output '  (none)'
            } else {
                foreach ($row in $assertedRows) {
                    Write-Output ('  ?    "{0}"  -- {1}' -f $row.Claim, $row.Reason)
                }
            }
            Write-Output ''
            Write-Output ("UNPARSED ({0} claim-like phrase(s), not confidently matched)" -f $nUnparsed)
            if ($nUnparsed -eq 0) {
                Write-Output '  (none)'
            } else {
                foreach ($ph in $unparsedRows) {
                    Write-Output ('  .    "{0}"' -f $ph)
                }
            }
            Write-Stderr ''
            Write-Stderr 'A green re-run proves the command passed here and now, not that the PR is correct.'
            if ($overall -eq 0) {
                Write-Stderr ("done-gate: review-pr OK $dash {0} re-executed claim(s) passed" -f $nReexec)
            } else {
                Write-Stderr "done-gate: review-pr FAIL $dash a re-executed claim did not pass"
            }
        }
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }

    exit $overall
}

$script:ROOT = Get-Root
$script:PROOF_DIR = if ($env:AGENT_DONE_DIR) { $env:AGENT_DONE_DIR } else { Join-Path $script:ROOT '.agent-proof' }

$argv = @($args)
if ($argv.Count -lt 1) {
    Usage
    exit 2
}

$sub = $argv[0]
$rest = @()
if ($argv.Count -gt 1) { $rest = @($argv[1..($argv.Count - 1)]) }

switch ($sub) {
    'capture' { Cmd-Capture $rest }
    'assert' { Cmd-Assert $rest }
    'verify' { Cmd-Verify $rest }
    'show' { Cmd-Show $rest }
    'audit' { Cmd-Audit $rest }
    'review-pr' { Cmd-ReviewPr $rest }
    '-h' { Usage }
    '--help' { Usage }
    'help' { Usage }
    default {
        Usage
        Die "unknown subcommand '$sub' (capture | assert | verify | show | audit | review-pr)"
    }
}
