# autorun.ps1 - what actually starts by itself (the "startup items" registration point).
#
# Why this file is bigger than "four Run keys": the panel used to show 3 rows on a
# machine where Task Manager lists dozens, and the user rightly called it wrong.
# Windows starts things from six different places, and a startup manager that
# shows one of them is not a startup manager:
#
#   1. Run / RunOnce           HKLM, HKLM\WOW6432Node, HKCU, HKCU\WOW6432Node,
#                              plus the policy and RunOnce\Setup variants
#   2. Startup folders         machine + user, including the ".disabled" spelling
#                              Explorer uses when you switch something off
#   3. UWP StartupTask         per-user AppModel state, keyed by package family
#   4. Scheduled tasks         logon / boot triggers (37 on this machine, 25 live)
#   5. Services                StartMode=Auto (61 on this machine) — the ones that
#                              are already running before anybody logs in
#   6. Active Setup            per-user one-time logon stubs (36 here)
#
# Rows 4 and 5 are ALSO exposed by task.ps1 / svc.ps1 as their own sources. That is
# deliberate: those sources are the registry-of-record for toggling them, and this
# file is the "what starts" view. Each row therefore carries `where`, which is what
# actions.ps1 dispatches on, so a toggle from here still goes through the exact same
# verified code path (ref-task / ref-service delegate to DoTask / DoService).
#
# Read-only.
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$rows = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------------------
# 1. Run / RunOnce values
# ---------------------------------------------------------------------------
$runKeys = @(
  @{ path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                  scope = 'machine'; kind = 'run' },
  @{ path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';             scope = 'machine'; kind = 'runonce' },
  @{ path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce\Setup';       scope = 'machine'; kind = 'runonce' },
  @{ path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';     scope = 'machine'; kind = 'run' },
  @{ path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; scope = 'machine'; kind = 'runonce' },
  @{ path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                 scope = 'user';    kind = 'run' },
  @{ path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';             scope = 'user';    kind = 'runonce' },
  @{ path = 'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';     scope = 'user';    kind = 'run' },
  @{ path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'; scope = 'machine'; kind = 'policyrun' },
  @{ path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'; scope = 'user';    kind = 'policyrun' }
)

foreach ($rk in $runKeys) {
  if (-not (Test-Path -LiteralPath $rk.path)) { continue }
  $props = Get-ItemProperty -LiteralPath $rk.path -ErrorAction SilentlyContinue
  if ($null -eq $props) { continue }
  foreach ($p in $props.PSObject.Properties) {
    if ($p.Name -like 'PS*') { continue }
    $rows.Add([ordered]@{
      source = 'autorun'
      kind   = $rk.kind
      name   = $p.Name
      state  = 'enabled'
      path   = [string]$p.Value
      scope  = $rk.scope
      keyPath= ($rk.path -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')
      where  = 'registry'
      via    = 'registry'
    })
  }
}

# ---------------------------------------------------------------------------
# 2. Startup folders
# ---------------------------------------------------------------------------
$startupDirs = @()
if ($env:ProgramData) {
  $startupDirs += @{ dir = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp'); scope = 'machine' }
}
if ($env:APPDATA) {
  $startupDirs += @{ dir = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'); scope = 'user' }
}

foreach ($sd in $startupDirs) {
  if (-not (Test-Path -LiteralPath $sd.dir)) { continue }
  foreach ($f in (Get-ChildItem -LiteralPath $sd.dir -File -ErrorAction SilentlyContinue)) {
    # desktop.ini is the folder's own metadata file, not something that starts.
    if ($f.Name -eq 'desktop.ini') { continue }
    # Explorer renames X.lnk to X.lnk.disabled when the user switches it off in
    # Task Manager > Startup. That trailing marker is the only record of the
    # user's intent, so it has to be read, not skipped.
    $disabled = $f.Name -match '\.disabled$'
    $rows.Add([ordered]@{
      source = 'autorun'
      kind   = 'startupfolder'
      name   = ($f.Name -replace '\.disabled$', '')
      state  = $(if ($disabled) { 'Disabled' } else { 'enabled' })
      path   = $f.FullName
      scope  = $sd.scope
      keyPath= $sd.dir
      where  = 'startup-folder'
      via    = 'startup-folder'
    })
  }
}

# ---------------------------------------------------------------------------
# 3. UWP / packaged autostart (StartupTask)
# ---------------------------------------------------------------------------
# These live under the per-user AppModel state, keyed by package family name.
$appModel = 'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
if (Test-Path -LiteralPath $appModel) {
  foreach ($pkg in (Get-ChildItem -LiteralPath $appModel -ErrorAction SilentlyContinue)) {
    $stKey = Join-Path $pkg.PSPath 'StartupTasks'
    if (-not (Test-Path -LiteralPath $stKey)) { continue }
    foreach ($task in (Get-ChildItem -LiteralPath $stKey -ErrorAction SilentlyContinue)) {
      $props = Get-ItemProperty -LiteralPath $task.PSPath -ErrorAction SilentlyContinue
      $stateRaw = 0
      if ($props -and $null -ne $props.State) { $stateRaw = [int]$props.State }
      $rows.Add([ordered]@{
        source = 'autorun'
        kind   = 'startuptask'
        name   = ($pkg.PSChildName + '/' + $task.PSChildName)
        # In AppModel\SystemAppData\...\StartupTasks, State 2 = enabled,
        # 1 = disabled by user, 0/absent = never configured.
        state  = $(if ($stateRaw -eq 2) { 'enabled' } elseif ($stateRaw -eq 1) { 'Disabled' } else { 'unconfigured' })
        path   = ''
        scope  = 'user'
        keyPath= ($task.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')
        where  = 'appmodel-startuptask'
        via    = 'startuptask'
      })
    }
  }
}

# ---------------------------------------------------------------------------
# 4. Scheduled tasks that fire at logon or boot
# ---------------------------------------------------------------------------
# Only logon/boot triggers belong in a "what starts when I turn the PC on" list.
# A task that runs daily at noon is not a startup item, so it stays in task.ps1.
try {
  $allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
  foreach ($t in $allTasks) {
    $hit = $false
    $triggerNames = New-Object System.Collections.Generic.List[string]
    foreach ($tr in @($t.Triggers)) {
      if ($null -eq $tr) { continue }
      $cls = [string]$tr.CimClass.CimClassName
      if ($cls -match 'LogonTrigger') { $hit = $true; $triggerNames.Add('登录时') }
      elseif ($cls -match 'BootTrigger') { $hit = $true; $triggerNames.Add('开机时') }
    }
    if (-not $hit) { continue }

    $actionText = ''
    try { $actionText = (@($t.Actions) | ForEach-Object { [string]$_.Execute }) -join ' ' } catch { $actionText = '' }
    $taskPath = [string]$t.TaskPath
    $taskName = [string]$t.TaskName
    $enabled = -not ([string]$t.State -eq 'Disabled')
    $rows.Add([ordered]@{
      source = 'autorun'
      kind   = 'scheduledtask'
      name   = ($taskPath + $taskName)
      state  = $(if ($enabled) { 'enabled' } else { 'Disabled' })
      path   = $actionText.Trim()
      scope  = 'machine'
      # `where = ref-task` is the dispatch key in actions.ps1: it hands the row to
      # DoTask, so disabling from here runs exactly the code the task source runs.
      keyPath= ($taskPath + $taskName)
      where  = 'ref-task'
      via    = 'scheduled-task'
      taskPath = $taskPath
      taskName = $taskName
      triggers = ($triggerNames -join '、')
    })
  }
} catch { }

# ---------------------------------------------------------------------------
# 5. Services that start automatically
# ---------------------------------------------------------------------------
# StartMode=Auto means "starts at boot whether or not you log in", which is the
# definition of a startup item on a machine like this one where Run keys are
# almost empty because everything moved into services.
try {
  foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
    if ([string]$s.StartMode -ne 'Auto') { continue }
    $rows.Add([ordered]@{
      source = 'autorun'
      kind   = 'service'
      name   = [string]$s.Name
      state  = $(if ([string]$s.State -eq 'Running') { 'Running' } else { 'Stopped' })
      path   = [string]$s.PathName
      scope  = 'machine'
      keyPath= ('service\' + [string]$s.Name)
      where  = 'ref-service'
      via    = 'service'
      displayName = [string]$s.DisplayName
    })
  }
} catch { }

# ---------------------------------------------------------------------------
# 6. Active Setup (per-user logon stubs)
# ---------------------------------------------------------------------------
# Active Setup entries run once per user at logon when their recorded version is
# newer than what that user already ran. They are a real autostart mechanism but
# they are NOT switchable per item: the only field is `Version`, and blanking it
# makes the stub re-run rather than stop. So rows are reported as enabled with
# where='activesetup', and actions.ps1 refuses to toggle them with an explanation
# instead of pretending.
foreach ($asRoot in @(
    'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components')) {
  if (-not (Test-Path -LiteralPath $asRoot)) { continue }
  foreach ($c in (Get-ChildItem -LiteralPath $asRoot -ErrorAction SilentlyContinue)) {
    $props = Get-ItemProperty -LiteralPath $c.PSPath -ErrorAction SilentlyContinue
    if ($null -eq $props) { continue }
    $label = [string]$props.'(default)'
    if (-not $label) { $label = [string]$c.PSChildName }
    $rows.Add([ordered]@{
      source = 'autorun'
      kind   = 'activesetup'
      name   = $label
      state  = $(if ([string]$props.StubPath) { 'enabled' } else { 'Disabled' })
      path   = [string]$props.StubPath
      scope  = 'machine'
      keyPath= ($c.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')
      where  = 'activesetup'
      via    = 'active-setup'
      version = [string]$props.Version
    })
  }
}

$json = ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 4 -Compress
[Console]::Out.Write($json)
