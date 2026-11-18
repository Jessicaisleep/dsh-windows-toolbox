# com.ps1 - enumerate shell extensions / COM handlers (L3 registration point).
#
# WHAT THIS COVERS
#   The context-menu and property-sheet entries a user can actually see and turn
#   off: ContextMenuHandlers, PropertySheetHandlers, DragDropHandlers,
#   CopyHookHandlers across the usual class roots, in both registry views, plus
#   the Shell Extensions\Approved allow-list that Explorer consults.
#
# TWO PERFORMANCE RULES - both measured on this machine 2026-11-17. Breaking
# either turns an 1.8 s probe into a minute-plus one.
#
#  1. NO Test-Path ON KEYS THAT MIGHT NOT EXIST.
#     A missing registry key costs ~387 ms per probe (measured: 60 probes on
#     absent keys = 23.2 s; 60 probes on absent child keys = 47.0 s). Probing
#     six paths per row for ~80 rows is the whole 85 s. Instead, enumerate each
#     CLSID root ONCE into a hashtable (7711 entries in 1.5 s) and answer every
#     lookup from memory.
#
#  2. -LiteralPath EVERYWHERE.
#     Several class roots contain a literal asterisk: Classes\*\shellex. With
#     plain -Path the provider treats '*' as a wildcard and walks the whole
#     Classes tree (7443 CLSID keys); measured >120 s and still running, which
#     reads as a hang. -LiteralPath returns in 4 ms.
#
# Read-only.
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ---- bulk CLSID index (rule 1) ----
# One enumeration per hive, then everything below is a hashtable hit.
$clsidRoots = @(
  @{ path = 'HKLM:\SOFTWARE\Classes\CLSID';             view = '64' },
  @{ path = 'HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID'; view = '32' },
  @{ path = 'HKCU:\SOFTWARE\Classes\CLSID';             view = 'user' }
)
$clsidIndex = @{}
foreach ($cr in $clsidRoots) {
  if (-not (Test-Path -LiteralPath $cr.path)) { continue }
  foreach ($k in (Get-ChildItem -LiteralPath $cr.path -ErrorAction SilentlyContinue)) {
    $id = $k.PSChildName
    if ($clsidIndex.ContainsKey($id)) { continue }
    $clsidIndex[$id] = $k
  }
}

# ---- MUI resource strings -> real UI text ----
# A property-sheet handler does not always ship its page title as plain text: the
# CLSID key may carry
#     PageTitle = '@C:\Windows\system32\twext.dll,-1024'
# which is a reference INTO a binary resource table. Printing that reference is
# exactly the "it says a page was added but not WHICH page" complaint, so it is
# resolved here through the shell's own resolver (SHLoadIndirectString) instead
# of being reimplemented: Windows is the only thing that knows how to dig the
# string out of a .mui, and a hand-rolled reader would silently drift.
#
# Failure is normal and must stay silent: a missing DLL, a bad resource id or a
# non-resource value all yield '' and the caller prints the raw reference.
$isMuiResolverReady = $false
try {
  $muiSignature = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DshMuiResolver {
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, SetLastError = false)]
    private static extern int SHLoadIndirectString(string pszSource, StringBuilder pszOutBuf, int cchOutBuf, IntPtr ppvReserved);
    public static string Resolve(string source) {
        if (string.IsNullOrEmpty(source)) return "";
        var buffer = new StringBuilder(2048);
        int hr = SHLoadIndirectString(source, buffer, buffer.Capacity, IntPtr.Zero);
        if (hr != 0) return "";
        return buffer.ToString();
    }
}
'@
  # -ErrorAction SilentlyContinue covers the re-run case ("type already exists"),
  # which happens whenever this dot-sourced script is loaded twice in one session.
  Add-Type -TypeDefinition $muiSignature -ErrorAction SilentlyContinue
  $isMuiResolverReady = $true
} catch {
  $isMuiResolverReady = $false
}

function Resolve-MuiText {
  param([string]$Value)
  $raw = ([string]$Value).Trim()
  if (-not $raw) { return '' }
  # Only '@...' values are indirection; anything else is already user-facing text
  # (some vendors store the literal page name in PageTitle).
  if (-not $raw.StartsWith('@')) { return $raw }
  if (-not $isMuiResolverReady) { return '' }
  try {
    $resolved = [DshMuiResolver]::Resolve($raw)
    if ($resolved) { return $resolved.Trim() }
  } catch { }
  return ''
}

# Resolve from the index only - never touch the registry for a miss.
function Resolve-Clsid {
  param([string]$Clsid)
  # pageTitle* : the property-sheet TAB name ("以前的版本"), which is what a user
  #              sees in 文件属性 → the extra tab they did not ask for.
  # verbs       : ImplementsVerbs, the shell verbs a context-menu handler adds
  #              ("startpin;startunpin" = pin to Start / unpin). This is the human
  #              answer to "which menu item is it?", available for only a few
  #              handlers but exact when present.
  $out = [ordered]@{
    name = ''; server = ''; serverType = ''
    pageTitle = ''; pageTitleText = ''; verbs = ''; neverDefault = ''
  }
  if (-not $clsidIndex.ContainsKey($Clsid)) { return $out }
  $key = $clsidIndex[$Clsid]
  $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
  if ($props) {
    if ($props.'(default)') { $out.name = [string]$props.'(default)' }
    if ($props.'PageTitle') { $out.pageTitle = [string]$props.'PageTitle' }
    if ($props.'ImplementsVerbs') { $out.verbs = [string]$props.'ImplementsVerbs' }
    if ($props.'NeverDefault') { $out.neverDefault = [string]$props.'NeverDefault' }
  }

  # Children of a key we already hold: enumerate the child NAMES (47 ms for 78
  # keys) rather than probing for each candidate server subkey by name (~387 ms
  # per miss). Only the hits get a Get-ItemProperty.
  #   InprocServer32 = in-process DLL, LocalServer32 = out-of-process EXE,
  #   InprocHandler32 = legacy 16-bit shim (rare, kept for completeness).
  $kids = @{}
  foreach ($kid in (Get-ChildItem -LiteralPath $key.PSPath -ErrorAction SilentlyContinue)) {
    $kids[$kid.PSChildName] = $kid.PSPath
  }
  foreach ($st in @('InprocServer32', 'LocalServer32', 'InprocHandler32')) {
    if (-not $kids.ContainsKey($st)) { continue }
    $sp = Get-ItemProperty -LiteralPath $kids[$st] -ErrorAction SilentlyContinue
    if ($null -eq $sp) { continue }
    $srv = [string]$sp.'(default)'
    if (-not $srv) { continue }
    # Prefer the in-process server: that is the one Explorer actually loads.
    if ($st -eq 'InprocServer32' -or -not $out.server) {
      $out.server = $srv
      $out.serverType = $st
    }
  }
  # Resolved after the server lookup: the reference is usually a path into the
  # handler's own DLL/MUI, and a future reader may want to fall back to the
  # server's directory for a bare resource id.
  if ($out.pageTitle) { $out.pageTitleText = Resolve-MuiText -Value $out.pageTitle }
  return $out
}

# ---- class roots carrying user-visible shell extensions ----
$classRoots = @(
  @{ sub = '*';                      cls = 'AllFiles' },
  @{ sub = 'AllFilesystemObjects';   cls = 'AllFilesystemObjects' },
  @{ sub = 'Directory';              cls = 'Directory' },
  @{ sub = 'Directory\Background';   cls = 'DirectoryBackground' },
  @{ sub = 'Folder';                 cls = 'Folder' },
  @{ sub = 'Drive';                  cls = 'Drive' },
  @{ sub = 'LibraryFolder';          cls = 'LibraryFolder' }
)

$handlerKinds = @('ContextMenuHandlers', 'PropertySheetHandlers', 'DragDropHandlers', 'CopyHookHandlers')

# ---- DLL version resources: FileDescription / CompanyName ----
# The explain layer wants to tell the user WHO provides a handler ("由「360压缩
# 文件类型」提供，注册名是…"), and the vendor's own words live in the DLL's version
# resource. Reading it is cheap but not free (measured 1.5 ms per DLL), and the
# 78 rows here share only 24 distinct DLLs, so cache by path: one read per DLL.
# Windows paths are case-insensitive, hence the lower-cased cache key.
#
# A missing, locked or permission-denied file must stay silent: the row keeps an
# empty string, nothing is thrown and nothing is written to stdout (stdout must
# contain the JSON document and nothing else).
$dllInfoCache = @{}
function Get-DllInfo {
  param([string]$Server)
  $info = [ordered]@{ description = ''; company = '' }
  $raw = ([string]$Server).Trim()
  if (-not $raw) { return $info }

  # LocalServer32 values are sometimes stored wrapped in quotes. Strip one pair;
  # anything with trailing command-line arguments simply fails to resolve below
  # and degrades to the empty strings, which is the intended behaviour.
  if ($raw.Length -ge 2 -and $raw.StartsWith('"') -and $raw.EndsWith('"')) {
    $raw = $raw.Substring(1, $raw.Length - 2).Trim()
  }
  if (-not $raw) { return $info }
  # Only absolute paths are trustworthy. LocalServer32 may hold a bare command
  # name ("msiexec.exe /x"), and resolving that against the current directory
  # could attribute a handler to an unrelated file that happens to sit there.
  if (-not [System.IO.Path]::IsPathRooted($raw)) { return $info }

  $ck = $raw.ToLowerInvariant()
  if ($dllInfoCache.ContainsKey($ck)) { return $dllInfoCache[$ck] }

  $item = Get-Item -LiteralPath $raw -ErrorAction SilentlyContinue
  if ($null -ne $item) {
    $vi = $item.VersionInfo
    if ($null -ne $vi) {
      $desc = [string]$vi.FileDescription
      $comp = [string]$vi.CompanyName
      if ($desc) { $info.description = $desc.Trim() }
      if ($comp) { $info.company = $comp.Trim() }
    }
  }
  $dllInfoCache[$ck] = $info
  return $info
}

# Two elevation-free views + the per-user one. A 32-bit-only handler still shows
# up in 64-bit Explorer, so both are worth reading.
$views = @(
  @{ hive = 'HKLM'; base = 'SOFTWARE\Classes';             view = '64' },
  @{ hive = 'HKLM'; base = 'SOFTWARE\WOW6432Node\Classes'; view = '32' },
  @{ hive = 'HKCU'; base = 'SOFTWARE\Classes';             view = 'user' }
)

$rows = New-Object System.Collections.Generic.List[object]
$seen = @{}

foreach ($v in $views) {
  $hivePath = "$($v.hive):\$($v.base)"
  if (-not (Test-Path -LiteralPath $hivePath)) { continue }

  foreach ($cr in $classRoots) {
    # Probe one level up (…\<class>\shellex) and enumerate its child names, so a
    # missing handler kind costs a hashtable miss instead of a 387 ms registry
    # probe. 21 such probes per run, all on keys that normally exist.
    $shellexPath = Join-Path $hivePath ($cr.sub + '\shellex')
    $shellex = Get-Item -LiteralPath $shellexPath -ErrorAction SilentlyContinue
    if ($null -eq $shellex) { continue }

    $kindPresent = @{}
    foreach ($kid in (Get-ChildItem -LiteralPath $shellexPath -ErrorAction SilentlyContinue)) {
      $kindPresent[$kid.PSChildName] = $kid.PSPath
    }

    foreach ($hk in $handlerKinds) {
      if (-not $kindPresent.ContainsKey($hk)) { continue }
      $p = $kindPresent[$hk]

      foreach ($h in (Get-ChildItem -LiteralPath $p -ErrorAction SilentlyContinue)) {
        $hp = Get-ItemProperty -LiteralPath $h.PSPath -ErrorAction SilentlyContinue
        $clsid = [string]$hp.'(default)'
        if (-not $clsid) { $clsid = [string]$h.PSChildName }
        $clsid = $clsid.Trim()
        # Some entries store a ProgID or a bare name instead of a CLSID; keep the
        # row (Explorer still loads it) but leave the CLSID fields empty.
        $isClsid = ($clsid -match '^\{[0-9A-Fa-f\-]{36}\}$')

        # WHERE the handler is registered and WHAT the handler calls itself are
        # two different things, and conflating them loses the good case:
        #     key  = ...\ContextMenuHandlers\{a2a9545d-...}
        #     (default) = "Start Menu Pin"
        # Here the default value is a friendly name, not a CLSID — so testing the
        # default alone concluded "not a CLSID" and skipped resolution entirely,
        # which is why the two entries that DO publish ImplementsVerbs reported
        # no verbs at all. The key name is the CLSID in that case, so fall back to
        # it for RESOLUTION while still reporting the default value as the display
        # name.
        $childName = [string]$h.PSChildName
        $resolveId = ''
        if ($isClsid) { $resolveId = $clsid }
        elseif ($childName -match '^\{[0-9A-Fa-f\-]{36}\}$') { $resolveId = $childName }

        $res = [ordered]@{
          name = ''; server = ''; serverType = ''
          pageTitle = ''; pageTitleText = ''; verbs = ''; neverDefault = ''
        }
        if ($resolveId) { $res = Resolve-Clsid -Clsid $resolveId }

        # The handler SUBKEY can carry its own MUIVerb ("Menu text override") and
        # CommandFlags. Measured on this machine 0 occurrences for these four
        # handler kinds, but a per-user entry from a vendored installer does use
        # it, and it is the only literal menu label available when it exists.
        $subMuiVerb = ''
        $subCommandFlags = ''
        if ($hp) {
          if ($hp.'MUIVerb') { $subMuiVerb = [string]$hp.'MUIVerb' }
          if ($hp.'CommandFlags') { $subCommandFlags = [string]$hp.'CommandFlags' }
        }
        $subMuiText = Resolve-MuiText -Value $subMuiVerb

        $dedupe = "$($cr.cls)|$hk|$clsid|$($v.view)"
        if ($seen.ContainsKey($dedupe)) { continue }
        $seen[$dedupe] = $true

        # Registry key names may carry a leading control-character sort prefix
        # (real example on this machine: "`u{0001}`u{0001}360Zip"). Windows uses
        # it to pin the entry to the top of the menu; it is noise in a UI, so it
        # is stripped from the display name while the untouched key name stays in
        # keyPath for the action probe to act on.
        $cleanName = ($h.PSChildName -replace '^[\x00-\x1f]+', '').Trim()
        if (-not $cleanName) { $cleanName = $clsid }

        # Cached: 78 rows resolve to 24 distinct DLLs on this machine, so this is
        # ~24 file reads instead of 78.
        $dll = Get-DllInfo -Server $res.server

        # The card title must never be a bare GUID when a human name exists. The
        # order is: the vendor's own menu-label override, then the CLSID key's
        # default value (the handler's registered name), then the registry key
        # name, and only if that is still a GUID, the server binary's own
        # FileDescription. That last step is what names the three leftovers on
        # this machine: cscui.dll ("客户端缓存 UI") and rdbui.dll ("ReadyBoost UI")
        # publish no name of their own anywhere in the registry.
        $cleanNameIsGuid = ($cleanName -match '^\{[0-9A-Fa-f\-]{36}\}$')
        $title = ''
        if ($subMuiText) { $title = $subMuiText }
        elseif ($res.name) { $title = $res.name }
        elseif ($cleanName -and -not $cleanNameIsGuid) { $title = $cleanName }
        elseif ($dll.description) { $title = $dll.description }
        elseif ($cleanName) { $title = $cleanName }

        $rows.Add([ordered]@{
          source      = 'com'
          kind        = 'shellext'
          name        = $(if ($title) { $title } elseif ($cleanName) { $cleanName } else { $clsid })
          rawName     = $h.PSChildName
          displayName = $res.name
          # clsid is the identity used for actions (Approved allow-list, disable),
          # so it is filled whenever the identity is knowable — including the case
          # where the default value is a friendly name and the KEY NAME is the
          # CLSID. rawValue keeps the untouched default value so the "no name of
          # its own, but the default value is the friendly name" rows still have a
          # label to show.
          clsid       = $resolveId
          rawValue    = $(if ($isClsid) { '' } else { $clsid })
          handlerKind = $hk
          classRoot   = $cr.cls
          scope       = $(if ($v.hive -eq 'HKCU') { 'user' } else { 'machine' })
          view        = $v.view
          server      = $res.server
          serverType  = $res.serverType
          # Whether Explorer loads this handler is decided SOLELY by whether an
          # empty value exists for its CLSID under Shell Extensions\Approved:
          #   no value at all -> loaded (Approved is an allow-list for one legacy
          #                     code path, absence is NOT a block)
          #   value == ''    -> NOT loaded (this is the reversible "disable" lever)
          #   value != ''    -> loaded
          # The three cases must stay distinguishable, so this probe reports
          # `inApproved` and `approved` separately instead of collapsing both
          # "absent" and "empty" into ''. Filled in after the allow-list is read.
          inApproved  = $false
          approved    = ''
          keyPath     = ($h.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')
          # Version resource of the server binary, so the explain layer can say
          # who provides the handler. Empty string when unreadable - never null,
          # so the consumer does not have to distinguish "missing" from "blank".
          dllDescription = $dll.description
          dllCompany     = $dll.company
          # --- "which page / which menu item?" data ---
          # pageTitle       raw reference, kept so the UI can show the provenance
          # pageTitleText   resolved tab name ("以前的版本"); '' when unresolvable
          # verbs           ImplementsVerbs, e.g. "startpin;startunpin"
          # muiVerb / muiVerbText  the handler subkey's own label override
          # commandFlags    CommandFlags bitfield (1 = default item, 32 = no UAC
          #                 shield, ...); reported raw, the explain layer only uses
          #                 the two flags it can name honestly
          pageTitle      = $res.pageTitle
          pageTitleText  = $res.pageTitleText
          verbs          = $res.verbs
          neverDefault   = $res.neverDefault
          muiVerb        = $subMuiVerb
          muiVerbText    = $subMuiText
          commandFlags   = $subCommandFlags
        })
      }
    }
  }
}

# ---- Shell Extensions\Approved allow-list ----
# Present but empty string = explicitly blocked. Per-CLSID, so it cross-references
# the rows above. Built the same way: enumerate once, no probe-on-miss.
$approvedMap = @{}
foreach ($v in @(
    @{ base = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'; tag = '64' },
    @{ base = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'; tag = '32' },
    @{ base = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'; tag = 'user' })) {
  if (-not (Test-Path -LiteralPath $v.base)) { continue }
  $props = Get-ItemProperty -LiteralPath $v.base -ErrorAction SilentlyContinue
  if ($null -eq $props) { continue }
  foreach ($p in $props.PSObject.Properties) {
    if ($p.Name -like 'PS*') { continue }
    if ($approvedMap.ContainsKey($p.Name)) { continue }
    $approvedMap[$p.Name] = [string]$p.Value
  }
}

foreach ($r in $rows) {
  $k = [string]$r.clsid
  if ($k -and $approvedMap.ContainsKey($k)) {
    $r.inApproved = $true
    $r.approved = $approvedMap[$k]
  }
}

# Handlers an Approved value of "" has switched off. Most are preview / thumbnail
# / namespace handlers that the loop above never enumerates, which is exactly why
# the count is reported separately from the handler rows.
$blockedCount = 0
foreach ($kv in $approvedMap.GetEnumerator()) {
  if ($kv.Value -eq '') { $blockedCount++ }
}

$payload = [ordered]@{
  rows          = @($rows.ToArray())
  approvedCount = $approvedMap.Count
  blockedCount  = $blockedCount
  clsidCount    = $clsidIndex.Count
}
$json = ConvertTo-Json -InputObject $payload -Depth 5 -Compress
[Console]::Out.Write($json)
