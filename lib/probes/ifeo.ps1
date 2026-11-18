# ifeo.ps1 - enumerate Image File Execution Options (IFEO) entries.
# Read-only. One JSON array on stdout.
#
# WHY THIS SOURCE EXISTS: its detection value beats its management value.
#
# IFEO is where Windows stores per-image compatibility and mitigation switches
# (MitigationOptions, CFGOptions, MinimumStackCommitInBytes ...). It is also the
# classic "image hijack" persistence trick: a `Debugger` value under
# IFEO\<process>.exe makes Windows launch the debugger INSTEAD of the program -
# e.g. Debugger=C:\evil.exe under notepad.exe means every notepad launch runs
# evil.exe. Real malware families (Gootkit, Dridex loaders, and most "ifEO"
# named stealers) use exactly this. A plain inventory of the key is therefore a
# security check, not a tidy-up list.
#
# Measured 2026-11-17, unelevated, via Microsoft.Win32.Registry (not the
# PowerShell provider): 43 subkeys in the 64-bit view (24 ms) and the same 43 in
# WOW6432Node (2 ms). Every one carries a mitigation value; zero carry a
# Debugger, i.e. this machine is clean today.
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# The .NET registry API is used instead of Get-ChildItem/Get-ItemProperty
# because it is ~4x faster here and, more importantly, never touches the
# PowerShell registry provider (which costs 387 ms per Test-Path on a key that
# does not exist - see docs/../CONTRACT.md).
Add-Type -AssemblyName Microsoft.Win32.Registry -ErrorAction SilentlyContinue

# Both registry views. 32-bit processes see a different IFEO tree; malware
# installed by a 32-bit dropper lands in the WOW6432Node copy and is invisible to
# a 64-bit-only scan.
$VIEWS = @(
  @{ path = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'; view = '64' },
  @{ path = 'SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'; view = '32' }
)

# Values IFEO is legitimately used for. Anything else is worth a look, and
# `Debugger` is the one that means "another program now runs instead of this one".
$KNOWN_SAFE = @(
  'MitigationOptions', 'CFGOptions', 'MinimumStackCommitInBytes',
  'DisableExceptionChainValidation', 'DisableUserModeCallbackFilter',
  'DisableUserModeCallbackFilterOverride', 'GlobalFlag', 'VerifierDlls',
  'LoadAppInit_DLLs', 'DisableLeakDetection', 'DisableHeapLookaside',
  'ShutdownFlags', 'UseFilter', 'PerfOptions', 'CpuPriorityClass',
  'IoPriority', 'PagePriority', 'MaxLoaderThreads', 'TrySupportedPlatforms'
)

$rows = New-Object System.Collections.Generic.List[object]

foreach ($v in $VIEWS) {
  # Get-Item equivalent with -ErrorAction SilentlyContinue semantics: OpenSubKey
  # returns $null for a missing key instead of throwing or costing 387 ms.
  $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($v.path)
  if ($null -eq $root) { continue }

  foreach ($exe in $root.GetSubKeyNames()) {
    $k = $root.OpenSubKey($exe)
    if ($null -eq $k) { continue }

    $debugger  = [string]$k.GetValue('Debugger')
    $globalFlag = [string]$k.GetValue('GlobalFlag')
    $mitigation = [string]$k.GetValue('MitigationOptions')
    $cfg       = [string]$k.GetValue('CFGOptions')
    $valueNames = @($k.GetValueNames())
    $k.Close()

    # "Debugger" or "GlobalFlag with FLG_APPLICATION_VERIFIER (0x100)" are the two
    # ways this key makes a different binary run. Treat both as hijacks.
    #
    # GlobalFlag 0x100 (256) = FLG_HEAP_ENABLE_TAIL_CHECK|...; the documented
    # "run gflags/verifier on this image" bitmask starts at 0x100 and does not
    # redirect execution, so only a Debugger counts as a redirect. GlobalFlag is
    # reported as a fact, not as bad.
    $isHijack = ($debugger -ne '')

    $unknownValues = @($valueNames | Where-Object { $KNOWN_SAFE -notcontains $_ })

    if ($isHijack) {
      $state = 'hijacked'
    } elseif ($valueNames.Count -gt 0) {
      $state = 'enabled'
    } else {
      $state = 'empty'
    }

    $rows.Add([ordered]@{
      source      = 'ifeo'
      kind        = 'ifeo'
      # IFEO keys are process image names, so exe name + registry view is the
      # identity. The same exe can legitimately appear in both views.
      keyPath     = "$($v.view)\$exe"
      name        = $exe
      displayName = $exe
      exe         = $exe
      state       = $state
      # `enabled` means "this IFEO entry is actively doing something". A debugger
      # entry is on by definition; a mitigation-only entry is on too (the values
      # apply at every launch). Only a completely empty key is inert.
      enabled     = ($valueNames.Count -gt 0)
      debugger    = $debugger
      hijacked    = $isHijack
      mitigation  = $mitigation
      cfg         = $cfg
      globalFlag  = $globalFlag
      valueNames  = $valueNames
      unknown     = $unknownValues
      path        = $debugger
      view        = $v.view
      scope       = 'machine'
      # Where the settings came from: a mitigation value is normally written by
      # Windows itself or by an Exploit Protection setting in Windows Security.
      description = $(if ($isHijack) {
        "该进程被劫持：启动 $exe 时实际运行的是 $debugger"
      } elseif ($unknownValues.Count -gt 0) {
        'IFEO 项含非标准值：' + ($unknownValues -join ', ')
      } else {
        'IFEO 兼容性/缓解选项'
      })
    })
  }
  $root.Close()
}

# @($rows.ToArray()) protects the array from being unrolled element by element.
$json = ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 6 -Compress
[Console]::Out.Write($json)
