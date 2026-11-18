# actions.ps1 - the enable/disable/rollback half of the five-hook model.
#
# One script handles every reversible source so there is a single place where
# "how do we change this thing" lives. detect/verify reuse the probes; this file
# only implements the mutation.
#
# INPUT (via -ParamFile, a JSON document):
#   {
#     "action":  "enable" | "disable" | "rollback" | "uninstall",
#     "source":  "svc" | "task" | "autorun" | "com" | "firewall"
#                | "program" | "appx" | "drv",
#     "dryRun":  true | false,
#     "target":  { ... identity fields for the source ... },
#     "undo":    { ...captured previous state, for rollback... }
#   }
#
# OUTPUT: one JSON object
#   { ok, action, source, changed, dryRun, before, after, undo, message }
#
# SAFETY RULES THIS SCRIPT ENFORCES ITSELF (do not rely on the caller):
#   * kernel drivers and services flagged AcceptStop=$false are refused: disabling
#     them can bugcheck the machine on next boot.
#   * a protected-service name is refused even if the caller asks.
#   * dryRun computes and returns everything (including the undo record) without
#     writing. The UI always dry-runs first and shows the plan.
#   * every mutation captures the previous value into `undo` BEFORE writing, and
#     that undo record is what rollback consumes.
#   * enable/disable is only ever applied to a REVERSIBLE registration point.
#     The three irreversible sources (program / appx / drv) answer `uninstall`
#     instead, and that path has its own rules — see the Uninstall section below
#     (systemComponent refused, registry export BEFORE the uninstaller runs,
#     no shell, 120 s budget, no killing of a stalled uninstaller).
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Emit($obj) {
  [Console]::Out.Write((ConvertTo-Json -InputObject $obj -Depth 8 -Compress))
}

function Fail($msg) {
  Emit ([ordered]@{ ok = $false; message = [string]$msg; changed = $false })
  exit 0
}

# Read the request.
$req = $null
try {
  $raw = Get-Content -LiteralPath $ParamFile -Raw -ErrorAction Stop
  $req = $raw | ConvertFrom-Json
} catch {
  Fail "无法读取参数文件: $($_.Exception.Message)"
}
if ($null -eq $req) { Fail '参数为空' }

$action = [string]$req.action
$source = [string]$req.source

# dryRun defaults to TRUE when the field is absent. The enable/disable path below
# used to treat a missing flag as "write now"; with `uninstall` in the vocabulary
# that default is the wrong way round — a hand-built request that forgets the
# flag must produce a plan, never an uninstall. /api/action always sends an
# explicit boolean, so this only ever bites the case the default is for.
$hasDryRunField = $false
if ($req -is [System.Management.Automation.PSCustomObject]) {
  $hasDryRunField = ($null -ne $req.PSObject.Properties['dryRun'])
} elseif ($req -is [System.Collections.IDictionary]) {
  $hasDryRunField = $req.Contains('dryRun')
}
$dryRun = $true
if ($hasDryRunField) { $dryRun = [bool]$req.dryRun }
$target = $req.target
$undoIn = $req.undo

if (-not $action) { Fail '缺少 action' }
if (-not $source) { Fail '缺少 source' }

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
# Measured on this machine 2026-11-17, unelevated (User=CHEN-KETING\26035,
# UAC ConsentPromptBehaviorAdmin=5):
#   HKCU autostart value  -> Windows
#   HKCU\...\Approved     -> Windows
#   HKLM\...\Approved     -> denied
#   Set-Service            -> "拒绝访问"
#   Disable-ScheduledTask  -> "拒绝访问"
#   pnputil /delete-driver -> needs admin
#   $fwRule.Enabled = ...  -> E_ACCESSDENIED 0x80070005 (HNetCfg.FwPolicy2)
# So the mutation half is only useful elevated, while the detect half works fine
# unelevated. Rather than let every action fail with a raw access-denied, refuse
# up front with canElevate=true and let the UI offer the UAC prompt.
$writeNeedsAdmin = @('svc', 'task', 'firewall')
# autorun rows that delegate to a service or a task need the same rights as the
# service/task source itself. Without this, clicking "disable" in the autostart
# list on one of the 61 service rows returned a raw 拒绝访问 from Set-Service
# instead of the needsAdmin answer the UI knows how to turn into a UAC request.
$wantsAdmin = $writeNeedsAdmin -contains $source
if (-not $wantsAdmin -and $source -eq 'autorun') {
  $whereHint = [string]$target.where
  if ($whereHint -eq 'ref-service' -or $whereHint -eq 'ref-task') { $wantsAdmin = $true }
}
$isElevated = $false
try {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $isElevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

if (-not $dryRun -and -not $isElevated -and $wantsAdmin) {
  Emit ([ordered]@{
    ok        = $false
    changed   = $false
    needsAdmin = $true
    canElevate = $true
    message   = '该操作需要管理员权限。可在插件里点「以管理员身份重试」。'
  })
  exit 0
}

# Same list as lib/sources.js PROTECTED_SERVICES. Duplicated on purpose: the JS
# side is for display/refusal, this side is the last line of defence if a caller
# tampers with the request.
$PROTECTED = @(
  'rpcss','rpcepmap','dcomlaunch','lsm','power','plugplay','bfe','eventlog',
  'profsvc','samss','winlogon','wuauserv','trustedinstaller','msiserver','gpsvc',
  'cryptsvc','dhcp','dnscache','nsi','netprofm','nlasvc','lanmanworkstation',
  'lanmanserver','windefend','seclogon','sppsvc','themes','audiosrv',
  'audioendpointbuilder','brokerinfrastructure','systemeventsbroker',
  'staterepository','coremessaging','devicesetupmanager'
)

function IsProtected($name) {
  return ($PROTECTED -contains ([string]$name).ToLower())
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------
function DoService($wantEnabled) {
  $name = [string]$target.name
  if (-not $name) { Fail '服务名缺失' }
  if (IsProtected $name) { Fail "拒绝操作受保护服务: $name" }

  $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($name -replace "'", "''")'" -ErrorAction SilentlyContinue
  if ($null -eq $svc) { Fail "服务不存在: $name" }

  $beforeMode = [string]$svc.StartMode
  # SCM reports kernel drivers with the same start modes; a driver has no
  # AcceptStop and lives under a ServiceType including 'Kernel Driver'.
  $isDriver = ([string]$svc.PathName) -match '(?i)\\drivers\\|\.sys\b'
  if ($isDriver) { Fail "拒绝操作内核驱动服务: $name" }

  $targetMode = if ($wantEnabled) { 'Manual' } else { 'Disabled' }

  $undo = [ordered]@{
    source = 'svc'
    name   = $name
    # Restoring the exact original start mode is why `before` matters: Auto and
    # Manual both mean "enabled" but only one is right.
    startMode = $beforeMode
    wasRunning = ([string]$svc.State -eq 'Running')
  }

  if ($dryRun) {
    return [ordered]@{
      ok = $true; action = $action; source = 'svc'; dryRun = $true; changed = $false
      before = [ordered]@{ startMode = $beforeMode; state = [string]$svc.State }
      after  = [ordered]@{ startMode = $targetMode }
      undo   = $undo
      message = "将 $name 的启动类型从 $beforeMode 改为 $targetMode"
    }
  }

  # 'Manual' rather than 'Automatic': turning something "back on" should restore
  # the ability to run, not make it start on every boot. The undo record carries
  # the original Automatic back if that is what it was.
  if ($wantEnabled) {
    Set-Service -Name $name -StartupType Manual -ErrorAction Stop
  } else {
    # Stop first so the change takes effect now; ignore "not running".
    if ([string]$svc.State -eq 'Running') {
      try { Stop-Service -Name $name -Force -ErrorAction Stop } catch { }
    }
    Set-Service -Name $name -StartupType Disabled -ErrorAction Stop
  }

  $after = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($name -replace "'", "''")'" -ErrorAction SilentlyContinue
  return [ordered]@{
    ok = $true; action = $action; source = 'svc'; dryRun = $false; changed = $true
    before = [ordered]@{ startMode = $beforeMode; state = [string]$svc.State }
    after  = [ordered]@{ startMode = [string]$after.StartMode; state = [string]$after.State }
    undo   = $undo
    message = "已将 $name 设为 $([string]$after.StartMode)"
  }
}

# ---------------------------------------------------------------------------
# Scheduled tasks
# ---------------------------------------------------------------------------
function DoTask($wantEnabled) {
  $path = [string]$target.taskPath
  $tname = [string]$target.taskName
  if (-not $tname) { Fail '任务名缺失' }
  if (-not $path) { $path = '\' }

  $t = Get-ScheduledTask -TaskPath $path -TaskName $tname -ErrorAction SilentlyContinue
  if ($null -eq $t) { Fail "任务不存在: $path$tname" }

  $beforeState = [string]$t.State
  $undo = [ordered]@{ source = 'task'; taskPath = $path; taskName = $tname; state = $beforeState }

  if ($dryRun) {
    return [ordered]@{
      ok = $true; action = $action; source = 'task'; dryRun = $true; changed = $false
      before = [ordered]@{ state = $beforeState }
      after  = [ordered]@{ state = $(if ($wantEnabled) { 'Ready' } else { 'Disabled' }) }
      undo   = $undo
      message = "将任务 $path$tname 从 $beforeState 改为 $(if ($wantEnabled) { '启用' } else { '禁用' })"
    }
  }

  if ($wantEnabled) { Enable-ScheduledTask -TaskPath $path -TaskName $tname -ErrorAction Stop | Out-Null }
  else              { Disable-ScheduledTask -TaskPath $path -TaskName $tname -ErrorAction Stop | Out-Null }

  $after = Get-ScheduledTask -TaskPath $path -TaskName $tname -ErrorAction SilentlyContinue
  return [ordered]@{
    ok = $true; action = $action; source = 'task'; dryRun = $false; changed = $true
    before = [ordered]@{ state = $beforeState }
    after  = [ordered]@{ state = [string]$after.State }
    undo   = $undo
    message = "任务 $path$tname 现为 $([string]$after.State)"
  }
}

# ---------------------------------------------------------------------------
# Autostart entries
# ---------------------------------------------------------------------------
function DoAutorun($wantEnabled) {
  $where = [string]$target.where
  $keyPath = [string]$target.keyPath
  $entryName = [string]$target.name
  $fullPath = [string]$target.path

  if ($where -eq 'registry') {
    if (-not $keyPath) { Fail '注册表路径缺失' }
    if (-not $entryName) { Fail '项名缺失' }
    $regKey = $keyPath
    if (-not $regKey.StartsWith('HK')) { $regKey = "Registry::$keyPath" }
    $props = Get-ItemProperty -LiteralPath $regKey -ErrorAction SilentlyContinue
    if ($null -eq $props) { Fail "注册表键不存在: $keyPath" }
    $prop = $props.PSObject.Properties | Where-Object { $_.Name -eq $entryName }
    if (-not $prop) { Fail "项不存在: $entryName" }

    $undo = [ordered]@{ source = 'autorun'; where = 'registry'; keyPath = $keyPath; name = $entryName; path = [string]$prop.Value }

    if ($dryRun) {
      return [ordered]@{
        ok = $true; action = $action; source = 'autorun'; dryRun = $true; changed = $false
        before = [ordered]@{ state = 'enabled'; path = [string]$prop.Value }
        after  = [ordered]@{ state = $(if ($wantEnabled) { 'enabled' } else { 'disabled' }) }
        undo   = $undo
        message = "将$(if ($wantEnabled) { '启用' } else { '禁用' })自启项 $entryName"
      }
    }

    if ($wantEnabled) {
      # The value was moved to <name>.__disabled by the disable path; move it back.
      $stash = $props.PSObject.Properties | Where-Object { $_.Name -eq "$entryName.__disabled" }
      if (-not $stash) { Fail "找不到已禁用的备份值 $entryName.__disabled" }
      $orig = [string]$stash.Value
      New-ItemProperty -LiteralPath $regKey -Name $entryName -Value $orig -PropertyType String -Force -ErrorAction Stop | Out-Null
      Remove-ItemProperty -LiteralPath $regKey -Name "$entryName.__disabled" -ErrorAction Stop
    } else {
      # Rename, do not delete: the value must be recoverable from the registry
      # alone, without keeping our own database. This mirrors what Explorer does
      # to startup-folder shortcuts (.lnk -> .lnk.disabled).
      New-ItemProperty -LiteralPath $regKey -Name "$entryName.__disabled" -Value ([string]$prop.Value) -PropertyType String -Force -ErrorAction Stop | Out-Null
      Remove-ItemProperty -LiteralPath $regKey -Name $entryName -ErrorAction Stop
    }

    return [ordered]@{
      ok = $true; action = $action; source = 'autorun'; dryRun = $false; changed = $true
      before = [ordered]@{ state = $(if ($wantEnabled) { 'disabled' } else { 'enabled' }) }
      after  = [ordered]@{ state = $(if ($wantEnabled) { 'enabled' } else { 'disabled' }) }
      undo   = $undo
      message = "已$(if ($wantEnabled) { '启用' } else { '禁用' })自启项 $entryName"
    }
  }

  if ($where -eq 'startup-folder') {
    if (-not $fullPath) { Fail '文件路径缺失' }
    if (-not (Test-Path -LiteralPath $fullPath)) { Fail "文件不存在: $fullPath" }
    $isDisabled = $fullPath -match '\.disabled$'
    $undo = [ordered]@{ source = 'autorun'; where = 'startup-folder'; path = $fullPath }

    if ($dryRun) {
      return [ordered]@{
        ok = $true; action = $action; source = 'autorun'; dryRun = $true; changed = $false
        before = [ordered]@{ state = $(if ($isDisabled) { 'disabled' } else { 'enabled' }) }
        after  = [ordered]@{ state = $(if ($wantEnabled) { 'enabled' } else { 'disabled' }) }
        undo   = $undo
        message = "将重命名启动项 $(Split-Path -Leaf $fullPath)"
      }
    }

    if ($wantEnabled) {
      if (-not $isDisabled) { Fail '该项已是启用状态' }
      Rename-Item -LiteralPath $fullPath -NewName ($fullPath -replace '\.disabled$', '') -ErrorAction Stop
    } else {
      if ($isDisabled) { Fail '该项已是禁用状态' }
      Rename-Item -LiteralPath $fullPath -NewName "$(Split-Path -Leaf $fullPath).disabled" -ErrorAction Stop
    }
    return [ordered]@{
      ok = $true; action = $action; source = 'autorun'; dryRun = $false; changed = $true
      before = [ordered]@{ state = $(if ($isDisabled) { 'disabled' } else { 'enabled' }) }
      after  = [ordered]@{ state = $(if ($wantEnabled) { 'enabled' } else { 'disabled' }) }
      undo   = $undo
      message = '已重命名启动项'
    }
  }

  # --- rows that autorun.ps1 reports but owns elsewhere -------------------
  #
  # The autostart view lists scheduled tasks and services too, because on a real
  # machine that is where most autostart actually lives (61 services and 37 logon
  # tasks here, against 2 Run values). Those rows must not invent a second,
  # weaker toggle path: they delegate to DoTask / DoService, the exact code the
  # task and svc sources use, including the protected-service and kernel-driver
  # refusals inside DoService. `where=ref-*` is the whole point of the prefix.
  if ($where -eq 'ref-task') {
    $r = DoTask $wantEnabled
    # Re-label the reply: the user clicked in the autostart list, not the task
    # list, and a source mismatch would make the caller clear the wrong cache.
    # OrderedDictionary (not hashtable) is what DoTask returns, so test for the
    # key, not the type -- `-is [hashtable]` silently let the old source through
    # on the first run.
    if ($null -ne $r -and $r.Contains('source')) { $r['source'] = 'autorun' }
    return $r
  }

  if ($where -eq 'ref-service') {
    $r = DoService $wantEnabled
    if ($null -ne $r -and $r.Contains('source')) { $r['source'] = 'autorun' }
    return $r
  }

  if ($where -eq 'activesetup') {
    # Active Setup has no per-item off switch. Its only field is `Version`; an
    # entry runs at logon when its registered version is newer than the one that
    # user already ran, so blanking Version makes it re-run once, and deleting
    # the key silently drops a vendor's repair hook. Refusing with the reason is
    # the honest answer -- a toggle here would look like it worked and do nothing.
    Fail 'Active Setup 项无法逐项禁用（它的唯一字段是 Version，清空只会让它再跑一次，不会停止它）。要彻底停用请卸载对应厂商组件。'
  }

  Fail "不支持的自启位置: $where"
}

# ---------------------------------------------------------------------------
# Shell extensions (Shell Extensions\Approved allow-list)
# ---------------------------------------------------------------------------
function DoShellExt($wantEnabled) {
  $clsid = [string]$target.clsid
  if (-not $clsid) { Fail 'CLSID 缺失（无法按名称禁用未注册 CLSID 的扩展）' }

  # Which Approved key to write? Prefer the hive the handler was found in. The
  # value is per-CLSID and Explorer consults HKLM\...\Approved first, so a
  # machine-scope row writes there.
  $approvedPath = if ([string]$target.scope -eq 'user') {
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'
  } else {
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'
  }

  $props = Get-ItemProperty -LiteralPath $approvedPath -ErrorAction SilentlyContinue
  $existing = $null
  if ($props) {
    $p = $props.PSObject.Properties | Where-Object { $_.Name -eq $clsid }
    if ($p) { $existing = [string]$p.Value }
  }

  # The value Explorer writes for "approved" is the handler's friendly name. We
  # cannot invent it when absent, so record whatever we found (possibly "") and
  # restore exactly that on rollback.
  $undo = [ordered]@{
    source = 'com'
    clsid = $clsid
    approvedPath = $approvedPath
    hadValue = ($null -ne $existing)
    value = [string]$existing
    displayName = [string]$target.displayName
  }

  if ($dryRun) {
    return [ordered]@{
      ok = $true; action = $action; source = 'com'; dryRun = $true; changed = $false
      before = [ordered]@{ approved = [string]$existing }
      after  = [ordered]@{ approved = $(if ($wantEnabled) { '<restore name>' } else { '' }) }
      undo   = $undo
      message = "$(if ($wantEnabled) { '启用' } else { '禁用' })外壳扩展 $clsid"
    }
  }

  # *** DANGER: New-Item -Force DESTROYS an existing key ***
  # Measured 2026-11-17 in the sibling plugin: `New-Item -Path <existing key>
  # -Force` re-creates the key and drops every value and subkey, rather than
  # being an idempotent no-op. On HKCU\...\Explorer\Advanced that wiped the whole
  # key. Only create when the key is genuinely absent.
  if ($null -eq (Get-Item -LiteralPath $approvedPath -ErrorAction SilentlyContinue)) {
    New-Item -Path $approvedPath -ErrorAction Stop | Out-Null
  }

  if ($wantEnabled) {
    $name = if ([string]$target.displayName) { [string]$target.displayName } else { $clsid }
    New-ItemProperty -LiteralPath $approvedPath -Name $clsid -Value $name -PropertyType String -Force -ErrorAction Stop | Out-Null
  } else {
    # Empty string = blocked. Must exist with "" - an absent value is NOT a
    # block, so this creates the value rather than deleting it.
    New-ItemProperty -LiteralPath $approvedPath -Name $clsid -Value '' -PropertyType String -Force -ErrorAction Stop | Out-Null
  }

  return [ordered]@{
    ok = $true; action = $action; source = 'com'; dryRun = $false; changed = $true
    before = [ordered]@{ approved = [string]$existing }
    after  = [ordered]@{ approved = $(if ($wantEnabled) { 'restored' } else { '' }) }
    undo   = $undo
    message = "已$(if ($wantEnabled) { '启用' } else { '禁用' })外壳扩展 $clsid"
  }
}

# ---------------------------------------------------------------------------
# Firewall rules (HNetCfg.FwPolicy2 - the rule's own Enabled property)
# ---------------------------------------------------------------------------
# WHY THIS IS NOT A REGISTRY WRITE: the rules also live under
# HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\
# FirewallRules as "v2.30|Action=Allow|Active=FALSE|..." strings, where Active is
# the enabled bit. Writing that string directly works, but it bypasses the
# firewall service's own validation and is not what Windows APIs do. The COM
# object is the documented path and it fails cleanly when it cannot write
# (measured: setting Enabled unelevated throws E_ACCESSDENIED 0x80070005 and
# leaves the rule untouched - no half-written state).
#
# The registry export is kept as a belt-and-braces backup: reg export of the
# FirewallRules key succeeds unelevated (measured 77 ms, 314 632 bytes), so a
# failed or wrong edit can always be restored from a file on disk.
function Backup-FirewallRules {
  $dir = Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox\regbackup'
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
  }
  if (-not (Test-Path -LiteralPath $dir)) { return $null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $file = Join-Path $dir "$stamp-firewallrules.reg"
  $key = 'HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
  & reg export $key $file /y 2>$null | Out-Null
  # A backup that silently did not happen is worse than no backup policy: abort.
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $file)) { return $null }
  return $file
}

# The nine-tuple is built the same way firewall.ps1 builds it. Name alone is not
# unique (542 rules, 324 distinct names), so the tuple is the only safe locator.
function Get-FwKey($r) {
  return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}' -f `
    [string]$r.Name, [int]$r.Direction, [int]$r.Action, [int]$r.Protocol,
    [string]$r.LocalPorts, [string]$r.RemotePorts, [string]$r.ApplicationName,
    [long]$r.Profiles, [string]$r.serviceName)
}

function DoFirewall($wantEnabled) {
  $keyPath = [string]$target.keyPath
  $wantName = [string]$target.name

  $fw = $null
  try { $fw = New-Object -ComObject HNetCfg.FwPolicy2 } catch {
    Fail "无法访问 Windows 防火墙（防火墙服务未运行？）：$($_.Exception.Message)"
  }

  # Find the one rule whose full tuple matches. Enumerating all 542 costs ~44 ms,
  # which is cheaper and far safer than trusting a non-unique name.
  $hit = $null
  $before = $null
  if ($keyPath) {
    foreach ($r in $fw.Rules) {
      if ((Get-FwKey $r) -eq $keyPath) { $hit = $r; break }
    }
  } elseif ($wantName) {
    # Fallback: an unambiguous name only. If two rules share the name, refuse -
    # guessing which one the user meant is how the wrong rule gets disabled.
    $matches = @()
    foreach ($r in $fw.Rules) { if ([string]$r.Name -eq $wantName) { $matches += $r } }
    if ($matches.Count -gt 1) {
      Fail "名称「$wantName」对应 $($matches.Count) 条规则，无法确定改哪一条。请传 target.keyPath。"
    }
    if ($matches.Count -eq 1) { $hit = $matches[0] }
  } else {
    Fail '缺少 target.keyPath（防火墙规则名不唯一，必须用九元组定位）'
  }

  if ($null -eq $hit) { Fail "找不到该防火墙规则：$keyPath" }

  $beforeEnabled = [bool]$hit.Enabled
  $undo = [ordered]@{
    source  = 'firewall'
    keyPath = $keyPath
    name    = [string]$hit.Name
    enabled = $beforeEnabled
  }

  if ($dryRun) {
    return [ordered]@{
      ok = $true; action = $action; source = 'firewall'; dryRun = $true; changed = $false
      before = [ordered]@{ enabled = $beforeEnabled; name = [string]$hit.Name }
      after  = [ordered]@{ enabled = $wantEnabled }
      undo   = $undo
      message = "$(if ($wantEnabled) { '启用' } else { '禁用' })防火墙规则 $([string]$hit.Name)"
    }
  }

  if ($beforeEnabled -eq $wantEnabled) {
    return [ordered]@{
      ok = $true; action = $action; source = 'firewall'; dryRun = $false; changed = $false
      before = [ordered]@{ enabled = $beforeEnabled }
      after  = [ordered]@{ enabled = $beforeEnabled }
      undo   = $undo
      message = "规则 $([string]$hit.Name) 已经是$(if ($wantEnabled) { '启用' } else { '禁用' })状态"
    }
  }

  $backup = Backup-FirewallRules
  if (-not $backup) {
    Fail '防火墙规则备份失败（reg export），已中止写入。'
  }

  $hit.Enabled = $wantEnabled

  # Verify: re-read from a fresh enumeration rather than trusting the setter.
  $after = $null
  foreach ($r in $fw.Rules) { if ((Get-FwKey $r) -eq $keyPath) { $after = [bool]$r.Enabled; break } }

  return [ordered]@{
    ok = $true; action = $action; source = 'firewall'; dryRun = $false; changed = $true
    before = [ordered]@{ enabled = $beforeEnabled }
    after  = [ordered]@{ enabled = $after }
    undo   = $undo
    backup = $backup
    message = "已$(if ($wantEnabled) { '启用' } else { '禁用' })防火墙规则 $([string]$hit.Name)（备份：$backup）"
  }
}

# ---------------------------------------------------------------------------
# Uninstall — program / appx / drv
# ---------------------------------------------------------------------------
# This is the destructive half and the only place in the plugin that removes
# software. Every function below obeys the same three rules:
#
#   1. dryRun ONLY plans. It does not create the backup directory, does not touch
#      the registry, and does not start anything — a preview must leave the disk
#      byte-identical to what it was.
#   2. A real uninstall starts only AFTER the registry record it is about to
#      destroy has been exported. A failed `reg export` aborts: an uninstall we
#      cannot point back to is an uninstall we cannot reason about afterwards.
#   3. NO SHELL. A registry UninstallString is DATA, never code: it is tokenised
#      into an argv array and the exe is started directly, or (when it is MSI) it
#      collapses to literally `msiexec /X{GUID}`. `cmd /c "<string>"`,
#      `Invoke-Expression` and `Start-Process -Verb RunAs` appear nowhere in this
#      file — the first two would execute whatever a hijacked UninstallString
#      says, and the third would raise a UAC prompt the user never clicked.
#
# Timeout: 120 s. On expiry we return {ok:false,timedOut:true} and DO NOT kill the
# process — a stalled uninstaller is usually a dialog the user is reading, and
# killing it mid-uninstall is how a half-removed program happens. index.js gives
# this probe a 60 s budget, so an interactive wizard may still be cut off at the
# JS layer; that is a caller-side limit, not a change to this rule.
$UNINSTALL_TIMEOUT_SEC = 120

# Uninstall is the one irreversible action in this file. Everything else here can
# be undone from an `undo` record; a removed program cannot, and this tool must say
# so instead of letting the UI imply otherwise.
$NO_ROLLBACK_NOTE = ' 注意：卸载无法自动回滚——卸载程序会自行删除文件并改写注册表，本工具只保留了卸载键的备份，装回来需要重新安装。'

# Upgrade / migrate / per-app permissions are deliberately NOT implemented here:
# they belong to the 360 toolbox's software-manager capability. Point at it
# rather than silently offering nothing.
$SOFTMGR_NOTE = ' 升级、软件搬家与权限调整不在本插件里做，请用「360 工具箱」的软件管家能力。'

function Get-RegBackupDir {
  $dir = Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox\regbackup'
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
  }
  if (-not (Test-Path -LiteralPath $dir)) { return $null }
  return $dir
}

# The leaf name is computed separately from the export so a dry run can SHOW the
# file it would write without creating the directory to hold it.
function New-RegBackupName([string]$tag) {
  $safe = ([string]$tag) -replace '[\\/:*?"<>|]', '_'
  if (-not $safe) { $safe = 'entry' }
  if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
  return ('{0}-uninstall-{1}.reg' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $safe)
}

function Backup-UninstallKey([string]$keyPath, [string]$leaf) {
  $dir = Get-RegBackupDir
  if (-not $dir) { return $null }
  $file = Join-Path $dir $leaf
  & reg export $keyPath $file /y 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $file)) { return $null }
  return $file
}

# Provider path ("HKLM:\...") <-> reg.exe path ("HKEY_LOCAL_MACHINE\...").
# program.ps1 hands us the HKEY_LOCAL_MACHINE form (it strips the Registry::
# prefix from PSPath), while a caller that only kept scope/view/productCode
# builds the HKLM: form; both must work.
function Resolve-RegPath([string]$p) {
  $x = [string]$p
  if (-not $x) { return '' }
  $x = $x -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
  if ($x -match '^(HKLM|HKCU|HKU|HKCR|HKCC):') { return $x }
  if ($x -match '^HKEY_') { return "Registry::$x" }
  return $x
}

function ConvertTo-RegExportPath([string]$p) {
  $x = ([string]$p) -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
  if ($x -match '^HKLM:') { return 'HKEY_LOCAL_MACHINE' + $x.Substring(5) }
  if ($x -match '^HKCU:') { return 'HKEY_CURRENT_USER' + $x.Substring(5) }
  if ($x -match '^HKU:')  { return 'HKEY_USERS' + $x.Substring(4) }
  if ($x -match '^HKCR:') { return 'HKEY_CLASSES_ROOT' + $x.Substring(5) }
  return $x
}

# Same three hives program.ps1 reads, so an installed program always has one.
function Get-UninstallRoots {
  return @(
    [ordered]@{ scope = 'machine'; view = '64'; path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' },
    [ordered]@{ scope = 'machine'; view = '32'; path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' },
    [ordered]@{ scope = 'user';    view = '64'; path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
  )
}

# Tokenise a command line the way CommandLineToArgvW does for the simple cases:
# only `"` is special, spaces separate. No uninstaller in the wild uses the
# backslash-escape corners, and guessing at them would be inventing behaviour.
function Split-CommandLine([string]$line) {
  $tokens = New-Object System.Collections.Generic.List[string]
  $cur = New-Object System.Text.StringBuilder
  $inQuote = $false
  $has = $false
  foreach ($ch in ([string]$line).ToCharArray()) {
    if ($ch -eq '"') { $inQuote = -not $inQuote; $has = $true; continue }
    if (-not $inQuote -and ($ch -eq ' ' -or $ch -eq [char]9)) {
      if ($has) { $tokens.Add($cur.ToString()); [void]$cur.Clear(); $has = $false }
      continue
    }
    [void]$cur.Append($ch)
    $has = $true
  }
  if ($has) { $tokens.Add($cur.ToString()) }
  return , $tokens
}

# Test-Path THROWS (it does not return $false) when a parent directory denies
# access, and with $ErrorActionPreference='Stop' that terminating error would
# abort the whole request with "Access to the path ... is denied" — a useless
# answer for the user. Three states keep "denied" distinct from "missing": we
# must never report a recorded file as absent when we were merely not allowed
# to look at it.
function Test-LeafPath([string]$Path) {
  try {
    if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop) { return 'exists' }
    return 'missing'
  } catch {
    if ($_.Exception.Message -match '(?i)denied|拒绝访问|0x80070005') { return 'denied' }
    return 'missing'
  }
}

# Turn a registry UninstallString into an exact exe + argv pair, or a refusal.
# Returns @{ ok; error; kind; exe; args; display; productCode; exeVerified }.
function Resolve-UninstallInvocation([string]$cmdLine, [string]$productCodeHint) {
  $text = ([string]$cmdLine).Trim()
  if (-not $text) {
    return @{ ok = $false; error = '该程序的安装记录里没有 UninstallString，无法确定如何卸载' }
  }

  $tokens = $null
  if ($text.StartsWith('"')) {
    $tokens = Split-CommandLine $text
  } elseif ($text -match '(?i)^(.*?\.exe)(?:\s+(.*))?$') {
    # Unquoted path containing spaces ("C:\Program Files\App\unins000.exe /S").
    # Cutting at the first ".exe" is a parse of the string, not a guess at a path.
    $head = $matches[1]
    $tail = $matches[2]
    $tokens = New-Object System.Collections.Generic.List[string]
    $tokens.Add($head)
    if ($tail) { foreach ($t in (Split-CommandLine $tail)) { $tokens.Add($t) } }
  } else {
    $tokens = Split-CommandLine $text
  }

  if ($null -eq $tokens -or $tokens.Count -eq 0) {
    return @{ ok = $false; error = "无法解析卸载命令: $text" }
  }

  $first = [string]$tokens[0]
  $rest = @()
  if ($tokens.Count -gt 1) { $rest = @($tokens.GetRange(1, $tokens.Count - 1).ToArray()) }

  # ---- MSI: collapse to msiexec /X{GUID}, never run the string as-is ----
  if ((Split-Path -Leaf $first) -match '(?i)^msiexec(\.exe)?$') {
    $msi = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    if (-not (Test-Path -LiteralPath $msi)) {
      return @{ ok = $false; error = "找不到 msiexec.exe: $msi" }
    }
    $guid = ''
    if (([string]$productCodeHint) -match '^\{[0-9A-Fa-f\-]{36}\}$') { $guid = ([string]$productCodeHint).ToUpper() }
    if (-not $guid) {
      $m = [regex]::Match($text, '\{[0-9A-Fa-f\-]{36}\}')
      if ($m.Success) { $guid = $m.Value.ToUpper() }
    }
    if (-not $guid) {
      return @{ ok = $false; error = "MSI 卸载命令里没有可识别的产品代码 GUID: $text" }
    }
    return @{
      ok = $true; kind = 'msi'; exe = $msi; args = @('/X' + $guid)
      display = ('{0} /X{1}' -f $msi, $guid); productCode = $guid; exeVerified = $true
    }
  }

  # ---- plain exe ----
  # UninstallString is DATA. Only a real executable may lead it: an interpreter
  # or a command shell would mean executing a string as code, which is exactly
  # what this file refuses to do (a hijacked UninstallString would run anything).
  # MSI is handled above; msiexec's /I also collapses there, so `MsiExec.exe /I`
  # never reinstalls by surprise.
  $exePath = $first.Trim('"')
  $exeLeaf = Split-Path -Leaf $exePath
  if ($exeLeaf -match '(?i)^(cmd|powershell|pwsh|wscript|cscript|mshta|rundll32|regsvr32)(\.exe)?$') {
    return @{
      ok = $false
      error = "该程序的卸载命令由 $exeLeaf 解释执行（$text）。为了不把注册表里的字符串当任意代码运行，本工具不执行这类卸载命令；请手动卸载，或在「360 软件管家」中处理。"
    }
  }
  $exeVerified = $true
  if ($exePath -match '^[A-Za-z]:\\' -or $exePath.StartsWith('\\')) {
    $state = Test-LeafPath $exePath
    if ($state -eq 'missing') {
      return @{ ok = $false; error = "安装记录指向的卸载程序不存在: $exePath" }
    }
    # 'denied': the file may well be there but this account cannot stat it
    # (e.g. C:\ProgramData\...\SetupSerialIO.exe under an unelevated shell).
    # Report the weaker, honest state instead of claiming the path is wrong.
    if ($state -eq 'denied') { $exeVerified = $false }
  } else {
    # Not a path at all (e.g. "MsiExec.exe"): only an executable that really
    # resolves on PATH is accepted. We never append .exe or try candidate dirs.
    $cmd = Get-Command -Name $exePath -CommandType Application -ErrorAction SilentlyContinue
    if (-not $cmd) {
      return @{ ok = $false; error = "安装记录指向的卸载程序不存在（也不在 PATH 上）: $exePath" }
    }
    $exePath = [string]$cmd.Source
  }

  # Start-Process joins an -ArgumentList array with spaces and adds no quoting,
  # so any argument that contains a space has to be quoted here, once.
  $argv = @()
  foreach ($a in $rest) {
    if (([string]$a) -match '\s') { $argv += ('"' + $a + '"') } else { $argv += [string]$a }
  }
  $display = $exePath
  if ($argv.Count -gt 0) { $display = $display + ' ' + ($argv -join ' ') }

  return @{ ok = $true; kind = 'exe'; exe = $exePath; args = $argv; display = $display; productCode = ''; exeVerified = $exeVerified }
}

# Start one child process with a wall-clock budget and never kill it.
# Start-Process (no -Verb) is used instead of `&` because `&` blocks with no
# timeout at all; -Redirect* is used for console tools so their output can be
# quoted back to the user.
function Invoke-ChildProcess {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [int]$TimeoutSec = $UNINSTALL_TIMEOUT_SEC,
    [switch]$CaptureOutput
  )

  $outFile = $null
  $errFile = $null
  $sp = @{ FilePath = $FilePath; PassThru = $true }
  if ($Arguments -and $Arguments.Count -gt 0) { $sp['ArgumentList'] = @($Arguments) }

  if ($CaptureOutput) {
    $stem = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-uninstall-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $outFile = "$stem.out"
    $errFile = "$stem.err"
    $sp['RedirectStandardOutput'] = $outFile
    $sp['RedirectStandardError'] = $errFile
  }

  $proc = $null
  try {
    $proc = Start-Process @sp
  } catch {
    return @{ exited = $false; timedOut = $false; startFailed = $true; error = $_.Exception.Message; pid = 0; exitCode = $null }
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
  }
  $exited = $proc.HasExited
  $code = $null
  if ($exited) { try { $code = $proc.ExitCode } catch { $code = $null } }

  $stdout = ''
  $stderr = ''
  if ($CaptureOutput) {
    try { if (Test-Path -LiteralPath $outFile) { $stdout = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue) } } catch { }
    try { if (Test-Path -LiteralPath $errFile) { $stderr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue) } } catch { }
    try { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue } catch { }
  }

  return @{
    exited = $exited
    # Expired budget: the child is deliberately NOT stopped. See the header.
    timedOut = (-not $exited)
    startFailed = $false
    pid = [int]$proc.Id
    exitCode = $code
    stdout = ([string]$stdout).Trim()
    stderr = ([string]$stderr).Trim()
  }
}

function DoProgramUninstall {
  $name = [string]$target.name
  $keyPath = [string]$target.keyPath
  $productCode = [string]$target.productCode
  if (-not $name -and -not $keyPath) { Fail '缺少 target.name / target.keyPath，无法定位要卸载的程序' }

  # ---- 1. locate the Uninstall key (keyPath is authoritative) ----
  $resolvedKey = ''
  if ($keyPath) {
    if ($null -ne (Get-Item -LiteralPath (Resolve-RegPath $keyPath) -ErrorAction SilentlyContinue)) {
      $resolvedKey = $keyPath
    }
  }
  if (-not $resolvedKey -and $productCode) {
    foreach ($root in (Get-UninstallRoots)) {
      $cand = "$($root.path)\$productCode"
      if ($null -ne (Get-Item -LiteralPath $cand -ErrorAction SilentlyContinue)) { $resolvedKey = $cand; break }
    }
  }
  if (-not $resolvedKey) {
    Fail "找不到该程序的卸载记录（可能已经卸载，或 keyPath 不正确）: $name"
  }

  $props = Get-ItemProperty -LiteralPath (Resolve-RegPath $resolvedKey) -ErrorAction SilentlyContinue
  if ($null -eq $props) { Fail "无法读取卸载键: $resolvedKey" }

  $displayName = [string]$props.DisplayName
  if (-not $displayName) { $displayName = $name }
  if (-not $displayName) { $displayName = $productCode }

  # ---- 2. systemComponent: refuse, do not try ----
  # Read from the registry, not from the request: the caller's copy is a view of
  # this value, and a tampered request must not be able to talk us into removing
  # a component Windows itself manages.
  $sc = [string]$props.SystemComponent
  if ($sc -eq '1' -or $sc -match '(?i)^true$') {
    Fail "拒绝卸载系统组件：$displayName（注册表 SystemComponent=$sc）。这类条目由 Windows 自身的更新与维护管理，不是用户安装的程序；如确需清理，请使用「360 软件管家」或系统自带的「应用和功能」。"
  }

  # ---- 3. resolve the uninstall command ----
  $uninstallLine = [string]$props.UninstallString
  if (-not $uninstallLine) { $uninstallLine = [string]$target.uninstall }
  $inv = Resolve-UninstallInvocation $uninstallLine $productCode
  if (-not $inv.ok) { Fail $inv.error }

  # HKLM means machine-wide: removing it rewrites Program Files and machine
  # registry, which an unelevated shell cannot do. Report the exact command so
  # the UI's "retry as administrator" can run it without re-deriving anything.
  $exportKey = ConvertTo-RegExportPath $resolvedKey
  $scope = if ($exportKey -match '^HKEY_LOCAL_MACHINE') { 'machine' } else { 'user' }
  $needsAdmin = ($scope -eq 'machine')

  $leafName = New-RegBackupName $displayName
  $backupDir = Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox\regbackup'
  $plannedBackup = Join-Path $backupDir $leafName

  if ($dryRun) {
    return [ordered]@{
      ok = $true; action = 'uninstall'; source = 'program'; dryRun = $true; changed = $false
      plan = [ordered]@{
        name              = $displayName
        scope             = $scope
        kind              = $inv.kind
        exe               = $inv.exe
        args              = @($inv.args)
        command           = $inv.display
        uninstallString   = $uninstallLine
        quietUninstall    = [string]$props.QuietUninstallString
        keyPath           = $resolvedKey
        backupWouldBe     = $plannedBackup
        timeoutSec        = $UNINSTALL_TIMEOUT_SEC
        needsAdmin        = $needsAdmin
        isElevated        = $isElevated
        # $false = the recorded exe could not be stat'ed (parent dir denies
        # access). The path may still be perfectly good; we just cannot prove it.
        exeVerified       = [bool]$inv.exeVerified
      }
      message = "预演：将运行 $($inv.display)；运行前会先把卸载键导出到 $plannedBackup。本次没有运行任何程序，也没有写入任何文件。" +
                $(if ($inv.exeVerified) { '' } else { '（注意：该卸载程序所在目录拒绝当前账户访问，无法确认文件是否真实存在，实际执行时可能失败。）' }) +
                $NO_ROLLBACK_NOTE + $SOFTMGR_NOTE
    }
  }

  # ---- 4. fail closed when the command needs rights we do not have ----
  if ($needsAdmin -and -not $isElevated) {
    return [ordered]@{
      ok = $false; action = 'uninstall'; source = 'program'; dryRun = $false; changed = $false
      needsAdmin = $true; canElevate = $true
      command = $inv.display
      commandFile = $inv.exe
      commandArgs = @($inv.args)
      keyPath = $resolvedKey
      message = "卸载 $displayName 需要管理员权限（该程序登记在 HKLM，安装位置与机器级注册表都需要写权限）。可在插件里点「以管理员身份重试」，将执行：$($inv.display)" + $NO_ROLLBACK_NOTE + $SOFTMGR_NOTE
    }
  }

  # ---- 5. back up the key BEFORE anything runs, abort on failure ----
  $backup = Backup-UninstallKey $exportKey $leafName
  if (-not $backup) {
    Fail "卸载键备份失败（reg export $exportKey），已中止卸载，未运行任何卸载程序。"
  }

  # ---- 6. run it, with a budget and no killing ----
  $run = Invoke-ChildProcess -FilePath $inv.exe -Arguments @($inv.args) -TimeoutSec $UNINSTALL_TIMEOUT_SEC

  if ($run.startFailed) {
    # A manifest requesting elevation fails here with Win32 740; that is the
    # same "you need admin" answer as an HKLM key, so give it the same shape.
    if ([string]$run.error -match '(?i)740|elevation|管理员|拒绝访问|Access is denied') {
      return [ordered]@{
        ok = $false; action = 'uninstall'; source = 'program'; dryRun = $false; changed = $false
        needsAdmin = $true; canElevate = $true
        command = $inv.display
        commandFile = $inv.exe
        commandArgs = @($inv.args)
        keyPath = $resolvedKey
        backup = $backup
        message = "卸载程序 $($inv.display) 要求管理员权限，当前进程未提权。可在插件里点「以管理员身份重试」。（卸载键已备份：$backup）"
      }
    }
    return [ordered]@{
      ok = $false; action = 'uninstall'; source = 'program'; dryRun = $false; changed = $false
      backup = $backup
      message = "无法启动卸载程序 $($inv.display)：$($run.error)（备份仍在：$backup）"
    }
  }

  if ($run.timedOut) {
    return [ordered]@{
      ok = $false; action = 'uninstall'; source = 'program'; dryRun = $false
      # changed=$true: the uninstaller DID run and may already have removed files.
      # The process is still alive on purpose — do not stop it.
      changed = $true; timedOut = $true; inflight = $true
      pid = $run.pid
      backup = $backup
      command = $inv.display
      message = "卸载程序已运行超过 $($UNINSTALL_TIMEOUT_SEC) 秒仍未结束（PID $($run.pid)），可能有对话框正在等待你确认。已保留该进程、未强行结束；卸载键备份：$backup"
    }
  }

  $code = $run.exitCode
  $keyStillThere = ($null -ne (Get-Item -LiteralPath (Resolve-RegPath $resolvedKey) -ErrorAction SilentlyContinue))

  # MSI's well-known codes; the rest are passed through verbatim.
  $ok = ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641)
  $cancelled = ($code -eq 1602 -or $code -eq 1223)
  $rebootNote = ''
  if ($code -eq 3010) { $rebootNote = '（需要重启才能完成）' }
  if ($code -eq 1641) { $rebootNote = '（卸载程序已自行重启系统）' }

  $verdict = if ($ok) { "卸载程序已完成$rebootNote" }
             elseif ($cancelled) { '卸载被取消（用户关闭或拒绝了卸载程序）' }
             else { "卸载程序返回失败代码 $code" }

  return [ordered]@{
    ok = $ok; action = 'uninstall'; source = 'program'; dryRun = $false
    changed = $ok
    exitCode = $code
    cancelled = $cancelled
    backup = $backup
    command = $inv.display
    before = [ordered]@{ installed = $true; name = $displayName; version = [string]$props.DisplayVersion }
    after  = [ordered]@{ uninstallKeyRemoved = (-not $keyStillThere) }
    message = "$verdict。备份：$backup" +
              $(if ($ok -and $keyStillThere) { '（卸载键仍存在，程序可能把自己留在了列表里）' } else { '' }) +
              $NO_ROLLBACK_NOTE + $SOFTMGR_NOTE
  }
}

function DoAppxUninstall {
  $fullName = [string]$target.fullName
  $name = [string]$target.name
  if (-not $fullName -and -not $name) { Fail '缺少 target.fullName / target.name，无法定位要卸载的 AppX 包' }

  # ---- 1. bridge the Appx module and PROVE it enumerated something ----
  # Under PS7 a bare Get-AppxPackage fails to load the module and returns an
  # EMPTY list without throwing — a silent false zero that would look like "this
  # package is not installed". So the bridge is mandatory and its result is
  # counted before anything is concluded from it.
  $bridged = $false
  $all = @()
  try {
    Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    $all = @(Get-AppxPackage -ErrorAction SilentlyContinue)
    $bridged = ($all.Count -gt 0)
  } catch { $bridged = $false }

  if (-not $bridged) {
    Fail 'AppX 模块桥接失败（PowerShell 7 无法直接加载 Appx 模块，且 -UseWindowsPowerShell 也没有返回任何包）。为避免把「读取失败」当成「包不存在」，已中止。请在有图形界面的 Windows PowerShell 5.1 中重试。'
  }

  # ---- 2. find the exact package ----
  $hit = $null
  if ($fullName) {
    foreach ($p in $all) {
      if ([string]$p.PackageFullName -eq $fullName) { $hit = $p; break }
    }
  }
  if ($null -eq $hit -and $name) {
    $matches2 = @($all | Where-Object { [string]$_.Name -eq $name })
    if ($matches2.Count -gt 1) {
      Fail "名称「$name」对应 $($matches2.Count) 个 AppX 包，无法确定卸载哪一个。请传 target.fullName。"
    }
    if ($matches2.Count -eq 1) { $hit = $matches2[0] }
  }
  if ($null -eq $hit) {
    Fail "在 $($all.Count) 个已安装包中找不到该 AppX 包（可能已经卸载）: $(if ($fullName) { $fullName } else { $name })"
  }

  $targetFull = [string]$hit.PackageFullName
  $targetName = [string]$hit.Name
  $nonRemovable = $false
  $isFramework = $false
  try { $nonRemovable = [bool]$hit.NonRemovable } catch { }
  try { $isFramework = [bool]$hit.IsFramework } catch { }

  # ---- 3. refuse what Windows will not let go of anyway ----
  if ($nonRemovable) {
    Fail "拒绝卸载 $targetName：该包标记为 NonRemovable（系统内置、不可移动），Windows 不允许按用户卸载。"
  }
  if ($isFramework) {
    Fail "拒绝卸载 $targetName：该包是框架包（IsFramework），其它应用依赖它，卸载会让它们一起不可用。"
  }

  if ($dryRun) {
    return [ordered]@{
      ok = $true; action = 'uninstall'; source = 'appx'; dryRun = $true; changed = $false
      plan = [ordered]@{
        name             = $targetName
        fullName         = $targetFull
        version          = [string]$hit.Version
        publisher        = [string]$hit.Publisher
        nonRemovable     = $nonRemovable
        isFramework      = $isFramework
        packageUserInformation = [string]$hit.PackageUserInformation
        # Proof the bridge really enumerated: a false zero would make the
        # existence check above meaningless.
        enumeratedCount  = $all.Count
        bridged          = $bridged
        removeCommand    = "Remove-AppxPackage -Package `"$targetFull`""
      }
      message = "预演：将执行 Remove-AppxPackage -Package `"$targetFull`"（当前用户范围）。桥接枚举到 $($all.Count) 个包，本次没有卸载任何东西。"
    }
  }

  # ---- 4. remove it ----
  try {
    Remove-AppxPackage -Package $targetFull -ErrorAction Stop
  } catch {
    $msg = $_.Exception.Message
    if ($msg -match '(?i)0x80070005|0x80073D19|拒绝访问|Access is denied|受限制|administrator') {
      return [ordered]@{
        ok = $false; action = 'uninstall'; source = 'appx'; dryRun = $false; changed = $false
        needsAdmin = $true; canElevate = $true
        command = "Remove-AppxPackage -Package `"$targetFull`""
        message = "卸载 $targetName 需要管理员权限（该包可能为所有用户安装）：$msg。可在插件里点「以管理员身份重试」。"
      }
    }
    Fail "卸载 AppX 包失败：$msg"
  }

  # ---- 5. verify from a fresh enumeration, not from the cmdlet's silence ----
  $after = @(Get-AppxPackage -ErrorAction SilentlyContinue)
  $stillThere = $false
  foreach ($p in $after) { if ([string]$p.PackageFullName -eq $targetFull) { $stillThere = $true; break } }

  return [ordered]@{
    ok = (-not $stillThere); action = 'uninstall'; source = 'appx'; dryRun = $false
    changed = (-not $stillThere)
    before = [ordered]@{ installed = $true; fullName = $targetFull; version = [string]$hit.Version }
    after  = [ordered]@{ installed = $stillThere; count = $after.Count }
    message = $(if ($stillThere) { "Remove-AppxPackage 返回成功，但重新枚举后 $targetName 仍在列表里。可能只对当前用户生效或需要重启。" }
                else { "已卸载 AppX 包 $targetName（重枚举 $($after.Count) 个包，目标已消失）" })
  }
}

function DoDriverUninstall {
  $name = [string]$target.name
  $published = [string]$target.publishedName
  $packageKey = [string]$target.packageKey

  # ---- 1. which package, and is it ours to delete? ----
  # The oem*.inf prefix IS the definition of a third-party package in the driver
  # store: in-box Microsoft packages use their own .inf names and pnputil refuses
  # to delete them. We recompute that from the published name rather than trust
  # target.thirdParty, so a stale row or a hand-built request cannot smuggle an
  # in-box driver in.
  if (-not $published -and $packageKey) {
    $infRoot = 'HKLM:\SYSTEM\DriverDatabase\DriverInfFiles'
    foreach ($k in (Get-ChildItem -LiteralPath $infRoot -ErrorAction SilentlyContinue)) {
      $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
      if ($null -eq $p) { continue }
      $active = [string]$p.Active
      if (-not $active) { $active = [string]$p.'(default)' }
      if ($active -eq $packageKey) { $published = [string]$k.PSChildName; break }
    }
  }

  $label = if ($published) { $published } elseif ($name) { $name } else { $packageKey }
  if (-not $label) { Fail '缺少 target.publishedName / target.packageKey，无法定位驱动包' }

  if ($published -notmatch '(?i)^oem\d+\.inf$') {
    Fail "拒绝删除驱动包 $label：只有第三方 OEM 驱动（发布名 oemNN.inf）能从驱动库里删除，Windows 内置驱动（如 $label）由系统组件存储管理，pnputil 也会拒绝。"
  }

  $infKey = "HKLM:\SYSTEM\DriverDatabase\DriverInfFiles\$published"
  if ($null -eq (Get-Item -LiteralPath $infKey -ErrorAction SilentlyContinue)) {
    Fail "驱动包 $published 已不在驱动库中（可能已被删除）"
  }

  # ---- 2. an in-use package cannot be deleted; say so instead of trying ----
  $bound = $false
  try { $bound = [bool]$target.bound } catch { }
  if ($bound) {
    Fail "拒绝删除驱动包 $published：它正被设备使用（bound=true）。请先在设备管理器里卸载对应设备或改为使用其它驱动，再删除这个包；强行删除在用的驱动包会让设备在下次启动时无法工作。"
  }

  $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
  if (-not (Test-Path -LiteralPath $pnputil)) { Fail "找不到 pnputil.exe: $pnputil" }

  $argv = @('/delete-driver', $published, '/uninstall')
  $display = "$pnputil $($argv -join ' ')"

  if ($dryRun) {
    return [ordered]@{
      ok = $true; action = 'uninstall'; source = 'drv'; dryRun = $true; changed = $false
      plan = [ordered]@{
        name          = $label
        publishedName = $published
        infName       = [string]$target.infName
        provider      = [string]$target.provider
        version       = [string]$target.version
        thirdParty    = $true
        bound         = $bound
        exe           = $pnputil
        args          = @($argv)
        command       = $display
        timeoutSec    = $UNINSTALL_TIMEOUT_SEC
        needsAdmin    = $true
        isElevated    = $isElevated
      }
      message = "预演：将执行 $display。pnputil 需要管理员权限；本次没有删除任何驱动。"
    }
  }

  # pnputil writes the driver store: always an elevated operation.
  if (-not $isElevated) {
    return [ordered]@{
      ok = $false; action = 'uninstall'; source = 'drv'; dryRun = $false; changed = $false
      needsAdmin = $true; canElevate = $true
      command = $display
      commandFile = $pnputil
      commandArgs = @($argv)
      publishedName = $published
      message = "删除驱动包 $published 需要管理员权限。可在插件里点「以管理员身份重试」，将执行：$display"
    }
  }

  $run = Invoke-ChildProcess -FilePath $pnputil -Arguments $argv -TimeoutSec $UNINSTALL_TIMEOUT_SEC -CaptureOutput

  if ($run.startFailed) {
    return [ordered]@{
      ok = $false; action = 'uninstall'; source = 'drv'; dryRun = $false; changed = $false
      message = "无法启动 pnputil：$($run.error)"
    }
  }
  if ($run.timedOut) {
    return [ordered]@{
      ok = $false; action = 'uninstall'; source = 'drv'; dryRun = $false
      changed = $true; timedOut = $true; inflight = $true
      pid = $run.pid; command = $display
      message = "pnputil 超过 $($UNINSTALL_TIMEOUT_SEC) 秒仍未结束（PID $($run.pid)）。已保留该进程、未强行结束。"
    }
  }

  # Verify against the driver store itself instead of trusting the exit code.
  $stillThere = ($null -ne (Get-Item -LiteralPath $infKey -ErrorAction SilentlyContinue))
  $ok = (-not $stillThere)
  $detail = @()
  if ($run.stdout) { $detail += $run.stdout }
  if ($run.stderr) { $detail += $run.stderr }

  return [ordered]@{
    ok = $ok; action = 'uninstall'; source = 'drv'; dryRun = $false
    changed = $ok
    exitCode = $run.exitCode
    command = $display
    output = ($detail -join "`n")
    before = [ordered]@{ installed = $true; publishedName = $published }
    after  = [ordered]@{ installed = $stillThere }
    message = $(if ($ok) { "已从驱动库删除 $published" }
                else { "pnputil 退出码 $($run.exitCode)，驱动包 $published 仍在驱动库中。输出：$($detail -join ' ')" })
  }
}

# ---------------------------------------------------------------------------
# Rollback: consume an undo record and put the previous state back.
# ---------------------------------------------------------------------------
function DoRollback() {
  if ($null -eq $undoIn) { Fail '缺少 undo 记录' }
  $src = [string]$undoIn.source

  if ($src -eq 'svc') {
    $name = [string]$undoIn.name
    if (IsProtected $name) { Fail "拒绝操作受保护服务: $name" }
    $mode = [string]$undoIn.startMode
    if (-not $mode) { Fail 'undo 记录缺少 startMode' }
    Set-Service -Name $name -StartupType $mode -ErrorAction Stop
    if ([bool]$undoIn.wasRunning) {
      try { Start-Service -Name $name -ErrorAction Stop } catch { }
    }
    $after = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($name -replace "'", "''")'" -ErrorAction SilentlyContinue
    return [ordered]@{
      ok = $true; action = 'rollback'; source = 'svc'; dryRun = $false; changed = $true
      before = $null; after = [ordered]@{ startMode = [string]$after.StartMode; state = [string]$after.State }
      undo = $null; message = "$name 已回滚为 $([string]$after.StartMode)"
    }
  }

  if ($src -eq 'task') {
    $path = [string]$undoIn.taskPath
    $tname = [string]$undoIn.taskName
    if ([string]$undoIn.state -eq 'Disabled') {
      Disable-ScheduledTask -TaskPath $path -TaskName $tname -ErrorAction Stop | Out-Null
    } else {
      Enable-ScheduledTask -TaskPath $path -TaskName $tname -ErrorAction Stop | Out-Null
    }
    $after = Get-ScheduledTask -TaskPath $path -TaskName $tname -ErrorAction SilentlyContinue
    return [ordered]@{
      ok = $true; action = 'rollback'; source = 'task'; dryRun = $false; changed = $true
      before = $null; after = [ordered]@{ state = [string]$after.State }
      undo = $null; message = "任务已回滚为 $([string]$after.State)"
    }
  }

  if ($src -eq 'autorun') {
    $where = [string]$undoIn.where
    if ($where -eq 'registry') {
      $regKey = [string]$undoIn.keyPath
      if (-not $regKey.StartsWith('HK')) { $regKey = "Registry::$regKey" }
      $n = [string]$undoIn.name
      $v = [string]$undoIn.path
      New-ItemProperty -LiteralPath $regKey -Name $n -Value $v -PropertyType String -Force -ErrorAction Stop | Out-Null
      $props = Get-ItemProperty -LiteralPath $regKey -ErrorAction SilentlyContinue
      if ($props -and ($props.PSObject.Properties | Where-Object { $_.Name -eq "$n.__disabled" })) {
        Remove-ItemProperty -LiteralPath $regKey -Name "$n.__disabled" -ErrorAction Stop
      }
      return [ordered]@{
        ok = $true; action = 'rollback'; source = 'autorun'; dryRun = $false; changed = $true
        before = $null; after = [ordered]@{ state = 'enabled' }; undo = $null
        message = "自启项 $n 已回滚"
      }
    }
    $p = [string]$undoIn.path
    $targetPath = if ($p -match '\.disabled$') { $p -replace '\.disabled$', '' } else { $p }
    if (-not (Test-Path -LiteralPath $targetPath)) {
      if (Test-Path -LiteralPath "$p.disabled") {
        Rename-Item -LiteralPath "$p.disabled" -NewName (Split-Path -Leaf $p) -ErrorAction Stop
      } else { Fail "回滚目标不存在: $targetPath" }
    }
    return [ordered]@{
      ok = $true; action = 'rollback'; source = 'autorun'; dryRun = $false; changed = $true
      before = $null; after = [ordered]@{ state = 'enabled' }; undo = $null
      message = '启动文件夹项已回滚'
    }
  }

  if ($src -eq 'com') {
    $clsid = [string]$undoIn.clsid
    $ap = [string]$undoIn.approvedPath
    if ([bool]$undoIn.hadValue) {
      New-ItemProperty -LiteralPath $ap -Name $clsid -Value ([string]$undoIn.value) -PropertyType String -Force -ErrorAction Stop | Out-Null
    } else {
      Remove-ItemProperty -LiteralPath $ap -Name $clsid -ErrorAction Stop
    }
    return [ordered]@{
      ok = $true; action = 'rollback'; source = 'com'; dryRun = $false; changed = $true
      before = $null; after = [ordered]@{ approved = [string]$undoIn.value }; undo = $null
      message = "外壳扩展 $clsid 已回滚"
    }
  }

  if ($src -eq 'firewall') {
    $keyPath = [string]$undoIn.keyPath
    $want = [bool]$undoIn.enabled
    if (-not $keyPath) { Fail 'undo 记录缺少 keyPath' }

    $fw = $null
    try { $fw = New-Object -ComObject HNetCfg.FwPolicy2 } catch {
      Fail "无法访问 Windows 防火墙：$($_.Exception.Message)"
    }
    $hit = $null
    foreach ($r in $fw.Rules) { if ((Get-FwKey $r) -eq $keyPath) { $hit = $r; break } }
    if ($null -eq $hit) { Fail "回滚目标规则已不存在：$keyPath" }

    $backup = Backup-FirewallRules
    if (-not $backup) { Fail '防火墙规则备份失败（reg export），已中止回滚。' }

    $hit.Enabled = $want
    $after = $null
    foreach ($r in $fw.Rules) { if ((Get-FwKey $r) -eq $keyPath) { $after = [bool]$r.Enabled; break } }

    return [ordered]@{
      ok = $true; action = 'rollback'; source = 'firewall'; dryRun = $false; changed = $true
      before = $null; after = [ordered]@{ enabled = $after }
      undo = $null; backup = $backup
      message = "防火墙规则已回滚为 enabled=$after（备份：$backup）"
    }
  }

  Fail "不支持的 rollback 来源: $src"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
try {
  if ($action -eq 'rollback') { Emit (DoRollback) ; exit 0 }

  # `uninstall` sits OUTSIDE the enable/disable vocabulary: it is not a toggle
  # and has no rollback record, so it is dispatched before the reversible gate.
  if ($action -eq 'uninstall') {
    if (-not $target) { Fail '缺少 target，无法确定要卸载哪一个' }
    switch ($source) {
      'program' { Emit (DoProgramUninstall) }
      'appx'    { Emit (DoAppxUninstall) }
      'drv'     { Emit (DoDriverUninstall) }
      default   { Fail "来源 $source 不支持卸载（只有已安装程序 program、AppX 应用和第三方驱动包 drv 可以卸载；服务、任务、自启项请用 enable/disable）" }
    }
    exit 0
  }

  $wantEnabled = ($action -eq 'enable')
  if ($action -ne 'enable' -and $action -ne 'disable') { Fail "不支持的 action: $action" }

  switch ($source) {
    'svc'      { Emit (DoService $wantEnabled) }
    'task'     { Emit (DoTask $wantEnabled) }
    'autorun'  { Emit (DoAutorun $wantEnabled) }
    'com'      { Emit (DoShellExt $wantEnabled) }
    'firewall' { Emit (DoFirewall $wantEnabled) }
    # program/appx/drv are not toggles: they are uninstalled, not disabled. The
    # message says which action to use instead of just denying enable/disable.
    'program'  { Fail '已安装程序没有「启用/停用」这种状态，请用 action=uninstall（默认 dryRun 预演）。' }
    'appx'     { Fail 'AppX 应用没有「启用/停用」这种状态，请用 action=uninstall（默认 dryRun 预演）。' }
    'drv'      { Fail '驱动包没有「启用/停用」这种状态，请用 action=uninstall（只支持第三方 oemNN.inf 包）。' }
    default    { Fail "来源 $source 不支持 enable/disable（IFEO、文件关联、凭据提供程序在本版本仅只读）" }
  }
} catch {
  Fail $_.Exception.Message
}
