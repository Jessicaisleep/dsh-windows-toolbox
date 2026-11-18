param([string]$ParamFile)

# ---------------------------------------------------------------------------
# tweaks.ps1 — 系统优化 / 安全加固 / WINDOWS 设置（声明式键值表驱动）
#
# The catalogue lives in lib/presets/tweaks.json, which is a filtered subset of
# ChrisTitusTech/winutil (MIT). Only the `registry` and `service` fields were
# taken — every InvokeScript/UndoScript was dropped on purpose: those are
# arbitrary PowerShell that cannot be audited statically, and executing a remote
# repo's code is not something a settings page should do.
#
# Each entry carries the value to apply AND the value to restore, so "applied"
# can be computed by comparison rather than tracked in a database, and a revert
# writes back the recorded original instead of guessing.
#
# Actions:
#   scan   — read every entry, report applied / not applied, never write
#   apply  — write the target values for the selected ids, capturing undo first
#   revert — write the recorded original values back
#
# Writes under HKLM need admin; HKCU does not. The probe reports needsAdmin per
# item so the panel can say which ones will be skipped before anything happens.
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$action = [string]$params.action
if (-not $action) { $action = 'scan' }
$dryRun = $true
if ($null -ne $params.dryRun) { $dryRun = [bool]$params.dryRun }
$wanted = @()
if ($params.ids) { $wanted = @($params.ids) }

$presetFile = Join-Path (Join-Path $PSScriptRoot '..') 'presets/tweaks.json'
if (-not (Test-Path -LiteralPath $presetFile)) {
    [Console]::Out.Write((@{ ok = $false; error = "预设文件缺失: $presetFile" } | ConvertTo-Json -Compress))
    exit 0
}
$preset = Get-Content -LiteralPath $presetFile -Raw -Encoding UTF8 | ConvertFrom-Json
$catalogue = @($preset.tweaks)

$isElevated = Test-Elevated
$items = New-ProbeList

function Get-CurrentValue {
    param([string]$Path, [string]$Name)
    try {
        $k = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $k.$Name
    } catch { return $null }
}

# Normalise a registry value to the string form the preset uses, so "0" and 0
# compare equal and a DWord 1 matches a preset "1".
#
# Absent is its own state, not "close enough". The preset's `original` field is
# often the literal "<RemoveEntry>", i.e. "this value did not exist before the
# tweak". Comparing an absent value against `original` and calling that
# "applied" reported Activity History as applied on a machine where none of its
# three keys exist — the tweak had never run. Absent only counts as applied when
# the target itself is "<RemoveEntry>".
function Test-EntryApplied {
    param($Entry)
    $cur = Get-CurrentValue -Path $Entry.path -Name $Entry.name
    if ($null -eq $cur) { return ($Entry.value -eq '<RemoveEntry>') }
    return ([string]$cur -eq [string]$Entry.value)
}

function Test-TweakApplied {
    param($Tweak)
    $all = $true
    foreach ($r in @($Tweak.registry)) {
        if (-not (Test-EntryApplied -Entry $r)) { $all = $false; break }
    }
    if ($all) {
        foreach ($s in @($Tweak.service)) {
            $svc = Get-Service -Name $s.name -ErrorAction SilentlyContinue
            if (-not $svc) { continue }
            if ([string]$svc.StartType -ne [string]$s.startupType) { $all = $false; break }
        }
    }
    return $all
}

# ---- apply / revert --------------------------------------------------------
if ($action -eq 'apply' -or $action -eq 'revert') {
    $results = New-ProbeList
    $allUndo = New-ProbeList
    $changed = 0

    # Revert prefers a PRECISE undo record when the caller passes one back: it
    # knows whether the value existed before, so "was absent" reverts to
    # deletion instead of writing the preset's placeholder 0. Without a record
    # we fall back to the declarative `original`, which is the best a
    # stateless revert can do — winutil behaves the same way.
    $givenUndo = @()
    if ($params.undo) { $givenUndo = @($params.undo) }
    $undoIndex = @{}
    foreach ($u in $givenUndo) {
        if ($u.tweak) { $undoIndex["$($u.tweak)|$($u.path)|$($u.name)"] = $u }
        elseif ($u.kind -eq 'service' -and $u.name) { $undoIndex["svc|$($u.name)|"] = $u }
    }

    # ---- safety net: export every key we are about to touch, before touching it
    #
    # This is not decoration. On 2026-11-17 a write path in this very file used
    # `New-Item -Force` on an existing key and wiped HKCU\...\Explorer\Advanced
    # down to zero values; there was no restore point, no RegBack for HKCU, and
    # no .reg export to fall back on, so the original values were unrecoverable
    # except for the few this session had independently measured. A `reg export`
    # costs tens of milliseconds and turns that class of mistake from permanent
    # into trivial. Never remove this to save time.
    $backupDir = Join-Path (Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox') 'regbackup'
    $backupFiles = New-ProbeList
    $backupError = ''
    if (-not $dryRun) {
        try {
            if (-not (Test-Path -LiteralPath $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
            }
            $touchedKeys = New-Object System.Collections.Generic.HashSet[string]
            foreach ($t in $catalogue) {
                if ($wanted.Count -gt 0 -and ($wanted -notcontains $t.id)) { continue }
                foreach ($r in @($t.registry)) {
                    if ($r.path) { [void]$touchedKeys.Add([string]$r.path) }
                }
            }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            foreach ($keyPath in $touchedKeys) {
                # reg.exe wants HKCU\... / HKLM\..., the preset uses the provider
                # form HKCU:\...
                $regPath = ($keyPath -replace '^HK(.*?):\\', 'HK$1\')
                $safe = ($regPath -replace '[\\/:*?"<>|]', '_')
                if ($safe.Length -gt 90) { $safe = $safe.Substring($safe.Length - 90) }
                $outFile = Join-Path $backupDir "$stamp-$safe.reg"
                & reg export $regPath $outFile /y 2>&1 | Out-Null
                if (Test-Path -LiteralPath $outFile) { $backupFiles.Add($outFile) }
            }
        } catch {
            $backupError = $_.Exception.Message
        }
        if ($backupError) {
            # Fail closed: a write we cannot back up is a write we do not make.
            Write-ProbeResult -Items (New-ProbeList) -Extra @{
                action = $action; dryRun = $false; changed = 0; elevated = $isElevated
                backupError = $backupError; undo = @()
            } -Note "已中止：无法备份注册表（$backupError）。没有写入任何内容。"
            exit 0
        }
    }

    foreach ($t in $catalogue) {
        if ($wanted.Count -gt 0 -and ($wanted -notcontains $t.id)) { continue }
        $undo = New-ProbeList
        $regWrites = 0
        $svcWrites = 0
        $skipped = New-ProbeList

        # Capture the pre-write state before anything is touched. This runs for
        # dry runs too, so the plan the panel shows and the undo it records come
        # from the same reading.
        foreach ($r in @($t.registry)) {
            $cur = Get-CurrentValue -Path $r.path -Name $r.name
            $undo.Add([ordered]@{
                tweak    = $t.id
                kind     = 'registry'
                path     = $r.path
                name     = $r.name
                existed  = ($null -ne $cur)
                previous = if ($null -ne $cur) { [string]$cur } else { '' }
                type     = $r.type
            })
        }
        foreach ($s in @($t.service)) {
            $svc = Get-Service -Name $s.name -ErrorAction SilentlyContinue
            $undo.Add([ordered]@{
                tweak    = $t.id
                kind     = 'service'
                name     = $s.name
                existed  = ($null -ne $svc)
                previous = if ($svc) { [string]$svc.StartType } else { '' }
            })
        }

        if ($dryRun) {
            Add-Item -List $results -Id $t.id -Group $t.category `
                -Label $(if (Get-OptionalString $t 'labelZh') { Get-OptionalString $t 'labelZh' } else { $t.content }) `
                -Status 'info' `
                -Value '将执行' -Detail "$(@($t.registry).Count) 个注册表值 · $(@($t.service).Count) 个服务" -Fix ''
            continue
        }

        foreach ($r in @($t.registry)) {
            $needsAdmin = $r.path -like 'HKLM:*' -or $r.path -like 'HKEY_LOCAL_MACHINE:*'
            if ($needsAdmin -and -not $isElevated) {
                Add-Item -List $skipped -Id "skip:$($r.path)" -Group $t.category -Label $r.name -Status 'skip' `
                    -Value '需管理员' -Detail $r.path -Fix '' -NeedsAdmin $true
                continue
            }

            # Resolve what to write. apply → the preset value; revert → the
            # recorded previous value when we have one, else the declarative
            # original.
            $targetValue = $r.value
            $removeIt = ($targetValue -eq '<RemoveEntry>')
            if ($action -eq 'revert') {
                $rec = $undoIndex["$($t.id)|$($r.path)|$($r.name)"]
                if ($null -ne $rec) {
                    if ($rec.existed -eq $false) { $removeIt = $true }
                    else { $targetValue = [string]$rec.previous; $removeIt = $false }
                } else {
                    $targetValue = $r.original
                    $removeIt = ($targetValue -eq '<RemoveEntry>')
                }
            }

            try {
                if ($removeIt) {
                    if ($null -ne (Get-CurrentValue -Path $r.path -Name $r.name)) {
                        Remove-ItemProperty -LiteralPath $r.path -Name $r.name -Force -ErrorAction Stop
                    }
                } else {
                    $regType = switch ($r.type) {
                        'DWord' { 'DWord' }
                        'QWord' { 'QWord' }
                        'String' { 'String' }
                        'ExpandString' { 'ExpandString' }
                        'MultiString' { 'MultiString' }
                        default { 'String' }
                    }
                    $cast = switch ($regType) {
                        'DWord' { [int]$targetValue }
                        'QWord' { [int64]$targetValue }
                        default { [string]$targetValue }
                    }
                    # *** DANGER: New-Item -Force DESTROYS an existing key ***
                    # Measured 2026-11-17: `New-Item -Path <existing key> -Force`
                    # does NOT act as a no-op — it re-creates the key and takes
                    # every value and subkey with it. Running it against
                    # HKCU\...\Explorer\Advanced reduced that key from dozens of
                    # values to zero. `-Force` is only safe on a key that does not
                    # yet exist, and probing whether it exists costs ~10ms via
                    # Get-Item (NOT 387ms — that figure was for Test-Path on a
                    # missing key, and it led to this shortcut in the first place).
                    if ($null -eq (Get-Item -LiteralPath $r.path -ErrorAction SilentlyContinue)) {
                        New-Item -Path $r.path -ErrorAction Stop | Out-Null
                    }
                    New-ItemProperty -LiteralPath $r.path -Name $r.name -Value $cast -PropertyType $regType -Force -ErrorAction Stop | Out-Null
                }
                $regWrites++
            } catch {
                Add-Item -List $skipped -Id "err:$($r.path)" -Group $t.category -Label $r.name -Status 'bad' `
                    -Value '写入失败' -Detail $_.Exception.Message -Fix '' -NeedsAdmin $needsAdmin
            }
        }

        foreach ($s in @($t.service)) {
            if (-not $isElevated) {
                Add-Item -List $skipped -Id "skip:svc:$($s.name)" -Group $t.category -Label $s.name -Status 'skip' `
                    -Value '需管理员' -Detail "服务启动类型" -Fix '' -NeedsAdmin $true
                continue
            }
            $targetType = if ($action -eq 'apply') { $s.startupType } else { $s.originalType }
            try {
                Set-Service -Name $s.name -StartupType $targetType -ErrorAction Stop
                $svcWrites++
            } catch {
                Add-Item -List $skipped -Id "err:svc:$($s.name)" -Group $t.category -Label $s.name -Status 'bad' `
                    -Value '设置失败' -Detail $_.Exception.Message -Fix '' -NeedsAdmin $true
            }
        }

        $changed++
        foreach ($u in $undo) { $allUndo.Add($u) }
        Add-Item -List $results -Id $t.id -Group $t.category `
            -Label $(if (Get-OptionalString $t 'labelZh') { Get-OptionalString $t 'labelZh' } else { $t.content }) `
            -Status 'ok' `
            -Value $(if ($action -eq 'apply') { '已应用' } else { '已还原' }) `
            -Detail "注册表 $regWrites 项 · 服务 $svcWrites 项 · 跳过 $($skipped.Count) 项" -Fix ''
        foreach ($s in $skipped) { $results.Add($s) }
    }
    Write-ProbeResult -Items $results -Extra @{
        action   = $action
        dryRun   = $dryRun
        changed  = $changed
        elevated = $isElevated
        undo     = @($allUndo.ToArray())
        backupDir = $backupDir
        backups  = @($backupFiles.ToArray())
    } -Note $(if ($dryRun) { '预演：没有写入任何内容。' }
             elseif ($action -eq 'apply') { '已写入。把输出的 undo 记录保存下来，回滚时传回可精确还原到写入前的状态（包括“原本不存在”的值）。' }
             else { '已回滚。' })
    exit 0
}

# ---- scan ------------------------------------------------------------------
foreach ($t in $catalogue) {
    $applied = Test-TweakApplied -Tweak $t

    # Report what the first registry value actually reads, so the panel shows a
    # measurement rather than a derived flag alone.
    $first = @($t.registry) | Select-Object -First 1
    $probeValue = ''
    if ($first) {
        $cur = Get-CurrentValue -Path $first.path -Name $first.name
        $probeValue = if ($null -eq $cur) { 'unset' } else { [string]$cur }
    }
    $svcText = ''
    if (@($t.service).Count -gt 0) {
        $parts = foreach ($s in @($t.service)) {
            $svc = Get-Service -Name $s.name -ErrorAction SilentlyContinue
            if ($svc) { "$($s.name)=$($svc.StartType)" } else { "$($s.name)=absent" }
        }
        $svcText = ($parts -join ' · ')
    }

    $needsAdmin = $false
    foreach ($r in @($t.registry)) {
        if ($r.path -like 'HKLM:*' -or $r.path -like 'HKEY_LOCAL_MACHINE:*') { $needsAdmin = $true; break }
    }
    if (-not $needsAdmin -and @($t.service).Count -gt 0) { $needsAdmin = $true }

    $detailParts = New-Object System.Collections.Generic.List[string]
    if ($probeValue) { $detailParts.Add("当前=$probeValue") }
    if ($svcText) { $detailParts.Add($svcText) }

    # Curated Chinese wording, when the preset has it (see lib/presets/tweaks.json).
    # The upstream winutil text is written for people who already know what
    # "Activity History" is; a non-technical reader does not. Label and detail
    # are what the panel actually prints, so the translation has to arrive on
    # those fields — adding it only to the preset would never reach the screen.
    $labelZh = Get-OptionalString $t 'labelZh'
    $descZh = Get-OptionalString $t 'descZh'
    if ($descZh) { $detailParts.Add($descZh) } elseif ($t.description) { $detailParts.Add($t.description) }
    $effectZh = Get-OptionalString $t 'effectZh'
    if ($effectZh) { $detailParts.Add("效果：$effectZh") }
    $riskZh = Get-OptionalString $t 'riskZh'
    if ($riskZh) { $detailParts.Add("风险：$riskZh") }

    $shownLabel = if ($labelZh) { $labelZh } else { $t.content }

    Add-Item -List $items -Id $t.id -Group $t.category -Label $shownLabel `
        -Status $(if ($applied) { 'ok' } else { 'warn' }) `
        -Value $(if ($applied) { '已应用' } else { '未应用' }) `
        -Detail ($detailParts -join ' | ') `
        -Fix $(if ($applied) { '' } else { '可应用' }) `
        -NeedsAdmin $needsAdmin `
        -Extra @{
            labelZh    = $labelZh
            whatZh     = (Get-OptionalString $t 'whatZh')
            effectZh   = $effectZh
            riskZh     = $riskZh
            audienceZh = (Get-OptionalString $t 'audienceZh')
            labelEn    = (Get-OptionalString $t 'content')
        }
}

Write-ProbeResult -Items $items -Extra @{
    action = 'scan'
    total  = $catalogue.Count
    source = $preset.source
    license = $preset.license
} -Note '数据源 ChrisTitusTech/winutil (MIT)，仅取 registry/service 字段，InvokeScript 全部丢弃。'
