# Windows Toolbox · Technical notes

One DSH plugin, two halves, sharing one probe infrastructure, one risk taxonomy and one "dry run before you write" safety model.

| Half | Panel tab | Scale | Deep docs |
|---|---|---|---|
| Registration manager | 插件化管理 | 11 registration-point classes / 2454 rows + an 8-check system-repair board | [details](manage/DETAIL.md) · [scope decisions](manage/SCOPE.md) · [system repair](manage/REPAIR.md) |
| Toolbox | 工具箱 | 25 capabilities / 9 cleanup groups / 31 cleanup targets | [details](toolbox/DETAIL.md) |

This document covers only what the two halves **share**: why the split is where it is, the common infrastructure, the common safety model, and the traps that bite either half. Per-half detail lives in the linked documents.

---

## 1. Why one plugin and not two

These were two separate plugins (`dsh-windows-plugin-manager` + `dsh-360-toolbox`) until 2026-11-18. The merge was not driven by "they look related" but by the fact that **they had already started sharing things**:

| Shared thing | Before | After |
|---|---|---|
| `ps.js` PowerShell launcher | two copies (differing by one `rm()`) | one (the version with `rm()`) |
| `featurelib.ps1` | two copies (127 lines vs 155; the larger adds `Add-Item -Extra` and `Get-OptionalString`) | one (the 155-line superset) |
| `host.ps1` | two copies, **byte-identical** | one |
| `reg export` backup | two separate implementations | one directory, `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\` |
| Elevation channel | two | one (`elevated.ps1` + two routes onto the same implementation) |
| dryRun default semantics | two informal conventions | one convention, asserted across both halves |

The immediate win is that **the tests can no longer cheat through copy-paste**. Before the merge the two `render.mjs` files were the same code twice, so half A's assertions going green could be caused by half B's file; now `tests/run-all.mjs` covers both in one run.

The cost: inside `index.js` the two halves are mounted in **independent try/catch blocks**. If one fails to mount, the other still works and only a `console.warn` is emitted. That is deliberate — a plugin failing should degrade, not go dark.

```js
function mountHalf(name, fn, ctx, config) {
  try {
    fn(ctx, config);
  } catch (err) {
    console.warn(`[${ID}:${name}] failed to mount: ${err?.message ?? err}`);
  }
}
```

### Why the tool names were not merged

The 12 agent tools keep two prefixes: `wpm_*` (7, registration points) and `tb360_*` (5, maintenance). Unifying them into `*_status` etc. would leave a model reading the tool list unable to tell which `status` is which. The prefix exists for the reader of the tool list, not for the code.

---

## 2. Shared infrastructure

### 2.1 `lib/ps.js` — the PowerShell launcher

| Export | Purpose |
|---|---|
| `probePath(name)` | absolute probe path via `fileURLToPath` (**never `.pathname`**, see trap 3.1) |
| `interpreter()` | cached choice: `pwsh` (PS7) first, else `System32\WindowsPowerShell\v1.0\powershell.exe` (5.1) |
| `runProbe(script, params, {timeout})` | writes `params` to a temp JSON and passes it as `-ParamFile` |
| `parseJson(stdout)` | tolerates stderr chatter: first `[`/`{` through last `]`/`}` |
| `resetInterpreterCache()` | for tests |

**Parameters always travel via `-ParamFile`, never interpolated into the script text.** A user-supplied path, CLSID or service name spliced into a command becomes arbitrary code execution behind one quote character.

### 2.2 `featurelib.ps1` — the row contract

Every "checks"-style probe emits the same row, which is what lets both halves share one renderer:

```powershell
[ordered]@{ id; group; label; status; value; detail; fix; needsAdmin }
```

`status` has exactly five values with fixed meaning:

| status | Meaning | UI |
|---|---|---|
| `ok` | measured, healthy | green |
| `warn` | measured, worth a look | amber |
| `bad` | measured, actually broken | red |
| `info` | pure fact (version, path, count) | grey |
| `skip` | **not measured**, `detail` must say why | dimmed + reason shown |

`skip` is the most important value in this contract. Missing tool, missing admin rights, unsupported hardware — all become `skip` with a stated reason. **Not measuring something must never be recorded as measuring it healthy.**

`Add-Item` also accepts `-Extra` (the superset version introduced with the toolbox half) for side-channel fields such as `labelZh`/`effectZh`. `lib/runner.js`'s normalizer forwards those to the panel. That is the fix point for the "Chinese tweak labels never reached the screen" bug: the original normalizer kept exactly 8 fixed fields and silently dropped the rest.

### 2.3 Risk taxonomy (identical in both halves)

```
blocked      must not be touched (protected services, IFEO hijack targets, system components)
reversible   writable and undoable: registry value, service start type, task enable, shell
             extension approve/block, firewall rule enable
destructive  not undoable: uninstall a program, remove an AppX package, delete a driver package,
             shred a file
readonly     checks only, no write path at all
```

`blocked` is decided by `riskOf()` in `lib/sources.js`: membership in the 35-entry `PROTECTED_SERVICES` set, a kernel path matching `\\drivers\\|\.sys\b` whose `acceptStop === false`, or an IFEO row with `detail.hijacked === true`.

### 2.4 Caching

- Registration index (`inventory.js`): 5-minute TTL, serial by default (twelve PowerShell processes at once will turn a low-end machine into what looks like a hang), parallel on refresh. Cold start ≈ 5.4 s for the full index (2327–2328 rows; the count drifts with services starting and stopping).
- Toolbox (`runner.js`): 5-minute TTL, per-capability timeouts (junk 120 s / dupfiles 240 s / speedtest 180 s / netdiag 240 s).
- **The cache stores one language only (`zh`)**; English is re-derived per request in `host-manage.js`'s `withLang()`. `explainEntry` is a pure function over the row, so recomputation is cheap, and storing both languages would double the cache for a value that may not change for an entire session.

---

## 3. Traps that bite either half (each measured, not guessed)

### 3.1 `new URL(...).pathname` percent-encodes non-ASCII paths

The plugin lives under `E:\DSHWORK\DSH插件\...`; `.pathname` yields `DSH%E6%8F%92%E4%BB%B6`, PowerShell reports "cannot find path", and **every probe dies at once**. Use `fileURLToPath(new URL(file, PROBE_ROOT))`.

### 3.2 PowerShell writes in the system code page, Node decodes as UTF-8

All Chinese becomes `�ܾ������ܱ�������`. Every `.ps1` must set, **after** `param(...)`:

```powershell
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
```

Testing only the JSON structure will not catch this: the structure is fine and the content is garbage.

### 3.3 The `param` block must be the first statement in the script

Otherwise PowerShell writes `术语 'param' 不会被识别为 cmdlet…` to stderr and then **keeps executing the body**. Node's `parseJson()` skips the noise, so everything "looks fine" while the parameters were never bound — the fallback path silently becomes dead code.

### 3.4 A PowerShell function's `return` enumerates a `List`

```powershell
return $rows        # caller receives the enumerated items; with one element, not even an array
return , $rows      # correct: the leading comma suppresses enumeration
```

The follow-on symptom is `[OrderedDictionary] does not contain a method named 'ToArray'`.

### 3.5 `OrderedDictionary` makes `Sort-Object -Property <key>` and `Measure-Object -Sum` fail silently

```powershell
$rows | Sort-Object -Property bytes -Descending        # does not sort at all, no error
$rows | Sort-Object -Property { [int64]$_.bytes } -Descending   # correct
$rows | Measure-Object -Property files -Sum            # returns nothing
```

A dictionary's keys are not PS properties as far as these cmdlets are concerned. All sorting and summing must go through a scriptblock or a hand-written loop. This trap has produced both "288 MB listed above 575 MB" and "totalFiles silently became empty".

### 3.6 `New-Item -Force` **erases an existing registry key**

```powershell
New-Item -Path $key -Force    # key exists -> recreated, all values and subkeys discarded, no error
```

This caused real data loss here (`HKCU\...\Explorer\Advanced` emptied to 0 values). Correct form:

```powershell
if ($null -eq (Get-Item -LiteralPath $path -ErrorAction SilentlyContinue)) {
    New-Item -Path $path -ErrorAction Stop | Out-Null
}
```

Related correction: probing a non-existent registry key with `Get-Item` costs about **10 ms**; the 387 ms figure belongs to `Test-Path` (a registry-provider quirk). On the filesystem `Test-Path` costs 1.6 ms and is fine to use in bulk.

### 3.7 A literal `*` in a registry path requires `-LiteralPath`

`HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers` with plain `-Path` is treated as a wildcard; the provider walks the entire `Classes` tree and takes over two minutes, which looks like a hang.

### 3.8 PS7 cannot load the Appx module, and does not say so

Under PS7, `Get-AppxPackage` fails with `Operation is not supported on this platform. (0x80131539)`; the command **does not throw, it returns nothing** — so it looks like "this machine has no AppX". There are 100 packages. Fix: `Import-Module Appx -UseWindowsPowerShell`, and **verify `count > 0` before trusting it**; otherwise fall back to a `powershell.exe` 5.1 child process.

Same family: `Get-NetFirewallRule` under PS7 **silently returns 0 rows** (there are 542). Use the COM API `HNetCfg.FwPolicy2` instead: 44 ms to enumerate, no elevation needed.

**General lesson: when an enumeration returns zero, first prove the zero is real.**

### 3.9 The explain layer must not recite itself

The first `explain.js` returned a per-`source` fixed sentence, so all 78 shell-extension cards read: "A shell extension. It does not run by itself, but adds an item to Explorer." The user's words were "your description is as good as nothing."

Fix: build each sentence from **that row's own data**. For shell extensions this means naming the concrete thing on screen: `PageTitle` resolved through `SHLoadIndirectString` gives the real tab caption ("Previous Versions", "Location", "Security"); `ImplementsVerbs` gives a plain-language verb ("Pin to Start / Unpin from Start").

It also has to avoid presenting **COM class names as user-visible labels**: `ShellContextMenu Class`, `DfsShell Class`, `kdesktopshellext Class` never appear in a menu. Showing one as the caption is worse than saying nothing. See the `looksLikeCode` regex in `lib/explain.js`.

Two more boundaries only showed up when measured:

- **The verb table must hold menu-item text, not sentences.** The first `startpin` read 「把这一项固定到「开始」屏幕」, which made `what` read "它加的是把这一项固定到「开始」屏幕" — half a sentence. The table now stores `固定到开始屏幕` and the assembler adds the quotes. A regression assertion (`!/把这一项/.test(zh.what)`) guards it.
- **Never quote a placeholder as a name.** An unnamed device's `name` is `(未命名)`; pasting that into a sentence produces "它现在绑定的驱动 INF 是 (未命名)". It must fall back to the device id (`HTREE\ROOT\0`).

Measured across all 2462 rows: empty `where` **168 → 0** (every one of them a drv device row whose whole card was one category sentence); CJK brackets leaking into English **67 → 0**; distinct `what` **2154/2327**. Seven new unit assertions in `tests/run-all-manage.mjs` hold these numbers, and each was verified to go red by breaking the corresponding line on purpose.

---

## 4. Safety model (shared)

1. **Every write route defaults to `dryRun: true`.** Unless the body explicitly sends `dryRun: false`, the route only plans. The plan is structurally the same response as a real run (the targets, the bytes that would be freed, the exact commands that would execute), not a placeholder.
2. **Back up before writing; abort if the backup fails.** Registry writes `reg export` to `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\<timestamp>-<key>.reg`; if that directory cannot be created, nothing is written. Firewall rules use `Backup-FirewallRules` (77 ms, 314 KB, works unelevated).
3. **Capture the undo record before mutating.** `existed: false` in the record means "this key did not exist", so rollback deletes rather than restoring an empty value.
4. **Blocked rows get no button.** A `risk === 'blocked'` card shows a grey "protected" label rather than a disabled button, so "I clicked and nothing happened" cannot be mistaken for a bug.
5. **Disabling a shell extension writes an empty string, it does not delete the value.** An empty value under `Approved` means blocked; **a missing value does not**, because that path is only consulted by specific legacy code. Conflating the two makes "disabled" look successful while nothing changed.
6. **Never used**: `Set-ExecutionPolicy`, `Invoke-Expression`/`iex`, `Format-Volume`, `Initialize-Disk`, `Remove-Partition`, `Clear-Disk`, `diskpart clean`, bulk `reg delete`, `bcdedit`, `Restart-Computer`. `tools/audit-probes.mjs` scans for these twelve constructs and fails on a hit.

---

## 5. Privilege boundary (measured on this machine, unelevated)

Host: `Windows 10 Pro build 19045`, `UAC ConsentPromptBehaviorAdmin = 5`, user `CHEN-KETING\26035`, `elevated = false`.

| Operation | Unelevated result |
|---|---|
| HKCU registry write | ✅ works |
| HKCU autorun value rename | ✅ works |
| `reg export` backup | ✅ works |
| Startup-folder rename | ✅ works |
| DNS cache flush / `netsh` DNS change | ✅ works |
| `Set-Service` | ❌ `拒绝访问。` (access denied) |
| `Disable-ScheduledTask` | ❌ `拒绝访问。` |
| HKLM `Approved` write | ❌ denied |
| Firewall rule `Enabled=` | ❌ `E_ACCESSDENIED 0x80070005` (rule left untouched) |
| `pnputil /delete-driver` | ❌ needs admin |
| Any DISM operation | ❌ `Error: 740` |
| `fltmc filters` | ❌ denied |

So instead of failing outright, every write route that needs admin returns:

```json
{ "ok": false, "changed": false, "needsAdmin": true, "canElevate": true,
  "message": "该操作需要管理员权限。可在插件里点「以管理员身份重试」。" }
```

The panel renders a "retry as administrator" button from that, hitting `POST /api/{manage,toolbox}/elevated`: `Start-Process -Verb RunAs` launches a child that runs `actions.ps1`, writes `%TEMP%\dsh-wpm-elevated-<guid>.json`, and the parent polls for up to 180 s. **A cancelled UAC prompt returns `{ok:false,cancelled:true}` with HTTP 200, not 500** — declining is not an error.

---

## 6. Tests

```bash
node tools/smoke-merged.mjs          # are both halves mounted: 13 routes + 12 tools + 0 stale prefixes
node tools/audit-probes.mjs          # 44 probes: syntax / param position / UTF-8 header / banned APIs / output contract
node tests/run-all.mjs               # both halves in full (real probe runs, a few minutes)
node tests/run-all.mjs --unit-only   # units only
node tests/render.mjs                                  # headless render of the manage half
WINDOWS_TOOLBOX_PANEL=toolbox node tests/render.mjs    # headless render of the toolbox half
```

`tools/smoke-merged.mjs` exists specifically for this merge. It captures `webServer.register()` and `tools.register()` calls, asserts all 13 routes and 12 tools are under the right API prefix, and asserts that **none of the old `/dsh-360-toolbox/api` or `/dsh-windows-plugin-manager/api` strings survive** (a survivor 404s silently). The most likely mistake when moving a file into the merged tree is forgetting the path constant inside it, and no syntax check catches that.

`tests/render.mjs` runs the real `client.js` against a fake React; it can click, expand, switch panel tabs, and assert that row-level action buttons appear **on the collapsed card face**. It exists because before the merge every test was green while the user was looking at a wall of cards that could only be read, not acted on. Assertions must cover what a user can reach, not which branches exist in the code.

---

## 7. Known limits

- **Real-time protection is out of reach.** Popup blocking, driver-level blocking and BadUSB defence all need a resident kernel component; a plugin's lifecycle is session-scoped, and the semantics conflict (a plugin failing means degraded features; security software failing means the machine is undefended). Those capabilities do read-only posture checks and say "not possible" in the UI.
- **Nothing is recoverable after TRIM.** Both SSDs here report `DisableDeleteNotify = 0`, so deleted file contents are already zeroed at the device level and recovery tools scan blank space. The `recovery` capability only assesses and gives the correct order of operations (stop writing immediately → boot from another disk → run recovery there → restore to a third disk).
- **SMART readings are partly unavailable.** `Get-StorageReliabilityCounter` throws `AccessDenied` (reachable with elevation), while `MSStorageDriver_FailurePredictStatus` has **zero instances** (that WMI class only enumerates ATA/SATA; the NVMe hardware path does not support it, so elevation will not help either). The two `skip` rows state this separately and `smartFields` are `null`, never zero.
- **The C: expansion is hard-blocked on this machine.** C: ends at `324,420,992,512` and the recovery partition starts at `324,421,025,792` — a **32.5 KB** gap. The recovery partition has to be moved first; `expandc` reports `blocked-system-partition` and notes that deleting it would disable WinRE.
- **Windows' own names stay Chinese under an English UI.** `我的文档文件夹 UI`, `安全外壳扩展` come from this machine's Chinese Windows resources; only our own framing sentences are translated. That is accurate reporting, not a bug.

---

## 8. Install

```jsonc
// D:\Program Files (x86)\DSH_Data\profiles\desktop\package.json
"dsh-windows-toolbox": "link:E:/DSHWORK/DSH插件/dsh-windows-toolbox"
```

**Reload behaviour differs by layer**: `lib/probes/*.ps1` and `client.js` take effect immediately; `lib/*.js` and `index.js` **require restarting the DSH desktop process**. The reason is that the profile is a hoisted layout — plugin updates rewrite the files in place and the module URL never changes, so Node's ESM cache serves the old module on every later import. `POST /dsh-market/toggle` responding `hot:true` only means a fiber was rebuilt around the **old** module (verified with a double-marker experiment: the markers were unreadable), and `POST /dsh-market/restart` returns 403 `self-restart is disabled for this host` whenever a supervisor is present.
