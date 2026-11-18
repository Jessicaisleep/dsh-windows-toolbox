# driver.ps1 - enumerate PnP driver packages and their bound devices (L1).
#
# Why the registry instead of `pnputil /enum-drivers`:
#   pnputil localises its field labels ("发布名称:" / "原始名称:" / "类 GUID:"),
#   and on a zh-CN console the labels that PowerShell captures come out mangled
#   by the OEM code page, so any label-based parse silently matches nothing and
#   reports "0 driver packages". Verified on this machine 2026-11-17:
#   `cmd /c chcp 65001 && pnputil /enum-drivers` still yields "Class Name: ��չ".
#   The registry has no such problem, is readable unelevated, and holds strictly
#   more: it is the same store pnputil reads, plus StatusFlags/SignerScore.
#
# Two views, deliberately kept apart:
#   * packages - HKLM\SYSTEM\DriverDatabase\DriverPackages, one row per driver
#                package in the store. Several devices can share one package, and
#                a package can sit there bound to nothing.
#   * devices  - Win32_PnPSignedDriver, one row per *device instance*: which
#                driver is bound to which hardware right now.
#   The panel lists packages; devices are joined in by inf name.
#
# Read-only.
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ---- 1. driver packages (registry store) ----
# DriverInfFiles maps a logical inf name (oemNN.inf, or a Microsoft in-box name
# like acpi.inf) to the real package key under DriverPackages. The oemNN.inf
# names are exactly what Win32_PnPSignedDriver reports as InfName, so this map is
# also the join key back to devices.
$infRoot = 'HKLM:\SYSTEM\DriverDatabase\DriverInfFiles'
$pkgRoot = 'HKLM:\SYSTEM\DriverDatabase\DriverPackages'

$logicalToPackage = @{}
if (Test-Path -LiteralPath $infRoot) {
  foreach ($k in (Get-ChildItem -LiteralPath $infRoot -ErrorAction SilentlyContinue)) {
    $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
    if ($null -eq $p) { continue }
    $target = [string]$p.Active
    if (-not $target) {
      $target = [string]$p.'(default)'
    }
    if ($target) { $logicalToPackage[$k.PSChildName] = $target }
  }
}

# Reverse it so a package key can report the oemNN.inf name users actually see.
$packageToLogical = @{}
foreach ($kv in $logicalToPackage.GetEnumerator()) {
  if (-not $packageToLogical.ContainsKey($kv.Value)) { $packageToLogical[$kv.Value] = $kv.Key }
}

$packages = New-Object System.Collections.Generic.List[object]
if (Test-Path -LiteralPath $pkgRoot) {
  foreach ($k in (Get-ChildItem -LiteralPath $pkgRoot -ErrorAction SilentlyContinue)) {
    $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
    if ($null -eq $p) { continue }
    $key      = $k.PSChildName                       # e.g. unifhid.inf_amd64_ba68...
    $infName  = [string]$p.'(default)'               # e.g. unifhid.inf
    $logical  = [string]$packageToLogical[$key]      # e.g. oem10.inf (may be empty)
    if (-not $infName) { $infName = ($key -replace '_[^_]+$', '') }

    # Version is a driver date/time encoded byte-wise; only the raw blob is
    # reliably available here, so it is left "" rather than guessed at. The real
    # version string comes from the bound device rows.
    $statusFlags = 0
    if ($null -ne $p.StatusFlags) { $statusFlags = [int]$p.StatusFlags }

    # A third-party (oem*.inf) package is the only kind that can be uninstalled
    # with pnputil /delete-driver; in-box Microsoft .inf packages cannot.
    $thirdParty = ($logical -like 'oem*.inf')

    $packages.Add([ordered]@{
      source      = 'drv'
      kind        = 'driverpackage'
      name        = $(if ($logical) { $logical } else { $infName })
      infName     = $infName
      publishedName = $logical
      packageKey  = $key
      provider    = [string]$p.Provider
      signerScore = [string]$p.SignerScore
      statusFlags = $statusFlags
      thirdParty  = $thirdParty
      version     = ''
      state       = 'installed'
      path        = "HKLM\SYSTEM\DriverDatabase\DriverPackages\$key"
    })
  }
}

# ---- 2. bound devices ----
$devices = New-Object System.Collections.Generic.List[object]
foreach ($d in (Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue)) {
  $devices.Add([ordered]@{
    source       = 'drv'
    kind         = 'driverdevice'
    name         = [string]$d.DeviceName
    deviceId     = [string]$d.DeviceID
    infName      = [string]$d.InfName
    version      = [string]$d.DriverVersion
    provider     = [string]$d.DriverProviderName
    date         = [string]$d.DriverDate
    manufacturer = [string]$d.Manufacturer
    deviceClass  = [string]$d.DeviceClass
    signed       = $true   # Win32_PnPSignedDriver only lists signed drivers
  })
}

# Fold the device-side version/provider back onto packages: a package with no
# bound device keeps version "" and that is meaningful (it is an orphan).
$byInf = @{}
foreach ($dv in $devices) {
  $n = [string]$dv.infName
  if (-not $n) { continue }
  if (-not $byInf.ContainsKey($n)) { $byInf[$n] = $dv }
}
foreach ($pk in $packages) {
  $logical = [string]$pk.publishedName
  $dev = $null
  if ($logical -and $byInf.ContainsKey($logical)) { $dev = $byInf[$logical] }
  if ($null -eq $dev -and $byInf.ContainsKey([string]$pk.infName)) { $dev = $byInf[[string]$pk.infName] }
  if ($dev) {
    $pk.version  = [string]$dev.version
    $pk.bound    = $true
  } else {
    $pk.bound    = $false
    $pk.state    = 'unbound'
  }
}

$payload = [ordered]@{
  packages = @($packages.ToArray())
  devices  = @($devices.ToArray())
  # Kept so a future maintainer can tell a real "no third-party drivers" machine
  # from a silent parse failure.
  oemCount = @($logicalToPackage.Keys | Where-Object { $_ -like 'oem*.inf' }).Count
}
$json = ConvertTo-Json -InputObject $payload -Depth 4 -Compress
[Console]::Out.Write($json)
