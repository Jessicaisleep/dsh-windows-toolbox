/**
 * lib/runner.js — executes capabilities and normalizes their results.
 *
 * Design rules, all of them learned from the sibling plugin's failures:
 *
 *  • A capability NEVER throws. A probe that times out, refuses for lack of
 *    admin, or returns garbage is recorded as `error` on that capability's slot
 *    and the other capabilities on the page keep working. One broken scan must
 *    not blank the whole panel.
 *
 *  • Scans are cached with a TTL. `bigfiles` on a 34k-file Documents folder takes
 *    39 s; re-running it because the panel repainted would be unusable. An
 *    explicit refresh bypasses the cache.
 *
 *  • Results are normalized into { items, meta } so the client can render every
 *    capability with one component, while `raw` keeps whatever the probe said for
 *    the detail view. Nothing is dropped.
 */
import { runProbe } from './ps.js';
import {
  CAPABILITY_BY_ID,
  CAPABILITY_IDS,
  JUNK_IDS,
  SCAN_ROOT_IDS,
} from './capabilities.js';

const DEFAULT_TTL_MS = 5 * 60 * 1000;

/**
 * Per-capability timeouts. These are wall-clock budgets, not predictions.
 *
 * Observed worst cases on this machine (2026-11-17, single runs unless noted):
 *   bigfiles    13.8 s (user profile, 196k files)
 *   dupfiles    39.1 s (Documents, 34k files)
 *   speedtest   23.9 s (three failed endpoints before the fallback answered)
 *   rescue       6.5 s (sfc/DISM time out by design when not elevated)
 *   health       5.1 s
 *
 * The budgets leave room for a machine several times slower before a scan is
 * reported as timed out. `speedtest` gets the largest multiplier because its
 * cost is network latency, which the user cannot control.
 */
const TIMEOUTS = {
  junk: 120_000,
  bigfiles: 180_000,
  dupfiles: 240_000,
  netdiag: 90_000,
  health: 90_000,
  security: 120_000,
  privacy: 90_000,
  perm: 90_000,
  popup: 90_000,
  speedtest: 180_000,
  homepage: 120_000,
  slim: 120_000,
  rescue: 150_000,
  backup: 150_000,
  software: 120_000,
  softmgr: 180_000,
  drivers: 120_000,
  drivers2: 120_000,
  contextmenu: 120_000,
  winsettings: 120_000,
  phone: 120_000,
  tweaks: 120_000,
  shredder: 120_000,
  proc: 30_000,
  diskhealth: 30_000,
};

function nowMs() {
  return Date.now();
}

/** Coerce an unknown probe payload into the { items, meta } shape the panel uses. */
export function normalizeCapability(capabilityId, raw) {
  const box = { items: [], meta: {} };
  if (raw === null || typeof raw !== 'object') {
    box.meta = { shape: 'empty' };
    return box;
  }
  box.meta = { ...raw };
  switch (capabilityId) {
    case 'junk': {
      // The panel groups targets by category; keep the flat list as items so
      // selection is per-target, not per-group.
      const targets = Array.isArray(raw.targets) ? raw.targets : [];
      box.items = targets.map((t) => ({
        id: String(t.id ?? ''),
        // The group is what makes the five cleanup categories visible; without
        // it the panel can only show one flat list and Cookie / 痕迹 / 注册表
        //清理 look like more temp files.
        group: String(t.group ?? ''),
        label: String(t.label ?? t.labelEn ?? t.id ?? ''),
        path: String(t.path ?? ''),
        kind: String(t.kind ?? ''),
        exists: t.exists === true,
        blocked: t.blocked === true,
        needsAdmin: t.needsAdmin === true,
        files: Number(t.files ?? 0),
        bytes: Number(t.bytes ?? 0),
        note: String(t.note ?? ''),
      }));
      box.meta = {
        action: raw.action ?? 'scan',
        dryRun: raw.dryRun !== false,
        elevated: raw.elevated === true,
        totalBytes: Number(raw.totalBytes ?? 0),
        totalFiles: Number(raw.totalFiles ?? 0),
        freed: Number(raw.freed ?? 0),
        deleted: Number(raw.deleted ?? 0),
        skipped: Number(raw.skipped ?? 0),
        messages: Array.isArray(raw.messages) ? raw.messages.map(String) : [],
      };
      break;
    }
    case 'bigfiles': {
      const rows = Array.isArray(raw.rows) ? raw.rows : [];
      box.items = rows.map((r) => ({
        path: String(r.path ?? ''),
        name: String(r.name ?? ''),
        folder: String(r.folder ?? ''),
        ext: String(r.ext ?? ''),
        bytes: Number(r.bytes ?? 0),
        modified: String(r.modified ?? ''),
      }));
      box.meta = {
        root: String(raw.root ?? ''),
        rootPath: String(raw.rootPath ?? ''),
        minMb: Number(raw.minMb ?? 0),
        scanned: Number(raw.scanned ?? 0),
        scannedBytes: Number(raw.scannedBytes ?? 0),
        matched: Number(raw.matched ?? 0),
        truncated: raw.truncated === true,
        elapsedMs: Number(raw.elapsedMs ?? 0),
      };
      break;
    }
    case 'dupfiles': {
      const groups = Array.isArray(raw.groups) ? raw.groups : [];
      box.items = groups.map((g) => ({
        hash: String(g.hash ?? ''),
        bytes: Number(g.bytes ?? 0),
        count: Number(g.count ?? 0),
        wasted: Number(g.wasted ?? 0),
        files: Array.isArray(g.files)
          ? g.files.map((f) => ({
            path: String(f.path ?? ''),
            name: String(f.name ?? ''),
            folder: String(f.folder ?? ''),
            bytes: Number(f.bytes ?? 0),
            modified: String(f.modified ?? ''),
          }))
          : [],
      }));
      box.meta = {
        root: String(raw.root ?? ''),
        rootPath: String(raw.rootPath ?? ''),
        minKb: Number(raw.minKb ?? 0),
        scanned: Number(raw.scanned ?? 0),
        hashed: Number(raw.hashed ?? 0),
        groupsTotal: Number(raw.groupsTotal ?? 0),
        wastedTotal: Number(raw.wastedTotal ?? 0),
        truncated: raw.truncated === true,
        elapsedMs: Number(raw.elapsedMs ?? 0),
      };
      break;
    }
    case 'netdiag': {
      // Two shapes come back from the same probe:
      //   action='scan'   -> { steps[] }           one row per diagnostic hop
      //   action='repair' -> { targets[], results[] } one row per fix target
      // The repair shape carries far more per-row context (command, risk,
      // impact, whether it needs admin or a reboot), so it is mapped explicitly
      // rather than through the generic path — the panel prints those fields.
      if (raw.action === 'dnspick') {
        // Third shape: the DNS switch. The probe already emits a ready-made
        // items[] (target / plan / verify), so it is passed through as-is
        // while the machine-readable extras ride along in meta for the panel.
        const list = Array.isArray(raw.items) ? raw.items : [];
        box.items = list.map((it) => ({
          id: String(it.id ?? ''),
          group: String(it.group ?? ''),
          label: String(it.label ?? ''),
          status: String(it.status ?? 'info'),
          value: String(it.value ?? ''),
          detail: String(it.detail ?? ''),
          fix: String(it.fix ?? ''),
          needsAdmin: it.needsAdmin === true,
        }));
        // The probe reports the adapter it will touch as a one-element array
        // (`targets:[{interfaceIndex,interfaceAlias}]`), not as a bare object —
        // reading `.interfaceAlias` straight off it yields undefined.
        const targetOne = Array.isArray(raw.targets) ? (raw.targets[0] ?? {}) : (raw.targets ?? {});
        box.meta = {
          action: 'dnspick',
          dryRun: raw.dryRun === true,
          changed: raw.changed === true,
          elevated: raw.elevated === true,
          needsAdmin: raw.needsAdmin === true,
          server: String(raw.server ?? ''),
          alias: String(targetOne.interfaceAlias ?? ''),
          interfaceIndex: Number(targetOne.interfaceIndex ?? 0),
          currentDns: Array.isArray(raw.currentDns) ? raw.currentDns.map(String) : [],
          afterDns: Array.isArray(raw.afterDns) ? raw.afterDns.map(String) : [],
          planCommands: Array.isArray(raw.planCommands) ? raw.planCommands.map(String) : [],
          rollbackCommands: Array.isArray(raw.rollbackCommands) ? raw.rollbackCommands.map(String) : [],
          candidates: Array.isArray(raw.candidates) ? raw.candidates : [],
          backupFile: String(raw.backupFile ?? ''),
          aborted: String(raw.aborted ?? ''),
          verdict: String(raw.verdict ?? ''),
          notes: Array.isArray(raw.notes) ? raw.notes : [],
          summary: raw.summary ?? {},
          elapsedMs: Number(raw.elapsedMs ?? 0),
        };
        break;
      }
      if (raw.action === 'repair' || Array.isArray(raw.targets)) {
        const targets = Array.isArray(raw.targets) ? raw.targets : [];
        const results = Array.isArray(raw.results) ? raw.results : [];
        const byId = new Map(results.map((r) => [String(r.id ?? ''), r]));
        box.items = targets.map((t) => {
          const done = byId.get(String(t.id ?? ''));
          return {
            id: String(t.id ?? ''),
            label: String(t.label ?? ''),
            status: String(t.status ?? (done ? done.status : 'info')),
            detail: String(t.detail ?? t.risk ?? ''),
            fix: String(t.command ?? ''),
            needsAdmin: t.needsAdmin === true,
            // Kept as extras so the panel can render the "what will happen"
            // line without the runner having to know Chinese.
            category: String(t.category ?? ''),
            actionText: String(t.command ?? ''),
            impact: String(t.impact ?? ''),
            risk: String(t.risk ?? ''),
            currentState: String(t.currentState ?? ''),
            needsReboot: t.needsReboot === true,
            canRun: t.canRun === true,
            ran: done ? done.ran === true : false,
          };
        });
        box.meta = {
          action: 'repair',
          dryRun: raw.dryRun === true,
          changed: raw.changed === true,
          elevated: raw.elevated === true,
          targetCount: Number(raw.targetCount ?? targets.length),
          selectedIds: Array.isArray(raw.selectedIds) ? raw.selectedIds.map(String) : [],
          results,
          verdict: String(raw.verdict ?? ''),
          notes: Array.isArray(raw.notes) ? raw.notes : [],
          summary: raw.summary ?? {},
          elapsedMs: Number(raw.elapsedMs ?? 0),
        };
        break;
      }
      const steps = Array.isArray(raw.steps) ? raw.steps : [];
      box.items = steps.map((s) => ({
        id: String(s.id ?? ''),
        label: String(s.label ?? ''),
        status: String(s.status ?? ''),
        detail: String(s.detail ?? ''),
        // The two rows added for the WiFi/DNS checks carry a group (so the
        // panel can bucket them like every other checks-style capability) and
        // a short `value` worth showing in its own column. The original eight
        // hops have neither, so both default to empty and their rendering is
        // byte-for-byte unchanged.
        group: String(s.group ?? ''),
        value: String(s.value ?? ''),
        ms: Number(s.ms ?? 0),
      }));
      box.meta = {
        action: 'scan',
        verdict: String(raw.verdict ?? ''),
        firstFail: String(raw.firstFail ?? ''),
        online: raw.online === true,
        elapsedMs: Number(raw.elapsedMs ?? 0),
        adapters: Array.isArray(raw.adapters) ? raw.adapters : [],
        ipConfig: Array.isArray(raw.ipConfig) ? raw.ipConfig : [],
        dnsServers: Array.isArray(raw.dnsServers) ? raw.dnsServers.map(String) : [],
        proxy: raw.proxy ?? {},
        winhttp: String(raw.winhttp ?? ''),
        hostsPath: String(raw.hostsPath ?? ''),
        hostsBlocked: Number(raw.hostsBlocked ?? 0),
        hostsEntries: Array.isArray(raw.hostsEntries) ? raw.hostsEntries : [],
      };
      break;
    }
    case 'health': {
      const checks = Array.isArray(raw.checks) ? raw.checks : [];
      box.items = checks.map((c) => ({
        id: String(c.id ?? ''),
        label: String(c.label ?? ''),
        status: String(c.status ?? ''),
        value: String(c.value ?? ''),
        detail: String(c.detail ?? ''),
        // health.ps1 predates featurelib and calls the hint `fixHint`, while
        // every featurelib probe calls it `fix`. Emit both so one renderer can
        // handle all checks-style capabilities without a special case.
        fix: String(c.fixHint ?? c.fix ?? ''),
        fixHint: String(c.fixHint ?? c.fix ?? ''),
      }));
      box.meta = {
        summary: raw.summary ?? {},
        disks: Array.isArray(raw.disks) ? raw.disks : [],
        host: raw.host ?? {},
        elapsedMs: Number(raw.elapsedMs ?? 0),
      };
      break;
    }
    default: {
      // The featurelib family. Every probe written against
      // lib/probes/featurelib.ps1 returns the same envelope, so one branch
      // normalizes all of them: { ok, count, items[], summary, ...extra }.
      // Keeping this generic is deliberate — adding a capability then means
      // touching capabilities.js only, not this switch.
      const items = Array.isArray(raw.items) ? raw.items : [];
      box.items = items.map((it) => {
        const row = {
          id: String(it.id ?? ''),
          group: String(it.group ?? ''),
          label: String(it.label ?? ''),
          status: String(it.status ?? 'info'),
          value: String(it.value ?? ''),
          detail: String(it.detail ?? ''),
          fix: String(it.fix ?? ''),
          needsAdmin: it.needsAdmin === true,
        };
        // Carry through optional per-row extras (tweaks.ps1 emits labelZh /
        // whatZh / effectZh / riskZh / audienceZh). They used to be discarded
        // here, which is why a curated Chinese label in the preset never
        // reached the screen. Only copy primitives, and never overwrite a
        // field the normalizer already owns.
        for (const [k, v] of Object.entries(it)) {
          if (k in row) continue;
          if (v === null || v === undefined) continue;
          const t = typeof v;
          if (t === 'string' || t === 'number' || t === 'boolean') row[k] = v;
        }
        return row;
      });
      // Everything except the payload and summary becomes meta, so a probe can
      // surface extra readings (thirdPartyCount, cVerdict, trim, ...) without a
      // code change here.
      const { items: _i, summary: _s, ...extra } = raw;
      box.meta = { summary: raw.summary ?? {}, ...extra };
      break;
    }
  }
  return box;
}

/**
 * Validate and clean what the client sent for one capability.
 *
 * Everything from the client is untrusted: it arrives over HTTP and could be
 * edited by hand. Only whitelisted ids and numeric ranges survive; anything
 * unknown is dropped rather than forwarded to PowerShell.
 */
export function sanitizeParams(capabilityId, input) {
  const out = {};
  // An unknown id must never reach a probe: return an empty bag so a typo (or a
  // hand-crafted request) cannot pick up the generic branch's allowances.
  if (!CAPABILITY_BY_ID.has(capabilityId)) return out;
  const num = (raw, min, max, fallback) => {
    const n = Number(raw);
    if (!Number.isFinite(n)) return fallback;
    return Math.max(min, Math.min(max, Math.trunc(n)));
  };
  switch (capabilityId) {
    case 'junk':
      // junk is the only capability with a `clean` verb. Its action/dryRun used
      // to be stripped here, which silently degraded run('junk', {action:'clean'})
      // into a scan — the caller got a plan and believed it had cleaned. The
      // panel and the MCP tool bypass Runner for cleaning, so this never showed
      // up in testing, but the API surface was lying.
      if (typeof input?.action === 'string' && /^(scan|clean)$/.test(input.action)) {
        out.action = input.action;
      }
      if (typeof input?.dryRun === 'boolean') out.dryRun = input.dryRun;
      if (Array.isArray(input?.targets)) {
        out.targets = input.targets.map(String).filter((id) => JUNK_IDS.has(id));
      }
      break;
    case 'bigfiles':
      out.root = SCAN_ROOT_IDS.has(String(input?.root)) ? String(input.root) : 'user';
      out.minMb = num(input?.minMb, 1, 100_000, 100);
      out.limit = num(input?.limit, 1, 2000, 200);
      break;
    case 'dupfiles':
      out.root = SCAN_ROOT_IDS.has(String(input?.root)) ? String(input.root) : 'user';
      out.minKb = num(input?.minKb, 1, 1_000_000, 1024);
      out.limit = num(input?.limit, 1, 500, 100);
      break;
    case 'netdiag':
      // netdiag doubles as the network repair tool (360's 断网急救箱): the same
      // probe answers action='scan' (8 diagnostic steps) and action='repair'
      // (7 fix targets). Both keys have to survive sanitizing, otherwise the
      // panel can show the repair plan but the request arrives empty and the
      // probe silently falls back to scan.
      if (typeof input?.action === 'string' && /^(scan|repair|dnspick)$/.test(input.action)) {
        out.action = input.action;
      }
      if (typeof input?.dryRun === 'boolean') out.dryRun = input.dryRun;
      // dnspick takes exactly one of the five published resolvers, or 'auto'.
      // Anything else is dropped here AND re-rejected by the probe, so a
      // hand-edited body cannot point the machine at an arbitrary server.
      if (typeof input?.server === 'string' && /^(223\.5\.5\.5|119\.29\.29\.29|1\.1\.1\.1|8\.8\.8\.8|114\.114\.114\.114|auto)$/.test(input.server)) {
        out.server = input.server;
      }
      if (Array.isArray(input?.targets)) {
        out.targets = input.targets
          .map(String)
          .filter((id) => /^[a-z][a-z0-9-]{0,31}$/.test(id))
          .slice(0, 20);
      }
      break;
    case 'health':
      break;
    default:
      // The featurelib family passes a small, capability-specific bag. Only
      // allow the keys those probes actually read, so a hand-edited HTTP body
      // cannot smuggle arbitrary strings into a PowerShell param file.
      //
      // The list below was derived by grepping every probe for `params.<name>`
      // rather than guessed: homepage (target/value), backup (keys),
      // contextmenu (clsid/scope), shredder (paths), tweaks (ids/undo),
      // winsettings (setting/value), softmgr (appName/installPath/exePath/purge).
      if (input && typeof input === 'object') {
        if (typeof input.action === 'string' && /^[a-z][a-z0-9-]{0,31}$/.test(input.action)) {
          out.action = input.action;
        }
        if (typeof input.dryRun === 'boolean') out.dryRun = input.dryRun;
        if (typeof input.purge === 'boolean') out.purge = input.purge;
        if (Array.isArray(input.files)) out.files = input.files.map(String).slice(0, 50);
        if (Array.isArray(input.paths)) out.paths = input.paths.map(String).slice(0, 50);
        if (Array.isArray(input.keys)) out.keys = input.keys.map(String).slice(0, 100);
        if (Array.isArray(input.ids)) out.ids = input.ids.map(String).slice(0, 200);
        if (Array.isArray(input.undo)) out.undo = input.undo.slice(0, 200);
        if (typeof input.target === 'string' && input.target.length <= 260) out.target = input.target;
        if (typeof input.setting === 'string' && /^[A-Za-z0-9_.-]{1,64}$/.test(input.setting)) out.setting = input.setting;
        if (typeof input.preset === 'string' && /^[A-Za-z0-9_.-]{1,64}$/.test(input.preset)) out.preset = input.preset;
        if (typeof input.clsid === 'string' && /^\{?[0-9A-Fa-f-]{8,40}\}?$/.test(input.clsid)) out.clsid = input.clsid;
        if (typeof input.scope === 'string' && /^(machine|user)$/.test(input.scope)) out.scope = input.scope;
        if (typeof input.appName === 'string' && input.appName.length <= 200) out.appName = input.appName;
        if (typeof input.installPath === 'string' && /^[A-Za-z]:\\/.test(input.installPath)) out.installPath = input.installPath;
        if (typeof input.exePath === 'string' && /^[A-Za-z]:\\/.test(input.exePath)) out.exePath = input.exePath;
        if (typeof input.root === 'string' && SCAN_ROOT_IDS.has(input.root)) out.root = input.root;
        // `value` is deliberately unconstrained in shape but bounded in length:
        // winsettings writes DWORDs and strings, homepage writes URLs. The
        // probes validate the type per setting and refuse mismatches.
        if (input.value !== undefined && (typeof input.value === 'string' || typeof input.value === 'number')) {
          out.value = String(input.value).slice(0, 2048);
        }
      }
      break;
  }
  return out;
}

export class Runner {
  constructor({ ttlMs = DEFAULT_TTL_MS } = {}) {
    this.ttlMs = ttlMs;
    /** capabilityId -> { at, data, error, params } */
    this.slots = new Map();
  }

  /** True when a cached result exists and is still fresh. */
  fresh(id) {
    const slot = this.slots.get(id);
    if (!slot) return false;
    if (slot.error) return false;
    return nowMs() - slot.at < this.ttlMs;
  }

  /**
   * Run one capability. Never throws: a failure is recorded on the slot and
   * returned in the result so the caller can show it in place.
   */
  async run(id, params = {}, { timeout } = {}) {
    const cap = CAPABILITY_BY_ID.get(id);
    if (!cap) {
      return { ok: false, id, error: `unknown capability: ${id}`, items: [], meta: {} };
    }
    const clean = sanitizeParams(id, params);
    const startedAt = nowMs();
    try {
      const raw = await runProbe(cap.probe, clean, { timeout: timeout ?? TIMEOUTS[id] ?? 120_000 });
      if (raw?.ok === false) {
        // The probe ran but refused (bad root, missing folder). That is a real
        // answer, not a crash: keep its message and do not cache it as success.
        const message = String(raw.error ?? '扫描失败');
        this.slots.set(id, { at: startedAt, data: null, error: message, params: clean });
        return { ok: false, id, error: message, items: [], meta: { ...raw }, params: clean };
      }
      const box = normalizeCapability(id, raw);
      this.slots.set(id, { at: startedAt, data: box, error: null, params: clean });
      return { ok: true, id, ...box, params: clean, elapsedMs: nowMs() - startedAt };
    } catch (error) {
      const message = String(error?.message ?? error);
      this.slots.set(id, { at: startedAt, data: null, error: message, params: clean });
      return { ok: false, id, error: message, items: [], meta: {}, params: clean };
    }
  }

  /** Return the cached result, or run it when the cache is cold/stale. */
  async ensure(id, params = {}, options = {}) {
    if (!options.force && this.fresh(id)) {
      const slot = this.slots.get(id);
      return {
        ok: true,
        id,
        ...slot.data,
        params: slot.params,
        cached: true,
        at: slot.at,
      };
    }
    const out = await this.run(id, params, options);
    return { ...out, cached: false };
  }

  /**
   * Cheap status for every capability without running any scan: what is cached,
   * when, and what the last error was. This is what the panel's first paint uses
   * — it must return instantly.
   */
  status() {
    const rows = [];
    for (const id of CAPABILITY_IDS) {
      const cap = CAPABILITY_BY_ID.get(id);
      const slot = this.slots.get(id);
      rows.push({
        id,
        label: cap.label,
        labelEn: cap.labelEn,
        tagline: cap.tagline,
        detail: cap.detail,
        risk: cap.risk,
        view: cap.view,
        group: cap.group,
        coverage: cap.coverage,
        actions: cap.actions,
        needsAdmin: cap.needsAdmin === true,
        cached: Boolean(slot && !slot.error),
        at: slot?.at ?? null,
        stale: slot ? nowMs() - slot.at >= this.ttlMs : true,
        error: slot?.error ?? null,
        hasResult: Boolean(slot?.data),
        itemCount: slot?.data?.items?.length ?? 0,
        summary: slot?.data?.meta?.summary ?? null,
      });
    }
    return rows;
  }

  /** Snapshot of a cached result without running anything. */
  cached(id) {
    const slot = this.slots.get(id);
    if (!slot?.data) return null;
    return { ok: true, id, ...slot.data, params: slot.params, cached: true, at: slot.at };
  }

  clear(id) {
    if (id) this.slots.delete(id);
    else this.slots.clear();
  }
}
