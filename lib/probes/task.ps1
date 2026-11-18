# task.ps1 - enumerate scheduled tasks (L3 registration point).
# Read-only. One JSON array on stdout.
#
# Two quirks of the Windows task store that this handles explicitly:
#
# 1. "by user disabled" sentinel. When you disable a task's *action* (not the
#    whole task) in Task Scheduler, Windows stores the literal string
#    "by user disabled" as <Command>. Verified on this machine 2026-11-17: 16
#    tasks carry it, and the raw XML under C:\Windows\System32\Tasks really does
#    say <Command>by user disabled</Command>. So it is not a probe failure; it is
#    a real value that must not be rendered as a command line.
#
# 2. Settings.Enabled=false (task disabled) is separate from an action being
#    disabled. Both are reported, so the UI can tell "never runs" from
#    "runs but its payload was switched off".
param([string]$ParamFile)

# Node reads our stdout as UTF-8; without this line PowerShell encodes it in the
# console code page (936/GBK on a zh-CN box) and every non-ASCII character
# arrives as mojibake. Measured 2026-11-17: all Chinese messages were garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$SENTINEL = 'by user disabled'

$rows = New-Object System.Collections.Generic.List[object]
foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
  $acts = @($t.Actions | ForEach-Object { $_.Execute }) | Where-Object { $_ }
  $cmds = @($t.Actions | ForEach-Object {
    $line = [string]$_.Execute
    if ($_.Arguments) { $line = "$line $($_.Arguments)" }
    $line
  }) | Where-Object { $_ }

  $actionDisabled = ($acts -contains $SENTINEL)
  $realCmds = @($cmds | Where-Object { $_ -ne $SENTINEL -and $_ -notlike "$SENTINEL*" })
  $realActs = @($acts | Where-Object { $_ -ne $SENTINEL })

  # Trigger kinds only - these are cheap and stable across host versions.
  $trigs = @($t.Triggers | ForEach-Object { $_.CimClass.CimClassName -replace '^MSFT_Task', '' }) |
           Where-Object { $_ } | Select-Object -Unique

  $user = ''
  try { $user = [string]$t.Principal.UserId } catch { }

  # Settings.Enabled is the task-level switch.
  $taskEnabled = $true
  try { if ($null -ne $t.Settings.Enabled) { $taskEnabled = [bool]$t.Settings.Enabled } } catch { }
  if ([string]$t.State -eq 'Disabled') { $taskEnabled = $false }

  $rows.Add([ordered]@{
    source         = 'task'
    kind           = 'scheduledtask'
    name           = "$($t.TaskPath)$($t.TaskName)"
    taskPath       = [string]$t.TaskPath
    taskName       = [string]$t.TaskName
    state          = [string]$t.State
    taskEnabled    = $taskEnabled
    actionDisabled = $actionDisabled
    # Empty when the only action is the sentinel - better a blank column than a
    # command line that does not exist.
    path           = ($realCmds -join ' | ')
    executables    = ($realActs -join ' | ')
    triggers       = ($trigs -join ',')
    author         = [string]$t.Author
    user           = $user
    description    = [string]$t.Description
  })
}

$json = ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 4 -Compress
[Console]::Out.Write($json)
