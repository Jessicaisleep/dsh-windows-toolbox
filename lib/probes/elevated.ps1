<#
.SYNOPSIS
  Elevation bridge: run actions.ps1 inside a real elevated (UAC) process.

.DESCRIPTION
  This is the only place in the plugin that asks Windows for administrator
  rights, and it does so through the real UAC channel — never by pretending.

  Two roles in one file:

    launcher (default)   runs NON-elevated (as the DSH host does), parses the
                         caller's params, calls Start-Process -Verb RunAs to
                         start an elevated copy of THIS script, then polls for
                         the result file until it appears or the budget runs
                         out (default 180 s). The caller (index.js) only ever
                         sees one JSON document on stdout, and a cancelled UAC
                         prompt is a normal answer — ok:false / cancelled:true —
                         never an exception and never an HTTP 500.

    -Child               runs INSIDE the elevated process. It executes
                         actions.ps1 with the params the launcher wrote, takes
                         that script's stdout and publishes it as the result
                         file (written to <name>.part first, then moved, so a
                         polling launcher never reads a half-written file).

    -Probe               child mode that runs no action at all: it reports who
                         the elevated token belongs to. That is what the
                         panel's "request elevation" button uses to prove the
                         channel works before any destructive action is
                         offered.

  Why a file and not stdout: the elevated process has no usable stdio pipe back
  to the non-elevated caller (Start-Process -Verb RunAs cannot redirect into an
  existing pipe), so the result travels through
  $env:TEMP\dsh-wpm-elevated-<guid>.json and the launcher deletes it afterwards.

  Measured on this machine (2026-11-17): the account is an administrator running
  with a filtered token (isAdmin=False, BUILTIN\Administrators = deny-only), and
  UAC is EnableLUA=1 / ConsentPromptBehaviorAdmin=5 / PromptOnSecureDesktop=1,
  so a consent dialog really is shown — and cancelling it really does raise
  "The operation was canceled by the user" (zh-CN: "操作已被用户取消。").
  Both spellings are matched, plus Win32 error 1223, which is the locale-free
  truth behind them.
#>
param(
  [string]$ParamFile,
  [switch]$Child,
  [switch]$Probe,
  [string]$ActionFile,
  [string]$ResultFile,
  [string]$OutFile,
  [string]$ErrFile,
  [int]$TimeoutSecs = 180,
  # Test hook: run the cancel matcher against a genuine Win32 1223 exception and
  # emit exactly what a real cancelled UAC prompt emits. Only used by tests.
  [switch]$SelfTest,
  # Test hook: make the launcher take its cancel path without showing a prompt,
  # by throwing the real Win32 1223 error Start-Process would throw.
  [switch]$SimulateCancel
)

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'Stop'

function Emit($obj) {
  [Console]::Out.Write((ConvertTo-Json -InputObject $obj -Depth 8 -Compress))
  [Console]::Out.Flush()
}

function Fail($msg) {
  Emit ([ordered]@{ ok = $false; changed = $false; cancelled = $false; elevated = $false; message = [string]$msg })
  exit 0
}

<#
  Was this Start-Process failure the user dismissing the UAC prompt?

  Start-Process -Verb RunAs throws a Win32Exception for ERROR_CANCELLED (1223).
  Its Message is LOCALISED, so matching only the English sentence would report
  a Chinese Windows as "elevation failed" instead of "you cancelled". Match the
  numeric code first (locale-free), then both known spellings as a fallback for
  hosts that wrap the exception.
#>
function Test-CancelledByUser($err) {
  if ($null -eq $err) { return $false }
  try {
    $ex = $err.Exception
    while ($null -ne $ex -and -not ($ex -is [System.ComponentModel.Win32Exception])) { $ex = $ex.InnerException }
    if ($null -ne $ex -and [int]$ex.NativeErrorCode -eq 1223) { return $true }
  } catch { /* not a Win32Exception path — fall through to the text check */ }
  $msg = ''
  try { $msg = [string]$err.Exception.Message } catch { $msg = [string]$err }
  if ($msg -match '(?i)cancel') { return $true }   # "The operation was canceled by the user"
  if ($msg -match '取消') { return $true }         # "操作已被用户取消。"
  return $false
}

function Write-ResultFile([string]$path, [string]$text) {
  $part = "$path.part"
  [System.IO.File]::WriteAllText($part, $text, (New-Object System.Text.UTF8Encoding $false))
  Move-Item -LiteralPath $part -Destination $path -Force
}

# ------------------------------------------------------------------ self test
if ($SelfTest) {
  $fake = $null
  try { throw [System.ComponentModel.Win32Exception]::new(1223) } catch { $fake = $_ }
  if (Test-CancelledByUser $fake) {
    Emit ([ordered]@{
        ok = $false; changed = $false; cancelled = $true; elevated = $false
        message = '你取消了 UAC 提权'; selfTest = $true
      })
  } else {
    Emit ([ordered]@{ ok = $false; changed = $false; cancelled = $false; elevated = $false; message = 'cancel matcher did not recognise Win32 1223'; selfTest = $true })
  }
  exit 0
}

$psExe = (Get-Process -Id $PID).Path
$scriptPath = $PSCommandPath

# --------------------------------------------------------------------- child
if ($Child) {
  try {
    if ($Probe) {
      $id = [Security.Principal.WindowsIdentity]::GetCurrent()
      $isAdmin = $false
      try {
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
      } catch { $isAdmin = $false }
      $payload = ConvertTo-Json -InputObject ([ordered]@{
          ok = $isAdmin; changed = $false; elevated = $isAdmin; probe = $true
          user = [string]$id.Name
          message = if ($isAdmin) { '提权通道已就绪' } else { '提权进程已启动，但令牌里没有管理员组' }
        }) -Depth 6 -Compress
      Write-ResultFile $ResultFile $payload
      exit 0
    }

    if (-not $ActionFile -or -not (Test-Path -LiteralPath $ActionFile)) {
      Write-ResultFile $ResultFile (ConvertTo-Json -InputObject ([ordered]@{
            ok = $false; changed = $false; elevated = $true; message = '提权进程没有拿到参数文件'
          }) -Depth 6 -Compress)
      exit 0
    }
    $actionScript = Join-Path $PSScriptRoot 'actions.ps1'
    if (-not (Test-Path -LiteralPath $actionScript)) {
      Write-ResultFile $ResultFile (ConvertTo-Json -InputObject ([ordered]@{
            ok = $false; changed = $false; elevated = $true; message = "找不到 actions.ps1: $actionScript"
          }) -Depth 6 -Compress)
      exit 0
    }
    if (-not $OutFile) { $OutFile = [System.IO.Path]::GetTempFileName() }
    if (-not $ErrFile) { $ErrFile = [System.IO.Path]::GetTempFileName() }

    # actions.ps1 ends with `exit 0` on its failure paths, so it MUST run in its
    # own process: calling it with & would terminate this elevated process
    # before the result file is written.
    $innerArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ParamFile "{1}"' -f $actionScript, $ActionFile
    $null = Start-Process -FilePath $psExe -ArgumentList $innerArgs -Wait -NoNewWindow -PassThru `
      -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile

    $text = ''
    if (Test-Path -LiteralPath $OutFile) { $text = [System.IO.File]::ReadAllText($OutFile) }
    if (-not $text.Trim()) {
      $errText = ''
      if (Test-Path -LiteralPath $ErrFile) { $errText = ([System.IO.File]::ReadAllText($ErrFile)).Trim() }
      $text = ConvertTo-Json -InputObject ([ordered]@{
          ok = $false; changed = $false; elevated = $true
          message = if ($errText) { "动作脚本没有返回结果: $errText" } else { '动作脚本没有返回结果' }
        }) -Depth 6 -Compress
    }
    Write-ResultFile $ResultFile $text
  } catch {
    $payload = ConvertTo-Json -InputObject ([ordered]@{
        ok = $false; changed = $false; elevated = $true
        message = ('提权进程内部错误: ' + [string]$_.Exception.Message)
      }) -Depth 6 -Compress
    try { Write-ResultFile $ResultFile $payload } catch { }
  }
  exit 0
}

# ------------------------------------------------------------------ launcher
$actionText = '{}'
$wantProbe = [bool]$Probe
$budget = [Math]::Max(1, $TimeoutSecs)
if ($ParamFile) {
  if (-not (Test-Path -LiteralPath $ParamFile)) { Fail "缺少参数文件: $ParamFile" }
  $raw = Get-Content -LiteralPath $ParamFile -Raw -Encoding UTF8
  if (-not $raw -or -not $raw.Trim()) { $raw = '{}' }
  try {
    $parsedIn = $raw | ConvertFrom-Json
    $actionText = $parsedIn | ConvertTo-Json -Depth 8 -Compress
  } catch {
    Fail ('参数文件不是合法 JSON: ' + [string]$_.Exception.Message)
  }
  # `probe` / `timeoutSecs` / `simulateCancel` travel inside the params document
  # so that index.js can reach every mode through the one runProbe() path (which
  # only forwards a -ParamFile, never extra switches). simulateCancel is a test
  # hook: it makes the launcher take its cancel branch without showing a prompt,
  # so the "user pressed No" answer is verified over real HTTP, not just by
  # reading the code.
  try {
    if ($parsedIn.probe -eq $true) { $wantProbe = $true }
    if ($parsedIn.simulateCancel -eq $true) { $SimulateCancel = $true }
    if ($null -ne $parsedIn.timeoutSecs) {
      $n = 0
      if ([int]::TryParse([string]$parsedIn.timeoutSecs, [ref]$n) -and $n -ge 5) { $budget = [Math]::Min($n, 600) }
    }
  } catch { }
  # A dry run writes nothing, so it never needs -- and must never trigger -- a
  # UAC prompt. Refuse rather than put a consent dialog in front of a preview.
  try {
    if ($parsedIn.dryRun -eq $true) { Fail '预演不需要提权：请直接调用 /api/action（dryRun=true）' }
  } catch { }
}

$guid = [guid]::NewGuid().ToString('N')
$resultFile = Join-Path $env:TEMP "dsh-wpm-elevated-$guid.json"
$actionFile = Join-Path $env:TEMP "dsh-wpm-elevated-$guid.params.json"
$outFile = Join-Path $env:TEMP "dsh-wpm-elevated-$guid.out"
$errFile = Join-Path $env:TEMP "dsh-wpm-elevated-$guid.err"

function Clear-WorkFiles {
  foreach ($p in @($resultFile, "$resultFile.part", $actionFile, $outFile, $errFile)) {
    try { if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force } } catch { }
  }
}

try {
  [System.IO.File]::WriteAllText($actionFile, $actionText, (New-Object System.Text.UTF8Encoding $false))

  $childParts = @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', ('"{0}"' -f $scriptPath),
    '-Child'
  )
  if ($wantProbe) {
    $childParts += '-Probe'
  } else {
    $childParts += '-ActionFile'
    $childParts += ('"{0}"' -f $actionFile)
  }
  $childParts += @('-ResultFile', ('"{0}"' -f $resultFile), '-OutFile', ('"{0}"' -f $outFile), '-ErrFile', ('"{0}"' -f $errFile))
  $childArg = $childParts -join ' '

  $proc = $null
  try {
    # Test hook: throw the genuine Win32 cancel error before touching UAC, so
    # the whole launcher cancel path (payload, cleanup, exit code) is exercised
    # by a test instead of only ever being read.
    if ($SimulateCancel) { throw [System.ComponentModel.Win32Exception]::new(1223) }
    $proc = Start-Process -FilePath $psExe -Verb RunAs -PassThru -ArgumentList $childArg -ErrorAction Stop
  } catch {
    $cancelled = Test-CancelledByUser $_
    Clear-WorkFiles
    if ($cancelled) {
      Emit ([ordered]@{
          ok = $false; changed = $false; cancelled = $true; elevated = $false
          message = '你取消了 UAC 提权'
        })
    } else {
      Emit ([ordered]@{
          ok = $false; changed = $false; cancelled = $false; elevated = $false
          message = ('无法发起提权进程: ' + [string]$_.Exception.Message)
        })
    }
    exit 0
  }

  $deadline = (Get-Date).AddSeconds($budget)
  $text = ''
  $exitedAt = $null
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $resultFile) {
      try {
        $t = [System.IO.File]::ReadAllText($resultFile)
        if ($t.Trim()) { $text = $t; break }
      } catch { /* still being written — poll again */ }
    }
    if ($proc) {
      $gone = $false
      try { $gone = $proc.HasExited } catch { $gone = $true }
      if ($gone) {
        if (-not $exitedAt) { $exitedAt = Get-Date }
        elseif (((Get-Date) - $exitedAt).TotalSeconds -gt 3) { break }
      }
    }
    Start-Sleep -Milliseconds 200
  }

  if (-not $text) {
    $exitedNote = ''
    if ($proc -and $exitedAt) { $exitedNote = '（提权进程已退出但没有留下结果文件：可能是 UAC 已取消，或动作被组策略拦截）' }
    Emit ([ordered]@{
        ok = $false; changed = $false; cancelled = $false; elevated = $true; timeout = $true
        message = ("提权操作在 {0} 秒内没有返回结果{1}" -f $budget, $exitedNote)
      })
    exit 0
  }

  $start = $text.IndexOf('{')
  $end = $text.LastIndexOf('}')
  if ($start -lt 0 -or $end -le $start) {
    Emit ([ordered]@{
        ok = $false; changed = $false; elevated = $true
        message = ('提权结果不是 JSON: ' + $text.Substring(0, [Math]::Min(200, $text.Length)))
      })
    exit 0
  }
  try {
    $parsed = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
  } catch {
    Emit ([ordered]@{
        ok = $false; changed = $false; elevated = $true
        message = ('提权结果无法解析: ' + [string]$_.Exception.Message)
      })
    exit 0
  }

  $out = [ordered]@{}
  foreach ($prop in $parsed.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
  $out['elevated'] = $true
  if (-not $out.Contains('ok')) { $out['ok'] = $false }
  if (-not $out.Contains('changed')) { $out['changed'] = $false }
  if (-not $out.Contains('cancelled')) { $out['cancelled'] = $false }
  Emit $out
} finally {
  Clear-WorkFiles
}
exit 0
