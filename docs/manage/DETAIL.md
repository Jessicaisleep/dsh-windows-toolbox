# Windows Plugin Manager · Technical Notes

> v0.1.0 · Measured on Windows 10 Pro (build 19045) · PowerShell 7.6.10 · not elevated
> Every number below was measured on this machine on 2026-11-17, not estimated.

## 1. What problem this solves

Windows has no single place that answers "what gets loaded on this machine, what is currently on, and what happens if I turn it off". The answer is scattered across eleven registration points that do not know about each other:

| Registration point | Authoritative source | Rows here | Time |
|---|---|---|---|
| Services | SCM | 272 | 707 ms |
| Scheduled tasks | Task Scheduler + `System32\Tasks` | 165 | 1267 ms |
| Autostart | ten Run/RunOnce keys + Startup folders + UWP StartupTask + logon/boot scheduled tasks + auto-start services + Active Setup | 136 | 1927 ms |
| Shell extensions | 12 shellex locations + the Approved allow-list | 75 | 2306 ms |
| Installed programs | three Uninstall roots (HKLM 64/32, HKCU) | 114 | 606 ms |
| AppX / MSIX | `Get-AppxPackage` (PS7 through the 5.1 bridge) | 100 | 3976 ms |
| Drivers | `HKLM\SYSTEM\DriverDatabase` + `Win32_PnPSignedDriver` | 418 | 1611 ms |
| Firewall rules | COM `HNetCfg.FwPolicy2` | 546 | 1059 ms |
| Image-file hijacks (IFEO) | `HKLM\...\Image File Execution Options`, both views | 86 | 521 ms |
| File associations | `HKCU\...\FileExts` UserChoice | 520 | 609 ms |
| Credential providers | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers` | 22 | 495 ms |

**2320 registration points** total. Separately there is a **system-repair board** with 8 items (see [REPAIR.md](REPAIR.md)); those are not registration points, have no on/off state, and therefore are not in the table above and do not participate in card grouping. All twelve probes cold-start in parallel in **5400 ms** (including the 904 ms of the repair board), 0 ms when cached.

The plugin folds them into one index where every row can answer four questions: what is it, is it on, is it safe to change, and how do I undo the change.

## 2. The five hooks

Every capability is described by the same interface:

```
detect    read current state, change nothing
enable    turn it on
disable   turn it off, reversibly
verify    re-read to confirm the write landed
rollback  restore the value captured by detect
```

What v0.1 actually wires:

- **detect** — all eleven registration points plus the 8 system-repair checks.
- **enable / disable / rollback** — services, tasks, autostart, shell extensions, firewall rules (five reversible classes, each with its own write path and undo record in `actions.ps1`).
- **single verb `uninstall`** — installed programs, AppX/MSIX, driver packages. Their only action is uninstall/delete, which is destructive, so they get no enable/disable; the card face offers 「卸载」, previews the exact command first, and refuses `systemComponent=true`, `bound=true` driver packages, and non-third-party driver packages.
- **not wired** — IFEO, file associations, credential providers. These three are read-only in this version (a hijacked IFEO entry is flagged `blocked` and painted red, but editing it means writing into the system directory's registry, and the risk is not symmetric). The uninstall button previews the exact command and refuses any bound package precisely because deleting a driver a device is using is a blue screen.

## 3. Risk classes

| Class | Meaning | Rows here |
|---|---|---|
| `blocked` | protected; the UI must refuse to act | 30 (all services) |
| `reversible` | has enable/disable with a captured undo | 1030 (svc 242 + firewall 542 + task 165 + com 78 + autorun 3) |
| `destructive` | removes something; not always undoable | 632 (drv 418 + program 114 + appx 100) |
| `readonly` | list only | 636 (fileexts 520 + ifeo 86 + credprov 22 + repair 8) |

2462 rows in total (2454 registration rows + 8 repair rows).

**35 protected services**: `rpcss`, `rpcepmap`, `dcomlaunch`, `lsm`, `power`, `plugplay`, `bfe`, `eventlog`, `profsvc`, `samss`, `winlogon`, `wuauserv`, `trustedinstaller`, `msiserver`, `gpsvc`, `cryptsvc`, `dhcp`, `dnscache`, `nsi`, `netprofm`, `nlasvc`, `lanmanworkstation`, `lanmanserver`, `windefend`, `seclogon`, `sppsvc`, `themes`, `audiosrv`, `audioendpointbuilder`, `brokerinfrastructure`, `systemeventsbroker`, `staterepository`, `coremessaging`, `event system`, `devicesetupmanager`.

These are the "disabling looks fine until you reboot and land on a black screen" class, so they are `blocked` with no button at all.

Second `blocked` rule: a service whose binary path matches `\\drivers\\` or `.sys` **and** whose `acceptStop` is `false` is a kernel-mode service — stopping it can bugcheck the box.

## 4. Layout

```
dsh-windows-toolbox/
├─ index.js              host: 6 API routes + 6 agent tools
├─ client.js             client: sidebar entry + main panel (hand-rolled React, no host UI package)
├─ cordis.patch.yml      bundle patch
├─ icon.svg
├─ lib/
│  ├─ sources.js         the twelve sources, risk classes, 35 protected services
│  ├─ normalize.js       folds each probe's JSON into one entry shape
│  ├─ explain.js         turns a raw row into "what it is / where it shows / what it does / what breaks if off" (zh+en)
│  ├─ inventory.js       caching and scheduling (5-minute TTL, one failing source never kills the rest)
│  └─ probes/
│     ├─ svc.ps1
│     ├─ task.ps1
│     ├─ autorun.ps1
│     ├─ com.ps1
│     ├─ program.ps1
│     ├─ appx.ps1        AppX/MSIX (PS7 → Windows PowerShell bridge)
│     ├─ driver.ps1      registry-based, deliberately not pnputil
│     ├─ firewall.ps1    firewall rules (COM HNetCfg.FwPolicy2)
│     ├─ ifeo.ps1        image-file hijacks
│     ├─ fileexts.ps1    file associations
│     ├─ credprov.ps1    credential providers
│     ├─ repair.ps1      system repair: 8 configuration-drift checks
│     ├─ featurelib.ps1  probe shared library (row shape, UTF-8, error containment)
│     ├─ actions.ps1     enable / disable / rollback executor (incl. the firewall nine-tuple)
│     └─ host.ps1        host facts (elevated?, user, OS build)
├─ tests/
│  ├─ run-all.mjs        55 checks (31 unit + 24 live)
│  └─ render.mjs         headless React renderer: proves the panel mounts and paints (real 12-source fixture)
└─ docs/
   ├─ DETAIL.zh.md / DETAIL.md    this file
   ├─ SCOPE.zh.md / SCOPE.md      what else could be split out (incl. the four rejected, with reasons)
   └─ REPAIR.zh.md / REPAIR.md    the system-repair board
```

## 5. Interface

### HTTP (host)

Prefix `/dsh-windows-toolbox/api/manage`. Every route validates host/origin; off-machine callers are refused.

| Method | Path | Purpose |
|---|---|---|
| GET | `/status` | host facts + per-source counts and timings; the first call runs the full probe sweep |
| GET | `/entries` | the unified index, filters `source` / `enabled` / `risk` / `q` / `limit` / `lang` |
| GET | `/detail?id=` | full payload for one row |
| POST | `/refresh` | force a re-run (optionally a subset, in parallel) |
| POST | `/action` | enable / disable / rollback, **`dryRun` defaults to true** |
| POST | `/repair` | the eight system-repair checks: `{action:'scan'\|'fix', dryRun, ids}`, **`dryRun` defaults to true** |

### Agent tools

`wpm_status`, `wpm_list`, `wpm_detail`, `wpm_refresh`, `wpm_action`, `wpm_repair`. `wpm_action` defaults to `dryRun: true` — without an explicit `dryRun: false` it only plans. `wpm_repair` behaves the same and its description states outright that hosts is never modified and UAC / font cache / icon cache are reported, never auto-fixed.

## 6. Fifteen traps (all measured, not guessed)

### 6.1 PS7 cannot load the Appx module, and does not say so

```
在模块 'Appx' 中找到了 'Get-AppxPackage' 命令，但由于以下错误而无法加载该模块:
[Operation is not supported on this platform. (0x80131539)]
```

Worse: `Get-AppxPackage` does **not** throw, it returns nothing — which reads as "this machine has no AppX packages". That is a silent false zero. The real count is 100 (via Windows PowerShell 5.1).

`appx.ps1` has a three-tier fallback: ① `Import-Module Appx -UseWindowsPowerShell`, then **verify count > 0 before believing it**; ② re-run itself under `System32\WindowsPowerShell\v1.0\powershell.exe`; ③ read `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications` as a last resort.

Corroborating signals (use these to tell "no AppX" from "probe broke"): `AppxAllUserStore\Applications` has 44 keys, `%LOCALAPPDATA%\Packages` has 87 directories, but `C:\Program Files\WindowsApps` has 0 subdirectories — believing only the last one gives the opposite conclusion.

### 6.2 A literal `*` in a registry path requires `-LiteralPath`

`HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers` — that `*` is a **real key name** (the wildcard shell extension). With plain `-Path`, PowerShell treats it as a wildcard and walks the entire Classes tree; measured **> 2 minutes without finishing**, which looks like a hang.

`-LiteralPath` returns immediately. The first version of the com probe read only 96 rows because this bug silently skipped a large chunk.

### 6.3 Probing a registry key that does not exist costs ~387 ms

Measured: 60 `Test-Path -LiteralPath` calls against nonexistent keys = **23240 ms**; against nonexistent subkeys = **47003 ms**.

Bulk-enumerating existing keys is cheap: indexing all three CLSID roots took **1498 ms for 7711 entries**, and `Get-ChildItem` over the 78 existing keys took **47 ms**.

So `com.ps1` was rewritten from "probe 6–9 possibly-absent paths per row" to "enumerate each root once into a hashtable, resolve from memory". **85.5 s → 9.81 s → 2.2 s**, all 78 rows preserved.

> This applies to the **registry provider only**. On the filesystem, `Test-Path` against a missing path costs 1.62 ms (100 calls = 162 ms); bulk probing is cheap there. Do not carry the conclusion across.

### 6.4 PowerShell `return` enumerates a List

When `$rows` is a `List[object]`, `return $rows` hands the caller the enumerated contents (a single element even arrives as an OrderedDictionary), and the following `.ToArray()` throws:

```
方法调用失败，因为 [System.Collections.Specialized.OrderedDictionary] 不包含名为 'ToArray' 的方法。
```

Fix: `return , $rows` (leading comma). Any PowerShell function returning `List[object]` needs it.

### 6.5 OrderedDictionary silently defeats `Sort-Object -Property <key>` and `Measure-Object -Sum`

No error, no warning — wrong results that look plausible:

```powershell
$rows | Sort-Object -Property bytes -Descending                  # unchanged order
$rows | Sort-Object -Property { [int64]$_.bytes } -Descending    # correct
```

Likewise `$rows | Measure-Object -Property files -Sum` returns nothing, because dictionary keys are not PS properties to the cmdlet.

In this plugin svc/task/autorun emit PSCustomObject, so it does not bite. The 360 toolbox (built on the same probe idea) hit it in three places and only scriptblocks fixed it. **If a probe emits OrderedDictionary, every sort and every sum must use a scriptblock or a manual `foreach`.**

### 6.6 PowerShell writes in the system code page; Node decodes UTF-8 → all Chinese becomes mojibake

All nine `.ps1` files use `[Console]::Out.Write(...)`. PowerShell emits GBK (936) by default, Node decodes UTF-8, and every Chinese string turns into `�ܾ������ܱ�������`.

This went unnoticed for a while because the tests only asserted JSON structure. Fix, in every script right after `param(...)`:

```powershell
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
```

**Any PowerShell → Node UTF-8 pipe needs this line.**

### 6.7 `pnputil /enum-drivers` localized labels are broken in a zh-CN console

It prints localized field labels (`发布名称:` / `类名:`), and the zh-CN console mangles them regardless of code page: `cmd /c chcp 65001 && pnputil /enum-drivers` still yields `Class Name: ��չ`, and setting `[Console]::OutputEncoding` to 936 or 65001 changes nothing. 290 lines, exit 0, English labels fine, Chinese labels destroyed — so any label-based parser matches 0 rows and concludes "no driver packages".

`driver.ps1` therefore reads the registry: `DeviceIds` / `DriverFiles` / `DriverInfFiles` / `DriverPackages` under `HKLM:\SYSTEM\DriverDatabase`. No encoding problem, no elevation, and more data (both-way mapping, SignerScore, third-party detection). Measured: 250 driver packages + 168 devices in 1.5 s.

### 6.8 `new URL(...).pathname` percent-encodes non-ASCII paths

The plugin lives under `E:\DSHWORK\DSH插件\...`; `.pathname` yields `DSH%E6%8F%92%E4%BB%B6`, PowerShell reports "path not found", and every probe dies. Use `fileURLToPath(new URL(file, PROBE_ROOT))`.

### 6.9 For shell extensions, "empty string" and "absent" mean opposite things

In `Shell Extensions\Approved`:

- CLSID **not present** → normal load path (**enabled**)
- CLSID present with an **empty value** → explicitly blocked (**disabled**)

The first version collapsed both into `approved: ''`, so all 78 rows displayed "unknown". The probe now returns an `inApproved` boolean and the normalizer distinguishes the two cases.

### 6.10 `New-Item -Force` wipes an existing registry key (real data loss, our own bug)

To dodge the "probing a missing key is expensive" problem, the first tweaks write path used `New-Item -Path $r.path -Force`, with a comment calling it "a cheap no-op". **That assumption was wrong**: `-Force` **recreates** a key that already exists, discarding every value and subkey, without raising an error.

Isolated reproduction (`HKCU\Software\WpmProbeTest2`): before the call `a=111 b=keepme`, after it both are gone.

Real consequence: `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` was emptied to 0 values. This machine had zero restore points, no RegBack coverage for HKCU, no .reg backup and no Windows.old — only a subset was recovered from an export file made beforehand.

The correct form:

```powershell
if ($null -eq (Get-Item -LiteralPath $r.path -ErrorAction SilentlyContinue)) {
    New-Item -Path $r.path -ErrorAction Stop | Out-Null
}
```

Along the way one number got corrected: **probing a missing key with `Get-Item` costs about 10 ms**; 387 ms is the `Test-Path` figure.

> This applies to the **registry provider only**. On the file system, `New-Item -ItemType Directory -Force` measured safe (it does not empty an existing directory).

### 6.11 `Get-NetFirewallRule` silently returns 0 rows under PS7

Same class of trap as the AppX false zero in 6.1: the NetSecurity module yields 0 results under PS7 without throwing, so it looks like "this machine has no firewall rules". Bridged through `powershell.exe` 5.1 it reports `Access is denied` instead.

`firewall.ps1` therefore uses the COM interface `HNetCfg.FwPolicy2` (`New-Object -ComObject HNetCfg.FwPolicy2`): 542 rules enumerated in **44 ms**, no administrator needed.

**But firewall rule Name is not unique**: the 542 rules carry only 324 distinct names, adding direction still leaves 131 colliding groups, and adding `Profiles` still leaves 63. So `actions.ps1` keys on a **nine-tuple** `name|dir|action|protocol|localPorts|remotePorts|app|profiles|serviceName`, which is 542/542 unique; when a name-based fallback lookup matches more than one rule it refuses rather than guessing.

### 6.12 A PowerShell `param` block must be the very first statement

`appx.ps1` once had the UTF-8 line above `param(...)`, so PowerShell treated `param` as the name of a command to invoke:

```
术语 'param' 不会被识别为 cmdlet、函数、脚本文件或可执行程序的名称。
```

It **prints that to stderr and then keeps executing the script body**, and Node's `parseJson()` skips leading noise — so everything "looked fine" while no parameter was ever bound and the 5.1 fallback path was dead code that could never run. Fixing it immediately exposed a second bug (runaway child spawning, below), because that branch had never been reachable.

How to audit an entire code base: no executable statement may appear before `param`. A `param(...)` inside a function body does not count.

### 6.13 Fixing parameter binding detonated a fork bomb

Inside the `-NativeOnly` child, step 1 was skipped wholesale by `if (-not $NativeOnly)` → `$rows` stayed `$null` → step 2's `if ($null -eq $rows)` held → another 5.1 child was spawned → infinite recursion. It hung for over 180 seconds.

Fix: add `-not $NativeOnly` to step 2's condition. And pin down what `-NativeOnly` means: "you are the 5.1 child: enumerate natively, do not use the bridge, do not spawn again" — what is withheld is the **bridge**, not **enumeration**. The original code read it as "skip step 1 entirely", which is the exact opposite.

### 6.14 An explanation layer must not quote itself back

`lib/explain.js` owes every row a plain-language explanation. On the first coverage count I reported "78/78 rows have a friendly name", and **that was wrong** — when the CLSID key's `(default)` was missing, the code fell back to `PSChildName`, which *is* the GUID, so the GUID was being used as proof that a name existed.

Real coverage (78 com rows measured): CLSID key `(default)` has a name in 62, the DLL has a `FileDescription` in 68, a `CompanyName` in 68 (11 of them third-party), any usable source in 72; for the remaining 6 the friendly name actually sits in the `rawValue` field (`Taskband Pin`, `Start Menu Pin`, `OLE DocFile Property Page`, `Summary Properties Page`). Reading `displayName || rawValue || dllDescription` reaches 78/78.

The corollary: **explanation material must come from fields the probe really emits**. The first `explain.js` read `detail.dllDescription` / `detail.dllCompany`, which `com.ps1` never produced → everything was `origin: null` and `purpose` degraded to a restatement. Adding the probe fields (read `(Get-Item $server).VersionInfo`, dedupe by DLL path — 24 unique DLLs behind 78 references) produced `origin=thirdparty 11` / `origin=microsoft 57` for about +215 ms.

### 6.15 An explanation must name the actual tab or menu item, never just the category

The user's words: "文件夹「属性」对话框里多出来的一页……这里你需要讲明，多出来的是哪一页？具体对应哪项？右键菜单也是，你需要说明对应的是哪个右键菜单，而不是就一句对应右键菜单中的一项。"

The cause was `SHELLX_PLACEMENT` (16 `root|kind` pairs → one Chinese/English sentence) describing only the *placement category*, so all 78 cards of a kind read identically. Fixed in three steps, all by adding probe fields rather than hand-writing 78 captions:

1. `com.ps1` reads the CLSID's `PageTitle` and resolves it through `SHLoadIndirectString` (an inline C# `DllImport` of `shlwapi.dll` via `Add-Type`). Only **6** CLSIDs on this machine carry a `PageTitle`; they all resolve to 「以前的版本」/ "Previous Versions".
2. `com.ps1` reads `ImplementsVerbs` and turns verbs into the menu text the user actually sees (`startpin`/`startunpin` → "Pin to Start"/"Unpin from Start", and the taskbar pair). Only **4** rows have verbs.
3. For rows with neither, `explain.js` consults `SHELLX_ITEM_LABEL` (30 keys, dual-keyed `'<clsid>|<handlerKind>'` with a bare-clsid fallback) for verified captions. The table stores **bare** names (`位置`, `安全`, `ReadyBoost`); the wrapper (`「…」页` / `"…" tab`) is added exactly once by the caller — otherwise you get `「「位置」页」页`.

Three boundaries that must be remembered:

- **A class name is not menu text.** `ShellContextMenu Class`, `DfsShell Class`, `kdesktopshellext Class` are COM registration names that the context menu never displays; offering them as a caption is worse than saying nothing. Guard: `looksLikeCode = /(^|\s)(Class|Handler|Extension|Extensions|Handler Class|Shell Extension)$|\bCLSID\b|^\{/i`. A vendor-supplied name (`360压缩文件类型`) *is* what the user sees and must be used.
- **Verbs must be stored as menu-item text, not sentences.** The first `startpin` read 「把这一项固定到「开始」屏幕」, which made `what` read "它加的是把这一项固定到「开始」屏幕" — half a sentence. The table now stores `固定到开始屏幕` and the assembler adds the quotes. A regression assertion (`!/把这一项/.test(zh.what)`) guards it.
- **Never quote a placeholder as a name.** An unnamed device `(未命名)` must fall back to the device id (`HTREE\ROOT\0`), otherwise you emit "它现在绑定的驱动 INF 是 (未命名)".

Measured over all 2462 rows: empty `where` **168 → 0** (all of them drv device rows, whose entire card was one category sentence); CJK brackets leaking into English **67 → 0**; distinct `what` **2154/2327**; com rows carrying `—具体是` **60/78** (the remaining 18 are system handlers with no displayName and no DLL version resource — better silent than guessed).

## 7. Privilege boundary (measured, not elevated)

| Operation | Result |
|---|---|
| Rename an HKCU autostart value | ✅ works |
| Write a value under HKCU `...\Approved` | ✅ works |
| Write a value under HKLM `...\Approved` | ❌ access denied |
| `Set-Service` | ❌ access denied |
| `Disable-ScheduledTask` | ❌ access denied |
| `pnputil /delete-driver` | needs admin |

`actions.ps1` checks before writing: not elevated + not dryRun + source in `svc`/`task` → it returns

```json
{ "ok": false, "changed": false, "needsAdmin": true, "canElevate": true,
  "message": "该操作需要管理员权限。可在插件里点「以管理员身份重试」。" }
```

dryRun is unaffected by privilege and still returns the plan plus the undo record.

## 8. How rollback works

**Capture the undo record before every write.**

| Source | disable | enable | rollback |
|---|---|---|---|
| svc | `Stop-Service` → `Set-Service -StartupType Disabled` | restore to `Manual` (not Automatic; the original start type is in the undo record) | exact restore from the recorded startMode |
| task | `Disable-ScheduledTask` | `Enable-ScheduledTask` | restore original state |
| autorun (registry) | rename the value to `<name>.__disabled` (**never delete**) | move `.__disabled` back | restore per undo |
| autorun (Startup folder) | add a `.disabled` suffix | remove it | restore |
| com | `New-ItemProperty -Name <CLSID> -Value ''` (empty = blocked) | write the displayName back | write back or delete per `hadValue` |
| firewall | `$rule.Enabled = $false` via COM (unelevated throws `E_ACCESSDENIED 0x80070005` and leaves the rule untouched) | `$rule.Enabled = $true` | restore per undo |
| repair | `fix` off by default; `dryRun=true` only plans | — | restore per undo (dead startup values are re-created) |

Firewall rules cannot be addressed by name alone: the 542 rules carry only 324 unique names, `name+dir` still leaves 131 collisions, and adding `Profiles` still leaves 63. The executor therefore keys on the **nine-tuple** `name|dir|action|protocol|localPorts|remotePorts|app|profiles|serviceName`, which is 542/542 unique, and refuses rather than guessing when a name-only lookup is ambiguous.

Verified end to end: an HKCU RunOnce value renamed to `Application Restart #0.__disabled` on disable and back to its original name on rollback; an HKCU Approved CLSID written then rolled back (`hadValue=false`) disappeared, leaving the value count at 1. Test residue was cleaned up.

Refusal paths are verified too: `RpcSs` → `拒绝操作受保护服务: RpcSs`; unknown service → `服务不存在: xxx`; `program` → `来源 program 不支持 enable/disable（已安装程序、AppX、驱动在本版本仅只读）`.

## 9. Tests

```bash
node tests/run-all-manage.mjs       # 55 checks (31 unit + 24 live)
node tests/run-all-manage.mjs --unit-only  # unit only (31)
node tests/render.mjs               # render the panel alone; WINDOWS_TOOLBOX_LANG=en for English
```

The live half really launches the twelve PowerShell probes and reads this machine, but **only ever runs actions.ps1 and repair.ps1 as a dry run** — nothing is written.

The `[render]` checks run `tests/render.mjs`: it mounts `client.js` in a hand-rolled miniature React runtime and asserts the tree does not throw, every dictionary key of all three namespaces resolves, real data reaches the screen, the sidebar `order` and label are correct, no `fetch` escapes the `/dsh-windows-toolbox/api/manage/` namespace, and the whole thing works in both zh and en. That is the automated proof that the panel displays — the agent cannot click DSH's own window. The fixture is captured from the live host: 12 sources / 2327–2328 rows.

The 7 newest unit checks are a regression wall for 「说明对应的是哪个右键菜单」: a property-sheet row must be named by its own `PageTitle`, a menu row by its `ImplementsVerbs` (phrased as menu text, never as a sentence — `!/把这一项/`), a verified table caption is used when the probe has none, a COM class name like `ShellContextMenu Class` is never offered as the visible caption, a third-party name like `360压缩文件类型` *is* the caption, a driver device row points at the exact node in Device Manager, and three different rows must produce three different sentences. Each of those was verified to go red by breaking the corresponding line in `lib/explain.js` on purpose.

## 10. Known limits

1. **The component store (WinSxS) is never touched.** That is a hard design line: once the store's index is disturbed, cumulative updates roll back at 9% with `Component store is corrupt, please copy the original image and start again` — copying files back does not help, because the index is what broke.
2. **Uninstall is not reversible.** Programs / AppX / drivers do offer an uninstall button, but it only runs the program's own uninstall string or pnputil — there is no undo record. System components (systemComponent=true) and driver packages currently bound to a device (bound=true) are refused.
3. **Without elevation, services and tasks cannot be changed**, only planned. The UI says so explicitly.
4. **Shell extension `enabled` relies on the Approved allow-list**, which is an old Explorer code path; an extension absent from Approved is in fact still loading, so it defaults to "enabled".
5. **Driver package versions are blank.** `Version` under `DriverDatabase` is a binary blob and is not parsed.
6. **AppX depends on the Windows PowerShell bridge.** If PowerShell 5.1 is removed, it degrades to registry mode (names only, no version or publisher).
7. **The panel's visual rendering has not been checked in a browser.** The agent cannot click DSH's own window (`HOST_INPUT_DENIED` / `INPUT_TARGET_UNAVAILABLE` / `WCU_POLICY_DENIED`), so a headless React harness verifies that the component tree mounts, paints real data, and has every dictionary key in both zh and en — but the visual result needs a human look.

## 11. Install

```
plugin_manager install_bundle  target: E:\DSHWORK\DSH插件\dsh-windows-toolbox
```

The profile records `link:E:/DSHWORK/DSH插件/dsh-windows-toolbox`, so edits take effect immediately without reinstalling. Neither the host nor the client needed a DSH restart.
