# 360 Toolbox (the toolbox tab of dsh-windows-toolbox)

Takes the parts of 360 Total Security that actually do real maintenance work and rebuilds them as **29 auditable, read-only-first capabilities** inside DSH. No drivers installed, no resident process, no popups, no scores we cannot justify.

**What it does not do**: no real-time blocking (there is no resident process, so no `SetWinEventHook`), no antivirus engine (no signature database, no malware scanning), no deleting system files (deletion only touches contents of a fixed whitelist of cache directories, and the directories themselves always survive).

Every reading below comes from actually running the probes on this machine (Windows 10 Pro 22H2 · 19045.7846 · 64-bit, PS7, **not elevated**, 31.8 GB RAM, 2 NVMe SSDs), captured 2026-11-17. Anything that could not be measured is reported as `skip`, never converted into a pass.

## Overview

| Dimension | Measured value |
| --- | --- |
| Capabilities | 29 (`CAPABILITIES.length` in `lib/capabilities.js`) |
| Groups | cleanup 6 / system 15 / network 2 / apps 6 |
| coverage spread | full 9 / partial 9 / readonly 7 / blocked 4 |
| Capabilities with a write action | 9 (junk clean; repair+dnspick for netdiag; apply for homepage / backup / softmgr / contextmenu / winsettings / tweaks / shredder) |
| Requiring admin | 1 (`tweaks`, and only when actually writing HKLM values) |
| Probes | 47 `.ps1` files in `lib/probes/` = 29 capability probes + 12 registration-point probes + featurelib / junklib / rootlib + actions / elevated / host |
| Panel views | 25 capabilities share `ChecksList`; junk=table, bigfiles=table, dupfiles=table, netdiag=step list |

### What the four coverage values mean

coverage describes how complete a capability is. It is not a score and it says nothing about risk.

- **full (9)**: the capability does its whole job within our scope. Either it reads the complete data set, or its write path is wired up (with dry run and backup). The only missing pieces are things Windows itself forbids, which are listed under Known limits.
- **partial (9)**: only part of the job is done, and the missing part is stated per row in the table below. The common pattern: detection is complete, the action side (block, download, move, repair, auto-install) is not wired, or wiring it would not reach what 360 does.
- **readonly (7)**: detect, conclude, present evidence, **no repair button**. Either the repair needs admin (`sfc` / `DISM` / `pnputil` / `Set-Service`), or the repair is harmful (flipping every privacy toggle off also breaks the applications that need them).
- **blocked (4)**: the machine's condition does not allow it, and the capability itself reports what is in the way. All four are hard constraints: C: cannot grow because a 608 MB recovery partition sits right behind it (32.5 KB gap), deleted-file recovery is defeated by SSD + TRIM, reinstalling requires rebooting into another environment, and firmware-level BadUSB cannot be defended from inside the OS.

## The 25 capabilities

The "measured here" column is this round's raw sample; timings include PowerShell startup and WMI queries.

### Cleanup and space (cleanup, 6)

| Capability | coverage | actions | Admin | Measured here |
| --- | --- | --- | --- | --- |
| Junk cleanup (junk) | full | scan+clean | no | 9 groups / 31 targets, 17200 files / 2.01 GB, 4 targets skipped for lack of admin |
| Large files (bigfiles) | full | scan | no | root=user profile, 197703 files / 44.9 GB, 49 hits >=100 MB, 8282 ms |
| Duplicate files (dupfiles) | full | scan | no | root=Downloads, 3032 files, 44 fully hashed, 22 groups, 63.6 MB reclaimable, 458 ms |
| Slim system drive (slim) | readonly | scan | no | C: 165.19 / 302.03 GB free (54.7%); pagefile 48.83 GB; no hiberfil; no Windows.old; 13 items in 4648 ms |
| Expand C: (expandc) | blocked | scan | no | C: ends at 324420992512, recovery partition starts at 324421025792 — a 32.5 KB gap; largest contiguous free space on either disk is 1.0 MB |
| File shredder (shredder) | partial | scan+apply | no | 2 SSDs / 0 HDDs, TRIM on (DisableDeleteNotify=0) -> the result states overwrite shredding is ineffective on SSD |
#### The 9 groups and 31 targets

A group id may only be one of these nine (`JUNK_GROUPS` in `lib/capabilities.js`; `lib/probes/junklib.ps1` is the only place a target is defined, and a test asserts the two counts agree).

| Group | Name | Targets | How it is handled |
| --- | --- | --- | --- |
| temp | Temporary files | user-temp / windows-temp / crash-dumps / wer-report | Temporary copies made while programs run; deleting them does not disturb installed software |
| browser | Browser caches | edge-cache / edge-code-cache / chrome-cache / chrome-code-cache / inet-cache | Web and compiled caches; the first page load after a clean is slightly slower, and you are not logged out |
| system | System caches | thumb-cache / icon-cache / prefetch / dns-cache | Thumbnail/icon caches and prefetch files, rebuilt automatically; anything in use is skipped |
| update | Update caches | wu-download / delivery-opt | Downloaded copies of already-installed updates; removing them does not change the OS build; needs admin |
| recycle | Recycle bin | recycle-bin | Cannot be undone through the recycle bin; confirm before running |
| privacy | Cookies | edge-cookies / chrome-cookies / inet-cookies | Sites will ask you to sign in again; when the browser is running the files are locked and are reported as skipped, never as cleaned |
| traces | Usage traces | recent-lnk / recent-auto / recent-custom / ps-history | Recently opened files, taskbar jump lists, shell history; installed software is unaffected |
| registry | Registry leftovers | typed-paths / run-mru / uninstall-shells / binary-mru / mui-cache / app-paths / firewall-rules | Only entries whose pointed-to path no longer exists. Each removal is backed up to regbackup and can be rolled back alone; empty uninstall shells, binary MRU and firewall rules are detect-only; App Paths subkeys with an empty default value are skipped |
| plugins | Browser extensions | browser-extensions | Detect only: how many extensions are installed and where they came from. Uninstalling is risky - do it in the browser's own extensions page |

The first five groups map to `sysclean` in 360's `sweeper/okctree.xml`. The last four are our own implementation of 360's other four top-level categories (`privacyclean` / `traceclean` / `register` / `pluginclean`); `plugins` stops at detection because 360's plugin catalogue lives on its servers and nothing reuseable ships locally.

### System and security (system, 15)

| Capability | coverage | actions | Admin | Measured here |
| --- | --- | --- | --- | --- |
| Health check (health) | full | scan | no | 11 items ok8 / warn3 / bad0, 4207 ms; pagefile 48.8 GB against 31.8 GB RAM |
| Task manager (proc) | full | scan | no | 19 items; 208 processes, 30.4% CPU, 36.4% memory; top consumer is pwsh itself at 8.8%; 1.52 s sampling window |
| Disk health (diskhealth) | partial | scan | no | 7 items ok5 / skip2; both NVMe drives Healthy; SMART detail and failure prediction both skip (reasons below) |
| System security (security) | readonly | scan | no | 24 items ok13 / warn6 / info5; SMB signing not required, LLMNR unset, LSA protection unset |
| Privacy guard (privacy) | readonly | scan | no | 34 items; 29 permission classes / 45 app-level entries; location globally denied, telemetry unset |
| App permissions (perm) | readonly | scan | no | 33 items; 29 permission classes / 46 app-level records; 3 bad (camera and sound recorder hold microphone) |
| BadUSB guard (amiba) | blocked | scan | no | 30 items ok7 / warn12 / info11; "1 on, 4 unconfigured"; firmware-level BadUSB explicitly declared unsolvable |
| Popup sources (popup) | partial | scan | no | 17 items; 5 visible windows; 17 of 32 notification apps already off; focus assist unreadable -> skip |
| Homepage guard (homepage) | full | scan+apply | no | 0 of 95 .lnk files carry an appended URL; IE home about:blank; default browser Edge |
| Deleted file recovery (recovery) | blocked | scan | no | TRIM on, 2 NVMe SSDs; shadow copies unreadable without admin -> recovery odds near zero |
| System rescue (rescue) | readonly | scan | no | 12 items ok5 / warn3 / skip2; sfc and DISM skip honestly when not elevated |
| Backup / restore (backup) | partial | scan+apply | no | 0 restore points, VSS stopped; 16 .reg files already exported |
| Reinstall readiness (reinstall) | blocked | scan | no | 11 items; WinRE and BitLocker need admin -> skip; the reinstall itself is not performed by the plugin |
| Windows settings (winsettings) | partial | scan+apply | no | 38 items ok21 / info16 / skip1; dark mode, extensions, hidden files read correctly |
| Tweak presets (tweaks) | partial | scan+apply | **yes** (HKLM writes) | 51 items ok5 / warn46 (46 not applied), 1175 ms |

### Network (network, 2)

| Capability | coverage | actions | Admin | Measured here |
| --- | --- | --- | --- | --- |
| Network diagnosis (netdiag) | full | scan+repair+dnspick | no (resets do) | 10 scan rows, all pass: WLAN up, 192.168.0.105, gateway 192.168.0.1, gateway ping 1043 ms, DNS 20 ms, internet HTTP 200 / 605 ms, proxy off, 0 hosts entries, 3701 ms |
| Speed test (speedtest) | full | scan | no | download 1.78 Mbps, upload 2.77 Mbps, latency 358 ms (warn), 3/3 endpoints available, 40.2 s against a 45 s budget |

### Apps and shell (apps, 6)

| Capability | coverage | actions | Admin | Measured here |
| --- | --- | --- | --- | --- |
| Software manager (software) | partial | scan | no | 114 installed entries; 11 of the 198 catalogue entries installed, 187 not |
| Software deep clean (softmgr) | partial | scan+apply | no | winget v1.29.380, 13 upgradable; 542 firewall rules; dryRun defaults to true |
| Driver inventory (drivers) | readonly | scan | no | 250 driver packages, 16 third-party oem*.inf (NVIDIA, Intel x6, Micro-Star, Logitech x2) |
| Driver update check (drivers2) | partial | scan | no | 0 devices missing drivers; 168 signed driver records deduplicated to 106, 10 third-party older than 730 days |
| Context menu (contextmenu) | full | scan+apply | no | 78 items ok10 / info68; 12 shellex registration points |
| Phone link (phone) | readonly | scan | no | Phone Link 1.25072.81.0 installed; all 4 portable-device records "not connected (history)"; verdict "no phone connected" |

Why some of these are only partial or readonly:

- **Software manager partial**: the catalogue and the official links are complete (198 entries), but install/upgrade/uninstall **is not wired**. It prints the command and lets the user run it, because a silent install is an irreversible write.
- **Software deep clean partial**: uninstall leftovers are scanned and moving feasibility is analysed; the move itself is not performed. Moving a directory that is still referenced destroys the installed program, and the symlink workaround is unreliable across volumes on Windows.
- **Driver update check partial**: Windows has no local database of vendor-latest versions, so this capability **never claims to have found a new version**. It reports missing drivers and drivers with old dates, plus vendor homepages. Nine `DriverDate` values are placeholder stamps (1989 or earlier) and are excluded from sorting.
- **Task manager full**: it does the same job as 360's task manager - find what is consuming the machine right now. CPU percentages come from the delta between two samples (reading `Get-Process`'s cumulative CPU property would answer "average since boot", which is not what the user feels), with the Idle process excluded. The pwsh row at the top is usually the probe itself; the measurement says so instead of hiding it.
- **Disk health partial**: controller health, capacity, partition table and drive letters are all read for both NVMe drives. The two SMART routes fail for **completely different reasons**, so they are reported as two separate skips: `Get-StorageReliabilityCounter` throws `CimException` (`NativeErrorCode=AccessDenied`, HResult=0x80070005) - a permission problem that elevation fixes; `MSStorageDriver_FailurePredictStatus` exists as a class but has **0 instances** - that WMI only enumerates ATA/SATA, so the NVMe hardware channel never exposes it and elevation changes nothing. Every SMART field is null; nothing is filled with 0 to look populated.
- **System security readonly**: it reports the raw registry and WMI values against a baseline and points out where they differ. Forcing SMB signing on would disconnect old NAS boxes and shared printers, and that trade-off is the user's to make.
- **App permissions readonly**: its value is exposing "the door is open", e.g. camera permission enabled globally while no app has used it. Which app to cut off is a user decision.
- **BadUSB guard blocked**: the name is inherited from 360, but what it actually covers is USB device installation policy, removable-storage policy and lateral-movement surface. A BadUSB device enumerates as a keyboard with rewritable firmware, so every OS-level policy runs behind it; the verdict says out loud that only the physical layer solves it. On this machine 4 of the key policies are unconfigured.
- **Backup / restore partial**: the registry path is complete (auto `reg export` before writing, `reg import` to roll back). Restore points are out of reach: this machine has 0 restore points, VSS stopped, and creating a point needs admin.
- **Reinstall readiness blocked**: reinstalling reboots into another environment and the plugin has no lifecycle hook there. The pre-flight checks are complete, but WinRE state and BitLocker state both need admin, so both are skip here.
- **Tweak presets partial**: only the two change classes are kept (registry values and service start types). Upstream winutil's 27 arbitrary PowerShell scripts are dropped — that is unauditable arbitrary execution.
- **Slim system drive readonly**: measuring only is correct. The 48.83 GB pagefile (52428800000 bytes) can be moved but not deleted, and disabling hibernation needs admin; a "free 48 GB" button would destroy hibernation and crash dumps.
- **Network diagnosis full** refers to the diagnosis: it reports the first broken hop in link order. Auto-repair (winsock reset, DNS flush) is not wired, because those are writes that also interrupt the current connection.
- **Speed test 1.78 Mbps** is this round's real sample. Two rounds on the same network can differ by several times, so the result always states which endpoint was used and whether it fell back. 358 ms latency is flagged warn.
- **Phone link readonly**: it can read Phone Link's install state, portable-device history, and the WPD/MTP driver stack. File management, screen mirroring and SMS need a phone-side app and a resident connection, so they are out.

## The 22-item 360 feature comparison

This is the core of the document. **Anything we cannot do says so and says why**, rather than being rounded up to "partially supported".

| # | 360 feature | Our capability | What we do | What we cannot do, and why |
| --- | --- | --- | --- | --- |
| 1 | Popup blocking | popup (partial) | Count visible windows, spot off-screen ones, trace popups to scheduled tasks and installed software, summarise notification switches for 32 apps | **Real-time blocking is impossible.** It needs a resident process hooking `SetWinEventHook` on `EVENT_OBJECT_CREATE` / `EVENT_OBJECT_SHOW`; this DSH plugin is session-scoped and unloadable at any time. This machine has 5 visible windows and 17 of 32 notification apps already off — we can say which to switch off, the switching is manual |
| 2 | Permission management | perm (readonly) | List all 29 permission classes / 46 app-level records, locate which app holds the camera, and expose "door open, nobody walked in" situations | No one-click disable. Cutting an app off the microphone also destroys its voice features; the trade-off is the user's. Real changes go through Settings |
| 3 | Homepage protection | homepage (full) | Read IE start/search pages, policy locks, Edge/Chrome startup pages, and 95 .lnk target lines for appended URLs; write back when hijacked, dry run by default | Covers IE / Edge / Chrome only. Other browsers (360 Browser, Firefox, Brave) have different startup-page mechanisms and are not wired. Here 0 of 95 shortcuts were hijacked and Chrome is not installed |
| 4 | Amoeba protection | amiba (blocked) | Read USB device installation restrictions, removable-storage policy, and lateral-movement surface (SMB, remote registry, WinRM, RDP) | **Detecting the malware is impossible.** 360's "amoeba" is self-mutating malware that evades signatures; stopping it needs a kernel driver, a live signature feed and behavioural monitoring. This capability covers the firmware and policy layer only, and 4 key policies are unconfigured here |
| 5 | System security | security (readonly) | UAC, Defender (real-time / tamper / PUA / controlled folders / ASR), SMBv1 and signing, RDP, autoplay, LSA protection, execution policy — 24 items with raw registry values | Changes nothing. Forcing SMB signing or enabling LLMNR restrictions would disconnect old devices, so the cost is written into the conclusion and the user decides |
| 6 | Phone assistant | phone (readonly) | Phone Link install state, paired and historical devices, WPD/MTP driver stack, USB and portable-device service state | **Everything phone-side is out**: file management, screen mirroring, SMS, phone cleanup all need a phone app plus a resident link. All 4 portable-device records here are history; no phone is connected |
| 7 | Software manager | software + softmgr (partial) | 198-entry official-link catalogue across 11 categories, matching against 114 installed programs, winget's local upgradable list (13), uninstall-leftover evidence, 542 firewall rules | **No install, no uninstall, no moving.** Installs/upgrades print a command; moving only gets a feasibility analysis (target free space, holders, link points) because moving destroys installed programs |
| 8 | Privacy guard | privacy (readonly) | Telemetry, advertising ID, location, activity history, 29 permission classes and 45 app-level entries | Report only. Most of the 30 warns here are "permission is globally on"; switching each off breaks legitimate features of paid software |
| 9 | Homepage repair | homepage apply side (full) | Write back the original value when a hijack is found, **dry run by default**, auto `reg export` backup beforehand, abort if backup fails | Repairs only the registry and shortcut classes of hijack. Browser-synced startup pages, extension-level hijacks and DNS-level hijacks are out of scope |
| 10 | File shredder | shredder (partial) | Overwrite-then-delete for explicitly passed single files; rejects wildcards, never recurses, refuses system directories and executable extensions, refuses hard links and reparse points | **Ineffective on SSD.** Both disks here are SSD with TRIM on (`DisableDeleteNotify=0`), so the controller remaps overwritten blocks and the old physical blocks wait for GC. The result says this outright and never claims guaranteed destruction. The real answer is full-disk encryption |
| 11 | Deleted file recovery | recovery (blocked) | Decide whether recovery is even possible: TRIM state, media type, volume health, shadow copy and restore point state, recycle bin remnants | **Recovery is impossible and should not be attempted.** 2 NVMe SSDs with TRIM on means deleted files are marked reclaimable and the physical blocks are eventually erased; real odds are near zero. A "one-click recover" button would only deceive the user into writing more data and destroying the last chance |
| 12 | Offline first aid | netdiag (full) | 10-hop link-order diagnosis of the first break: NIC -> IP -> gateway -> DNS -> internet -> proxy -> hosts, plus a Wi-Fi check (signal, band, tx/rx rate) and a DNS picker that measures 7 candidates; `repair` offers 7 actions (flushdns / renew-dhcp / reset-winsock / reset-tcpip / reset-proxy / reset-ie-proxy / restart-adapter) and `dnspick` switches the resolver | Three of the seven repairs need no admin and one was really executed here (flushdns: cache 67 -> 4 entries, exit 0, 59 ms); the other four need admin and **could not be elevated on this machine, so they are verified only up to "skip with the exact command"**. reset-winsock and reset-tcpip also need a reboot to take full effect, which is why nothing restarts the machine for you. The DNS switch accepts only five resolvers measured reachable here, or auto, and backs up the old value with a rollback command |
| 13 | Broadband speed test | speedtest (full) | Download / upload / latency / jitter across 3 HTTP endpoints, first success wins, result within 40 s | No speed-test component is installed, pure HTTP; single samples vary, so endpoints and fallback state are always reported. Here: 1.78 Mbps down, 2.77 Mbps up, 358 ms latency |
| 14 | System drive slimming | slim (readonly) | Break down pagefile / hibernation / Windows.old / update cache / AppData usage, 13 items | **No slimming performed.** The 48.83 GB pagefile can be moved but not deleted (and moving needs a reboot); disabling hibernation needs admin; WinSxS is not enumerated (88982 files / 11.5 GB takes 15.2 s) and instead points at `DISM /Online /Cleanup-Image /AnalyzeComponentStore` |
| 15 | System rescue box | rescue (readonly) | Pending-reboot flag, component store package count, restore point count, 24 h system errors, latest update, signature age, device health, missing startup entries | **No auto-repair**, and the core repair tools need admin: here `sfc` exits 1 and `DISM` exits 740 (both permission denials) and are reported as skip. Running them for real needs elevation and DISM occupies the system for a long time |
| 16 | Expand C: | expandc (blocked) | Full disk geometry: partition start/end bytes, adjacent objects, unallocated space, recovery partition position, cost analysis | **Cannot expand on this machine.** C: ends at 324420992512 and the 608 MB recovery partition starts at 324421025792 — a 32.5 KB alignment gap. Disk Management only consumes unallocated space immediately adjacent at the tail; it cannot expand across a partition, and deleting the recovery partition breaks WinRE. Largest contiguous free space on either disk is 1.0 MB |
| 17 | Large / duplicate file finder | bigfiles + dupfiles (full) | Large files: recursive threshold scan (197703 files / 44.9 GB, 49 hits here). Duplicates: three-stage funnel (size groups -> first 64 KiB -> full SHA256; 22 groups / 63.6 MB here) | **Report only, never delete.** Deletion is irreversible and a human should look at the path first |
| 18 | System reinstall | reinstall (blocked) | Pre-flight: recovery partition, BitLocker, Windows.old, machine type, accounts, storage controllers, NICs, power plan | **The reinstall itself is impossible.** It requires rebooting into WinPE and writing the disk; the plugin has no lifecycle there. WinRE state and BitLocker state both need admin here, so both are skip |
| 19 | Backup and restore | backup (partial) | Export registry keys to `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup` (16 .reg files here) and `reg import` them back; dry run by default | **System-level backup and restore is out.** This machine has 0 restore points with VSS/SDRSVC/swprv all stopped, and creating a point needs admin; image backup (wbadmin) also needs elevation and a separate volume. What we protect is "the handful of keys we changed" |
| 20 | Driver installation | drivers + drivers2 (readonly / partial) | Inventory of 250 driver packages and 16 third-party oem*.inf, devices missing drivers (0 here), drivers older than 730 days (10 third-party here), vendor homepage entry points | **No auto-download, no auto-install.** Windows has no local vendor-latest database, so "is there a newer version" cannot be answered; installing needs `pnputil /add-driver` (admin) or Device Manager, and neither belongs in a read-only plugin |
| 21 | Context menu manager | contextmenu (full) | Enumerate 12 shellex registration points and 78 current items, enable/block per item; HKCU is writable without elevation | Blocking relies on the empty-string convention in `Shell Extensions\Approved` (value present and empty = blocked; deleting the value does not disable). HKLM-scoped entries need admin |
| 22 | Windows settings | winsettings (partial) | Read 38 common settings and write back HKCU items: dark mode, file extensions, hidden files, taskbar, 24-hour clock, etc. | HKLM items are not written (needs admin); Win11-only items honestly report "not set = system default" on Win10; a DWORD sent as a string "writes but does not take effect", so such requests are rejected outright |

### One-line summary

- **Complete (full)**: junk cleanup, large files, duplicate files, network diagnosis, speed test, health check, task manager, homepage guard, context menu.
- **Partial**: popup sources, backup/restore, software manager, software deep clean, driver update check, disk health, Windows settings, tweak presets, file shredder.
- **Detect only (readonly)**: system security, privacy guard, app permissions, system drive slimming, system rescue, driver inventory, phone link.
- **Blocked by this machine**: BadUSB guard, expand C:, deleted file recovery, reinstall readiness.
- **Genuinely out of scope, admitted in writing**: real-time popup blocking, amoeba malware detection, everything phone-side, deleted-file recovery, growing C:, performing the reinstall, sfc/DISM repair (needs admin), moving installed software, driver auto-install, system-level backup. Network reset and the DNS switch *are* wired, but the three admin-only reset actions were never executed on a real machine here.

## Three design rules

### Rule 1: read-only first

16 of the 25 capabilities are pure `scan`: they read the registry, WMI, event logs and the filesystem and change no state. The 9 with write actions must clear the next two rules.

Read-only is not caution for its own sake; for these capabilities the conclusion is the product. `netdiag` tells the user which hop is broken, `security` tells them which baseline is unmet, and the user has their own way of acting on it. Automatic repair, by contrast, has no rollback path once it repairs the wrong thing.

### Rule 2: writes are dry run by default and always backed up

- Every apply entry point defaults to `dryRun = true`. The `softmgr` probe output carries `dryRun: true` literally.
- The panel is a **two-step confirmation**: the host runs the dry run first and lays out "which key changes, from what to what"; only after the user confirms does it execute with `dryRun=false`. `deriveApplyParams` in `client.js` turns a row into apply parameters.
- Before a real write it does `reg export` into `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup`, and **aborts the whole action if the backup fails**. 16 .reg files are already there.
- `contextmenu` blocks via the empty-string convention in `Shell Extensions\Approved` rather than deleting the value: deleting means "undeclared", and then the shell decides on its own, unpredictably.

### Rule 3: never fabricate; skip when it cannot be measured

- Without elevation, `sfc` / `DISM` / shadow copies / WinRE / BitLocker all emit `status: "skip"` with a stated reason and are **never converted into ok**. Here: `rescue` 2 skips, `reinstall` 2 skips, `recovery` 1, `slim` 1, `backup` 1, `winsettings` 1.
- Unreadable items are marked info and say they are unreadable. `popup`'s focus-assist state lives in a CloudStore blob (116 bytes, undocumented format) and the probe says "does not parse undocumented formats and does not guess" rather than inventing a value.
- `drivers2` states "no local database of newer versions", so it never claims to have detected an update.
- `Runner.run()` never throws: a crashed probe writes an error into that one slot and the other capabilities still report. One failure must not take down the panel.

## Software catalogue policy: official links only

`lib/presets/softwares.json` holds **198 entries across 11 categories**, every one on the vendor's own domain.

| Category | Entries | Category | Entries |
| --- | --- | --- | --- |
| im | 11 | office | 18 |
| browser | 13 | input | 10 |
| media | 30 | graphics | 12 |
| dev | 25 | utility | 25 |
| system | 21 | security | 13 |
| network | 20 | | |

Top-level fields: `version: 1`, `captured: "2026-11-17"`, `policy: "official-only"`, `policyNote`, `note`, `categories`, `softwares`.

### The enforcer

`tools/verify-catalog.mjs` is a gate, not advice. For both URLs per entry (`homepage` / `downloadPage`) it checks:

1. It is `https:` and parses with `new URL()`.
2. The host does not hit `FORBIDDEN_HOSTS`: softonic.com, filehippo.com, cnet.com, download.com, softpedia.com and similar portals.
3. The host does not hit `FORBIDDEN_EXACT_HOSTS` (shorteners: is.gd, buff.ly, rb.gy, cutt.ly, shorturl.at...). **Host equality is mandatory** — substring matching was a real bug: `https://www.capcut.cn/` was flagged as a shortener because it contains `t.cn`, and conversely `evil-t.cn` must not pass.
4. The host is not a bare IP (`/^\d+\.\d+\.\d+\.\d+$/`).
5. The path contains no `/s?`, `/link?`, `/redirect`, `mydown`, `/softdown`, `/download.php?id=`.
6. `github.com/<org>` is not a violation but only a WARN requiring a human to confirm the publisher is the upstream author (all 14 warns here are this class).

`--offline` runs shape and policy only; without the flag it also probes reachability.

### Where 198 comes from

`lib/presets/` holds one base plus three shards: `softwares.json` (base) + `softwares-A.json` (35 rows) + `softwares-B.json` (44 rows) + `softwares-C.json` (48 rows). `node tools/merge-catalog.mjs --dry-run` this round:

```
base entries      : 198
shard A           : 35 rows, 35 accepted
shard B           : 44 rows, 44 accepted
shard C           : 48 rows, 48 accepted
added             : 0
replaced (by id)  : 127
total             : 198
categories        : 11
VERDICT: PASS
```

So the shards **override 127 existing base entries by id**; they do not append into an empty catalogue (`added 0`). That matches how the work is actually done: a shard is "the entries revised this round", merge writes them back into the base, and `total` stays 198.

### Adding an entry

1. Add it to any of `softwares-A.json` / `B` / `C` with the same fields as a base entry (`id`, both URLs, ...). Which shard holds it does not affect the result; a shard is just a pending revision set.
2. `node tools/merge-catalog.mjs` (run `--dry-run` first and check `accepted` / `replaced`, then drop the flag to write `softwares.json`).
3. `node tools/verify-catalog.mjs --offline` must PASS with no new non-github warns.
4. For reachability, rerun without `--offline`.

Only entries that can be confirmed as official domains get in. One entry fewer beats a link that bounces to a download portal.

### Driver and tweak presets

- `lib/presets/drivers.json`: 20 vendors + 10 USB vendors + 15 classes, `captured: "2026-11-17"`. Vendor keys are PCI vendor ids (1002 / 1022 / 1028 ...), validated by `tools/verify-drivers.mjs` (`--offline` passes here).
- `lib/presets/tweaks.json`: 51 entries, sourced from ChrisTitusTech/winutil, MIT, `captured: "2026-11-17"`. Only registry values and service start types are kept; upstream's 27 arbitrary PowerShell scripts are dropped.

## Directory layout

```
dsh-windows-toolbox/  (one directory, two halves; this file covers the toolbox half)
├─ index.js              host side: 5 HTTP routes + 4 tools + capability exports (21530 B)
├─ client.js             panel: group tabs, capability cards, 5 views, two-step confirm (1424 lines)
├─ package.json          link-install entry, dsh.client.immediately = true
├─ cordis.patch.yml      client injection declaration
├─ icon.svg              panel icon
├─ README.md             quick tour
├─ docs/
│  ├─ DETAIL.zh.md       Chinese version
│  └─ DETAIL.md          this file
├─ lib/
│  ├─ capabilities.js    single source of truth for the 29 (CAPABILITIES / CAPABILITY_GROUPS / COVERAGE / RISK / JUNK_GROUPS / SCAN_ROOTS)
│  ├─ runner.js          cache and concurrency: 5 min TTL, run() never throws, param allowlist
│  ├─ ps.js              probe invocation: -ParamFile params, UTF-8 parsing, 120 s default timeout
│  ├─ probes/            47 .ps1 = 29 capability probes + 12 registration-point probes + featurelib/junklib/rootlib + actions/elevated/host, plus CONTRACT.md
│  └─ presets/           softwares.json (198) + softwares-A|B|C.json + drivers.json + tweaks.json
├─ locale/               zh.json / en.json (panel title and description only; the glossary lives in client.js)
├─ tests/
│  ├─ run-all.mjs        unit + live, 36 cases
│  └─ render.mjs         server-renders the panel and validates copy and fetch calls
└─ tools/
   ├─ verify-catalog.mjs  the official-links-only enforcer
   ├─ verify-drivers.mjs  driver preset validator
   ├─ merge-catalog.mjs   merges shards back into the base
   ├─ audit-probes.mjs    objective probe audit (syntax, banned APIs, UTF-8 header, param position)
   └─ probe-shapes.mjs    probe input/output shape snapshot
```

Host routes (prefix `/dsh-windows-toolbox/api/toolbox`): `GET /status`, `GET /result?id=`, `POST /run`, `POST /apply`, `POST /elevated`, `POST /clean`.
Tools: `tb360_status`, `tb360_scan`, `tb360_apply`, `tb360_clean`.

## Pitfalls we actually hit

Each one reproduced on a real machine and is already fixed. Symptom -> root cause -> fix.

1. **Caller receives a bare array and `.Count` counts elements one at a time**
   Symptom: a function returning 4 items yields `.Count` of 4 ones instead of 1 four.
   Cause: PowerShell's `return $list` enumerates a `List[object]`, so the pipeline emits 4 objects.
   Fix: `return , $list` — the comma stops the enumeration.

2. **Parameters silently do not bind; `$DryRun` keeps its default**
   Symptom: passing `-DryRun $false` has no effect and nothing errors.
   Cause: `param()` must be the first statement in the script. Putting the `[Console]::OutputEncoding = ...` line before it makes `param` a command name and the whole block inert.
   Fix: `param()` first, the UTF-8 line after it.

3. **Node receives mojibake and JSON.parse dies at the first Chinese character**
   Symptom: Chinese arrives as `���` and `parseJson` throws SyntaxError.
   Cause: PowerShell writes in the console code page (936) while Node decodes UTF-8.
   Fix: every .ps1 sets `[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false` (`$false` = no BOM, and a BOM breaks JSON.parse too).

4. **`Sort-Object -Property bytes` silently sorts nothing**
   Symptom: the large-file table is in random order with no error.
   Cause: rows are `OrderedDictionary`, and `-Property <key>` on a dictionary row is a silent no-op.
   Fix: `Sort-Object { [int64]$_.bytes } -Descending`.

5. **`Measure-Object -Property bytes -Sum` returns nothing**
   Symptom: the total is empty and serialises to `null`.
   Cause: same as above — dictionary rows do not accept property names.
   Fix: accumulate in a `foreach`, or `($rows | Measure-Object { [int64]$_.bytes } -Sum)`.

6. **387 ms spent probing a registry key that does not exist**
   Symptom: one "is this even configured" item slows the whole sweep.
   Cause: `Test-Path` on a nonexistent key costs 387 ms per call (full path resolution plus permission check).
   Fix: read with `Get-RegValue` (~10 ms) — absent means unconfigured. The filesystem `Test-Path` costs only 1.6 ms, so it stays.

7. **Hard-coding `$env:USERPROFILE\Documents` yields a false zero**
   Symptom: the Documents folder reports 0 files while it actually holds tens of GB.
   Cause: known folders get redirected. Here Documents -> E:, Downloads -> E:, Desktop -> D:, Pictures -> D:; the shell folders under the profile are empty.
   Fix: read `User Shell Folders` from the registry and fall back to the default path only if absent.

8. **`Get-WinEvent` throws when no event matches**
   Symptom: a 24 h error count of zero is reported as a read failure.
   Cause: no matches raises `NoMatchingEventsFoundException` instead of returning an empty collection.
   Fix: catch that specific exception as 0 and treat anything else as a real failure.

9. **A single-endpoint HTTP probe lies**
   Symptom: the same endpoint passes in 527 ms one round and times out at 6 s the next; the verdict flips.
   Cause: one slow endpoint or one burst of congestion decides everything.
   Fix: multiple endpoints with ordered fallback, **first success wins**, and report which endpoint was used and how many fallbacks happened.

10. **A disconnected NIC is judged as "no IP"**
    Symptom: the NICs are fine but the report claims an IP problem.
    Cause: a disconnected NIC carries a `169.254.x.x` APIPA address that was being counted as a valid IP. This machine's Bluetooth NIC holds `169.254.127.184`.
    Fix: filter by `Status` first and run the APIPA check only on `Up` adapters.

11. **"Tightest disk" pointed at the one with 937 GB free**
    Symptom: the health check flagged E: as the tightest disk while it had 937.1 GB left.
    Cause: choosing by used%. E: is a 1907.7 GB volume, so 50.9% used sounds high, but its absolute free space dwarfs C:'s 165.2 GB.
    Fix: grade against each disk's own capacity and always report absolute free space, never the percentage alone.

12. **`New-Item -Force` wipes an existing registry key**
    Symptom: writing one value erases every existing subkey and value under that key.
    Cause: `New-Item -Force` is recreate semantics on an existing key.
    Fix: check with `Get-Item` (or `Test-Path`) and only create when absent.

13. **Assigning to `$HOME` / `$pid` / `$args` fails silently**
    Symptom: the script assigns a value and later reads the original or nothing.
    Cause: these are read-only automatic variables; under `-ErrorAction SilentlyContinue` the assignment fails without a message.
    Fix: rename (`$profileHome`, `$procId`, `$scriptArgs`) and add these names to the banned list that `audit-probes.mjs` checks.

14. **`@($list)` throws `Argument types do not match` on PS7.6**
    Symptom: wrapping a `New-Object List[object]` in an array raises a type error.
    Cause: PS7.6 hits a type-binding problem when array-converting a List built with `New-Object`.
    Fix: build with `[System.Collections.Generic.List[object]]::new()`.

15. **`reg.exe` prints a success message to stdout and corrupts the JSON**
    Symptom: a line reading "The operation completed successfully." (localised) appears before the JSON and parsing fails.
    Cause: `reg.exe` writes a localised confirmation to stdout on success.
    Fix: redirect to a temp file (`reg ... > $tmpFile 2>&1`) and read from it, or discard output entirely and judge by exit code.

16. **`[Parser]` is not a valid type name and silently returns `$null`**
    Symptom: the syntax check passes everything, including broken scripts.
    Cause: `[Parser]` is not a usable alias, so PowerShell treats it as a string / `$null` and `ParseFile` never runs.
    Fix: use the full name `[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)`.

17. **The banned-API scan flags suggestion text inside `-Fix` strings**
    Symptom: a `Set-Service` that only appears in help text is reported as a real call.
    Cause: the regex ran over raw text, so comments and string literals matched too.
    Fix: strip comments and string literals first (tokenise, then compare) and inspect only genuine command tokens.

## Privilege boundary: what works without elevation

Everything here was measured while unelevated.

| Operation | Unelevated | Note |
| --- | --- | --- |
| Read HKLM / HKCR | yes | read-only enumeration works |
| Read and write HKCU | **yes** | this is why `contextmenu`, `winsettings` HKCU items and `tweaks` HKCU items can really write |
| Write HKLM | no | needs admin; `tweaks` is marked `needsAdmin` for this |
| `reg export` / `reg import` | yes | the backup path needs no elevation; all 14 .reg files were exported unelevated |
| `Get-Service` / read service state | yes | |
| `Set-Service` / change service start type | no | needs admin |
| `Disable-ScheduledTask` | no | needs admin; scheduled tasks are read-only here (360ZipUpd x2 found already Disabled) |
| `pnputil /add-driver`, removing driver packages | no | needs admin |
| `sfc /scannow` | no | exits 1 here, probe reports skip |
| `DISM /Online /Cleanup-Image` | no | exits 740 here, probe reports skip |
| Shadow copies / creating restore points | no | shadow-copy read is denied, `recovery` marks it skip |
| Read WinRE state, read BitLocker | no | `reinstall` marks both skip |
| `Get-CimInstance` (disk, memory, events) | yes | most read-only data comes from here |
| Enumerate installed programs (Uninstall registry) | yes | 114 entries here |
| `Get-AppxPackage` | needs a bridge | called directly from PS7 it silently returns empty; must go through the 5.1 bridge and verify the count is greater than zero |

## Tests and verification

```powershell
# Full suite: unit + live probes
node tests/run-all.mjs

# Unit only (fast, writes nothing)
node tests/run-all.mjs --unit-only

# Render the panel and validate copy and fetch calls
node tests/render.mjs

# Objective probe audit: syntax, banned APIs, UTF-8 header, param position (--no-run skips execution)
node tools/audit-probes.mjs
node tools/audit-probes.mjs --no-run

# Catalogue and preset validation (--offline makes no network calls)
node tools/verify-catalog.mjs --offline
node tools/verify-drivers.mjs --offline
node tools/merge-catalog.mjs --dry-run
```

This round's readings:

| Command | Result |
| --- | --- |
| `node tests/run-all-toolbox.mjs` | **PASS 38/38** (including live: junk 9 groups / 31 targets / 17200 files, bigfiles, dupfiles, netdiag, health, caching, render in both languages) |
| `node tests/run-all.mjs --unit-only` | **PASS 20/20**, including "panel and probes agree on the junk target count" |
| `node tests/render.mjs` | slots correct (order 8, sidebarGlyph svg), dict keys defined 152 / used 40, text nodes 121, 2 fetch calls; label "360 工具箱" and chars 2186 in zh, label "360 Toolbox" and chars 2894 with `TB360_LANG=en` |
| `node tools/audit-probes.mjs` | **44/44 probes clean, VERDICT PASS** |
| `node tools/verify-catalog.mjs --offline` | **198 entries / 11 categories, 14 warns (all github.com pending human confirmation), VERDICT PASS** |
| `node tools/verify-drivers.mjs --offline` | **20 vendors / 10 usb vendors / 15 classes, VERDICT PASS** |

The three junk samples all differ slightly (the probe alone reported 12801 files / 2082011223 bytes; inside the suite 12783 files / 2080592913 bytes; the documentation pass 12831 files / 2082971509 bytes) because the cache directories themselves change. That is not a read error. The table quotes the documentation pass.

## Installation

```powershell
# Already in the desktop profile as a link install (code edits take effect immediately).
# The entry in D:\Program Files (x86)\DSH_Data\profiles\desktop\package.json reads:
#   "dsh-windows-toolbox": "link:E:/DSHWORK/DSH插件/dsh-windows-toolbox"
```

To install from the plugin market as a link rather than a copy:

```
plugin_manager action:install_bundle target:"link:E:/DSHWORK/DSH插件/dsh-windows-toolbox"
```

**The host does not hot-reload.** Client-only changes (`client.js`) appear on a panel refresh, but changes to `index.js` or anything under `lib/` need the host to reload the plugin:

```powershell
$body = '{"name":"dsh-windows-toolbox","enabled":false}'
Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:51923/dsh-market/toggle' `
  -ContentType 'application/json' -Body $body `
  -Headers @{ origin = 'http://127.0.0.1:51923'; referer = 'http://127.0.0.1:51923/' }

$body = '{"name":"dsh-windows-toolbox","enabled":true}'
Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:51923/dsh-market/toggle' `
  -ContentType 'application/json' -Body $body `
  -Headers @{ origin = 'http://127.0.0.1:51923'; referer = 'http://127.0.0.1:51923/' }
```

Both the `origin` and `referer` headers are required; without them same-origin policy rejects the call. The route accepts POST only — `GET` returns 405.

Verify afterwards: `GET http://127.0.0.1:51923/dsh-windows-toolbox/  (one directory, two halves; this file covers the toolbox half)api/status` must return status for all 27 capabilities.

## Known limits

Written plainly. These are not a backlog; they are things that are impossible in this design or should not be done.

1. **Real-time popup blocking is impossible.** It needs a resident process hooking `SetWinEventHook` on window creation, and this DSH plugin is session-scoped and unloadable. `popup` publishes sources instead.
2. **Amoeba malware detection is impossible.** No kernel driver, no live signature feed, no behavioural monitoring. This capability covers USB installation policy and lateral-movement surface.
3. **BadUSB is unsolvable at the firmware layer.** A device that enumerates as a keyboard can rewrite its firmware and present as any device class; every OS policy runs behind it. Only the physical layer solves it.
4. **File shredding is ineffective on SSD with TRIM.** Both disks here are NVMe SSD with TRIM on, so overwritten blocks are remapped and the old physical blocks wait for GC. The real answer is full-disk encryption.
5. **Deleted-file recovery odds are near zero.** Same reason: on SSD a delete marks the blocks reclaimable. Only the judgement is offered, never a recover button — a button would trick the user into writing more data.
6. **C: cannot grow because of the recovery partition.** C: ends at 324420992512 and the recovery partition starts at 324421025792, only 32.5 KB apart; largest contiguous free space on either disk is 1.0 MB. Deleting the recovery partition breaks WinRE.
7. **DISM and sfc need elevation.** They exit 740 / 1 here and are reported as skip. They also should not run in the background from a plugin: DISM occupies the system for a long time.
8. **Moving installed software and auto-downloading drivers are not wired.** Moving only gets a feasibility analysis (moving a referenced directory destroys the program); drivers only get an inventory and vendor homepages because Windows has no local vendor-latest database.
9. **System-level backup and restore is out.** This machine has 0 restore points and VSS stopped. What is protected is "the registry keys we changed".
10. **Reinstall only gets pre-flight checks.** The reinstall reboots into another environment and the plugin has no lifecycle there.
11. **Software install/upgrade only prints commands.** A silent install is an irreversible write and must be run by the user.
12. **Some readings need admin and are skip when unelevated.** This round's skips: `rescue` sfc/DISM, `recovery` shadow copies, `reinstall` WinRE/BitLocker, `slim` system restore, `backup` export (not requested), 1 item in `winsettings`, and `popup`'s focus-assist state (undocumented format, not parsed).
13. **Speed test results depend on a single sample.** Two rounds on the same network can differ by several times, so endpoints and fallback state are always reported. Here: 1.78 Mbps down, 2.77 Mbps up, 358 ms latency.
14. **`Get-AppxPackage` silently returns empty on PS7.** Installed-app enumeration must go through the 5.1 bridge and verify the count is greater than zero, otherwise it looks like "no applications installed".
15. **Panel visuals need a human eye.** `tests/render.mjs` validates the copy and fetch calls produced by server rendering, not pixels. Dark mode, narrow-window wrapping and long-path truncation (`truncateMid`) all need a visual pass.
