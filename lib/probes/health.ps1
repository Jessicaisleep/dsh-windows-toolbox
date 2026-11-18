param([string]$ParamFile)

# ---------------------------------------------------------------------------
# health.ps1 — system health check ("系统体检 / 急救箱").
#
# Read-only. Every item reports whether it is healthy, what the measured value
# is, and what the machine's own baseline looks like — never a bare score. A
# number without a threshold cannot be argued with, so each check carries an
# explicit `bad` condition written next to it.
#
# Nothing here repairs anything. Fixes belong in separate, explicitly named
# actions so a scan can never change state behind the user's back.
#
# UTF-8 on stdout (PowerShell otherwise emits the OEM code page; Node reads
# mojibake).
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'

$params = @{}
if ($ParamFile -and (Test-Path -LiteralPath $ParamFile)) {
    $raw = Get-Content -LiteralPath $ParamFile -Raw -Encoding UTF8
    if ($raw) { $params = $raw | ConvertFrom-Json }
}

$started = Get-Date
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param(
        [string]$Id,
        [string]$Label,
        [string]$Status,     # ok | warn | bad | skip
        [string]$Value,
        [string]$Detail,
        $FixHint = ''
    )
    $checks.Add([ordered]@{
        id = $Id
        label = $Label
        status = $Status
        value = $Value
        detail = $Detail
        fixHint = $FixHint
    })
}

# ---- 1. disks ----------------------------------------------------------------
# Thresholds are percentage-based, not absolute: a 128 GB system disk at 10% free
# is in trouble while a 4 TB data disk at 10% free is fine.
$disks = [System.Collections.Generic.List[object]]::new()
foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
    $size = [int64]$v.Size
    if ($size -le 0) { continue }
    $free = [int64]$v.FreeSpace
    $usedPct = [math]::Round(100.0 * ($size - $free) / $size, 1)
    $freeGb = [math]::Round($free / 1GB, 1)
    $sizeGb = [math]::Round($size / 1GB, 1)
    # Grade each disk on its OWN size, then report the worst one. Grading by
    # used% alone and picking the max is wrong on a mixed machine: this box has
    # C: 45% used on 302 GB but E: 51% used with 937 GB still free, so a
    # percentage-max picked E: and called it "the tightest partition" while the
    # actually-small system disk went unmentioned.
    #   95%+ used, OR free < 5% of size and < 10 GB  → bad
    #   90%+ used, OR free < 10% of size             → warn
    $freePct = [math]::Round(100.0 * $free / $size, 1)
    $level = 'ok'
    if ($usedPct -ge 95 -or ($freePct -lt 5 -and $freeGb -lt 10)) { $level = 'bad' }
    elseif ($usedPct -ge 90 -or $freePct -lt 10) { $level = 'warn' }
    $disks.Add([ordered]@{
        drive = $v.DeviceID
        label = $v.VolumeName
        sizeGb = $sizeGb
        freeGb = $freeGb
        usedPct = $usedPct
        freePct = $freePct
        level = $level
        fileSystem = $v.FileSystem
    })
}
# Scriptblock sort (see the OrderedDictionary note above). One composite key so
# the ordering is unambiguous: worst level first, then the more-used disk.
# (Passing two keys with -Descending:$false sorts both ascending, which would
# pick the LEAST-used disk inside the same level.)
$rank = @{ bad = 0; warn = 1; ok = 2 }
$worstDisk = $disks | Sort-Object -Property { ([double]$rank[[string]$_.level]) * 1000 - [double]$_.usedPct } | Select-Object -First 1
if ($null -eq $worstDisk) {
    Add-Check 'disk' '磁盘空间' 'skip' '' '没有取到磁盘信息'
} else {
    $line = "$($worstDisk.drive) 已用 $($worstDisk.usedPct)%（剩 $($worstDisk.freeGb) GB / 共 $($worstDisk.sizeGb) GB）"
    $all = (($disks | ForEach-Object { "$($_.drive) $($_.usedPct)%" }) -join '，')
    switch ($worstDisk.level) {
        'bad' { Add-Check 'disk' '磁盘空间' 'bad' $line "共 $($disks.Count) 个分区：$all" '清理垃圾文件或卸载不用的程序；系统盘剩余低于 10 GB 会影响更新' }
        'warn' { Add-Check 'disk' '磁盘空间' 'warn' $line "共 $($disks.Count) 个分区：$all" '建议清理；剩余空间低于 10% 会影响更新与休眠文件' }
        default { Add-Check 'disk' '磁盘空间' 'ok' $line "共 $($disks.Count) 个分区：$all" }
    }
}

# ---- 2. memory ---------------------------------------------------------------
# Commit charge (committed bytes / commit limit) is the number that actually
# predicts "this machine will start failing allocations"; raw free RAM is not,
# because Windows keeps free RAM near zero on purpose (standby cache).
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$memTotalGb = 0
$memFreeGb = 0
if ($os) {
    $memTotalGb = [math]::Round([int64]$os.TotalVisibleMemorySize / 1MB, 1)
    $memFreeGb = [math]::Round([int64]$os.FreePhysicalMemory / 1MB, 1)
}
$commit = Get-Counter -Counter '\Memory\% Committed Bytes In Use' -ErrorAction SilentlyContinue
$commitPct = $null
if ($commit -and $commit.CounterSamples.Count -gt 0) { $commitPct = [math]::Round([double]$commit.CounterSamples[0].CookedValue, 1) }
if ($null -eq $commitPct) {
    Add-Check 'memory' '内存' 'ok' "$memFreeGb GB 可用 / $memTotalGb GB" '已提交内存占用未能读取'
} elseif ($commitPct -ge 90) {
    Add-Check 'memory' '内存' 'bad' ("已提交 $commitPct%（可用 $memFreeGb GB / $memTotalGb GB）") '接近提交上限，可能出现分配失败或频繁换页' '关闭占用大的程序，或增加虚拟内存'
} elseif ($commitPct -ge 80) {
    Add-Check 'memory' '内存' 'warn' ("已提交 $commitPct%（可用 $memFreeGb GB / $memTotalGb GB）") '提交占用偏高'
} else {
    Add-Check 'memory' '内存' 'ok' ("已提交 $commitPct%（可用 $memFreeGb GB / $memTotalGb GB）") ''
}

# ---- 3. pagefile -------------------------------------------------------------
# A pagefile smaller than RAM breaks full memory dumps and can starve the commit
# limit; no pagefile at all is a common "optimisation" that causes odd crashes.
$pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
$pfTotalMb = 0
foreach ($p in $pf) { $pfTotalMb += [int64]$p.AllocatedBaseSize }
$pfAuto = $false
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $pfAuto = [bool]$cs.AutomaticManagedPagefile
} catch {}
if ($pfTotalMb -le 0) {
    Add-Check 'pagefile' '虚拟内存' 'bad' '没有启用页面文件' '没有页面文件时，内存吃紧会直接导致程序崩溃' '改为「系统管理的大小」'
} elseif ($memTotalGb -gt 0 -and $pfTotalMb -lt ($memTotalGb * 1024 * 0.25)) {
    Add-Check 'pagefile' '虚拟内存' 'warn' ("$([math]::Round($pfTotalMb/1024,1)) GB / 内存 $memTotalGb GB") '页面文件明显小于内存的 25%，可能限制提交上限' '改为「系统管理的大小」'
} else {
    Add-Check 'pagefile' '虚拟内存' 'ok' ("$([math]::Round($pfTotalMb/1024,1)) GB / 内存 $memTotalGb GB") $(if ($pfAuto) { '系统管理' } else { '自定义大小' })
}

# ---- 4. uptime ---------------------------------------------------------------
# Long uptime correlates with leaked handles and stuck updates; it is a prompt to
# reboot, not a fault by itself.
if ($os) {
    $boot = $os.LastBootUpTime
    $upDays = [math]::Round(((Get-Date) - $boot).TotalDays, 1)
    if ($upDays -ge 30) {
        Add-Check 'uptime' '开机时长' 'warn' "$upDays 天" "上次启动: $($boot.ToString('yyyy-MM-dd HH:mm'))" '建议重启一次，长期不重启容易累积句柄与内存碎片'
    } else {
        Add-Check 'uptime' '开机时长' 'ok' "$upDays 天" "上次启动: $($boot.ToString('yyyy-MM-dd HH:mm'))"
    }
}

# ---- 5. pending reboot -------------------------------------------------------
# Three independent flags; any one of them means "updates are waiting on a
# restart", which is the usual reason a machine behaves oddly after patching.
$rebootReasons = [System.Collections.Generic.List[string]]::new()
foreach ($k in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)) {
    if (Test-Path -LiteralPath $k) { $rebootReasons.Add((Split-Path $k -Leaf)) }
}
try {
    $pfro = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
    if ($pfro.PendingFileRenameOperations) { $rebootReasons.Add('PendingFileRenameOperations') }
} catch {}
if ($rebootReasons.Count -gt 0) {
    Add-Check 'reboot' '待重启' 'warn' ("$($rebootReasons.Count) 项") ($rebootReasons -join ', ') '重启后这些安装才会真正完成'
} else {
    Add-Check 'reboot' '待重启' 'ok' '无' ''
}

# ---- 6. services set to auto but stopped -------------------------------------
# These are the ones that are supposed to be running and are not. Excluding the
# deliberately-stopped-by-design set matters: listing them as broken would drown
# the real finding.
$byDesignStopped = @(
    'WSearch', 'SysMain', 'WerSvc', 'Spooler', 'MapsBroker', 'RemoteRegistry',
    'lfsvc', 'TabletInputService', 'CDPSvc', 'WalletService', 'XblAuthManager',
    'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc', 'DiagTrack', 'dmwappushservice',
    'RetailDemo', 'WMPNetworkSvc', 'PhoneSvc', 'SensorService', 'SensrSvc',
    'WbioSrvc', 'WlanSvc', 'icssvc', 'NvContainerLocalSystem', 'RmSvc',
    # sppsvc (Software Protection) is Automatic + trigger-start: it sits Stopped
    # by design and only wakes when activation is queried.
    'sppsvc'
)
$autoStopped = [System.Collections.Generic.List[object]]::new()
foreach ($s in @(Get-Service -ErrorAction SilentlyContinue)) {
    if ($s.StartType -ne 'Automatic') { continue }
    if ($s.Status -ne 'Stopped') { continue }
    if ($byDesignStopped -contains $s.Name) { continue }
    $autoStopped.Add([ordered]@{ name = $s.Name; displayName = $s.DisplayName })
}
if ($autoStopped.Count -gt 0) {
    Add-Check 'services' '自动启动服务' 'warn' ("$($autoStopped.Count) 个未运行") (($autoStopped | Select-Object -First 8 | ForEach-Object { $_.name }) -join ', ') '服务设置了自动启动但当前未运行，可能是启动失败或依赖缺失'
} else {
    Add-Check 'services' '自动启动服务' 'ok' '全部运行' ''
}

# ---- 7. crashed devices ------------------------------------------------------
# A device with ConfigManagerErrorCode != 0 is a real problem (driver missing,
# resource conflict); Windows will keep retrying it silently forever.
$badDevices = [System.Collections.Generic.List[object]]::new()
foreach ($d in @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue)) {
    $code = $d.ConfigManagerErrorCode
    if ($null -eq $code -or [int]$code -eq 0 -or [int]$code -eq 22) { continue }  # 22 = disabled by user
    $badDevices.Add([ordered]@{ name = $d.Name; errorCode = [int]$code; status = [string]$d.Status })
}
if ($badDevices.Count -gt 0) {
    Add-Check 'devices' '设备状态' 'warn' ("$($badDevices.Count) 个设备异常") (($badDevices | Select-Object -First 6 | ForEach-Object { "$($_.name) (代码 $($_.errorCode))" }) -join '; ') '在设备管理器里查看黄色感叹号设备'
} else {
    Add-Check 'devices' '设备状态' 'ok' '无异常' ''
}

# ---- 8. Defender -------------------------------------------------------------
$mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
if ($null -eq $mp) {
    Add-Check 'defender' '病毒防护' 'skip' '' 'Defender 状态不可读（可能被第三方安全软件接管）'
} else {
    $rtp = [bool]$mp.RealTimeProtectionEnabled
    $sigAge = $null
    try { $sigAge = [int]$mp.AntivirusSignatureAge } catch { $sigAge = $null }
    if (-not $rtp) {
        Add-Check 'defender' '病毒防护' 'bad' '实时保护已关闭' ("杀毒引擎 $($mp.AMEngineVersion)") '确认是否有意关闭；若是第三方安软接管可忽略'
    } elseif ($null -ne $sigAge -and $sigAge -gt 7) {
        Add-Check 'defender' '病毒防护' 'warn' ("实时保护开启，病毒库 $sigAge 天未更新") ("引擎 $($mp.AMEngineVersion)") '更新病毒库定义'
    } else {
        Add-Check 'defender' '病毒防护' 'ok' ("实时保护开启" + $(if ($null -ne $sigAge) { "，病毒库 $sigAge 天前的" } else { '' })) ("引擎 $($mp.AMEngineVersion)")
    }
}

# ---- 9. system restore -------------------------------------------------------
# Restore points are the only cheap undo for a driver or update change; a machine
# with protection "on" but zero points has no undo at all, which is the trap.
$srOn = $false
try { $srOn = [bool](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' -Name RPSessionInterval -ErrorAction Stop) } catch { $srOn = $false }
$rpCount = 0
try { $rpCount = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop).Count } catch { $rpCount = 0 }
if (-not $srOn) {
    Add-Check 'restore' '系统还原' 'warn' '已关闭或未配置' '改系统前没有回滚点' '建议至少开启系统盘保护'
} elseif ($rpCount -eq 0) {
    Add-Check 'restore' '系统还原' 'warn' '已开启但没有任何还原点' '保护是开的，但没有任何可用快照——等于没有退路' '手动创建一个还原点'
} else {
    Add-Check 'restore' '系统还原' 'ok' "$rpCount 个还原点" ''
}

# ---- 10. update recency ------------------------------------------------------
$lastInstall = $null
try {
    $lastInstall = @(Get-HotFix -ErrorAction Stop | Sort-Object -Property InstalledOn -Descending | Select-Object -First 1)[0].InstalledOn
} catch {}
if ($lastInstall) {
    $days = [math]::Round(((Get-Date) - $lastInstall).TotalDays, 0)
    if ($days -gt 90) {
        Add-Check 'updates' '系统更新' 'warn' "最近一次更新在 $days 天前" "安装日期: $($lastInstall.ToString('yyyy-MM-dd'))" '长期未更新，注意累积更新可能已经很大'
    } else {
        Add-Check 'updates' '系统更新' 'ok' "最近一次更新在 $days 天前" "安装日期: $($lastInstall.ToString('yyyy-MM-dd'))"
    }
} else {
    Add-Check 'updates' '系统更新' 'skip' '' '未能读取更新历史'
}

# ---- 11. event log errors (last 24h) -----------------------------------------
# Only Critical and Error, and only the System log — Application errors are
# mostly the user's own software crashing, which is a different conversation.
#
# This machine's log simply has no Level 1/2 events in the window, and
# Get-WinEvent signals exactly that by THROWING NoMatchingEventsFoundException
# ('找不到与指定的选择条件匹配的事件。'). Catching it broadly would report
# "could not read the log" and hide a clean bill of health, so the no-match case
# is separated from a genuine failure.
$errCount = 0
$topSources = [System.Collections.Generic.List[object]]::new()
try {
    $since = (Get-Date).AddHours(-24)
    $evts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -MaxEvents 500 -ErrorAction Stop)
    $errCount = $evts.Count
    $topSources = @($evts | Group-Object -Property ProviderName | Sort-Object -Property Count -Descending | Select-Object -First 5 | ForEach-Object { [ordered]@{ source = $_.Name; count = $_.Count } })
} catch {
    $isNoMatch = $false
    try { $isNoMatch = ($_.Exception.GetType().Name -eq 'NoMatchingEventsFoundException') } catch { $isNoMatch = $false }
    if (-not $isNoMatch) {
        # Fallback for PS5.1-style wrapping: the localised no-match text.
        $isNoMatch = ($_.Exception.Message -match '找不到与指定的选择条件匹配|No events were found|没有与指定')
    }
    if ($isNoMatch) { $errCount = 0 } else { $errCount = -1 }
}
if ($errCount -lt 0) {
    Add-Check 'events' '系统日志' 'skip' '' '未能读取系统事件日志'
} elseif ($errCount -ge 50) {
    Add-Check 'events' '系统日志' 'warn' "24 小时 $errCount 条错误" (($topSources | ForEach-Object { "$($_.source) x$($_.count)" }) -join ', ') '来源集中的错误往往指向同一个根因，值得展开看'
} else {
    Add-Check 'events' '系统日志' 'ok' "24 小时 $errCount 条错误" (($topSources | ForEach-Object { "$($_.source) x$($_.count)" }) -join ', ')
}

# ---- roll-up ------------------------------------------------------------------
$bad = @($checks | Where-Object { $_.status -eq 'bad' }).Count
$warn = @($checks | Where-Object { $_.status -eq 'warn' }).Count
$okc = @($checks | Where-Object { $_.status -eq 'ok' }).Count
$skip = @($checks | Where-Object { $_.status -eq 'skip' }).Count

$out = [ordered]@{
    ok = $true
    elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    summary = [ordered]@{ total = $checks.Count; ok = $okc; warn = $warn; bad = $bad; skip = $skip }
    checks = @($checks)
    disks = @($disks)
    host = [ordered]@{
        memoryTotalGb = $memTotalGb
        memoryFreeGb = $memFreeGb
        commitPct = $commitPct
        pagefileMb = $pfTotalMb
        pagefileAuto = $pfAuto
        uptimeDays = $(if ($os) { [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1) } else { $null })
    }
}
[Console]::Out.Write((ConvertTo-Json -InputObject $out -Depth 6 -Compress))
