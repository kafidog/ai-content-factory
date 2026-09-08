#!/usr/bin/env node
// agent-done-or-not - thin npm wrapper. It forwards CLI args to the bundled
// engine, preserves the caller's cwd (so .agent-proof/ lands in their repo),
// and exits with the engine's own exit code. Zero dependencies.
'use strict';

const path = require('path');
const fs = require('fs');
const { spawnSync } = require('child_process');

const pkgRoot = path.join(__dirname, '..');
const bashGate = path.join(pkgRoot, 'done-gate.sh');
const psGate = path.join(pkgRoot, 'done-gate.ps1');
const bashStopGate = path.join(pkgRoot, 'stop-gate.sh');
const psStopGate = path.join(pkgRoot, 'stop-gate.ps1');
const args = process.argv.slice(2);
const proofStart = '<!-- agent-done-or-not:start -->';
const proofEnd = '<!-- agent-done-or-not:end -->';

// Label taxonomy for wrong-check warning (§3)
const WEAK_LABELS = new Set(['lint', 'format', 'fmt', 'style', 'manual', 'docs']);
const STRONG_LABELS = new Set(['test', 'tests', 'e2e', 'build', 'typecheck', 'smoke', 'run',
  'browser', 'curl', 'integration', 'unit', 'check']);

function isWeakLabel(label) {
  return WEAK_LABELS.has(String(label || '').toLowerCase());
}

// Unknown labels are treated as STRONG (don't nag on custom verifying commands)
function isStrongLabel(label) {
  const l = String(label || '').toLowerCase();
  return STRONG_LABELS.has(l) || !WEAK_LABELS.has(l);
}

// Returns { fires: bool, weakLabel: string|null }
function wrongCheckWarning(receipts) {
  const passing = receipts.filter((r) => Number(r.exit_code) === 0);
  if (passing.length === 0) return { fires: false, weakLabel: null };
  const hasStrongPassing = passing.some((r) => isStrongLabel(r.label));
  if (hasStrongPassing) return { fires: false, weakLabel: null };
  // All passing receipts are WEAK — find most recent passing weak label
  const weakLabel = passing[0].label || null;
  return { fires: true, weakLabel };
}

function printHelp() {
  process.stdout.write(`agent-done-or-not

Usage:
  agent-done-or-not init [--dry-run] [--yes] [--claude-hook] [--claude] [--policy] [--force] [--label name --command "cmd"]
  agent-done-or-not report [--format markdown|html|json|pr]
  agent-done-or-not capture --label check -- <command>
  agent-done-or-not assert [--label check] [--ttl seconds]
  agent-done-or-not stop-gate   (run the bundled Stop hook; reads payload on stdin)

Commands other than init/report/stop-gate are forwarded to the bundled proof gate.
`);
}

function run(command, commandArgs) {
  return spawnSync(command, commandArgs, {
    stdio: 'inherit',
    cwd: process.cwd(),
  });
}

// Run a .sh/.ps1 gate pair, exiting with its code. On Windows we try PowerShell
// FIRST: a WSL `bash.exe` on PATH launches fine but chokes on the Windows script
// path, and its non-ENOENT failure would otherwise never fall through to the
// native .ps1 engine (the historical Windows/WSL adoption trap). Elsewhere bash
// leads. finish() only returns false on ENOENT, so a real check failure exits
// with its own code instead of retrying the other shell.
function runPs(script, forwardArgs) {
  for (const shell of ['pwsh', 'powershell']) {
    const result = run(shell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, ...forwardArgs]);
    if (result.error && result.error.code === 'ENOENT') continue;
    return result;
  }
  return { error: { code: 'ENOENT' } };
}

function forwardToGate(bashScript, psScript, forwardArgs) {
  const tryBash = () => run('bash', [bashScript, ...forwardArgs]);
  const tryPs = () => runPs(psScript, forwardArgs);
  // Default: bash-first, except Windows prefers the native PowerShell engine so a
  // WSL bash.exe on PATH (which fails on a Windows script path) can't abort the
  // run before the .ps1 engine is tried. AGENT_DONE_SHELL=bash|pwsh forces the
  // order — e.g. Git-Bash-on-Windows users who want bash-flavored check commands.
  const pref = String(process.env.AGENT_DONE_SHELL || '').toLowerCase();
  let order;
  if (pref === 'bash') order = [tryBash, tryPs];
  else if (pref === 'pwsh' || pref === 'powershell') order = [tryPs, tryBash];
  else order = process.platform === 'win32' ? [tryPs, tryBash] : [tryBash, tryPs];
  for (const attempt of order) {
    // finish() exits with the child's own status on any non-ENOENT outcome and
    // returns false only when the shell was missing (ENOENT) -> try the next one.
    // The trailing exit is a defensive backstop (finish never returns truthy).
    if (finish(attempt()) !== false) process.exit(1);
  }
  process.stderr.write(
    'agent-done-or-not: no supported shell found. Install bash, or on Windows install/use PowerShell.\n'
  );
  process.exit(127);
}

function finish(result) {
  if (result.error) {
    if (result.error.code === 'ENOENT') {
      return false;
    }
    process.stderr.write('agent-done-or-not: ' + result.error.message + '\n');
    process.exit(1);
  }

  if (result.signal) {
    process.exit(1);
  }

  process.exit(result.status === null ? 1 : result.status);
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return null;
  }
}

function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
}

function fileExists(file) {
  try {
    return fs.existsSync(file);
  } catch (_) {
    return false;
  }
}

function chooseNodeRunner(cwd) {
  if (fileExists(path.join(cwd, 'pnpm-lock.yaml'))) return 'pnpm';
  if (fileExists(path.join(cwd, 'yarn.lock'))) return 'yarn';
  return 'npm';
}

function nodeCommand(runner, scriptName) {
  if (runner === 'yarn') return `yarn ${scriptName}`;
  return `${runner} run ${scriptName}`;
}

function detectChecks(cwd) {
  const commandIndex = args.indexOf('--command');
  const labelIndex = args.indexOf('--label');
  if (commandIndex !== -1 && args[commandIndex + 1]) {
    return [{ label: labelIndex !== -1 && args[labelIndex + 1] ? args[labelIndex + 1] : 'check', command: args[commandIndex + 1] }];
  }

  const checks = [];
  const pkg = readJson(path.join(cwd, 'package.json'));
  if (pkg && pkg.scripts && typeof pkg.scripts === 'object') {
    const runner = chooseNodeRunner(cwd);
    for (const label of ['test', 'build', 'lint']) {
      if (typeof pkg.scripts[label] === 'string') {
        checks.push({ label, command: nodeCommand(runner, label) });
      }
    }
  }

  if (fileExists(path.join(cwd, 'pyproject.toml')) ||
      fileExists(path.join(cwd, 'pytest.ini')) ||
      fileExists(path.join(cwd, 'tox.ini')) ||
      fileExists(path.join(cwd, 'setup.cfg'))) {
    checks.push({ label: 'test', command: 'python -m pytest' });
  }
  if (fileExists(path.join(cwd, 'go.mod'))) checks.push({ label: 'test', command: 'go test ./...' });
  if (fileExists(path.join(cwd, 'Cargo.toml'))) checks.push({ label: 'test', command: 'cargo test' });
  if (fileExists(path.join(cwd, 'pom.xml'))) checks.push({ label: 'test', command: 'mvn test' });
  if (fileExists(path.join(cwd, 'build.gradle')) || fileExists(path.join(cwd, 'build.gradle.kts'))) {
    checks.push({ label: 'test', command: fileExists(path.join(cwd, 'gradlew')) ? './gradlew test' : 'gradle test' });
  }

  if (checks.length === 0) {
    checks.push({ label: 'check', command: '<your verifying command>' });
  }
  return checks;
}

function proofBlock(checks) {
  const first = checks[0];
  const lines = [
    proofStart,
    '## Proof Of Done',
    '',
    'Before reporting a task complete, run the verifying command through the proof gate and only claim done after a passing receipt.',
    '',
    '```bash',
    `npx agent-done-or-not capture --label ${first.label} -- ${first.command}`,
    '```',
    '',
    'Suggested checks:'
  ];
  for (const check of checks) {
    lines.push(`- \`${check.label}\`: \`${check.command}\``);
  }
  lines.push('', 'If a check fails, fix the issue and capture again. Do not report success from a failing or stale receipt.', proofEnd, '');
  return lines.join('\n');
}

// Never overwrite an existing backup: a same-second re-run would otherwise
// clobber the only copy of the user's original content.
function writeBackup(file, content) {
  const stamp = new Date().toISOString().replace(/[-:TZ.]/g, '').slice(0, 14);
  const base = `${file}.agent-done-or-not.bak-${stamp}`;
  let backup = base;
  let n = 1;
  while (fileExists(backup)) backup = `${base}-${n++}`;
  fs.writeFileSync(backup, content);
}

function patchInstructionFile(file, block, dryRun, touched) {
  let current = '';
  if (fileExists(file)) current = fs.readFileSync(file, 'utf8');
  let next;
  if (current.includes(proofStart) && current.includes(proofEnd)) {
    const before = current.slice(0, current.indexOf(proofStart));
    const after = current.slice(current.indexOf(proofEnd) + proofEnd.length);
    // Preserve a newline between the managed block and following content so
    // repeated `init` runs cannot glue the end marker to the next line.
    const tail = after.replace(/^\n*/, after.trim() ? '\n' : '');
    next = before + block.trimEnd() + tail;
  } else {
    next = current.trimEnd() + (current.trim() ? '\n\n' : '') + block;
  }

  if (next !== current) {
    touched.push(path.relative(process.cwd(), file) || path.basename(file));
    if (!dryRun) {
      if (current) writeBackup(file, current);
      fs.writeFileSync(file, next);
    }
  }
}

// Does this file look like a previous copy of one of OUR gate scripts? Used so an
// upgrade+re-init refreshes stale vendored scripts (else a repo initialized on an
// older version keeps weaker, e.g. policy-unaware, enforcement) without ever
// clobbering an unrelated user file of the same name.
function looksLikeOurGate(file) {
  try {
    const head = fs.readFileSync(file, 'utf8').slice(0, 800);
    return head.includes('proof receipts for AI coding agents')
        || head.includes('block "done" until it');
  } catch (_) { return false; }
}

function sameContent(a, b) {
  try { return fs.readFileSync(a).equals(fs.readFileSync(b)); } catch (_) { return false; }
}

// Install the gate scripts into the target repo so a hook that references
// `$CLAUDE_PROJECT_DIR/stop-gate.sh` resolves, and so stop-gate finds done-gate
// beside it for policy enforcement. Copies when missing; REFRESHES an older copy
// of our own script (so upgrades take effect); preserves a foreign file of the
// same name unless --force. A self-init in this repo is a harmless no-op.
function copyGateScripts(cwd, dryRun, touched, force) {
  for (const name of ['done-gate.sh', 'done-gate.ps1', 'stop-gate.sh', 'stop-gate.ps1']) {
    const src = path.join(pkgRoot, name);
    const dest = path.join(cwd, name);
    if (!fileExists(src)) continue;
    if (fileExists(dest)) {
      if (sameContent(src, dest)) continue;             // already up to date
      if (!force && !looksLikeOurGate(dest)) continue;  // preserve an unrelated file
    }
    touched.push(path.relative(cwd, dest) || name);
    if (!dryRun) {
      fs.copyFileSync(src, dest);
      if (name.endsWith('.sh')) {
        try { fs.chmodSync(dest, 0o755); } catch (_) {}
      }
    }
  }
}

function writeClaudeHook(cwd, dryRun, touched) {
  const settingsFile = path.join(cwd, '.claude', 'settings.json');
  const settings = readJson(settingsFile) || {};
  const command = process.platform === 'win32'
    ? 'powershell -NoProfile -File "$env:CLAUDE_PROJECT_DIR\\stop-gate.ps1"'
    : 'bash "$CLAUDE_PROJECT_DIR/stop-gate.sh"';
  settings.hooks = settings.hooks || {};
  settings.hooks.Stop = settings.hooks.Stop || [];
  const exists = JSON.stringify(settings.hooks.Stop).includes('stop-gate.');
  if (!exists) {
    settings.hooks.Stop.push({ hooks: [{ type: 'command', command }] });
    touched.push(path.relative(cwd, settingsFile));
    if (!dryRun) writeJson(settingsFile, settings);
  }
}

// Escape a literal string for use as a regex pattern (no literal double-quote allowed)
function regexEscape(str) {
  return str.replace(/[.\\*+?()\[\]{}^$|]/g, '\\$&');
}

function writePolicyFile(cwd, checks, dryRun, touched) {
  const policyPath = path.join(cwd, 'agent-done.json');
  if (fileExists(policyPath)) {
    process.stdout.write('(agent-done.json exists, skipped)\n');
    return null;
  }
  const required = checks
    .filter((c) => c.command && c.command !== '<your verifying command>')
    .map((c) => ({
      label: c.label,
      command_regex: regexEscape(c.command),
    }));
  if (required.length === 0) {
    required.push({ label: checks[0].label });
  }
  const policy = {
    $schema: 'https://github.com/mohamedzhioua/agent-done-or-not/policy.schema.json',
    required,
    ttl: 3600,
  };
  const relPath = path.relative(cwd, policyPath) || 'agent-done.json';
  touched.push(relPath);
  if (!dryRun) {
    fs.writeFileSync(policyPath, JSON.stringify(policy, null, 2) + '\n');
  }
  return relPath;
}

function runInit() {
  const dryRun = args.includes('--dry-run');
  // Accept both --claude-hook and --claude as aliases
  const claudeHook = args.includes('--claude-hook') || args.includes('--claude');
  const force = args.includes('--force');
  const writePolicy = args.includes('--policy');
  const cwd = process.cwd();
  const checks = detectChecks(cwd);
  const targets = ['AGENTS.md', 'CLAUDE.md', '.cursorrules', '.windsurfrules', '.clinerules']
    .map((name) => path.join(cwd, name))
    .filter((file) => fileExists(file));
  if (targets.length === 0) targets.push(path.join(cwd, 'AGENTS.md'));

  const touched = [];
  const block = proofBlock(checks);
  for (const target of targets) patchInstructionFile(target, block, dryRun, touched);
  if (claudeHook) {
    copyGateScripts(cwd, dryRun, touched, force);
    writeClaudeHook(cwd, dryRun, touched);
  }

  let policyRelPath = null;
  if (writePolicy) {
    policyRelPath = writePolicyFile(cwd, checks, dryRun, touched);
  }

  const first = checks[0];
  const touchedDisplay = touched.length ? touched.join(', ') : '(nothing)';
  process.stdout.write(`${dryRun ? 'Would update' : 'Updated'}: ${touchedDisplay}\n`);
  process.stdout.write(`Next capture command:\n  npx agent-done-or-not capture --label ${first.label} -- ${first.command}\n`);
  if (!claudeHook) process.stdout.write('Add --claude-hook to generate a Claude Code Stop hook config.\n');
}

// Receipt fields (notably `command` and `label`) are agent-controlled, so they
// must be neutralized before rendering into a markdown table or HTML.
function mdCell(value) {
  // Receipt `command`/`label` are agent-controlled. Besides table-breaking
  // characters, neutralize `<`/`>` so a crafted command can't inject the
  // `<!-- agent-done-or-not:proof -->` sticky-comment marker into report output.
  return String(value == null ? '' : value)
    .replace(/\\/g, '\\\\')
    .replace(/\|/g, '\\|')
    .replace(/`/g, '\\`')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/\r?\n/g, ' ');
}

function htmlCell(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function gitValue(argsForGit) {
  const result = spawnSync('git', argsForGit, { cwd: process.cwd(), encoding: 'utf8' });
  if (result.status !== 0) return null;
  return String(result.stdout || '').trim();
}

// Heuristic: does this path look like a test/spec file? Used only for an advisory
// (never changes pass/fail) that flags a "done" claim sitting on top of
// uncommitted test edits — the most-cited agent check-gaming pattern.
function isTestPath(p) {
  return /(^|\/)(tests?|specs?|__tests__)\//i.test(p)
    || /\.(test|spec)\.[A-Za-z0-9]+$/i.test(p)
    || /(^|\/)test_[^/]*\.py$/i.test(p)
    || /_test\.(go|py|rb|rs|js|ts)$/i.test(p);
}

function changedTestFiles() {
  const out = new Set();
  for (const gitArgs of [['diff', '--name-only'], ['diff', '--cached', '--name-only']]) {
    const v = gitValue(gitArgs);
    if (!v) continue;
    for (const line of v.split(/\r?\n/)) {
      if (line && isTestPath(line)) out.add(line);
    }
  }
  return Array.from(out);
}

// Reason the newest receipt no longer matches the working tree, else ''. Mirrors
// the gate logic: a new commit, or edits after a CLEAN capture. Uses the
// receipt's recorded commit/dirty; silent on pre-binding receipts (advisory).
function driftReason(receipts) {
  const latest = receipts[0];
  if (!latest || !latest.commit) return '';
  const fullHead = gitValue(['rev-parse', 'HEAD']);
  if (!fullHead) return '';
  if (latest.commit !== fullHead) {
    return `proof captured at ${String(latest.commit).slice(0, 7)} but HEAD is now ${fullHead.slice(0, 7)}`;
  }
  if (latest.dirty === false) {
    const dirty = gitValue(['status', '--porcelain']);
    if (dirty) return 'working tree changed since the (clean) proof was captured';
  }
  return '';
}

// Relative age helper: "just now" / "Nm ago" / "Nh ago" / "Nd ago"
function agoText(epoch) {
  if (!epoch) return 'unknown';
  const secs = Math.floor(Date.now() / 1000) - Number(epoch);
  if (secs < 60) return 'just now';
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

function listLedgerFiles(dir) {
  const out = [];
  if (!fileExists(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const ledger = path.join(dir, entry.name, 'ledger.jsonl');
    if (fileExists(ledger)) out.push(ledger);
  }
  return out;
}

function readReceipts() {
  const proofDir = process.env.AGENT_DONE_DIR || path.join(process.cwd(), '.agent-proof');
  const receipts = [];
  for (const ledger of listLedgerFiles(proofDir)) {
    const lines = fs.readFileSync(ledger, 'utf8').split(/\r?\n/).filter(Boolean);
    for (const line of lines) {
      try {
        const receipt = JSON.parse(line);
        receipt.ledger = path.relative(process.cwd(), ledger);
        receipts.push(receipt);
      } catch (_) {}
    }
  }
  receipts.sort((a, b) => Number(b.epoch || 0) - Number(a.epoch || 0));
  return receipts;
}

function reportState(receipts) {
  if (process.env.AGENT_DONE_OFF === '1') return 'bypassed';
  if (receipts.length === 0) return 'missing';
  if (Number(receipts[0].exit_code) !== 0) return 'failed';
  const ttl = Number(process.env.AGENT_DONE_TTL || 3600);
  const epoch = Number(receipts[0].epoch || 0);
  if (ttl > 0 && epoch > 0 && Math.floor(Date.now() / 1000) - epoch > ttl) return 'stale';
  return 'local-only';
}

// State → glyph + WORD mapping for the card
const STATE_DISPLAY = {
  'local-only': { glyph: '✅', word: 'PASS' },
  'failed':     { glyph: '❌', word: 'FAILED' },
  'stale':      { glyph: '⚠️',  word: 'STALE' },
  'missing':    { glyph: '⛔', word: 'NO PROOF' },
  'bypassed':   { glyph: '🔓', word: 'BYPASSED' },
};

function runReport() {
  let format = 'markdown';
  const formatIndex = args.indexOf('--format');
  if (formatIndex !== -1 && args[formatIndex + 1]) format = args[formatIndex + 1];
  const receipts = readReceipts();
  const state = reportState(receipts);
  const commit = gitValue(['rev-parse', '--short', 'HEAD']);
  const dirty = gitValue(['status', '--porcelain']);
  const drift = driftReason(receipts);
  const testsTouched = changedTestFiles();
  const payload = {
    state,
    commit,
    dirty: dirty === null ? null : dirty.length > 0,
    state_drift: drift || null,
    tests_touched: testsTouched,
    bypass: process.env.AGENT_DONE_OFF === '1',
    receipts: receipts.slice(0, 20),
  };

  if (format === 'json') {
    process.stdout.write(JSON.stringify(payload, null, 2) + '\n');
    return;
  }

  // Build the existing table (shared by markdown + pr)
  const top = receipts.slice(0, 10);
  const rows = top.map((r) =>
    `| ${mdCell(r.label)} | ${mdCell(r.exit_code)} | ${mdCell(r.sha256)} | ${mdCell(r.command)} | ${mdCell(r.ledger)} |`
  );
  const existingTable = [
    '| Label | Exit | SHA-256 | Command | Ledger |',
    '|---|---:|---|---|---|',
    ...(rows.length ? rows : ['| - | - | - | no receipts found | - |']),
  ].join('\n');

  const dirtyLabel = dirty === null ? 'unknown' : (dirty.length > 0 ? 'dirty' : 'clean');
  const commitStr = commit ? `${commit} (${dirtyLabel})` : `unknown (${dirtyLabel})`;

  if (format === 'html') {
    const cells = top.map((r) =>
      `    <tr><td>${htmlCell(r.label)}</td><td>${htmlCell(r.exit_code)}</td><td><code>${htmlCell(r.sha256)}</code></td><td><code>${htmlCell(r.command)}</code></td><td>${htmlCell(r.ledger)}</td></tr>`
    );
    const html = [
      '<!doctype html><meta charset="utf-8"><title>Proof Report</title>',
      '<h1>Proof Report</h1>',
      `<p>State: <strong>${htmlCell(state)}</strong></p>`,
      `<p>Commit: ${htmlCell(commit || 'unknown')}</p>`,
      `<p>Dirty tree: ${dirty === null ? 'unknown' : dirty.length > 0 ? 'yes' : 'no'}</p>`,
      `<p>Bypass: ${payload.bypass ? 'yes' : 'no'}</p>`,
      '<table>',
      '  <thead><tr><th>Label</th><th>Exit</th><th>SHA-256</th><th>Command</th><th>Ledger</th></tr></thead>',
      '  <tbody>',
      ...(cells.length ? cells : ['    <tr><td colspan="5">no receipts found</td></tr>']),
      '  </tbody>',
      '</table>',
      ''
    ].join('\n');
    process.stdout.write(html);
    return;
  }

  if (format === 'pr') {
    const display = STATE_DISPLAY[state] || { glyph: '⛔', word: 'NO PROOF' };
    const isPassing = state === 'local-only';
    const headingGlyph = isPassing ? '✅' : (state === 'missing' ? '⛔' : '❌');
    const warning = wrongCheckWarning(receipts);

    // Most-recent receipt info
    const latest = receipts[0];
    const latestStr = latest
      ? `\`${mdCell(latest.command)}\` · exit ${latest.exit_code} · ${agoText(latest.epoch)}`
      : '—';

    const lines = [
      '<!-- agent-done-or-not:proof -->',
      `### ${headingGlyph} Proof of Done`,
      '',
      '| | |',
      '|---|---|',
      `| **Status** | ${display.word} |`,
      `| **Commit** | \`${commit || 'unknown'}\` (${dirtyLabel}) |`,
      `| **Latest** | ${latestStr} |`,
      '',
      '**Checks** (most recent 10)',
    ];

    for (const r of top) {
      const icon = Number(r.exit_code) === 0 ? '✅' : '❌';
      const sha12 = r.sha256 ? r.sha256.slice(0, 12) : '';
      const shaStr = sha12 ? ` — \`sha256:${sha12}…\`` : '';
      lines.push(`- ${icon} \`${mdCell(r.label)}\` — \`${mdCell(r.command)}\` — exit \`${r.exit_code}\` — ${agoText(r.epoch)}${shaStr}`);
    }
    if (top.length === 0) {
      lines.push('- *(no receipts found)*');
    }

    lines.push('');

    if (warning.fires) {
      lines.push(`> ⚠️ latest proof is ${warning.weakLabel}-only — this may not verify the requested behavior`);
      lines.push('');
    }

    if (drift) {
      lines.push(`> ⚠️ ${drift} — this proof may not reflect the current code`);
      lines.push('');
    }

    if (testsTouched.length) {
      lines.push(`> ⚠️ uncommitted changes to test files (${testsTouched.slice(0, 5).map(mdCell).join(', ')}) — confirm the check wasn't weakened`);
      lines.push('');
    }

    if (isPassing) {
      lines.push('> This completion is backed by a fresh passing receipt.');
    } else {
      // Remediation block
      const remLabel = latest ? mdCell(latest.label) : 'test';
      const remCmd = latest ? mdCell(latest.command) : 'npm test';
      // A fenced block nested inside a blockquote does not render as code on
      // GitHub, so keep the fence outside the quote (still within the markers).
      lines.push('> No fresh passing receipt. Run:');
      lines.push('');
      lines.push('```');
      lines.push(`npx agent-done-or-not capture --label ${remLabel} -- ${remCmd}`);
      lines.push('```');
    }

    lines.push('<!-- agent-done-or-not:proof -->');
    lines.push('');

    process.stdout.write(lines.join('\n'));
    return;
  }

  if (format !== 'markdown') {
    process.stderr.write('agent-done-or-not: --format must be markdown, html, json, or pr\n');
    process.exit(2);
  }

  // markdown: prepend card above existing table
  const display = STATE_DISPLAY[state] || { glyph: '⛔', word: 'NO PROOF' };
  const latest = receipts[0];
  const warning = wrongCheckWarning(receipts);

  const cardLines = [
    '# Proof of Done',
    '',
    `Status: ${display.glyph} ${display.word}`,
  ];

  if (latest) {
    cardLines.push(`Check: \`${mdCell(latest.command)}\``);
    cardLines.push(`Exit: ${latest.exit_code}`);
    cardLines.push(`Ran: ${agoText(latest.epoch)}`);
    const sha12 = latest.sha256 ? latest.sha256.slice(0, 12) : '';
    cardLines.push(`Output hash: \`${sha12}…\``);
  }
  cardLines.push(`Commit: ${commitStr}`);
  cardLines.push('');

  if (state === 'local-only') {
    cardLines.push('This completion is backed by a fresh passing receipt.');
  }
  if (warning.fires) {
    cardLines.push(`> ⚠️ latest proof is ${warning.weakLabel}-only — this may not verify the requested behavior`);
  }
  if (drift) {
    cardLines.push(`> ⚠️ ${drift} — this proof may not reflect the current code`);
  }
  if (testsTouched.length) {
    cardLines.push(`> ⚠️ uncommitted changes to test files (${testsTouched.slice(0, 5).join(', ')}) — confirm the check wasn't weakened`);
  }

  // Existing table (legacy markdown report)
  const legacyTable = [
    '# Proof Report',
    '',
    `State: **${state}**`,
    `Commit: ${commit || 'unknown'}`,
    `Dirty tree: ${dirty === null ? 'unknown' : dirty.length > 0 ? 'yes' : 'no'}`,
    `Bypass: ${payload.bypass ? 'yes' : 'no'}`,
    '',
    existingTable,
    '',
  ].join('\n');

  const output = cardLines.join('\n') + '\n\n' + legacyTable;
  process.stdout.write(output);
}

if (args.length === 0 || args[0] === '--help' || args[0] === '-h' || args[0] === 'help') {
  printHelp();
  process.exit(0);
}

if (args[0] === 'init') {
  runInit();
  process.exit(0);
}

if (args[0] === 'report') {
  runReport();
  process.exit(0);
}

// `stop-gate` runs the bundled Stop hook, piping the caller's stdin (the hook
// payload) through. Lets a Claude Code hook use `npx agent-done-or-not stop-gate`
// without vendoring scripts, and keeps done-gate next to stop-gate for policy.
if (args[0] === 'stop-gate') {
  forwardToGate(bashStopGate, psStopGate, args.slice(1));
}

forwardToGate(bashGate, psGate, args);
