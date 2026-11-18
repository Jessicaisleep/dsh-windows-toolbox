/**
 * inventory.js - run probes, cache their output, normalize, and answer queries.
 *
 * The panel is opened many times per session but the machine changes slowly, so:
 *   * each source's result is cached with its own TTL (default 5 min)
 *   * a refresh button bypasses the cache
 *   * probes run one at a time on first fill, then in parallel on refresh
 *
 * Why not always parallel: seven PowerShell processes starting at once pegs a
 * low-end CPU and makes the panel look broken, while a cold first paint with
 * sequential probes still finishes in ~11 s (measured: 10.9 s for all seven).
 * A warm cache is instant either way.
 */

import { SOURCES, SOURCE_BY_ID } from './sources.js';
import { normalizePayload, sortEntries } from './normalize.js';
import { attachExplanations } from './explain.js';
import { runProbe } from './ps.js';

const DEFAULT_TTL_MS = 5 * 60 * 1000;

/** @typedef {{entries: any[], meta: any, at: number, ms: number, error: string}} CacheSlot */

export class Inventory {
  constructor(options = {}) {
    this.ttlMs = Number.isFinite(options.ttlMs) ? options.ttlMs : DEFAULT_TTL_MS;
    /** @type {Map<string, CacheSlot>} */
    this.slots = new Map();
    /** @type {Promise<void> | null} */
    this.inflight = null;
    this.inflightSources = null;
  }

  /** Is a slot fresh enough to reuse? */
  fresh(id, now = Date.now()) {
    const slot = this.slots.get(id);
    if (!slot) return false;
    if (slot.error) return false;
    return now - slot.at < this.ttlMs;
  }

  /** Run one source's probe and store the result. Never throws. */
  async runSource(id) {
    const source = SOURCE_BY_ID.get(id);
    if (!source) throw new Error(`unknown source: ${id}`);
    const started = Date.now();
    let entries = [];
    let meta = {};
    let error = '';
    try {
      const payload = await runProbe(source.probe, {}, { timeout: source.id === 'appx' ? 180000 : 120000 });
      const norm = normalizePayload(id, payload);
      // Attach the plain-language explanation here, at the one place every
      // source funnels through, so the panel, the tools and the render test all
      // see identical text. explainEntry never invents: it returns null fields
      // it cannot derive, and finalize() drops the whole object if nothing is
      // left.
      //
      // The cache deliberately stores ONE language only ('zh'). Re-deriving the
      // text for the active language happens per request in host-manage.js
      // (withLang() on /entries and /detail), which is cheap because
      // explainEntry is a pure function over the row. Storing both languages
      // here would double the cache for a value that changes maybe once a
      // session.
      entries = attachExplanations(norm.entries, 'zh');
      meta = norm.meta;
    } catch (e) {
      // A probe failing must not take the whole panel down: the other six
      // sources are still worth showing. The error is kept per-source so the UI
      // can mark just that tab.
      error = e instanceof Error ? e.message : String(e);
    }
    const slot = { entries, meta, at: Date.now(), ms: Date.now() - started, error };
    this.slots.set(id, slot);
    return slot;
  }

  /**
   * Ensure every requested source is loaded.
   *
   * @param {{ sources?: string[], force?: boolean, parallel?: boolean }} opts
   */
  async ensure(opts = {}) {
    const ids = (opts.sources?.length ? opts.sources : SOURCES.map((s) => s.id)).filter((id) => SOURCE_BY_ID.has(id));
    const todo = opts.force ? ids : ids.filter((id) => !this.fresh(id));

    if (todo.length === 0) {
      return { ran: [], cached: ids, elapsedMs: 0 };
    }

    const started = Date.now();
    if (opts.parallel) {
      await Promise.all(todo.map((id) => this.runSource(id)));
    } else {
      for (const id of todo) await this.runSource(id);
    }
    return { ran: todo, cached: ids.filter((id) => !todo.includes(id)), elapsedMs: Date.now() - started };
  }

  /** Entries for one source, read from cache only. */
  entriesOf(id) {
    return this.slots.get(id)?.entries ?? [];
  }

  /** All entries, sorted for display. */
  allEntries() {
    const out = [];
    for (const s of SOURCES) out.push(...this.entriesOf(s.id));
    return sortEntries(out);
  }

  /**
   * A compact per-source summary: counts plus the timing/error of the last run.
   * This is what the header strip shows.
   */
  summary() {
    return SOURCES.map((s) => {
      const slot = this.slots.get(s.id);
      const entries = slot?.entries ?? [];
      let on = 0;
      let off = 0;
      let unknown = 0;
      for (const e of entries) {
        if (e.enabled === true) on++;
        else if (e.enabled === false) off++;
        else unknown++;
      }
      return {
        id: s.id,
        label: s.label,
        labelEn: s.labelEn,
        risk: s.risk,
        actions: s.actions,
        total: entries.length,
        enabled: on,
        disabled: off,
        unknown,
        ms: slot?.ms ?? null,
        at: slot?.at ?? null,
        stale: slot ? Date.now() - slot.at >= this.ttlMs : true,
        error: slot?.error ?? '',
        meta: slot?.meta ?? {},
      };
    });
  }

  /** Total entry count across all freshly-cached sources. */
  total() {
    let n = 0;
    for (const s of SOURCES) n += this.entriesOf(s.id).length;
    return n;
  }

  /** Forget everything (used by the explicit refresh path). */
  clear() {
    this.slots.clear();
    this.inflight = null;
  }
}
