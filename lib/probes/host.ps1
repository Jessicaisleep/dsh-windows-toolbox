# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

# host.ps1 - machine-level facts the panel header shows.
#
# Deliberately tiny and non-throwing: if any single fact cannot be read, it comes
# back empty rather than failing the whole call. The panel works without this
# probe, so nothing here is load-bearing.

$ErrorActionPreference = 'SilentlyContinue'

$elevated = $false
try {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

$os = ''
try {
  $v = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
  $os = ('{0} (build {1})' -f $v.Caption, $v.BuildNumber).Trim()
} catch { }

# Every string below is forced through [string] so ConvertTo-Json never sees a
# $null that would drop the key entirely.
$out = [ordered]@{
  elevated     = [bool]$elevated
  user         = [string]$env:USERNAME
  domain       = [string]$env:USERDOMAIN
  os           = [string]$os
  psMajor      = [int]$PSVersionTable.PSVersion.Major
  psEdition    = [string]$PSVersionTable.PSEdition
  is64Bit      = [bool][Environment]::Is64BitOperatingSystem
  processor    = [string]$env:PROCESSOR_ARCHITECTURE
  machine      = [string]$env:COMPUTERNAME
}

ConvertTo-Json -InputObject $out -Depth 3 -Compress
