#!/usr/bin/env node
'use strict';
// Run the configured shell command without transporting it through several
// shells as an argument. Its actual exit code is captured by the upstream gate.
const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const { command } = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const r = spawnSync(command, { shell: true, stdio: 'inherit', timeout: 300000 });
if (r.error) console.error(r.error.message);
process.exit(r.status === null ? 1 : r.status);
