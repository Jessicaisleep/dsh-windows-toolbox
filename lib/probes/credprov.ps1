# credprov.ps1 - enumerate registered credential providers.
# Read-only. One JSON array on stdout.
#
# WHAT THIS SHOWS: HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\
# Authentication\Credential Providers holds one subkey per provider - the
# components that draw a tile on the Windows sign-in screen (password, PIN,
# picture password, smartcard, Windows Hello face/fingerprint ...). Each subkey
# is named by CLSID, its (default) value is the display name, and the CLSID's
# InprocServer32 points at the implementing DLL.
#
# WHY IT IS WORTH A COLUMN: this is a credential-capture surface. A provider DLL
# that is not signed by Microsoft, is not in System32, or lives in a user-writable
# directory can read the password typed at the lock screen. Also, the LOGON
# experience silently skips a provider whose DLL is missing, which is the usual
# cause of "PIN 突然没了 / 只能用密码登录".
#
# MEASURED 2026-11-17, unelevated, via Microsoft.Win32.Registry: 22 subkeys,
# all 22 with a non-empty display name, all 22 with a resolvable InprocServer32
# DLL, 10 ms total. No elevation needed to read; writing needs admin (and is not
# offered - see docs/SCOPE.md).
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName Microsoft.Win32.Registry -ErrorAction SilentlyContinue

$BASE = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers'

# Well-known provider CLSIDs and what removing them would actually do. This is a
# closed, tiny set (22 providers on a stock machine); anything NOT in this list
# is either a Windows feature added after this list was written or a third party.
$KNOWN = @{
  '{6f45dc1e-5384-457a-bc13-2cd81b0d28ed}' = 'PIN 登录（Windows Hello）'
  '{8af662bf-65a0-4d0a-a540-a338a999d36f}' = '指纹登录（Windows Hello）'
  '{b1dcc9dd-5262-4d8d-a863-c897e6d979b9}' = '密码登录（系统内置）'
  '{2135f72a-90b5-4ed3-a7f1-8bb705ac276a}' = '图片密码登录'
  '{1b283861-754f-4022-ad47-a5eaaa618894}' = '智能卡读卡器选择'
  '{1ee7337f-85ac-45e2-a23c-37c753209769}' = '智能卡 WinRT 提供程序'
  '{25cbb996-92ed-457e-b28c-4774084bd562}' = '通用凭据提供程序（内置）'
  '{27fbdb57-b613-4af2-9d7e-4fa7a66c21ad}' = '受信任信号提供程序'
  '{01a30791-40ae-4653-ab2e-fd210019ae88}' = '自动重新部署（企业环境）'
  '{3dd6bec0-8193-4ffe-ae25-e08e39ea4063}' = '云域凭据提供程序'
  '{cb82ea12-9f71-446d-89e1-8d0924e1256e}' = 'PIN 登录（旧版备用）'
  '{d6886603-9d2f-4eb2-b667-1971041fa96b}' = 'NGC 提供程序（Windows Hello 容器）'
  '{877e4351-6f6a-4e39-b56d-e3f0b3a3b0cb}' = '证书登录'
}

$rows = New-Object System.Collections.Generic.List[object]

$root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($BASE)
if ($null -eq $root) {
  [Console]::Out.Write('[]')
  return
}

foreach ($clsid in $root.GetSubKeyNames()) {
  $k = $root.OpenSubKey($clsid)
  if ($null -eq $k) { continue }
  $disp = ''
  $v = $k.GetValue('')
  if ($null -ne $v) { $disp = [string]$v }
  $k.Close()

  # Resolve the implementing DLL. InprocServer32 lives under HKCR\CLSID - i.e.
  # HKLM\SOFTWARE\Classes\CLSID, the machine-wide merge - so an HKLM-only read is
  # correct here and needs no per-user hive.
  $dll = ''
  $ip = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("CLSID\$clsid\InprocServer32")
  if ($null -ne $ip) {
    $dv = $ip.GetValue('')
    if ($null -ne $dv) { $dll = [string]$dv }
    $ip.Close()
  }
  # %SystemRoot% style paths come back with the variable already expanded from
  # InprocServer32, but an unexpanded one would break the "is it in Windows"
  # check below, so expand defensively.
  if ($dll -like '%*%') {
    $dll = [Environment]::ExpandEnvironmentVariables($dll)
  }

  $label = $KNOWN[$clsid.ToLower()]
  $name = if ($disp) { $disp } else { $clsid }

  # Where risk lives: a provider whose DLL is outside Windows, or whose key does
  # not resolve to a DLL at all. Both are worth a look - not proof of anything.
  $lower = $dll.ToLower()
  $inSystem = ($lower -and ($lower.StartsWith($env:SystemRoot.ToLower()) -or $lower.Contains('\system32\')))
  $missing = $false
  if ($dll) { $missing = -not (Test-Path -LiteralPath $dll -PathType Leaf) }

  $rows.Add([ordered]@{
    source      = 'credprov'
    kind        = 'credprov'
    # CLSID is the identity - it is the key name and is unique by construction.
    keyPath     = $clsid
    clsid       = $clsid
    name        = $name
    displayName = $disp
    # A registered provider is "on": Windows offers it at sign-in. There is no
    # per-provider enable flag in the registry.
    state       = 'registered'
    enabled     = $true
    dll         = $dll
    path        = $dll
    inSystemDir = $inSystem
    dllMissing  = $missing
    known       = [bool]$label
    purpose     = $(if ($label) { $label } else { '' })
    scope       = 'machine'
    view        = '64'
    description = $(if ($label) {
      "$label（$clsid）"
    } elseif (-not $dll) {
      "注册表里没有对应 DLL 的凭据提供程序：$clsid"
    } elseif (-not $inSystem) {
      "第三方凭据提供程序：$clsid"
    } else {
      "登录界面上的一个凭据提供程序：$clsid"
    })
  })
}
$root.Close()

# @($rows.ToArray()) protects the array from being unrolled element by element.
$json = ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 6 -Compress
[Console]::Out.Write($json)
