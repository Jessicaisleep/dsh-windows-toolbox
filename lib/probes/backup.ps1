param([string]$ParamFile)

# ---------------------------------------------------------------------------
# backup.ps1 — 备份能力巡检 + 注册表导出（唯一写路径）
#
# 只回答两件事：这台机器现在有哪些备份手段、能不能在建点之前先把注册表存下来。
# 唯一的写操作是把指定的注册表键 `reg export` 成 .reg 文件，写进
# %LOCALAPPDATA%\dsh-windows-toolbox\regbackup\；**不动注册表本身**，也不创建还原点。
#
# 三个必须写清楚的边界：
#
#  1. 绝不调用 Checkpoint-Computer。它在 PowerShell 7 下不存在（那是 PS5.1 的
#     Microsoft.PowerShell.Management 模块命令），而且需要管理员；写了只会让
#     探针在 pwsh7 里直接报 CommandNotFound。这里只读地报告还原点现状，建点
#     交给用户在「系统属性 > 系统保护」里做。
#
#  2. 写操作默认 dryRun=true。只有 params.dryRun 显式等于 $false 才落盘。
#     未传 action/keys 时连 dryRun 的"将要导出"都不列，避免把每次扫描都变成
#     一份像模像样的计划书。
#
#  3. 目标目录只允许 regbackup 这一个。$outDir 是从 $env:LOCALAPPDATA 拼出来的
#     固定路径，不接受 params 传入路径——探针不该有"把备份写到任意位置"的口子。
#
# 外部命令（reg.exe）走 Start-Process 式硬超时 + 强制结束：reg export 正常
# 80 ms 左右结束，这里给 20 秒，超时就杀掉并如实报超时，绝不让探针挂死。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList
$isElevated = Test-Elevated
$started = Get-Date

# ---- helpers ---------------------------------------------------------------
# reg.exe 的输出是 OEM 代码页（本机 936），按 UTF-8 解会得到一串问号，
# 失败信息就丢了。这里按字节判定，优先 BOM，其次严格 UTF-8，再退代码页。
function ConvertFrom-ToolBytes {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return [ordered]@{ text = ''; encoding = 'empty' } }

    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [ordered]@{ text = [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2); encoding = 'utf16-bom' }
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [ordered]@{ text = [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3); encoding = 'utf8-bom' }
    }
    if (($Bytes.Length % 2) -eq 0 -and $Bytes.Length -ge 4) {
        $zOdd = 0
        $zEven = 0
        $i = 0
        while ($i -lt $Bytes.Length) {
            if ($Bytes[$i] -eq 0) { $zEven++ }
            if ($i + 1 -lt $Bytes.Length -and $Bytes[$i + 1] -eq 0) { $zOdd++ }
            $i += 2
        }
        if ($zOdd -ge 2 -and $zOdd -gt ($zEven * 2)) {
            $s = [Text.Encoding]::Unicode.GetString($Bytes)
            if ($s -notmatch "`u{FFFD}") { return [ordered]@{ text = $s; encoding = 'utf16' } }
        }
    }
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    try { return [ordered]@{ text = $strict.GetString($Bytes); encoding = 'utf8' } } catch {}
    foreach ($cp in @([int][Console]::OutputEncoding.CodePage, 936, 65001)) {
        if ($cp -le 0) { continue }
        try {
            $enc = [Text.Encoding]::GetEncoding($cp)
            $t = $enc.GetString($Bytes)
            if ($t -notmatch "`u{FFFD}") { return [ordered]@{ text = $t; encoding = "cp$cp" } }
        } catch {}
    }
    return [ordered]@{ text = [Text.Encoding]::UTF8.GetString($Bytes); encoding = 'utf8-lossy' }
}

# 跑一个外部命令，硬超时。返回 exitCode/timedOut/elapsedMs/text/stderr/error。
function Invoke-NativeTool {
    param([string]$Exe, [string[]]$ArgumentList = @(), [int]$TimeoutMs = 20000)
    $res = [ordered]@{
        ran = $false; exitCode = $null; timedOut = $false
        elapsedMs = 0; text = ''; stderr = ''; encoding = ''; error = ''
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($psi.PSObject.Properties.Name -contains 'ArgumentList') {
        foreach ($a in $ArgumentList) { $psi.ArgumentList.Add([string]$a) }
    } else {
        $quoted = foreach ($a in $ArgumentList) {
            if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
        }
        $psi.Arguments = ($quoted -join ' ')
    }
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    try { $proc.Start() | Out-Null } catch {
        $res.error = $_.Exception.Message
        $sw.Stop(); $res.elapsedMs = [int]$sw.ElapsedMilliseconds
        return $res
    }
    $res.ran = $true
    $msOut = New-Object IO.MemoryStream
    $msErr = New-Object IO.MemoryStream
    $tOut = $proc.StandardOutput.BaseStream.CopyToAsync($msOut)
    $tErr = $proc.StandardError.BaseStream.CopyToAsync($msErr)
    $finished = $proc.WaitForExit($TimeoutMs)
    if (-not $finished) {
        $res.timedOut = $true
        try { $proc.Kill() | Out-Null } catch {}
        try { $proc.WaitForExit(3000) | Out-Null } catch {}
    }
    try { $tOut.Wait(3000) | Out-Null } catch {}
    try { $tErr.Wait(3000) | Out-Null } catch {}
    try { if ($finished) { $res.exitCode = $proc.ExitCode } } catch {}
    $sw.Stop()
    $res.elapsedMs = [int]$sw.ElapsedMilliseconds
    $res.text = (ConvertFrom-ToolBytes -Bytes $msOut.ToArray()).text
    $res.stderr = (ConvertFrom-ToolBytes -Bytes $msErr.ToArray()).text
    try { $proc.Dispose() } catch {}
    return $res
}

# 字节数 → 人读的大小。还原点配额动辄几十 GB，直接打字节数没人看得懂。
function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -le 0) { return '0 B' }
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($units.Count - 1)) { $Bytes = $Bytes / 1024; $i++ }
    return ('{0:0.##} {1}' -f $Bytes, $units[$i])
}

# ---- 参数：dryRun / action / keys -----------------------------------------
# 写操作默认不执行：属性不存在、值是字符串 "true"、值是 0/空，都算 dryRun。
# 只有显式 $false 才真正落盘。
$dryRun = -not ($params.PSObject.Properties.Name -contains 'dryRun' -and $params.dryRun -eq $false)

$action = ''
if ($params.PSObject.Properties.Name -contains 'action' -and $params.action) { $action = ([string]$params.action).Trim().ToLowerInvariant() }

# keys 可能是数组、单个字符串，甚至连键名都被 PowerShell 展开成一串字符的情况，
# 这里一律规范成非空的字符串数组，并去掉首尾空白。
$keys = @()
if ($params.PSObject.Properties.Name -contains 'keys' -and $null -ne $params.keys) {
    $rawKeys = $params.keys
    if ($rawKeys -is [string]) { $keys = @($rawKeys) } else { $keys = @($rawKeys | ForEach-Object { [string]$_ }) }
    $keys = @($keys | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
}

# ---- 1. 系统保护开关 ------------------------------------------------------
# DisableSR=1 才是"系统保护被关掉"；absent 表示从未设置（默认启用）。
# SystemRestorePointCreationFrequency 控制两次自动还原点的最短间隔（分钟），
# 未设置时 Windows 用默认的 1440（24 小时），这也是"新点覆盖旧点"的常见原因。
$srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$cfgKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\cfg'
$disableSr = Get-RegValue -Path $srKey -Name 'DisableSR'
$srFreq = Get-RegValue -Path $srKey -Name 'SystemRestorePointCreationFrequency'
$diskPercent = Get-RegValue -Path $cfgKey -Name 'DiskPercent'

$srDisabled = ($null -ne $disableSr -and [string]$disableSr -eq '1')
$srParts = @(
    "DisableSR=$(Format-RegValue $disableSr)",
    "CreationFrequency=$(Format-RegValue $srFreq)",
    "DiskPercent=$(Format-RegValue $diskPercent)"
)
if ($srDisabled) {
    Add-Item -List $items -Id 'backup:system-protection' -Group 'protection' -Label '系统保护' `
        -Status 'bad' -Value ($srParts -join ' · ') `
        -Detail 'DisableSR=1：系统保护被明确关闭，任何还原点都不会被创建' `
        -Fix '在「系统属性 > 系统保护」勾选系统盘并点击「配置」重新启用保护' -NeedsAdmin $true
} else {
    $freqNote = '未设置（Windows 默认 24 小时最多自动建一个还原点）'
    if ($null -ne $srFreq) { $freqNote = "已设为 $srFreq 分钟" }
    $dpNote = '未设置（默认按卷容量取上限）'
    if ($null -ne $diskPercent) { $dpNote = "DiskPercent=$diskPercent（还原点最多占用系统盘的 $diskPercent%）" }
    Add-Item -List $items -Id 'backup:system-protection' -Group 'protection' -Label '系统保护' `
        -Status 'ok' -Value ($srParts -join ' · ') `
        -Detail "DisableSR 未设置即保护开启；建立频率$freqNote；配额$dpNote" `
        -Fix '' -NeedsAdmin $false
}

# ---- 2. 还原点 ------------------------------------------------------------
$shadowCopies = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue)
$rpCount = $shadowCopies.Count
$rpNewest = ''
if ($rpCount -gt 0) {
    $latest = $shadowCopies | Sort-Object -Property { [string]$_.InstallDate } -Descending | Select-Object -First 1
    try { $rpNewest = ([Management.ManagementDateTimeConverter]::ToDateTime([string]$latest.InstallDate)).ToString('yyyy-MM-dd HH:mm') } catch { $rpNewest = [string]$latest.InstallDate }
}
if ($rpCount -eq 0) {
    Add-Item -List $items -Id 'backup:restore-points' -Group 'restore' -Label '还原点' `
        -Status 'warn' -Value '0 个' `
        -Detail 'Win32_ShadowCopy 为空：没有可回滚的快照，改驱动/系统设置前缺少退路' `
        -Fix '先在「系统属性 > 系统保护」为系统盘建一个还原点，再动系统（建点需管理员）' -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'backup:restore-points' -Group 'restore' -Label '还原点' `
        -Status 'ok' -Value "$rpCount 个 · 最近 $rpNewest" `
        -Detail '存在可用快照，出问题可以回滚' -Fix '' -NeedsAdmin $false
}

# ---- 3. VSS / SDRSVC 服务 -------------------------------------------------
# 两个服务默认 Manual + Stopped，这是设计如此；只有服务缺失或异常退出才值得报警。
$svcParts = New-Object System.Collections.Generic.List[string]
$svcMissing = 0
foreach ($name in @('VSS', 'SDRSVC')) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) { $svcParts.Add("$name=$($svc.Status)/$($svc.StartType)") }
    else { $svcParts.Add("$name=absent"); $svcMissing++ }
}
Add-Item -List $items -Id 'backup:vss-services' -Group 'restore' -Label '卷影服务' `
    -Status $(if ($svcMissing -gt 0) { 'warn' } else { 'info' }) -Value ($svcParts -join ' · ') `
    -Detail $(if ($svcMissing -gt 0) { '有服务缺失：创建还原点和卷影复制都会失败' } else { 'VSS/SDRSVC 按需启动，Stopped/Manual 是默认状态，建点时由系统拉起' }) `
    -Fix $(if ($svcMissing -gt 0) { '检查系统镜像完整性后再试' } else { '' }) -NeedsAdmin $false

# ---- 4. 影子存储配额 ------------------------------------------------------
# Win32_ShadowStorage 只在卷上真正建过快照时才有记录；本机 0 条恰好和 0 个
# 还原点对得上。没有记录不等于"配额为 0"，所以这里用 info 而不是 bad。
$shadowStorage = @(Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction SilentlyContinue)
if ($shadowStorage.Count -eq 0) {
    Add-Item -List $items -Id 'backup:shadow-storage' -Group 'restore' -Label '影子存储' `
        -Status 'info' -Value '0 条配额记录' `
        -Detail 'Win32_ShadowStorage 没有条目：该卷从未建过快照，配额尚未分配（与 0 个还原点一致）' `
        -Fix '创建第一个还原点后这里才会出现 UsedSpace/MaxSpace' -NeedsAdmin $false
} else {
    $usedSum = 0
    $maxSum = 0
    $stLines = New-Object System.Collections.Generic.List[string]
    foreach ($s in $shadowStorage) {
        $u = 0; $m = 0
        [void][double]::TryParse([string]$s.UsedSpace, [ref]$u)
        [void][double]::TryParse([string]$s.MaxSpace, [ref]$m)
        $usedSum += $u
        $maxSum += $m
        $stLines.Add("$([string]$s.DiffVolume)：已用 $(Format-Bytes $u) / 上限 $(Format-Bytes $m)")
    }
    $pct = 0
    if ($maxSum -gt 0) { $pct = [math]::Round(($usedSum / $maxSum) * 100, 1) }
    Add-Item -List $items -Id 'backup:shadow-storage' -Group 'restore' -Label '影子存储' `
        -Status $(if ($pct -ge 90) { 'warn' } else { 'info' }) `
        -Value ("已用 $(Format-Bytes $usedSum) / 上限 $(Format-Bytes $maxSum)（$pct%）") `
        -Detail (($stLines | Select-Object -First 5) -join '；') `
        -Fix $(if ($pct -ge 90) { '旧快照快占满配额，新建的点会挤掉旧的；可在系统保护里调大配额' } else { '' }) -NeedsAdmin $false
}

# ---- 5. 已有的注册表备份 --------------------------------------------------
# 这条是"我上次到底备过没有"的依据：数文件和字节数，不读内容。
$backupRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox') 'regbackup'
$existingFiles = @()
if (Test-Path -LiteralPath $backupRoot) {
    # 文件系统的 Test-Path 很便宜（实测 1.6 ms），这里可以放心用。
    $existingFiles = @(Get-ChildItem -LiteralPath $backupRoot -Filter '*.reg' -File -ErrorAction SilentlyContinue)
}
$existingBytes = 0
$existingLatest = ''
if ($existingFiles.Count -gt 0) {
    foreach ($f in $existingFiles) { $existingBytes += [long]$f.Length }
    $newestFile = $existingFiles | Sort-Object -Property { $_.LastWriteTime } -Descending | Select-Object -First 1
    $existingLatest = $newestFile.Name + ' (' + $newestFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + ')'
}
if ($existingFiles.Count -eq 0) {
    Add-Item -List $items -Id 'backup:regbackup-files' -Group 'export' -Label '注册表备份' `
        -Status 'warn' -Value '0 个文件' `
        -Detail "目录 $backupRoot 下还没有 .reg 备份，改注册表前没有退路" `
        -Fix '用 params.action=export + params.keys 导出要改的键（默认 dryRun，确认后再落盘）' -NeedsAdmin $false
} else {
    Add-Item -List $items -Id 'backup:regbackup-files' -Group 'export' -Label '注册表备份' `
        -Status 'ok' -Value "$($existingFiles.Count) 个 .reg · 共 $(Format-Bytes $existingBytes)" `
        -Detail "最新一份：$existingLatest；目录 $backupRoot" `
        -Fix '' -NeedsAdmin $false
}

# ---- 6. Windows 备份状态 --------------------------------------------------
# 这台机器上这个键存在但既无值也无子键 = 从未配置过"备份和还原(Windows 7)"。
# 值名在不同版本里不统一，这里把 ValueNames 原样列出，看到什么报什么。
$wbKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsBackup'
$wbKeyItem = Get-Item -LiteralPath $wbKey -ErrorAction SilentlyContinue
if ($null -eq $wbKeyItem) {
    Add-Item -List $items -Id 'backup:windows-backup' -Group 'protection' -Label 'Windows 备份' `
        -Status 'skip' -Value '无此键' `
        -Detail 'WindowsBackup 键不存在（精简系统或从未打开过「备份和还原」），无法判断备份状态' `
        -Fix '' -NeedsAdmin $false
} else {
    $wbNames = @($wbKeyItem.GetValueNames())
    $wbSubs = @(Get-ChildItem -LiteralPath $wbKey -ErrorAction SilentlyContinue)
    if ($wbNames.Count -eq 0 -and $wbSubs.Count -eq 0) {
        Add-Item -List $items -Id 'backup:windows-backup' -Group 'protection' -Label 'Windows 备份' `
            -Status 'info' -Value '未配置' `
            -Detail 'WindowsBackup 键存在但没有任何值和子键：从未设置过 Windows 备份，也没有正在运行的备份任务' `
            -Fix '需要整机镜像备份时在「控制面板 > 备份和还原(Windows 7)」里设置；日常回滚用还原点更轻' -NeedsAdmin $false
    } else {
        $wbDetail = "值：" + $(if ($wbNames.Count -gt 0) { $wbNames -join ', ' } else { '无' }) +
            "；子键：" + $(if ($wbSubs.Count -gt 0) { (@($wbSubs | ForEach-Object { $_.PSChildName }) -join ', ') } else { '无' })
        Add-Item -List $items -Id 'backup:windows-backup' -Group 'protection' -Label 'Windows 备份' `
            -Status 'info' -Value "$($wbNames.Count) 个值 · $($wbSubs.Count) 个子键" `
            -Detail $wbDetail -Fix '' -NeedsAdmin $false
    }
}

# ---- 7. 注册表导出（唯一写操作，默认 dryRun） ----------------------------
# 键路径在 reg.exe 里要写成 HKLM\...（花括号形式），而 PowerShell 里是
# HKLM:\...。转换只针对驱动器前缀，不动后面反斜杠的内容。
function ConvertTo-RegPath {
    param([string]$KeyPath)
    $p = $KeyPath.Trim()
    if ($p -match '^(HK(?:EY_)?(?:LM|CU|CR|U|CC))\s*:\s*(.*)$') { $p = $Matches[1] + '\' + $Matches[2].TrimStart('\') }
    return $p
}
function Get-SafeFileName {
    param([string]$KeyPath)
    # \ / : * ? " < > | 在文件名里都不合法，统一换成下划线；过长时保留尾巴
    # （键名有区分度的部分通常在最后一级）。
    $safe = ($KeyPath -replace '[\\/:*?"<>|]', '_')
    if ($safe.Length -gt 90) { $safe = $safe.Substring($safe.Length - 90) }
    return $safe
}

$exportResults = New-Object System.Collections.Generic.List[object]
$exportItemStatus = 'info'
$exportValue = ''
$exportDetail = ''
$exportFix = ''

if ($action -ne 'export') {
    $exportItemStatus = 'skip'
    $exportValue = '未请求导出'
    $exportDetail = if ($action) { "params.action=$action 不是 export，本次不导出任何键" } else { '未传 params.action=export，本探针只做只读巡检（写操作需要显式请求）' }
} elseif ($keys.Count -eq 0) {
    $exportItemStatus = 'skip'
    $exportValue = '未提供键'
    $exportDetail = 'action=export 但 params.keys 为空，没有可导出的目标'
    $exportFix = '在 params.keys 里给出要备份的注册表键，例如 HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
} elseif ($dryRun) {
    # dryRun 不落盘，只把"将会写到哪里"列清楚，让用户在点确认之前就能核对。
    $exportItemStatus = 'info'
    $exportValue = "$($keys.Count) 个键 · dryRun，未落盘"
    $planLines = foreach ($k in $keys) {
        $rp = ConvertTo-RegPath -KeyPath $k
        $name = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + (Get-SafeFileName -KeyPath $rp) + '.reg'
        "$rp → $(Join-Path $backupRoot $name)"
    }
    $exportDetail = '将导出到 ' + $backupRoot + '：' + (($planLines | Select-Object -First 6) -join '；')
    $exportFix = '确认后以 params.dryRun=false 重新运行即真正写入'
} else {
    # 真正落盘：目录先建好（文件系统 -Force 是安全的，不会清空内容），
    # 再逐个 export，每个都记 exit code 和落盘字节数。
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        try { New-Item -ItemType Directory -Path $backupRoot -Force -ErrorAction Stop | Out-Null } catch {}
    }
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        $exportItemStatus = 'bad'
        $exportValue = '无法创建目录'
        $exportDetail = "创建备份目录失败：$backupRoot（可能被安全软件拦截或磁盘只读）"
        $exportFix = '确认该路径可写后重试'
    } else {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
        foreach ($k in $keys) {
            $regPath = ConvertTo-RegPath -KeyPath $k
            $outFile = Join-Path $backupRoot ($stamp + '-' + (Get-SafeFileName -KeyPath $regPath) + '.reg')
            $rec = [ordered]@{
                key = $k; regPath = $regPath; file = $outFile
                exitCode = $null; bytes = 0; ok = $false; timedOut = $false; error = ''
            }
            if (Test-Path -LiteralPath $outFile) {
                $rec.error = '同名文件已存在，为免覆盖已跳过'
            } else {
                $r = Invoke-NativeTool -Exe $regExe -ArgumentList @('export', $regPath, $outFile, '/y') -TimeoutMs 20000
                $rec.exitCode = $r.exitCode
                $rec.timedOut = $r.timedOut
                if ($r.timedOut) {
                    $rec.error = 'reg export 超时 20 秒，已强制结束'
                } elseif ($r.error) {
                    $rec.error = $r.error
                } else {
                    $msg = (([string]$r.stderr).Trim() + ' ' + ([string]$r.text).Trim()).Trim()
                    if (Test-Path -LiteralPath $outFile) { $rec.bytes = [long](Get-Item -LiteralPath $outFile).Length }
                    if ($r.exitCode -eq 0 -and $rec.bytes -gt 0) {
                        $rec.ok = $true
                    } elseif ($r.exitCode -eq 0) {
                        $rec.error = 'reg export 返回 0 但没有生成文件（或文件为 0 字节）'
                    } else {
                        $rec.error = if ($msg) { $msg } else { "reg export 返回 exit $($r.exitCode)，无输出" }
                    }
                }
            }
            $exportResults.Add([pscustomobject]$rec)
        }
        $okCount = @($exportResults | Where-Object { $_.ok }).Count
        $failCount = $exportResults.Count - $okCount
        $totalBytes = 0
        foreach ($r in $exportResults) { $totalBytes += [long]$r.bytes }
        if ($failCount -eq 0) { $exportItemStatus = 'ok' } elseif ($okCount -gt 0) { $exportItemStatus = 'warn' } else { $exportItemStatus = 'bad' }
        $exportValue = "$okCount/$($exportResults.Count) 成功 · 共 $(Format-Bytes $totalBytes)"
        $failLines = @($exportResults | Where-Object { -not $_.ok } | ForEach-Object { "$($_.regPath)：$($_.error)" })
        $okLines = @($exportResults | Where-Object { $_.ok } | ForEach-Object { "$($_.regPath) → $(Split-Path -Leaf $_.file) ($($_.bytes) B)" })
        if ($failCount -eq 0) {
            $exportDetail = '已写入 ' + $backupRoot + '：' + (($okLines | Select-Object -First 6) -join '；')
        } else {
            $exportDetail = (($failLines | Select-Object -First 3) -join '；')
            if ($okCount -gt 0) { $exportDetail += '；成功 ' + $okCount + ' 个：' + (($okLines | Select-Object -First 3) -join '，') }
            $exportFix = '确认键路径拼写（PowerShell 写成 HKLM:\...，reg 用 HKLM\...）与是否有读取该键的权限'
        }
    }
}
Add-Item -List $items -Id 'backup:export' -Group 'export' -Label '注册表导出' `
    -Status $exportItemStatus -Value $exportValue -Detail $exportDetail -Fix $exportFix -NeedsAdmin $false

# ---- 汇总 ------------------------------------------------------------------
$elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
Write-ProbeResult -Items $items -Extra @{
    elapsedMs      = $elapsedMs
    elevated       = $isElevated
    dryRun         = $dryRun
    action         = $action
    requestedKeys  = @($keys)
    backupRoot     = $backupRoot
    existingBackups = [ordered]@{ count = $existingFiles.Count; bytes = $existingBytes; newest = $existingLatest }
    restorePoints  = [ordered]@{
        count       = $rpCount
        newest      = $rpNewest
        diskPercent = $(if ($null -ne $diskPercent) { $diskPercent } else { $null })
        disableSR   = $(if ($null -ne $disableSr) { $disableSr } else { $null })
    }
    exports        = @($exportResults.ToArray() | ForEach-Object {
            [ordered]@{ key = $_.regPath; file = $_.file; exitCode = $_.exitCode; bytes = $_.bytes; ok = $_.ok; error = $_.error }
        })
} -Note '只读巡检 + 一条受控写路径（reg export 到 %LOCALAPPDATA%\dsh-windows-toolbox\regbackup）。不修改注册表，不调用 Checkpoint-Computer，不创建还原点。写操作默认 dryRun=true，需显式 params.dryRun=false。'
