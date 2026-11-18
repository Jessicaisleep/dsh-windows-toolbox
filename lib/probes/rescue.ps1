param([string]$ParamFile)

# ---------------------------------------------------------------------------
# rescue.ps1 — 系统救援巡检（只读，不执行 sfc /scannow 或 DISM /RestoreHealth）
#
# 这个探针只回答「现在能不能修、坏在哪」，不修任何东西。所有修复动作
# （sfc /scannow、DISM /RestoreHealth、创建还原点）都需要管理员，且会用掉
# 十几分钟，绝不能藏在一次扫描里。
#
# 三处实现上的坑，都是在本机实测踩出来的：
#
#  1. sfc /verifyonly 的输出是 UTF-16LE，不是控制台代码页。按 GBK/UTF-8 解
#     会得到 `N�NO(u s f c ...`，看起来像"命令失败"，其实是提示语
#     「为了使用 sfc 工具，你必须作为管理员运行控制台会话。」。所以这里按
#     字节解码，先看 BOM，再看奇数位 0x00 的比例（真 UTF-16LE 的 ASCII 段
#     一定在奇数位出现 0x00，而用 GBK 编码的中文一个 0x00 都没有），最后才
#     退回严格 UTF-8 / 936。
#
#  2. Get-WinEvent 在没有匹配事件时不是返回空数组，而是抛
#     NoMatchingEventsFoundException（本机 Message 是「找不到与指定的选择
#     条件匹配的事件。」）。把它当成"读取失败"会把一台干净机器报成读不到日志。
#     这个探针改成在受控 runspace 里 catch，用 "EMPTY|0" 哨兵返回，把
#     "没有事件" 和 "读不到日志" 分成两种结果。
#
#  3. Get-PnpDevice 默认返回全部历史记录：本机 254 个设备里 89 个是
#     CM_PROB_PHANTOM（拔掉的 U 盘/键鼠留下的记录），Status 全是 Unknown。
#     按 Status -ne 'OK' 去数会把 89 个幽灵算成 89 个故障设备。必须用
#     -PresentOnly 只看当前插着的硬件。
#
# 外部命令（sfc / DISM）一律 Start-Process 式硬超时 + 强制结束，绝不挂死：
# 未提权时 sfc 约 40 ms、DISM 约 200 ms 就返回；提权后 sfc /verifyonly 在
# 大型系统上可能跑几分钟，这里最多等 $sfcTimeoutMs（默认 50 秒），超时就报
# skip 并告诉用户去管理员命令行手动跑，而不是把面板卡死。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList
$isElevated = Test-Elevated
$started = Get-Date

# ---- helpers ---------------------------------------------------------------
# 字节 → 文本。sfc 是 UTF-16LE，DISM/reg 是 OEM 代码页（本机 936）。
# 直接按 UTF-8 解析 UTF-16LE 的中文会得到一长串替换字符，所以先判定再看内容。
function ConvertFrom-ToolBytes {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return [ordered]@{ text = ''; encoding = 'empty' } }

    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [ordered]@{ text = [Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2); encoding = 'utf16-bom' }
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [ordered]@{ text = [Text.Encoding]::UTF8.GetString($Bytes, 3, $Bytes.Length - 3); encoding = 'utf8-bom' }
    }

    # UTF-16LE 判定：ASCII 字符的高字节是 0x00，且只出现在奇数位。用 GBK
    # 编码的中文根本不会产生 0x00，这一条足以把 sfc 的输出和 DISM 的输出分开。
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

# 跑一个外部命令，带回硬超时。返回 exitCode/timedOut/elapsedMs/text/stderr/encoding。
# 用 ProcessStartInfo.ArgumentList 传参，避免路径里的空格和引号被 shell 重新解释；
# PowerShell 5.1（.NET Framework）没有 ArgumentList，退回手工拼引号的 Arguments。
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
    $dec = ConvertFrom-ToolBytes -Bytes $msOut.ToArray()
    $res.text = $dec.text
    $res.encoding = $dec.encoding
    $res.stderr = (ConvertFrom-ToolBytes -Bytes $msErr.ToArray()).text
    try { $proc.Dispose() } catch {}
    return $res
}

# 在独立 runspace 里跑一段脚本，带硬超时并给结果加哨兵。Get-WinEvent 这类
# 会卡在 RPC 上的 cmdlet 用它包一层；脚本自己 catch 并把"无事件"翻译成
# EMPTY 哨兵，避免跨边界抛异常时把 NoMatchingEvents 误判成读取失败。
function Invoke-BoundedScript {
    param($Script, [int]$TimeoutMs = 15000)
    $out = [ordered]@{ ok = $false; timedOut = $false; result = $null; error = '' }
    $ps = $null
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddScript([string]$Script, $true)
        $async = $ps.BeginInvoke()
        $done = $async.AsyncWaitHandle.WaitOne($TimeoutMs)
        if (-not $done) {
            $out.timedOut = $true
            try { $ps.Stop() } catch {}
            return $out
        }
        $res = $ps.EndInvoke($async)
        $out.ok = $true
        if ($res -and $res.Count -gt 0) { $out.result = [string]$res[0] }
        return $out
    } catch {
        $out.error = $_.Exception.Message
        return $out
    } finally {
        if ($ps) { try { $ps.Dispose() } catch {} }
    }
}

# params 里的超时（可选，面板默认不传）。夹在 5 秒到 10 分钟之间，
# 免得手工传一个 0 或负数把探针变成"立刻超时"。
function Get-TimeoutParam {
    param($Value, [int]$Default, [int]$Min = 5000, [int]$Max = 600000)
    $n = 0
    if (-not [int]::TryParse([string]$Value, [ref]$n)) { return $Default }
    if ($n -lt $Min) { return $Min }
    if ($n -gt $Max) { return $Max }
    return $n
}

$sfcTimeout = Get-TimeoutParam -Value $params.sfcTimeoutMs -Default 50000
$dismTimeout = Get-TimeoutParam -Value $params.dismTimeoutMs -Default 35000

$systemRoot = $env:SystemRoot
if (-not $systemRoot) { $systemRoot = 'C:\Windows' }

# ---- 1. 待重启标记 --------------------------------------------------------
# 三个标记互为补充：CBS 管组件安装，WU 管更新，PendingFileRenameOperations
# 管"文件被占用、下次启动时替换"。任何一个为真，机器就处在"半装完"状态。
# 读键用 Get-Item（缺键约 26 ms），不用 Test-Path（缺键实测 163 ms）。
$cbsPending = ($null -ne (Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction SilentlyContinue))
$wuPending = ($null -ne (Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction SilentlyContinue))
$pfroRaw = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations'
$pfroEntries = @()
if ($null -ne $pfroRaw) { $pfroEntries = @($pfroRaw) }
# PendingFileRenameOperations 是「源/目标」成对出现的 MULTI_SZ，每一项都带
# 一个空串占位，所以真实的重命名操作数是非空条目数，不是数组长度。
# 本机 42 条记录 = 21 项操作。
$pfroOps = @($pfroEntries | Where-Object { $_ -ne '' }).Count
$pfroPending = ($pfroEntries.Count -gt 0)

$pendingCount = 0
$pendingNames = New-Object System.Collections.Generic.List[string]
if ($cbsPending) { $pendingCount++; $pendingNames.Add('CBS RebootPending') }
if ($wuPending) { $pendingCount++; $pendingNames.Add('WU RebootRequired') }
if ($pfroPending) { $pendingCount++; $pendingNames.Add("PendingFileRename x$pfroOps") }

$rebootValue = "CBS=$cbsPending · WU=$wuPending · PendingFileRename=$pfroPending"
if ($pendingCount -gt 0) {
    Add-Item -List $items -Id 'rescue:pending-reboot' -Group 'reboot' -Label '待重启' `
        -Status 'warn' -Value $rebootValue `
        -Detail ("$pendingCount 个标记为真：" + ($pendingNames -join '，') + "。挂起的替换通常是杀毒驱动或 Office 就地更新留下的，重启后才会落盘。") `
        -Fix '重启一次完成挂起的安装/替换；重启前不要再装驱动或更新' -NeedsAdmin $false
} else {
    Add-Item -List $items -Id 'rescue:pending-reboot' -Group 'reboot' -Label '待重启' `
        -Status 'ok' -Value $rebootValue `
        -Detail '三个标记都为空：没有等待重启才能完成的安装或文件替换' -Fix '' -NeedsAdmin $false
}

# ---- 2. 组件存储包数 ------------------------------------------------------
# CBS\Packages 的键数就是组件存储里登记的包数。它是"系统文件完整性"的规模
# 指标：清空或异常膨胀都说明组件存储被动过，更新失败的案子大多从这里看起。
$pkgCount = -1
$pkgKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
$pkgChildren = @(Get-ChildItem -LiteralPath $pkgKey -ErrorAction SilentlyContinue)
if ($pkgChildren.Count -gt 0) { $pkgCount = $pkgChildren.Count }
if ($pkgCount -lt 0) {
    Add-Item -List $items -Id 'rescue:cbs-packages' -Group 'integrity' -Label '组件存储' `
        -Status 'skip' -Value '读不到' -Detail 'CBS\Packages 存在但枚举为空（可能需要管理员）' -Fix '' -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'rescue:cbs-packages' -Group 'integrity' -Label '组件存储' `
        -Status 'info' -Value "$pkgCount 个包" `
        -Detail 'Component Based Servicing\Packages 的登记键数；更新异常时对照这个数量看是否有包缺失' `
        -Fix '' -NeedsAdmin $false
}

# ---- 3. sfc /verifyonly ---------------------------------------------------
# 不跑 /scannow：verifyonly 只校验不修，但仍然要管理员。未提权时 sfc 会以
# exit 1 返回 UTF-16LE 的「你必须作为管理员运行控制台会话」——仍然调用一次，
# 把这个原始证据解码后写进 detail，比笼统写一句"需要管理员"更有据可查。
$sfcExe = Join-Path $systemRoot 'System32\sfc.exe'
if (-not (Test-Path -LiteralPath $sfcExe)) {
    Add-Item -List $items -Id 'rescue:sfc' -Group 'integrity' -Label '系统文件' `
        -Status 'skip' -Value '找不到 sfc.exe' -Detail "未在 $sfcExe 找到 sfc" -Fix '' -NeedsAdmin $true
} else {
    $sfc = Invoke-NativeTool -Exe $sfcExe -ArgumentList @('/verifyonly') -TimeoutMs $sfcTimeout
    $sfcText = ([string]$sfc.text).Trim()
    $adminMsg = ($sfcText -match '管理员|administrator|elevat')
    if ($sfc.timedOut) {
        Add-Item -List $items -Id 'rescue:sfc' -Group 'integrity' -Label '系统文件' `
            -Status 'skip' -Value "超时 $([int]($sfcTimeout/1000)) 秒" `
            -Detail 'sfc /verifyonly 未在时限内结束（大型系统常需数分钟）。没有下结论，超时不算发现损坏' `
            -Fix '在管理员命令行手动运行 sfc /verifyonly，或调大 params.sfcTimeoutMs' -NeedsAdmin $true
    } elseif ($sfc.exitCode -eq 1 -and $adminMsg) {
        Add-Item -List $items -Id 'rescue:sfc' -Group 'integrity' -Label '系统文件' `
            -Status 'skip' -Value 'exit 1 · 需要管理员' `
            -Detail "sfc 拒绝执行，原话（UTF-16LE 解码）：$sfcText" `
            -Fix '以管理员身份重新扫描，或运行 sfc /scannow 修复' -NeedsAdmin $true
    } elseif ($sfc.exitCode -eq 0) {
        Add-Item -List $items -Id 'rescue:sfc' -Group 'integrity' -Label '系统文件' `
            -Status 'ok' -Value "exit 0 · 耗时 $($sfc.elapsedMs) ms" `
            -Detail 'sfc /verifyonly 未发现完整性冲突' -Fix '' -NeedsAdmin $true
    } else {
        $corrupt = ($sfcText -match '找到损坏|found corrupt|完整性冲突')
        Add-Item -List $items -Id 'rescue:sfc' -Group 'integrity' -Label '系统文件' `
            -Status $(if ($corrupt) { 'bad' } else { 'warn' }) `
            -Value "exit $($sfc.exitCode)" `
            -Detail $(if ($sfcText) { $sfcText } else { "sfc 返回非零退出码但没有输出" }) `
            -Fix '运行 sfc /scannow（需管理员）；仍失败再用 DISM /RestoreHealth' -NeedsAdmin $true
    }
}

# ---- 4. DISM /CheckHealth -------------------------------------------------
# 只 CheckHealth（读标记），不 ScanHealth/RestoreHealth。未提权时 DISM 直接
# 以 exit 740 返回「需要提升权限才能运行 DISM」，这本身就是明确结论。
$dismExe = Join-Path $systemRoot 'System32\Dism.exe'
$dism = $null
if (Test-Path -LiteralPath $dismExe) {
    $dism = Invoke-NativeTool -Exe $dismExe -ArgumentList @('/Online', '/Cleanup-Image', '/CheckHealth') -TimeoutMs $dismTimeout
}
if ($null -eq $dism) {
    Add-Item -List $items -Id 'rescue:dism-health' -Group 'integrity' -Label '组件健康' `
        -Status 'skip' -Value '找不到 Dism.exe' -Detail "未在 $dismExe 找到 DISM" -Fix '' -NeedsAdmin $true
} elseif ($dism.timedOut) {
    Add-Item -List $items -Id 'rescue:dism-health' -Group 'integrity' -Label '组件健康' `
        -Status 'skip' -Value "超时 $([int]($dismTimeout/1000)) 秒" `
        -Detail 'DISM /CheckHealth 未在时限内结束，未下结论' `
        -Fix '在管理员命令行手动运行 DISM /Online /Cleanup-Image /CheckHealth' -NeedsAdmin $true
} elseif ($dism.exitCode -eq 740) {
    Add-Item -List $items -Id 'rescue:dism-health' -Group 'integrity' -Label '组件健康' `
        -Status 'skip' -Value 'exit 740 · 需要管理员' `
        -Detail ("DISM 拒绝执行：" + (([string]$dism.text).Trim() -replace '\s+', ' ')) `
        -Fix '以管理员身份扫描，或运行 DISM /Online /Cleanup-Image /CheckHealth' -NeedsAdmin $true
} else {
    $dismText = ([string]$dism.text).Trim()
    $healthy = ($dismText -match 'No component store corruption|未检测到组件存储损坏')
    $repairable = ($dismText -match 'The component store is repairable|组件存储可修复')
    if ($dism.exitCode -eq 0 -and $healthy) {
        Add-Item -List $items -Id 'rescue:dism-health' -Group 'integrity' -Label '组件健康' `
            -Status 'ok' -Value "exit 0 · 耗时 $($dism.elapsedMs) ms" `
            -Detail 'DISM /CheckHealth 未检测到组件存储损坏' -Fix '' -NeedsAdmin $true
    } elseif ($repairable) {
        Add-Item -List $items -Id 'rescue:dism-health' -Group 'integrity' -Label '组件健康' `
            -Status 'warn' -Value "exit $($dism.exitCode) · 可修复" `
            -Detail $dismText `
            -Fix '运行 DISM /Online /Cleanup-Image /RestoreHealth（需管理员，约十几分钟）' -NeedsAdmin $true
    } else {
        Add-Item -List $items -Id 'rescue:dism-health' -Group 'integrity' -Label '组件健康' `
            -Status 'warn' -Value "exit $($dism.exitCode)" `
            -Detail $(if ($dismText) { ($dismText -replace '\s+', ' ') } else { 'DISM 返回非零退出码但没有输出' }) `
            -Fix '在管理员命令行重跑 CheckHealth，看完整报错' -NeedsAdmin $true
    }
}

# ---- 5. 系统还原点 --------------------------------------------------------
# Win32_ShadowCopy 是系统还原和卷影复制共用的快照表。0 条 = 没有任何回滚点，
# 动手改驱动/系统设置前没有后悔药。
$shadowCopies = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue)
$rpCount = $shadowCopies.Count
$rpNewest = ''
if ($rpCount -gt 0) {
    $latest = $shadowCopies | Sort-Object -Property { [string]$_.InstallDate } -Descending | Select-Object -First 1
    try { $rpNewest = ([Management.ManagementDateTimeConverter]::ToDateTime([string]$latest.InstallDate)).ToString('yyyy-MM-dd HH:mm') } catch { $rpNewest = [string]$latest.InstallDate }
}
if ($rpCount -eq 0) {
    Add-Item -List $items -Id 'rescue:restore-points' -Group 'restore' -Label '还原点' `
        -Status 'warn' -Value '0 个' `
        -Detail 'Win32_ShadowCopy 为空：改驱动或系统设置出了问题无法回滚到之前的状态' `
        -Fix '在「系统属性 > 系统保护」为系统盘开启保护并手动创建一个还原点（需管理员）' -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'rescue:restore-points' -Group 'restore' -Label '还原点' `
        -Status 'ok' -Value "$rpCount 个 · 最近 $rpNewest" `
        -Detail '有可用的卷影快照，可以回滚' -Fix '' -NeedsAdmin $false
}

# ---- 6. VSS / SDRSVC 服务 -------------------------------------------------
# 两个服务默认都是 Manual + Stopped，这是设计如此（按需启动），本身不是故障；
# 但配合 0 个还原点就说明它们从未被触发过。
$svcParts = New-Object System.Collections.Generic.List[string]
$svcStopped = 0
$svcMissing = 0
foreach ($name in @('VSS', 'SDRSVC')) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svc) {
        $svcParts.Add("$name=$($svc.Status)/$($svc.StartType)")
        if ([string]$svc.Status -eq 'Stopped') { $svcStopped++ }
    } else {
        $svcParts.Add("$name=absent")
        $svcMissing++
    }
}
Add-Item -List $items -Id 'rescue:vss-services' -Group 'restore' -Label '卷影服务' `
    -Status $(if ($svcMissing -gt 0) { 'warn' } else { 'info' }) `
    -Value ($svcParts -join ' · ') `
    -Detail $(if ($svcMissing -gt 0) { '有服务缺失，还原点功能不可用' } else { 'VSS/SDRSVC 按需启动，Stopped/Manual 是默认状态；只有在创建还原点时才需要它们起来' }) `
    -Fix $(if ($svcMissing -gt 0) { '检查系统镜像是否完好' } else { '' }) -NeedsAdmin $false

# ---- 7. 有问题的设备 ------------------------------------------------------
# 必须 -PresentOnly：不加这个参数会把历史幽灵设备（CM_PROB_PHANTOM，拔掉的
# U 盘和键鼠留下的记录）也算进来，本机 254 个设备里 89 个是这种。
$presentDevices = @()
$allDevices = @()
try { $presentDevices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop) } catch { $presentDevices = @() }
try { $allDevices = @(Get-PnpDevice -ErrorAction Stop) } catch { $allDevices = @() }
if ($presentDevices.Count -eq 0) {
    # 退回 CIM：ConfigManagerErrorCode 非 0 且不是 22（用户禁用）才算异常。
    $cimBad = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
            $null -ne $_.ConfigManagerErrorCode -and [int]$_.ConfigManagerErrorCode -ne 0 -and [int]$_.ConfigManagerErrorCode -ne 22
        })
    if ($cimBad.Count -eq 0) {
        Add-Item -List $items -Id 'rescue:bad-devices' -Group 'hardware' -Label '设备状态' `
            -Status 'ok' -Value '无异常' -Detail 'Get-PnpDevice 不可用，已用 Win32_PnPEntity 的 ConfigManagerErrorCode 复核' -Fix '' -NeedsAdmin $false
    } else {
        Add-Item -List $items -Id 'rescue:bad-devices' -Group 'hardware' -Label '设备状态' `
            -Status 'warn' -Value "$($cimBad.Count) 个设备异常" `
            -Detail (($cimBad | Select-Object -First 6 | ForEach-Object { "$($_.Name) (代码 $($_.ConfigManagerErrorCode))" }) -join '; ') `
            -Fix '在设备管理器里查看带黄色感叹号的设备并重装驱动' -NeedsAdmin $true
    }
} else {
    $badDevices = @($presentDevices | Where-Object { [string]$_.Status -ne 'OK' })
    $phantom = @($allDevices | Where-Object { [string]$_.Status -ne 'OK' -and [string]$_.Problem -eq 'CM_PROB_PHANTOM' })
    if ($badDevices.Count -eq 0) {
        Add-Item -List $items -Id 'rescue:bad-devices' -Group 'hardware' -Label '设备状态' `
            -Status 'ok' -Value "当前 $($presentDevices.Count) 个设备全部 OK" `
            -Detail ("当前插着的硬件没有异常；另有 $($phantom.Count) 个历史幽灵记录（CM_PROB_PHANTOM，已拔掉的设备），不影响使用") `
            -Fix '' -NeedsAdmin $false
    } else {
        $lines = ($badDevices | Select-Object -First 6 | ForEach-Object {
                $p = [string]$_.Problem
                if (-not $p) { $p = "Status $($_.Status)" }
                "$([string]$_.FriendlyName) [$p]"
            }) -join '; '
        Add-Item -List $items -Id 'rescue:bad-devices' -Group 'hardware' -Label '设备状态' `
            -Status 'warn' -Value "$($badDevices.Count) 个设备异常" `
            -Detail $lines `
            -Fix '在设备管理器里逐个查看问题代码并重装/更新驱动' -NeedsAdmin $true
    }
}

# ---- 8. 最近 24h 系统严重错误 --------------------------------------------
# Level 1=Critical, 2=Error。Get-WinEvent 在无匹配时抛异常，必须翻译成 0 条；
# 真正的读取失败（权限、日志服务停了）才报 skip，两者不能合并。
$eventProbe = Invoke-BoundedScript -TimeoutMs 15000 -Script {
    try {
        $since = (Get-Date).AddHours(-24)
        $evts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -MaxEvents 500 -ErrorAction Stop)
        $top = @($evts | Group-Object -Property ProviderName | Sort-Object -Property Count -Descending | Select-Object -First 5 |
                ForEach-Object { "$($_.Name) x$($_.Count)" })
        'OK|' + $evts.Count + '|' + ($top -join '; ')
    } catch {
        $m = [string]$_.Exception.Message
        if ($m -match '找不到与指定的选择条件匹配|No events were found|没有与指定') { 'EMPTY|0|' }
        else { 'ERR|' + $m }
    }
}
$evKind = 'ERR'
$evCount = -1
$evTop = ''
$evErr = ''
if ($eventProbe.timedOut) {
    $evErr = 'Get-WinEvent 超时（15 秒）'
} elseif ($eventProbe.ok -and $eventProbe.result) {
    $parts = ([string]$eventProbe.result) -split '\|', 3
    $evKind = $parts[0]
    if ($parts.Count -ge 2) { [void][int]::TryParse($parts[1], [ref]$evCount) }
    if ($parts.Count -ge 3) { $evTop = $parts[2] }
    if ($evKind -eq 'ERR' -and $parts.Count -ge 2) { $evErr = $parts[1] }
} elseif ($eventProbe.error) {
    $evErr = $eventProbe.error
}
if ($evKind -eq 'OK' -or $evKind -eq 'EMPTY') {
    if ($evCount -le 0) {
        Add-Item -List $items -Id 'rescue:event-errors' -Group 'events' -Label '系统错误' `
            -Status 'ok' -Value '24 小时 0 条' `
            -Detail 'System 日志 24 小时内没有 Critical/Error 级事件（无匹配事件是正常结果，不是读取失败）' `
            -Fix '' -NeedsAdmin $false
    } else {
        Add-Item -List $items -Id 'rescue:event-errors' -Group 'events' -Label '系统错误' `
            -Status $(if ($evCount -ge 50) { 'bad' } else { 'warn' }) -Value "24 小时 $evCount 条" `
            -Detail $(if ($evTop) { $evTop } else { '集中在单一来源的错误通常指向同一个根因' }) `
            -Fix '在事件查看器里按来源筛选，先解决出现次数最多的那个' -NeedsAdmin $false
    }
} else {
    Add-Item -List $items -Id 'rescue:event-errors' -Group 'events' -Label '系统错误' `
        -Status 'skip' -Value '读不到' -Detail ("未能读取系统事件日志：" + $evErr) -Fix '' -NeedsAdmin $true
}

# ---- 9. 上次成功安装更新 --------------------------------------------------
$hotfixes = @(Get-HotFix -ErrorAction SilentlyContinue | Sort-Object -Property InstalledOn -Descending)
$lastFix = $null
if ($hotfixes.Count -gt 0) { $lastFix = $hotfixes[0] }
if ($null -eq $lastFix -or $null -eq $lastFix.InstalledOn) {
    Add-Item -List $items -Id 'rescue:last-update' -Group 'updates' -Label '最近更新' `
        -Status 'skip' -Value '读不到' -Detail 'Get-HotFix 没有返回带安装日期的补丁' -Fix '' -NeedsAdmin $false
} else {
    $fixDays = [math]::Round(((Get-Date) - $lastFix.InstalledOn).TotalDays, 0)
    Add-Item -List $items -Id 'rescue:last-update' -Group 'updates' -Label '最近更新' `
        -Status $(if ($fixDays -gt 90) { 'warn' } else { 'ok' }) `
        -Value "$($lastFix.HotFixID) · $fixDays 天前" `
        -Detail ("安装日期 " + $lastFix.InstalledOn.ToString('yyyy-MM-dd') + "，共 $($hotfixes.Count) 个补丁记录") `
        -Fix $(if ($fixDays -gt 90) { '检查 Windows Update 是否卡住，长期未更新会让累积更新变得很大' } else { '' }) -NeedsAdmin $false
}

# ---- 10. Defender 特征库年龄 ---------------------------------------------
$mpStatus = $null
$mpProbe = Invoke-BoundedScript -TimeoutMs 12000 -Script {
    try { $mp = Get-MpComputerStatus -ErrorAction Stop; 'OK|' + [string]$mp.AntivirusSignatureLastUpdated + '|' + [string]$mp.AntivirusSignatureVersion + '|' + [string]$mp.RealTimeProtectionEnabled }
    catch { 'ERR|' + [string]$_.Exception.Message }
}
if ($mpProbe.ok -and $mpProbe.result) { $mpStatus = [string]$mpProbe.result }
$sigDays = -1
$sigDate = $null
$sigVersion = ''
$rtpOn = $null
if ($mpStatus) {
    $mpParts = $mpStatus -split '\|', 4
    if ($mpParts[0] -eq 'OK' -and $mpParts.Count -ge 2) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($mpParts[1], [ref]$parsed)) {
            $sigDate = $parsed
            $sigDays = [math]::Round(((Get-Date) - $parsed).TotalDays, 1)
        }
        if ($mpParts.Count -ge 3) { $sigVersion = $mpParts[2] }
        if ($mpParts.Count -ge 4) { $rtpOn = ($mpParts[3] -eq 'True') }
    }
}
if ($sigDays -lt 0) {
    Add-Item -List $items -Id 'rescue:defender-sig' -Group 'protection' -Label '病毒特征库' `
        -Status 'skip' -Value '读不到' `
        -Detail 'Get-MpComputerStatus 未返回特征库时间（可能被第三方安全软件接管）' -Fix '' -NeedsAdmin $false
} else {
    Add-Item -List $items -Id 'rescue:defender-sig' -Group 'protection' -Label '病毒特征库' `
        -Status $(if ($sigDays -gt 7) { 'warn' } else { 'ok' }) `
        -Value "$sigDays 天前（$($sigDate.ToString('yyyy-MM-dd HH:mm'))）" `
        -Detail ("特征库版本 $sigVersion，实时保护 " + $(if ($rtpOn -eq $false) { '已关闭' } else { '开启' })) `
        -Fix $(if ($sigDays -gt 7) { '在 Windows 安全中心手动检查更新' } else { '' }) -NeedsAdmin $false
}

# ---- 11. 磁盘健康 --------------------------------------------------------
$disks = @()
try { $disks = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $disks = @() }
if ($disks.Count -eq 0) {
    try {
        $disks = @(Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' -ClassName MSFT_PhysicalDisk -ErrorAction Stop |
                ForEach-Object { [pscustomobject]@{ FriendlyName = $_.FriendlyName; HealthStatus = $_.HealthStatus; MediaType = $_.MediaType } })
    } catch { $disks = @() }
}
if ($disks.Count -eq 0) {
    Add-Item -List $items -Id 'rescue:disk-health' -Group 'hardware' -Label '磁盘健康' `
        -Status 'skip' -Value '读不到' -Detail 'Get-PhysicalDisk 与 MSFT_PhysicalDisk 都没有返回结果' -Fix '' -NeedsAdmin $false
} else {
    $unhealthy = @($disks | Where-Object { [string]$_.HealthStatus -ne 'Healthy' })
    $diskLines = ($disks | ForEach-Object { "$($_.FriendlyName)=$($_.HealthStatus)" }) -join '；'
    Add-Item -List $items -Id 'rescue:disk-health' -Group 'hardware' -Label '磁盘健康' `
        -Status $(if ($unhealthy.Count -gt 0) { 'bad' } else { 'ok' }) `
        -Value $(if ($unhealthy.Count -gt 0) { "$($unhealthy.Count)/$($disks.Count) 块异常" } else { "$($disks.Count) 块 · 均 Healthy" }) `
        -Detail $diskLines `
        -Fix $(if ($unhealthy.Count -gt 0) { '立刻备份重要数据，用厂商工具（如 Samsung Magician / CrystalDiskInfo）看 SMART 详情' } else { '' }) -NeedsAdmin $false
}

# ---- 12. 启动项指向的缺失文件 --------------------------------------------
# 只读 Run/RunOnce，不写。Test-Path 对文件系统很便宜（实测 1.6 ms），可以逐项验证。
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
)
$startupTotal = 0
$startupMissing = New-Object System.Collections.Generic.List[string]
$startupUnverified = New-Object System.Collections.Generic.List[string]
foreach ($rk in $runKeys) {
    $key = Get-Item -LiteralPath $rk -ErrorAction SilentlyContinue
    if ($null -eq $key) { continue }
    foreach ($vn in @($key.GetValueNames())) {
        if (-not $vn) { continue }
        $startupTotal++
        $raw = [string]$key.GetValue($vn)
        if (-not $raw) { continue }
        $cmd = [Environment]::ExpandEnvironmentVariables($raw.Trim())
        # 命令行里可能带参数、带引号，也可能不带引号但路径含空格。按三种形态取
        # 可执行文件路径：先引号，再"到第一个 .exe/.dll/.bat/.cmd 为止"，最后取首段。
        if ($cmd -match '^\s*"([^"]+)"') {
            $cmd = $Matches[1]
        } elseif ($cmd -match '^\s*([A-Za-z]:\\[^"]*?\.(?:exe|dll|bat|cmd|com|scr|ps1))') {
            $cmd = $Matches[1]
        } else {
            $cmd = ($cmd -split '\s+')[0]
        }
        if (-not $cmd) { continue }

        if ($cmd -match '\\' -or $cmd -match '^[A-Za-z]:') {
            # 绝对/相对路径：直接验证文件在不在。
            if (-not (Test-Path -LiteralPath $cmd)) { $startupMissing.Add("$vn → $cmd") }
        } else {
            # 裸命令名（如 rundll32.exe）：不能拿当前目录去 Test-Path，否则必然
            # 判成缺失。这里按 PATH/PATHEXT 解析，再查 App Paths 注册表。
            $app = $null
            try { $app = Get-Command -Name $cmd -CommandType Application -ErrorAction Stop | Select-Object -First 1 } catch { $app = $null }
            if ($app) { continue }
            $appPathKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$cmd"
            $appKeyItem = Get-Item -LiteralPath $appPathKey -ErrorAction SilentlyContinue
            if ($appKeyItem) { continue }
            $startupUnverified.Add("$vn → $cmd（非绝对路径，PATH 与 App Paths 均未找到）")
        }
    }
}
$unverifiedNote = ''
if ($startupUnverified.Count -gt 0) {
    $unverifiedNote = '；另有 ' + $startupUnverified.Count + ' 项无法验证：' + (($startupUnverified | Select-Object -First 3) -join '，')
}
if ($startupTotal -eq 0) {
    Add-Item -List $items -Id 'rescue:startup-missing' -Group 'startup' -Label '启动项' `
        -Status 'info' -Value '0 项' -Detail 'HKLM/HKCU 的 Run/RunOnce 都没有条目' -Fix '' -NeedsAdmin $false
} elseif ($startupMissing.Count -eq 0) {
    Add-Item -List $items -Id 'rescue:startup-missing' -Group 'startup' -Label '启动项' `
        -Status $(if ($startupUnverified.Count -gt 0) { 'info' } else { 'ok' }) `
        -Value "$startupTotal 项 · 0 项缺失" `
        -Detail ('每个自启动项指向的可执行文件都真实存在' + $unverifiedNote) -Fix '' -NeedsAdmin $false
} else {
    Add-Item -List $items -Id 'rescue:startup-missing' -Group 'startup' -Label '启动项' `
        -Status 'warn' -Value "$startupTotal 项 · $($startupMissing.Count) 项缺失" `
        -Detail ((($startupMissing | Select-Object -First 5) -join '; ') + $unverifiedNote) `
        -Fix '在任务管理器的「启动」页禁用这些残留项（删注册表值需谨慎，先导出备份）' -NeedsAdmin $true
}

# ---- 汇总 ------------------------------------------------------------------
$elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
Write-ProbeResult -Items $items -Extra @{
    elapsedMs       = $elapsedMs
    elevated        = $isElevated
    pendingReboot   = [ordered]@{
        cbs                = $cbsPending
        windowsUpdate      = $wuPending
        pendingFileRename  = $pfroPending
        pendingFileRenameOps = $pfroOps
    }
    cbsPackages     = $pkgCount
    restorePoints    = $rpCount
    eventErrors24h  = $evCount
    lastHotfix      = $(if ($lastFix) { [ordered]@{ id = $lastFix.HotFixID; installedOn = $(if ($lastFix.InstalledOn) { $lastFix.InstalledOn.ToString('yyyy-MM-dd') } else { '' }) } } else { $null })
    defender        = [ordered]@{ signatureAgeDays = $(if ($sigDays -ge 0) { $sigDays } else { $null }); signatureVersion = $sigVersion }
    physicalDisks   = @($disks | ForEach-Object { [ordered]@{ name = [string]$_.FriendlyName; health = [string]$_.HealthStatus } })
    startupItems    = $startupTotal
    missingStartup  = @($startupMissing.ToArray())
    unverifiedStartup = @($startupUnverified.ToArray())
} -Note '全部只读：不运行 sfc /scannow、不运行 DISM /RestoreHealth、不创建还原点。需要管理员的项在未提权时返回 skip 并附上原始报错。'
