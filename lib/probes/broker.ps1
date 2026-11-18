param(
    [Parameter(Mandatory = $true)][string]$JobDir,
    [Parameter(Mandatory = $true)][string]$Token,
    [int]$IdleSecs = 900
)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'

<#
    Resident elevated worker ("broker").

    WHY THIS EXISTS
    ---------------
    The first version of elevation started a fresh `Start-Process -Verb RunAs`
    child per action. Every child is a new process, so every action showed the
    user another UAC prompt — asking twice for one cleanup is exactly the
    behaviour the panel was told to stop.

    This process is started ONCE. It holds the administrator token for the whole
    session and executes jobs handed to it through a directory. The user sees one
    prompt; every later elevated action rides on the token this process already
    has.

    PROTOCOL (all files in $JobDir, all JSON, all UTF-8 without BOM)
    ---------------------------------------------------------------
      ready.json       written on start: {ok, pid, elevated, user, token, started}
      beat.json        rewritten every loop: {at, pid, jobs}
      job-<id>.json    host -> broker: {id, token, probe, params, timeoutMs}
      res-<id>.json    broker -> host: {id, ok, output, error, elapsedMs, elevated}
      halt.json        host -> broker: stop after the current job

    The token is checked on every job so a stray file dropped into the directory
    by some other program cannot make this process run a probe. It is NOT a
    security boundary against the same user (that user can read the token); it
    stops accidents, and the honest documentation says so.

    EXIT CONDITIONS: halt.json, or $IdleSecs without a job. Never on its own
    initiative mid-job.
#>

$meta = [ordered]@{
    ok       = $true
    kind     = 'broker'
    elevated = $false
    user     = ''
    pid      = $PID
    token    = $Token
    started  = (Get-Date).ToString('o')
    host     = $env:COMPUTERNAME
}

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    $meta.elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $meta.user = [string]$id.Name
} catch { }

function Write-Json {
    param([string]$Path, $Object)
    $text = $Object | ConvertTo-Json -Depth 8 -Compress
    $part = "$Path.part"
    [System.IO.File]::WriteAllText($part, $text, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $part -Destination $Path -Force
}

if (-not (Test-Path -LiteralPath $JobDir)) {
    New-Item -ItemType Directory -Path $JobDir -Force | Out-Null
}

Write-Json -Path (Join-Path $JobDir 'ready.json') -Object $meta

$lastJob = Get-Date
$served = 0

while ($true) {
    if (Test-Path -LiteralPath (Join-Path $JobDir 'halt.json')) { break }

    $jobs = @(Get-ChildItem -LiteralPath $JobDir -Filter 'job-*.json' -ErrorAction SilentlyContinue)
    if ($jobs.Count -eq 0) {
        $idle = ((Get-Date) - $lastJob).TotalSeconds
        if ($idle -ge $IdleSecs) {
            Write-Json -Path (Join-Path $JobDir 'bye.json') -Object ([ordered]@{
                    ok = $true; reason = 'idle'; idleSecs = [int]$idle; served = $served
                })
            break
        }
    }

    foreach ($file in $jobs) {
        $job = $null
        try {
            $raw = [System.IO.File]::ReadAllText($file.FullName)
            $job = $raw | ConvertFrom-Json
        } catch {
            # Unreadable or half-written: drop it rather than spin on it forever.
            Remove-Item -LiteralPath $file.FullName -Force
            continue
        }

        $jobId = [string]$job.id
        if ([string]::IsNullOrWhiteSpace($jobId)) {
            Remove-Item -LiteralPath $file.FullName -Force
            continue
        }

        $resPath = Join-Path $JobDir "res-$jobId.json"

        if ([string]$job.token -ne $Token) {
            Write-Json -Path $resPath -Object ([ordered]@{
                    id = $jobId; ok = $false; elevated = $meta.elevated
                    error = 'job token mismatch — refusing to run'
                })
            Remove-Item -LiteralPath $file.FullName -Force
            continue
        }

        $started = Get-Date
        $probe = [string]$job.probe
        $probeOk = -not [string]::IsNullOrWhiteSpace($probe) -and (Test-Path -LiteralPath $probe)
        if (-not $probeOk) {
            Write-Json -Path $resPath -Object ([ordered]@{
                    id = $jobId; ok = $false; elevated = $meta.elevated
                    error = "probe not found: $probe"
                })
            Remove-Item -LiteralPath $file.FullName -Force
            continue
        }

        $paramFile = Join-Path $JobDir "params-$jobId.json"
        try {
            $params = $job.params
            if ($null -eq $params) { $params = @{} }
            $text = $params | ConvertTo-Json -Depth 8 -Compress
            if ([string]::IsNullOrWhiteSpace($text)) { $text = '{}' }
            [System.IO.File]::WriteAllText($paramFile, $text, (New-Object System.Text.UTF8Encoding $false))
        } catch {
            Write-Json -Path $resPath -Object ([ordered]@{
                    id = $jobId; ok = $false; elevated = $meta.elevated
                    error = "could not write params: $([string]$_.Exception.Message)"
                })
            Remove-Item -LiteralPath $file.FullName -Force
            continue
        }

        $captured = $null
        $failed = $null
        $outFile = Join-Path $JobDir "out-$jobId.txt"
        $errFile = Join-Path $JobDir "err-$jobId.txt"
        try {
            # The probe MUST run in its own process. actions.ps1 and several other
            # probes end with `exit 0` on their failure paths, and running them
            # in-process would kill this broker on the first refused action —
            # taking the admin token with it and forcing another UAC prompt.
            # This is the same reason elevated.ps1 spawned a child.
            $psExe = (Get-Process -Id $PID).Path
            $childArgs = @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $probe, '-ParamFile', $paramFile
            )
            $child = Start-Process -FilePath $psExe -ArgumentList $childArgs `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            if ($null -ne $child -and $null -ne $child.ExitCode -and $child.ExitCode -ne 0) {
                # A non-zero exit usually still carries a JSON document that
                # explains itself; only record the code, let the host decide.
                $failed = $null
            }
            $captured = [System.IO.File]::ReadAllText($outFile)
        } catch {
            $failed = [string]$_.Exception.Message
        }

        foreach ($scratch in @($paramFile, $outFile, $errFile)) {
            Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $file.FullName -Force

        $elapsed = [int](((Get-Date) - $started).TotalMilliseconds)
        $served += 1
        $lastJob = Get-Date

        if ($null -ne $failed) {
            Write-Json -Path $resPath -Object ([ordered]@{
                    id = $jobId; ok = $false; elevated = $meta.elevated
                    error = $failed; elapsedMs = $elapsed
                })
            continue
        }

        # Resolve the probe's own ok flag without trusting its text to be JSON:
        # a probe that printed diagnostics ahead of its document must not be
        # reported as a broker failure.
        $parsed = $null
        try { $parsed = $captured | ConvertFrom-Json } catch { }
        $probeOkFlag = $true
        if ($null -ne $parsed -and $null -ne $parsed.PSObject.Properties['ok']) {
            $probeOkFlag = [bool]$parsed.ok
        }

        Write-Json -Path $resPath -Object ([ordered]@{
                id        = $jobId
                ok        = $probeOkFlag
                elevated  = $meta.elevated
                elapsedMs = $elapsed
                output    = [string]$captured
            })
    }

    Write-Json -Path (Join-Path $JobDir 'beat.json') -Object ([ordered]@{
            at = (Get-Date).ToString('o'); pid = $PID; jobs = $served
        })

    Start-Sleep -Milliseconds 150
}
