/**
 * dsh-windows-toolbox — Host half.
 *
 * Reads every place Windows loads something from (services, scheduled tasks,
 * autostart entries, shell extensions, installed programs, AppX/MSIX packages,
 * drivers), normalizes them into one shape, and exposes:
 *
 *   GET  /dsh-windows-toolbox/api/manage/status   — host facts + per-source summary
 *   GET  /dsh-windows-toolbox/api/manage/entries  — the unified list (filterable, ?lang=zh|en)
 *   GET  /dsh-windows-toolbox/api/manage/detail   — one entry with its raw probe row (?lang=zh|en)
 *   POST /dsh-windows-toolbox/api/manage/refresh   — re-run probes, optionally forced
 *   POST /dsh-windows-toolbox/api/manage/action    — enable / disable / rollback / uninstall
 *   POST /dsh-windows-toolbox/api/manage/repair    — system-repair checks: scan / fix
 *   POST /dsh-windows-toolbox/api/manage/elevated  — run one action through a real UAC prompt
 *
 *   tools: wpm_status, wpm_list, wpm_detail, wpm_refresh, wpm_action, wpm_repair,
 *          wpm_elevated
 *
 * Elevation split (why two endpoints): actions.ps1 answers "this needs admin"
 * with needsAdmin/canElevate instead of trying to raise a prompt itself, and
 * never contains a RunAs call. /api/elevated is the only code path that shows a
 * UAC dialog: probes/elevated.ps1 starts an elevated child and hands it to
 * actions.ps1. A cancelled prompt comes back as {ok:false,cancelled:true} with
 * HTTP 200 — a user clicking "No" is an answer, not a server error.
 *
 * Uninstall is destructive and irreversible: program / appx / drv carry exactly
 * one verb (`uninstall`), and the probe — not this layer — decides per row
 * whether that row may be removed.
 *
 * The five hooks every capability is described by live in lib/sources.js:
 * detect / enable / disable / verify / rollback.
 */

import { SOURCES, SOURCE_BY_ID, RISK } from './sources.js';
import { Inventory } from './inventory.js';
import { sortEntries } from './normalize.js';
import { explainEntry } from './explain.js';
import { runProbe, interpreter, probePath } from './ps.js';
import { runElevated, brokerStatus, canActElevated, ensureBroker, stopBroker } from './elevation.js';

const API = '/dsh-windows-toolbox/api/manage';

/**
 * Every verb /api/action and wpm_action speak. `uninstall` is the irreversible
 * one; a program/appx/drv row is uninstalled, never disabled.
 */
const ACTIONS = ['enable', 'disable', 'rollback', 'uninstall'];

/**
 * Budget for one probe run of actions.ps1.
 *
 * actions.ps1 gives an uninstaller 120 s of its own ($UNINSTALL_TIMEOUT_SEC)
 * because that is how long an interactive uninstall wizard needs. A shorter
 * outer budget here would kill the probe in the middle of a legitimate
 * uninstall and report it as a failure, so the outer budget has to outlast the
 * inner one.
 */
const ACTION_TIMEOUT_MS = 180_000;

/**
 * Budget for one run of probes/elevated.ps1, which waits on a UAC prompt (a
 * human deciding) and then on actions.ps1. Never shorter than
 * ACTION_TIMEOUT_MS, or the elevated path would time out where the direct path
 * would have waited.
 */
const ELEVATED_TIMEOUT_MS = 180_000;

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
  const local = bare(String(localAddress).toLowerCase());
  const hn = bare(hostname.toLowerCase());
  return hn === local;
}
function originTrusted(origin, localAddress) {
  if (!origin || !origin.trim()) return true;
  try {
    const u = new URL(origin);
    return hostMatchesListener(u.host, localAddress);
  } catch { return false; }
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

/**
 * Host facts, read once. Kept separate from the inventory because these do not
 * change while the panel is open, and because a failure here must not stop the
 * the enumerations from working.
 *
 * `elevatedSelf` is the RAW fact ("does this process hold an admin token") and is
 * deliberately NOT what the panel sees: it would stay false forever, so the
 * panel would keep offering a button the user already pressed. The elevation
 * answer is computed per request (see elevationFacts()) because it changes the
 * moment the broker starts or dies.
 */
async function hostFacts() {
  const chosen = await interpreter();
  let ownElevated = null;
  let user = '';
  let os = '';
  try {
    const out = await runProbe('host.ps1', {});
    ownElevated = out?.elevated ?? null;
    user = String(out?.user ?? '');
    os = String(out?.os ?? '');
  } catch {
    /* host.ps1 is optional; the panel still works without it */
  }
  return {
    interpreter: chosen ? `${chosen.bin} (PS ${chosen.major})` : '',
    elevatedSelf: ownElevated,
    user,
    os,
  };
}

/**
 * The combined elevation answer, recomputed on every /status.
 *
 * ONE channel for both halves: `elevated` is true if either this process or the
 * resident broker can write privileged things right now, so approving UAC once
 * flips both tabs to "elevated" and neither offers the button again.
 */
function elevationFacts(facts) {
  const broker = brokerStatus();
  return {
    elevated: canActElevated(facts?.elevatedSelf === true),
    elevatedSelf: facts?.elevatedSelf ?? null,
    broker,
  };
}

function createRuntime(config) {
  const inventory = new Inventory({ ttlMs: config?.ttlMs });
  const factsPromise = hostFacts().catch(() => ({ interpreter: '', elevatedSelf: null, user: '', os: '' }));
  return { inventory, factsPromise };
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

    wrap({ path: `${API}/status`, method: 'GET' }, async (_req, res) => {
      const facts = await rt.factsPromise;
      // First call populates the cache; a warm call returns immediately. This is
      // what makes the panel's first paint show real numbers instead of an
      // empty table: the client only asks for /status once.
      const fill = await rt.inventory.ensure({});
      json(res, 200, {
        ok: true,
        name: 'dsh-windows-toolbox',
        version: '0.1.0',
        host: { ...facts, ...elevationFacts(facts) },
        sources: rt.inventory.summary(),
        total: rt.inventory.total(),
        elapsedMs: fill.elapsedMs,
        ran: fill.ran,
        risk: RISK,
      });
    });

    wrap({ path: `${API}/entries`, method: 'GET' }, async (req, res) => {
      const q = queryOf(req);
      const source = q.get('source') || '';
      const wanted = q.get('enabled');       // 'true' | 'false' | '' (any)
      const risk = q.get('risk') || '';
      const text = (q.get('q') || '').toLowerCase();
      const limit = clampInt(q.get('limit'), 1, 5000, 2000);
      const lang = langOf(q);

      await rt.inventory.ensure({});
      let rows = source ? rt.inventory.entriesOf(source) : rt.inventory.allEntries();
      if (wanted === 'true') rows = rows.filter((e) => e.enabled === true);
      else if (wanted === 'false') rows = rows.filter((e) => e.enabled === false);
      if (risk) rows = rows.filter((e) => e.risk === risk);
      if (text) {
        rows = rows.filter((e) =>
          e.name.toLowerCase().includes(text)
          || e.path.toLowerCase().includes(text)
          || e.publisher.toLowerCase().includes(text));
      }
      const total = rows.length;
      // Language is applied AFTER filtering and slicing so `total`/`shown` keep
      // their meaning, and onto mapped copies: the cache stores one canonical
      // (default-language) row set and must not be rewritten by a request.
      const page = rows.slice(0, limit).map((e) => withLang(e, lang));
      json(res, 200, { total, shown: Math.min(total, limit), rows: page });
    });

    wrap({ path: `${API}/detail`, method: 'GET' }, async (req, res) => {
      const q = queryOf(req);
      const id = q.get('id') || '';
      if (!id) { json(res, 400, { error: 'missing id' }); return; }
      await rt.inventory.ensure({});
      const hit = rt.inventory.allEntries().find((e) => e.id === id);
      if (!hit) { json(res, 404, { error: 'no such entry', id }); return; }
      json(res, 200, { ok: true, entry: withLang(hit, langOf(q)) });
    });

    wrap({ path: `${API}/refresh`, method: 'POST' }, async (req, res) => {
      const body = await readJsonBody(req).catch(() => ({}));
      const sources = Array.isArray(body?.sources) ? body.sources.filter((s) => SOURCE_BY_ID.has(s)) : undefined;
      // force=true is the explicit refresh button; force=false only fills what
      // is stale. Refresh runs in parallel because the user asked for it and is
      // watching a spinner (cold fill stays sequential, see inventory.js).
      const out = await rt.inventory.ensure({ sources, force: true, parallel: true });
      json(res, 200, { ok: true, ...out, sources: rt.inventory.summary(), total: rt.inventory.total() });
    });

    wrap({ path: `${API}/action`, method: 'POST' }, async (req, res) => {
      const body = await readJsonBody(req).catch(() => ({}));
      const source = String(body?.source ?? '');
      const action = String(body?.action ?? '');
      const target = body?.target ?? {};
      const undo = body?.undo ?? null;
      const dryRun = body?.dryRun === true;

      if (!SOURCE_BY_ID.has(source)) { json(res, 400, { ok: false, error: `unknown source: ${source}` }); return; }
      if (!ACTIONS.includes(action)) {
        json(res, 400, { ok: false, error: `unknown action: ${action}` }); return;
      }
      if (!dryRun && action !== 'rollback' && !target?.key && !target?.name && !target?.taskName) {
        json(res, 400, { ok: false, error: 'missing target' }); return;
      }

      // The probe re-checks every safety rule itself (protected services, kernel
      // drivers, "is this source even writable") — the JS layer does not
      // duplicate that list, so there is exactly one authority on what is legal.
      let out;
      try {
        out = await runProbe('actions.ps1', { action, source, target, undo, dryRun }, { timeout: ACTION_TIMEOUT_MS });
      } catch (error) {
        json(res, 200, { ok: false, changed: false, error: String(error?.message ?? error) });
        return;
      }

      // A successful mutation invalidates that source's cache, so the panel's
      // re-read shows the new state instead of the pre-change snapshot.
      if (out?.ok && out?.changed && !dryRun) {
        rt.inventory.clear();
      }
      json(res, 200, { ...out, dryRun });
    });

    // ------------------------------------------------------------------------
    // POST /api/elevated — the ONLY path that shows a UAC prompt.
    //
    // Shared with the toolbox half: both call lib/elevation.js, which keeps ONE
    // resident elevated broker (lib/probes/broker.ps1). The user approves UAC
    // once; every later elevated job from either tab is handed to that same
    // process, so no second prompt appears until it exits or goes idle.
    //
    // Same body as /api/action. Refused cases are answers, not errors:
    //   * the user cancels the UAC dialog  → 200 {ok:false,cancelled:true}
    //   * the broker never answers         → 200 {ok:false,timeout:true}
    //   * the probe itself throws → 200 {ok:false,error}
    // None of those may become a 500: a 500 tells the panel "the server broke",
    // which is exactly the lie that makes a user retry a destructive action.
    //
    // A dry run never reaches here — the probe refuses it, because a preview
    // must not put a consent dialog in front of the user.
    // ------------------------------------------------------------------------
    wrap({ path: `${API}/elevated`, method: 'POST' }, async (req, res) => {
      const body = await readJsonBody(req).catch(() => ({}));

      // Probe mode: prove the elevation channel works without asking the caller
      // to name a target. This is what the panel's "request elevation" button
      // sends — it starts (or adopts) the broker, changes nothing, and is the
      // one and only UAC prompt the user should ever see.
      if (body?.probe === true) {
        let ready;
        try {
          ready = await ensureBroker();
        } catch (error) {
          json(res, 200, { ok: false, changed: false, elevated: false, cancelled: false, error: String(error?.message ?? error) });
          return;
        }
        if (ready?.ok !== true) {
          const cancelled = ready?.cancelled === true;
          json(res, 200, {
            ok: false,
            changed: false,
            probe: true,
            elevated: false,
            cancelled,
            error: cancelled ? '' : String(ready?.error ?? ''),
            message: cancelled ? '你取消了 UAC 提权' : String(ready?.error ?? ''),
          });
          return;
        }
        const broker = brokerStatus();
        json(res, 200, {
          ok: true,
          changed: false,
          probe: true,
          elevated: ready?.elevated === true,
          cancelled: false,
          reused: ready?.reused === true,
          user: String(broker.user ?? ''),
          broker,
        });
        return;
      }

      const source = String(body?.source ?? '');
      const action = String(body?.action ?? '');
      const target = body?.target ?? {};
      const undo = body?.undo ?? null;
      const dryRun = body?.dryRun === true;

      if (!SOURCE_BY_ID.has(source)) { json(res, 400, { ok: false, error: `unknown source: ${source}` }); return; }
      if (!ACTIONS.includes(action)) {
        json(res, 400, { ok: false, error: `unknown action: ${action}` }); return;
      }
      if (dryRun) {
        // Elevation buys write rights; a preview needs none. Point the caller at
        // the cheap path instead of raising a prompt for nothing.
        json(res, 200, { ok: false, changed: false, elevated: false, error: 'dry-run-needs-no-elevation' });
        return;
      }
      if (action !== 'rollback' && !target?.key && !target?.name && !target?.taskName) {
        json(res, 400, { ok: false, error: 'missing target' }); return;
      }

      let run;
      try {
        run = await runElevated(probePath('actions.ps1'), { action, source, target, undo, dryRun: false }, { timeout: ELEVATED_TIMEOUT_MS });
      } catch (error) {
        // A launcher that could not even start is still an answer, not a crash.
        json(res, 200, { ok: false, changed: false, elevated: false, cancelled: false, error: String(error?.message ?? error) });
        return;
      }

      if (run?.cancelled === true) {
        json(res, 200, { ok: false, changed: false, elevated: false, cancelled: true, message: '你取消了 UAC 提权' });
        return;
      }
      if (run?.ok !== true || !run?.out) {
        json(res, 200, {
          ok: false,
          changed: false,
          elevated: run?.elevated === true,
          cancelled: false,
          timeout: run?.timeout === true,
          error: String(run?.error ?? 'elevated run produced no result'),
        });
        return;
      }

      const out = run.out;
      if (out?.ok && out?.changed) rt.inventory.clear();
      json(res, 200, { ...out, elevated: true, requested: { source, action } });
    });

    // Stop the resident broker when this plugin unloads: leaving an elevated
    // process behind after the panel is gone is not something a plugin should do.
    ctx.effect(() => () => { try { stopBroker(); } catch { /* noop */ } }, 'dsh-windows-toolbox: broker lifecycle');

    // ------------------------------------------------------------------------
    // POST /api/repair — run the configuration-drift checks, optionally fixing.
    //
    // Separate from /action on purpose. /action addresses ONE row in the
    // unified list and speaks the enable/disable/rollback vocabulary of a
    // registration point. A repair finding is not a row that can be switched
    // off: fixing it means re-asserting a whole setting (rewrite Start Page,
    // delete a dead Run value), and the safe unit is the check, not the row.
    // Trying to express that in /action would have meant faking a target.
    //
    // dryRun defaults to TRUE: an accidental POST must not write anything.
    // ------------------------------------------------------------------------
    wrap({ path: `${API}/repair`, method: 'POST' }, async (req, res) => {
      const body = await readJsonBody(req).catch(() => ({}));
      const action = body?.action === 'fix' ? 'fix' : 'scan';
      const dryRun = body?.dryRun !== false;
      const ids = Array.isArray(body?.ids) ? body.ids.map((s) => String(s)) : [];

      let out;
      try {
        out = await runProbe('repair.ps1', { action, dryRun, ids }, { timeout: 120_000 });
      } catch (error) {
        json(res, 200, { ok: false, action, dryRun, error: String(error?.message ?? error) });
        return;
      }

      // A non-dry fix may have written registry values or a hosts snapshot, so
      // the cached row set is no longer trustworthy.
      if (out?.ok && !dryRun && action === 'fix') rt.inventory.clear();
      json(res, 200, { ...out, action, dryRun });
    });

    return () => { for (const d of disposers) { try { d(); } catch { /* noop */ } } };
  }, 'dsh-windows-toolbox: routes');
}

/**
 * Requested display language.
 *
 * Only 'zh' and 'en' exist; anything else falls back to 'zh' (the plugin's
 * default) rather than throwing, so a stray `?lang=fr` cannot 500 the panel.
 */
function langOf(q) {
  return q.get('lang') === 'en' ? 'en' : 'zh';
}

/**
 * Re-derive the explanation in the requested language.
 *
 * Returns a NEW object: the inventory cache holds one canonical row set shared
 * by every request, so mutating `entry.explain` here would leak one client's
 * language into the next client's response.
 */
function withLang(entry, lang) {
  if (!entry) return entry;
  let explain = null;
  try {
    explain = explainEntry(entry, lang);
  } catch {
    explain = null;
  }
  return { ...entry, explain };
}

function clampInt(raw, min, max, fallback) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}

/* --------------------------------------------------------------------- tools */

function renderResult(_args, value) {
  return [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }];
}
const OUTPUT = { schema: { type: 'object' }, render: renderResult };

function mountTools(ctx, rt) {
  ctx.effect(() => {
    const tools = ctx.tools;
    if (tools === undefined || typeof tools.register !== 'function') return () => {};
    const disposers = [];
    const reg = (def) => {
      try { disposers.push(tools.register(def)); } catch (e) { console.warn('[dsh-windows-toolbox:manage] tool register failed:', e?.message); }
    };

    reg({
      name: 'wpm_status',
      description: 'Overview of this Windows machine\'s plugin/extension registration points: services, scheduled tasks, autostart entries, shell extensions, installed programs, AppX/MSIX packages, driver packages, firewall rules, IFEO image-hijack entries, file associations and credential providers. Returns per-source counts (total/enabled/disabled) plus the host facts (elevated?, interpreter). Call this first.',
      parameters: { type: 'object', properties: {}, required: [] },
      output: OUTPUT,
      async execute() {
        const facts = await rt.factsPromise;
        const fill = await rt.inventory.ensure({});
        return {
          ok: true,
          host: facts,
          total: rt.inventory.total(),
          elapsedMs: fill.elapsedMs,
          ran: fill.ran,
          sources: rt.inventory.summary(),
        };
      },
    });

    reg({
      name: 'wpm_list',
      description: 'List entries from the unified index (bounded). Filter by source ("svc"|"task"|"autorun"|"com"|"program"|"appx"|"drv"|"firewall"|"ifeo"|"fileexts"|"credprov"), by enabled state, by risk class, or by a substring of name/path/publisher. Returns id, name, state, enabled, risk, path for each row — never the full probe payload; use wpm_detail for that.',
      parameters: {
        type: 'object',
        properties: {
          source: { type: 'string', description: 'svc | task | autorun | com | program | appx | drv | firewall | ifeo | fileexts | credprov' },
          enabled: { type: 'boolean', description: 'true = only currently-on entries, false = only currently-off' },
          risk: { type: 'string', enum: ['readonly', 'reversible', 'destructive', 'blocked'], description: 'Risk class filter' },
          q: { type: 'string', description: 'Case-insensitive substring over name / path / publisher' },
          limit: { type: 'number', description: 'Max rows (1-5000, default 200)' },
        },
        required: [],
      },
      output: OUTPUT,
      async execute(args) {
        const source = String(args?.source ?? '');
        const risk = String(args?.risk ?? '');
        const text = String(args?.q ?? '').toLowerCase();
        const limit = clampInt(args?.limit ?? 200, 1, 5000, 200);
        if (source && !SOURCE_BY_ID.has(source)) return { ok: false, error: `unknown source: ${source}` };

        await rt.inventory.ensure({});
        let rows = source ? rt.inventory.entriesOf(source) : rt.inventory.allEntries();
        if (args?.enabled === true) rows = rows.filter((e) => e.enabled === true);
        else if (args?.enabled === false) rows = rows.filter((e) => e.enabled === false);
        if (risk) rows = rows.filter((e) => e.risk === risk);
        if (text) {
          rows = rows.filter((e) =>
            e.name.toLowerCase().includes(text)
            || e.path.toLowerCase().includes(text)
            || e.publisher.toLowerCase().includes(text));
        }
        const total = rows.length;
        return {
          total,
          shown: Math.min(total, limit),
          rows: rows.slice(0, limit).map((e) => ({
            id: e.id, source: e.source, name: e.name, state: e.state,
            enabled: e.enabled, risk: e.risk, path: e.path,
            publisher: e.publisher, version: e.version,
          })),
        };
      },
    });

    reg({
      name: 'wpm_detail',
      description: 'Read one entry by id, including the probe\'s own raw fields (detail) so an action can be built from it. Use wpm_list first to get an id.',
      parameters: {
        type: 'object',
        properties: { id: { type: 'string', description: 'Entry id from wpm_list, e.g. svc:machine:Spooler' } },
        required: ['id'],
      },
      output: OUTPUT,
      async execute(args) {
        const id = String(args?.id ?? '').trim();
        if (!id) return { ok: false, error: 'missing id' };
        await rt.inventory.ensure({});
        const hit = rt.inventory.allEntries().find((e) => e.id === id);
        if (!hit) return { ok: false, error: `no such entry: ${id}` };
        return { ok: true, entry: hit };
      },
    });

    reg({
      name: 'wpm_refresh',
      description: 'Re-run the probes and rebuild the index (bypasses the 5-minute cache). Optionally limit to some sources. Takes about 5 s in parallel; the first cold fill of all eleven sources takes about 14 s sequentially.',
      parameters: {
        type: 'object',
        properties: {
          sources: { type: 'array', items: { type: 'string' }, description: 'Optional subset of source ids' },
        },
        required: [],
      },
      output: OUTPUT,
      async execute(args) {
        const sources = Array.isArray(args?.sources)
          ? args.sources.filter((s) => SOURCE_BY_ID.has(s))
          : undefined;
        const out = await rt.inventory.ensure({ sources, force: true, parallel: true });
        return { ok: true, ...out, total: rt.inventory.total(), sources: rt.inventory.summary() };
      },
    });

    reg({
      name: 'wpm_action',
      description: 'Enable, disable, roll back or uninstall ONE entry. Five sources toggle (svc / task / autorun / com / firewall: enable, disable, rollback). Three are destroyed rather than toggled (program / appx / drv: uninstall only) — uninstall is irreversible and has no rollback record, only a registry backup. ifeo, fileexts and credprov are read-only. Protected services, kernel drivers, SystemComponent programs and Microsoft-signed driver packages are refused by the probe itself; the probe also decides per row whether an uninstall is even possible, so never pre-judge that in the caller. Always run with dryRun:true first to see the plan, then repeat with dryRun:false. Service, task, firewall and any HKLM-scoped uninstall need an elevated shell and return needsAdmin:true otherwise — retry those through wpm_elevated rather than here.',
      parameters: {
        type: 'object',
        properties: {
          source: { type: 'string', enum: ['svc', 'task', 'autorun', 'com', 'firewall', 'program', 'appx', 'drv'], description: 'Source id' },
          action: { type: 'string', enum: ACTIONS, description: 'What to do; uninstall applies to program/appx/drv only, enable/disable to the five toggleable sources' },
          dryRun: { type: 'boolean', description: 'true = report the plan and the undo record without writing (default true)' },
          target: { type: 'object', description: 'The entry detail object from wpm_detail (probe-specific: name / taskPath+taskName / keyPath+name / clsid+scope). For firewall the keyPath nine-tuple is required: rule names are not unique (542 rules, 324 distinct names).' },
          undo: { type: 'object', description: 'For action=rollback: the undo record returned by the original change' },
        },
        required: ['source', 'action'],
      },
      output: OUTPUT,
      async execute(args) {
        const source = String(args?.source ?? '');
        const action = String(args?.action ?? '');
        if (!SOURCE_BY_ID.has(source)) return { ok: false, error: `unknown source: ${source}` };
        if (!ACTIONS.includes(action)) return { ok: false, error: `unknown action: ${action}` };
        const dryRun = args?.dryRun !== false;
        try {
          const out = await runProbe('actions.ps1', {
            action, source, target: args?.target ?? {}, undo: args?.undo ?? null, dryRun,
          }, { timeout: ACTION_TIMEOUT_MS });
          if (out?.ok && out?.changed && !dryRun) rt.inventory.clear();
          return { ...out, dryRun };
        } catch (error) {
          return { ok: false, changed: false, error: String(error?.message ?? error) };
        }
      },
    });

    reg({
      name: 'wpm_repair',
      description: 'Run the eight system-repair checks (hosts file / IE home+search page / static DNS / TCP connection-count limits / UAC settings / dead startup and uninstall registry entries / font cache / icon cache). Each check reports what it expected, what it measured, and whether a fix exists. This is a block operation, not a row action: use action=fix with dryRun:true first (the default) to see exactly which values would be written or deleted and which backup file would be captured, then repeat with dryRun:false. hosts is never modified - fixing it only snapshots the file. UAC, font cache and icon cache are reported without an automatic fix because they need a sign-out, a service stop or an Explorer restart.',
      parameters: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['scan', 'fix'], description: 'scan = detect only (default); fix = also apply the safe repairs' },
          dryRun: { type: 'boolean', description: 'true = report the plan and the backup paths without writing (default true)' },
          ids: { type: 'array', items: { type: 'string' }, description: 'Optional subset of check ids: hosts / ie / dns / netconn / uac / redundant / fontcache / iconcache' },
        },
        required: [],
      },
      output: OUTPUT,
      async execute(args) {
        const action = args?.action === 'fix' ? 'fix' : 'scan';
        const dryRun = args?.dryRun !== false;
        const ids = Array.isArray(args?.ids) ? args.ids.map((s) => String(s)) : [];
        try {
          const out = await runProbe('repair.ps1', { action, dryRun, ids }, { timeout: 120_000 });
          if (out?.ok && !dryRun && action === 'fix') rt.inventory.clear();
          return { ...out, action, dryRun };
        } catch (error) {
          return { ok: false, action, dryRun, error: String(error?.message ?? error) };
        }
      },
    });

    // ------------------------------------------------------------------
    // wpm_elevated — the retry path for anything that answered needsAdmin.
    // ------------------------------------------------------------------
    // Kept separate from wpm_action on purpose: this call shows a UAC dialog on
    // the interactive desktop. An agent must choose it deliberately, after a
    // wpm_action result said needsAdmin:true, never as an automatic escalation.
    reg({
      name: 'wpm_elevated',
      description: 'Retry ONE action through a real UAC elevation prompt. Use this only after wpm_action (or wpm_elevated itself) returned needsAdmin:true with canElevate:true — it raises an actual administrator consent dialog on the user\'s desktop, which the user must approve. Never pass dryRun:true: a preview needs no rights and is refused without a prompt, so call wpm_action for that. A user who cancels the prompt is answered with {ok:false,cancelled:true} and nothing was changed — that is not an error, do not retry it in a loop and do not report it as a failure. Pass the same target you sent to wpm_action; the elevated child runs actions.ps1 with the same parameters.',
      parameters: {
        type: 'object',
        properties: {
          source: { type: 'string', enum: ['svc', 'task', 'autorun', 'com', 'firewall', 'program', 'appx', 'drv'], description: 'Source id, same as wpm_action' },
          action: { type: 'string', enum: ACTIONS, description: 'What to do; uninstall applies to program/appx/drv only' },
          target: { type: 'object', description: 'The entry detail object from wpm_detail, exactly as sent to wpm_action' },
          undo: { type: 'object', description: 'For action=rollback: the undo record returned by the original change' },
        },
        required: ['source', 'action'],
      },
      output: OUTPUT,
      async execute(args) {
        const source = String(args?.source ?? '');
        const action = String(args?.action ?? '');
        if (!SOURCE_BY_ID.has(source)) return { ok: false, error: `unknown source: ${source}` };
        if (!ACTIONS.includes(action)) return { ok: false, error: `unknown action: ${action}` };
        if (action !== 'rollback' && !args?.target?.key && !args?.target?.name && !args?.target?.taskName) {
          return { ok: false, error: 'missing target' };
        }
        try {
          const run = await runElevated(probePath('actions.ps1'), {
            action, source, target: args?.target ?? {}, undo: args?.undo ?? null, dryRun: false,
          }, { timeout: ELEVATED_TIMEOUT_MS });
          if (run?.cancelled === true) {
            return { ok: false, changed: false, elevated: false, cancelled: true, message: '你取消了 UAC 提权' };
          }
          if (run?.ok !== true || !run?.out) {
            return {
              ok: false,
              changed: false,
              elevated: run?.elevated === true,
              cancelled: false,
              timeout: run?.timeout === true,
              error: String(run?.error ?? 'elevated run produced no result'),
            };
          }
          const out = run.out;
          if (out?.ok && out?.changed) rt.inventory.clear();
          return { ...out, elevated: true, dryRun: false };
        } catch (error) {
          return { ok: false, changed: false, elevated: false, error: String(error?.message ?? error) };
        }
      },
    });

    return () => { for (const dispose of disposers) { try { dispose(); } catch { /* noop */ } } };
  }, 'dsh-windows-toolbox: agent tools');
}

/* ---------------------------------------------------------------- host apply */

export function mountManage(ctx, config) {
  const rt = createRuntime(config ?? {});
  // Each service is injected independently so a missing one cannot suppress the
  // whole plugin (mirrors dsh-source-inbox:1013-1024).
  ctx.inject(['webServer'], (webCtx) => mountRoutes(webCtx, rt));
  ctx.inject(['tools'], (toolsCtx) => mountTools(toolsCtx, rt));
}

export { sortEntries };
