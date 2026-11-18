/**
 * normalize.js - collapse eleven differently-shaped probe payloads into one entry
 * shape the panel and the tools can both consume.
 *
 * The probes were written independently and each carries its own fields (svc has
 * startMode, task has actionDisabled, com has approved, firewall has a nine-tuple
 * key, …). Rather than teach the UI about eleven shapes, every row becomes an
 * Entry:
 *
 *   id        stable identity, "<source>:<scope>:<key>"    - used as the row key
 *   source    source id from sources.js                    - 'svc', 'task', …
 *   name      what the user sees                           - never empty
 *   state     enabled | disabled | running | stopped | installed | unbound | …
 *   enabled   boolean or null when the concept does not apply
 *   path      the binary / command / registry path         - '' when unknown
 *   version   '' when unknown
 *   publisher '' when unknown
 *   scope     'machine' | 'user'
 *   view      '64' | '32' | 'user'
 *   risk      from sources.js: readonly | reversible | destructive | blocked
 *   detail    the probe's own fields, kept verbatim for the detail pane
 *
 * Nothing is dropped on the floor: `detail` holds the original row so a future
 * action can act on it without re-probing.
 */

import { SOURCE_BY_ID, riskOf } from './sources.js';

/** Truthy state names that should render as "on". */
const ON_STATES = new Set(['enabled', 'running', 'ready', 'installed', 'queued']);
/** Falsey ones. */
const OFF_STATES = new Set(['disabled', 'stopped', 'unbound', 'unconfigured', 'notinstalled']);

function lower(v) {
  return String(v ?? '').trim().toLowerCase();
}

/** Is this entry "on" right now? null = the concept does not apply. */
export function enabledFrom(state, extra = {}) {
  if (typeof extra.enabled === 'boolean') return extra.enabled;
  if (typeof extra.taskEnabled === 'boolean') return extra.taskEnabled;
  const s = lower(state);
  if (ON_STATES.has(s)) return true;
  if (OFF_STATES.has(s)) return false;
  return null;
}

/** Build the stable id. Falls back to name when a probe has no better key. */
function makeId(source, scope, kind, key, name, index) {
  const k = String(key ?? '').trim();
  if (k) return `${source}:${scope}:${k}`;
  const n = String(name ?? '').trim();
  if (n) return `${source}:${scope}:${kind}:${n}`;
  return `${source}:${scope}:${kind}:#${index}`;
}

/**
 * Normalize one raw probe row into an Entry.
 *
 * `listKey` distinguishes the two driver lists (packages vs devices) so their
 * ids never collide.
 */
export function normalizeOne(sourceId, raw, index, listKey = '') {
  const source = SOURCE_BY_ID.get(sourceId);
  const scope = lower(raw.scope) === 'user' ? 'user' : 'machine';
  const view = String(raw.view ?? (scope === 'user' ? 'user' : '64'));
  const kind = String(raw.kind ?? listKey ?? sourceId);
  const name = String(raw.name ?? raw.displayName ?? raw.taskName ?? '').trim()
    || String(raw.publishedName ?? raw.PackageFamilyName ?? '').trim()
    || '(未命名)';

  // The most specific identity the probe offered.
  //
  // `fullName`/`fullname` matters for AppX: several versions of the same
  // framework package share one FamilyName, so keying on the family produced
  // duplicate ids (measured: Microsoft.NET.Native.Framework.1.7 and .2.2 each
  // appeared twice, caught by tests/run-all.mjs). The full name carries the
  // version and is unique per installed package.
  const keyCandidate =
    raw.keyPath
    ?? raw.packageKey
    ?? raw.clsid
    ?? raw.productCode
    ?? raw.fullName
    ?? raw.packageFullName
    ?? raw.family
    ?? raw.PackageFamilyName
    ?? raw.deviceId
    ?? raw.name
    ?? '';

  const entry = {
    id: makeId(sourceId, scope, kind, listKey ? `${listKey}:${keyCandidate}` : keyCandidate, name, index),
    source: sourceId,
    kind,
    name,
    state: String(raw.state ?? ''),
    enabled: enabledFrom(raw.state ?? raw.startMode, {
      enabled: typeof raw.enabled === 'boolean' ? raw.enabled : undefined,
      taskEnabled: typeof raw.taskEnabled === 'boolean' ? raw.taskEnabled : undefined,
    }),
    path: String(raw.path ?? raw.server ?? raw.executables ?? ''),
    version: String(raw.version ?? ''),
    publisher: String(raw.publisher ?? raw.provider ?? raw.signer ?? ''),
    scope,
    view,
    risk: '',
    detail: raw,
  };

  // Shell extensions do not carry a state field: Explorer loads a registered
  // handler unless its CLSID appears in Shell Extensions\Approved with an EMPTY
  // value. Three cases, and collapsing any two of them is a real bug:
  //   absent from Approved   -> loaded  (Approved only gates one legacy path)
  //   present, value ''      -> blocked (this is the reversible lever)
  //   present, value non-''  -> loaded
  // The probe therefore reports `inApproved` alongside `approved`.
  if (sourceId === 'com') {
    entry.enabled = raw.inApproved !== true ? true : String(raw.approved ?? '') !== '';
  }

  // ---------------------------------------------------------------------------
  // Firewall rules
  // ---------------------------------------------------------------------------
  // A rule's `Name` is NOT unique: 542 rules carry 324 distinct names, and
  // name+direction still leaves 131 colliding groups on this machine. The probe
  // therefore supplies a nine-tuple as `keyPath`, which the generic branch above
  // already turned into the id - nothing to override. Two field mappings are
  // worth being explicit about:
  //   path        - the ApplicationName is the only meaningful "program" column;
  //                 the probe mirrors it into `path` so the row/card shows the
  //                 executable instead of an empty cell.
  //   publisher   - deliberately empty. Filling it would require FileVersionInfo
  //                 on 94 distinct binaries, which measured 5161 ms cold for the
  //                 64 in System32 - more than the whole enumeration. A blank is
  //                 honest; a guessed publisher is not.
  if (sourceId === 'firewall') {
    entry.path = String(raw.application ?? raw.path ?? '');
  }

  // ---------------------------------------------------------------------------
  // IFEO
  // ---------------------------------------------------------------------------
  // Identity is "<view>\\<exe>" (86 rows, 86 unique). `enabled` needs care: a
  // completely empty IFEO key does nothing, while a mitigation-only key applies
  // its settings at every launch. Both are "on" states from the user's point of
  // view, so `state` alone would be misleading - the probe's boolean wins.
  if (sourceId === 'ifeo') {
    entry.path = String(raw.debugger ?? '');
    entry.enabled = raw.valueNames?.length > 0;
    // A hijacked row is the whole reason this source exists; keep it in `state`
    // so the row text says "hijacked" rather than a generic "enabled".
    entry.state = String(raw.state ?? (entry.enabled ? 'enabled' : 'empty'));
  }

  // ---------------------------------------------------------------------------
  // File associations
  // ---------------------------------------------------------------------------
  // `enabled` here means "a default program is actually associated", not "the
  // extension exists": 520 extensions exist, only 163 have a UserChoice ProgId,
  // and 230 are empty shells left behind by uninstalled apps. The probe's
  // four-valued `state` (userchoice / openwith / empty / none) is what the panel
  // prints; the boolean is what the filter uses.
  if (sourceId === 'fileexts') {
    entry.path = String(raw.command ?? '');
    entry.publisher = String(raw.progId ?? '');
    entry.enabled = Boolean(raw.progId);
  }

  // ---------------------------------------------------------------------------
  // Credential providers
  // ---------------------------------------------------------------------------
  // Registration is not a boolean - a provider either has a subkey or it does
  // not - so every row is enabled. The interesting columns are `purpose` (the
  // name Windows itself stores) and whether the DLL sits outside System32.
  if (sourceId === 'credprov') {
    entry.path = String(raw.dll ?? '');
    entry.enabled = true;
  }

  // ---------------------------------------------------------------------------
  // Repair findings
  // ---------------------------------------------------------------------------
  // These rows are not registration points: the probe emits one row per
  // configuration-drift check, keyed by a stable check id (hosts / ie / dns /
  // netconn / uac / redundant / fontcache / iconcache). `label` is the human
  // name, and the probe's status IS the row state - there is no enabled flag,
  // because "the hosts file drifted" is not a thing you switch on or off.
  if (sourceId === 'repair') {
    entry.name = String(raw.label ?? raw.id ?? '').trim() || '(未命名)';
    entry.kind = String(raw.group ?? 'repair');
    entry.state = String(raw.status ?? '');
    entry.enabled = null;
    entry.path = '';
    entry.publisher = '';
    // The finding text and the suggested fix are the interesting columns; the
    // raw record still carries them, and explain.js turns them into prose.
    entry.detail = raw;
    entry.id = makeId(sourceId, 'machine', String(raw.group ?? 'repair'), String(raw.id ?? ''), entry.name, index);
  }

  entry.risk = riskOf(source, entry);
  return entry;
}

/** Normalize a whole probe payload according to its declared shape. */
export function normalizePayload(sourceId, payload) {
  const source = SOURCE_BY_ID.get(sourceId);
  if (!source) throw new Error(`unknown source: ${sourceId}`);

  const out = [];
  let i = 0;

  if (source.shape === 'array') {
    const rows = Array.isArray(payload) ? payload : [];
    for (const r of rows) out.push(normalizeOne(sourceId, r, i++));
    return { entries: out, meta: {} };
  }

  if (source.shape === 'rows') {
    const rows = Array.isArray(payload?.rows) ? payload.rows : [];
    for (const r of rows) out.push(normalizeOne(sourceId, r, i++));
    const meta = { ...payload };
    delete meta.rows;
    return { entries: out, meta };
  }

  // items: the featurelib envelope {ok,count,items[],summary,...}. Kept separate
  // from the `multi` fallback on purpose - `multi` treats EVERY array field as a
  // row list, and repair.ps1 also carries an `ids` array of the request's id
  // filter, which would surface as spurious rows.
  if (source.shape === 'items') {
    const rows = Array.isArray(payload?.items) ? payload.items : [];
    for (const r of rows) out.push(normalizeOne(sourceId, r, i++));
    const meta = { ...payload };
    delete meta.items;
    return { entries: out, meta };
  }

  // multi: several named lists in one payload (drivers: packages + devices).
  const meta = {};
  for (const [k, v] of Object.entries(payload ?? {})) {
    if (Array.isArray(v)) {
      for (const r of v) out.push(normalizeOne(sourceId, r, i++, k));
    } else {
      meta[k] = v;
    }
  }
  return { entries: out, meta };
}

/**
 * Sort for display: actionable problems first, then by name.
 *
 * Deliberately not "alphabetical": someone opening this panel is looking for the
 * handful of things they did not install. So: disabled-but-present entries are
 * not the story; the story is third-party stuff that is on.
 */
export function sortEntries(entries) {
  return [...entries].sort((a, b) => {
    const ra = riskRank(a.risk);
    const rb = riskRank(b.risk);
    if (ra !== rb) return ra - rb;
    const sa = a.enabled === true ? 0 : a.enabled === false ? 2 : 1;
    const sb = b.enabled === true ? 0 : b.enabled === false ? 2 : 1;
    if (sa !== sb) return sa - sb;
    return a.name.localeCompare(b.name, 'zh-Hans-CN');
  });
}

function riskRank(risk) {
  switch (risk) {
    case 'blocked': return 0;
    case 'reversible': return 1;
    case 'destructive': return 2;
    default: return 3;
  }
}
