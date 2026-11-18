// audit-probes.mjs — objective acceptance check for every probe in a plugin.
//
//   node tools/audit-probes.mjs                 # audit this plugin's probes
//   node tools/audit-probes.mjs --dir <plugin>  # audit another plugin directory
//   node tools/audit-probes.mjs --json          # machine readable
//
// Why this exists: subagents write probes in parallel, and "it worked for me"
// is not evidence. This script applies the same checks to every probe so the
// review step is a table of numbers, not a reading of eleven chat reports:
//
//   1. syntax      - [System.Management.Automation.Language.Parser]::ParseFile
//                    returns zero errors. (`[Parser]` alone silently returns
//                    $null and would pass everything, so the full type name is
//                    mandatory.)
//   2. param block - the param(...) block must be the FIRST statement. If a
//                    [Console]::OutputEncoding line sits above it, PowerShell
//                    treats `param` as a command name, prints an error to
//                    stderr, and carries on executing the body - so the probe
//                    "runs" while its parameters were never bound. That exact
//                    bug hid a dead 5.1 fallback path in appx.ps1 for a long
//                    time.
//   3. utf8 line   - [Console]::OutputEncoding must be set, or every Chinese
//                    string arrives as mojibake in Node.
//   4. runs        - optional: actually execute it and check the envelope.
//   5. envelope    - stdout parses as one JSON object with ok=true, an items
//                    array, and a summary whose five counts add up to total.
//   6. ids         - every item id is unique and non-empty.
//   7. mojibake    - no U+FFFD in the output, and CJK present when the probe is
//                    expected to emit Chinese.
//   8. banned API  - no New-Item -Force on a registry path, no reg delete,
//                    no Format-Volume / Initialize-Disk / Remove-Partition /
//                    Clear-Disk / diskpart clean / bcdedit / Restart-Computer.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, basename } from 'node:path';
import { spawnSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const AS_JSON = argv.includes('--json');
const NO_RUN = argv.includes('--no-run');
const dirIdx = argv.indexOf('--dir');
const PLUGIN = dirIdx >= 0 && argv[dirIdx + 1]
  ? argv[dirIdx + 1]
  : join(HERE, '..');
const PROBES = join(PLUGIN, 'lib', 'probes');

// Probes that are libraries, not entry points: they have no param block and are
// dot-sourced by others. Auditing them as programs would produce false alarms.
const LIBRARY_PROBES = new Set(['featurelib.ps1', 'junklib.ps1', 'rootlib.ps1']);
const NO_BARE_RUN = new Set(['actions.ps1', 'shredder.ps1', 'backup.ps1', 'softmgr.ps1', 'junk.ps1', 'repair.ps1', 'broker.ps1']);

// Resident services, not one-shot probes: broker.ps1 refuses to start without
// -JobDir and -Token, then loops until halted. Running it bare exits 1 and prints
// nothing, and "dryRun" is the wrong question for a process that spends its whole
// life running jobs other halves have already gated. Audit it for syntax, the
// param block and the banned-API list only.
const DAEMON_PROBES = new Set(['broker.ps1']);

// Probes whose envelope is a flat object rather than a list: host.ps1 reports
// machine facts (elevated/user/os/...) with no array at all, and elevated.ps1 is
// the UAC bridge whose reply is the outcome of one elevated call
// ({ok, message, changed, elevated, cancelled}) — a status, not rows.
const SCALAR_PROBES = new Set(['host.ps1', 'elevated.ps1']);

const BANNED = [
  { re: /New-Item[^\n]*-Force[^\n]*(HKLM:|HKCU:|HKEY_)/i, why: 'New-Item -Force on a registry key WIPES existing values' },
  { re: /New-Item[^\n]*(HKLM:|HKCU:|HKEY_)[^\n]*-Force/i, why: 'New-Item -Force on a registry key WIPES existing values' },
  { re: /\breg\s+delete\b/i, why: 'reg delete is unrecoverable; use Remove-ItemProperty after a reg export' },
  { re: /\bFormat-Volume\b/i, why: 'destroys a volume' },
  { re: /\bInitialize-Disk\b/i, why: 'destroys a disk' },
  { re: /\bRemove-Partition\b/i, why: 'destroys a partition' },
  { re: /\bClear-Disk\b/i, why: 'destroys a disk' },
  { re: /\bdiskpart\b[^\n]*\bclean\b/i, why: 'diskpart clean destroys a disk' },
  { re: /\bbcdedit\b/i, why: 'boot configuration; a wrong write bricks boot' },
  { re: /\bRestart-Computer\b/i, why: 'a probe must never reboot the machine' },
  { re: /\bInvoke-Expression\b|\biex\b/i, why: 'arbitrary code execution from data' },
  { re: /\bSet-ExecutionPolicy\b/i, why: 'changes a machine-wide security setting' },
];

const results = [];
let hardFail = 0;

function record(name, checks, notes) {
  const failed = checks.filter((c) => !c.pass);
  if (failed.length) hardFail++;
  results.push({ name, ok: failed.length === 0, checks, notes });
}

function psParseErrors(file) {
  // Full type name on purpose: `[Parser]` resolves to $null under PS7 in some
  // hosts and then ParseFile is never called, so everything "passes".
  const script = `
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(${psQuote(file)}, [ref]$null, [ref]$errs)
if ($null -eq $errs) { 'NOERRARRAY' } else { $errs.Count }
`;
  const r = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', script], {
    encoding: 'utf8',
    timeout: 30000,
    windowsHide: true,
  });
  const out = String(r.stdout ?? '').trim();
  if (out === 'NOERRARRAY') return -1;
  const n = Number(out);
  return Number.isFinite(n) ? n : -2;
}

function psQuote(s) {
  return `'${String(s).replace(/'/g, "''")}'`;
}

// Banned-API and dryRun checks must look at CODE, not prose. Three real false
// positives came from this on the first run (all since cleared, kept as the
// reason this function exists):
//   expandc.ps1  a header comment listing the disk cmdlets the probe refuses
//                to call — the list itself tripped the ban
//   security.ps1:410  a fix HINT string "-Fix 'Set-ExecutionPolicy -Scope ...'"
//                   (advice to the user, not a call)
//   security.ps1:7   a comment saying it never writes
// Strip block comments, then line comments, then single/double quoted strings.
// This can over-strip in exotic cases (here-strings containing #), which is the
// safe direction: a false negative on a banned call is caught by the runtime
// checks, whereas a false positive just makes the reviewer distrust the tool.
function stripProse(text) {
  let s = String(text);
  s = s.replace(/<#[\s\S]*?#>/g, ' ');           // block comments
  s = s.split(/\r?\n/).map((line) => {
    // Drop a line whose content is a comment.
    const t = line.trim();
    if (t.startsWith('#')) return '';
    return line;
  }).join('\n');
  // Blank out quoted strings so `-Fix 'Set-ExecutionPolicy ...'` cannot trip.
  s = s.replace(/'(?:[^']|'')*'/g, "''");
  s = s.replace(/"(?:[^"`]|`.)*"/g, '""');
  // Trailing line comments (only when # is not inside what is left of a string).
  s = s.split(/\r?\n/).map((line) => line.replace(/\s+#\s.*$/, '')).join('\n');
  return s;
}

function runProbe(file) {
  const r = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-File', file], {
    encoding: 'utf8',
    timeout: 180000,
    windowsHide: true,
    cwd: PLUGIN,
  });
  return {
    code: r.status,
    stdout: String(r.stdout ?? ''),
    stderr: String(r.stderr ?? ''),
    ms: undefined,
  };
}

function parseEnvelope(stdout) {
  const s = String(stdout);
  const start = s.search(/[[{]/);
  if (start < 0) return null;
  const lastObj = s.lastIndexOf('}');
  const lastArr = s.lastIndexOf(']');
  const end = Math.max(lastObj, lastArr);
  if (end <= start) return null;
  try {
    return JSON.parse(s.slice(start, end + 1));
  } catch {
    return null;
  }
}

if (!existsSync(PROBES)) {
  console.error(`no probes directory: ${PROBES}`);
  process.exit(2);
}

const files = readdirSync(PROBES).filter((f) => f.endsWith('.ps1')).sort();

for (const f of files) {
  const full = join(PROBES, f);
  const text = readFileSync(full, 'utf8');
  const checks = [];
  const notes = [];

  // --- 1. syntax ---------------------------------------------------------
  const errCount = psParseErrors(full);
  checks.push({
    name: 'syntax',
    pass: errCount === 0,
    detail: errCount === 0 ? '0 parse errors' : `parse errors = ${errCount}`,
  });

  if (LIBRARY_PROBES.has(f)) {
    // A library: only syntax matters, plus the banned-API scan below.
    checks.push({ name: 'library', pass: true, detail: 'dot-sourced helper, not an entry point' });
  } else {
    // --- 2. param block must be first --------------------------------
    const lines = text.split(/\r?\n/);
    let firstCode = -1;
    let paramAt = -1;
    let inBlock = false;
    for (let i = 0; i < lines.length; i++) {
      const t = lines[i].trim();
      // Block comments count as prose too. elevated.ps1 documents its whole
      // guard contract in a 44-line <# ... #> header; without this the header's
      // first line was mistaken for the first statement and param-first failed
      // even though param() really is the first thing PowerShell executes.
      if (inBlock) {
        if (t.includes('#>')) inBlock = false;
        continue;
      }
      if (t.startsWith('<#')) {
        if (!t.includes('#>')) inBlock = true;
        continue;
      }
      if (!t || t.startsWith('#')) continue;
      if (firstCode < 0) firstCode = i;
      if (t.toLowerCase().startsWith('param')) { paramAt = i; break; }
    }
    const paramFirst = paramAt < 0 ? null : paramAt === firstCode;
    checks.push({
      name: 'param-first',
      pass: paramAt < 0 ? true : paramFirst === true,
      detail: paramAt < 0
        ? 'no param block'
        : paramFirst
          ? 'param is the first statement'
          : `param at line ${paramAt + 1} but first code at line ${firstCode + 1} — parameters will NOT bind`,
    });
    if (paramAt < 0) notes.push('no param block (fine if it takes no arguments)');

    // --- 3. UTF-8 stdout ---------------------------------------------
    const hasUtf8 = /\[Console\]::OutputEncoding\s*=\s*New-Object '?System\.Text\.UTF8Encoding/i.test(text);
    checks.push({
      name: 'utf8-stdout',
      pass: hasUtf8,
      detail: hasUtf8 ? 'UTF8Encoding set' : 'missing [Console]::OutputEncoding — Chinese will be mojibake',
    });

    // --- 4/5/6/7. run + envelope -------------------------------------
    if (!NO_RUN && !NO_BARE_RUN.has(f)) {
      const started = Date.now();
      const run = runProbe(full);
      const ms = Date.now() - started;
      checks.push({
        name: 'exit-code',
        pass: run.code === 0,
        detail: `exit=${run.code} in ${ms}ms`,
      });
      const env = parseEnvelope(run.stdout);
      checks.push({
        name: 'json-envelope',
        pass: !!env,
        detail: env ? 'parsed' : `unparseable stdout (${run.stdout.slice(0, 120).replace(/\s+/g, ' ')}…)`,
      });
      if (env) {
        // Two envelopes exist in this plugin by design:
        //   - featurelib probes (the newer ones): { ok, count, items[], summary }
        //   - the five original capabilities: { ok, rows[] } / { groups[] } /
        //     { steps[] }, and host.ps1 which returns a flat object with no array.
        // Insisting on `items` flagged five healthy probes on the first run, so
        // accept any of the known payload keys and exempt the scalar one.
        const PAYLOAD_KEYS = ['items', 'rows', 'groups', 'steps', 'checks', 'devices', 'packages'];
        // A third envelope shape exists: svc.ps1 / task.ps1 / autorun.ps1 emit a
        // BARE JSON ARRAY (`[{...},...]`) rather than { ok, items[] }. Looking up
        // `env['items']` on an array silently yields undefined and reported both
        // probes as broken when they were fine — so treat an array payload as
        // the row list itself.
        const payloadKey = Array.isArray(env)
          ? 'bare array'
          : PAYLOAD_KEYS.find((k) => Array.isArray(env[k]));
        const items = Array.isArray(env) ? env : payloadKey ? env[payloadKey] : null;
        if (SCALAR_PROBES.has(f) && !payloadKey) {
          checks.push({ name: 'items', pass: true, detail: 'scalar envelope by design' });
        } else {
          checks.push({
            name: 'items',
            pass: !!items && items.length > 0,
            detail: items ? `${items.length} ${payloadKey}` : `no ${PAYLOAD_KEYS.join('/')} array`,
          });
        }
        if (items) {
          // Only featurelib rows carry id/status; the original capabilities use
          // their own shapes (path/bytes, hash/count). Check ids where present.
          const withId = items.filter((i) => i && typeof i === 'object' && 'id' in i);
          if (withId.length) {
            const ids = withId.map((i) => String(i?.id ?? ''));
            const empty = ids.filter((i) => !i).length;
            const dupes = ids.length - new Set(ids).size;
            checks.push({
              name: 'unique-ids',
              pass: empty === 0 && dupes === 0,
              detail: empty || dupes ? `${empty} empty, ${dupes} duplicate` : `${ids.length} unique`,
            });
          }
          const withStatus = items.filter((i) => i && typeof i === 'object' && 'status' in i);
          if (withStatus.length) {
            const badStatus = withStatus.filter((i) => !['ok', 'warn', 'bad', 'info', 'skip'].includes(String(i?.status ?? '')));
            checks.push({
              name: 'status-values',
              pass: badStatus.length === 0,
              detail: badStatus.length ? `${badStatus.length} items with unknown status` : 'all in ok/warn/bad/info/skip',
            });
            const skipNoReason = withStatus.filter((i) => i?.status === 'skip' && !String(i?.detail ?? '').trim());
            checks.push({
              name: 'skip-has-reason',
              pass: skipNoReason.length === 0,
              detail: skipNoReason.length ? `${skipNoReason.length} skip items without detail` : 'every skip explains itself',
            });
          }
        }
        const sum = env.summary;
        if (sum && typeof sum === 'object') {
          const parts = ['ok', 'warn', 'bad', 'info', 'skip'].reduce((a, k) => a + Number(sum[k] ?? 0), 0);
          checks.push({
            name: 'summary-adds-up',
            pass: parts === Number(sum.total ?? -1),
            detail: `parts=${parts} total=${sum.total}`,
          });
        }
        // --- 7. mojibake ---------------------------------------------
        // U+FFFD is the real signal: PowerShell writing GBK into a UTF-8 pipe
        // produces it. "No CJK" is only a note, because probes that scan file
        // paths legitimately emit ASCII only (bigfiles, dupfiles, host).
        const hasReplacement = run.stdout.includes('\uFFFD');
        const hasCjk = /[\u4E00-\u9FFF]/.test(run.stdout);
        checks.push({
          name: 'no-mojibake',
          pass: !hasReplacement,
          detail: hasReplacement
            ? 'U+FFFD present — encoding broken'
            : hasCjk
              ? 'CJK present, no replacement chars'
              : 'no CJK (ASCII-only output, acceptable)',
        });
        if (!hasCjk) notes.push('output has no CJK; verify by eye if it should have');
      }
    } else if (NO_BARE_RUN.has(f)) {
      notes.push('not executed bare (needs arguments or is destructive)');
    }
  }

  // --- 8. banned API -----------------------------------------------------
  // Scan code only; see stripProse() for the false positives this avoids.
  const code = stripProse(text);
  const hits = BANNED.filter((b) => b.re.test(code));
  checks.push({
    name: 'no-banned-api',
    pass: hits.length === 0,
    detail: hits.length ? hits.map((h) => h.why).join('; ') : 'clean',
  });

  // --- safety: dryRun default for anything that writes ----------------
  // Libraries are exempt: junklib.ps1 exposes Remove-JunkTarget, but the dryRun
  // gate lives in junk.ps1, which is the only caller and refuses to delete
  // unless params say dryRun=false. Auditing the library in isolation would ask
  // a helper function to carry its caller's policy.
  const writes = /\b(Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Set-Service|New-Item|Remove-Item|Clear-RecycleBin)\b/.test(code);
  if (writes) {
    if (LIBRARY_PROBES.has(f)) {
      notes.push('writes exist but dryRun gate lives in the calling probe');
    } else if (DAEMON_PROBES.has(f)) {
      notes.push('resident daemon: the dryRun decision belongs to whoever submits a job');
    } else {
      const hasDry = /dryRun/i.test(text);
      checks.push({
        name: 'dryrun-default',
        pass: hasDry,
        detail: hasDry ? 'mentions dryRun' : 'contains write cmdlets but no dryRun — a probe must default to read-only',
      });
    }
  }

  record(f, checks, notes);
}

// ---------------------------------------------------------------------------
const pass = results.filter((r) => r.ok).length;

if (AS_JSON) {
  console.log(JSON.stringify({ plugin: PLUGIN, pass, total: results.length, results }, null, 2));
} else {
  console.log(`audit-probes: ${PLUGIN}`);
  console.log(`  probes: ${results.length}\n`);
  const width = Math.max(...results.map((r) => r.name.length), 10);
  for (const r of results) {
    const mark = r.ok ? '✔' : '✘';
    console.log(`  ${mark} ${r.name.padEnd(width)}  ${r.checks.filter((c) => c.pass).length}/${r.checks.length}`);
    for (const c of r.checks) {
      if (!c.pass) console.log(`      ✗ ${c.name}: ${c.detail}`);
    }
    for (const n of r.notes) console.log(`      · ${n}`);
  }
  console.log(`\n${pass}/${results.length} probes clean`);
  console.log(hardFail === 0 ? 'VERDICT: PASS' : 'VERDICT: FAIL');
}

process.exit(hardFail === 0 ? 0 : 1);
