# svc.ps1 - enumerate Windows services (L3 registration point).
# Read-only. One JSON array on stdout.
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$rows = New-Object System.Collections.Generic.List[object]
foreach ($s in (Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
  $rows.Add([ordered]@{
    source      = 'svc'
    kind        = 'service'
    name        = $s.Name
    displayName = $s.DisplayName
    state       = [string]$s.State
    startMode   = [string]$s.StartMode
    path        = [string]$s.PathName
    logon       = [string]$s.StartName
    acceptStop  = [bool]$s.AcceptStop
    description = [string]$s.Description
  })
}

$json = ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 4 -Compress
[Console]::Out.Write($json)
