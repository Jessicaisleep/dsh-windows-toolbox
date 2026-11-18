# appx.ps1 - enumerate installed AppX / MSIX packages (L2 registration point).
#
# THE TRAP THIS FILE EXISTS TO AVOID
# ----------------------------------
# Under PowerShell 7 the Appx module fails to load:
#   在模块 'Appx' 中找到了 'Get-AppxPackage' 命令，但由于以下错误而无法加载该模块:
#   [Operation is not supported on this platform. (0x80131539)]
# and Get-AppxPackage then returns an EMPTY list without throwing. That silences
# into "this machine has no AppX packages", which is wrong: on this machine the
# real count is 100. So we never trust a bare Get-AppxPackage under PS7.
#
# Strategy, in order:
#   1. Try the WinPS compatibility bridge: Import-Module Appx -UseWindowsPowerShell.
#      Objects arrive DESERIALIZED, so PackageUserInformation and friends lose
#      their methods and Version becomes a string - read every field defensively.
#   2. If the bridge fails, re-run this same script under powershell.exe 5.1.
#   3. If that also fails, fall back to a registry-only inventory so the panel can
#      at least say "N packages registered" instead of lying with zero.
param(
  [string]$ParamFile,
  [switch]$NativeOnly
)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
#
# This line MUST come after param(). Four earlier probes had it before the param
# block, which silently turned param() into a command name: PowerShell parsed it
# as a call to a cmdlet called "param" and printed
#   术语 'param' 不会被识别为 cmdlet、函数、脚本文件或可执行程序的名称。
# to stderr while still running the body. Node's parseJson() skips the leading
# noise, so the probe "worked" and the breakage only showed up as the -NativeOnly
# switch being unbound (the 5.1 fallback in Get-AppxRows was dead code).
# Rule: param() is the first statement; no executable statement may precede it.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

function Read-ParamFile([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return @{} }
  try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return @{} }
}

function Get-AppxRows {
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($a in (Get-AppxPackage -ErrorAction SilentlyContinue)) {
    $ver = ''
    try { $ver = [string]$a.Version } catch { }
    $pub = ''
    try { $pub = [string]$a.Publisher } catch { }
    $loc = ''
    try { $loc = [string]$a.InstallLocation } catch { }
    $fam = ''
    try { $fam = [string]$a.PackageFamilyName } catch { }
    $full = ''
    try { $full = [string]$a.PackageFullName } catch { }

    $nonRemovable = $false
    try { $nonRemovable = [bool]$a.NonRemovable } catch { }

    $isFramework = $false
    try { $isFramework = [bool]$a.IsFramework } catch { }

    $rows.Add([ordered]@{
      source       = 'appx'
      kind         = 'appx'
      name         = [string]$a.Name
      state        = 'installed'
      path         = $loc
      version      = $ver
      publisher    = $pub
      family       = $fam
      fullName     = $full
      nonRemovable = $nonRemovable
      isFramework  = $isFramework
      signatureKind= [string]$a.SignatureKind
      arch         = [string]$a.Architecture
    })
  }
  # The leading comma matters: without it PowerShell ENUMERATES the List on
  # return, so the caller receives a bare array (or, with exactly one package, a
  # single OrderedDictionary) and every later .ToArray() dies with
  # "方法调用失败，因为 [System.Collections.Specialized.OrderedDictionary]
  #  不包含名为 'ToArray' 的方法".
  return , $rows
}

# ---- step 1: enumerate in THIS host ----
#
# -NativeOnly means "you are the Windows PowerShell 5.1 child; enumerate natively,
# never bridge and never respawn". So the bridge attempt is what -NativeOnly
# withholds — NOT the enumeration itself. Getting this backwards leaves the child
# with no rows, and it then falls through to the registry-only fallback, so the
# expensive path never actually enumerates anything.
$bridged = $false
$rows = $null

if (-not $NativeOnly -and $PSVersionTable.PSVersion.Major -ge 7) {
  # A bare Import-Module check is not enough: the command can be *present* and
  # still return nothing. We import, then verify by counting real objects.
  Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
  $probe = @(Get-AppxPackage -ErrorAction SilentlyContinue)
  if ($probe.Count -gt 0) {
    $bridged = $true
    $rows = Get-AppxRows
  }
} else {
  # Native host (5.1 child, or a 5.1 parent): a plain call works. Mark it as
  # enumerated too — the packages were really read; `bridged` only means "this
  # process needed the compatibility bridge", and leaving it false here labelled
  # a genuine 100-package enumeration as 'registry-only' (measured 2026-11-17).
  $probe = @(Get-AppxPackage -ErrorAction SilentlyContinue)
  if ($probe.Count -gt 0) {
    $bridged = $true
    $rows = Get-AppxRows
  }
}

# ---- step 2: re-run under Windows PowerShell 5.1 ----
#
# `-not $NativeOnly` is load-bearing, not decoration. The child is started WITH
# -NativeOnly, so in the child step 1 runs natively and this branch must never
# trigger a second spawn. Without the guard, a child that ends up with no rows
# spawns another child, forever: a fork bomb of powershell.exe processes,
# observed 2026-11-17 (the call never returned and had to be killed). It stayed
# hidden while param() was broken, because the switch was never bound and this
# whole branch was therefore unreachable.
if ($null -eq $rows -and -not $NativeOnly) {
  $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (Test-Path -LiteralPath $ps51) {
    $self = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($self)) {
      # $PSCommandPath is empty when the script was dot-sourced; fall back to the
      # invocation path we were started with.
      $self = $MyInvocation.MyCommand.Path
    }
    if (-not [string]::IsNullOrWhiteSpace($self)) {
      $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $self, '-NativeOnly')
      if (-not [string]::IsNullOrWhiteSpace($ParamFile)) { $argList += @('-ParamFile', $ParamFile) }
      $child = & $ps51 @argList 2>$null
      if (-not [string]::IsNullOrWhiteSpace($child)) {
        try {
          $parsed = $child | ConvertFrom-Json
          if ($parsed -and $parsed.rows) { $rows = $parsed.rows; $bridged = $true }
        } catch { }
      }
    }
  }
}

# ---- step 3: registry-only inventory (honest degraded mode) ----
if ($null -eq $rows) {
  $rows = New-Object System.Collections.Generic.List[object]
  $store = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications'
  if (Test-Path -LiteralPath $store) {
    foreach ($k in (Get-ChildItem -LiteralPath $store -ErrorAction SilentlyContinue)) {
      $rows.Add([ordered]@{
        source       = 'appx'
        kind         = 'appx'
        name         = [string]$k.PSChildName
        state        = 'installed'
        path         = ''
        version      = ''
        publisher    = ''
        family       = ''
        fullName     = [string]$k.PSChildName
        nonRemovable = $false
        isFramework  = $false
        signatureKind= ''
        arch         = ''
      })
    }
  }
}

# ---- report ----
$mode = if ($bridged) { 'enumerated' } elseif ($rows.Count -gt 0) { 'registry-only' } else { 'empty' }
$payload = [ordered]@{
  rows  = @($rows.ToArray())
  mode  = $mode
  host  = "$($PSVersionTable.PSVersion)"
  count = $rows.Count
}
$json = ConvertTo-Json -InputObject $payload -Depth 4 -Compress
[Console]::Out.Write($json)
