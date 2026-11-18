# fileexts.ps1 - enumerate per-user file-type associations (FileExts).
# Read-only. One JSON array on stdout.
#
# WHAT THIS SHOWS: HKCU\...\Explorer\FileExts\<ext> is where Windows remembers
# "which program opens .pdf for THIS user". Three subkeys carry that:
#   UserChoice        { Progid, Hash }  - the default handler; Hash is an HMAC
#                                        over progid+user+sid, so an edit that
#                                        does not recompute it is silently
#                                        reverted by Windows (see docs/SCOPE.md)
#   OpenWithProgids   a list of alternative ProgIds for "打开方式"
#   OpenWithList      a list of alternative executables for "打开方式"
#
# MEASURED 2026-11-17, this machine: 520 extension subkeys, 163 with a UserChoice
# ProgId, 224 with OpenWithProgids, 61 with OpenWithList, 288 with at least one
# association. 352 UserChoice subkeys exist but hold NO values at all - empty
# shells left behind by uninstalled apps. They are reported as state=empty
# instead of being hidden, because that is exactly the "为什么我的关联丢了"
# case a user opens this panel to diagnose.
#
# PERFORMANCE - the reason this file uses Microsoft.Win32.Registry and not the
# PowerShell provider (all measured on this machine):
#   Get-ItemProperty -LiteralPath, 3 calls per extension   34 210 ms   (unusable)
#   Get-ChildItem -Recurse over the whole tree                507 ms   1545 keys
#   Registry.OpenSubKey per extension + per subkey             88 ms
#
# NO WILDCARD PATHS. Every extension is opened by its literal name. A path like
# "...\FileExts\*" would send the registry provider through a wildcard expansion
# over the whole tree (the sibling plugin measured 7443 keys and >120 s on
# Classes\*\shellex); -LiteralPath everywhere avoids that class of bug entirely.
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName Microsoft.Win32.Registry -ErrorAction SilentlyContinue

$BASE = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'

# Resolve "<ProgId>\shell\open\command" so the panel can say WHICH program opens
# the file, not just which ProgId string is stored. 79 distinct ProgIds for 163
# associations; resolving all of them cost 9 ms.
$commandCache = @{}

function ProgIdCommand([string]$progId) {
  if (-not $progId) { return '' }
  if ($commandCache.ContainsKey($progId)) { return $commandCache[$progId] }
  $cmd = ''
  $k = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("$progId\shell\open\command")
  if ($null -ne $k) {
    $v = $k.GetValue('')
    if ($null -ne $v) { $cmd = [string]$v }
    $k.Close()
  }
  $commandCache[$progId] = $cmd
  return $cmd
}

$rows = New-Object System.Collections.Generic.List[object]

$root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($BASE)
if ($null -eq $root) {
  # A brand-new profile can genuinely have no FileExts key. Empty list, not an
  # error - the live test only requires a parseable document from the probe, and
  # this branch would otherwise make the whole source look broken.
  [Console]::Out.Write('[]')
  return
}

foreach ($ext in $root.GetSubKeyNames()) {
  $progId = ''
  $hash = ''
  $hasChoice = $false

  $uc = $root.OpenSubKey("$ext\UserChoice")
  if ($null -ne $uc) {
    # The value name is spelled 'Progid' (lowercase d) on this machine. Registry
    # value names are case-insensitive but the .NET GetValue call is not, so both
    # spellings are tried.
    $v = $uc.GetValue('Progid')
    if ($null -eq $v) { $v = $uc.GetValue('ProgId') }
    if ($null -ne $v) { $progId = [string]$v }
    $h = $uc.GetValue('Hash')
    if ($null -ne $h) { $hash = [string]$h }
    $hasChoice = $true
    $uc.Close()
  }

  $withProgids = @()
  $owp = $root.OpenSubKey("$ext\OpenWithProgids")
  if ($null -ne $owp) {
    $withProgids = @($owp.GetValueNames() | Where-Object { $_ })
    $owp.Close()
  }

  $withList = @()
  $owl = $root.OpenSubKey("$ext\OpenWithList")
  if ($null -ne $owl) {
    # OpenWithList stores (a) (b) (c) ... plus MRUList; the letters are not
    # executable names by themselves, so only the entry count is reported.
    $withList = @($owl.GetValueNames() | Where-Object { $_ -ne 'MRUList' })
    $owl.Close()
  }

  $command = if ($progId) { ProgIdCommand $progId } else { '' }

  # Four honest states, because collapsing them hides the bug the user came for:
  #   userchoice  - a default handler is set (this is a real association)
  #   openwith    - no default, but "打开方式" alternatives are registered
  #   empty       - the UserChoice key exists with no values (卸载残留空壳)
  #   none        - no association of any kind
  if ($progId) {
    $state = 'userchoice'
  } elseif ($withList.Count -gt 0 -or $withProgids.Count -gt 0) {
    $state = 'openwith'
  } elseif ($hasChoice) {
    $state = 'empty'
  } else {
    $state = 'none'
  }

  $rows.Add([ordered]@{
    source       = 'fileexts'
    kind         = 'fileext'
    keyPath      = $ext
    name         = $ext
    displayName  = $ext
    state        = $state
    # "enabled" = a default program is actually associated with this extension.
    enabled      = [bool]$progId
    progId       = $progId
    command      = $command
    path         = $command
    hash         = $hash
    # Windows validates Hash when UserChoice is read. A hash that is missing on a
    # key that has a Progid is a shortcut malware and "default app" tools use; it
    # is also what makes the association un-editable without Windows' help.
    hashPresent  = [bool]$hash
    openWithProgids = $withProgids
    openWithList    = $withList
    hasUserChoice   = $hasChoice
    scope        = 'user'
    view         = 'user'
    description  = $(if ($progId) {
      "默认用 $progId 打开 $ext 文件"
    } elseif ($hasChoice) {
      "$ext 的 UserChoice 键存在但没有任何值（卸载残留）"
    } else {
      "$ext 没有设置默认程序"
    })
  })
}
$root.Close()

# @($rows.ToArray()) protects the array from being unrolled element by element.
$json = ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 6 -Compress
[Console]::Out.Write($json)
