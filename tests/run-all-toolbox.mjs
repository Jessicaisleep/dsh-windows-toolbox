/**
 * tests/run-all.mjs — the checks that must pass before this toolbox is trusted.
 *
 * Run:  node tests/run-all.mjs
 *       node tests/run-all.mjs --unit-only     (skip everything that touches the machine)
 *
 * Two kinds of check live here:
 *
 *   unit — pure logic: the capability catalogue, the parameter whitelist, the
 *          result normalizer. No PowerShell, no disk.
 *   live — really run each probe on THIS machine and assert the shape and the
 *          invariants of what comes back. Live checks never mutate: junk is only
 *          ever run as a scan or as dryRun, bigfiles/dupfiles only scan.
 *
 * The point of the live half is that the probes are PowerShell: a change that
 * parses fine can still return nothing (the appx `return $rows` bug) or return
 * mojibake (`[Console]::OutputEncoding`). Only a real run catches those.
 */
import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

import {
  RISK, JUNK_GROUPS, JUNK_IDS, CAPABILITIES, CAPABILITY_BY_ID, CAPABILITY_IDS,
  SCAN_ROOTS, SCAN_ROOT_IDS,
} from '../lib/capabilities.js';
import { Runner, sanitizeParams } from '../lib/runner.js';
import { runProbe, interpreter, probePath } from '../lib/ps.js';

const unitOnly = process.argv.includes('--unit-only');
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

let pass = 0;
let fail = 0;
const failures = [];

function check(name, fn) {
  try {
    fn();
    pass++;
    console.log(`  ok   ${name}`);
  } catch (e) {
    fail++;
    failures.push(`${name}: ${e?.message ?? e}`);
    console.log(`  FAIL ${name}: ${e?.message ?? e}`);
  }
}
async function checkAsync(name, fn) {
  try {
    await fn();
    pass++;
    console.log(`  ok   ${name}`);
  } catch (e) {
    fail++;
    failures.push(`${name}: ${e?.message ?? e}`);
    console.log(`  FAIL ${name}: ${e?.message ?? e}`);
  }
}
function eq(actual, expected, label = '') {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${label} expected ${b}, got ${a}`);
}
function ok(cond, label) {
  if (!cond) throw new Error(label || 'expected truthy');
}
function skip(name, why) {
  console.log(`  skip ${name} — ${why}`);
}

/* ------------------------------------------------------------------- unit */

console.log('\n[unit] capabilities.js');

check('capability ids are unique', () => {
  const ids = CAPABILITIES.map((c) => c.id);
  eq(new Set(ids).size, ids.length);
});

check('every capability has label / labelEn / tagline / detail / probe', () => {
  for (const cap of CAPABILITIES) {
    for (const field of ['label', 'labelEn', 'tagline', 'detail', 'probe']) {
      ok(typeof cap[field] === 'string' && cap[field].length > 0, `${cap.id} missing ${field}`);
    }
  }
});

check('every capability declares at least a scan action', () => {
  for (const cap of CAPABILITIES) {
    ok(Array.isArray(cap.actions) && cap.actions.includes('scan'), `${cap.id} must be scannable`);
  }
});

check('only junk may clean — every other verb is read-only until it declares a write verb', () => {
  // Contract: `clean` belongs to junk alone (it deletes cache contents).
  // Capabilities that expose a fix declare `apply` or `repair` instead, and only
  // they may carry a non-readonly risk class. Anything with no write verb must be
  // readonly, so a new capability cannot quietly become writable.
  //
  // `repair` was added for netdiag: it runs external commands (ipconfig/netsh)
  // rather than editing state through a probe-defined recipe, so it is a
  // different verb from `apply` — but it is still a write verb and must not be
  // smuggled in under the readonly flag.
  // `dnspick` is the same story for the DNS switch: one whitelisted server
  // either comes from the five published resolvers or 'auto', and the probe
  // backs up the old value before writing.
  for (const cap of CAPABILITIES) {
    if (cap.id === 'junk') { ok(cap.actions.includes('clean'), 'junk must expose clean'); continue; }
    ok(!cap.actions.includes('clean'), `${cap.id} must not clean`);
    const writes = cap.actions.includes('apply') || cap.actions.includes('repair') || cap.actions.includes('dnspick');
    if (writes) {
      ok(cap.risk !== RISK.readonly, `${cap.id} exposes a write verb, so it must not claim readonly`);
    } else {
      eq(cap.risk, RISK.readonly, `${cap.id} risk`);
    }
  }
});

check('every write-capable probe actually gates its writes behind dryRun', () => {
  // `apply`, `repair` and `dnspick` are promises that the probe can change the
  // machine safely. The two things that make them safe are (a) the probe reads a
  // dryRun parameter and (b) it has a real write path. A capability claiming any
  // of them without both would put a button in the panel that does nothing, or
  // worse, writes unconditionally.
  for (const cap of CAPABILITIES) {
    const writes = cap.actions.includes('apply') || cap.actions.includes('repair') || cap.actions.includes('dnspick');
    if (!writes) continue;
    ok(cap.actions.includes('scan'), `${cap.id} must still be scannable`);
    ok(cap.risk !== RISK.readonly, `${cap.id} exposes a write verb, so it must not claim readonly`);
    const src = readFileSync(probePath(cap.probe), 'utf8');
    ok(/dryRun/.test(src), `${cap.id}: probe reads no dryRun parameter`);
    ok(/Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Remove-Item|Export|reg\s+export/i.test(src),
      `${cap.id}: probe shows no write path`);
  }
});

check('junk is declared destructive (it deletes data)', () => {
  eq(CAPABILITY_BY_ID.get('junk').risk, RISK.destructive);
});

check('every capability probe file exists on disk', () => {
  for (const cap of CAPABILITIES) {
    const p = probePath(cap.probe);
    ok(existsSync(p), `missing probe: ${p}`);
  }
});

check('junk groups are non-empty and every target id is claimed once', () => {
  ok(JUNK_GROUPS.length >= 4);
  const seen = new Set();
  for (const g of JUNK_GROUPS) {
    ok(g.targets.length > 0, `${g.id} has no targets`);
    for (const id of g.targets) {
      ok(!seen.has(id), `target ${id} claimed by two groups`);
      seen.add(id);
    }
  }
  eq(seen.size, JUNK_IDS.size);
});

check('scan roots: ids unique, and user is present', () => {
  const ids = SCAN_ROOTS.map((r) => r.id);
  eq(new Set(ids).size, ids.length);
  ok(SCAN_ROOT_IDS.has('user'));
});

console.log('\n[unit] runner.sanitizeParams');

check('junk keeps only whitelisted target ids', () => {
  const out = sanitizeParams('junk', { targets: ['user-temp', 'not-a-target', 'C:\\Windows'] });
  eq(out.targets, ['user-temp']);
});

check('junk drops a non-array targets value instead of forwarding it', () => {
  eq(sanitizeParams('junk', { targets: 'user-temp' }), {});
  eq(sanitizeParams('junk', { targets: { 0: 'user-temp' } }), {});
});

check('bigfiles root must be a known scan root, else falls back to user', () => {
  eq(sanitizeParams('bigfiles', { root: 'downloads' }).root, 'downloads');
  eq(sanitizeParams('bigfiles', { root: 'C:\\Users' }).root, 'user');
  eq(sanitizeParams('bigfiles', { root: '\\\\server\\share' }).root, 'user');
});

check('bigfiles numbers are clamped integers', () => {
  eq(sanitizeParams('bigfiles', { minMb: 0 }).minMb, 1);
  eq(sanitizeParams('bigfiles', { minMb: -5 }).minMb, 1);
  eq(sanitizeParams('bigfiles', { minMb: 1e9 }).minMb, 100000);
  eq(sanitizeParams('bigfiles', { minMb: '250.7' }).minMb, 250);
  eq(sanitizeParams('bigfiles', {}).minMb, 100);
});

check('dupfiles numbers are clamped integers', () => {
  eq(sanitizeParams('dupfiles', { minKb: 0 }).minKb, 1);
  eq(sanitizeParams('dupfiles', { limit: 99999 }).limit, 500);
  eq(sanitizeParams('dupfiles', {}).minKb, 1024);
});

check('read-only capabilities accept no smuggled parameters', () => {
  eq(sanitizeParams('netdiag', { root: 'user', evil: 1 }), {});
  eq(sanitizeParams('health', { targets: ['user-temp'] }), {});
});

check('the DNS switch only accepts a published resolver or auto', () => {
  // A typo in this field takes the machine off the network, so the allow-list
  // lives in two places (host sanitizer and probe) and is tested here.
  eq(sanitizeParams('netdiag', { action: 'dnspick', server: '223.5.5.5' }),
    { action: 'dnspick', server: '223.5.5.5' });
  eq(sanitizeParams('netdiag', { action: 'dnspick', server: 'auto' }),
    { action: 'dnspick', server: 'auto' });
  // Anything else is dropped, not passed through.
  eq(sanitizeParams('netdiag', { action: 'dnspick', server: '6.6.6.6' }), { action: 'dnspick' });
  eq(sanitizeParams('netdiag', { action: 'dnspick', server: 'evil.example' }), { action: 'dnspick' });
  eq(sanitizeParams('netdiag', { action: 'nuke' }), {});
});

check('unknown capability yields an empty parameter set', () => {
  eq(sanitizeParams('rm-rf', { root: 'user' }), {});
});

check('the DNS allow-list is identical in the probe, the host and the panel', () => {
  // Three places must agree, otherwise the panel offers a server the host strips
  // or the probe rejects — and the user sees a button that does nothing.
  const servers = ['223.5.5.5', '119.29.29.29', '1.1.1.1', '8.8.8.8', '114.114.114.114'];
  // runner.js keeps the allow-list as a regex, so the dots are escaped there.
  // Normalizing `\.` back to `.` lets one check cover all three files without
  // caring which representation each one chose.
  const norm = (s) => s.replace(/\\(?=[.\-])/g, '');
  const probeSrc = norm(readFileSync(probePath('netdiag.ps1'), 'utf8'));
  const runnerSrc = norm(readFileSync(new URL('../lib/runner.js', import.meta.url), 'utf8'));
  const clientSrc = norm(readFileSync(new URL('../client.js', import.meta.url), 'utf8'));
  for (const ip of servers) {
    ok(probeSrc.includes(ip), `netdiag.ps1 does not know ${ip}`);
    ok(runnerSrc.includes(ip), `runner.js does not know ${ip}`);
    ok(clientSrc.includes(ip), `client.js does not know ${ip}`);
  }
  ok(/auto/.test(probeSrc) && /auto/.test(runnerSrc) && /auto/.test(clientSrc), 'the auto option is missing somewhere');
  ok(CAPABILITY_BY_ID.get('netdiag').actions.includes('dnspick'), 'netdiag must declare the dnspick verb');
});

console.log('\n[unit] runner bookkeeping');

check('an unknown capability fails without throwing', () => {
  const r = new Runner();
  // run() is async but the unknown-id branch resolves immediately.
  return r.run('nope', {}).then((out) => {
    eq(out.ok, false);
    ok(String(out.error).includes('unknown capability'), out.error);
  });
});

check('status() lists every capability and runs nothing', () => {
  const r = new Runner();
  const rows = r.status();
  eq(rows.length, CAPABILITIES.length);
  for (const row of rows) {
    ok(CAPABILITY_IDS.has(row.id));
    eq(row.cached, false);
    eq(row.itemCount, 0);
    eq(row.error, null);
  }
});

check('cached() is empty before anything runs and after clear()', () => {
  const r = new Runner();
  eq(r.cached('junk'), null);
  r.clear();
  eq(r.cached('junk'), null);
});

check('panel and probes agree on the junk target count', () => {
  // junklib.ps1 is the authority; the JS catalogue mirrors it. A drift here is
  // how a target silently becomes unscannable. The ids are the first positional
  // argument of each `_add` call, not `id = ...`.
  const text = readFileSync(path.join(ROOT, 'lib', 'probes', 'junklib.ps1'), 'utf8');
  const ids = [...text.matchAll(/^\s*_add\s+'([a-z0-9-]+)'/gm)].map((m) => m[1]);
  ok(ids.length >= 10, `only found ${ids.length} _add rows in junklib.ps1`);
  eq(ids.length, JUNK_IDS.size, 'probe target count vs JS catalogue');
  eq([...ids].sort(), [...JUNK_IDS].sort());
});

/* ------------------------------------------------------------------- live */

const runLive = async () => {
  console.log('\n[live] interpreter');
  const interp = await interpreter();
  if (!interp) throw new Error('no PowerShell interpreter found (pwsh or powershell.exe)');
  console.log(`  interpreter: ${interp.bin} (PS ${interp.major})`);

  const runner = new Runner();

  console.log('\n[live] junk scan');
  await checkAsync('junk scans and reports every whitelisted target', async () => {
    const out = await runner.run('junk', {});
    ok(out.ok, `junk failed: ${out.error}`);
    eq(out.items.length, JUNK_IDS.size, 'target count');
    for (const it of out.items) {
      ok(JUNK_IDS.has(it.id), `unexpected target ${it.id}`);
      // recycle-bin and dns-cache are not directories, so they legitimately
      // carry no path; every filesystem target must have one.
      const nonPath = it.kind === 'recycle' || it.kind === 'flushdns';
      if (nonPath) eq(it.path, '', `${it.id} should have no path`);
      else ok(typeof it.path === 'string' && it.path.length > 0, `${it.id} has no path`);
      ok(Number.isFinite(it.bytes) && it.bytes >= 0, `${it.id} bad bytes`);
      ok(typeof it.label === 'string' && it.label.length > 0, `${it.id} has no label`);
    }
    // Total must equal the sum of the rows — this is what broke when
    // Measure-Object silently returned nothing over OrderedDictionary rows.
    const sum = out.items.reduce((a, b) => a + b.bytes, 0);
    eq(out.meta.totalBytes, sum, 'totalBytes vs row sum');
    console.log(`       ${out.items.length} targets, ${out.meta.totalFiles} files, ${out.meta.totalBytes} bytes`);
  });

  await checkAsync('junk labels are real UTF-8 Chinese, not mojibake', async () => {
    const out = await runner.cached('junk') ?? await runner.ensure('junk', {});
    const labels = out.items.map((i) => i.label).join('');
    ok(!labels.includes('\uFFFD'), 'labels contain the UTF-8 replacement character');
    ok(/[\u4e00-\u9fa5]/.test(labels), 'labels contain no CJK characters');
  });

  await checkAsync('junk dry run reports what it would free and deletes nothing', async () => {
    // The guarantee is "a dry run deletes nothing". It is NOT "two scans of a
    // live machine agree on the total", which is what this check used to assert:
    // %TEMP% churns constantly (measured 236 KB drift out of 2.12 GB between two
    // back-to-back scans), so comparing totals measured the environment, not the
    // dry run. Instead: dry-run only the target we then re-inspect, and require
    // that target to still hold files afterwards.
    const dry = await runProbe('junk.ps1', { action: 'clean', dryRun: true, targets: ['user-temp'] }, { timeout: 180_000 });
    eq(dry.dryRun, true, 'dryRun flag');
    eq(dry.freed, 0, 'a dry run must free nothing');
    eq(dry.deleted, 0, 'a dry run must delete nothing');
    eq(dry.targets.length, 1, 'dry run must select exactly the named target');

    const after = await runProbe('junk.ps1', { action: 'scan', targets: ['user-temp'] }, { timeout: 180_000 });
    const target = after.targets[0];
    ok(target, 'user-temp vanished from the target list');
    ok(target.files > 0, 'a dry run deleted the target contents');
  });

  await checkAsync('junk refuses an id that is not in the whitelist', async () => {
    const out = await runProbe('junk.ps1', {
      action: 'clean', dryRun: true, targets: ['..\\..\\Windows\\System32'],
    }, { timeout: 60_000 });
    eq(out.targets.length, 0, 'a bogus target must select nothing');
  });

  console.log('\n[live] bigfiles');
  await checkAsync('bigfiles scans a root and returns rows sorted by size', async () => {
    const out = await runner.run('bigfiles', { root: 'downloads', minMb: 1, limit: 20 });
    ok(out.ok, `bigfiles failed: ${out.error}`);
    ok(out.meta.scanned > 0, 'scanned nothing — check the root redirect handling');
    for (const r of out.items) {
      ok(r.bytes >= 1024 * 1024, `row below the minimum: ${r.bytes}`);
      ok(r.path.includes('\\'), `row has no path: ${JSON.stringify(r)}`);
    }
    const sizes = out.items.map((r) => r.bytes);
    const sorted = [...sizes].sort((a, b) => b - a);
    eq(sizes, sorted, 'rows must be largest-first');
  });

  await checkAsync('bigfiles falls back to a real directory for an unknown root', async () => {
    const out = await runner.run('bigfiles', { root: 'not-a-root', minMb: 1, limit: 5 });
    ok(out.ok, `bigfiles failed: ${out.error}`);
    eq(out.meta.root, 'user', 'unknown root should normalize to user');
    ok(out.meta.rootPath.length > 0, 'rootPath must be resolved');
  });

  console.log('\n[live] dupfiles');
  await checkAsync('dupfiles scans and every reported group is really identical', async () => {
    const out = await runner.run('dupfiles', { root: 'pictures', minKb: 1, limit: 10 });
    ok(out.ok, `dupfiles failed: ${out.error}`);
    for (const g of out.items) {
      ok(g.count >= 2, `group with ${g.count} files is not a duplicate`);
      eq(g.files.length, g.count, 'file list vs count');
      for (const f of g.files) eq(f.bytes, g.bytes, 'group members must share a size');
      eq(g.wasted, (g.count - 1) * g.bytes, 'wasted = (count-1) * bytes');
    }
  });

  console.log('\n[live] netdiag');
  await checkAsync('netdiag walks every step and names the first failure', async () => {
    const out = await runner.run('netdiag', {});
    ok(out.ok, `netdiag failed: ${out.error}`);
    ok(out.items.length >= 5, `only ${out.items.length} steps`);
    for (const s of out.items) {
      ok(['ok', 'warn', 'fail', 'skip'].includes(s.status), `bad status ${s.status} on ${s.id}`);
      ok(typeof s.label === 'string' && s.label.length > 0, `${s.id} has no label`);
    }
    ok(typeof out.meta.verdict === 'string' && out.meta.verdict.length > 0, 'no verdict');
    // firstFail must be the first non-ok step, or empty when everything is fine.
    const firstNonOk = out.items.find((s) => s.status !== 'ok' && s.status !== 'skip');
    eq(out.meta.firstFail ?? '', firstNonOk?.id ?? '', 'firstFail vs step order');
  });

  console.log('\n[live] health');
  await checkAsync('health returns every check with a status and a measured value', async () => {
    const out = await runner.run('health', {});
    ok(out.ok, `health failed: ${out.error}`);
    ok(out.items.length >= 8, `only ${out.items.length} checks`);
    for (const c of out.items) {
      ok(['ok', 'warn', 'bad', 'skip'].includes(c.status), `bad status ${c.status} on ${c.id}`);
      ok(typeof c.label === 'string' && c.label.length > 0, `${c.id} has no label`);
    }
    const counts = { ok: 0, warn: 0, bad: 0, skip: 0 };
    for (const c of out.items) counts[c.status]++;
    // the probe also reports total, so compare the four statuses only
    for (const k of ['ok', 'warn', 'bad', 'skip']) eq(out.meta.summary?.[k], counts[k], `summary.${k}`);
    eq(out.meta.summary?.total, out.items.length, 'summary.total');
  });

  await checkAsync('health grades each disk on its own size and reports the worst', async () => {
    const out = await runner.run('health', {});
    ok(out.ok, `health failed: ${out.error}`);
    ok(Array.isArray(out.meta.disks) && out.meta.disks.length > 0, 'no disks reported');
    const rank = { bad: 0, warn: 1, ok: 2 };
    for (const d of out.meta.disks) {
      ok(['ok', 'warn', 'bad'].includes(d.level), `${d.drive} has no level: ${d.level}`);
      // the level must follow the thresholds, not the enumeration order
      const expect = (d.usedPct >= 95 || (d.freePct < 5 && d.freeGb < 10)) ? 'bad'
        : (d.usedPct >= 90 || d.freePct < 10) ? 'warn' : 'ok';
      eq(d.level, expect, `${d.drive} level for ${d.usedPct}% used / ${d.freePct}% free`);
      ok(Math.abs(d.usedPct + d.freePct - 100) < 0.3, `${d.drive} used%+free% != 100`);
    }
    // The reported disk must be the worst one, not merely the first enumerated.
    const worst = [...out.meta.disks].sort((a, b) =>
      (rank[a.level] - rank[b.level]) || (b.usedPct - a.usedPct))[0];
    const diskCheck = out.items.find((c) => c.id === 'disk');
    ok(diskCheck, 'no disk check');
    ok(diskCheck.value.startsWith(worst.drive), `reported ${diskCheck.value} but worst is ${worst.drive}`);
  });

  await checkAsync('health labels are UTF-8, not mojibake', async () => {
    const out = await runner.ensure('health', {});
    const text = out.items.map((c) => c.label + c.detail).join('');
    ok(!text.includes('\uFFFD'), 'health output contains the UTF-8 replacement character');
  });

  console.log('\n[live] caching');
  await checkAsync('a second ensure() is served from cache', async () => {
    const a = await runner.ensure('netdiag', {});
    const b = await runner.ensure('netdiag', {});
    eq(b.cached, true, 'second call should hit the cache');
    eq(b.items.length, a.items.length);
  });

  await checkAsync('force:true bypasses the cache', async () => {
    const out = await runner.ensure('netdiag', {}, { force: true });
    eq(out.cached, false, 'force must not report a cache hit');
  });

  await checkAsync('status() reflects the caches once scans have run', async () => {
    const rows = runner.status();
    eq(rows.length, CAPABILITIES.length);
    for (const row of rows) {
      if (row.id === 'junk' || row.id === 'health') {
        ok(row.cached, `${row.id} should be cached after its scan`);
        ok(row.itemCount > 0, `${row.id} cached but empty`);
      }
    }
  });
};

/* ------------------------------------------------- client render (headless) */

/**
 * The panel cannot be opened from an agent session — desktop input refuses to
 * target a DSH host window and the GUI URL is refused to the browser lane. So
 * client.js is rendered in a miniature React runtime (tests/render.mjs) instead:
 * it proves the component tree mounts, resolves every dictionary key, paints
 * real data and never produces a URL outside the plugin namespace.
 *
 * The merged plugin shows the toolbox half behind the「工具箱」tab; the harness
 * clicks that tab and then drives the DNS capability, so picking the panel is
 * mandatory rather than optional.
 */
function renderPanel(lang) {
  const out = spawnSync(
    process.execPath,
    [path.join(ROOT, 'tests', 'render.mjs')],
    {
      encoding: 'utf8',
      env: { ...process.env, WINDOWS_TOOLBOX_LANG: lang, WINDOWS_TOOLBOX_PANEL: 'toolbox' },
    },
  );
  if (out.status !== 0) {
    throw new Error((out.stderr || out.stdout || 'render failed').trim().split('\n').slice(-4).join(' | '));
  }
  return JSON.parse(out.stdout);
}

if (!unitOnly) {
  console.log('\n[render] client.js panel (headless React)');
  for (const lang of ['zh', 'en']) {
    await checkAsync(`the panel renders in ${lang} with real data`, async () => {
      const r = renderPanel(lang);
      if (!r.ok) throw new Error('render reported not ok');
      if (r.panel !== 'toolbox') throw new Error(`expected the toolbox half, got '${r.panel}'`);
      if (r.lang !== lang) throw new Error(`expected lang ${lang}, got ${r.lang}`);
      if (!r.textNodes || r.textNodes < 20) throw new Error(`only ${r.textNodes} text nodes painted`);
      if (!r.dictKeysUsed) throw new Error('panel never called t() — the dictionary check proved nothing');
      // One merged sidebar entry at order 7, not the old second entry at 8.
      if (r.slots.order !== 7) throw new Error(`sidebar order should be 7, got ${r.slots.order}`);
      if (!String(r.slots.label).includes(lang === 'zh' ? '工具箱' : 'Toolbox')) {
        throw new Error(`unexpected sidebar label: ${r.slots.label}`);
      }
      if (r.slots.sidebar !== 'dsh-windows-toolbox') throw new Error('wrong sidebar slot id');
      // The half must actually be on screen, i.e. the tab click worked.
      if (r.activeTab !== (lang === 'zh' ? '工具箱' : 'Toolbox')) {
        throw new Error(`toolbox half was not selected: ${r.activeTab}`);
      }
      // And it must have reached a capability by clicking, not just rendered chrome.
      if (!r.interaction) throw new Error('the DNS capability was never opened by clicking');
    });
  }
}

/* -------------------------------------------------------------------- main */

if (!unitOnly) {
  try {
    await runLive();
  } catch (e) {
    fail++;
    failures.push(`live suite aborted: ${e?.message ?? e}`);
    console.log(`  FAIL live suite aborted: ${e?.message ?? e}`);
  }
} else {
  skip('live suite', '--unit-only');
}

console.log(`\n${fail === 0 ? 'PASS' : 'FAIL'} ${pass}/${pass + fail}`);
if (fail > 0) {
  console.log('\nfailures:');
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
