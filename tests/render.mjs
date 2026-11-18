/**
 * Mounts the merged WINDOWS工具箱 panel in a miniature React runtime with a
 * stubbed host (slots / locale / fetch), re-rendering until the tree settles.
 *
 * Why this exists: the agent cannot click into the DSH window — the desktop-input
 * lane refuses to target a DSH host executable (HOST_INPUT_DENIED), and opening
 * the GUI URL in a browser lane is refused too (WCU_POLICY_DENIED). So "does the
 * panel actually mount and paint" is otherwise unverifiable. This catches
 * ReferenceErrors, missing dict keys, undeclared state, bad element types,
 * mojibake, and URLs that escape the plugin namespace.
 *
 * Not a browser: no layout, no CSS, no real React reconciliation. It proves the
 * component tree renders without throwing and produces the expected strings.
 *
 * The merged plugin is two halves behind one sidebar entry, and this harness
 * asserts both:
 *
 *   WINDOWS_TOOLBOX_PANEL=manage   (default) the plugin-manager half
 *   WINDOWS_TOOLBOX_PANEL=toolbox  clicks the「工具箱」tab first, then the toolbox
 *
 *   node tests/render.mjs
 *   WINDOWS_TOOLBOX_PANEL=toolbox node tests/render.mjs
 *   WINDOWS_TOOLBOX_LANG=en       node tests/render.mjs   # render the English dictionary
 *   WINDOWS_TOOLBOX_DEBUG=1       node tests/render.mjs   # dump render passes and text
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const CLIENT = process.argv[2] ?? fileURLToPath(new URL('../client.js', import.meta.url));
const FIXTURES_FILE = fileURLToPath(new URL('./fixtures.json', import.meta.url));
const src = readFileSync(CLIENT, 'utf8');
const FIXTURES = JSON.parse(readFileSync(FIXTURES_FILE, 'utf8'));
const LANG = process.env.WINDOWS_TOOLBOX_LANG ?? 'zh';
const PANEL = process.env.WINDOWS_TOOLBOX_PANEL ?? 'manage';
const DEBUG = process.env.WINDOWS_TOOLBOX_DEBUG === '1';
const MAX_PASSES = 30;

if (PANEL !== 'manage' && PANEL !== 'toolbox') {
  throw new Error(`WINDOWS_TOOLBOX_PANEL must be 'manage' or 'toolbox', got '${PANEL}'`);
}

/* ------------------------------------------------------------- fake react */

const React = {
  createElement(type, props, ...children) {
    const kids = children.length === 1 ? children[0] : (children.length ? children : undefined);
    return { type, props: props ?? {}, children: kids };
  },
  Fragment: Symbol('Fragment'),
};

/**
 * Frames persist across passes so useState keeps its value, like real hooks.
 *
 * Identity matters more in the merged plugin than it did in either half alone:
 * the shell shows ONE half at a time, and both halves define a component
 * literally named `Panel`. Keying frames by visit order alone would hand the
 * toolbox Panel the manage Panel's hook slots the moment the tab switches, and
 * the panel would explode on state of the wrong type (observed: `results` came
 * back null because it inherited a different component's slot). So the key is
 * the component FUNCTION IDENTITY plus its ordinal within the pass.
 */
let frames = new Map();
let fnIds = new Map();
let nextFnId = 1;
let passCounters = new Map();
let hookStack = [];
let visitOrder = 0;
let dirty = false;
let effects = [];

function frameKeyFor(fn) {
  let id = fnIds.get(fn);
  if (id === undefined) { id = nextFnId; nextFnId += 1; fnIds.set(fn, id); }
  const ordinal = passCounters.get(id) ?? 0;
  passCounters.set(id, ordinal + 1);
  return `c${id}#${ordinal}`;
}

function useSlot(init) {
  const frame = hookStack[hookStack.length - 1];
  if (!frame) throw new Error('hook called outside a component');
  const i = frame.cursor++;
  if (!frame.slots) frame.slots = [];
  if (!(i in frame.slots)) frame.slots[i] = { v: typeof init === 'function' ? init() : init };
  return frame.slots[i];
}

function depsChanged(prev, next) {
  if (!prev || !next) return true;
  if (prev.length !== next.length) return true;
  return next.some((d, i) => !Object.is(d, prev[i]));
}

React.useState = (init) => {
  const slot = useSlot(init);
  const set = (next) => {
    const value = typeof next === 'function' ? next(slot.v) : next;
    if (!Object.is(value, slot.v)) { slot.v = value; dirty = true; }
  };
  return [slot.v, set];
};
// NOTE: writing `useSlot({ current: init }).ref` here returns undefined — the
// slot itself is the ref object, so `.v` is the box with `.current` inside it.
React.useRef = (init) => useSlot({ current: init }).v;
React.useMemo = (fn, deps) => {
  const slot = useSlot(null);
  if (slot.seeded && !depsChanged(slot.deps, deps)) return slot.v;
  slot.v = fn();
  slot.deps = deps;
  slot.seeded = true;
  return slot.v;
};
React.useCallback = (fn, deps) => React.useMemo(() => fn, deps);
React.useEffect = (fn, deps) => {
  const slot = useSlot(null);
  if (slot.seeded && !depsChanged(slot.deps, deps)) return;
  slot.deps = deps;
  slot.seeded = true;
  effects.push(fn);
};

function expand(node, depth) {
  if (depth > 80) throw new Error('render tree too deep — possible infinite recursion');
  if (node == null || node === false || node === true) return node;
  if (typeof node === 'string' || typeof node === 'number') return String(node);
  if (Array.isArray(node)) return node.map((n) => expand(n, depth + 1));
  if (typeof node !== 'object') return node;

  const { type, props } = node;
  if (type === React.Fragment) return expand(props?.children ?? node.children, depth + 1);

  if (typeof type === 'function') {
    const key = frameKeyFor(type);
    const frame = frames.get(key) ?? { cursor: 0, slots: [] };
    frames.set(key, frame);
    frame.cursor = 0;
    visitOrder += 1;
    hookStack.push(frame);
    try {
      // A component may render either `h(X, props, ...children)` (children on the
      // node) or `X(props)` returning an element that carries them; expand() only
      // ever reads props.children, so mirror the node's children into props.
      const withChildren = node.children === undefined
        ? (props ?? {})
        : { ...(props ?? {}), children: node.children };
      return expand(type(withChildren), depth + 1);
    } finally {
      hookStack.pop();
    }
  }

  if (typeof type === 'string') {
    const kids = props?.children ?? node.children;
    return { type, props: { ...props, children: expand(kids, depth + 1) } };
  }

  throw new Error(`element type is not renderable: ${String(type)}`);
}

/* --------------------------------------------------------------- fake host */

/**
 * Namespace-aware locale. The merged client registers THREE dictionaries —
 * `dsh-windows-toolbox` (shell), `-manage`, `-toolbox` — and both halves define
 * nav/title/refresh/loading with different wording. A single flat table (what
 * the pre-merge harnesses used) would let the last registration shadow the
 * others, and then the missing-key check would silently prove nothing.
 */
const byNs = {};
const seenByNs = {};
const registeredNs = [];
const mod = { id: null };
const fetchLog = [];

function lookup(path) {
  const halves = Object.entries(FIXTURES.halves);
  let best = null;
  for (const [, cfg] of halves) {
    for (const [k, v] of Object.entries(cfg.payloads)) {
      if (!path.includes(k)) continue;
      if (!best || k.length > best.k.length) best = { k, v };
    }
  }
  return best ? best.v : { ok: true };
}

const sandbox = {
  window: {
    __ModuleLoader__: {
      load(spec) {
        mod.id = spec.id;
        mod.exports = spec.factory((name) => {
          if (name === 'react') return React;
          throw new Error(`unexpected require(${name})`);
        });
      },
    },
  },
  document: { baseURI: 'http://127.0.0.1:51923/' },
  URL, URLSearchParams,
  fetch: async (url, init) => {
    const path = String(url);
    fetchLog.push(`${init?.method ?? 'GET'} ${path}`);
    return { ok: true, status: 200, json: async () => lookup(path) };
  },
  console,
  setTimeout, clearTimeout, queueMicrotask,
  setInterval: () => 0, clearInterval: () => {}, requestAnimationFrame: () => 0,
  Promise, Set, Map, Error, JSON, Object, Array, Number, String, Boolean, Math, RegExp, Date,
  isNaN, parseInt, parseFloat, isFinite,
};

vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: CLIENT });

if (!mod.exports) throw new Error('client.js did not call __ModuleLoader__.load');
if (mod.id !== 'dsh-windows-toolbox') {
  throw new Error(`expected module id 'dsh-windows-toolbox', got '${mod.id}'`);
}

const registered = {};

const ctx = {
  effect(fn) { const off = fn(); return typeof off === 'function' ? off : () => {}; },
  locale: {
    register(ns, dict) {
      const layer = dict?.[LANG] ?? dict;
      byNs[ns] = layer;
      registeredNs.push(ns);
      seenByNs[ns] = seenByNs[ns] ?? new Set();
      return () => { delete byNs[ns]; };
    },
    // client.js does `t = ctx.locale.bind(NS)`, so THIS closure is what the panel
    // really calls — the missing-key check has to live here, per namespace.
    bind(ns) {
      return (k) => {
        const table = byNs[ns] ?? {};
        seenByNs[ns] = seenByNs[ns] ?? new Set();
        seenByNs[ns].add(k);
        const v = table[k];
        if (v === undefined) throw new Error(`missing dict key: ${ns}:${k}`);
        return v;
      };
    },
    getSnapshot() { return { active: LANG, locales: [LANG, 'zh', 'en'], revision: 1 }; },
  },
  theme: { token() { return ''; } },
  inject(names, fn) {
    const stub = {};
    for (const n of names) {
      stub[n] = n === 'layout'
        ? { selectPanel() {}, panelInfo: { getSnapshot: () => ({}) } }
        : {};
    }
    fn(stub);
  },
  slots: {
    inject(_name, fn) { fn(); return () => {}; },
    register(spec, render) {
      if (spec.name === 'main') registered.main = { spec, render };
      if (spec.name === 'sidebar.panellist') registered.sidebar = { spec, render };
      return () => {};
    },
  },
};

mod.exports.apply(ctx);

if (!registered.main) throw new Error('main slot not registered');
if (!registered.sidebar) throw new Error('sidebar.panellist slot not registered');
if (registeredNs.length !== 3) {
  throw new Error(`expected 3 locale namespaces, got ${registeredNs.length}: ${registeredNs.join(', ')}`);
}

/* ------------------------------------------------------- mount + re-render */

const tShell = (k) => byNs['dsh-windows-toolbox']?.[k] ?? k;  // fallback only

let tree = null;

/**
 * Render until nothing is dirty. Extracted so the test can also drive the panel
 * the way a user does — click a tab, click a capability card — then settle
 * again, instead of only ever observing the default screen.
 */
async function settle() {
  for (let pass = 0; pass < MAX_PASSES; pass += 1) {
    visitOrder = 0;
    passCounters = new Map();
    dirty = false;
    effects = [];
    tree = expand(registered.main.render({}), 0);
    if (DEBUG) console.error(`pass ${pass}: effects=${effects.length} dirty=${dirty}`);
    for (const fn of effects) fn();
    // Effects start promise chains (status → getJSON → fetch). Drain macrotasks so
    // every await in those chains resolves before deciding whether to re-render.
    for (let i = 0; i < 8; i += 1) await new Promise((r) => setTimeout(r, 0));
    if (DEBUG) console.error(`pass ${pass}: settled dirty=${dirty} fetch=${fetchLog.length}`);
    if (!dirty) break;
    if (pass === MAX_PASSES - 1) throw new Error(`panel never settled after ${MAX_PASSES} passes`);
  }
  return tree;
}

await settle();

/* ------------------------------------------------------------- tree utils */

function textOf(node) {
  if (node == null || node === false) return '';
  if (typeof node === 'string') return node;
  if (Array.isArray(node)) return node.map(textOf).join(' ');
  if (typeof node !== 'object') return '';
  if (!('type' in node)) return '';
  // expand() keeps children under props.children, not node.children.
  let out = textOf(node.props?.children);
  for (const [k, v] of Object.entries(node.props ?? {})) {
    if (k === 'style' || k === 'children' || /^on/.test(k)) continue;
    if (typeof v === 'string') out += ` ${v}`;
  }
  return out;
}

function collectTexts(root) {
  const out = [];
  (function walk(n) {
    if (n == null || n === false) return;
    if (typeof n === 'string') { out.push(n); return; }
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (typeof n !== 'object' || !('type' in n)) return;
    walk(n.props?.children);
  }(root));
  return out;
}

function findClickable(node, needle, acc = []) {
  if (node == null || node === false) return acc;
  if (Array.isArray(node)) { node.forEach((n) => findClickable(n, needle, acc)); return acc; }
  if (typeof node !== 'object' || !('type' in node)) return acc;
  const clickable = typeof node.props?.onClick === 'function';
  if (clickable && textOf(node).includes(needle)) acc.push(node);
  findClickable(node.props?.children, needle, acc);
  return acc;
}

async function clickText(needle) {
  const hits = findClickable(tree, needle);
  if (!hits.length && DEBUG) {
    const all = findClickable(tree, '');
    console.error('CLICKABLES:', JSON.stringify(all.slice(0, 12).map((n) => textOf(n).slice(0, 60))));
  }
  if (!hits.length) throw new Error(`no clickable node mentions "${needle}" — the harness cannot reach that screen`);
  hits[0].props.onClick({ stopPropagation() {}, preventDefault() {} });
  await settle();
}

/** All rendered text below one node, flattened. */
function textOfAll(node) { return collectTexts(node).join(' '); }

/** First clickable card whose own text mentions `needle`. */
function findCard(root, needle) {
  let hit = null;
  (function walk(n) {
    if (hit || n == null || n === false || typeof n !== 'object') return;
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (!('type' in n)) return;
    if (n.props?.role === 'button' && typeof n.props?.onClick === 'function'
      && textOfAll(n).includes(needle)) { hit = n; return; }
    walk(n.props?.children);
  }(root));
  return hit;
}

/* ------------------------------------------------- the shell (both tabs) */

const sidebarGlyph = expand(registered.sidebar.render({ size: 16 }), 0);
const shellDict = byNs['dsh-windows-toolbox'];

if (!shellDict) throw new Error('shell dictionary was never registered');

const sidebarLabel = registered.sidebar.spec.label?.();
if (sidebarLabel !== shellDict.nav) {
  throw new Error(`sidebar label is "${sidebarLabel}", expected "${shellDict.nav}"`);
}
// One entry, not two: the whole point of the merge.
if (registered.sidebar.spec.id !== 'dsh-windows-toolbox') {
  throw new Error(`sidebar id is "${registered.sidebar.spec.id}", expected 'dsh-windows-toolbox'`);
}
if (registered.sidebar.spec.order !== 7) {
  throw new Error(`sidebar order is ${registered.sidebar.spec.order}, expected 7`);
}

/** Both tabs must be on screen with their own labels, and exactly one active. */
function shellTabs() {
  const tabs = [];
  (function walk(n) {
    if (n == null || n === false || typeof n !== 'object') return;
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (!('type' in n)) return;
    if (n.props?.role === 'tab') tabs.push({ label: textOfAll(n).trim(), active: n.props['aria-selected'] === 'true' });
    walk(n.props?.children);
  }(tree));
  return tabs;
}

const tabs = shellTabs();
if (tabs.length !== 2) throw new Error(`expected 2 tabs, found ${tabs.length}: ${JSON.stringify(tabs)}`);
const tabManageLabel = shellDict.tabManage;
const tabToolboxLabel = shellDict.tabToolbox;
// Two tabs with the same words are unusable: neither the user nor this test can
// tell which half is on screen. (A negative control collapsed both labels to the
// same string and this block was the only thing that could catch it — without
// the distinctness check the run still passed.)
if (tabManageLabel === tabToolboxLabel) {
  throw new Error(`both tab labels read "${tabManageLabel}" — the halves are indistinguishable`);
}
for (const want of [tabManageLabel, tabToolboxLabel]) {
  if (!tabs.some((x) => x.label === want)) {
    throw new Error(`tab "${want}" is missing; tabs are ${JSON.stringify(tabs)}`);
  }
}
if (new Set(tabs.map((x) => x.label)).size !== 2) {
  throw new Error(`duplicate tab labels on screen: ${JSON.stringify(tabs)}`);
}
if (tabs.filter((x) => x.active).length !== 1) {
  throw new Error(`exactly one tab must be selected, got ${JSON.stringify(tabs)}`);
}

const activeTab = tabs.find((x) => x.active).label;
if (PANEL === 'manage' && activeTab !== tabManageLabel) {
  throw new Error(`panel opens on "${activeTab}", expected the manage tab`);
}

// The toolbox half lives behind its tab; click it before asserting anything
// about that half, so "the tab exists but nothing is behind it" cannot pass.
if (PANEL === 'toolbox') {
  if (activeTab !== tabToolboxLabel) await clickText(tabToolboxLabel);
  const after = shellTabs();
  if (!after.some((x) => x.active && x.label === tabToolboxLabel)) {
    throw new Error(`clicking "${tabToolboxLabel}" did not select it: ${JSON.stringify(after)}`);
  }
}

/* --------------------------------------------------------------- validate */

const cfg = FIXTURES.halves[PANEL];
if (!cfg) throw new Error(`fixtures.json has no '${PANEL}' half`);

// The assertions are language-specific: the panel swaps its whole dictionary,
// so checking English output against Chinese strings would only ever fail (and
// then get "fixed" by deleting the English run).
const langCfg = {
  mustShow: cfg.mustShow[LANG] ?? cfg.mustShow.zh,
  labels: cfg.labels[LANG] ?? cfg.labels.zh,
};
if (!langCfg.mustShow?.length) throw new Error(`fixtures.json has no mustShow for lang '${LANG}'`);

const texts = collectTexts(tree);
const badTypes = new Set();
const urls = [];
(function walk(node) {
  if (node == null || node === false) return;
  if (Array.isArray(node)) { node.forEach(walk); return; }
  if (typeof node !== 'object') return;
  if (!('type' in node)) return;  // style objects / plain prop values
  if (typeof node.type !== 'string' || !/^[a-z][a-z0-9]*$/.test(node.type)) badTypes.add(String(node.type));
  for (const [k, v] of Object.entries(node.props ?? {})) {
    if (k === 'style') continue;
    if (typeof v === 'function' && /^on[A-Z]/.test(k)) continue;
    walk(v);
    if (typeof v === 'string' && v.startsWith('/')) urls.push(v);
  }
}(tree));

if (badTypes.size) throw new Error(`non-HTML element types survived expansion: ${[...badTypes].join(', ')}`);

const joined = texts.join(' ');
if (/\uFFFD/.test(joined)) throw new Error('rendered text contains U+FFFD (mojibake)');
if (!texts.length) throw new Error('panel rendered no text at all');

const strayUrls = [...new Set(urls.filter((u) => u.startsWith('/') && !u.startsWith('/dsh-windows-toolbox/api/')))];
if (strayUrls.length) {
  throw new Error(`panel produced URLs outside its own API namespace: ${strayUrls.join(', ')}`);
}

// The panel must paint real data, not just its chrome.
const absent = langCfg.mustShow.filter((s) => !joined.includes(s));
if (DEBUG) {
  console.error('--- DEBUG ---');
  console.error('panel:', PANEL, 'lang:', LANG, 'tab:', activeTab);
  console.error('absent:', absent);
  console.error('fetch:', fetchLog);
  console.error('text:', joined.slice(0, 1500));
}
if (absent.length) throw new Error(`panel did not paint expected content: ${absent.join(' | ')}`);

// The right half must have been the one that painted: prove its own API was
// called, not just that some text matched.
const apiPrefix = `/dsh-windows-toolbox/api/${PANEL}/`;
if (!fetchLog.some((line) => line.includes(`${apiPrefix}status`))) {
  throw new Error(`panel never asked ${apiPrefix}status for data`);
}

/* --------------------------------------------- manage: cards can be ACTED ON */

let faceReport = null;
let actionable = null;
let explainedOnly = null;
let expandedChars = null;

if (PANEL === 'manage') {
  const dict = byNs['dsh-windows-toolbox-manage'];
  if (!dict) throw new Error('manage dictionary was never registered');

  /**
   * The user's complaint was "大量卡片只能看不能操作": every verb lived inside
   * the expanded detail, so the panel read as a wall of inert text. The fix put
   * one primary verb on each card face, as a SIBLING of the expanding
   * role="button" node (nesting a button inside a button is invalid ARIA and
   * swallows clicks).
   */
  function faceOf(cardNode) {
    let found = null;
    (function walk(n) {
      if (found || n == null || n === false || typeof n !== 'object') return;
      if (Array.isArray(n)) { n.forEach(walk); return; }
      if (!('type' in n)) return;
      const kids = n.props?.children;
      const list = Array.isArray(kids) ? kids : (kids ? [kids] : []);
      if (list.includes(cardNode)) { found = list; return; }
      walk(kids);
    }(tree));
    return found ?? [];
  }

  function buttonTexts(nodes) {
    const out = [];
    (function walk(n) {
      if (n == null || n === false) return;
      if (Array.isArray(n)) { n.forEach(walk); return; }
      if (typeof n !== 'object' || !('type' in n)) return;
      // Two shapes count as a button: a host `<button>` tag (what Btn renders) and
      // anything carrying role="button" with a click handler (the card face).
      const isButton = n.type === 'button'
        || (n.props?.role === 'button' && typeof n.props?.onClick === 'function');
      if (isButton) {
        const label = textOfAll(n).trim();
        if (label) out.push(label);
        return;
      }
      walk(n.props?.children);
    }(nodes));
    return out;
  }

  const cards = [];
  (function walk(n) {
    if (n == null || n === false || typeof n !== 'object') return;
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (!('type' in n)) return;
    if (n.props?.role === 'button' && 'aria-expanded' in (n.props ?? {})) cards.push(n);
    walk(n.props?.children);
  }(tree));

  const rowCount = cfg.payloads['/dsh-windows-toolbox/api/manage/entries'].rows.length;
  if (cards.length < rowCount) {
    throw new Error(`expected >= ${rowCount} entry cards, found ${cards.length}`);
  }
  if (cards.some((c) => c.props['aria-expanded'] !== 'false')) {
    throw new Error('every card must start collapsed (aria-expanded=false)');
  }

  // The one-sentence explanation has to be on the CARD FACE — the whole point of
  // the redesign is that nobody has to click to learn what a thing is.
  const faceAbsent = cfg.explainOnFace.filter((s) => !joined.includes(s));
  if (faceAbsent.length) {
    throw new Error(`card faces did not render explain.what/where: ${faceAbsent.join(' | ')}`);
  }

  // explain === null must degrade to the raw state plus an honest note, not crash.
  if (!dict.noExplain) throw new Error('dictionary has no noExplain string');
  if (!joined.includes(dict.noExplain)) {
    throw new Error('an entry with explain === null did not render the noExplain fallback');
  }

  // Nothing detail-only may leak into the collapsed view.
  const leaked = cfg.explainOnExpand.filter((s) => joined.includes(s));
  if (leaked.length) {
    throw new Error(`collapsed cards rendered detail-only text: ${leaked.join(' | ')}`);
  }

  faceReport = cards.map((c) => {
    const siblings = faceOf(c).filter((s) => s !== c);
    const btns = buttonTexts(siblings);
    const otherText = siblings.map((s) => (typeof s === 'string' ? s : textOfAll(s))).join(' ').trim();
    return {
      name: (textOfAll(c).split(' ')[0] ?? '').slice(0, 24),
      buttons: btns,
      // A card with no verb must still say why: 受保护 / 仅查看.
      explains: btns.length > 0
        || otherText.includes(dict.riskBlockedNote)
        || otherText.includes(dict.readonlyBadge),
      text: otherText.slice(0, 120),
    };
  });

  const inert = faceReport.filter((f) => !f.explains);
  if (inert.length) {
    throw new Error(
      `${inert.length} collapsed card(s) are neither actionable nor explained: `
      + inert.map((f) => `${f.name} [${f.text}]`).join(' | '),
    );
  }
  actionable = faceReport.filter((f) => f.buttons.length > 0).length;
  explainedOnly = faceReport.filter((f) => f.buttons.length === 0).length;
  if (actionable === 0) {
    throw new Error('no card face exposes an action button — the panel is read-only again');
  }
  if (!dict.actionDisable || !dict.actionUninstall) {
    throw new Error('dictionary lost the face verb labels');
  }
  if (!joined.includes(dict.actionDisable)) {
    throw new Error(`no card face shows "${dict.actionDisable}" — enabled rows lost their verb`);
  }
  if (!joined.includes(dict.actionUninstall)) {
    throw new Error(`no card face shows "${dict.actionUninstall}" — programs lost their uninstall`);
  }

  /* ------------------------------------------------------- click to expand */

  const card = findCard(tree, cfg.openName);
  if (!card) throw new Error(`no clickable card for "${cfg.openName}"`);

  card.props.onClick({ stopPropagation() {}, preventDefault() {} });
  await settle();

  const expandedJoined = collectTexts(tree).join(' ');
  expandedChars = expandedJoined.length;

  const expandAbsent = cfg.explainOnExpand.filter((s) => !expandedJoined.includes(s));
  if (expandAbsent.length) {
    throw new Error(`expanded card missing purpose/ifOff/facts: ${expandAbsent.join(' | ')}`);
  }
  if (!expandedJoined.includes(dict.exp_raw)) throw new Error('expanded card has no raw-data summary');
  if (!expandedJoined.includes(dict.actionDryRun)) throw new Error('expanded card has no dry-run button');

  const openAfter = [];
  (function walk(n) {
    if (n == null || n === false || typeof n !== 'object') return;
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (!('type' in n)) return;
    if (n.props?.role === 'button' && n.props?.['aria-expanded'] === 'true') openAfter.push(n);
    walk(n.props?.children);
  }(tree));
  if (openAfter.length !== 1) throw new Error(`expected exactly 1 expanded card, got ${openAfter.length}`);
}

/* ------------------------------ toolbox: a capability is reachable by clicking */

let interaction = null;

if (PANEL === 'toolbox') {
  const dict = byNs['dsh-windows-toolbox-toolbox'];
  if (!dict) throw new Error('toolbox dictionary was never registered');

  // Everything above only ever looks at the landing screen, which is exactly how
  // a control can exist and still be unreachable. Drive it like a user: switch to
  // the network group, open the DNS capability, and assert the parameter form is
  // actually on screen with the values it is supposed to offer.
  await clickText(langCfg.labels.networkGroup);
  const afterGroup = textOfAll(tree);
  if (!afterGroup.includes(langCfg.labels.dnsCap)) {
    throw new Error(`clicking the network group did not reach the DNS capability: ${afterGroup.slice(0, 240)}`);
  }

  // The scan result is served from the cache for this capability, so the panel
  // paints real rows before asking for anything.
  await clickText(langCfg.labels.dnsCap);
  if (!fetchLog.some((line) => line.includes(`${apiPrefix}result?id=netdiag`))) {
    throw new Error('selecting the DNS capability never asked the host for its cached result');
  }

  const formText = textOfAll(tree);
  const missingDns = [
    langCfg.labels.dnsFormTitle,   // "切换到这个 DNS" — the form's own heading
    '223.5.5.5',               // a candidate the panel must always offer
    '119.6.6.6',               // the resolver this machine actually uses
  ].filter((s) => !formText.includes(s));
  if (missingDns.length) {
    throw new Error(`DNS form is not usable on screen — missing ${missingDns.join(', ')}`);
  }

  interaction = { group: langCfg.labels.networkGroup, capability: langCfg.labels.dnsCap, formChars: formText.length };
}

/* ------------------------------------------------------------------ report */

const dictKeysDefined = PANEL === 'manage'
  ? Object.keys(byNs['dsh-windows-toolbox-manage'] ?? {}).length
  : Object.keys(byNs['dsh-windows-toolbox-toolbox'] ?? {}).length;
const dictKeysUsed = seenByNs[PANEL === 'manage' ? 'dsh-windows-toolbox-manage' : 'dsh-windows-toolbox-toolbox']?.size ?? 0;

console.log(JSON.stringify({
  ok: true,
  moduleId: mod.id,
  panel: PANEL,
  lang: LANG,
  namespaces: registeredNs,
  slots: {
    main: registered.main.spec.key ?? null,
    sidebar: registered.sidebar.spec.id ?? null,
    order: registered.sidebar.spec.order ?? null,
    label: sidebarLabel,
    sidebarGlyph: sidebarGlyph?.type?.name ?? sidebarGlyph?.type ?? null,
  },
  // Re-read after every click: the opening tab is only interesting for the
  // manage half, and reporting the pre-click state for the toolbox half would
  // claim the panel never switched when it did.
  tabs: shellTabs().map((x) => x.label),
  activeTab: shellTabs().find((x) => x.active)?.label ?? null,
  openedTab: activeTab,
  dictKeysDefined,
  dictKeysUsed,
  textNodes: texts.length,
  chars: joined.length,
  fetchCalls: [...new Set(fetchLog)],
  mustShowFound: langCfg.mustShow.length,
  cards: faceReport?.length ?? null,
  faceActions: actionable,
  faceExplainedOnly: explainedOnly,
  explainOnFace: cfg.explainOnFace?.length ?? null,
  explainOnExpand: cfg.explainOnExpand?.length ?? null,
  expandedCard: PANEL === 'manage' ? cfg.openName : null,
  expandedChars,
  interaction,
  sample: joined.slice(0, 300),
}, null, 2));
