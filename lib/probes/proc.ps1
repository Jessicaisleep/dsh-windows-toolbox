param([string]$ParamFile)

# ---------------------------------------------------------------------------
# proc.ps1 — 任务管理器：谁在吃我的电脑（进程资源排行）。
#
# 完全只读：只排行、只给建议，**绝不结束任何进程**。结束进程是用户在任务
# 管理器里的显式动作，不该是"打开一个面板"的副作用。
#
# CPU 百分比不能取 Get-Process 的 CPU 属性——那是进程启动以来的**累计 CPU
# 秒数**，一个跑了一天的空闲进程会压过刚起来的忙进程。这里取两次采样求差，
# 再除以（窗口秒数 × 逻辑核数）。Idle（PID 0）必须排除：它报的是"每个核
# 闲置的比例"，永远 90%+，混进排行就是垃圾数据；System（PID 4）同理排除。
#
# 磁盘 IO 排行和 CPU 总占用来自同一次 Get-Counter 调用，这次调用同时也充当
# 两次进程采样之间的等待窗口，让单次执行压在 5 秒内。
#
# 读不到的东西一律 skip 并写明原因，不填 0、不猜。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList
$started = Get-Date

# 排行条数可调（面板默认不带参数）。只接受 1..15 的整数，其余当作默认 5。
$topCpuN = 5
$topMemN = 5
$rawTop = $null
if ($params -is [System.Collections.IDictionary]) { $rawTop = $params['top'] }
elseif ($null -ne $params) { $rawTop = $params.top }
if ($null -ne $rawTop) {
    $parsed = 0
    if ([int]::TryParse([string]$rawTop, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 15) { $topCpuN = $parsed; $topMemN = $parsed }
}

# ---- 主机事实：CPU 型号 / 核数 / 内存总量 -------------------------------------
$cpuName = ''
$cores = [Environment]::ProcessorCount
$physCores = 0
$cpuInfo = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cpuInfo) {
    $cpuName = ([string]$cpuInfo.Name -replace '\s+', ' ').Trim()
    if ([int]$cpuInfo.NumberOfLogicalProcessors -gt 0) { $cores = [int]$cpuInfo.NumberOfLogicalProcessors }
    $physCores = [int]$cpuInfo.NumberOfCores
}
if ($cores -lt 1) { $cores = 1 }

$memTotalBytes = [int64]0
$memFreeBytes = [int64]0
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($osInfo) {
    $memTotalBytes = [int64]$osInfo.TotalVisibleMemorySize * 1024
    $memFreeBytes = [int64]$osInfo.FreePhysicalMemory * 1024
}
$memTotalGb = [math]::Round($memTotalBytes / 1GB, 1)
$memFreeGb = [math]::Round($memFreeBytes / 1GB, 1)

# ---- 第一次进程采样 -----------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$firstCpu = @{}
$procNames = @{}
foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    if ($null -eq $p) { continue }
    $procId = [int]$p.Id
    $firstCpu[$procId] = [double]$p.CPU
    $procNames[$procId] = [string]$p.ProcessName
}
$tFirst = $sw.Elapsed.TotalSeconds

# ---- 采样窗口：计数器（进程 IO + 处理器总占用） -------------------------------
# Get-Counter 取两次原始样本自己算差值，实测量约 1.0-1.5 s，正好当采样窗口。
#
# 坑：个别进程的样本 Status 非 0（刚启动/刚退出的计数器实例），Get-Counter 会抛
# **非终止**错误「其中一个性能计数器样本中的数据无效」。如果用 -ErrorAction Stop
# 就会把整批 429 个有效样本一起丢掉（处理器总占用也一起没了）。所以这里用
# SilentlyContinue，再按 $_.Status -eq 0 逐条筛。
$counterSamples = @()
$counterErr = ''
try {
    $cc = Get-Counter -Counter '\Process(*)\IO Data Bytes/sec', '\Process(*)\ID Process', '\Processor(_Total)\% Processor Time' `
        -ErrorAction SilentlyContinue
    if ($cc) { $counterSamples = @($cc.CounterSamples | Where-Object { $_.Status -eq 0 }) }
} catch { $counterErr = $_.Exception.Message }
if (-not $cc -and -not $counterErr) { $counterErr = 'Get-Counter 没有返回样本' }

# 计数器不可用时窗口可能只有几十毫秒，除出来的百分比会离谱地大；补一次等待。
$span = $sw.Elapsed.TotalSeconds - $tFirst
if ($span -lt 0.5) { Start-Sleep -Milliseconds 700 }

# ---- 第二次进程采样 -----------------------------------------------------------
$tSecond = $sw.Elapsed.TotalSeconds
$secondCpu = @{}
$workset = @{}
foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    if ($null -eq $p) { continue }
    $procId = [int]$p.Id
    $secondCpu[$procId] = [double]$p.CPU
    $workset[$procId] = [double]$p.WorkingSet64
}
$interval = $tSecond - $tFirst
if ($interval -le 0) { $interval = 0.001 }

# ---- CPU 排行：两次采样求差 ---------------------------------------------------
$cpuRows = [System.Collections.Generic.List[object]]::new()
foreach ($procId in @($firstCpu.Keys)) {
    if (-not $secondCpu.ContainsKey($procId)) { continue }        # 窗口内退出的进程
    if ($procId -eq 0 -or $procId -eq 4) { continue }             # Idle / System
    $delta = [double]$secondCpu[$procId] - [double]$firstCpu[$procId]
    if ($delta -lt 0) { continue }                                # PID 被复用，差值无意义
    $pct = ($delta / ($interval * $cores)) * 100.0
    if ($pct -lt 0.1) { continue }                                # 0.0% 的条目只是噪声
    $cpuRows.Add([pscustomobject]@{
        pid   = $procId
        name  = $procNames[$procId]
        pct   = [math]::Round($pct, 1)
        raw   = $pct
        # pct 是"占整机 CPU 容量的百分比"，换算成等效逻辑核数要乘上核数。
        cores = [math]::Round($pct * $cores / 100.0, 2)
    })
}
$cpuTop = @($cpuRows | Sort-Object -Property { [double]$_.raw } -Descending | Select-Object -First $topCpuN)

# ---- 内存排行：工作集 / 物理内存 ----------------------------------------------
$memRows = [System.Collections.Generic.List[object]]::new()
foreach ($procId in @($secondCpu.Keys)) {
    if ($procId -eq 0 -or $procId -eq 4) { continue }
    $ws = [double]$workset[$procId]
    if ($ws -le 0) { continue }
    $pct = 0.0
    if ($memTotalBytes -gt 0) { $pct = ($ws / [double]$memTotalBytes) * 100.0 }
    $memRows.Add([pscustomobject]@{
        pid  = $procId
        name = $procNames[$procId]
        mb   = [math]::Round($ws / 1MB, 1)
        pct  = [math]::Round($pct, 1)
        raw  = $pct
    })
}
$memTop = @($memRows | Sort-Object -Property { [double]$_.raw } -Descending | Select-Object -First $topMemN)

# ---- 磁盘 IO 排行：计数器路径 → PID -------------------------------------------
# 同名进程（chrome、svchost）在计数器里是 name#1、name#2……，所以必须按
# "路径前缀" 把 IO 样本和 ID Process 样本配对，只按 InstanceName 配会串号。
$ioRows = [System.Collections.Generic.List[object]]::new()
$cpuTotalPct = $null
if ($counterSamples.Count -gt 0) {
    $pidByInst = @{}
    $ioByInst = @{}
    foreach ($s in $counterSamples) {
        $path = [string]$s.Path
        $cut = $path.LastIndexOf('\')
        if ($cut -lt 1) { continue }
        $inst = $path.Substring(0, $cut)
        $counterName = $path.Substring($cut + 1).ToLowerInvariant()
        if ($counterName -eq 'id process') {
            $pidByInst[$inst] = [int]$s.CookedValue
        } elseif ($counterName -eq 'io data bytes/sec') {
            if ([string]$s.InstanceName -ne '_total') { $ioByInst[$inst] = [double]$s.CookedValue }
        } elseif ($counterName -eq '% processor time' -and $inst -match 'processor\(_total\)$') {
            $cpuTotalPct = [double]$s.CookedValue
        }
    }
    foreach ($inst in @($ioByInst.Keys)) {
        $bytes = [double]$ioByInst[$inst]
        if ($bytes -lt 1024) { continue }                         # 低于 1 KB/s 不值得占一行
        $procId = 0
        if ($pidByInst.ContainsKey($inst)) { $procId = [int]$pidByInst[$inst] }
        $nm = $procNames[$procId]
        if ([string]::IsNullOrEmpty($nm)) {
            $nm = ($inst -replace '^.*\\process\(', '') -replace '\)$', ''
        }
        $ioRows.Add([pscustomobject]@{
            pid   = $procId
            name  = $nm
            bytes = $bytes
            mbps  = [math]::Round($bytes / 1MB, 2)
        })
    }
}
$ioTop = @($ioRows | Sort-Object -Property { [double]$_.bytes } -Descending | Select-Object -First 3)

# ---- 总体占用 ----------------------------------------------------------------
$cpuTotalRound = $null
$cpuTotalSource = 'counter'
if ($null -ne $cpuTotalPct) {
    $cpuTotalRound = [math]::Round([double]$cpuTotalPct, 1)
} else {
    # 处理器计数器不可用时，用所有进程的差值和替代（不含 Idle/System，是下界）。
    $sum = 0.0
    foreach ($r in $cpuRows) { $sum += [double]$r.raw }
    $cpuTotalRound = [math]::Round($sum, 1)
    $cpuTotalSource = 'sum'
}

$memUsedPct = $null
if ($memTotalBytes -gt 0) {
    $memUsedPct = [math]::Round((($memTotalBytes - $memFreeBytes) / [double]$memTotalBytes) * 100.0, 1)
}

function Format-ProcName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return '(未知)' }
    if ($Name.Length -gt 18) { return $Name.Substring(0, 18) + '…' }
    return $Name
}

function Format-CpuName {
    # CPU 型号名长（例如 "12th Gen Intel(R) Core(TM) i5-12490F"），但它是身份信息，
    # 截断就看不出是什么型号了；这里只压空白，保留全名。
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return '(未知)' }
    return ($Name -replace '\s+', ' ').Trim()
}

# ---- 总览行 ------------------------------------------------------------------
if ($cpuName) {
    $threadText = if ($physCores -gt 0) { "$physCores 核 / $cores 线程" } else { "$cores 线程" }
    Add-Item -List $items -Id 'proc:cpu-model' -Group '总览' -Label '处理器' -Status 'info' `
        -Value (Format-CpuName $cpuName) -Detail $threadText -Fix ''
} else {
    Add-Item -List $items -Id 'proc:cpu-model' -Group '总览' -Label '处理器' -Status 'skip' `
        -Value '' -Detail 'Win32_Processor 未返回型号（WMI 不可用）' -Fix ''
}

if ($memTotalBytes -gt 0) {
    Add-Item -List $items -Id 'proc:memory-total' -Group '总览' -Label '物理内存' -Status 'info' `
        -Value "$memTotalGb GB" -Detail "当前可用 $memFreeGb GB" -Fix ''
} else {
    Add-Item -List $items -Id 'proc:memory-total' -Group '总览' -Label '物理内存' -Status 'skip' `
        -Value '' -Detail 'Win32_OperatingSystem 未返回内存信息' -Fix ''
}

if ($null -ne $cpuTotalRound) {
    $cpuStatus = 'ok'
    if ($cpuTotalRound -ge 80) { $cpuStatus = 'warn' }
    $cpuDetail = '本次采样窗口内的实时占用'
    if ($cpuTotalSource -eq 'sum') { $cpuDetail = '处理器计数器不可用，此值由各进程占用求和得出（不含 Idle/System，是下界）' }
    Add-Item -List $items -Id 'proc:cpu-total' -Group '总览' -Label 'CPU 总占用' -Status $cpuStatus `
        -Value "$cpuTotalRound%" -Detail $cpuDetail -Fix ''
} else {
    Add-Item -List $items -Id 'proc:cpu-total' -Group '总览' -Label 'CPU 总占用' -Status 'skip' `
        -Value '' -Detail '未能读取 CPU 占用' -Fix ''
}

if ($null -ne $memUsedPct) {
    $memStatus = 'ok'
    if ($memUsedPct -ge 80) { $memStatus = 'warn' }
    Add-Item -List $items -Id 'proc:mem-used' -Group '总览' -Label '内存占用' -Status $memStatus `
        -Value "$memUsedPct%" -Detail "$([math]::Round($memTotalGb - $memFreeGb, 1)) GB / $memTotalGb GB 已用" -Fix ''
} else {
    Add-Item -List $items -Id 'proc:mem-used' -Group '总览' -Label '内存占用' -Status 'skip' `
        -Value '' -Detail '未能读取物理内存总量' -Fix ''
}

Add-Item -List $items -Id 'proc:count' -Group '总览' -Label '进程数' -Status 'info' `
    -Value "$($secondCpu.Count) 个" -Detail "采样窗口 $([math]::Round($interval, 2)) 秒" -Fix ''

# ---- CPU 排行行 --------------------------------------------------------------
if ($cpuTop.Count -eq 0) {
    Add-Item -List $items -Id 'proc:cpu:none' -Group 'CPU 占用' -Label '无活跃进程' -Status 'skip' `
        -Value '' -Detail '采样窗口内没有任何进程的 CPU 时间增长（机器基本空闲）' -Fix ''
} else {
    $rank = 0
    foreach ($r in $cpuTop) {
        $rank++
        # 单个进程吃掉半台机器的 CPU，值得单独标黄；排行靠前本身不该被当成异常。
        $st = if ($r.pct -ge 50) { 'warn' } else { 'info' }
        $detail = "采样窗口内约 $($r.cores) 个逻辑核的占用"
        if ($st -eq 'warn') { $detail += '；单个进程占用超过整机一半' }
        Add-Item -List $items -Id "proc:cpu:$($r.pid)" -Group 'CPU 占用' -Label (Format-ProcName $r.name) -Status $st `
            -Value "$($r.pct)% · PID $($r.pid)" -Detail $detail `
            -Fix $(if ($st -eq 'warn') { '确认它是不是你正在跑的任务；本工具只读，不会替你结束进程' } else { '' })
    }
}

# ---- 内存排行行 --------------------------------------------------------------
if ($memTop.Count -eq 0) {
    Add-Item -List $items -Id 'proc:mem:none' -Group '内存占用' -Label '无数据' -Status 'skip' `
        -Value '' -Detail '未能读取任何进程的工作集' -Fix ''
} else {
    foreach ($r in $memTop) {
        # 单个进程工作集超过物理内存 30% 单独提示；正常大程序（浏览器/IDE）不该被标黄。
        $st = if ($r.pct -ge 30) { 'warn' } else { 'info' }
        Add-Item -List $items -Id "proc:mem:$($r.pid)" -Group '内存占用' -Label (Format-ProcName $r.name) -Status $st `
            -Value "$($r.mb) MB · $($r.pct)%" -Detail "工作集占物理内存 $memTotalGb GB 的 $($r.pct)% · PID $($r.pid)" `
            -Fix $(if ($st -eq 'warn') { '确认它是否需要长期常驻；本工具只读，不会替你结束进程' } else { '' })
    }
}

# ---- 磁盘 IO 排行行 ----------------------------------------------------------
if ($ioTop.Count -eq 0) {
    $why = '采样窗口内没有任何进程的磁盘读写超过 1 KB/s'
    if ($counterSamples.Count -eq 0) {
        $why = '进程 IO 性能计数器不可用（读不到进程级磁盘读写）'
        if ($counterErr) { $why = "进程 IO 性能计数器不可用：$counterErr" }
    }
    Add-Item -List $items -Id 'proc:io:none' -Group '磁盘 IO' -Label '磁盘读写' -Status 'skip' `
        -Value '' -Detail $why -Fix ''
} else {
    foreach ($r in $ioTop) {
        $val = if ($r.bytes -ge 1MB) { "$($r.mbps) MB/s · PID $($r.pid)" } else { "$([math]::Round($r.bytes / 1KB, 0)) KB/s · PID $($r.pid)" }
        # 持续 100 MB/s 以上的进程 IO 会让整机明显变卡，值得单独标一下。
        $st = if ($r.bytes -ge 100MB) { 'warn' } else { 'info' }
        Add-Item -List $items -Id "proc:io:$($r.pid)" -Group '磁盘 IO' -Label (Format-ProcName $r.name) -Status $st `
            -Value $val -Detail '读+写合计；持续高 IO 会让整机响应变慢' -Fix ''
    }
}

# ---- 结论行 ------------------------------------------------------------------
$topCpuName = ''
if ($cpuTop.Count -gt 0) { $topCpuName = $cpuTop[0].name }
$topMemName = ''
if ($memTop.Count -gt 0) { $topMemName = $memTop[0].name }

if ($null -eq $cpuTotalRound -and $null -eq $memUsedPct) {
    Add-Item -List $items -Id 'proc:conclusion' -Group '结论' -Label '当前状态' -Status 'skip' `
        -Value '' -Detail 'CPU 与内存占用都没能读到，无法给出结论' -Fix ''
} else {
    $cpuHigh = ($null -ne $cpuTotalRound -and $cpuTotalRound -ge 80)
    $memHigh = ($null -ne $memUsedPct -and $memUsedPct -ge 80)
    $advice = '不需要处理。如果机器仍然卡，按 CPU 或内存排序看是哪一项在涨。'
    if ($cpuHigh -or $memHigh) {
        $advice = '在任务管理器（Ctrl+Shift+Esc）里按占用排序，确认没用再结束它；本工具只读，不会替你结束任何进程。'
    }
    if ($cpuHigh -and $memHigh) {
        $valueText = "CPU $cpuTotalRound%，内存 $memUsedPct% 都偏高"
        $detailText = "CPU 主要是 $(Format-ProcName $topCpuName) 在占，内存主要是 $(Format-ProcName $topMemName) 在占。"
        Add-Item -List $items -Id 'proc:conclusion' -Group '结论' -Label '当前状态' -Status 'warn' `
            -Value $valueText -Detail $detailText -Fix $advice
    } elseif ($cpuHigh) {
        $detailText = "占用最高的是 $(Format-ProcName $topCpuName)（$($cpuTop[0].pct)%）。如果这不是你正在跑的任务，可以结束它。"
        Add-Item -List $items -Id 'proc:conclusion' -Group '结论' -Label '当前状态' -Status 'warn' `
            -Value "CPU $cpuTotalRound% 偏高" -Detail $detailText -Fix $advice
    } elseif ($memHigh) {
        $detailText = "占用最高的是 $(Format-ProcName $topMemName)（$($memTop[0].mb) MB）。关掉不用的程序能立刻缓解。"
        Add-Item -List $items -Id 'proc:conclusion' -Group '结论' -Label '当前状态' -Status 'warn' `
            -Value "内存 $memUsedPct% 偏高" -Detail $detailText -Fix $advice
    } else {
        $bits = @()
        if ($null -ne $cpuTotalRound) { $bits += "CPU $cpuTotalRound%" }
        if ($null -ne $memUsedPct) { $bits += "内存 $memUsedPct%" }
        $detailText = '当前没有异常占用（' + ($bits -join '，') + '）'
        if ($topCpuName) { $detailText += "，占用最高的是 $(Format-ProcName $topCpuName) $($cpuTop[0].pct)%" }
        $detailText += '。'
        Add-Item -List $items -Id 'proc:conclusion' -Group '结论' -Label '当前状态' -Status 'ok' `
            -Value '没有异常占用' -Detail $detailText -Fix $advice
    }
}

$elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds

$extra = @{
    elapsedMs      = $elapsedMs
    sampledSeconds = [math]::Round($interval, 2)
    logicalCores   = $cores
    cpuTotalPct    = $cpuTotalRound
    cpuTotalSource = $cpuTotalSource
    memoryPct      = $memUsedPct
    memoryTotalGb  = $memTotalGb
    processCount   = $secondCpu.Count
    cpuTop         = @($cpuTop | ForEach-Object { [ordered]@{ name = $_.name; pid = $_.pid; pct = $_.pct } })
    memoryTop      = @($memTop | ForEach-Object { [ordered]@{ name = $_.name; pid = $_.pid; mb = $_.mb; pct = $_.pct } })
    diskIoTop      = @($ioTop | ForEach-Object { [ordered]@{ name = $_.name; pid = $_.pid; bytesPerSec = [int64]$_.bytes } })
}

Write-ProbeResult -Items $items -Extra $extra -Note 'CPU 百分比为约 1 秒采样的实时占用；Idle 与 System 不计入排行。'
