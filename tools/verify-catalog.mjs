/**
 * verify-catalog.mjs - prove every entry in lib/presets/softwares.json points at
 * the vendor's own site before the panel is allowed to offer a download.
 *
 * WHY THIS EXISTS
 * ---------------
 * The user's constraint was blunt: "你可以没有，但是不能给出非官网的下载" -
 * it is acceptable to be missing software, it is NOT acceptable to hand out a
 * download from a non-official source. That is a correctness requirement, not a
 * nicety, so it is enforced by a test rather than by care.
 *
 * What is checked, per entry:
 *   1. `homepage` and `downloadPage` are HTTPS and parse as a URL.
 *   2. The host is the vendor's own domain - not a download portal, not a
 *      mirror, not a URL shortener. Enforced by an allowlist of portal hosts
 *      that must NEVER appear (see FORBIDDEN_HOSTS).
 *   3. The URL actually answers. A HEAD request is tried first and a GET
 *      fallback covers servers that reject HEAD (github release pages do).
 *
 * HARD vs SOFT unreachability
 * ---------------------------
 * A 404 means OUR DATA IS WRONG - the page is gone, the entry must be fixed or
 * removed. That is a failure.
 *
 * A timeout, a connection reset, or a 403/429/451/503 means WE COULD NOT
 * MEASURE: the site is up but hostile to scripts, or the path from this machine
 * is broken. Measured on 2026-11-17 from this host: `github.com` fails every
 * HEAD and GET at ~10.6 s (documented in E:\DSHWORK\github-helper\README.md as
 * a mainland-China routing problem, while api.github.com stays reachable),
 * blender.org/filezilla/autohotkey/hwinfo answer 403 to any non-browser client,
 * and voidtools.com alternates between 200 and reset. Reporting those as "our
 * catalogue is broken" would be wrong in the other direction - so they are
 * NOTES by default and only become failures under `--strict`.
 *
 * Network access is optional: `--offline` verifies shape and policy only, which
 * is what CI or a machine behind a firewall can run.
 *
 * Usage:
 *   node tools/verify-catalog.mjs              # shape + policy + live (notes soft misses)
 *   node tools/verify-catalog.mjs --offline    # shape + policy only
 *   node tools/verify-catalog.mjs --strict     # live misses all count as failures
 *   node tools/verify-catalog.mjs --json       # machine-readable result
 */

import { readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const CATALOG = fileURLToPath(new URL('../lib/presets/softwares.json', import.meta.url));

/**
 * Hosts that mean "this is not the vendor". A download that routes through any
 * of these is exactly the thing the user refused to accept.
 *
 * Kept as a substring list (not a suffix list) so `dl.pconline.com.cn` and
 * `xiazai.zol.com.cn` are both caught without enumerating every subdomain.
 */
export const FORBIDDEN_HOSTS = [
  'pconline.com.cn', 'zol.com.cn', 'onlinedown.net', 'crsky.com', 'ddooo.com',
  'xiazaiba.com', 'pc6.com', 'downxia.com', 'duote.com', 'xiazai.com',
  'softonic.com', 'filehippo.com', 'cnet.com', 'download.com', 'softpedia.com',
  'majorgeeks.com', 'lo4d.com', 'fosshub.com', 'snapfiles.com',
  'hao123.com', 'lanzou.com', 'lanzoux.com', 'qhimg.com', '360simg.com',
];

/**
 * Shorteners must match the WHOLE host, never a substring of the URL.
 *
 * A substring check here was a real bug: `https://www.capcut.cn/` contains the
 * text `t.cn/`, so the CapCut entry was flagged as routing through the t.cn
 * shortener. Matching the parsed hostname equality-wise fixes it and is also
 * the only correct way to compare hostnames - `evil-t.cn` must not pass, and
 * `capcut.cn` must not fail.
 */
export const FORBIDDEN_EXACT_HOSTS = new Set([
  'bit.ly', 'tinyurl.com', 't.cn', 'dwz.cn', 'suo.im', 'goo.gl', 'ow.ly',
  'is.gd', 'buff.ly', 'rb.gy', 'cutt.ly', 'shorturl.at',
]);

/** Path fragments that mean "this is a search/redirect page", not a real link. */
const FORBIDDEN_PATH_HINTS = [
  '/s?', '/link?', '/redirect', 'mydown', '/softdown', '/download.php?id=',
];

/** Third-party GitHub orgs that are legitimately the upstream project itself. */
const GITHUB_OK = new Set([
  'M2Team', 'microsoft', 'obsproject', 'inkscape', 'blender',
  'videolan', 'git-for-windows', 'python', 'nodejs', 'nvm-sh',
]);

function fail(list, id, msg) {
  list.push({ id, msg });
}

/** Shape + policy checks. No network. */
function checkPolicy(entry, errors, warnings) {
  const id = entry.id ?? '(no id)';
  if (!entry.id) fail(errors, id, 'entry has no id');
  if (!entry.name) fail(errors, id, 'entry has no name');

  for (const field of ['homepage', 'downloadPage']) {
    const raw = entry[field];
    if (!raw) {
      fail(errors, id, `missing ${field}`);
      continue;
    }
    let u;
    try {
      u = new URL(raw);
    } catch {
      fail(errors, id, `${field} is not a valid URL: ${raw}`);
      continue;
    }
    if (u.protocol !== 'https:') {
      fail(errors, id, `${field} is not https: ${raw}`);
    }
    const host = u.host.toLowerCase();
    for (const bad of FORBIDDEN_HOSTS) {
      if (host.includes(bad)) {
        fail(errors, id, `${field} routes through a forbidden portal (${bad}): ${raw}`);
      }
    }
    // Shorteners: host equality only. See FORBIDDEN_EXACT_HOSTS for why.
    for (const short of FORBIDDEN_EXACT_HOSTS) {
      if (host === short || host.endsWith(`.${short}`)) {
        fail(errors, id, `${field} uses a URL shortener (${short}): ${raw}`);
      }
    }
    const pathAndQuery = `${u.pathname}${u.search}`.toLowerCase();
    for (const hint of FORBIDDEN_PATH_HINTS) {
      if (pathAndQuery.includes(hint)) {
        fail(errors, id, `${field} looks like a search/redirect page (${hint}): ${raw}`);
      }
    }
    // A GitHub URL is acceptable only when the repo is the upstream project.
    if (host.endsWith('github.com')) {
      const owner = u.pathname.split('/').filter(Boolean)[0] ?? '';
      if (!GITHUB_OK.has(owner)) {
        warnings.push({ id, msg: `${field} points at github.com/${owner} - confirm this is the upstream repo` });
      }
    }
    // A bare-IP host is never a vendor storefront.
    if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) {
      fail(errors, id, `${field} is a bare IP address: ${raw}`);
    }
  }
}

/**
 * Hosts the author knows answer 403/connection-reset to any scripted client.
 * Listed only so the operator does not have to re-diagnose the same four sites;
 * the classification below already treats 403/timeout as "not measured", so
 * this list changes nothing but the wording of the note. Keep it honest: only
 * add a host after measuring it here.
 */
export const PROBE_BLOCKED_HOSTS = new Set([
  'blender.org', 'filezilla-project.org', 'autohotkey.com', 'hwinfo.com',
]);

/** A status code that means "the site refused to answer ME", not "page is gone". */
const REFUSED_STATUS = new Set([401, 403, 405, 406, 418, 429, 451, 503]);

/**
 * Classify one live result.
 *
 *   'ok'      - answered with 2xx/3xx.
 *   'dead'    - 404/410/other 4xx: the entry's URL is genuinely wrong.
 *   'unmeasured' - timeout, transport error, or refusal. We learned nothing
 *                  about whether the page exists.
 */
function classify(result) {
  if (result.ok) return 'ok';
  if (result.status === 404 || result.status === 410) return 'dead';
  if (result.status >= 400 && result.status < 500 && !REFUSED_STATUS.has(result.status)) return 'dead';
  return 'unmeasured';
}

/**
 * Fetch one URL the way a browser would, because the question this tool asks is
 * "can a user open this download page", not "does the server allow scripts".
 *
 * Two lessons are baked in here:
 *   * A custom bot User-Agent gets 403 from several vendors (Dell), which would
 *     report a perfectly good page as broken. So we send a desktop Chrome UA.
 *   * Only an explicit "HEAD not supported" (405/501) or a transport error may
 *     fall through to GET. A 404 must stay a 404; retrying it as GET would turn
 *     a genuinely dead link into a PASS.
 */
async function fetchOne(url, timeoutMs = 15000) {
  const ctrl = () => AbortSignal.timeout(timeoutMs);
  const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  const headers = { 'user-agent': ua, accept: 'text/html,application/xhtml+xml,*/*;q=0.8', 'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8' };

  let headNote = '';
  try {
    const r = await fetch(url, { method: 'HEAD', redirect: 'follow', signal: ctrl(), headers });
    if (r.status < 400) return { ok: true, status: r.status, note: 'HEAD' };
    // Genuine rejection: report it, do not retry it into a pass.
    if (r.status !== 405 && r.status !== 501) return { ok: false, status: r.status, note: 'HEAD' };
    headNote = `HEAD ${r.status}`;
  } catch (e) {
    headNote = `HEAD ${e?.name ?? e}`;
  }

  try {
    const r = await fetch(url, { method: 'GET', redirect: 'follow', signal: ctrl(), headers });
    return { ok: r.status < 400, status: r.status, note: `GET after ${headNote}` };
  } catch (e) {
    return { ok: false, status: 0, note: `GET after ${headNote} failed: ${e?.name ?? e}` };
  }
}

/** Run `worker` over `items` with at most `limit` in flight. Order is preserved. */
async function pool(items, limit, worker) {
  const out = new Array(items.length);
  let next = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    for (;;) {
      const i = next++;
      if (i >= items.length) return;
      out[i] = await worker(items[i], i);
    }
  });
  await Promise.all(runners);
  return out;
}

async function main() {
  const argv = process.argv.slice(2);
  const offline = argv.includes('--offline');
  const asJson = argv.includes('--json');
  const strict = argv.includes('--strict');

  const catalog = JSON.parse(readFileSync(CATALOG, 'utf8'));
  const list = Array.isArray(catalog.softwares) ? catalog.softwares : [];

  const errors = [];
  const warnings = [];
  const seen = new Map();

  for (const entry of list) {
    checkPolicy(entry, errors, warnings);
    if (entry.id) {
      if (seen.has(entry.id)) fail(errors, entry.id, `duplicate id (also used by ${seen.get(entry.id)})`);
      else seen.set(entry.id, entry.name ?? '');
    }
    if (entry.category && !catalog.categories?.[entry.category]) {
      fail(errors, entry.id, `unknown category: ${entry.category}`);
    }
  }

  const dead = [];
  const unmeasured = [];
  if (!offline) {
    // Same question, far less traffic: probe each unique URL once (many entries
    // share a vendor homepage) and keep only a handful of connections in
    // flight. Hundreds of simultaneous requests to vendor sites look like a
    // scraper and get connection-reset; serial takes 20+ minutes.
    const unique = [...new Set(list.flatMap((e) => [e.homepage, e.downloadPage].filter(Boolean)))];
    const concurrency = Number(process.env.VERIFY_CATALOG_CONCURRENCY ?? 8) || 8;
    const startedAt = Date.now();
    const probed = await pool(unique, concurrency, async (u) => ({ url: u, ...(await fetchOne(u)) }));
    const byUrl = new Map(probed.map((r) => [r.url, r]));
    for (const entry of list) {
      const urls = [entry.homepage, entry.downloadPage].filter(Boolean);
      const bad = urls.map((u) => byUrl.get(u)).filter((r) => r && !r.ok);
      if (!bad.length) continue;
      const rows = bad.map((b) => {
        const verdict = classify(b);
        const host = (() => { try { return new URL(b.url).host.toLowerCase(); } catch { return ''; } })();
        return { ...b, verdict, probeBlocked: PROBE_BLOCKED_HOSTS.has(host) };
      });
      const isDead = rows.some((r) => r.verdict === 'dead');
      (isDead ? dead : unmeasured).push({ id: entry.id, name: entry.name, bad: rows });
    }
    if (!asJson) {
      const secs = ((Date.now() - startedAt) / 1000).toFixed(1);
      console.log(`probed ${unique.length} unique URLs at concurrency ${concurrency} in ${secs}s`);
    }
  }

  const failing = errors.length > 0 || dead.length > 0 || (strict && unmeasured.length > 0);
  const payload = {
    ok: !failing,
    offline,
    strict,
    entries: list.length,
    categories: Object.keys(catalog.categories ?? {}).length,
    errors,
    warnings,
    dead,
    unmeasured,
    // Kept for older callers that expected one flat list.
    unreachable: [...dead, ...unmeasured],
  };

  if (asJson) {
    console.log(JSON.stringify(payload, null, 2));
  } else {
    console.log(`catalog: ${payload.entries} entries, ${payload.categories} categories`);
    console.log(`mode: ${offline ? 'offline (shape + policy only)' : `online (shape + policy + reachability${strict ? ', strict' : ''})`}`);
    if (warnings.length) {
      console.log(`\nWARN ${warnings.length}`);
      for (const w of warnings) console.log(`  - ${w.id}: ${w.msg}`);
    }
    if (errors.length) {
      console.log(`\nFAIL ${errors.length} policy/shape errors`);
      for (const e of errors) console.log(`  - ${e.id}: ${e.msg}`);
    }
    if (!offline) {
      if (dead.length) {
        console.log(`\nFAIL ${dead.length} entries point at a dead page (our data is wrong)`);
        for (const d of dead) {
          const detail = d.bad.map((b) => `${b.status || 'ERR'} ${b.url}`).join(' | ');
          console.log(`  - ${d.id} (${d.name}): ${detail}`);
        }
      }
      if (unmeasured.length) {
        const label = strict ? 'FAIL' : 'NOTE';
        console.log(`\n${label} ${unmeasured.length} could not be measured from this machine`);
        console.log('  (timeout / connection reset / site refuses scripted clients - says nothing about the page)');
        for (const m of unmeasured) {
          const detail = m.bad
            .map((b) => `${b.status || 'ERR'} ${b.url}${b.probeBlocked ? ' [known-refusing host]' : ''}`)
            .join(' | ');
          console.log(`  - ${m.id} (${m.name}): ${detail}`);
        }
      }
      if (!dead.length && !unmeasured.length) {
        console.log(`\nOK   all ${list.length} entries reachable`);
      }
    }
    console.log(`\nVERDICT: ${payload.ok ? 'PASS' : 'FAIL'}`);
  }

  process.exit(payload.ok ? 0 : 1);
}

/**
 * Only run when executed directly. `tools/verify-drivers.mjs` imports the
 * FORBIDDEN_HOSTS / FORBIDDEN_EXACT_HOSTS lists from here instead of keeping a
 * second copy, and without this guard that import would run the whole catalogue
 * check and call process.exit() on the importer.
 */
const invokedDirectly = (() => {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();

if (invokedDirectly) main();
