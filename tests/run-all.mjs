/**
 * One entry point for the merged plugin's tests.
 *
 * The plugin is two halves behind one sidebar entry. Each half kept its own
 * suite through the merge (nothing was dropped: 24 unit + 24 live checks for the
 * manage half, 20 unit + 18 live for the toolbox half), and this file runs both
 * in sequence and reports a single verdict.
 *
 *   node tests/run-all.mjs                # everything, live probes included
 *   node tests/run-all.mjs --unit-only    # pure logic, no PowerShell
 *
 * Exit code is 0 only when BOTH halves pass. Running them as separate processes
 * (rather than importing both suites) keeps the two halves' module-level state
 * from touching each other — they both import ../lib/ps.js, and a shared
 * interpreter cache would hide a per-half failure.
 */
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const unitOnly = process.argv.includes('--unit-only');

const SUITES = [
  { name: 'manage', file: 'run-all-manage.mjs' },
  { name: 'toolbox', file: 'run-all-toolbox.mjs' },
];

const results = [];

for (const suite of SUITES) {
  const args = [HERE + suite.file];
  if (unitOnly) args.push('--unit-only');

  console.log(`\n${'='.repeat(72)}`);
  console.log(`[${suite.name}] node tests/${suite.file}${unitOnly ? ' --unit-only' : ''}`);
  console.log('='.repeat(72));

  const started = Date.now();
  const out = spawnSync(process.execPath, args, { stdio: 'inherit', env: process.env });
  const ms = Date.now() - started;

  results.push({ name: suite.name, code: out.status ?? 1, ms });
}

console.log(`\n${'='.repeat(72)}`);
console.log('[merged] summary');
console.log('='.repeat(72));
for (const r of results) {
  console.log(`  ${r.code === 0 ? 'PASS' : 'FAIL'}  ${r.name.padEnd(8)} ${(r.ms / 1000).toFixed(1)}s`);
}

const failed = results.filter((r) => r.code !== 0);
if (failed.length) {
  console.log(`\nVERDICT: FAIL (${failed.map((r) => r.name).join(', ')})`);
  process.exit(1);
}
console.log(`\nVERDICT: PASS (both halves, ${unitOnly ? 'unit only' : 'unit + live'})`);
