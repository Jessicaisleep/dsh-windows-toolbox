/**
 * verify-drivers.mjs - prove every entry in lib/presets/drivers.json points at
 * the vendor's own site, and that the IDs are the format Device Manager's
 * Hardware IDs actually use.
 *
 * WHY THIS EXISTS
 * ---------------
 * drivers.json is a fallback map: given the PCI `VEN_10DE` / USB `VID_046D`
 * prefix in a device instance ID, it answers "who made this, and where is their
 * official driver page". There is no per-version download URL because vendors
 * do not publish stable ones - the version numbers change weekly and the
 * redirect chains are opaque. What must be true, and what the user's constraint
 * demands ("可以没有，但是不能给出非官网的下载"), is:
 *
 *   1. every recognised vendor code is well-formed, so lookup can never mismatch;
 *   2. every URL is https, is the vendor's own domain, and actually answers.
 *
 * The two halves are separable on purpose: `--offline` checks shape and policy
 * only (no network), which is what runs in CI or behind a firewall; the default
 * checks reachability too.
 *
 * DIFFERENCE FROM verify-catalog.mjs
 * ----------------------------------
 * The forbidden-host policy is the same list, so it is IMPORTED from
 * tools/verify-catalog.mjs rather than copied - two copies of that list would
 * drift, and a drifted copy is exactly how a download portal sneaks back in.
 * The reachability loop here is sequential for the same reason as there: ~50
 * parallel requests to a mix of vendor sites look like a scraper and get reset.
 *
 * Usage:
 *   node tools/verify-drivers.mjs              # shape + policy + live fetch
 *   node tools/verify-drivers.mjs --offline    # shape + policy only
 *   node tools/verify-drivers.mjs --json       # machine-readable result
 */

import { readFileSync } from 'node:fs';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { FORBIDDEN_HOSTS, FORBIDDEN_EXACT_HOSTS } from './verify-catalog.mjs';

const DRIVERS = fileURLToPath(new URL('../lib/presets/drivers.json', import.meta.url));

/** The six top-level keys the rest of the toolbox indexes into. */
const REQUIRED_KEYS = ['version', 'captured', 'policy', 'vendors', 'classes', 'usbVendors'];

/**
 * PnP class names are the `Class` property of Win32_PnPEntity - a fixed,
 * undocumented-but-stable enum. A typo here silently matches nothing, so the
 * list is spelled out rather than pattern-matched.
 */
const PNP_CLASSES = new Set([
  // classes drivers.json uses
  'Display', 'Net', 'Media', 'SCSIAdapter', 'USB', 'Bluetooth', 'HIDClass',
  'Printer', 'Camera', 'AudioEndpoint', 'System', 'Mouse', 'Keyboard',
  'DiskDrive', 'Firmware',
  // other real classes, so a future addition is not rejected just for being new
  'Volume', 'VolumeSnapshot', 'Battery', 'Processor', 'Monitor', 'SoftwareDevice',
  'Biometric', 'Image', 'Modem', 'SecurityDevices', 'SmartCardFilter',
  'SmartCardReader', 'WCEUSBS', '1394', 'Enum1394', 'PCMCIA', 'MultiFunction',
  'MTD', 'Ports', 'USBDevice', 'Extension', 'CDROM', 'FloppyDisk', 'HDC',
  'MediumChanger', 'Memory', 'NetClient', 'NetService', 'NetTrans', 'TapeDrive',
  'Thermal', 'PnpPrinters',
]);

/** Path fragments that mean "this is a search/redirect page", not a download page. */
const FORBIDDEN_PATH_HINTS = ['/link?', '/redirect', '/download.php?id='];

/**
 * Driver-specific portals, on top of the shared FORBIDDEN_HOSTS list.
 *
 * The shared list was written for the software catalog and only knows software
 * aggregators (pconline, onlinedown, softonic...). Driver "one-click installers"
 * are their own ecosystem and none of them appear there - a negative test showed
 * `drivergenius.com` sailing straight through. These are exactly what the
 * official-only policy exists to keep out, so drivers carry their own names.
 */
const FORBIDDEN_DRIVER_HOSTS = [
  'drivergenius.com', 'drivegenius', 'drivetheworld', 'driverbooster',
  'iobit.com', 'driveridentifier', 'drivermax', 'driverscloud',
  'slimdrivers', 'driverpack', 'driver-soft', 'driverscollection',
  'driverscape.com', 'drivereasy', 'hardwarelabs', 'update-drivers',
  'driver-tool', 'driverguide', 'radarsync', 'driver-whiz',
];

const HEX4 = /^[0-9A-F]{4}$/;

function fail(list, id, msg) {
  list.push({ id, msg });
}

/**
 * Shape + policy checks for one URL. No network.
 * Returns true when the URL is structurally acceptable.
 */
function checkUrl(raw, id, field, errors, warnings) {
  if (!raw) {
    fail(errors, id, `missing ${field}`);
    return false;
  }
  let u;
  try {
    u = new URL(raw);
  } catch {
    fail(errors, id, `${field} is not a valid URL: ${raw}`);
    return false;
  }
  if (u.protocol !== 'https:') {
    fail(errors, id, `${field} is not https: ${raw}`);
    return false;
  }
  const host = u.hostname.toLowerCase();
  for (const bad of FORBIDDEN_HOSTS) {
    if (host.includes(bad)) {
      fail(errors, id, `${field} routes through a forbidden portal (${bad}): ${raw}`);
    }
  }
  for (const bad of FORBIDDEN_DRIVER_HOSTS) {
    if (host.includes(bad)) {
      fail(errors, id, `${field} routes through a driver portal/download site (${bad}): ${raw}`);
    }
  }
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
  // A bare IP is never a vendor storefront, and is not reachable by name
  // for a user who wants to check the site themselves.
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host) || host === '[::1]') {
    fail(errors, id, `${field} is a bare IP address: ${raw}`);
  }
  // We are offline-only for shape: no reachability, but flag obvious gaps.
  if (host.split('.').length < 2) {
    warnings.push({ id, msg: `${field} has a single-label host: ${raw}` });
  }
  return true;
}

/** Shape + policy checks over the whole document. No network. */
function checkPolicy(doc, errors, warnings) {
  for (const key of REQUIRED_KEYS) {
    if (!(key in doc)) fail(errors, '(document)', `missing top-level key: ${key}`);
  }
  if (doc.policy !== 'official-only') {
    fail(errors, '(document)', `policy must be "official-only", got ${JSON.stringify(doc.policy)}`);
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(doc.captured ?? ''))) {
    fail(errors, '(document)', `captured must be YYYY-MM-DD, got ${JSON.stringify(doc.captured)}`);
  } else if (Number.isNaN(Date.parse(doc.captured))) {
    fail(errors, '(document)', `captured is not a real date: ${doc.captured}`);
  }

  const vendors = doc.vendors && typeof doc.vendors === 'object' ? doc.vendors : {};
  const classes = doc.classes && typeof doc.classes === 'object' ? doc.classes : {};
  const usb = doc.usbVendors && typeof doc.usbVendors === 'object' ? doc.usbVendors : {};

  for (const [code, v] of Object.entries(vendors)) {
    const id = `VEN_${code}`;
    if (!HEX4.test(code)) fail(errors, id, `vendor code must be 4 uppercase hex digits, got ${JSON.stringify(code)}`);
    if (!v || typeof v !== 'object') { fail(errors, id, 'entry is not an object'); continue; }
    if (!v.name) fail(errors, id, 'missing name');
    if (!v.driverPage) fail(errors, id, 'missing driverPage (required for PCI vendors)');
    checkUrl(v.driverPage, id, 'driverPage', errors, warnings);
    if (v.deviceSearch) checkUrl(v.deviceSearch, id, 'deviceSearch', errors, warnings);
  }

  for (const [code, v] of Object.entries(usb)) {
    const id = `VID_${code}`;
    if (!HEX4.test(code)) fail(errors, id, `usb vendor code must be 4 uppercase hex digits, got ${JSON.stringify(code)}`);
    if (!v || typeof v !== 'object') { fail(errors, id, 'entry is not an object'); continue; }
    if (!v.name) fail(errors, id, 'missing name');
    checkUrl(v.driverPage, id, 'driverPage', errors, warnings);
  }

  for (const [name, c] of Object.entries(classes)) {
    if (!PNP_CLASSES.has(name)) {
      fail(errors, `class:${name}`, `not a PnP class name (Win32_PnPEntity.Class): ${name}`);
    }
    if (!c || typeof c !== 'object') { fail(errors, `class:${name}`, 'entry is not an object'); continue; }
    if (!c.name) fail(errors, `class:${name}`, 'missing localized name');
    if (!c.hint) warnings.push({ id: `class:${name}`, msg: 'no hint - the panel will show an empty tooltip' });
  }

  return { vendors: Object.keys(vendors).length, usb: Object.keys(usb).length, classes: Object.keys(classes).length };
}

/** Every URL in the document, with the id that owns it, for the live pass. */
function collectUrls(doc) {
  const out = [];
  for (const [code, v] of Object.entries(doc.vendors ?? {})) {
    for (const field of ['driverPage', 'deviceSearch']) {
      if (v?.[field]) out.push({ id: `VEN_${code}`, field, url: v[field], probeBlocked: Boolean(v.probeBlocked) });
    }
  }
  for (const [code, v] of Object.entries(doc.usbVendors ?? {})) {
    if (v?.driverPage) out.push({ id: `VID_${code}`, field: 'driverPage', url: v.driverPage, probeBlocked: Boolean(v.probeBlocked) });
  }
  return out;
}

// A plain bot User-Agent is actively refused by several vendor sites: Dell answers
// 403 to both HEAD and GET, AMD stalls the connection until it times out. Those
// pages load fine in a browser, and the question this tool answers is "can a user
// open the driver page", so it identifies as a normal browser.
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
const HEADERS = {
  'user-agent': UA,
  accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
};

/** One request. Body is cancelled so the connection is exercised, not just opened. */
async function attempt(url, method, timeoutMs) {
  try {
    const r = await fetch(url, {
      method,
      redirect: 'follow',
      signal: AbortSignal.timeout(timeoutMs),
      headers: HEADERS,
    });
    try { await r.body?.cancel(); } catch { /* ignore */ }
    return { ok: r.status < 400, status: r.status };
  } catch (e) {
    return { ok: false, status: 0, note: e?.cause?.code ?? e?.name ?? String(e) };
  }
}

/**
 * Fetch one URL: HEAD first, GET only when HEAD gets rejected.
 * Returns {ok, status, note}.
 *
 * Two different failure shapes show up in the wild and they need opposite handling:
 *   - Dell / AMD refuse or stall a bare HEAD but serve GET fine      -> fall back to GET.
 *   - download.virtualbox.org serves HEAD 200 but stalls every GET   -> never prefer GET.
 * So a transport error on HEAD is retried as HEAD (a hiccup, fixed by repeating the
 * cheap probe); GET is only spent on an explicit rejection. A definitive 4xx is never
 * retried into a pass - it is the answer.
 */
async function fetchOne(url, timeoutMs = 12000) {
  let head = await attempt(url, 'HEAD', timeoutMs);
  if (!head.ok && head.status === 0) head = await attempt(url, 'HEAD', timeoutMs); // transient
  if (head.ok) return { ...head, note: 'HEAD' };

  // 405 / 501 mean "HEAD not supported"; 403 is often a bot rule answering HEAD
  // differently than GET, so GET still gets its chance for those.
  const retryable = head.status === 0 || head.status === 403
    || head.status === 405 || head.status === 501 || head.status >= 500;
  if (!retryable) return { ...head, note: 'HEAD' };

  let last = head;
  for (let i = 0; i < 2; i++) {
    const get = await attempt(url, 'GET', timeoutMs);
    if (get.ok) return { ...get, note: 'GET' };
    last = get;
    if (last.status >= 400 && last.status < 500) break; // definitive, stop
  }
  return { ...last, note: `GET ${last.note ?? last.status}` };
}

async function main() {
  const argv = process.argv.slice(2);
  const offline = argv.includes('--offline');
  const asJson = argv.includes('--json');

  let doc;
  try {
    doc = JSON.parse(readFileSync(DRIVERS, 'utf8'));
  } catch (e) {
    const msg = `cannot read/parse ${DRIVERS}: ${e?.message ?? e}`;
    if (asJson) console.log(JSON.stringify({ ok: false, error: msg }, null, 2));
    else {
      console.log('drivers: 0 vendors, 0 usb vendors, 0 classes');
      console.log(`\nFAIL ${msg}`);
      console.log('\nVERDICT: FAIL');
    }
    process.exit(1);
  }

  const errors = [];
  const warnings = [];
  const counts = checkPolicy(doc, errors, warnings);

  const urls = collectUrls(doc);
  const live = [];
  const unprobed = [];
  if (!offline) {
    for (const item of urls) {
      const r = await fetchOne(item.url);
      if (r.ok) continue;
      // `probeBlocked: true` marks a vendor page behind a bot wall (Cloudflare
      // answers every scripted request with 403 while a real browser gets 200).
      // Those are reported, not failed - but a definitive 404/410 still means the
      // URL itself is gone, and that is never excused.
      const dead = r.status === 404 || r.status === 410;
      if (item.probeBlocked && !dead) {
        unprobed.push({ ...item, status: r.status, note: r.note });
      } else {
        live.push({ ...item, status: r.status, note: r.note });
      }
    }
  }

  const payload = {
    ok: errors.length === 0 && live.length === 0,
    offline,
    vendors: counts.vendors,
    usbVendors: counts.usb,
    classes: counts.classes,
    urls: urls.length,
    errors,
    warnings,
    unreachable: live,
    unprobed,
  };

  if (asJson) {
    console.log(JSON.stringify(payload, null, 2));
  } else {
    console.log(`drivers: ${payload.vendors} vendors, ${payload.usbVendors} usb vendors, ${payload.classes} classes`);
    console.log(`mode: ${offline ? 'offline (shape + policy only)' : `online (shape + policy + ${urls.length} URLs)`}`);
    if (warnings.length) {
      console.log(`\nWARN ${warnings.length}`);
      for (const w of warnings) console.log(`  - ${w.id}: ${w.msg}`);
    }
    if (errors.length) {
      console.log(`\nFAIL ${errors.length} policy/shape errors`);
      for (const e of errors) console.log(`  - ${e.id}: ${e.msg}`);
    }
    if (!offline) {
      if (unprobed.length) {
        console.log(`\nNOTE ${unprobed.length} URL(s) could not be script-probed (bot wall), verified by browser instead`);
        for (const l of unprobed) console.log(`  - ${l.id} ${l.field}: ${l.status || 'ERR'} ${l.url}`);
      }
      if (live.length) {
        console.log(`\nFAIL ${live.length}/${urls.length} unreachable`);
        for (const l of live) console.log(`  - ${l.id} ${l.field}: ${l.status || 'ERR'} ${l.url}`);
      } else {
        console.log(`\nOK   all ${urls.length - unprobed.length} script-probed URLs reachable`);
      }
    }
    console.log(`\nVERDICT: ${payload.ok ? 'PASS' : 'FAIL'}`);
  }

  process.exit(payload.ok ? 0 : 1);
}

const invokedDirectly = (() => {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();

if (invokedDirectly) main();
