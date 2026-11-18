# firewall.ps1 - enumerate Windows Firewall rules (an L3 registration point).
# Read-only. One JSON array on stdout.
#
# WHY COM AND NOT netsh / Get-NetFirewallRule (all measured on this machine
# 2026-11-17, 542 rules):
#   netsh advfirewall firewall show rule name=all verbose   943 ms, 10251 lines
#                                                            of text to parse
#   Get-NetFirewallRule (NetSecurity module)                PS7: returns 0 rows
#                                                           silently (module not
#                                                           loaded); via
#                                                           powershell.exe:
#                                                           "Access is denied"
#                                                           (Windows error 5) -
#                                                           unusable unelevated
#   HNetCfg.FwPolicy2 COM + $fw.Rules                        44 ms for all 542
# Read-only enumeration needs NO elevation; writing Enabled needs admin (see
# lib/probes/actions.ps1, which refuses up front with needsAdmin=true).
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# Windows stores a rule's display name as an INDIRECT resource string for 38 of
# the 542 rules ("@firewallapi.dll,-50327"), which is unreadable in a panel. The
# COM object resolves Description and Grouping itself but NOT Name, so those 38
# are resolved here through SHLoadIndirectString.
#
# Add-Type costs ~750 ms (measured: -MemberDefinition 748 ms, -TypeDefinition
# 831 ms) - more than the enumeration itself - so it is compiled at most once
# and only when an indirect name actually shows up.
function New-IndirectResolver {
  Add-Type -Namespace WpmFirewall -Name Res -MemberDefinition @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode, SetLastError = false)]
public static extern int SHLoadIndirectString(string pszSource, System.Text.StringBuilder pszOutBuf, int cchOutBuf, System.IntPtr ppvReserved);
'@ -ErrorAction SilentlyContinue
  return { param([string]$s)
    $buf = New-Object System.Text.StringBuilder 512
    $hr = [WpmFirewall.Res]::SHLoadIndirectString($s, $buf, 512, [IntPtr]::Zero)
    if ($hr -eq 0 -and $buf.Length -gt 0) { return $buf.ToString() }
    return $s
  }
}

$PROTO = @{
  1 = 'ICMPv4'; 2 = 'IGMP'; 6 = 'TCP'; 17 = 'UDP'; 41 = 'IPv6'
  47 = 'GRE'; 50 = 'ESP'; 51 = 'AH'; 58 = 'ICMPv6'; 255 = 'Any'; 256 = 'Any'
}

function ProtocolText([int]$p) {
  if ($PROTO.ContainsKey($p)) { return $PROTO[$p] }
  return [string]$p
}

# A rule's Profile bitmask: 1 = domain, 2 = private, 4 = public, 0x7FFFFFFF = any.
function ProfileText([long]$p) {
  if ($p -eq 2147483647 -or $p -eq 0) { return '全部' }
  $parts = @()
  if ($p -band 1) { $parts += '域' }
  if ($p -band 2) { $parts += '专用' }
  if ($p -band 4) { $parts += '公用' }
  if ($parts.Count -eq 0) { return [string]$p }
  return ($parts -join '/')
}

# Collect the raw COM values first: a single pass over $fw.Rules is the only way
# to keep this fast, and the name has to be resolved before the row key is built.
$raw = New-Object System.Collections.Generic.List[object]
$needsResolve = New-Object System.Collections.Generic.HashSet[string]

try {
  $fw = New-Object -ComObject HNetCfg.FwPolicy2
} catch {
  # No firewall service (or a stripped-down SKU): report an empty list rather
  # than a broken JSON document.
  [Console]::Out.Write('[]')
  return
}

foreach ($r in $fw.Rules) {
  $nm = [string]$r.Name
  if ($nm.StartsWith('@')) { [void]$needsResolve.Add($nm) }
  $raw.Add([ordered]@{
    name        = $nm
    enabled     = [bool]$r.Enabled
    direction   = [int]$r.Direction            # 1 = in, 2 = out
    action      = [int]$r.Action               # 1 = allow, 2 = block
    protocol    = [int]$r.Protocol
    localPorts  = [string]$r.LocalPorts
    remotePorts = [string]$r.RemotePorts
    application = [string]$r.ApplicationName
    serviceName = [string]$r.serviceName
    profiles    = [long]$r.Profiles
    grouping    = [string]$r.Grouping
    description = [string]$r.Description
  })
}

# Resolve indirect names once per distinct string.
$resolved = @{}
if ($needsResolve.Count -gt 0) {
  $resolver = New-IndirectResolver
  foreach ($s in $needsResolve) {
    $v = & $resolver $s
    # If shlwapi refused (missing resource, or Add-Type failed) keep the raw
    # indirect string: a visible "@firewallapi.dll,-50327" is bad, but an empty
    # name would be worse - it would collide with every other unresolved rule.
    if (-not $v) { $v = $s }
    $resolved[$s] = $v
  }
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($x in $raw) {
  $shown = if ($resolved.ContainsKey($x.name)) { $resolved[$x.name] } else { $x.name }

  # 542 rules carry only 324 distinct Names; name+direction leaves 131 groups
  # still colliding, name+direction+profiles leaves 63. This nine-tuple is the
  # smallest combination that is unique for all 542 (0 collisions, measured) and
  # is what the write half uses to find the rule again.
  $key = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}' -f `
    $x.name, $x.direction, $x.action, $x.protocol, $x.localPorts, `
    $x.remotePorts, $x.application, $x.profiles, $x.serviceName

  $rows.Add([ordered]@{
    source      = 'firewall'
    kind        = 'fwrule'
    keyPath     = $key
    name        = $shown
    displayName = $shown
    state       = $(if ($x.enabled) { 'enabled' } else { 'disabled' })
    enabled     = $x.enabled
    direction   = $(if ($x.direction -eq 1) { 'in' } else { 'out' })
    action      = $(if ($x.action -eq 1) { 'allow' } else { 'block' })
    protocol    = (ProtocolText $x.protocol)
    profiles    = (ProfileText $x.profiles)
    localPorts  = $x.localPorts
    remotePorts = $x.remotePorts
    application = $x.application
    path        = $x.application
    serviceName = $x.serviceName
    group       = $x.grouping
    description = $x.description
    indirect    = $x.name.StartsWith('@')
  })
}

# @($rows.ToArray()) instead of $rows: a bare List enumerates back into the
# pipeline and ConvertTo-Json would receive one element per statement.
$json = ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 6 -Compress
[Console]::Out.Write($json)
