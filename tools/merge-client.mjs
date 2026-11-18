/**
 * Merge the two client halves into one panel.
 *
 * Why a script instead of hand-editing 3647 lines: the transformation is purely
 * mechanical (slice the factory body, rewrite one API literal, drop the
 * registration block), and doing it by hand is how a 118 KB file quietly loses
 * a helper. Rules the script enforces, each failing loudly rather than silently:
 *
 *   1. both sources must have a `factory(require) {` line and a
 *      `// ---- module registration ----` marker;
 *   2. the API literal must appear exactly once in each body (the panels use a
 *      single `API` constant, so a second occurrence means someone hardcoded a
 *      path and the merge would produce a panel calling a dead URL);
 *   3. each body must define a top-level `function Panel(` and an icon
 *      function whose name the script is told about;
 *   4. the produced file must contain both Panels exactly once.
 *
 * The two bodies keep their OWN module scope (`DICT`, `Panel`, `API`, every
 * helper), which is the whole point: no renaming, no cross-talk, and each half
 * stays diffable against the plugin it came from. The only shared surface is the
 * tab shell below, plus two locale namespaces so the two dictionaries cannot
 * overwrite each other's keys (`nav`, `title`, `refresh`, `loading` all collide
 * by name but not by meaning).
 *
 * Usage: node tools/merge-client.mjs [--check]
 *   --check  build in memory and compare against the existing output, exit 1 on
 *            drift (used after any manual edit to catch a stale merge)
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');

const OUT = join(ROOT, 'client.js');
const CHECK = process.argv.includes('--check');

const SOURCES = [
  {
    half: 'manage',
    file: join(ROOT, 'tools', 'legacy', 'manage-client.js'),
    fnName: 'makeManageModule',
    icon: 'ManagerIcon',
    oldApi: "'/dsh-windows-plugin-manager/api'",
    newApi: "'/dsh-windows-toolbox/api/manage'",
  },
  {
    half: 'toolbox',
    file: join(ROOT, 'tools', 'legacy', 'toolbox-client.js'),
    fnName: 'makeToolboxModule',
    icon: 'ToolboxIcon',
    oldApi: "'/dsh-360-toolbox/api'",
    newApi: "'/dsh-windows-toolbox/api/toolbox'",
  },
];

function fail(message) {
  console.error(`merge-client: ${message}`);
  process.exit(1);
}

function sliceBody(src) {
  const factoryAt = src.search(/^\s*factory\(require\)\s*\{/m);
  if (factoryAt < 0) return null;
  const headEnd = src.indexOf('\n', factoryAt);
  if (headEnd < 0) return null;
  const markerAt = src.indexOf('// ---- module registration ----', headEnd);
  if (markerAt < 0) return null;
  return { headEnd, markerAt };
}

const halves = SOURCES.map((spec) => {
  if (!existsSync(spec.file)) fail(`missing source: ${spec.file}`);
  const src = readFileSync(spec.file, 'utf8');
  const bounds = sliceBody(src);
  if (!bounds) fail(`${spec.file}: no factory(require) / registration marker`);

  let body = src.slice(bounds.headEnd + 1, bounds.markerAt);

  // The API prefix is the one thing that must change: both sets of routes moved
  // under /dsh-windows-toolbox/api/<half>. Exactly one occurrence, by contract.
  const apiHits = body.split(spec.oldApi).length - 1;
  if (apiHits !== 1) fail(`${spec.file}: expected exactly 1 occurrence of ${spec.oldApi}, found ${apiHits}`);
  body = body.replace(spec.oldApi, spec.newApi);

  if (!/^\s{4}function Panel\(/m.test(body)) fail(`${spec.file}: no top-level function Panel(`);
  if (!new RegExp(`^\\s{4}function ${spec.icon}\\(`, 'm').test(body)) fail(`${spec.file}: no top-level function ${spec.icon}(`);

  // Each half's own `NS` / `PANEL_ID` become dead once its `apply()` is dropped:
  // the shell below owns the single registration and binds the three
  // namespaces. Keeping them would mean the generated file still declares
  // `const PANEL_ID = '<old plugin id>'` and similar stale names —
  // harmless at runtime but actively misleading to anyone reading the file (and
  // to anyone grepping for leftovers). Remove them, then prove nothing in the
  // remaining body still refers to either identifier.
  body = body.replace(/^[ \t]*const (?:NS|PANEL_ID) = '[^']*';[ \t]*\r?\n/gm, '');
  const leftovers = (body.match(/\b(?:NS|PANEL_ID)\b/g) ?? []).length;
  if (leftovers !== 0) fail(`${spec.file}: ${leftovers} reference(s) to NS/PANEL_ID survive outside the registration block`);

  body = body.replace(/\s+$/, '');

  return { spec, body };
});

const [manageHalf, toolboxHalf] = halves;

const fileHeader = `/**
 * dsh-windows-toolbox — Client half: the single 工作栏 panel for both halves.
 *
 * GENERATED FILE — build it with \`node tools/merge-client.mjs\`, do not edit.
 * It concatenates the two module bodies from
 *    tools/legacy/manage-client.js   (manage half)
 *    tools/legacy/toolbox-client.js  (toolbox half)
 * verbatim, each inside its own function scope, and adds only:
 *
 *   - one sidebar entry ("WINDOWS工具箱", order 7) instead of two;
 *   - a two-tab shell so the panels switch in place;
 *   - three locale namespaces, so the two dictionaries keep their own keys
 *     (both define nav/title/refresh/loading, with different meanings).
 *
 * Everything else -- the card grid, the checks list, the apply forms, the
 * dry-run dialogs -- is the original component code, unchanged, so a fix in
 * either half still lands in the same component it was written for.
 */
window.__ModuleLoader__.load({
  id: 'dsh-windows-toolbox',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    const { useState } = React;

    const NS = 'dsh-windows-toolbox';
    const NS_MANAGE = 'dsh-windows-toolbox-manage';
    const NS_TOOLBOX = 'dsh-windows-toolbox-toolbox';
    const PANEL_ID = 'dsh-windows-toolbox';

    /** Only the shell's own strings live here; each half carries its own. */
    const SHELL_DICT = {
      zh: {
        nav: 'WINDOWS工具箱',
        title: 'WINDOWS工具箱',
        tabManage: '插件化管理',
        tabToolbox: '工具箱',
        tabManageHint: '本机装了哪些东西、在哪注册、关掉会怎样',
        tabToolboxHint: '清理、体检、修复、软件与驱动',
      },
      en: {
        nav: 'Windows Toolbox',
        title: 'Windows Toolbox',
        tabManage: 'Plugins',
        tabToolbox: 'Toolbox',
        tabManageHint: 'What is installed, where it hooks in, what turning it off does',
        tabToolboxHint: 'Cleanup, health, repair, software and drivers',
      },
    };

    // ---- manage half (tools/legacy/manage-client.js, verbatim body) ----
`;

const toolboxPrelude = `

    // ---- toolbox half (tools/legacy/toolbox-client.js, verbatim body) ----
`;

const shellCode = `
    // ---- merged shell ----
    /** Sidebar glyph: a window grid (manage) overlapping a toolbox (toolbox). */
    function ToolboxMergedIcon({ size = 16 }) {
      return h('svg', {
        width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
        stroke: 'currentColor', strokeWidth: 1.7, strokeLinecap: 'round', strokeLinejoin: 'round',
        'aria-hidden': true,
      },
        h('rect', { x: 2.2, y: 3.4, width: 12.2, height: 10.4, rx: 1.8 }),
        h('path', { d: 'M2.2 6.6h12.2' }),
        h('path', { d: 'M5 9.4h3.4M5 11.6h5' }),
        h('path', { d: 'M8.6 14.6h4.2', opacity: 0.55 }),
        h('rect', { x: 8.4, y: 15.2, width: 13.4, height: 6, rx: 1.6 }),
        h('path', { d: 'M13.2 15.2v-1.1a1 1 0 0 1 1-1h1.8a1 1 0 0 1 1 1v1.1' }),
        h('rect', { x: 13.9, y: 17.3, width: 2.4, height: 1.7, rx: 0.5 }),
      );
    }

    /** Tab button: same visual vocabulary as each half's Btn, no shared import. */
    function TabButton({ active, label, hint, onClick }) {
      return h('button', {
        type: 'button',
        title: hint,
        'aria-selected': active ? 'true' : 'false',
        role: 'tab',
        onClick,
        style: {
          cursor: 'pointer',
          fontSize: 13,
          padding: '6px 14px',
          borderRadius: 7,
          border: '1px solid ' + (active ? 'var(--dsw-alias-border-accent, #3B82F6)' : 'var(--dsw-alias-border-subtle, #d8dce3)'),
          background: active ? 'var(--dsw-alias-bg-accent-weak, rgba(59,130,246,0.12))' : 'transparent',
          color: active ? 'var(--dsw-alias-text-primary, inherit)' : 'var(--dsw-alias-text-secondary, inherit)',
          fontWeight: active ? 600 : 400,
        },
      }, label);
    }

    /**
     * The merged panel. Both children are mounted fresh on every switch rather
     * than kept alive: each Panel re-fetches its own /status on mount, and the
     * halves have ~15 s of PowerShell behind them, so keeping a hidden one alive
     * would only mean a stale view with no way to see it.
     */
    function Shell({ t, tManage, tToolbox, getLang, Manage, Toolbox }) {
      const [tab, setTab] = useState('manage');
      const tabs = [
        { id: 'manage', label: t('tabManage'), hint: t('tabManageHint') },
        { id: 'toolbox', label: t('tabToolbox'), hint: t('tabToolboxHint') },
      ];
      return h('div', {
        style: { display: 'flex', flexDirection: 'column', gap: 10, height: '100%', minHeight: 0 },
      },
        h('div', {
          role: 'tablist',
          'aria-label': t('title'),
          style: {
            display: 'flex', gap: 8, alignItems: 'center',
            paddingBottom: 8,
            borderBottom: '1px solid var(--dsw-alias-border-subtle, #e5e7eb)',
          },
        },
          ...tabs.map((item) => h(TabButton, {
            key: item.id,
            active: tab === item.id,
            label: item.label,
            hint: item.hint,
            onClick: () => setTab(item.id),
          })),
        ),
        h('div', { style: { flex: '1 1 auto', minHeight: 0, overflow: 'hidden' } },
          tab === 'manage'
            ? h(Manage.Panel, { t: tManage, getLang })
            : h(Toolbox.Panel, { t: tToolbox }),
        ),
      );
    }

    // ---- module registration ----
    return {
      inject: ['slots', 'locale', 'theme'],
      apply(ctx) {
        let t = (k) => k;
        let tManage = (k) => k;
        let tToolbox = (k) => k;
        let layout;
        const canLocate = ctx.locale
          && typeof ctx.locale.register === 'function'
          && typeof ctx.locale.bind === 'function';
        if (canLocate) {
          // Three namespaces, registered together and disposed together. The
          // halves must NOT share one: both dictionaries define nav/title/
          // refresh/loading, so the second registration would shadow the first
          // and one panel would start showing the other's wording.
          ctx.effect(() => {
            const offs = [
              ctx.locale.register(NS, SHELL_DICT),
              ctx.locale.register(NS_MANAGE, MANAGE.DICT),
              ctx.locale.register(NS_TOOLBOX, TOOLBOX.DICT),
            ];
            return () => {
              for (const off of offs) { if (typeof off === 'function') { try { off(); } catch { /* noop */ } } }
            };
          }, 'dsh-windows-toolbox: dictionaries');
          t = ctx.locale.bind(NS);
          tManage = ctx.locale.bind(NS_MANAGE);
          tToolbox = ctx.locale.bind(NS_TOOLBOX);
        }
        // The manage half's explanations are generated server-side, so it needs
        // to be told the active language. Defensive: a host without
        // getSnapshot, or one that throws, falls back to the plugin default
        // instead of breaking load().
        const getLang = () => {
          try {
            const active = ctx.locale?.getSnapshot?.()?.active;
            if (typeof active === 'string' && active.toLowerCase().startsWith('en')) return 'en';
          } catch { /* no snapshot on this host */ }
          return 'zh';
        };
        try { ctx.inject(['layout'], (scoped) => { layout = scoped.layout; }); } catch { /* optional */ }
        ctx.effect(() => {
          const offs = [];
          // MUST go through ctx.slots.inject(name, () => ctx.slots.register(...)):
          // rc.3 declares these slots lazily, so a bare register() at apply time
          // runs before the declaration exists and is silently dropped.
          try {
            offs.push(ctx.slots.inject('main', () => ctx.slots.register({
              name: 'main', key: PANEL_ID, locale: NS, inject: () => ({ t, tManage, tToolbox, getLang }),
            }, () => h(Shell, { t, tManage, tToolbox, getLang, Manage: MANAGE, Toolbox: TOOLBOX }))));
          } catch (e) { console.warn('[dsh-windows-toolbox] main panel registration failed:', e?.message); }
          try {
            offs.push(ctx.slots.inject('sidebar.panellist', () => ctx.slots.register({
              name: 'sidebar.panellist', id: PANEL_ID, order: 7, label: () => t('nav'), locale: NS,
            }, (owner = {}) => h(ToolboxMergedIcon, { size: owner.size ?? 16 }))));
          } catch (e) { console.warn('[dsh-windows-toolbox] sidebar row unavailable:', e?.message); }

          return () => {
            for (const off of offs) { if (typeof off === 'function') { try { off(); } catch { /* noop */ } } }
            try { if (layout?.panelInfo?.getSnapshot?.().activePanelId === PANEL_ID) layout.selectPanel?.(null); } catch { /* noop */ }
          };
        }, 'dsh-windows-toolbox: workbench panel');
      },
    };
  },
});
`;

let out = fileHeader;
out += `    function ${manageHalf.spec.fnName}(require) {\n`;
out += manageHalf.body;
out += `\n\n      return { Panel, Icon: ${manageHalf.spec.icon}, DICT };\n    }\n`;
out += `    const MANAGE = ${manageHalf.spec.fnName}(require);\n`;
out += toolboxPrelude;
out += `    function ${toolboxHalf.spec.fnName}(require) {\n`;
out += toolboxHalf.body;
out += `\n\n      return { Panel, Icon: ${toolboxHalf.spec.icon}, DICT };\n    }\n`;
out += `    const TOOLBOX = ${toolboxHalf.spec.fnName}(require);\n`;
out += shellCode;

if ((out.match(/function Panel\(/g) ?? []).length !== 2) fail('output must contain exactly two Panel definitions');

if (CHECK) {
  if (!existsSync(OUT)) fail(`no output to check: ${OUT}`);
  const current = readFileSync(OUT, 'utf8');
  if (current === out) {
    console.log('merge-client: client.js is up to date');
    process.exit(0);
  }
  fail('client.js differs from a fresh merge — run `node tools/merge-client.mjs`');
}

writeFileSync(OUT, out, 'utf8');
const lines = out.split('\n').length;
console.log(`merge-client: wrote ${OUT}`);
console.log(`  ${lines} lines, ${out.length} bytes`);
console.log(`  manage  body ${manageHalf.body.split('\n').length} lines`);
console.log(`  toolbox body ${toolboxHalf.body.split('\n').length} lines`);
