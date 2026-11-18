param([string]$ParamFile)

# ---------------------------------------------------------------------------
# diskhealth.ps1 — 硬盘健康（对标 360「360硬盘健康」：监测硬盘健康，提前预警）。
#
# 完全只读：只读 SMART 派生值，不做任何分区/格式化/固件操作。
#
# 数据源按"谁能给出真话"排序，每个字段独立判定：
#   ① Get-PhysicalDisk → Get-StorageReliabilityCounter
#      （Temperature / Wear / PowerOnHours / ReadErrorsTotal / WriteErrorsTotal）
#      —— 这条通道**需要管理员**。非管理员调用抛 CimException，NativeErrorCode
#      = AccessDenied（本机实测）。拿不到就 skip 并写明"需管理员"，绝不填 0。
#   ② root\wmi: MSStorageDriver_FailurePredictStatus / ATAPISmartData
#      —— 这些是 **ATA/SATA** 的 SMART 通道。本机两块盘都是 NVMe，类存在但
#      实例数为 0，这是硬件/驱动不提供，不是权限问题。
#   ③ Win32_DiskDrive + Get-Disk + Get-PhysicalDisk 的 Status/HealthStatus
#      —— 任何权限都能读，但它只是"控制器认为健康"，不等于 SMART。
#
# 关键区别必须写进 detail：**权限拿不到** 和 **盘不支持** 是两件不同的事，
# 用户看到的建议也不同（前者"以管理员身份重跑就能看到"，后者"这块盘本来就
# 不提供这项"）。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList
$started = Get-Date
$elevated = Test-Elevated

function Format-DiskName {
    param([string]$Name, [int]$Max = 26)
    if ([string]::IsNullOrEmpty($Name)) { return '(未知型号)' }
    $n = ($Name -replace '\s+', ' ').Trim()
    if ($n.Length -gt $Max) { return $n.Substring(0, $Max) + '…' }
    return $n
}

# ---- 物理盘清单 --------------------------------------------------------------
# Get-PhysicalDisk 给出 MediaType / BusType / HealthStatus；Get-Disk 补充分区
# 风格并确认 Online。两个都失败时退回 Win32_DiskDrive（仍有型号与 Status）。
$physical = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
$logicalDrives = @()
foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue)) {
    $logicalDrives += [pscustomobject]@{
        number     = [int]$d.Number
        name       = [string]$d.FriendlyName
        health     = [string]$d.HealthStatus
        opStatus   = [string]$d.OperationalStatus
        bus        = [string]$d.BusType
        style      = [string]$d.PartitionStyle
        sizeBytes  = [int64]$d.Size
    }
}

# 盘符归属：一块盘上可能挂多个分区（本机 C:/D: 同属 disk 0，E: 属 disk 1）。
$lettersByDisk = @{}
$usedByDisk = @{}
$totalByDisk = @{}
foreach ($p in @(Get-Partition -ErrorAction SilentlyContinue)) {
    if (-not $p.DriveLetter) { continue }
    $dn = [int]$p.DiskNumber
    if (-not $lettersByDisk.ContainsKey($dn)) { $lettersByDisk[$dn] = [System.Collections.Generic.List[string]]::new() }
    $lettersByDisk[$dn].Add("$($p.DriveLetter):")
}
foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue)) {
    if (-not $v.DriveLetter) { continue }
    $size = [int64]$v.Size
    $free = [int64]$v.SizeRemaining
    if ($size -le 0) { continue }
    # Get-Volume 不带 DiskNumber，用 分区的盘号 反查（上面已建表）。
    $dn = -1
    foreach ($k in $lettersByDisk.Keys) {
        if ($lettersByDisk[$k] -contains "$($v.DriveLetter):") { $dn = [int]$k; break }
    }
    if ($dn -lt 0) { continue }
    if (-not $totalByDisk.ContainsKey($dn)) { $totalByDisk[$dn] = [int64]0; $usedByDisk[$dn] = [int64]0 }
    $totalByDisk[$dn] += $size
    $usedByDisk[$dn] += ($size - $free)
}

# ---- 逐盘读取 ---------------------------------------------------------------
$disks = [System.Collections.Generic.List[object]]::new()
$counterAccessDenied = $false
$counterUnsupported = $false
$counterErrText = ''

foreach ($pd in $physical) {
    $devId = [int]$pd.DeviceId
    $rec = [ordered]@{
        deviceId    = $devId
        model       = [string]$pd.FriendlyName
        mediaType   = [string]$pd.MediaType
        busType     = [string]$pd.BusType
        sizeBytes   = [int64]$pd.Size
        health      = [string]$pd.HealthStatus
        opStatus    = [string]$pd.OperationalStatus
        serial      = ([string]$pd.SerialNumber).Trim()
        letters     = @()
        style       = ''
        smartOk     = $false
        temperature = $null
        wear        = $null
        powerOnHrs  = $null
        readErrors  = $null
        writeErrors = $null
        smartErr    = ''
        smartErrKind= ''
    }
    $lk = [int]$devId
    if ($lettersByDisk.ContainsKey($lk)) { $rec.letters = @($lettersByDisk[$lk].ToArray()) }
    foreach ($ld in $logicalDrives) { if ($ld.number -eq $devId) { $rec.style = $ld.style } }

    # ① 可靠性计数器（需管理员）
    $ctr = $null
    $ctrErr = ''
    $ctrKind = ''
    try {
        $ctr = Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction Stop
    } catch {
        $ctrErr = [string]$_.Exception.Message
        $native = ''
        try { $native = [string]$_.Exception.NativeErrorCode } catch { $native = '' }
        if ($native -match 'AccessDenied') { $ctrKind = 'access' }
        elseif ($native -match 'NotSupported|Invalid') { $ctrKind = 'unsupported' }
        elseif ($ctrErr -match '访问|Access|拒绝|权限') { $ctrKind = 'access' }
        else { $ctrKind = 'other' }
    }
    if ($null -ne $ctr) {
        $rec.smartOk = $true
        try { if ($null -ne $ctr.Temperature -and [int]$ctr.Temperature -ge 0) { $rec.temperature = [int]$ctr.Temperature } } catch {}
        try { if ($null -ne $ctr.Wear -and [int]$ctr.Wear -ge 0) { $rec.wear = [int]$ctr.Wear } } catch {}
        try { if ($null -ne $ctr.PowerOnHours -and [int64]$ctr.PowerOnHours -ge 0) { $rec.powerOnHrs = [int64]$ctr.PowerOnHours } } catch {}
        try { if ($null -ne $ctr.ReadErrorsTotal) { $rec.readErrors = [int64]$ctr.ReadErrorsTotal } } catch {}
        try { if ($null -ne $ctr.WriteErrorsTotal) { $rec.writeErrors = [int64]$ctr.WriteErrorsTotal } } catch {}
    } else {
        $rec.smartErr = $ctrErr
        $rec.smartErrKind = $ctrKind
        if ($ctrKind -eq 'access') { $counterAccessDenied = $true }
        elseif ($ctrKind -eq 'unsupported') { $counterUnsupported = $true }
        if (-not $counterErrText) { $counterErrText = $ctrErr }
    }
    $disks.Add([pscustomobject]$rec)
}

# 一块盘都读不到时退回 Win32_DiskDrive（非管理员也能拿到型号/容量/Status）。
# 回退模式下 Get-Disk 也大概率不可用，但 Get-Partition / Get-Volume 可能还活着，
# 所以盘符和分区类型照样从上面建好的表里按盘号补，别让回退把已知信息一起丢掉。
$fallbackUsed = $false
if ($disks.Count -eq 0) {
    $fallbackUsed = $true
    foreach ($d in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue)) {
        $idx = [int]$d.Index
        $ld = $null
        foreach ($x in $logicalDrives) { if ($x.number -eq $idx) { $ld = $x; break } }
        $fbLetters = @()
        if ($lettersByDisk.ContainsKey($idx)) { $fbLetters = @($lettersByDisk[$idx].ToArray()) }
        $disks.Add([pscustomobject][ordered]@{
            deviceId     = $idx
            model        = [string]$d.Model
            mediaType    = if ([string]$d.MediaType -match 'SSD') { 'SSD' } else { [string]$d.MediaType }
            busType      = $(if ($ld -and $ld.bus) { $ld.bus } else { [string]$d.InterfaceType })
            sizeBytes    = [int64]$d.Size
            health       = [string]$d.Status
            opStatus     = [string]$d.Status
            serial       = ([string]$d.SerialNumber).Trim()
            letters      = $fbLetters
            style        = $(if ($ld) { $ld.style } else { '' })
            smartOk      = $false
            temperature  = $null
            wear         = $null
            powerOnHrs   = $null
            readErrors   = $null
            writeErrors  = $null
            smartErr     = 'Win32_DiskDrive 不提供 SMART 字段'
            smartErrKind = 'fallback'
        })
    }
}

# ---- 磁盘行 ------------------------------------------------------------------
if ($disks.Count -eq 0) {
    Add-Item -List $items -Id 'disk:list' -Group '磁盘' -Label '物理盘' -Status 'skip' `
        -Value '' -Detail 'Get-PhysicalDisk / Get-Disk / Win32_DiskDrive 都没有返回硬盘（存储服务可能已停止）' -Fix ''
}

$anyProblem = $false
foreach ($d in $disks) {
    $letters = ($d.letters -join ' ')
    if (-not $letters) { $letters = '无盘符' }
    # 容量按厂商十进制口径显示（Windows 里 1 TB 盘 = 931 GiB，写成 932 GB 会让人
    # 以为盘少了 68 GB）。>= 1 TB 用 TB，否则用 GiB——后者和资源管理器的数字一致。
    if ($d.sizeBytes -ge 1e12) {
        $sizeText = "$([math]::Round($d.sizeBytes / 1e12, 2)) TB"
    } else {
        $sizeText = "$([math]::Round($d.sizeBytes / 1GB, 1)) GB"
    }

    $status = 'ok'
    $healthText = $d.health
    if ($healthText -match 'Warning|Caution') { $status = 'warn'; $anyProblem = $true }
    elseif ($healthText -match 'Unhealthy|Critical|Bad|Failed') { $status = 'bad'; $anyProblem = $true }
    elseif ($healthText -match 'Unknown') { $status = 'info' }
    if ($d.opStatus -and $d.opStatus -notmatch '^OK$' -and $d.opStatus -notmatch 'Online') { $status = 'warn'; $anyProblem = $true }

    $detailBits = @("$sizeText", "$($d.busType)")
    if ($d.mediaType) { $detailBits += $d.mediaType }
    if ($d.style) { $detailBits += $d.style }
    $detailBits += "盘符 $letters"
    if ($d.opStatus -and $d.opStatus -notmatch '^(OK|Online)$') { $detailBits += "运行状态 $($d.opStatus)" }
    if ($d.serial) { $detailBits += "序列号 $($d.serial)" }

    Add-Item -List $items -Id "disk:$($d.deviceId):info" -Group '磁盘' -Label (Format-DiskName $d.model) -Status $status `
        -Value "$healthText" -Detail ($detailBits -join ' · ') -Fix ''
}

# ---- SMART 派生值 -------------------------------------------------------------
$smartGot = 0
$smartMissing = 0
foreach ($d in $disks) {
    if ($d.smartOk) {
        $fields = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $d.powerOnHrs) { $fields.Add("通电 $($d.powerOnHrs) 小时") }
        if ($null -ne $d.temperature) { $fields.Add("温度 $($d.temperature)°C") }
        if ($null -ne $d.wear) { $fields.Add("磨损 $($d.wear)%") }
        if ($fields.Count -eq 0) {
            # 计数器对象拿到了但没有可用字段——照样不能编。
            Add-Item -List $items -Id "disk:$($d.deviceId):smart" -Group 'SMART' -Label (Format-DiskName $d.model 20) -Status 'skip' `
                -Value '' -Detail '可靠性计数器返回了对象，但 Temperature / Wear / PowerOnHours 全为空（该盘固件未上报）' -Fix ''
            $smartMissing++
            continue
        }
        $smartGot++
        # 每一项警告独立累加，不能后一项把前一项的说明覆盖掉（磨损 86% 且温度 73°C
        # 的盘，两个理由都要说）。
        $problems = [System.Collections.Generic.List[string]]::new()
        $fixList = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $d.wear -and $d.wear -ge 80) {
            $problems.Add("磨损已到 $($d.wear)%（剩余寿命约 $(100 - $d.wear)%）")
            $fixList.Add('先备份重要数据，再考虑更换这块盘')
        } elseif ($null -ne $d.wear -and $d.wear -ge 60) {
            $problems.Add("磨损 $($d.wear)%，剩余寿命约 $(100 - $d.wear)%")
        }
        if ($null -ne $d.temperature -and $d.temperature -ge 70) {
            $problems.Add("温度 $($d.temperature)°C 偏高，长期高温会加速磨损")
            $fixList.Add('改善机箱风道，避免长时间满载')
        }
        if (($null -ne $d.readErrors -and $d.readErrors -gt 0) -or ($null -ne $d.writeErrors -and $d.writeErrors -gt 0)) {
            $problems.Add("读写错误累计 读 $($d.readErrors) / 写 $($d.writeErrors) 次")
            $fixList.Add('留意读写错误是否持续增长；持续增长说明介质在退化')
        }

        $status = if ($problems.Count -eq 0) { 'ok' } else { 'warn' }
        if ($problems.Count -gt 0) { $anyProblem = $true }
        $detail = '由 Get-StorageReliabilityCounter 读取'
        if ($problems.Count -gt 0) { $detail = ($problems -join '；') }
        if ($null -ne $d.wear) { $fields.Add("剩余寿命约 $(100 - $d.wear)%") }
        Add-Item -List $items -Id "disk:$($d.deviceId):smart" -Group 'SMART' -Label (Format-DiskName $d.model 20) -Status $status `
            -Value ($fields -join '，') -Detail $detail -Fix ($fixList -join '；')
    } else {
        $smartMissing++
    }
}

# 整条计数器通道不可用时，只出一条汇总 skip（重复 N 条同样的"拿不到"没有信息量），
# 但原因必须写清楚是权限还是硬件。
if ($smartGot -eq 0 -and $smartMissing -gt 0) {
    if ($counterAccessDenied) {
        $why = 'Get-StorageReliabilityCounter 被系统拒绝（AccessDenied：需要管理员）'
        $fix = '以管理员身份运行本工具即可读取温度 / 磨损 / 通电小时'
    } elseif ($counterUnsupported) {
        $why = '该盘的驱动不支持可靠性计数器（非权限问题）'
        $fix = ''
    } elseif ($fallbackUsed) {
        $why = 'Get-PhysicalDisk 没有返回硬盘，已退回 Win32_DiskDrive；这条老通道本身不提供 SMART 字段（非权限问题，是通道能力限制）'
        $fix = '确认 Windows 存储服务（StorSvc / Virtual Disk）在运行后重跑；SMART 详细读数需要 Get-PhysicalDisk 这条通道'
    } else {
        $why = '可靠性计数器不可用'
        if ($counterErrText) { $why += "：$counterErrText" }
        $fix = '以管理员身份重跑；若仍为空则说明该盘固件不上报'
    }
    Add-Item -List $items -Id 'disk:smart-summary' -Group 'SMART' -Label 'SMART 详细读数' -Status 'skip' `
        -Value '' -Detail "$why。通电小时 / 温度 / 磨损 / 重映射扇区 / 剩余寿命都无法读取（未填任何猜测值）。" `
        -Fix $fix -NeedsAdmin $counterAccessDenied
}

# ---- 故障预测（ATA SMART 通道） -----------------------------------------------
$predictCount = 0
$predictFail = [System.Collections.Generic.List[string]]::new()
$predictErr = ''
try {
    $fps = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSStorageDriver_FailurePredictStatus' -ErrorAction Stop)
    $predictCount = $fps.Count
    foreach ($f in $fps) {
        if ($f.PredictFailure -eq $true) { $predictFail.Add([string]$f.InstanceName) }
    }
} catch {
    $predictErr = [string]$_.Exception.Message
}

if ($predictCount -gt 0) {
    if ($predictFail.Count -gt 0) {
        Add-Item -List $items -Id 'disk:predict' -Group 'SMART' -Label '故障预测' -Status 'bad' `
            -Value "SMART 预测将故障（$($predictFail.Count) 块）" `
            -Detail (($predictFail -join '; ') + ' —— 固件自己的预测，不是估算') `
            -Fix '立刻备份数据并准备换盘；不要继续存放唯一副本'
        $anyProblem = $true
    } else {
        Add-Item -List $items -Id 'disk:predict' -Group 'SMART' -Label '故障预测' -Status 'ok' `
            -Value "SMART 未预测故障（$predictCount 块）" -Detail 'ATA SMART 通道返回 PredictFailure=False' -Fix ''
    }
} else {
    $why = '本机没有任何 ATA SMART 实例'
    $nvmeOnly = ($disks.Count -gt 0 -and @($disks | Where-Object { $_.busType -notmatch 'NVMe' }).Count -eq 0)
    if ($nvmeOnly) {
        $why = '本机硬盘全部是 NVMe，Windows 的 MSStorageDriver_FailurePredictStatus 只枚举 ATA/SATA 盘，实例数为 0 —— 这是硬件通道不支持，不是权限问题'
    } elseif ($predictErr) {
        $why = "读取 root\wmi 失败：$predictErr"
    }
    Add-Item -List $items -Id 'disk:predict' -Group 'SMART' -Label '故障预测' -Status 'skip' `
        -Value '' -Detail "$why。没有预测结果不代表盘一定健康，只能说这条通道给不出结论。" -Fix ''
}

# ---- 容量行（每块盘汇总其分区占用） -------------------------------------------
foreach ($d in $disks) {
    $dn = [int]$d.deviceId
    if (-not $totalByDisk.ContainsKey($dn)) { continue }
    $total = [int64]$totalByDisk[$dn]
    $used = [int64]$usedByDisk[$dn]
    if ($total -le 0) { continue }
    $usedPct = [math]::Round(100.0 * $used / $total, 1)
    $freeGb = [math]::Round(($total - $used) / 1GB, 1)
    $status = 'ok'
    if ($usedPct -ge 95) { $status = 'bad' } elseif ($usedPct -ge 90) { $status = 'warn' }
    $letters = ($d.letters -join ' ')
    Add-Item -List $items -Id "disk:$($dn):usage" -Group '容量' -Label (Format-DiskName $d.model 20) -Status $status `
        -Value "已用 $usedPct%（剩 $freeGb GB）" -Detail "分区 $letters 合计" `
        -Fix $(if ($status -eq 'ok') { '' } else { '清理垃圾或把大文件挪到别的盘，SSD 留 10% 以上空闲能维持写入性能' })
}

# ---- 结论行 ------------------------------------------------------------------
$ssdCount = @($disks | Where-Object { $_.mediaType -match 'SSD' -or $_.busType -match 'NVMe' }).Count
$healthyCount = @($disks | Where-Object { $_.health -match 'Healthy|OK' }).Count
$totalText = "$($disks.Count) 块盘"
if ($ssdCount -gt 0) { $totalText += "（$ssdCount 块 SSD）" }

if ($disks.Count -eq 0) {
    Add-Item -List $items -Id 'disk:conclusion' -Group '结论' -Label '硬盘健康' -Status 'skip' `
        -Value '' -Detail '没有读到任何物理盘，无法给出结论' -Fix ''
} elseif ($anyProblem) {
    # 点出是哪一块，否则用户看到 "2 / 2 块报告健康" 配一条警告会以为工具自相矛盾：
    # "控制器报告健康" 和 "SMART 已磨损" 是两回事，要把这层区别说出来。
    $badNames = @($disks | Where-Object {
        $_.health -match 'Warning|Caution|Unhealthy|Critical|Bad|Failed' -or
        ($null -ne $_.wear -and $_.wear -ge 80) -or
        ($null -ne $_.temperature -and $_.temperature -ge 70)
    } | ForEach-Object { Format-DiskName $_.model 18 })
    $who = if ($badNames.Count -gt 0) { ($badNames -join '、') } else { '至少一块盘' }
    $detail = "$who 有异常信号，详见上面标黄的 SMART 行。"
    if ($healthyCount -eq $disks.Count) {
        $detail += '注意：控制器的 HealthStatus 只代表"控制器没判它坏"，SMART 的磨损/温度预警往往更早。'
    }
    Add-Item -List $items -Id 'disk:conclusion' -Group '结论' -Label '硬盘健康' -Status 'warn' `
        -Value "$healthyCount / $($disks.Count) 块控制器报告健康，但已出现预警" `
        -Detail $detail `
        -Fix '先备份重要数据；SMART 预警的盘不要再放唯一副本'
} else {
    $concl = "${totalText}也都报告健康"
    if ($smartGot -gt 0) {
        $powerBits = @()
        foreach ($d in $disks) { if ($null -ne $d.powerOnHrs) { $powerBits += "$(Format-DiskName $d.model 14) 通电 $($d.powerOnHrs) 小时" } }
        if ($powerBits.Count -gt 0) { $concl += '；' + ($powerBits -join '，') }
    } else {
        $concl += '；但 SMART 详细读数（通电小时 / 温度 / 磨损）没拿到'
        if ($counterAccessDenied) { $concl += '，因为需要管理员权限' }
    }
    Add-Item -List $items -Id 'disk:conclusion' -Group '结论' -Label '硬盘健康' -Status 'ok' `
        -Value '控制器报告健康' -Detail "$concl。" `
        -Fix $(if ($counterAccessDenied) { '想看温度 / 磨损 / 通电小时，用管理员身份重跑一次即可' } else { '' })
}

$elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds

$extra = @{
    elapsedMs       = $elapsedMs
    diskCount       = $disks.Count
    smartReadable   = ($smartGot -gt 0)
    smartAccessDenied = $counterAccessDenied
    smartFields     = @($disks | ForEach-Object {
        [ordered]@{
            deviceId    = $_.deviceId
            model       = $_.model
            busType     = $_.busType
            mediaType   = $_.mediaType
            capacityGb  = [math]::Round($_.sizeBytes / 1GB, 0)
            health      = $_.health
            poweredOnHrs= $_.powerOnHrs
            temperature = $_.temperature
            wear        = $_.wear
            readErrors  = $_.readErrors
            writeErrors = $_.writeErrors
            smartSource = $(if ($_.smartOk) { 'StorageReliabilityCounter' } else { 'unavailable' })
        }
    })
    predictFailureInstances = $predictCount
    usedWin32Fallback = $fallbackUsed
}

Write-ProbeResult -Items $items -Extra $extra -Note 'SMART 详细读数需要管理员权限；NVMe 盘不走 ATA SMART 通道。未读到的字段一律标 skip，没有填猜测值。'
