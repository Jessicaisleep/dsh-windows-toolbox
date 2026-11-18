# program.ps1 - enumerate installed programs from the three Uninstall hives (L2).
#
# Note on the hotfix/appcomponent split: an Uninstall key with no DisplayName is
# a component/hotfix stub, not a program the user recognizes. We keep those out
# of the program list but still count them, because the count is the honest
# answer to "how many registry uninstall entries exist".
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$roots = @(
  @{ scope = 'machine';  view = '64'; path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
  @{ scope = 'machine';  view = '32'; path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
  @{ scope = 'user';     view = '64'; path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
)

$rows = New-Object System.Collections.Generic.List[object]
$stubs = 0

foreach ($root in $roots) {
  if (-not (Test-Path -LiteralPath $root.path)) { continue }
  foreach ($key in (Get-ChildItem -LiteralPath $root.path -ErrorAction SilentlyContinue)) {
    $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
    if ($null -eq $props) { continue }
    if (-not $props.DisplayName) { $stubs++; continue }

    $sizeKb = $null
    if ($props.EstimatedSize) {
      try { $sizeKb = [int64]$props.EstimatedSize } catch { }
    }

    $rows.Add([ordered]@{
      source          = 'uninst'
      kind            = 'program'
      name            = [string]$props.DisplayName
      state           = 'installed'
      path            = [string]$props.DisplayIcon
      version         = [string]$props.DisplayVersion
      publisher       = [string]$props.Publisher
      installLocation = [string]$props.InstallLocation
      uninstall       = [string]$props.UninstallString
      quietUninstall  = [string]$props.QuietUninstallString
      modify          = [string]$props.ModifyPath
      productCode     = [string]$key.PSChildName
      scope           = $root.scope
      view            = $root.view
      keyPath         = ($key.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')
      installDate     = [string]$props.InstallDate
      sizeKb          = $sizeKb
      systemComponent = [string]$props.SystemComponent
    })
  }
}

$payload = [ordered]@{ rows = @($rows.ToArray()); stubCount = $stubs }
$json = ConvertTo-Json -InputObject $payload -Depth 4 -Compress
[Console]::Out.Write($json)
