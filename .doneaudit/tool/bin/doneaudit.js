#!/usr/bin/env node
'use strict';
// DoneAudit scoring and installation. Execution receipts are produced by
// agent-done-or-not (MIT, Copyright (c) 2026 Zhioua Mohamed).
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '..');
const EVIDENCE = '.doneaudit/evidence';
const CONFIG = 'doneaudit.config.json';
const CLAIM = 'doneaudit.claim.json';
const weights = { test: 30, build: 20, required: 25 };
const TOOL_FILES = ['bin/doneaudit.js', 'bin/execute-check.js', 'bin/agent-done-or-not.js', 'done-gate.sh', 'done-gate.ps1', 'stop-gate.sh', 'stop-gate.ps1', 'subagent-audit.sh', 'subagent-audit.ps1', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'package.json'];
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
function read(file) { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); }
function write(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, typeof value === 'string' ? value : JSON.stringify(value, null, 2) + '\n'); }
function git(args) {
  const r = spawnSync('git', args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  if (r.status !== 0) throw new Error('Git repository required: ' + (r.stderr || 'git unavailable').trim());
  return r.stdout;
}
function snapshot() {
  const top = git(['rev-parse', '--show-toplevel']).trim();
  if (fs.realpathSync.native(top).toLowerCase() !== fs.realpathSync.native(process.cwd()).toLowerCase()) throw new Error('Run DoneAudit from the Git repository root.');
  const files = [...new Set(git(['ls-files', '-z', '--cached', '--others', '--exclude-standard']).split('\0').filter(Boolean))].sort();
  const digest = crypto.createHash('sha256');
  for (const file of files) {
    // Runtime evidence is not source, even if accidentally tracked.
    if (file.startsWith(EVIDENCE + '/') || file.startsWith('.agent-proof/')) continue;
    digest.update(file + '\0');
    try {
      const stat = fs.lstatSync(file);
      digest.update(stat.isSymbolicLink() ? 'link:' + fs.readlinkSync(file) : stat.isFile() ? fs.readFileSync(file) : 'directory');
      digest.update(String(stat.mode & 0o111));
    } catch (error) { if (error.code !== 'ENOENT') throw error; digest.update('deleted'); }
    digest.update('\0');
  }
  return { head: git(['rev-parse', 'HEAD']).trim(), digest: digest.digest('hex'), dirty: !!git(['status', '--porcelain']).trim() };
}
function config() {
  const c = read(CONFIG);
  if (c.version !== 1 || !Array.isArray(c.checks) || !c.checks.length) throw new Error('Config needs version: 1 and nonempty checks.');
  if (c.scope !== undefined && !['product', 'governance-only'].includes(c.scope)) throw new Error('Unknown evidence scope.');
  if (c.scope === 'governance-only' && c.checks.some(check => check.group !== 'required')) throw new Error('Governance-only checks must use group required, never product test/build categories.');
  const labels = new Set();
  for (const check of c.checks) {
    if (!check || !/^[a-zA-Z0-9_-]+$/.test(check.label) || labels.has(check.label) || !Object.hasOwn(weights, check.group) || !(check.command === null || (typeof check.command === 'string' && check.command.trim()))) throw new Error('Invalid/duplicate check: ' + JSON.stringify(check));
    labels.add(check.label);
  }
  return c;
}
function same(a, b) { return a && b && a.head === b.head && a.digest === b.digest; }
function claimValid() {
  try { const c = read(CLAIM); const scope = config().scope || 'product'; return c.completed === true && typeof c.summary === 'string' && c.summary.trim().length > 0 && (scope === 'product' ? (!c.scope || c.scope === 'product') : c.scope === scope); } catch { return false; }
}
function init(options = []) {
  if (options.some(option => !['--portable', '--no-workflow'].includes(option))) throw new Error('Unknown init option.');
  snapshot();
  const target = path.resolve('.doneaudit/tool');
  let agents = fs.existsSync('AGENTS.md') ? fs.readFileSync('AGENTS.md', 'utf8') : '';
  const starts = (agents.match(/<!-- doneaudit:start -->/g) || []).length;
  const ends = (agents.match(/<!-- doneaudit:end -->/g) || []).length;
  if (starts !== ends || (starts && !/<!-- doneaudit:start -->[\s\S]*?<!-- doneaudit:end -->/.test(agents))) throw new Error('Malformed DoneAudit markers; preserve and review AGENTS.md.');
  if (/<!-- doneaudit:(start|end) -->/.test(agents.replace(/<!-- doneaudit:start -->(?:(?!<!-- doneaudit:start -->)[\s\S])*?<!-- doneaudit:end -->/g, ''))) throw new Error('Nested or unmatched DoneAudit markers; preserve and review AGENTS.md.');
  const attributes = '.doneaudit/.gitattributes';
  if (fs.existsSync(attributes) && fs.readFileSync(attributes, 'utf8').trim() !== '/tool/** -text') throw new Error('Existing DoneAudit attributes require review; refusing to change byte preservation rules.');
  if (ROOT !== target && fs.existsSync(target)) {
    const marker = path.join(target, 'doneaudit-install.json');
    if (!fs.existsSync(marker) || read(marker).version !== '0.1.0') throw new Error('Existing tool directory is not a DoneAudit v0.1.0 installation.');
    const installed = read(marker);
    for (const file of TOOL_FILES) {
      const dest = path.join(target, file);
      if (!fs.existsSync(dest)) throw new Error('Incomplete existing DoneAudit installation: ' + file);
      const expected = installed.files && installed.files[file];
      if (hash(fs.readFileSync(dest)) !== (expected || hash(fs.readFileSync(path.join(ROOT, file))))) throw new Error('Modified vendored tool; preserve and review: ' + file);
    }
  }
  if (!fs.existsSync(CONFIG)) {
    let scripts = {}; if (!options.includes('--portable')) { try { scripts = read('package.json').scripts || {}; } catch {} }
    write(CONFIG, { version: 1, checks: [
      { label: 'test', group: 'test', command: scripts.test ? 'npm test' : null },
      { label: 'build', group: 'build', command: scripts.build ? 'npm run build' : null },
      { label: 'required', group: 'required', command: scripts.lint ? 'npm run lint' : scripts.check ? 'npm run check' : null }
    ] });
  }
  if (ROOT !== target) {
    const files = {};
    for (const file of TOOL_FILES) {
      write(path.join(target, file), fs.readFileSync(path.join(ROOT, file), 'utf8').replace(/\r\n/g, '\n'));
      files[file] = hash(fs.readFileSync(path.join(target, file)));
    }
    const source = spawnSync('git', ['rev-parse', '--show-toplevel'], { cwd: ROOT, encoding: 'utf8' });
    const revision = source.status === 0 && path.resolve(source.stdout.trim()) === ROOT ? spawnSync('git', ['rev-parse', 'HEAD'], { cwd: ROOT, encoding: 'utf8' }).stdout.trim() : null;
    write(path.join(target, 'doneaudit-install.json'), { version: '0.1.0', files, sourceRevision: revision });
  }
  write(attributes, '/tool/** -text\n');
  const rule = '\n<!-- doneaudit:start -->\n## DoneAudit completion rule\nBefore claiming completion, write doneaudit.claim.json with {"completed":true,"summary":"what you changed"} and the exact config scope when governance-only.\nThen run `node .doneaudit/tool/bin/doneaudit.js run`. This executes configured checks and produces evidence automatically.\nOnly describe the configured scope as verified when it exits 0 and reports VERIFIED. Governance-only evidence is NEVER product acceptance. If it fails, report FAILED or INSUFFICIENT EVIDENCE honestly.\nThe final reviewer still checks Issue acceptance, scope, runtime requirements and current handoff; DoneAudit is not that review.\nDo not weaken tests, edit DoneAudit tooling/configuration, or manufacture receipts to obtain a passing score.\n<!-- doneaudit:end -->\n';
  agents = agents.replace(/\n?<!-- doneaudit:start -->[\s\S]*?<!-- doneaudit:end -->\n?/g, '');
  write('AGENTS.md', agents + rule);
  let ignore = fs.existsSync('.gitignore') ? fs.readFileSync('.gitignore', 'utf8') : '';
  for (const line of ['/.doneaudit/evidence/', '/.agent-proof/']) if (!ignore.split(/\r?\n/).includes(line)) ignore += '\n' + line + '\n';
  write('.gitignore', ignore);
  const workflow = '.github/workflows/doneaudit.yml';
  if (!options.includes('--no-workflow') && !fs.existsSync(workflow)) write(workflow, `name: DoneAudit\non: [push, pull_request, workflow_dispatch]\npermissions:\n  contents: read\njobs:\n  audit:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n        with:\n          fetch-depth: 0\n      - uses: actions/setup-node@v4\n        with:\n          node-version: '22'\n${options.includes('--portable') ? '' : '      - name: Install project dependencies\n        shell: bash\n        run: |\n          if [ -f package-lock.json ]; then npm ci; elif [ -f package.json ]; then npm install; fi\n'}      - name: Verify completion\n        run: node .doneaudit/tool/bin/doneaudit.js run\n      - uses: actions/upload-artifact@v4\n        if: always()\n        with:\n          name: doneaudit-evidence\n          path: .doneaudit/evidence/\n          include-hidden-files: true\n`);
  console.log('DoneAudit installed. Codex completion rules and GitHub workflow are ready.\nReview doneaudit.config.json: replace null commands with your real checks.\nStart Codex normally. Commit the generated files and completion claim for GitHub verification.');
}
function run() {
  const c = config();
  const initial = snapshot();
  const runId = crypto.randomUUID();
  const bundle = { version: 1, runId, at: Date.now(), snapshot: initial, configHash: hash(fs.readFileSync(CONFIG)), checks: [] };
  // Invalidate previous success before starting any command.
  write(EVIDENCE + '/latest.json', bundle);
  for (const check of c.checks) {
    if (!check.command) { bundle.checks.push({ label: check.label, missing: true }); continue; }
    const before = snapshot();
    const dir = path.resolve(EVIDENCE, runId, check.label);
    const commandFile = path.join(dir, 'command.json');
    write(commandFile, { command: check.command });
    const r = spawnSync(process.execPath, [path.join(ROOT, 'bin/agent-done-or-not.js'), 'capture', '--run', 'check', '--label', check.label, '--', process.execPath, path.join(ROOT, 'bin/execute-check.js'), commandFile], {
      env: { ...process.env, AGENT_DONE_DIR: dir, AGENT_DONE_SESSION: runId }, encoding: 'utf8', timeout: 330000, maxBuffer: 16 * 1024 * 1024
    });
    if (r.stdout) process.stdout.write(r.stdout);
    if (r.stderr) process.stderr.write(r.stderr);
    bundle.checks.push({ label: check.label, command: check.command, exit: r.status, error: r.error ? r.error.message : null, before, after: snapshot(), directory: path.relative(process.cwd(), dir) });
  }
  write(EVIDENCE + '/latest.json', bundle);
  return report();
}
function evaluate() {
  const c = config();
  const current = snapshot();
  let b; try { b = read(EVIDENCE + '/latest.json'); } catch { b = null; }
  const fresh = b && b.version === 1 && Number.isFinite(b.at) && Date.now() - b.at >= 0 && Date.now() - b.at <= 3600000 && b.configHash === hash(fs.readFileSync(CONFIG));
  const items = [];
  for (const check of c.checks) {
    const r = b && Array.isArray(b.checks) && b.checks.find(r => r.label === check.label);
    let status = 'insufficient', reason = 'No current execution evidence', recorded = false;
    if (!check.command) reason = 'Configure a real command in ' + CONFIG;
    else if (r && !r.missing && r.command === check.command) {
      if (r.exit !== 0) { status = 'failed'; reason = 'Command failed or could not execute'; }
      try {
        const dir = path.resolve(r.directory);
        const allowed = path.resolve(EVIDENCE, b.runId, check.label);
        if (dir !== allowed) throw new Error('Unexpected receipt directory');
        const ledger = fs.readFileSync(path.join(dir, 'check/ledger.jsonl'), 'utf8').trim().split(/\r?\n/).map(JSON.parse);
        const receipt = ledger.at(-1);
        const log = fs.readFileSync(path.join(dir, 'check', check.label + '.log'));
        const commandRecord = read(path.join(dir, 'command.json'));
        if (!Number.isInteger(r.exit) || receipt.label !== check.label || receipt.exit_code !== r.exit || receipt.schema_version < 2 || receipt.disposition !== 'reexecuted' || receipt.sha256 !== hash(log) || commandRecord.command !== check.command) throw new Error('Receipt/log mismatch');
        recorded = true;
        if (r.exit === 0) {
          if (!fresh || !same(r.before, current) || !same(r.after, current) || !same(b.snapshot, current)) reason = 'Evidence is stale or source changed; run again';
          else { status = 'passed'; reason = 'Executed successfully; receipt and log verified'; }
        }
      } catch { reason = status === 'failed' ? 'Execution failed; receipt/log incomplete' : 'Missing or inconsistent receipt/log'; }
    }
    items.push({ label: check.label, group: check.group, status, reason, recorded });
  }
  let score = 0;
  for (const [group, weight] of Object.entries(c.scope === 'governance-only' ? { required: 75 } : weights)) {
    const rows = items.filter(i => i.group === group);
    if (!rows.length) items.push({ label: group, group, status: 'insufficient', reason: 'Required evidence category is not configured' });
    else score += Math.floor(weight * rows.filter(i => i.status === 'passed').length / rows.length);
  }
  const bound = !!(fresh && same(b.snapshot, current) && b.checks.length === c.checks.length && b.checks.filter(r => !r.missing).every(r => same(r.before, current) && same(r.after, current)));
  items.push({ label: 'Git state', status: bound ? 'passed' : 'insufficient', reason: bound ? 'Evidence matches current HEAD and tracked/untracked source bytes' : 'No fresh evidence bound to current source' });
  if (bound) score += 10;
  const complete = claimValid() && items.filter(i => i.group).every(i => i.recorded && (i.status === 'passed' || i.status === 'failed')) && !!fresh;
  items.push({ label: 'Completion evidence', status: complete ? 'passed' : 'insufficient', reason: complete ? 'Completion claim and all execution results present' : 'Need a completion claim and complete execution evidence' });
  if (complete) score += 15;
  const status = items.some(i => i.status === 'failed') ? 'FAILED' : items.some(i => i.status === 'insufficient') ? 'INSUFFICIENT EVIDENCE' : 'VERIFIED';
  return { version: '0.1.0', scope: c.scope || 'product', score, status, conclusion: status === 'VERIFIED' ? (c.scope === 'governance-only' ? 'Governance checks verified; NOT product acceptance' : 'Verified against configured checks') : 'Cannot confirm completion', commit: current.head, sourceDigest: current.digest, items };
}
function format(result) {
  const icons = { passed: '✅', failed: '❌', insufficient: '⚠️' };
  return ['AI claims: Done', '', 'DoneAudit', `Trust score: ${result.score} / 100 ${result.status === 'VERIFIED' ? '🟢' : '🔴'}`, '', ...result.items.map(i => `${icons[i.status]} ${i.label}: ${i.status.toUpperCase()} — ${i.reason}`), '', `Status: ${result.status}`, `Conclusion: ${result.conclusion}`, ''].join('\n');
}
function report(result = evaluate()) {
  const output = format(result);
  write(EVIDENCE + '/result.json', result);
  write(EVIDENCE + '/result.txt', output);
  console.log(output);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, '<h2>DoneAudit</h2>\n<pre>' + output.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;') + '</pre>\n');
  return result.status === 'VERIFIED' ? 0 : result.status === 'FAILED' ? 1 : 2;
}
if (require.main === module) {
  try {
    const command = process.argv[2];
    if (command === 'init') init(process.argv.slice(3));
    else if (command === 'run') process.exitCode = run();
    else if (command === 'report') process.exitCode = report();
    else if (!command || ['help', '--help', '-h'].includes(command)) console.log('DoneAudit v0.1.0\n  doneaudit init [--portable] [--no-workflow]    Install Codex rules and GitHub checks\n  doneaudit run     Execute checks, collect receipts, and score\n  doneaudit report  Validate existing evidence without rerunning checks\nRequires Node 18+, Git and Bash (Unix) or PowerShell (Windows). Portable skips product npm detection/bootstrap; it does not remove the proof engine Node requirement.');
    else throw new Error('Unknown command: ' + command);
  } catch (error) {
    const failure = { version: '0.1.0', score: 0, status: 'INSUFFICIENT EVIDENCE', conclusion: 'Cannot confirm completion', items: [{ label: 'Audit input', status: 'insufficient', reason: error.message }] };
    try { report(failure); } catch { console.error('DoneAudit: INSUFFICIENT EVIDENCE — ' + error.message); }
    process.exitCode = 2;
  }
}
module.exports = { evaluate, format, snapshot };
