# System repair (repair)

Modelled on 360 Safe's "system repair / speed-up" module. 360's repair list has 15 items; six of them are already existing sources in this plugin (startup items → `autorun`, services → `svc`, scheduled tasks → `task`, shortcut hijacks → `com` + `ifeo`, system time → `w32time`, Windows Update → `wuauserv` + `BITS`), and one (winsock reset) was already ruled out.

**The remaining eight are not "registration points" but "configuration drift"**: there is no object to enable or disable, only "what this setting is now" versus "what it should be". So they do not become switchable cards inside `SOURCES`; they get their own board, and every item walks the same three-stage pipeline:

```
assert (what this should look like)
  → detect (what it actually is now)
    → fix (how to put it back without loss)
```

- Probe: `lib/probes/repair.ps1` (always emits 8 rows; the row shape is identical to the featurelib family)
- Route: `POST /dsh-windows-toolbox/api/manage/repair`
- Tool: `wpm_repair`
- Frontend: the "System repair" strip at the top of the panel (parallel to the card area, not part of source grouping)

## Parameters

| Parameter | Values | Default | Meaning |
| --- | --- | --- | --- |
| `action` | `scan` \| `fix` | `scan` | `scan` is read-only; only `fix` reaches a write path |
| `dryRun` | `true` \| `false` | **`true`** | only `fix` + `dryRun=false` actually writes disk/registry |
| `ids` | `string[]` | all | process only these ids: `hosts` / `ie` / `dns` / `netconn` / `uac` / `redundant` / `fontcache` / `iconcache` |

Three hard constraints on the write path (inherited from the existing `actions.ps1` contract):

1. `dryRun` by default. Before any non-dry write, the whole key is exported via `reg export` to `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\`, and **if the backup fails the operation aborts** — never a half-written key.
2. Never `New-Item -Force` on an existing registry key (it recreates the key and discards every value and subkey). This probe only uses `Set-ItemProperty` / `Remove-ItemProperty` and **never creates keys**.
3. Writes that need administrator (HKLM) are reported as `skip` with the reason when unelevated, instead of a half-write.

## The eight checks

### 1. `hosts` — hosts file anomaly

| | |
| --- | --- |
| What is checked | the **non-comment, effective lines** of `C:\Windows\System32\drivers\etc\hosts`: the IP being pointed at and the redirected domain |
| How it is judged | a name outside the localhost family whose IP is `0.0.0.0` / `127.0.0.1` / `::1` / `::` → **blocked** (warn); an IP that is not loopback → **redirected** (bad); comments only or a user's own ordinary mapping → ok |
| Fix action | **lossless snapshot only**: copy the original file to `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\hosts.<stamp>.bak`. **Content is never modified** (hosts is a file operators and developers edit on purpose; automatic rewriting risks far more than it gains) |
| Needs admin | no (reads a file; the snapshot is written to the user's own directory) |
| Measured on this machine (2026-11-17) | `status=ok`, `value="0 effective / 824 B"`, detail: 0 effective entries, 0 blocked, 0 redirected |

### 2. `ie` — Internet Explorer settings tampered with

| | |
| --- | --- |
| What is checked | `HKCU\Software\Microsoft\Internet Explorer\Main`: `Start Page` / `Search Page` / `Default_Page_URL` / `Search Bar` / `Local Page` |
| How it is judged | `Start Page` equal to `about:blank` → normal; pointing at a non-Microsoft domain → **hijacked** (bad); any other drift → warn. `Search Page` / `Default_Page_URL` are judged the same way against the Microsoft domain set |
| Fix action | `Set-ItemProperty -Name 'Start Page' -Value 'about:blank'` (HKCU; `reg export` the whole key first, read back to verify afterwards) |
| Needs admin | no (HKCU) |
| Measured on this machine (2026-11-17) | `status=ok`, `value="24 values / Start=about:blank"`, `Search Page=http://go.microsoft.com/fwlink/?LinkId=54896` |

> Note: IE is retired, but old installers and bundleware still write to it — this is not a question of "is IE useful", it is evidence of "did someone change the default entry point of your browser".

### 3. `dns` — DNS settings anomaly

| | |
| --- | --- |
| What is checked | for each interface under `HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\*`: `NameServer` (static) and `DhcpNameServer` (DHCP-provided) |
| How it is judged | static DNS belonging to a common public resolver (`114.114.114.114`, `8.8.8.8`, `223.5.5.5`, `1.1.1.1`, …) or to a private range → ok; static and uncommon → warn. **No reachability probe** (no ping, no port-53 check); only the address is compared |
| Fix action | no automatic fix. `detail` gives the manual step: switch back to "obtain DNS automatically" (`Set-DnsClientServerAddress`, needs administrator) |
| Needs admin | yes |
| Measured on this machine (2026-11-17) | `status=ok`, `value="0 static / 8 interfaces"`, DHCP-provided DNS on 2 of them (WLAN `119.6.6.6 192.168.0.1`) |

> Why read the registry instead of calling `Get-DnsClientServerAddress`: the latter measured 378 ms here, `netsh interface ip show config` 97 ms, while reading the registry values of 8 interfaces is on the order of 25 ms. Same information, cheapest available measurement.

### 4. `netconn` — network connection limits

| | |
| --- | --- |
| What is checked | `TcpNumConnections` / `MaxUserPort` / `TcpTimedWaitDelay` / `MaxConnections` / `TcpMaxHalfOpen` / `TcpMaxHalfOpenRetried` under `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters` and `...\Tcpip6\Parameters` |
| How it is judged | **these values not existing is the normal case**. Existing means a "speed-up" style tool rewrote them → warn; a value outside a sane range → bad |
| Fix action | `Remove-ItemProperty` per value (**never `reg delete`**), `reg export` the whole key first. Unelevated → straight to skip |
| Needs admin | yes (HKLM) |
| Measured on this machine (2026-11-17) | `status=ok`, `value="0 rewritten connection limits"`, all six values unset |

### 5. `uac` — UAC settings

| | |
| --- | --- |
| What is checked | `EnableLUA` / `ConsentPromptBehaviorAdmin` / `PromptOnSecureDesktop` / `FilterAdministratorToken` under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` |
| How it is judged | `EnableLUA` unset or ≠ 1 → **bad** (UAC is off); `ConsentPromptBehaviorAdmin` `5` (default) or `2` (strictest) → normal, `0` → **bad**, anything else → warn; `PromptOnSecureDesktop=0` → warn. `FilterAdministratorToken` being `0` or unset is the Windows default (the built-in Administrator account is not filtered) and **is not drift** |
| Fix action | no automatic fix (takes effect only after sign-out/reboot, which belongs to "repairs that need a restart" and is out of scope here). `detail` states the value that should be written back |
| Needs admin | yes |
| Measured on this machine (2026-11-17) | `status=ok`, `value="EnableLUA=1 / ConsentPromptBehaviorAdmin=5"`, `PromptOnSecureDesktop=1`, `FilterAdministratorToken=unset` |

### 6. `redundant` — dead registry entries

| | |
| --- | --- |
| What is checked | in the five startup locations (`HKLM`/`HKCU` × `Run`/`RunOnce`, including `WOW6432Node`) and the three uninstall roots (`HKLM Uninstall`, `HKLM WOW6432Node Uninstall`, `HKCU Uninstall`), the entries **pointing at an executable that does not exist** |
| How it is judged | the executable is parsed out of the command line (quoted, unquoted-with-spaces, `DisplayIcon`'s `,0` icon-index suffix, `.ico` icon paths), then `Test-Path` decides existence. **Three-state**: exists → alive; definitely missing → dead; unmeasurable (ACL denial, bare filename that cannot be resolved) → **not judged dead** |
| Fix action | **only dead startup values are removed** (`reg export` the whole key first, `Remove-ItemProperty`, read back to verify). **Uninstall entries are reported, never deleted** — a broken uninstall entry does not stop the system from running, while deleting it can make "Programs and Features" lie |
| Needs admin | yes (the HKLM part) |
| Measured on this machine (2026-11-17) | `status=info`, `value="3 startup items (0 dead paths) / 130 uninstall entries (2 dead paths)"`, the two genuinely dead paths: `Bun -> C:\Users\26035\.bun\bin\bun.exe`, `夸克网盘 -> ...\Programs\QuarkCloudDrive\quark_cloud_drive.exe` |

> **Two real pitfalls were hit here, both fixed**:
> 1. `DisplayIcon`'s `.ico` path was treated as an executable and judged dead, producing 7 false positives (`Git`, `原神`, `Adobe Photoshop`, …). Any path ending in `.ico/.png/.bmp/.jpg/.gif/.svg` now falls back to `UninstallString` for the judgement.
> 2. `Test-Path` **throws `UnauthorizedAccessException` instead of returning `false`** for ACL-protected directories, and that was being read as "does not exist", causing a false positive on `Intel Package Cache`. It is now caught into `$null` (unmeasurable) and not judged dead.

### 7. `fontcache` — font cache

| | |
| --- | --- |
| What is checked | enumerability, total size and presence of `~FontCache-FontFace*.dat` conflict files in `C:\Windows\ServiceProfiles\LocalService\AppData\Local\FontCache`; plus `C:\Windows\System32\FNTCACHE.DAT` and the state of the `FontCache` service |
| How it is judged | directory unreadable → **skip** (with "needs administrator" spelled out, not "does not exist"); directory genuinely absent → warn; `~FontCache-FontFace*` present → bad |
| Fix action | no automatic fix (it would require stopping the `FontCache` service, which this board does not do). `detail` gives the manual steps |
| Needs admin | yes |
| Measured on this machine (2026-11-17) | `status=skip`, `value=""`, detail: `Access denied (UnauthorizedAccessException). The ACL on this directory only allows LocalService to read it; the current session is not elevated` |

> **Pitfall**: do not use `[System.IO.Directory]::Exists()` for this directory — on this machine it returns `False` for the ACL-protected directory, which would be misread as "directory does not exist". Use the try/catch of `Get-ChildItem -ErrorAction Stop` and branch on the exception type.

### 8. `iconcache` — icon cache

| | |
| --- | --- |
| What is checked | count, total size and number of zero-byte files among `*iconcache*` and `IconCache.db` under `%LOCALAPPDATA%\Microsoft\Windows\Explorer`; plus the size of `iconcache_idx.db` |
| How it is judged | **zero bytes is not corruption** — `iconcache_*.db` is lazily allocated, and 12 of the 15 files here are permanently 0 bytes, which is normal. Only `iconcache_idx.db` at 0 bytes, or `IconCache.db` existing at 0 bytes, → warn |
| Fix action | no automatic fix (it would require restarting `explorer.exe`). `detail` gives the manual steps |
| Needs admin | no (user directory) |
| Measured on this machine (2026-11-17) | `status=ok`, `value="15 files / 1031.5 KB / 0 zero-byte"`, `iconcache_idx.db = 7416 B` |

> An earlier measurement the same day read "15 files / 2055.3 KB / 11 zero-byte" — Explorer rewrites this batch while in use, so **these numbers change and that is normal**; the rule must not treat the zero-byte count as a hard indicator.

## Overall result on this machine (2026-11-17, unelevated pwsh 7)

```
action=scan  count=8
summary: { total: 8, ok: 6, warn: 0, bad: 0, info: 1, skip: 1 }
elevated: false
timings (three samples): hosts 13 / 13 / 13, ie 37 / 32 / 30, dns 23 / 23 / 18, netconn 48 / 50 / 47,
                         uac 17 / 18 / 17, redundant 215 / 236 / 211, fontcache 4 / 6 / 4, iconcache 12 / 13 / 9   // ms
whole run wall clock: 952 / 1041 / 939 ms
```

`redundant` is the only item above two hundred milliseconds (211–236 ms, 130 uninstall subkeys each `Test-Path`ed). The other seven together take under 160 ms. The sample spread comes from filesystem cache and Explorer jitter, not from a logic change.

With `action=fix&dryRun=true`, a line `| dryRun: ...` is appended to `detail`, explaining "what would have been done and where it was backed up". On this machine only `hosts` appends it (everything else was ok at the time, so there was nothing to fix).

The real write path was verified separately: create an `HKCU\...\Run` value pointing at a non-existent exe → `fix dryRun=true` reports warn "4 startup items (1 dead path)" → `fix dryRun=false` reports ok "removed 1 dead startup item" → reading the registry back confirms the value is gone and a `.reg` backup file exists.

## Why this is not an enable/disable source

`lib/sources.js` declares `repair` with `risk: readonly` and `actions: []`.

The reason: every row of the existing 11 sources is a **registration point** — a service, a scheduled task, a CLSID — which can be "enabled" or "disabled". Every row of this board is a **conclusion** ("hosts currently has 0 effective entries"); it has no enabled/disabled state, and faking one would only put two dead buttons in front of the user.

The real granularity of a repair is **the whole block** (write `Start Page` back to `about:blank`, remove a set of dead startup values), not "this row". So it has its own `POST /api/repair`, `dryRun` defaults to `true`, and the UI still requires "rehearse → confirm" in two steps.

## Related files

| File | Role |
| --- | --- |
| `lib/probes/repair.ps1` | the probe itself: 8 checks plus the write path for the fixable ones |
| `lib/probes/featurelib.ps1` | shared library (`Read-ProbeParams` / `New-ProbeList` / `Add-Item` / `Write-ProbeResult` / `Get-RegValue` / `Test-Elevated`) |
| `lib/sources.js` | the `repair` source declaration (`shape: 'items'`) |
| `lib/normalize.js` | the `items` envelope branch + row specialisation for `repair` |
| `lib/explain.js` | `SOURCE_KIND` for `repair` and the per-checkId WHERE table (zh/en pairs) |
| `index.js` | `POST /api/repair` route, the `wpm_repair` tool, `?lang=` explain recomputation |
| `client.js` | the "System repair" strip at the top of the panel |
