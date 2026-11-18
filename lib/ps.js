/**
 * lib/ps.js — the only place this plugin talks to PowerShell.
 *
 * Adapted from dsh-windows-toolbox/lib/ps.js, which carries two hard
 * lessons from this machine (2026-11-17):
 *
 *  1. **Every script must set the console output encoding.** All probes write
 *     JSON with `[Console]::Out.Write`. PowerShell defaults to the OEM code page
 *     (936/GBK here), while Node decodes stdout as UTF-8 — every Chinese string
 *     came back as `�ܾ������ܱ�������`. Each probe therefore starts with
 *     `[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false`.
 *
 *  2. **`Test-Path` on a key that does not exist costs ~387 ms** (measured: 60
 *     misses = 23.2 s). Never probe candidate paths one by one; enumerate what
 *     exists once, then look things up in memory. Relevant to this plugin when
 *     scanning many candidate cache directories.
 *
 * No user-supplied string is ever interpolated into a script. Everything that
 * needs a parameter is handed over through a temp JSON file (`-ParamFile`).
 */
import { spawn } from 'node:child_process';
import { writeFile, unlink, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_TIMEOUT = 120_000;
const PROBE_ROOT = new URL('./probes/', import.meta.url);

/**
 * Absolute path to a probe script shipped with this plugin.
 *
 * MUST go through fileURLToPath, not `new URL(...).pathname`: this plugin lives
 * under a non-ASCII directory (E:\DSHWORK\DSH插件\...), and `.pathname` hands
 * back the percent-encoded form (`DSH%E6%8F%92%E4%BB%B6`), which PowerShell then
 * fails to open with "无法找到路径…". Measured on the sibling plugin: every
 * probe failed until this was fixed.
 */
export function probePath(name) {
  const file = /\.ps1$/i.test(name) ? name : `${name}.ps1`;
  return fileURLToPath(new URL(file, PROBE_ROOT));
}

function pwshCandidates() {
  const list = [];
  if (process.env.DSH_PWSH) list.push(process.env.DSH_PWSH);
  list.push('pwsh');
  if (process.env.SystemRoot) {
    list.push(join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'));
  }
  return [...new Set(list)];
}

let cachedInterpreter;

/** Pick an interpreter once and reuse it (pwsh 7 first, then built-in 5.1). */
export async function interpreter() {
  if (cachedInterpreter !== undefined) return cachedInterpreter;
  for (const candidate of pwshCandidates()) {
    try {
      const out = await run(candidate, ['-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.Major'], { timeout: 20_000 });
      const major = Number(out.trim());
      if (Number.isFinite(major) && major >= 5) {
        cachedInterpreter = { bin: candidate, major };
        return cachedInterpreter;
      }
    } catch {
      /* try the next one */
    }
  }
  cachedInterpreter = null;
  return cachedInterpreter;
}

/** Low-level spawn. Resolves with raw stdout; rejects on non-zero exit. */
function run(bin, args, { timeout = DEFAULT_TIMEOUT, env } = {}) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      child = spawn(bin, args, {
        windowsHide: true,
        env: { ...process.env, ...env },
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (error) {
      reject(error);
      return;
    }
    let stdout = '';
    let stderr = '';
    let settled = false;
    const settle = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn(value);
    };
    const timer = setTimeout(() => {
      try { child.kill(); } catch { /* already gone */ }
      settle(reject, new Error(`PowerShell timed out after ${timeout}ms`));
    }, timeout);

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => settle(reject, error));
    child.on('close', (code) => {
      if (code === 0) settle(resolve, stdout);
      else settle(reject, new Error(trimError(stderr) || `PowerShell exited with code ${code}`));
    });
  });
}

function trimError(raw) {
  const text = String(raw ?? '').trim();
  if (!text) return '';
  return text.split(/\r?\n/).filter(Boolean).slice(0, 4).join(' | ').slice(0, 600);
}

/**
 * Run a probe script with optional parameters and parse its JSON output.
 *
 * The script must end by writing one JSON document to stdout. Any progress or
 * warning chatter goes to stderr, so a noisy-but-successful run is still
 * parseable by scanning for the first `{` / `[`.
 */
export async function runProbe(scriptName, params = {}, { timeout = DEFAULT_TIMEOUT } = {}) {
  const chosen = await interpreter();
  if (!chosen) throw new Error('No PowerShell interpreter found (tried pwsh and Windows PowerShell 5.1)');

  const dir = await mkdtemp(join(tmpdir(), 'dsh-360-'));
  const paramFile = join(dir, 'params.json');
  const scriptPath = probePath(scriptName);
  try {
    await writeFile(paramFile, JSON.stringify(params ?? {}), 'utf8');
    const args = [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
      '-ParamFile', paramFile,
    ];
    const stdout = await run(chosen.bin, args, { timeout });
    return parseJson(stdout);
  } finally {
    await unlink(paramFile).catch(() => {});
    await rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

/** Pull the first complete JSON value out of possibly chatty stdout. */
export function parseJson(stdout) {
  const text = String(stdout ?? '').trim();
  if (!text) throw new Error('probe produced no output');
  const start = text.search(/[[{]/);
  if (start < 0) throw new Error(`probe output was not JSON: ${text.slice(0, 200)}`);
  const end = Math.max(text.lastIndexOf('}'), text.lastIndexOf(']'));
  if (end <= start) throw new Error(`probe output was truncated: ${text.slice(0, 200)}`);
  return JSON.parse(text.slice(start, end + 1));
}

/** Convenience: run one small snippet and return parsed JSON. Used by tests. */
export async function runJson(snippet, options) {
  const chosen = await interpreter();
  if (!chosen) throw new Error('No PowerShell interpreter found');
  const wrapped = `$ErrorActionPreference='SilentlyContinue'\n${snippet}`;
  const stdout = await run(chosen.bin, ['-NoProfile', '-NonInteractive', '-Command', wrapped], options);
  return parseJson(stdout);
}

/** Reset the interpreter cache — used by tests that stub the environment. */
export function resetInterpreterCache() {
  cachedInterpreter = undefined;
}
