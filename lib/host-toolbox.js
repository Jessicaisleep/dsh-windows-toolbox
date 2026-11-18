/**
 * dsh-windows-toolbox — Host half.
 *
 * A catalogue of maintenance capabilities for this Windows machine, each
 * described by the same detect / plan / apply / verify / rollback vocabulary the
 * sibling plugin (dsh-windows-toolbox) uses for registry points.
 *
 * The catalogue lives in lib/capabilities.js (27 entries across four groups:
 * cleanup / system / network / apps). Every probe returns the same envelope
 * (`{ok, count, items[], summary, ...extra}`) because they all use
 * lib/probes/featurelib.ps1, so Runner.normalizeCapability has one generic
 * branch and adding a capability never means touching this file.
 *
 * Each capability declares `coverage` so the UI can be honest about the parts
 * that Windows itself makes impossible here:
 *   full      works end to end
 *   partial   real value, but a known piece cannot be done from a plugin
 *   readonly  inspection only — the fix needs a reboot, an installer or admin
 *   blocked   cannot be done safely/usefully at all (reason is in `detail`)
 *
 *   GET  /dsh-windows-toolbox/api/toolbox/status            — capability catalogue + cache state
 *   GET  /dsh-windows-toolbox/api/toolbox/result?id=        — one capability's cached result
 *   POST /dsh-windows-toolbox/api/toolbox/run               — run ONE capability's scan
 *   POST /dsh-windows-toolbox/api/toolbox/clean             — junk cleanup, dry-run by default
 *   POST /dsh-windows-toolbox/api/toolbox/apply             — the controllable fixes
 *   POST /dsh-windows-toolbox/api/toolbox/elevated          — run one probe in an elevated child
 *
 *   tools: tb360_status, tb360_scan, tb360_clean, tb360_apply, tb360_elevated
 *
 * Elevation is honest: the host process stays unelevated, so /status keeps
 * reporting `elevatedSelf:false`. Privileged work goes through lib/elevation.js,
 * which owns ONE resident elevated broker (probes/broker.ps1) shared with the
 * manage half — the user approves a single UAC prompt per session, and a
 * cancelled prompt is a normal answer (HTTP 200 with `cancelled:true`), never an
 * error page.
 *
 * Scope limit: nothing here deletes user files. `bigfiles` and `dupfiles`
 * report paths and byte counts only; `clean` exists solely for the fixed junk
 * whitelist; `shredder` only touches files the caller names one by one. There is
 * no "delete this file" endpoint, by design.
 */

import {
  CAPABILITIES, CAPABILITY_BY_ID, CAPABILITY_GROUPS, RISK,
  JUNK_GROUPS, SCAN_ROOTS,
} from './capabilities.js';
import { Runner, normalizeCapability, sanitizeParams } from './runner.js';
import { interpreter, probePath, runProbe, parseJson } from './ps.js';
import { runElevated, brokerStatus, canActElevated, ensureBroker, stopBroker } from './elevation.js';

const API = '/dsh-windows-toolbox/api/toolbox';

// Derived from the catalogue, never hand-written: a stray id list here would
// silently refuse a capability the panel already shows.
const SCANNABLE_IDS = CAPABILITIES.filter((c) => c.actions.includes('scan')).map((c) => c.id);
const APPLYABLE_IDS = CAPABILITIES.filter((c) => c.actions.includes('apply')).map((c) => c.id);
const ALL_IDS = CAPABILITIES.map((c) => c.id);
// netdiag speaks a third verb: 'repair' (360's 断网急救箱). It is kept separate
// from 'apply' because its request body is different — a chosen subset of fix
// ids plus dryRun — and because calling it "apply" would hide that four of the
// seven fixes cannot run without administrator rights.
const REPAIRABLE_IDS = CAPABILITIES.filter((c) => c.actions.includes('repair')).map((c) => c.id);
// 'dnspick' is a fourth verb: it rewrites the resolver list, which is neither a
// repair recipe nor a generic apply (the body carries one whitelisted server).
const DNSPICK_IDS = CAPABILITIES.filter((c) => c.actions.includes('dnspick')).map((c) => c.id);
// One capability can carry several write verbs (netdiag speaks repair AND
// dnspick), so the tool's enum has to be a de-duplicated union — otherwise the
// agent sees the same id twice and a future schema validator may reject it.
const WRITABLE_IDS = [...new Set([...APPLYABLE_IDS, ...REPAIRABLE_IDS, ...DNSPICK_IDS])];

/* ------------------------------------------------------------------ plumbing */

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(payload),
  });
  res.end(payload);
}

function hostnameOfHost(host) {
  try { return new URL(`http://${host}`).hostname; } catch { return ''; }
}
function isLocalHostname(h) {
  const v = String(h).toLowerCase().replace(/^\[|\]$/g, '');
  return v === 'localhost' || v === '127.0.0.1' || v === '::1' || v.startsWith('127.');
}
function hostMatchesListener(host, localAddress) {
  if (!host || !host.trim()) return false;
  const hostname = hostnameOfHost(host);
  if (isLocalHostname(hostname)) return true;
  if (hostname === '0.0.0.0' || hostname === '[::]') return false;
  if (!localAddress) return false;
  const bare = (x) => (x.startsWith('[') && x.endsWith(']') ? x.slice(1, -1) : x);
  return bare(hostname.toLowerCase()) === bare(String(localAddress).toLowerCase());
}
function originTrusted(origin, localAddress) {
  if (!origin || !origin.trim()) return true;
  try { return hostMatchesListener(new URL(origin).host, localAddress); } catch { return false; }
}
function trusted(req, res) {
  if (!hostMatchesListener(req.headers.host, req.socket?.localAddress)) {
    json(res, 403, { error: 'host-not-trusted' }); return false;
  }
  if (!originTrusted(req.headers.origin, req.socket?.localAddress)) {
    json(res, 403, { error: 'origin-not-trusted' }); return false;
  }
  return true;
}

function readJsonBody(req, maxBytes = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    let done = false;
    req.on('data', (c) => {
      if (done) return;
      size += c.length;
      if (size > maxBytes) { done = true; reject(new Error('request body too large')); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      if (done) return;
      done = true;
      const text = Buffer.concat(chunks).toString('utf8');
      if (!text.trim()) { resolve({}); return; }
      try { resolve(JSON.parse(text)); } catch (e) { reject(e); }
    });
    req.on('error', (e) => { if (!done) { done = true; reject(e); } });
  });
}

function queryOf(req) {
  try { return new URL(req.url ?? '/', 'http://localhost').searchParams; } catch { return new URLSearchParams(); }
}

/* ------------------------------------------------------------------- runtime */

function createRuntime(config) {
  const rt = {
    config,
    runner: new Runner({ ttlMs: Number(config?.cacheTtlMs) > 0 ? Number(config.cacheTtlMs) : undefined }),
    factsPromise: null,
  };
  // Host facts are read once, lazily, and a failure here must never stop the
  // capabilities from running (mirrors the sibling plugin's hostFacts()).
  rt.factsPromise = (async () => {
    const chosen = await interpreter();
    let ownElevated = null;
    let user = '';
    let os = '';
    try {
      const out = await runProbe('host.ps1', {}, { timeout: 30_000 });
      ownElevated = out?.elevated ?? null;
      user = String(out?.user ?? '');
      os = String(out?.os ?? '');
    } catch { /* optional */ }
    return {
      interpreter: chosen ? `${chosen.bin} (PS ${chosen.major})` : '',
      elevatedSelf: ownElevated,
      user,
      os,
    };
  })();
  return rt;
}

/**
 * Combined elevation answer, recomputed per request.
 *
 * ONE channel for both halves (lib/elevation.js): `elevated` is true if this
 * process OR the resident broker holds an admin token, so a single UAC approval
 * flips both tabs and neither asks again. `elevatedSelf` keeps the raw fact.
 */
function elevationFacts(facts) {
  return {
    elevated: canActElevated(facts?.elevatedSelf === true),
    elevatedSelf: facts?.elevatedSelf ?? null,
    broker: brokerStatus(),
  };
}

/* ------------------------------------------------------------------ elevated */

const ELEVATED_TIMEOUT_MS = 180_000;
const UAC_CANCELLED = '你取消了 UAC 提权';

/**
 * Parameters for the elevated path. This deliberately does NOT reuse
 * sanitizeParams: winsettings ids look like `winsettings:dark-mode-apps`, and
 * sanitizeParams's `setting` pattern rejects the colon, so a setting change
 * would silently lose its target when run as admin. Everything else keeps the
 * same whitelist shape, and unknown keys are dropped rather than forwarded.
 */
function elevatedParams(raw) {
  const src = raw !== null && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const out = {};
  const arr = (v, max) => (Array.isArray(v) ? v.map(String).slice(0, max) : undefined);
  if (typeof src.dryRun === 'boolean') out.dryRun = src.dryRun;
  if (typeof src.purge === 'boolean') out.purge = src.purge;
  if (typeof src.undo === 'boolean') out.undo = src.undo;
  if (typeof src.action === 'string' && /^[a-z][a-z0-9-]{0,31}$/.test(src.action)) out.action = src.action;
  if (typeof src.target === 'string' && src.target.length <= 260) out.target = src.target;
  if (typeof src.clsid === 'string' && /^\{?[0-9A-Fa-f-]{8,40}\}?$/.test(src.clsid)) out.clsid = src.clsid;
  if (src.scope === 'machine' || src.scope === 'user') out.scope = src.scope;
  if (typeof src.setting === 'string' && /^[A-Za-z0-9_.:-]{1,80}$/.test(src.setting)) out.setting = src.setting;
  if (typeof src.appName === 'string' && src.appName.length <= 200) out.appName = src.appName;
  if (typeof src.value === 'string' || typeof src.value === 'number') out.value = String(src.value).slice(0, 2048);
  const paths = arr(src.paths, 50); if (paths) out.paths = paths;
  const keys = arr(src.keys, 100); if (keys) out.keys = keys;
  const ids = arr(src.ids, 200); if (ids) out.ids = ids;
  const targets = arr(src.targets, 60); if (targets) out.targets = targets;
  if (typeof src.root === 'string' && SCAN_ROOTS.some((r) => r.id === src.root)) out.root = src.root;
  return out;
}

/* -------------------------------------------------------------------- routes */

function mountRoutes(ctx, rt) {
  ctx.effect(() => {
    const disposers = [];
    const route = (entry) => { disposers.push(ctx.webServer.register(entry)); };
    const wrap = (spec, run) => route({
      kind: 'exact',
      path: spec.path,
      handler: async (req, res) => {
        if (req.method !== spec.method) { res.writeHead(405, { allow: spec.method }); res.end(); return; }
        if (!trusted(req, res)) return;
        try {
          await run(req, res);
        } catch (error) {
          json(res, 500, { error: String(error?.message ?? error) });
        }
      },
    });

    // The first paint must be instant, so /status never runs a scan: it reports
    // the catalogue and whatever is already cached, plus the host facts.
    wrap({ path: `${API}/status`, method: 'GET' }, async (_req, res) => {
      const facts = await rt.factsPromise;
      json(res, 200, {
        ok: true,
        name: 'dsh-windows-toolbox',
        version: '0.1.0',
        host: { ...facts, ...elevationFacts(facts) },
        capabilities: rt.runner.status(),
        // The catalogue is derived from capabilities.js, never hand-listed:
        // a capability added there shows up in the panel and the tools with no
        // edit here.
        catalogue: CAPABILITIES.map((c) => ({
          id: c.id, label: c.label, labelEn: c.labelEn, tagline: c.tagline,
          detail: c.detail, risk: c.risk, actions: c.actions, defaultParams: c.defaultParams,
          view: c.view, group: c.group, coverage: c.coverage, needsAdmin: c.needsAdmin === true,
        })),
        groups: CAPABILITY_GROUPS,
        junkGroups: JUNK_GROUPS,
        scanRoots: SCAN_ROOTS,
        risk: RISK,
      });
    });

    wrap({ path: `${API}/result`, method: 'GET' }, async (req, res) => {
      const id = queryOf(req).get('id') || '';
      if (!CAPABILITY_BY_ID.has(id)) { json(res, 400, { ok: false, error: `unknown capability: ${id}` }); return; }
      const hit = rt.runner.cached(id);
      json(res, 200, hit ?? { ok: false, id, error: 'not-scanned-yet', cached: false });
    });

    wrap({ path: `${API}/run`, method: 'POST' }, async (req, res) => {
      const body = await readJsonBody(req).catch(() => ({}));
      const id = String(body?.id ?? '');
      if (!CAPABILITY_BY_ID.has(id)) { json(res, 400, { ok: false, error: `unknown capability: ${id}` }); return; }
      const cap = CAPABILITY_BY_ID.get(id);
      // `run` is for the read-only verbs. Mutations have their own endpoints so
      // a stale page replaying a scan request can never change the machine.
      if (!cap.actions.includes('scan')) { json(res, 400, { ok: false, error: `${id} is not scannable` }); return; }
      const force = body?.force === true;
      const out = await rt.runner.ensure(id, body?.params ?? {}, { force });
      json(res, 200, out);
    });

    // The capabilities that expose a controllable fix all share one contract:
    // dry-run unless dryRun:false is explicit, and the probe itself re-validates
    // every target. Keeping one endpoint means the panel and the agent tool
    // cannot drift apart.
    wrap({ path: `${API}/apply`, method: 'POST' }, async (req, res) => {
      const body = await readJsonBody(req).catch(() => ({}));
      const id = String(body?.id ?? '');
      if (!CAPABILITY_BY_ID.has(id)) { json(res, 400, { ok: false, error: `unknown capability: ${id}` }); return; }
      const cap = CAPABILITY_BY_ID.get(id);
      // 'repair' and 'dnspick' are both apply-shaped verbs (they change things)
      // so they ride this route, but only the capabilities that declare each
      // verb may use it — the generic 'apply' branch must not become a way to
      // reach a verb the capability never advertised.
      const wanted = String(body?.params?.action ?? '');
      const wantsRepair = wanted === 'repair';
      const wantsDnsPick = wanted === 'dnspick';
      const allowed = wantsRepair
        ? cap.actions.includes('repair')
        : wantsDnsPick
          ? cap.actions.includes('dnspick')
          : cap.actions.includes('apply');
      if (!allowed) {
        json(res, 400, {
          ok: false,
          error: wantsRepair
            ? `${id} has no repair action`
            : wantsDnsPick
              ? `${id} has no dnspick action`
              : `${id} has no apply action`,
        });
        return;
      }
      const params = sanitizeParams(id, body?.params ?? {});
      const dryRun = params?.dryRun !== false;
      try {
        const out = await runProbe(cap.probe, { ...params, dryRun }, {
          // netdiag's repair runs `ipconfig /renew` (4-5 s) and can retry, so it
          // needs a longer budget than the registry-only fixes.
          timeout: cap.id === 'shredder' ? 120_000 : cap.id === 'netdiag' ? 240_000 : 150_000,
        });
        // A dry run must not touch the cached scan — otherwise the panel would
        // show the plan as if it were the machine's current state.
        if (!dryRun) rt.runner.clear(id);
        json(res, 200, { ...normalizeCapability(id, out), ok: out?.ok !== false, dryRun });
      } catch (error) {
        json(res, 200, { ok: false, dryRun, error: String(error?.message ?? error) });
      }
    });

    // Elevation, done once for both halves: this process stays unelevated and
    // says so, while lib/elevation.js keeps ONE resident elevated broker
    // (probes/broker.ps1) that the user approved a single time. Every later
    // elevated job — from this tab or the other one — goes to that same process,
    // so no second prompt appears. A dismissed prompt is reported as `cancelled`
    // with HTTP 200: a user saying "no" is an answer, not a server error.
    wrap({ path: `${API}/elevated`, method: 'POST' }, async (req, res) => {
      const body = await readJsonBody(req).catch(() => ({}));

      // Probe mode is the panel's "request elevation" button: start (or adopt)
      // the broker, change nothing. This is the ONE place a UAC dialog appears.
      if (body?.probe === true) {
        let ready;
        try {
          ready = await ensureBroker();
        } catch (error) {
          json(res, 200, { ok: false, cancelled: false, elevated: false, error: String(error?.message ?? error) });
          return;
        }
        const cancelled = ready?.cancelled === true;
        if (ready?.ok !== true) {
          json(res, 200, {
            ok: false,
            probe: true,
            cancelled,
            elevated: false,
            error: cancelled ? '' : String(ready?.error ?? ''),
            message: cancelled ? UAC_CANCELLED : String(ready?.error ?? ''),
          });
          return;
        }
        const broker = brokerStatus();
        json(res, 200, {
          ok: true,
          probe: true,
          cancelled: false,
          elevated: ready?.elevated === true,
          reused: ready?.reused === true,
          user: String(broker.user ?? ''),
          broker,
        });
        return;
      }

      const id = String(body?.id ?? '');
      if (!CAPABILITY_BY_ID.has(id)) {
        json(res, 400, { ok: false, cancelled: false, error: `unknown capability: ${id}` });
        return;
      }
      const cap = CAPABILITY_BY_ID.get(id);
      const params = elevatedParams(body?.params);
      const dryRun = params.dryRun !== false;
      const probeFile = probePath(cap.probe);
      // Probes default to dryRun:true on their own; state it explicitly so the
      // elevated run can never be a mutation the caller did not ask for.
      const effective = { ...params, dryRun };
      try {
        const run = await runElevated(probeFile, effective, { timeout: ELEVATED_TIMEOUT_MS });
        if (run.cancelled === true) {
          json(res, 200, { ok: false, cancelled: true, id, message: UAC_CANCELLED });
          return;
        }
        if (run.ok !== true || !run.out) {
          json(res, 200, { ok: false, cancelled: false, id, timeout: run.timeout === true, error: run.error });
          return;
        }
        const out = run.out;
        if (!dryRun) rt.runner.clear(id);
        json(res, 200, {
          ...normalizeCapability(id, out),
          ok: out?.ok !== false,
          cancelled: false,
          elevated: true,
          dryRun,
        });
      } catch (error) {
        json(res, 200, { ok: false, cancelled: false, id, error: String(error?.message ?? error) });
      }
    });

    wrap({ path: `${API}/clean`, method: 'POST' }, async (req, res) => {
      const body = await readJsonBody(req).catch(() => ({}));
      // Default is a dry run. A caller must say dryRun:false explicitly, and the
      // panel's confirm dialog is what sends that — there is no way to clean by
      // passing an empty body.
      const dryRun = body?.dryRun !== false;
      const targets = Array.isArray(body?.targets) ? body.targets.map(String) : [];
      try {
        // Both branches go straight to the probe, never through Runner: a dry run
        // over a SUBSET of targets must not overwrite the cached full scan (the
        // panel would then show four targets as if the other twelve vanished).
        const out = await runProbe('junk.ps1', {
          action: 'clean', dryRun, targets,
        }, { timeout: 240_000 });
        if (dryRun) {
          json(res, 200, { ...normalizeCapability('junk', out), ok: true, dryRun: true });
          return;
        }
        rt.runner.clear('junk');
        json(res, 200, { ...out, ok: out?.ok !== false, dryRun: false });
      } catch (error) {
        json(res, 200, { ok: false, dryRun, error: String(error?.message ?? error) });
      }
    });

    return () => { for (const d of disposers) { try { d(); } catch { /* noop */ } } };
  }, 'dsh-windows-toolbox: routes');
}

/* --------------------------------------------------------------------- tools */

function renderResult(_args, value) {
  return [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }];
}
const OUTPUT = { schema: { type: 'object' }, render: renderResult };

function clampInt(raw, min, max, fallback) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}

/** Human bytes, so a tool result is readable without post-processing. */
function human(bytes) {
  const n = Number(bytes);
  if (!Number.isFinite(n) || n <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
}

function mountTools(ctx, rt) {
  ctx.effect(() => {
    const tools = ctx.tools;
    if (tools === undefined || typeof tools.register !== 'function') return () => {};
    const disposers = [];
    const reg = (def) => {
      try { disposers.push(tools.register(def)); } catch (e) { console.warn('[dsh-windows-toolbox:toolbox] tool register failed:', e?.message); }
    };

    reg({
      name: 'tb360_status',
      description: `Overview of this Windows toolbox: ${CAPABILITIES.length} maintenance capabilities grouped as cleanup / system / network / apps, each with its risk class, coverage (full | partial | readonly | blocked), whether a result is already cached, and host facts (elevated?, PowerShell interpreter). Call this first; it runs no scan and returns instantly.`,
      parameters: { type: 'object', properties: {}, required: [] },
      output: OUTPUT,
      async execute() {
        const facts = await rt.factsPromise;
        return {
          ok: true,
          host: { ...facts, ...elevationFacts(facts) },
          groups: CAPABILITY_GROUPS,
          capabilities: rt.runner.status(),
        };
      },
    });

    reg({
      name: 'tb360_scan',
      description: 'Run ONE maintenance scan and return its findings. Most capabilities are read-only: junk measures cleanable caches (never deletes — use tb360_clean), bigfiles finds the largest files under a root, dupfiles finds byte-identical duplicates by SHA256, netdiag walks link -> IP -> gateway -> DNS -> internet and reports the first broken step, health checks disks/memory/services/Devices/Defender/updates. The rest are inspection reports whose row status says ok/warn/bad/info, and a `skip` row always explains why it could not be measured (usually needs admin). Results are cached for 5 minutes; pass force:true to rescan.',
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', enum: SCANNABLE_IDS, description: 'Which capability to run' },
          root: { type: 'string', description: 'For bigfiles / dupfiles: user | downloads | desktop | documents | pictures | c: | d: | e:' },
          minMb: { type: 'number', description: 'For bigfiles: minimum file size in MB (default 100)' },
          minKb: { type: 'number', description: 'For dupfiles: minimum file size in KB (default 1024)' },
          limit: { type: 'number', description: 'Max rows/groups to return' },
          force: { type: 'boolean', description: 'true = bypass the 5-minute cache and rescan' },
        },
        required: ['id'],
      },
      output: OUTPUT,
      async execute(args) {
        const id = String(args?.id ?? '');
        if (!CAPABILITY_BY_ID.has(id)) return { ok: false, error: `unknown capability: ${id}`, choices: SCANNABLE_IDS };
        if (!CAPABILITY_BY_ID.get(id).actions.includes('scan')) return { ok: false, error: `${id} is not scannable` };
        const params = {};
        if (args?.root !== undefined) params.root = String(args.root);
        if (args?.minMb !== undefined) params.minMb = clampInt(args.minMb, 1, 100_000, 100);
        if (args?.minKb !== undefined) params.minKb = clampInt(args.minKb, 1, 1_000_000, 1024);
        if (args?.limit !== undefined) params.limit = clampInt(args.limit, 1, 2000, 200);
        const out = await rt.runner.ensure(id, params, { force: args?.force === true });
        if (!out.ok) return { ok: false, id, error: out.error };
        return {
          ok: true,
          id,
          cached: out.cached === true,
          itemCount: out.items?.length ?? 0,
          summary: out.meta?.summary ?? null,
          meta: out.meta,
          items: out.items,
        };
      },
    });

    reg({
      name: 'tb360_clean',
      description: 'Clean junk targets. ALWAYS a dry run unless dryRun:false is passed explicitly: the dry run returns exactly what would be freed (per target, with byte counts) and changes nothing. Only the fixed whitelist in lib/probes/junklib.ps1 can be touched — a target is named by id, never by path, and cache directories themselves are preserved (only their contents are removed). Targets needing admin are skipped with a message when the shell is not elevated. Get ids from tb360_scan with id:"junk".',
      parameters: {
        type: 'object',
        properties: {
          targets: { type: 'array', items: { type: 'string' }, description: 'Target ids, e.g. ["user-temp","edge-cache"]. Omit for all.' },
          dryRun: { type: 'boolean', description: 'false = actually delete (default true = report only)' },
        },
        required: [],
      },
      output: OUTPUT,
      async execute(args) {
        const targets = Array.isArray(args?.targets) ? args.targets.map(String) : [];
        const dryRun = args?.dryRun !== false;
        try {
          const out = await runProbe('junk.ps1', { action: 'clean', dryRun, targets }, { timeout: 240_000 });
          if (!dryRun) rt.runner.clear('junk');
          const totalBytes = Number(out?.totalBytes ?? 0);
          // `undefined` is not representable in JSON, and the tool output must be
          // lossless JSON (`invalid output: value is not lossless JSON` was the
          // real failure). Emit an empty string for the branch that does not
          // apply — the field stays present so callers can rely on the shape.
          return {
            ok: out?.ok !== false,
            dryRun,
            elevated: out?.elevated === true,
            wouldFree: dryRun ? human(totalBytes) : '',
            freed: dryRun ? '' : human(Number(out?.freed ?? 0)),
            deleted: Number(out?.deleted ?? 0),
            skipped: Number(out?.skipped ?? 0),
            messages: out?.messages ?? [],
            targets: (out?.targets ?? []).map((t) => ({
              id: t.id, label: t.label, bytes: t.bytes, files: t.files,
              blocked: t.blocked === true, needsAdmin: t.needsAdmin === true,
            })),
          };
        } catch (error) {
          return { ok: false, error: String(error?.message ?? error) };
        }
      },
    });

    reg({
      name: 'tb360_apply',
      description: `Run one of the controllable fixes: ${APPLYABLE_IDS.join(' / ')}${REPAIRABLE_IDS.length ? `, plus the network repair verbs: ${REPAIRABLE_IDS.join(' / ')} (pass action:"repair")` : ''}${DNSPICK_IDS.length ? `, and the DNS switch: ${DNSPICK_IDS.join(' / ')} (pass action:"dnspick" with server)` : ''}. ALWAYS a dry run unless dryRun:false is passed explicitly — the dry run reports exactly what would change (and the undo record) without touching anything. homepage repairs hijacked browser start pages; backup exports chosen registry keys to %LOCALAPPDATA%\\dsh-windows-toolbox\\regbackup; contextmenu enables/disables a shell-extension CLSID; shredder overwrites files the caller names one by one (never a directory, never a wildcard); netdiag action:"dnspick" switches the resolver list to one of the five published servers or back to automatic. Pass the capability's own parameters, e.g. {id:"contextmenu", params:{action:"disable", clsid:"{...}", scope:"user"}}.`,
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', enum: WRITABLE_IDS, description: 'Which apply-capable capability' },
          action: { type: 'string', description: 'Capability-specific verb, e.g. disable | enable | export | repair | dnspick | shred' },
          dryRun: { type: 'boolean', description: 'false = actually change things (default true = report the plan only)' },
          clsid: { type: 'string', description: 'For contextmenu: the shell-extension CLSID' },
          scope: { type: 'string', enum: ['machine', 'user'], description: 'For contextmenu: which approved-key to write' },
          keys: { type: 'array', items: { type: 'string' }, description: 'For backup: registry key paths to export' },
          paths: { type: 'array', items: { type: 'string' }, description: 'For shredder: absolute file paths, listed one by one' },
          target: { type: 'string', description: 'For homepage: which start page slot to repair' },
          value: { type: 'string', description: 'For homepage: the URL/value to write' },
          server: { type: 'string', description: 'For netdiag action:"dnspick": 223.5.5.5 | 119.29.29.29 | 1.1.1.1 | 8.8.8.8 | 114.114.114.114 | auto' },
        },
        required: ['id'],
      },
      output: OUTPUT,
      async execute(args) {
        const id = String(args?.id ?? '');
        if (!CAPABILITY_BY_ID.has(id)) return { ok: false, error: `unknown capability: ${id}`, choices: APPLYABLE_IDS };
        const cap = CAPABILITY_BY_ID.get(id);
        const wanted = String(args?.action ?? '');
        const wantsRepair = wanted === 'repair';
        const wantsDnsPick = wanted === 'dnspick';
        const allowed = wantsRepair
          ? cap.actions.includes('repair')
          : wantsDnsPick
            ? cap.actions.includes('dnspick')
            : cap.actions.includes('apply');
        if (!allowed) return { ok: false, error: `${id} has no ${wantsRepair ? 'repair' : wantsDnsPick ? 'dnspick' : 'apply'} action`, choices: WRITABLE_IDS };
        const { id: _drop, ...rest } = args ?? {};
        const params = sanitizeParams(id, rest);
        const dryRun = params.dryRun !== false;
        try {
          const out = await runProbe(cap.probe, { ...params, dryRun }, { timeout: id === 'shredder' ? 120_000 : id === 'netdiag' ? 240_000 : 150_000 });
          if (!dryRun) rt.runner.clear(id);
          const normalized = normalizeCapability(id, out);
          return {
            ok: out?.ok !== false,
            id,
            dryRun,
            itemCount: normalized.items?.length ?? 0,
            meta: normalized.meta,
            items: normalized.items,
          };
        } catch (error) {
          return { ok: false, id, dryRun, error: String(error?.message ?? error) };
        }
      },
    });

    reg({
      name: 'tb360_elevated',
      description: `Run one capability's probe as administrator. Use it when a read-only report says a row was skipped for lack of admin, or when a fix/cleanup must write HKLM. The host process itself stays unelevated — /status keeps reporting elevatedSelf:false, because that is the truth about this process — but the plugin holds ONE resident elevated broker (probes/broker.ps1, started by lib/elevation.js), so the user approves a single UAC prompt per session and every later privileged action rides that same token. If the broker is already running, this call raises no prompt at all. ALWAYS a dry run unless dryRun:false is passed explicitly. If the user dismisses the prompt the result is {ok:false, cancelled:true, message:"你取消了 UAC 提权"} — that is not an error, do not retry it blindly. Capabilities: ${ALL_IDS.join(' / ')}.`,
      parameters: {
        type: 'object',
        properties: {
          id: { type: 'string', enum: ALL_IDS, description: 'Which capability to run elevated' },
          action: { type: 'string', description: 'Capability-specific verb, e.g. scan | fix | set | disable | enable | export | upgrade | leftover | migrate | perm' },
          dryRun: { type: 'boolean', description: 'false = actually change things (default true = plan only)' },
          clsid: { type: 'string', description: 'For contextmenu: the FULL shell-extension CLSID' },
          scope: { type: 'string', enum: ['machine', 'user'], description: 'For contextmenu: which approved-key to write' },
          keys: { type: 'array', items: { type: 'string' }, description: 'For backup: registry key paths to export' },
          paths: { type: 'array', items: { type: 'string' }, description: 'For shredder: absolute file paths, one by one' },
          ids: { type: 'array', items: { type: 'string' }, description: 'For tweaks: tweak ids to apply/revert' },
          setting: { type: 'string', description: 'For winsettings: the full setting id, e.g. winsettings:dark-mode-apps' },
          appName: { type: 'string', description: 'For softmgr leftover: the application name' },
          target: { type: 'string', description: 'For homepage: ie-start | ie-search' },
          value: { type: 'string', description: 'For winsettings / homepage: the new value' },
          targets: { type: 'array', items: { type: 'string' }, description: 'For junk: target ids to clean' },
        },
        required: ['id'],
      },
      output: OUTPUT,
      async execute(args) {
        const id = String(args?.id ?? '');
        if (!CAPABILITY_BY_ID.has(id)) return { ok: false, error: `unknown capability: ${id}`, choices: ALL_IDS };
        const cap = CAPABILITY_BY_ID.get(id);
        const { id: _drop, ...rest } = args ?? {};
        const params = elevatedParams(rest);
        const dryRun = params.dryRun !== false;
        const run = await runElevated(probePath(cap.probe), { ...params, dryRun }, { timeout: ELEVATED_TIMEOUT_MS });
        if (run.cancelled === true) return { ok: false, id, cancelled: true, message: UAC_CANCELLED };
        if (run.ok !== true || !run.out) {
          return { ok: false, id, cancelled: false, timeout: run.timeout === true, error: run.error };
        }
        if (!dryRun) rt.runner.clear(id);
        const normalized = normalizeCapability(id, run.out);
        return {
          ok: run.out?.ok !== false,
          id,
          cancelled: false,
          dryRun,
          elevated: true,
          itemCount: normalized.items?.length ?? 0,
          meta: normalized.meta,
          items: normalized.items,
        };
      },
    });

    return () => { for (const dispose of disposers) { try { dispose(); } catch { /* noop */ } } };
  }, 'dsh-windows-toolbox: agent tools');
}

/* ---------------------------------------------------------------- host apply */

export function mountToolbox(ctx, config) {
  const rt = createRuntime(config ?? {});
  // Each service is injected independently so a missing one cannot suppress the
  // whole plugin (mirrors dsh-source-inbox:1013-1024).
  ctx.inject(['webServer'], (webCtx) => mountRoutes(webCtx, rt));
  ctx.inject(['tools'], (toolsCtx) => mountTools(toolsCtx, rt));
  // Stop the resident elevated broker when the plugin unloads. The manage half
  // registers the same disposer; stopping twice is harmless (stopBroker() is a
  // no-op once state.pid is cleared), and leaving an admin process running after
  // the panel is gone is not something a plugin should do.
  ctx.effect(() => () => { try { stopBroker(); } catch { /* noop */ } }, 'dsh-windows-toolbox: broker lifecycle');
}
