// Smoke-test the MERGED host half: both route families must mount from one
// apply(), and neither may take the other down when it fails.
//
// This is deliberately NOT a unit test of a single module - the whole point of
// the merge is `index.js` calling mountManage() and mountToolbox() inside
// separate try/catch blocks with different API prefixes. A typo in either
// prefix, or a stray hardcoded /dsh-360-toolbox/api left in a moved file,
// produces a panel that renders and then fails every request, which no
// syntax check catches.
//
//   node tools/smoke-merged.mjs
//
// Exit 0 = both halves mounted and answered.

import { apply } from '../index.js';

const calls = [];
const tools = [];

/** Minimal cordis-shaped host: inject() hands a scoped ctx to the callback. */
function makeCtx() {
  const ctx = {
    inject(names, cb) {
      const scoped = { ...ctx };
      for (const n of names) scoped[n] = n === 'webServer' ? webServer : n === 'tools' ? toolServer : {};
      cb(scoped);
    },
    effect(fn) {
      const off = fn();
      return typeof off === 'function' ? off : () => {};
    },
  };
  const webServer = {
    register(spec) {
      calls.push(spec);
      return () => {};
    },
  };
  const toolServer = {
    register(def) {
      tools.push(def);
      return () => {};
    },
  };
  return ctx;
}

apply(makeCtx(), {});

const paths = calls.map((c) => c.path).sort();
const names = tools.map((t) => t.name).sort();

const expect = (label, got, want) => {
  const ok = got === want;
  console.log(`${ok ? 'ok  ' : 'FAIL'}  ${label}: ${got}${ok ? '' : ` (want ${want})`}`);
  if (!ok) process.exitCode = 1;
};

expect('route count', calls.length, 13);
expect('tool count', tools.length, 12);
expect(
  'manage routes',
  paths.filter((p) => p.startsWith('/dsh-windows-toolbox/api/manage')).length,
  7,
);
expect(
  'toolbox routes',
  paths.filter((p) => p.startsWith('/dsh-windows-toolbox/api/toolbox')).length,
  6,
);
expect(
  'wpm_* tools',
  names.filter((n) => n.startsWith('wpm_')).length,
  7,
);
expect(
  'tb360_* tools',
  names.filter((n) => n.startsWith('tb360_')).length,
  5,
);

// The old prefixes must be GONE: a leftover would silently 404 at runtime
// because nothing serves that path any more.
const stale = paths.filter(
  (p) => p.includes('/dsh-360-toolbox/') || p.includes('/dsh-windows-plugin-manager/'),
);
expect('stale prefixes', stale.length, 0);

// Every route must be an exact match with a handler, or webServer.register()
// would have thrown in a real host.
expect(
  'exact+handler routes',
  calls.filter((c) => c.kind === 'exact' && typeof c.handler === 'function').length,
  13,
);

console.log('\nroutes:');
for (const p of paths) console.log('  ' + p);
console.log('\ntools:');
for (const n of names) console.log('  ' + n);
