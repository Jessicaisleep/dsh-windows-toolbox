# Scope assessment: which further Windows registration points belong in WPM

> Measured on Windows 10 Pro build 19045 · PowerShell 7.6.10 · **unelevated** · 2026-11-17
> Every count and duration below is a real measurement on this machine, reproducible from the shipped probes - not an estimate.

## 0. The criterion

WPM manages **registration points**: places where something registers itself so that Windows will load it, call it, or offer it as a candidate.
Whether a new registration point belongs in WPM is not a question of "how many entries does this key have". Four criteria decide it:

| Criterion | Meaning |
|---|---|
| **One authoritative source** | One read gets everything - no DISM, no network, no admin |
| **Reversible semantics** | On/off are two sides of one switch; the undo record restores it from the detected value |
| **Safe to get wrong** | A mistaken click has no irreversible consequence (no file deleted, no stack reset, no user binding broken) |
| **Meaningful alone** | One row out of context still answers "what is it, is it on, what happens if I turn it off" |

All four → its own management page. First two only → one read-only column in the search index. Otherwise → do not build it.

That criterion is the main output of this assessment: four of the eight candidates have hundreds or thousands of entries, but only one genuinely earns a management page.

## 1. Verdict table (8 candidates)

| Candidate | Entries (measured) | Read-only enumeration | Reversible | Risk of a wrong change | Needs admin | Verdict |
|---|---|---|---|---|---|---|
| Firewall rules | **542** (343 enabled) | **44 ms** (COM) | Yes, undo = previous `Enabled` | Wrong rule: that program/port loses or gains network access; no data loss | Read: no; **Write: yes** | **Include · own page + enable/disable** |
| IFEO image hijack | **86** (43 native + 43 WOW6432Node) | **595 ms** | No (read-only this version) | Detection value of a real malware technique far exceeds management value; deleting the wrong value silently drops a mitigation | Read: no; write: yes (not offered) | **Include · own page, read-only, hijacked rows marked bad** |
| File associations | **520** (163 with a real association) | **88 ms** (.NET per-key) | **No** (UserChoice is hash-bound) | Editing ProgId without the hash is silently reverted - the user believes the change worked | No (HKCU) | **No page · read-only column in the index** |
| Credential providers | **22** | **4 ms** | No (read-only this version) | Removing one removes a sign-in method; worst case locks you out | Read: no; write: yes | **No page · read-only column in the index** |
| Winsock LSP | **14** | **5 ms** | No (only a full `netsh winsock reset`) | The reset drops every network connection and needs a reboot | Yes | **Do not build** |
| Print providers | **2** | **2 ms** | No | Two system components; remove either and printing stops working | Yes | **Do not build** |
| ShellNew | **7** | **147 ms** (.NET per-key) | Yes (add/remove a subkey) | Only affects the right-click "New" menu; not worth a page | Write: yes | **Do not build** |
| CBS packages | **1680** | **6 ms** (.NET) | No | `CurrentState` is a bitmask; without DISM it cannot be translated into "installed / corrupt / pending reboot" | Read: no; write: yes (DISM) | **Do not build** |

> Measurement notes. "Enumeration" means reading the list only, excluding nothing but field formatting.
> For comparison: `netsh advfirewall firewall show rule name=all verbose` measured 943 ms / 10251 lines and was replaced by COM at 44 ms.
> Walking all of `HKLM\SOFTWARE\Classes` to find ShellNew measured 1741 ms (top level) / 3365 ms (wildcard) / 9063 ms (deep recursion); per-subkey `OpenSubKey('ShellNew')` brought it to 147 ms.

## 2. Candidate by candidate

### 2.1 Firewall rules - the only one that earns a page

It is the only candidate that meets all four criteria. Each of the 542 rules says "allow or block this program or port", `Enabled` is a genuine boolean, and turning a rule off is behaviourally identical to deleting it while remaining fully reversible.

**Why COM, not netsh and not the registry:**

| Method | Cost | Problem |
|---|---|---|
| `netsh advfirewall firewall show rule name=all verbose` | 943 ms / 10251 lines | Text parsing; fields recovered by regex; failures are silent |
| `Get-NetFirewallRule` (NetSecurity) | 1162 ms | **Returns 0 rows silently under PS7**; bridged through powershell.exe it reports "Access is denied" (System Error 5). Unusable on this machine |
| Registry `FirewallRules` key | 67 ms read + 94 ms parse | Values look like `v2.30\|Action=Allow\|Active=FALSE\|...`; readable and writable, but bypasses the firewall service's validation |
| **`New-Object -ComObject HNetCfg.FwPolicy2`** | **44 ms, all fields** | The documented path; fields are typed properties |

**Name is not unique - the real trap found while wiring this up.** 542 rules carry only 324 distinct names. `name+direction` still leaves 131 colliding groups; adding `Profiles` still leaves 63; and two same-named rules can even differ in state (Network Discovery ships two `SSDP-In` rules: `Profiles=5 Enabled=False` and `Profiles=2 Enabled=True`, confirmed by netsh).
Only the nine-tuple `name|dir|action|protocol|localPorts|remotePorts|app|profiles|serviceName` reaches 542/542 uniqueness. Therefore:

- Entry ids use the nine-tuple, never the name.
- `actions.ps1` falls back to name only when `keyPath` is absent, and **refuses outright when more than one rule matches**, asking for `keyPath` instead of guessing.

**Write access.** Setting `$rule.Enabled` to its own current value unelevated throws `E_ACCESSDENIED 0x80070005` and the rule stays byte-identical: the COM setter fails cleanly rather than half-writing. Writes are therefore in `$writeNeedsAdmin` and return `needsAdmin:true` unelevated so the panel can offer an elevated retry.

**Backup.** `reg export` of that key succeeds unelevated (77 ms / 314 632 bytes), so every write first exports to `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\<timestamp>-firewallrules.reg`; if the export fails, the write is aborted rather than attempted.

**Deliberately omitted.** Publisher/version via `VersionInfo` on each application path. The full pass measured 5161 ms - 64 paths sit in System32 and start cold. An empty field beats a page that stalls for five seconds.

### 2.2 IFEO image hijack - do not manage it, absolutely detect it

Each subkey under `Image File Execution Options` is named after an executable. If it contains a `Debugger` value then **launching that executable actually runs the Debugger's target; the original never starts.** This is a real, currently used malware persistence technique and does not occur on a clean machine.

**Measured here:** 43 keys in the native view, 43 in WOW6432Node, **zero `Debugger` values**. The value names present are `MitigationOptions`×78, `CFGOptions`×4, `DisableExceptionChainValidation`×4, `DisableUserModeCallbackFilter`×2, `MinimumStackCommitInBytes`×2 - all written by Windows' own exploit protection.

**Why it is included anyway.** Detection value far exceeds management value. A 43-row list that is normally all system mitigations and only grows a `Debugger` when the machine is compromised does not need frequent management - but it does need to be visible. Hence:

- Its own source, so it shows up in the source strip and sidebar.
- `riskOf()` returns `RISK.blocked` when `detail.hijacked === true`, so a hijacked row sorts to the top under the blocked rule and renders red, at the same visual level as a protected service.
- No write path: deleting the wrong `MitigationOptions` silently disables a mitigation for that program and the user sees nothing change.

### 2.3 File associations - real data, not writable

**Measured:** 520 extensions, 515 with a `UserChoice` subkey, but **only 163 carrying a `Progid` value** (note the value name here is `Progid` with a lowercase d; PowerShell property lookup is case-sensitive, so both spellings must be tried). 352 `UserChoice` keys hold no values at all - empty shells left by uninstalled software, and a common cause of "double-click does nothing / keeps asking", which is exactly why showing them is useful.

**Why it cannot be reversed.** `UserChoice` also carries a `Hash` value (sample here: `NRGqFLyZwMc=`) that Windows uses to verify the ProgId was not modified by a third party. Change the ProgId without recomputing the hash and Windows **silently reverts it** on next sign-in or reboot - the user believes the edit succeeded. Recomputing the hash is an undocumented algorithm; not attempted.

So: read-only listing (extension → current ProgId → the command that actually runs; ProgId→command resolved 67/79 in 9 ms), `actions: []`, and the explanation card states plainly that changes belong in Settings > Default apps.

**Performance trap.** Reading each extension with `Get-ItemProperty -LiteralPath` three times (UserChoice / OpenWithProgids / OpenWithList) measured **34 210 ms** - catastrophic. Switching to `[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey()` per subkey with direct `GetValue` brought it to 88 ms. The probe uses zero wildcards.

### 2.4 Credential providers - 22 rows, read-only, security lens

**Measured:** 22 CLSIDs, all with a display name and a resolvable `InprocServer32` DLL (10 ms). Samples: `{01A30791-…}` = Automatic Redeployment Credential Provider / `mgmtrefreshcredprov.dll`; `{25CBB996-…}` = GenericProvider / `credprovs.dll`.

**Why read-only.** Every provider is a way to sign in. Removing one removes a sign-in method; the worst case locks the owner out, and recovery needs another sign-in path. That cost is out of proportion to the benefit of a toggle.

**Why it still belongs in the index.** Two signals are detectable:
- `dllMissing`: the registered DLL is gone, so the sign-in method is skipped - a common cause of "my PIN/fingerprint option vanished".
- `inSystemDir === false`: the DLL is outside the Windows directory, i.e. a third-party component, and such a component can read what is typed at the lock screen. An unrecognised one is worth verifying.

12 of the 22 are outside the known list, and all 22 DLLs live in System32.

### 2.5 Winsock LSP - do not build

14 entries, readable in 5 ms. But:

- All 14 are system components (`mswsock.dll`, `wshqos.dll`). `PackedCatalogItem` is an 888-byte binary blob; scanning it as Unicode and as ASCII **yields only ProtocolName, never a DLL path**, so the probe cannot reliably say whose entry this is. `netsh winsock show catalog` (143 ms / 575 lines) is no better: its Provider Path column contains only `%SystemRoot%\system32\mswsock.dll` throughout.
- There is no per-entry switch. The only repair is `netsh winsock reset`, a **full** reset that drops every connection and requires a reboot.

A list that can only be fixed wholesale, and that cannot even say what each row is, would only invite users to press that reset. Not built.

### 2.6 Print providers - do not build

2 entries (Internet Print Provider / `inetpp.dll`, LanMan Print Services / `win32spl.dll`), 1 ms. Two fixed system components; removing either breaks printing. There is no "manage" action to offer. Not built.

### 2.7 ShellNew - do not build

7 entries: `.bmp .contact .library-ms .lnk .rtf .txt Folder`. A workable 147 ms enumeration exists (`LocalMachine.OpenSubKey('SOFTWARE\Classes')`, then `OpenSubKey('ShellNew')` per subkey, avoiding the full-tree walk), so it is technically fine.

But its entire scope is a handful of items in the right-click "New" menu. Toggling them affects neither what loads nor how any file behaves. It cannot carry a page, and as index rows it is noise. Not built.

### 2.8 CBS packages - do not build

1680 entries in 6 ms (.NET direct read). The problem is semantics: `CurrentState` is a bitmask (sample value 64) that cannot be translated into "installed / corrupt / pending reboot" without DISM. And packages have **no individual switch** - there is no "turn this package off", only an uninstall through DISM that forces a reboot.

A 1680-row list whose status codes users cannot read and whose only action is "uninstall and reboot" is the kind of page that looks professional and can only ever be closed. Not built.

## 3. Cross-check against 360's "System Repair / Speed-up" module

The user observed that 360's system-repair module is really "a collection of toggleable system items" - the same thing under another name. That is partly true, but **the two are not the same axis**, and the distinction matters:

- A WPM source is a **registration point**: something registered itself and will be loaded or called. The question is "what is this row, is it on".
- Most 360 repair items are **configuration drift checks**: a value should be X but currently is Y. The question is "was this changed, and can I change it back".

A registration point is a homogeneous list of rows; a drift check is a set of unrelated assertions. The latter needs "found problem → fix it", not a table view. Pushed into WPM's source grid, every row would be a one-off, which is precisely where the value disappears.

Item-by-item mapping (measured on this machine):

| 360 repair item | Maps to WPM source | Measured here | Conclusion |
|---|---|---|---|
| Too many startup items | **autorun** (+ svc / task) | 3 autorun rows | Exists, manageable |
| System service configuration | **svc** | 272 rows | Exists, manageable |
| Scheduled task anomalies | **task** | 165 rows | Exists, manageable |
| Desktop icon / shortcut hijack | **com** (shell extensions) + **ifeo** (launch hijack) | com 78 / ifeo 86 (0 hijacked) | Exists. 0 desktop `.lnk` files; shortcut targets need per-file WSH parsing and are outside registration-point scope |
| System time anomalies | **svc** (`w32time`) | Running / Manual | Exists |
| Windows Update service state | **svc** (`wuauserv` / `BITS`) | Running/Manual; Stopped/Manual | Exists |
| LSP repair | candidate **winsock** | 14 entries / 5 ms | **Not included** (see 2.5 - only a wholesale reset) |
| hosts anomalies | **no source** (a file, not a registration point) | exists, 0 active entries, 53 ms | Not built: file-integrity check |
| IE / browser settings tampering | **no source** | `HKCU\…\Internet Explorer\Main` 24 values, 16 ms | Not built: policy value checks |
| DNS settings | **no source** | 0 interfaces with static DNS, 41 ms | Not built: same |
| Network connection limit | **no source** | 0 relevant `Tcpip\Parameters` values, 31 ms | Not built: same |
| UAC settings | **no source** | `EnableLUA=1` / `ConsentPromptBehaviorAdmin=5`, 17 ms | Not built: same |
| Redundant registry entries | **no source** | - | Not built: needs a full-tree scan; cost and false-positive rate both high |
| Font cache corruption | **no source** (files) | `FontCache` directory: 0 files | Not built |
| Icon cache corruption | **no source** (files) | `IconCache.db` present + 16 `iconcache*` files, 37 ms | Not built: file cleanup, overlaps the tb360 toolbox |

Of the 15 items, **6 land on existing sources** (autorun / svc / task / com / ifeo), 1 lands on an evaluated candidate (winsock, excluded), and 8 belong to **a different capability class** (configuration drift / file integrity) which is not what WPM should grow into.

**Conclusion.** Do not add configuration checks to WPM just because 360 ships them. If those 8 are wanted, the right shape is a separate "system repair" plugin with an assert → detect → repair cycle, not a source.

## 4. What was actually built

Four new sources (sources.js: 7 → **11**):

| source | Purpose | Entries | Probe time | risk | actions |
|---|---|---|---|---|---|
| `firewall` | Firewall rules | 542 | 1314 ms | reversible | `enable` / `disable` |
| `ifeo` | IFEO image hijack | 86 | 595 ms | readonly (hijacked rows promoted to blocked) | `[]` |
| `fileexts` | File associations | 520 | 696 ms | readonly | `[]` |
| `credprov` | Credential providers | 22 | 551 ms | readonly | `[]` |

The unified index grows from 1150 to **2320 rows**. `node tests\run-all.mjs` → **PASS 47/47** (the original 43 plus one enumeration assertion per new source).

## 5. On client.js (read-only inspection, not modified)

`client.js` belongs to another change line and was not touched here. At delivery time it was re-checked for how it handles the new sources, and it **already keeps up automatically** - no change is needed for them:

- The sidebar and source strip are generated from `status.sources`, so a new source appears on its own.
- Row and card action buttons are gated by `canAct = actions.length > 0`, where `actions` comes from the source summary in the backend `/status` response - **not from a hardcoded list of source names**. So `firewall` (`actions: ['enable','disable']`) gets its buttons automatically, and the three read-only sources fall through to `readonlyNote` ("Read-only in this version.").
- Risk badges go through the `RISK_KEY` table: `readonly` → "Read-only", `blocked` → red "Protected".

An earlier revision of `client.js` had `canAct` hardcoded to `['svc','task','autorun','com']` and rendered action buttons for anything that was not blocked/destructive; both were fixed by the other change line before this delivery. **Adding a source now only requires declaring its `actions` honestly in `sources.js`; the panel follows by itself.**
