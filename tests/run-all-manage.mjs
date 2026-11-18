/**
 * tests/run-all.mjs - the checks that must pass before this plugin is trusted.
 *
 * Run: node tests/run-all.mjs
 *
 * Two kinds of test live here:
 *   * pure unit tests over lib/normalize.js and lib/sources.js (no PowerShell)
 *   * live tests that really enumerate this machine and really run actions.ps1
 *     in dryRun mode (no mutation). Live tests are skipped with --unit-only.
 */

import { SOURCES, RISK, PROTECTED_SERVICES, riskOf, isMicrosoft } from '../lib/sources.js';
import { normalizePayload, normalizeOne, sortEntries, enabledFrom } from '../lib/normalize.js';
import { Inventory } from '../lib/inventory.js';
import { explainEntry } from '../lib/explain.js';
import { runProbe, interpreter, probePath } from '../lib/ps.js';
import { brokerStatus, canActElevated } from '../lib/elevation.js';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const unitOnly = process.argv.includes('--unit-only');

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

/* ------------------------------------------------------------------- unit */

console.log('\n[unit] sources.js');
check('every source has a unique id', () => {
  const ids = SOURCES.map((s) => s.id);
  eq(new Set(ids).size, ids.length);
});
check('every source probe file exists on disk', () => {
  for (const s of SOURCES) {
    ok(existsSync(probePath(s.probe)), `missing probe ${s.probe}`);
  }
});
check('protected services include the boot-critical set', () => {
  for (const name of ['rpcss', 'dcomlaunch', 'lsm', 'plugplay', 'eventlog', 'samss', 'gpsvc', 'cryptsvc']) {
    ok(PROTECTED_SERVICES.has(name), `${name} should be protected`);
  }
});
check('riskOf marks a protected service as blocked', () => {
  const svc = SOURCES.find((s) => s.id === 'svc');
  eq(riskOf(svc, { name: 'RpcSs', detail: {} }), RISK.blocked);
});
check('riskOf leaves a normal service reversible', () => {
  const svc = SOURCES.find((s) => s.id === 'svc');
  eq(riskOf(svc, { name: 'Spooler', detail: { path: 'C:\\Windows\\System32\\spoolsv.exe' } }), RISK.reversible);
});
check('riskOf marks a non-stoppable kernel driver blocked', () => {
  const svc = SOURCES.find((s) => s.id === 'svc');
  eq(riskOf(svc, { name: 'SomeFilter', detail: { acceptStop: false, path: 'C:\\Windows\\System32\\drivers\\x.sys' } }), RISK.blocked);
});
check('isMicrosoft recognises the obvious publishers', () => {
  ok(isMicrosoft('Microsoft Corporation'));
  ok(isMicrosoft('Microsoft® Windows® Operating System'));
  ok(!isMicrosoft('360.cn'));
  ok(!isMicrosoft(''));
});
check('destructive sources offer uninstall and nothing else', () => {
  // These three used to declare no actions at all, which is why the cards in
  // the panel had no buttons: the data (UninstallString / PackageFullName /
  // oemNN.inf) was already collected, but nothing could act on it. They now
  // expose exactly one verb — uninstall — and must never offer the reversible
  // toggles, because "disabling" an installed program is not a thing.
  for (const id of ['program', 'appx', 'drv']) {
    const src = SOURCES.find((s) => s.id === id);
    eq(src.actions, ['uninstall'], id);
    eq(src.risk, RISK.destructive, `${id} risk`);
  }
});
check('reversible sources declare enable+disable', () => {
  for (const id of ['svc', 'task', 'autorun', 'com']) {
    eq(SOURCES.find((s) => s.id === id).actions, ['enable', 'disable'], id);
  }
});
check('the autostart source reads the real autostart surface, not just four Run keys', () => {
  // The bug this guards: autorun.ps1 used to read Run/RunOnce, the two Startup
  // folders and UWP StartupTasks. On this machine that yields THREE rows, and the
  // user rightly said "there should be dozens". Windows actually starts things
  // from six places; the three big ones (services, logon/boot tasks, Active Setup)
  // were missing entirely.
  const probe = readFileSync(fileURLToPath(new URL('../lib/probes/autorun.ps1', import.meta.url)), 'utf8');
  eq(
    ['registry', 'startup-folder', 'appmodel-startuptask', 'ref-task', 'ref-service', 'activesetup']
      .filter((w) => !new RegExp(`${w}`).test(probe)),
    [],
    'every autostart location must be handled',
  );
  const src = SOURCES.find((s) => s.id === 'autorun');
  ok(/Run\/RunOnce/.test(src.description) && /Active Setup/.test(src.description), 'description must name all six');
  ok(SOURCES.find((s) => s.id === 'autorun').actions.includes('disable'), 'autostart rows must be switchable');
});
check('autostart rows delegate back to the service and task handlers', () => {
  // ref-service / ref-task rows are the same objects svc.ps1 and task.ps1 own.
  // actions.ps1 must dispatch them to DoService/DoTask and then relabel the reply
  // so the panel does not see a source it never asked about.
  const actions = readFileSync(fileURLToPath(new URL('../lib/probes/actions.ps1', import.meta.url)), 'utf8');
  ok(/ref-service/.test(actions), 'actions.ps1 must dispatch ref-service');
  ok(/ref-task/.test(actions), 'actions.ps1 must dispatch ref-task');
  ok(/DoService/.test(actions) && /DoTask/.test(actions), 'the dispatch must reuse the verified handlers');
  ok(/activesetup/.test(actions), 'activesetup must be refused explicitly, not silently accepted');
  // DoTask/DoService return [ordered]@{}: `-is [hashtable]` is false for those and
  // silently skipped the relabel once already.
  ok(/\$r\.Contains\('source'\)/.test(actions), 'the relabel must use Contains(), ordered dicts are not hashtables');
});
check('the protected-service rule applies to autostart rows too', () => {
  // Without this, the same service is red in the Services tab and a harmless blue
  // toggle in the Autostart tab — and the user only finds out after approving UAC.
  const sources = readFileSync(fileURLToPath(new URL('../lib/sources.js', import.meta.url)), 'utf8');
  ok(/where.*=== 'ref-service'/.test(sources) || /===\s*'ref-service'/.test(sources), 'riskOf must special-case ref-service');
  ok(/activesetup/.test(sources), 'riskOf must mark Active Setup read-only');
});

console.log('\n[unit] one elevation channel for both halves');
check('exactly one module raises UAC, and both halves import it', () => {
  // The bug this guards: manage started its own elevated child and toolbox
  // started a second one with a different temp file, so acting as admin twice
  // meant approving twice and the two tabs disagreed about whether the user was
  // elevated. A single resident broker (probes/broker.ps1) now holds the token.
  const libDir = fileURLToPath(new URL('../lib/', import.meta.url));
  const hosts = ['host-manage.js', 'host-toolbox.js'].map((f) => readFileSync(libDir + f, 'utf8'));
  for (const [i, src] of hosts.entries()) {
    ok(/from '\.\/elevation\.js'/.test(src), `host ${i} must import lib/elevation.js`);
    ok(/runElevated\(/.test(src), `host ${i} must run jobs through runElevated()`);
    ok(!/runProbe\('elevated\.ps1'/.test(src), `host ${i} must not spawn elevated.ps1 itself`);
    ok(/canActElevated\(/.test(src), `host ${i} must report the combined elevation answer`);
  }
  // Every UAC raise lives in elevation.js start(); the legacy launcher stays on
  // disk only as the child-side protocol reference and is no longer routed to.
  const raisers = readdirSync(libDir).filter((f) => f.endsWith('.js'))
    .filter((f) => /Start-Process -Verb RunAs/.test(readFileSync(libDir + f, 'utf8')));
  eq(raisers, ['elevation.js']);
});
check('both halves resolve elevation from the same source of truth', () => {
  // Neither tab may keep its own "am I elevated?" memory: `elevated` is computed
  // per request from our own token OR the broker, so one approval flips both.
  const own = { elevatedSelf: false };
  eq(canActElevated(own.elevatedSelf), brokerStatus().running && brokerStatus().elevated);
  eq(canActElevated(true), true, 'a process that already holds a token needs no broker');
  const st = brokerStatus();
  ok(typeof st.running === 'boolean', 'running must be a boolean');
  ok(typeof st.elevated === 'boolean', 'elevated must be a boolean');
  ok(typeof st.stale === 'boolean', 'stale must be a boolean');
});

console.log('\n[unit] normalize.js');
check('enabledFrom understands the on states', () => {
  eq(enabledFrom('Running'), true);
  eq(enabledFrom('Ready'), true);
  eq(enabledFrom('Stopped'), false);
  eq(enabledFrom('Disabled'), false);
  eq(enabledFrom(''), null);
});
check('taskEnabled overrides the state string', () => {
  eq(enabledFrom('Ready', { taskEnabled: false }), false);
});
check('a com entry with an empty Approved value is disabled', () => {
  const e = normalizeOne('com', { name: 'x', clsid: '{X}', inApproved: true, approved: '' }, 0);
  eq(e.enabled, false);
});
check('a com entry with a non-empty Approved value is enabled', () => {
  const e = normalizeOne('com', { name: 'x', clsid: '{X}', inApproved: true, approved: 'Foo' }, 0);
  eq(e.enabled, true);
});
check('a com entry absent from Approved is NOT reported as disabled', () => {
  const e = normalizeOne('com', { name: 'x', clsid: '{X}', inApproved: false, approved: '' }, 0);
  eq(e.enabled, true);
});
check('normalizeOne never returns an empty name', () => {
  const e = normalizeOne('svc', {}, 3);
  ok(e.name.length > 0, 'name should fall back to (未命名)');
});
check('ids are unique across a multi-list payload', () => {
  const payload = {
    packages: [{ name: 'a', packageKey: 'p1' }, { name: 'b', packageKey: 'p2' }],
    devices: [{ name: 'a', deviceId: 'p1' }],
  };
  const { entries } = normalizePayload('drv', payload);
  const ids = entries.map((e) => e.id);
  eq(new Set(ids).size, ids.length, 'driver package/device ids collided');
});
check('array shape reads a bare list', () => {
  const { entries } = normalizePayload('svc', [{ name: 'A', state: 'Running' }]);
  eq(entries.length, 1);
  eq(entries[0].enabled, true);
});
check('rows shape strips the rows key from meta', () => {
  const { entries, meta } = normalizePayload('program', { rows: [{ name: 'A' }], stubCount: 15 });
  eq(entries.length, 1);
  eq(meta.stubCount, 15);
  eq(meta.rows, undefined);
});
check('sortEntries puts blocked before reversible before destructive', () => {
  const sorted = sortEntries([
    { name: 'd', risk: 'destructive', enabled: true },
    { name: 'r', risk: 'reversible', enabled: true },
    { name: 'b', risk: 'blocked', enabled: true },
  ]);
  eq(sorted.map((e) => e.name), ['b', 'r', 'd']);
});
check('sortEntries puts enabled entries ahead of disabled ones at equal risk', () => {
  const sorted = sortEntries([
    { name: 'off', risk: 'reversible', enabled: false },
    { name: 'on', risk: 'reversible', enabled: true },
  ]);
  eq(sorted.map((e) => e.name), ['on', 'off']);
});

console.log('\n[unit] inventory.js');
await checkAsync('an unknown source throws instead of silently returning nothing', async () => {
  const inv = new Inventory();
  let threw = false;
  try { await inv.runSource('nope'); } catch { threw = true; }
  ok(threw, 'runSource should throw on an unknown id');
});
await checkAsync('ensure() with a fabricated slot is served from cache', async () => {
  const inv = new Inventory({ ttlMs: 60_000 });
  inv.slots.set('svc', { entries: [{ id: 'x', name: 'x', enabled: true }], meta: {}, at: Date.now(), ms: 1, error: '' });
  const out = await inv.ensure({ sources: ['svc'] });
  eq(out.ran, []);
  eq(out.elapsedMs, 0);
});
await checkAsync('a failed slot is not treated as fresh', async () => {
  const inv = new Inventory({ ttlMs: 60_000 });
  inv.slots.set('svc', { entries: [], meta: {}, at: Date.now(), ms: 1, error: 'boom' });
  eq(inv.fresh('svc'), false);
});
check(`summary() reports all ${SOURCES.length} sources even when unloaded`, () => {
  const inv = new Inventory();
  const s = inv.summary();
  eq(s.length, SOURCES.length);
  eq(s.every((x) => x.total === 0), true);
});

/* --------------------------------------------------------------- explain.js */

// Regression wall for the "explanation says nothing" complaint: the user's
// words were 「多出来的是哪一页？具体对应哪项？右键菜单也是，你需要说明对应的是
// 哪个右键菜单」. A shell-extension card must therefore name the concrete tab or
// menu item — not just the placement category — whenever the data says which one.
console.log('\n[unit] explain.js');

const shellx = (over) => ({
  source: 'com',
  kind: 'shellx',
  name: over.name ?? '(unnamed)',
  detail: {
    clsid: '{00000000-0000-0000-0000-000000000000}',
    handlerKind: 'ContextMenuHandlers',
    classRoot: 'Directory',
    server: 'C:\\Windows\\system32\\shell32.dll',
    inApproved: false,
    ...over,
  },
});

check('a property-sheet page is named by its own PageTitle', () => {
  // Same shape com.ps1 emits for {596AB062-...}: CLSID PageTitle resolved by
  // SHLoadIndirectString into the real tab caption.
  const e = shellx({
    clsid: '{596ab062-b4d2-4215-9f74-e9109b0a8153}',
    handlerKind: 'PropertySheetHandlers',
    displayName: 'Previous Versions Property Page',
    pageTitle: '@C:\\Windows\\system32\\twext.dll,-1024',
    pageTitleText: '以前的版本',
  });
  const zh = explainEntry(e, 'zh');
  ok(zh.where.includes('以前的版本'), `where must name the tab, got: ${zh.where}`);
  ok(zh.what.includes('「以前的版本」页'), `what must name the tab, got: ${zh.what}`);
  ok(zh.facts.some(([k, v]) => /多出来的是/.test(k) && v === '以前的版本'), 'facts must repeat the tab caption');
});

check('a menu item is named by its ImplementsVerbs, phrased as menu text', () => {
  // {a2a9545d-...} = shell32's Start Menu Pin, ImplementsVerbs=startpin;startunpin.
  const e = shellx({
    clsid: '{a2a9545d-a0c2-42b4-9708-a0b2badd77c8}',
    handlerKind: 'ContextMenuHandlers',
    classRoot: '*',
    displayName: 'Start Menu Pin',
    verbs: 'startpin;startunpin',
  });
  const zh = explainEntry(e, 'zh');
  ok(zh.where.includes('固定到开始屏幕'), `where must name the menu item, got: ${zh.where}`);
  ok(zh.where.includes('从开始屏幕取消固定'), 'where must name the unpin verb too');
  ok(zh.what.includes('它加的是'), `what should read as "it adds", got: ${zh.what}`);
  ok(!/把这一项/.test(zh.what), 'verbs must be menu-item text, not a sentence fragment');
  const en = explainEntry(e, 'en');
  ok(!/[「」]/.test(en.what + en.where), `English output must not use CJK brackets: ${en.what}`);
});

check('a verified caption from the table is used when the probe has none', () => {
  // mydocs.dll's 位置 tab: CLSID carries no PageTitle on this machine, so the
  // caption comes from the per-CLSID table keyed by clsid|handlerKind.
  const e = shellx({
    clsid: '{4a7ded0a-ad25-11d0-98a8-0800361b1103}',
    handlerKind: 'PropertySheetHandlers',
    displayName: 'MyFolder menu and properties',
    dllDescription: '我的文档文件夹 UI',
    server: 'C:\\Windows\\system32\\mydocs.dll',
  });
  const zh = explainEntry(e, 'zh');
  ok(zh.where.includes('位置'), `where must name the 位置 tab, got: ${zh.where}`);
  // The same CLSID also registers under Drive — the tab is the same, the surface differs.
  const drive = explainEntry(shellx({
    clsid: '{4a7ded0a-ad25-11d0-98a8-0800361b1103}',
    handlerKind: 'PropertySheetHandlers',
    classRoot: 'Drive',
    displayName: 'MyFolder menu and properties',
  }), 'zh');
  ok(drive.where.includes('驱动器'), `Drive surface must be distinguished, got: ${drive.where}`);
});

check('a COM class name is never presented as the visible caption', () => {
  // `ShellContextMenu Class`, `DfsShell Class`, `kdesktopshellext Class` are
  // registered names COM uses; the menu never shows them.
  const e = shellx({
    clsid: '{11111111-2222-3333-4444-555555555555}',
    displayName: 'ShellContextMenu Class',
  });
  const zh = explainEntry(e, 'zh');
  ok(!zh.where.includes('——具体是'), `a class name must not be offered as the caption, got: ${zh.where}`);
});

check('a third-party registered name IS the visible caption', () => {
  const e = shellx({
    clsid: '{9179176e-b763-3200-8500-bb1b90b3d5de}',
    displayName: '360压缩文件类型',
    dllDescription: '360ZipExt',
    server: 'D:\\Program Files (x86)\\360\\360zip\\360ZipExt64.dll',
    dllCompany: '360.cn',
  });
  const zh = explainEntry(e, 'zh');
  ok(zh.where.includes('360压缩文件类型'), `where must name the menu item, got: ${zh.where}`);
  eq(zh.origin, 'thirdparty');
  eq(zh.originName, '360.cn');
});

check('a device row says which device to look at in Device Manager', () => {
  const e = {
    source: 'drv',
    kind: 'driverdevice',
    name: '通信端口',
    detail: {
      deviceId: 'ACPI\\PNP0501\\1', infName: 'msports.inf',
      deviceClass: 'PORTS', provider: 'Microsoft', name: '通信端口',
    },
  };
  const zh = explainEntry(e, 'zh');
  ok(zh.where.includes('设备管理器'), `device where must point at Device Manager, got: ${zh.where}`);
  ok(zh.where.includes('通信端口'), 'device where must name the device');
  // An unnamed node must not be presented as if it had a name.
  const unnamed = explainEntry({
    source: 'drv',
    kind: 'driverdevice',
    name: '(未命名)',
    detail: { deviceId: 'HTREE\\ROOT\\0', deviceClass: 'SYSTEM' },
  }, 'zh');
  ok(!/未命名\]?」/.test(unnamed.where), `unnamed device must not quote a placeholder name: ${unnamed.where}`);
  ok(unnamed.where.includes('HTREE\\ROOT\\0'), 'unnamed device must fall back to the device id');
});

check('every explanation names something or says nothing — never a bare category', () => {
  // The original bug: SOURCE_KIND returned one fixed sentence per source, so a
  // whole panel read identically. A category sentence may appear, but only
  // alongside a row-specific fact.
  const cases = [
    shellx({ clsid: '{4a7ded0a-ad25-11d0-98a8-0800361b1103}', handlerKind: 'PropertySheetHandlers', displayName: 'MyFolder menu and properties' }),
    shellx({ clsid: '{a2a9545d-a0c2-42b4-9708-a0b2badd77c8}', displayName: 'Start Menu Pin', verbs: 'startpin;startunpin' }),
    shellx({ clsid: '{9179176e-b763-3200-8500-bb1b90b3d5de}', displayName: '360压缩文件类型', dllDescription: '360ZipExt', dllCompany: '360.cn', server: 'D:\\x\\360ZipExt64.dll' }),
  ];
  const whats = cases.map((c) => explainEntry(c, 'zh').what);
  eq(new Set(whats).size, whats.length, `three different rows produced ${new Set(whats).size} distinct sentences`);
});

/* ------------------------------------------------------------------- live */

if (!unitOnly) {
  console.log('\n[live] interpreter');
  await checkAsync('an interpreter >= PS 5 is found', async () => {
    const chosen = await interpreter();
    ok(chosen, 'no interpreter');
    ok(chosen.major >= 5, `major=${chosen.major}`);
    console.log(`       using ${chosen.bin} (PS ${chosen.major})`);
  });

  console.log('\n[live] host.ps1');
  await checkAsync('host.ps1 reports elevation and OS', async () => {
    const out = await runProbe('host.ps1');
    ok(typeof out.elevated === 'boolean', 'elevated should be boolean');
    ok(String(out.os).length > 0, 'os should be non-empty');
  });

  console.log(`\n[live] all ${SOURCES.length} probes`);
  const inv = new Inventory({ ttlMs: 0 });
  let total = 0;
  for (const s of SOURCES) {
    await checkAsync(`${s.id} enumerates without error`, async () => {
      const slot = await inv.runSource(s.id);
      ok(!slot.error, slot.error);
      ok(slot.entries.length > 0, `${s.id} returned zero entries`);
      total += slot.entries.length;
      console.log(`       ${String(slot.entries.length).padStart(4)} entries in ${slot.ms} ms`);
    });
  }
  await checkAsync(`the unified index holds every row (${total} total)`, async () => {
    eq(inv.allEntries().length, total);
  });
  await checkAsync('appx is not a silent zero (the PS7/Appx trap)', async () => {
    const meta = inv.slots.get('appx')?.meta ?? {};
    eq(meta.mode, 'enumerated', `mode=${meta.mode}`);
    ok(Number(meta.count) > 0, `count=${meta.count}`);
  });
  await checkAsync('every entry has a unique id', async () => {
    const ids = inv.allEntries().map((e) => e.id);
    const dupes = ids.filter((id, i) => ids.indexOf(id) !== i);
    if (dupes.length) throw new Error(`duplicate ids: ${dupes.slice(0, 5).join(', ')}`);
  });

  console.log('\n[live] actions.ps1 dryRun (writes nothing)');
  await checkAsync('a normal service disable plans but does not write', async () => {
    const out = await runProbe('actions.ps1', {
      action: 'disable', source: 'svc', target: { name: 'Spooler' }, dryRun: true,
    });
    eq(out.ok, true, out.message);
    eq(out.changed, false);
    ok(out.undo, 'a dry run must still report the undo record');
  });
  await checkAsync('a protected service is refused', async () => {
    const out = await runProbe('actions.ps1', {
      action: 'disable', source: 'svc', target: { name: 'RpcSs' }, dryRun: true,
    });
    eq(out.ok, false);
    ok(String(out.message).includes('受保护'), out.message);
  });
  await checkAsync('an unknown service is refused', async () => {
    const out = await runProbe('actions.ps1', {
      action: 'disable', source: 'svc', target: { name: 'dsh-no-such-service-xyz' }, dryRun: true,
    });
    eq(out.ok, false);
    ok(String(out.message).includes('不存在'), out.message);
  });
  await checkAsync('program is not a toggle and points at uninstall', async () => {
    const out = await runProbe('actions.ps1', {
      action: 'disable', source: 'program', target: { name: 'x' }, dryRun: true,
    });
    eq(out.ok, false);
    // program/appx/drv are no longer read-only: enable/disable is the wrong verb
    // for them, so the refusal has to redirect to uninstall instead of claiming
    // the source is unwritable. See lib/probes/actions.ps1 dispatch.
    ok(String(out.message).includes('action=uninstall'), out.message);
  });
  await checkAsync('appx and drv are refused too', async () => {
    for (const source of ['appx', 'drv']) {
      const out = await runProbe('actions.ps1', {
        action: 'disable', source, target: { name: 'x' }, dryRun: true,
      });
      eq(out.ok, false, source);
    }
  });
}

/* ------------------------------------------------- client render (headless) */

/**
 * The panel cannot be opened from an agent session — desktop input refuses to
 * target a DSH host window and the GUI URL is refused to the browser lane. So
 * client.js is rendered in a miniature React runtime (tests/render.mjs) instead:
 * it proves the component tree mounts, resolves every dictionary key, paints
 * real data and never produces a URL outside the plugin namespace.
 *
 * The merged plugin shows the manage half behind its own tab, so the harness has
 * to be told which half to assert.
 */
function renderPanel(lang) {
  const out = spawnSync(
    process.execPath,
    [fileURLToPath(new URL('./render.mjs', import.meta.url))],
    {
      encoding: 'utf8',
      env: { ...process.env, WINDOWS_TOOLBOX_LANG: lang, WINDOWS_TOOLBOX_PANEL: 'manage' },
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
      if (r.panel !== 'manage') throw new Error(`expected the manage half, got '${r.panel}'`);
      if (r.lang !== lang) throw new Error(`expected lang ${lang}, got ${r.lang}`);
      if (!r.textNodes || r.textNodes < 20) throw new Error(`only ${r.textNodes} text nodes painted`);
      if (!r.dictKeysUsed) throw new Error('panel never called t() — the dictionary check proved nothing');
      if (r.slots.order !== 7) throw new Error(`sidebar order should be 7, got ${r.slots.order}`);
      // One sidebar entry for the whole plugin — the merge's whole point.
      if (r.slots.sidebar !== 'dsh-windows-toolbox') throw new Error('wrong sidebar slot id');
      if (!String(r.slots.label).includes(lang === 'zh' ? '工具箱' : 'Toolbox')) {
        throw new Error(`unexpected sidebar label: ${r.slots.label}`);
      }
      // Both tabs must be on screen, or the other half is unreachable.
      if (!Array.isArray(r.tabs) || r.tabs.length !== 2) {
        throw new Error(`expected 2 tabs, got ${JSON.stringify(r.tabs)}`);
      }
      if (r.activeTab !== (lang === 'zh' ? '插件化管理' : 'Plugins')) {
        throw new Error(`manage half did not open on its own tab: ${r.activeTab}`);
      }
      // The user's complaint was "只能看不能操作"; the harness counts the verbs
      // that are actually on the card faces.
      if (!(r.faceActions > 0)) throw new Error('no card face exposes an action button');
    });
  }
}

/* ------------------------------------------------------------------ report */

console.log('');
if (fail === 0) {
  console.log(`PASS ${pass}/${pass} checks`);
  process.exit(0);
} else {
  console.log(`FAIL ${fail} of ${pass + fail} checks`);
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
