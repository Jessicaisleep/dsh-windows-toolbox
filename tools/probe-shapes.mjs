// probe-shapes.mjs — run every probe and report its envelope shape.
// Used while wiring new probes into capabilities.js: the normalizer needs to
// know which key holds the payload (items/rows/checks/steps/groups) and which
// extra fields the panel can display.
import { runProbe } from '../lib/ps.js';

const NAMES = process.argv.slice(2);
if (!NAMES.length) {
  console.error('usage: node tools/probe-shapes.mjs <probe.ps1> [more...]');
  process.exit(2);
}

for (const name of NAMES) {
  const started = Date.now();
  let payload = null;
  let err = null;
  try {
    payload = await runProbe(name, {}, { timeout: 180_000 });
  } catch (e) {
    err = String(e?.message ?? e);
  }
  const ms = Date.now() - started;
  if (err || payload === null) {
    console.log(`${name}\tFAIL\t${ms}ms\t${err ?? 'null payload'}`);
    continue;
  }
  const keys = Object.keys(payload);
  const arrays = keys.filter((k) => Array.isArray(payload[k]));
  const counts = arrays.map((k) => `${k}=${payload[k].length}`).join(' ');
  const summary = payload.summary ? JSON.stringify(payload.summary) : '-';
  console.log(`${name}\t${ms}ms\tcount=${payload.count ?? '-'}\t${counts}\tsummary=${summary}`);
  console.log(`  keys: ${keys.join(', ')}`);
}
