/**
 * dsh-windows-toolbox — ONE elevation channel for both halves.
 *
 * The problem this solves
 * -----------------------
 * Both halves used to raise their own UAC prompt: `manage` started an elevated
 * child per action, `toolbox` did the same with a different temp file and a
 * different poll loop. Acting as admin twice meant approving twice, and the two
 * halves each kept their own "am I elevated?" answer — so one tab could say
 * "elevated" while the other still showed its request button.
 *
 * The design now
 * --------------
 * A single RESIDENT elevated worker (`lib/probes/broker.ps1`) holds the admin
 * token for the session. The user approves UAC once; every later elevated job
 * from either half is handed to that same process through a job directory, so
 * no further prompts appear.
 *
 * The host process itself stays UNELEVATED and keeps saying so per action —
 * `/status` reports `elevated` from the broker, which is the truth about what
 * can actually be done, not about our own token.
 *
 * Failure modes that are answers, not errors
 * ------------------------------------------
 *   - the user cancels the UAC dialog  → {ok:false, cancelled:true}
 *   - the broker dies / never answers  → {ok:false, timeout:true} after a re-probe
 *   - a probe throws inside the broker → {ok:false, error} with the probe's text
 * None of them may become a 500: a 500 tells the panel "the server broke", which
 * is exactly the lie that makes someone retry a destructive action.
 *
 * Honesty about the token
 * -----------------------
 * The job token stops ACCIDENTS (a stray JSON file in the directory), not a
 * hostile process running as the same user — that process can read ready.json.
 * Every probe the broker runs is still one the catalogue already declares, with
 * parameters that went through sanitizeParams, and every destructive probe keeps
 * its own dryRun gate. This module grants no new power; it only removes the
 * repeated prompts.
 */
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, mkdirSync, rmSync, readdirSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { interpreter, probePath, parseJson } from './ps.js';

/** Stable path: a host restart can adopt a broker that is still alive. */
const BROKER_DIR = join(tmpdir(), 'dsh-windows-toolbox-broker');

const READY = 'ready.json';
const BEAT = 'beat.json';
const HALT = 'halt.json';

const POLL_MS = 150;
/** How long an unclaimed ready.json/beat.json may sit before we call it dead. */
const STALE_MS = 6_000;
/** Idle lifetime handed to the broker; it exits on its own after this. */
const IDLE_SECS = 900;

const state = {
  /** pid of the broker this process knows about, or 0 */
  pid: 0,
  token: '',
  elevated: false,
  user: '',
  started: '',
  /** true while a start attempt is in flight, so two clicks cannot start two brokers */
  starting: false,
  lastError: '',
};

const sleep = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

function readJson(file) {
  try {
    const text = readFileSync(file, 'utf8');
    if (!text || !text.trim()) return null;
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function writeJson(file, value) {
  // Write-then-rename: the broker and this process read each other's files, and
  // a reader that catches a half-written document would see a truncated job.
  // renameSync onto an existing name is atomic on NTFS, so the target is always
  // either the old document or the new one.
  const tmp = `${file}.${randomUUID().slice(0, 8)}.tmp`;
  writeFileSync(tmp, JSON.stringify(value), 'utf8');
  try {
    renameSync(tmp, file);
  } catch {
    // Some filesystems refuse to rename over an existing file; fall back to a
    // direct write, which is what the broker's own Write-Json has to do too.
    writeFileSync(file, JSON.stringify(value), 'utf8');
    try { rmSync(tmp, { force: true }); } catch { /* scratch */ }
  }
}

function alive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM means "exists but not ours" — still alive for our purposes.
    return error?.code === 'EPERM';
  }
}

function beatFresh() {
  const beat = readJson(join(BROKER_DIR, BEAT));
  if (!beat || typeof beat.at !== 'string') return false;
  const at = Date.parse(beat.at);
  if (Number.isNaN(at)) return false;
  return Date.now() - at < STALE_MS;
}

/** Adopt a broker that is already running and answering. */
function adopt() {
  const ready = readJson(join(BROKER_DIR, READY));
  if (!ready || ready.ok !== true) return false;
  if (!alive(Number(ready.pid))) return false;
  if (!beatFresh()) return false;
  state.pid = Number(ready.pid);
  state.token = String(ready.token ?? '');
  state.elevated = ready.elevated === true;
  state.user = String(ready.user ?? '');
  state.started = String(ready.started ?? '');
  return true;
}

function clearDir() {
  try {
    for (const name of readdirSync(BROKER_DIR)) {
      try {
        rmSync(join(BROKER_DIR, name), { force: true });
      } catch { /* a locked file is not worth failing the whole start */ }
    }
  } catch { /* directory does not exist yet */ }
}

/**
 * Start the broker. This is the ONLY place in the plugin that raises a UAC
 * prompt, and it raises exactly one per session.
 *
 * `Start-Process -Verb RunAs` has no way to stream stdout back, so the child is
 * started with a job directory and reports readiness by writing ready.json; we
 * poll for it. A dismissed prompt makes Start-Process throw, which is reported
 * as `cancelled` rather than as a failure.
 */
async function start() {
  state.starting = true;
  state.lastError = '';
  try {
    const chosen = await interpreter();
    if (!chosen) {
      state.lastError = '找不到 PowerShell 解释器';
      return { ok: false, cancelled: false, error: state.lastError };
    }

    mkdirSync(BROKER_DIR, { recursive: true });
    // Fresh directory: leftovers from a dead broker would be picked up as jobs.
    clearDir();

    const token = randomUUID();
    const script = probePath('broker.ps1');
    if (!existsSync(script)) {
      state.lastError = `找不到 broker.ps1: ${script}`;
      return { ok: false, cancelled: false, error: state.lastError };
    }

    const quote = (value) => `'${String(value).replace(/'/g, "''")}'`;
    const argList = [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', quote(script),
      '-JobDir', quote(BROKER_DIR),
      '-Token', quote(token),
      '-IdleSecs', String(IDLE_SECS),
    ];

    const snippet = [
      "$ErrorActionPreference = 'Stop'",
      `$exe = ${quote(chosen.bin)}`,
      `$argList = @(${argList.join(', ')})`,
      'try {',
      '    $proc = Start-Process -FilePath $exe -Verb RunAs -WindowStyle Hidden -ArgumentList $argList -PassThru',
      '    @{ started = $true; pid = $proc.Id } | ConvertTo-Json -Compress',
      '} catch {',
      '    @{ started = $false; message = [string]$_.Exception.Message } | ConvertTo-Json -Compress',
      '}',
    ].join('\n');

    const launch = await runJsonSnippet(snippet, 120_000);
    if (launch?.started !== true) {
      const message = String(launch?.message ?? '').trim();
      // An empty message is what Windows produces for a dismissed prompt; the
      // text forms cover the localized cases we have actually seen.
      const cancelled = message === '' || /cancel|取消|denied|拒绝|已取消|操作已被用户/i.test(message);
      state.lastError = cancelled ? '你取消了 UAC 提权' : message;
      return { ok: false, cancelled, error: state.lastError };
    }

    // The prompt has been approved; the child now has to report in. A slow disk
    // or a cold PowerShell start can take seconds, so this waits rather than
    // guessing.
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      const ready = readJson(join(BROKER_DIR, READY));
      if (ready?.ok === true && String(ready.token ?? '') === token) {
        state.pid = Number(ready.pid ?? 0);
        state.token = token;
        state.elevated = ready.elevated === true;
        state.user = String(ready.user ?? '');
        state.started = String(ready.started ?? '');
        return {
          ok: true, cancelled: false, started: true,
          elevated: state.elevated, user: state.user, pid: state.pid,
        };
      }
      await sleep(POLL_MS);
    }

    state.lastError = '提权进程已启动但没有报到（可能仍在初始化）';
    return { ok: false, cancelled: false, timeout: true, error: state.lastError };
  } finally {
    state.starting = false;
  }
}

/** Local copy of ps.js's snippet runner — kept here so this module owns its deps. */
let runJsonSnippetImpl = null;
async function runJsonSnippet(snippet, timeout) {
  if (runJsonSnippetImpl) return runJsonSnippetImpl(snippet, timeout);
  const ps = await import('./ps.js');
  runJsonSnippetImpl = ps.runJson;
  return runJsonSnippetImpl(snippet, timeout);
}

/**
 * Make sure a broker is running, starting one (with UAC) if needed.
 *
 * Serialised: two halves asking at the same moment must not raise two prompts —
 * that is the exact bug this module exists to prevent.
 */
let starting = null;
export async function ensureBroker() {
  if (adopt()) {
    return { ok: true, cancelled: false, reused: true, elevated: state.elevated, user: state.user, pid: state.pid };
  }
  if (starting) return starting;
  starting = (async () => {
    const result = await start();
    starting = null;
    return result;
  })();
  return starting;
}

/**
 * Pure read — never STARTS anything. Safe to call from /status.
 *
 * It does adopt: after a host restart the broker is still alive and still holds
 * the token, so reporting `running:false` until some action happens to call
 * ensureBroker() would make the panel offer a button the user already pressed.
 * Adopting only reads ready.json/beat.json and checks the pid; it raises no
 * prompt, which is what "pure read" is protecting.
 */
export function brokerStatus() {
  if (!state.pid) adopt();
  if (state.pid && (!alive(state.pid) || !beatFresh())) {
    // It died or went idle. Report what we know, but stop claiming elevation.
    return {
      running: false, elevated: false, pid: 0, user: '',
      lastElevated: state.elevated, lastUser: state.user, stale: true,
    };
  }
  return {
    running: state.pid > 0,
    elevated: state.elevated,
    pid: state.pid,
    user: state.user,
    started: state.started,
    stale: false,
  };
}

/**
 * Report elevation for /status.
 *
 * Two independent facts: can THIS process write privileged things right now, and
 * can the broker. The panel only needs the combined answer — if either is true,
 * an action will go through without another prompt.
 */
export function canActElevated(ownElevated) {
  if (ownElevated === true) return true;
  const s = brokerStatus();
  return s.running === true && s.elevated === true;
}

/**
 * Run one probe inside the resident elevated broker.
 *
 * `probeFile` is an absolute path; `params` has already been through the caller's
 * own whitelist. The broker is asked to start if it is not running, so the first
 * call costs one UAC prompt and every later call costs none.
 */
export async function runElevated(probeFile, params, { timeout = 180_000 } = {}) {
  const ready = await ensureBroker();
  if (ready.ok !== true) {
    return {
      ok: false,
      cancelled: ready.cancelled === true,
      elevated: false,
      error: ready.error ?? '',
      message: ready.cancelled === true ? '你取消了 UAC 提权' : (ready.error ?? ''),
    };
  }

  const id = randomUUID().slice(0, 12);
  const jobFile = join(BROKER_DIR, `job-${id}.json`);
  const resFile = join(BROKER_DIR, `res-${id}.json`);

  writeJson(jobFile, { id, token: state.token, probe: probeFile, params: params ?? {} });

  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const res = readJson(resFile);
    if (res && String(res.id ?? '') === id) {
      try {
        rmSync(resFile, { force: true });
      } catch { /* the broker may have cleaned it already */ }
      if (res.ok !== true && !res.output) {
        return {
          ok: false, cancelled: false, elevated: res.elevated === true,
          error: String(res.error ?? ''),
        };
      }
      const out = res.output ? parseJson(String(res.output)) : null;
      if (out === null) {
        return {
          ok: false, cancelled: false, elevated: res.elevated === true,
          error: `提权进程回传的内容不是 JSON: ${String(res.error ?? '')}`,
        };
      }
      return { ok: true, cancelled: false, elevated: res.elevated === true, out, elapsedMs: res.elapsedMs };
    }
    if (!alive(state.pid)) {
      state.pid = 0;
      return { ok: false, cancelled: false, elevated: false, error: '提权进程已经退出，请重新请求提权' };
    }
    await sleep(POLL_MS);
  }

  try {
    rmSync(jobFile, { force: true });
  } catch { /* never claimed */ }
  return {
    ok: false, cancelled: false, elevated: state.elevated,
    timeout: true,
    error: `提权进程在 ${Math.round(timeout / 1000)}s 内没有回传结果`,
  };
}

/** Ask the broker to stop. Called on plugin unload; failure is not fatal. */
export function stopBroker() {
  if (!state.pid) return;
  try {
    writeJson(join(BROKER_DIR, HALT), { at: new Date().toISOString() });
  } catch { /* nothing we can do, and a lingering broker exits on idle anyway */ }
  state.pid = 0;
  state.elevated = false;
  state.token = '';
}
