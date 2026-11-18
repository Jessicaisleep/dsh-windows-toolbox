// merge-catalog.mjs — merge the per-agent catalog shards into the single
// softwares.json the plugin ships with.
//
//   node tools/merge-catalog.mjs            # merge + report
//   node tools/merge-catalog.mjs --dry-run  # report only, write nothing
//
// Why shards: three subagents each own a slice of the catalog (A: im/office/
// browser/input, B: media/graphics/dev, C: utility/system/security/network).
// Letting them all rewrite softwares.json would have them clobber each other.
// Each writes softwares-X.json; this script is the only writer of the real file.
//
// Merge rules:
//   * the existing softwares.json entries are kept as the base
//   * a shard entry with an id that already exists REPLACES it (the shard is
//     newer and was checked against the live vendor site)
//   * duplicate ids inside one shard: first wins, and it is reported
//   * entries are sorted by category (in the canonical category order) then id,
//     so re-running the merge produces a stable file
//   * categories must exist in the canonical category map; an unknown category
//     is a hard error — silently accepting it would ship an unfilterable entry

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const PRESETS = join(HERE, '..', 'lib', 'presets');
const TARGET = join(PRESETS, 'softwares.json');

const SHARDS = [
  ['A', join(PRESETS, 'softwares-A.json')],
  ['B', join(PRESETS, 'softwares-B.json')],
  ['C', join(PRESETS, 'softwares-C.json')],
];

// Canonical display order for the panel. Anything not listed here is a bug in a
// shard, not a new category.
const CATEGORY_ORDER = [
  'im', 'office', 'browser', 'input',
  'media', 'graphics',
  'dev', 'utility', 'system', 'security', 'network',
];

const args = new Set(process.argv.slice(2));
const DRY = args.has('--dry-run');
const problems = [];
const notes = [];

function fail(msg) { problems.push(msg); }

function readJson(path, label) {
  if (!existsSync(path)) { notes.push(`${label}: missing (${path})`); return null; }
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (e) {
    fail(`${label}: invalid JSON — ${e.message}`);
    return null;
  }
}

const base = readJson(TARGET, 'softwares.json');
if (!base) { console.error('cannot read base catalog'); process.exit(2); }

const categories = base.categories;
if (!categories || typeof categories !== 'object') fail('base catalog has no categories map');

const byId = new Map();
for (const entry of base.softwares ?? []) {
  if (!entry?.id) { fail('base catalog entry without id'); continue; }
  byId.set(entry.id, entry);
}
const baseCount = byId.size;

const added = [];
const replaced = [];
const perShard = [];

for (const [part, path] of SHARDS) {
  const shard = readJson(path, `shard ${part}`);
  if (!shard) continue;
  // Shards label themselves "shard" (what the agents were told to write) but the
  // older convention was "part" — accept either, and only note it when a label
  // exists and disagrees (an absent label means the file predates the convention).
  const declared = shard.shard ?? shard.part;
  if (declared !== undefined && declared !== part) {
    notes.push(`shard ${part}: field says "${declared}"`);
  }
  const rows = Array.isArray(shard.softwares) ? shard.softwares : [];
  let kept = 0, dupInShard = 0;
  const seenHere = new Set();

  for (const entry of rows) {
    if (!entry?.id) { fail(`shard ${part}: entry without id`); continue; }
    if (seenHere.has(entry.id)) { dupInShard++; continue; }
    seenHere.add(entry.id);

    if (!entry.category) { fail(`shard ${part}: ${entry.id} has no category`); continue; }
    if (!(entry.category in categories)) {
      fail(`shard ${part}: ${entry.id} has unknown category "${entry.category}"`);
      continue;
    }
    if (!entry.name) { fail(`shard ${part}: ${entry.id} has no name`); continue; }
    if (!entry.homepage) { fail(`shard ${part}: ${entry.id} has no homepage`); continue; }

    if (byId.has(entry.id)) {
      replaced.push(entry.id);
    } else {
      added.push(entry.id);
    }
    byId.set(entry.id, entry);
    kept++;
  }
  perShard.push({ part, rows: rows.length, accepted: kept, dupInShard });
}

const merged = [...byId.values()];
const rank = (c) => {
  const i = CATEGORY_ORDER.indexOf(c);
  return i === -1 ? CATEGORY_ORDER.length : i;
};
merged.sort((a, b) => {
  const d = rank(a.category) - rank(b.category);
  if (d !== 0) return d;
  return String(a.id).localeCompare(String(b.id));
});

const dist = {};
for (const s of merged) dist[s.category] = (dist[s.category] ?? 0) + 1;

const out = {
  ...base,
  captured: new Date().toISOString().slice(0, 10),
  note: base.note,
  softwares: merged,
};

console.log('merge-catalog');
console.log(`  base entries      : ${baseCount}`);
for (const s of perShard) {
  console.log(`  shard ${s.part}           : ${s.rows} rows, ${s.accepted} accepted${s.dupInShard ? `, ${s.dupInShard} dup-in-shard skipped` : ''}`);
}
console.log(`  added             : ${added.length}`);
console.log(`  replaced (by id)  : ${replaced.length}`);
console.log(`  total             : ${merged.length}`);
console.log(`  categories        : ${Object.keys(dist).length}`);
console.log('  distribution      : ' + Object.entries(dist)
  .sort((a, b) => rank(a[0]) - rank(b[0]))
  .map(([k, v]) => `${k}=${v}`).join(' '));

if (notes.length) {
  console.log('\nnotes:');
  for (const n of notes) console.log('  - ' + n);
}
if (problems.length) {
  console.log('\nPROBLEMS:');
  for (const p of problems) console.log('  ✗ ' + p);
  console.log('\nVERDICT: FAIL');
  process.exit(1);
}

if (DRY) {
  console.log('\n(dry run — nothing written)');
  console.log('VERDICT: PASS');
  process.exit(0);
}

// Keep the original ordering of top-level keys by writing the object as built;
// JSON.stringify preserves insertion order, and `...base` came first.
writeFileSync(TARGET, JSON.stringify(out, null, 2) + '\n', 'utf8');
console.log(`\nwrote ${TARGET}`);
console.log('VERDICT: PASS');
