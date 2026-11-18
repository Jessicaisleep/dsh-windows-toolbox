/**
 * Regenerate tests/fixtures.json from the two PRE-MERGE render harnesses.
 *
 * Why not hand-copy: the fixture payloads are real captured host responses
 * (29 capabilities with live probe output; 12 registration sources with real
 * explain text including the Git row and the oem19.inf row whose explain is
 * null). Retyping any of that by hand risks inventing data, and invented
 * fixtures are how a panel test goes green while the real panel is broken.
 *
 * So: lift the objects out of the two old harnesses mechanically, rename the
 * two module-level fixture keys to `manage` / `toolbox`, repoint every payload
 * key at its merged API path, and write one JSON file both harnesses can read.
 *
 *   node tools/merge-render-fixtures.mjs
 *
 * Refuses to write if either source yields an implausible payload set.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import { CAPABILITY_IDS } from '../lib/capabilities.js';

const HERE = fileURLToPath(new URL('..', import.meta.url));
const SOURCES = [
  {
    half: 'toolbox',
    file: join(HERE, 'tools', 'legacy', 'toolbox-render.mjs'),
    moduleId: 'dsh-360-toolbox',
    api: '/dsh-windows-toolbox/api/toolbox',
    // Names that must survive the lift, or the lift went wrong.
    requireKeys: ['/status', '/result?id=junk', '/result?id=netdiag', '/result?id=perm', '/result?id=slim'],
  },
  {
    half: 'manage',
    file: join(HERE, 'tools', 'legacy', 'manage-render.mjs'),
    moduleId: 'dsh-windows-plugin-manager',
    api: '/dsh-windows-toolbox/api/manage',
    requireKeys: ['/status', '/entries'],
  },
];

/**
 * Find `const FIXTURES = {` and return the balanced `{...}` that follows it.
 *
 * Two hazards, both hit on the first attempt:
 *
 *  1. Braces are everywhere inside string data - registry paths and GUIDs like
 *     `"{09A47860-11B0-4DA5-AFA5-26D86198A780}"` - so the counter must track
 *     string literals.
 *  2. Comments inside the literal contain apostrophes (`host's /status`), and a
 *     naive string tracker starts a string there and never closes it, walking
 *     off the end of the file. So comments must be skipped BEFORE quotes are
 *     considered.
 */
function sliceFixtureLiteral(text, file) {
  const start = text.indexOf('const FIXTURES = {');
  if (start < 0) throw new Error(`${file}: no 'const FIXTURES = {' found`);
  let i = text.indexOf('{', start);
  const from = i;
  let depth = 0;
  let quote = null;
  for (; i < text.length; i += 1) {
    const ch = text[i];
    const next = text[i + 1];
    if (quote) {
      if (ch === '\\') { i += 1; continue; }
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '/' && next === '/') {
      const nl = text.indexOf('\n', i);
      i = nl < 0 ? text.length : nl;
      continue;
    }
    if (ch === '/' && next === '*') {
      const close = text.indexOf('*/', i + 2);
      i = close < 0 ? text.length : close + 1;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') { quote = ch; continue; }
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return text.slice(from, i + 1);
    }
  }
  throw new Error(`${file}: unterminated FIXTURES literal`);
}

const out = { captured: '2026-11-18', halves: {} };

for (const src of SOURCES) {
  const text = readFileSync(src.file, 'utf8');
  const literal = sliceFixtureLiteral(text, src.file);
  // The literal references module-level consts declared just above it (the
  // manage harness factors the host block out as `HOST`). Pull those in rather
  // than inlining them, so a re-capture of the source still round-trips.
  const preamble = {};
  for (const m of text.matchAll(/^const ([A-Z][A-Z0-9_]*)\s*=\s*(\{.*?\});\s*$/gm)) {
    try {
      preamble[m[1]] = vm.runInNewContext(`(${m[2]})`, {});
    } catch {
      /* not a plain literal - the fixture does not need it, or we will fail loudly below */
    }
  }
  // LANG is read inside the literal (mustShow / labels pick a language), so the
  // literal has to be evaluated once per language — capturing only 'zh' is how
  // the English run ends up asserting Chinese strings.
  const perLang = {};
  for (const lang of ['zh', 'en']) {
    const parsed = vm.runInNewContext(`(${literal})`, { LANG: lang, ...preamble });
    const entry = parsed[src.moduleId];
    if (!entry) throw new Error(`${src.file}: FIXTURES has no '${src.moduleId}' key`);
    perLang[lang] = entry;
  }
  const entry = perLang.zh;

  for (const k of src.requireKeys) {
    if (!(k in entry.payloads)) throw new Error(`${src.file}: missing required payload '${k}'`);
  }

  // Repoint payload keys at the merged API path. The old harness matched by
  // substring ("longest prefix wins"), so a bare '/status' would now collide
  // between the two halves — the prefix has to be part of the key.
  const payloads = {};
  for (const [k, v] of Object.entries(entry.payloads)) {
    payloads[src.api + k] = v;
  }

  // The host now reports one plugin name for both halves.
  if (payloads[src.api + '/status'] && typeof payloads[src.api + '/status'] === 'object') {
    payloads[src.api + '/status'].name = 'dsh-windows-toolbox';
  }

  // The captured payloads still carry the pre-merge plugin id inside prose
  // (e.g. the backup hint "… reg export to %LOCALAPPDATA%\<id>\regbackup"), and
  // the panel prints those strings verbatim. Rewriting them here keeps the
  // fixture honest: a panel that shows a path the plugin no longer uses is a
  // real defect, and smoke-merged.mjs treats a stale prefix as a failure.
  const renameStale = (v) =>
    typeof v === 'string'
      ? v.split('dsh-windows-plugin-manager').join('dsh-windows-toolbox').split('dsh-360-toolbox').join('dsh-windows-toolbox')
      : v;
  const scrub = (v) => {
    if (Array.isArray(v)) return v.map(scrub);
    if (v && typeof v === 'object') {
      const o = {};
      for (const [k, val] of Object.entries(v)) o[renameStale(k)] = scrub(val);
      return o;
    }
    return renameStale(v);
  };
  for (const k of Object.keys(payloads)) payloads[k] = scrub(payloads[k]);

  // The captured /status was taken when the plugin still shipped 29
  // capabilities. Two arrays in it enumerate capabilities by id — the catalogue
  // (what the strip draws) and the runner's per-capability status. Both have to
  // be filtered against the current table, or the fixture starts asserting the
  // rendering of cards that no longer exist and the live panel quietly
  // disagrees with its own test.
  const pruneCaps = (list) =>
    Array.isArray(list) ? list.filter((row) => row && CAPABILITY_IDS.has(row.id)) : list;
  for (const payload of Object.values(payloads)) {
    if (!payload || typeof payload !== 'object') continue;
    for (const key of ['catalogue', 'capabilities']) {
      if (Array.isArray(payload[key])) payload[key] = pruneCaps(payload[key]);
    }
    // `junkGroups` carries the 9 junk groups, not capabilities — untouched.
  }

  out.halves[src.half] = {
    ns: src.api + '/',
    payloads,
    // Per-language assertion strings. The panel switches dictionary AND the
    // strings it is checked against must switch with it, or the English run
    // fails on Chinese expectations and quietly gets skipped.
    mustShow: { zh: perLang.zh.mustShow, en: perLang.en.mustShow },
    labels: { zh: perLang.zh.labels ?? null, en: perLang.en.labels ?? null },
    // Extra assertions the pre-merge manage harness carried.
    explainOnFace: entry.explainOnFace ?? null,
    explainOnExpand: entry.explainOnExpand ?? null,
    openName: entry.openName ?? null,
    noExplainName: entry.noExplainName ?? null,
  };

  console.log(
    `${src.half.padEnd(8)} payloads=${Object.keys(payloads).length} ` +
    `mustShow zh=${perLang.zh.mustShow.length}/en=${perLang.en.mustShow.length} ` +
    `labels zh=${perLang.zh.labels ? 'yes' : 'no'}/en=${perLang.en.labels ? 'yes' : 'no'}`,
  );
}

// Sanity: the two payload sets must not share a key, or one half's fixture
// silently answers the other half's request.
const tk = Object.keys(out.halves.toolbox.payloads);
const mk = Object.keys(out.halves.manage.payloads);
const clash = tk.filter((k) => mk.includes(k));
if (clash.length) throw new Error(`payload keys collide between halves: ${clash.join(', ')}`);

const dest = fileURLToPath(new URL('../tests/fixtures.json', import.meta.url));
writeFileSync(dest, JSON.stringify(out, null, 2) + '\n');
console.log(`\nwrote ${dest} (${(JSON.stringify(out).length / 1024).toFixed(1)} KiB)`);
