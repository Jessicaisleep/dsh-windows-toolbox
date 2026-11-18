param([string]$ParamFile)
# slim.ps1 - 只读分析：统计 C 盘可回收空间分布。绝不删除、移动或修改任何文件/配置。
# 目录大小一律用流式 BFS（DirectoryInfo + 显式栈 + 硬截止），Get-ChildItem -Recurse 在本机不流式、会卡死。
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items  = New-ProbeList

$clock       = [System.Diagnostics.Stopwatch]::StartNew()
$TotalBudget = 55000   # 总预算 55s，留 5s 给收尾（上限要求 60s）

function Get-Budget {
    $left = $TotalBudget - $clock.ElapsedMilliseconds
    if ($left -lt 0) { return 0 }
    return [int]$left
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1073741824) { return ([string]::Format('{0:F2} GB', $Bytes / 1073741824)) }
    if ($Bytes -ge 1048576) { return ([string]::Format('{0:F1} MB', $Bytes / 1048576)) }
    if ($Bytes -ge 1024) { return ([string]::Format('{0:F1} KB', $Bytes / 1024)) }
    return "$Bytes B"
}

function Format-MB {
    param([int64]$Bytes)
    return ([string]::Format('{0:F1} MB', $Bytes / 1048576))
}

# 按大小分级：>=2GB bad，>=500MB warn，其余 ok。
function Get-SizeStatus {
    param([int64]$Bytes, [string]$SmallStatus = 'ok')
    if ($Bytes -ge 2147483648) { return 'bad' }
    if ($Bytes -ge 524288000) { return 'warn' }
    return $SmallStatus
}

# ---------------------------------------------------------------------------
# Get-DirBytes：流式递归统计目录大小
#   用 System.IO.DirectoryInfo 的 EnumerateFiles/EnumerateDirectories + 显式栈，
#   每处理一个目录前检查 Stopwatch；超时即停并置 truncated=true（不谎报完整值）。
#   无权限目录计入 denied。绝不使用 Get-ChildItem -Recurse：本机实测它在 WinSxS 上
#   取前 50 个文件就要 15.5s（整棵树先枚举完才吐第一项），无法做真实超时。
# ---------------------------------------------------------------------------
function Get-DirBytes {
    param(
        [string]$Path,
        [int]$MaxMs = 8000
    )
    $res = [pscustomobject]@{
        path = $Path; exists = $false; bytes = [int64]0; files = [int64]0
        dirs = [int64]0; denied = [int64]0; truncated = $false
        elapsedMs = 0; error = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { $res.error = '路径为空'; return $res }
    if (-not [System.IO.Directory]::Exists($Path)) { $res.error = '目录不存在'; return $res }
    $res.exists = $true

    $sw    = [System.Diagnostics.Stopwatch]::StartNew()
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        if ($sw.ElapsedMilliseconds -gt $MaxMs) { $res.truncated = $true; break }
        $cur = [string]$stack.Pop()
        $res.dirs++
        $di = $null
        try {
            $di = New-Object System.IO.DirectoryInfo -ArgumentList $cur
            foreach ($f in $di.EnumerateFiles()) {
                try { $res.bytes += [int64]$f.Length; $res.files++ } catch { $res.denied++ }
            }
            foreach ($d in $di.EnumerateDirectories()) {
                $stack.Push($d.FullName)
            }
        }
        catch {
            # 整个目录不可读（ACL/系统目录），记一次并跳过
            $res.denied++
        }
        $di = $null
    }
    $sw.Stop()
    $res.elapsedMs = [int]$sw.ElapsedMilliseconds
    return $res
}

# 单文件大小（不递归），用于 pagefile/hiberfil 这类顶层大文件
function Get-FileBytes {
    param([string]$Path)
    $out = [pscustomobject]@{ path = $Path; exists = $false; bytes = [int64]0; error = '' }
    try {
        $fi = New-Object System.IO.FileInfo -ArgumentList $Path
        if ($fi.Exists) { $out.exists = $true; $out.bytes = [int64]$fi.Length }
    }
    catch { $out.error = $_.Exception.Message }
    return $out
}

$elevated = Test-Elevated
$safeItems = New-Object System.Collections.ArrayList   # 可安全回收项：@{label; bytes; needsAdmin}

# ---------------------------------------------------------------------------
# 0) C 盘容量上下文（给其他项的占比做参照）
# ---------------------------------------------------------------------------
$cFree = [int64]0; $cTotal = [int64]0
try {
    $dv = New-Object System.IO.DriveInfo -ArgumentList 'C'
    $cFree  = [int64]$dv.TotalFreeSpace
    $cTotal = [int64]$dv.TotalSize
}
catch { }
if ($cTotal -gt 0) {
    Add-Item -List $items -Id 'slim:disk' -Group '磁盘' -Label 'C 盘容量 / 可用' `
        -Status 'info' -Value ("可用 $(Format-Bytes $cFree) / 总 $(Format-Bytes $cTotal)") `
        -Detail ("已用 $(Format-Bytes ($cTotal - $cFree))，可用率 " +
            ([string]::Format('{0:F1}%', ($cFree * 100.0 / $cTotal))) +
            "。以下各项的回收价值以该可用量为参照。") `
        -Fix '' -NeedsAdmin $false
}

# ---------------------------------------------------------------------------
# 1) hiberfil.sys
# ---------------------------------------------------------------------------
$hib = Get-FileBytes 'C:\hiberfil.sys'
$hibReg = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
if ($hib.exists) {
    Add-Item -List $items -Id 'slim:hiberfil' -Group '休眠' -Label 'hiberfil.sys（休眠镜像）' `
        -Status (Get-SizeStatus $hib.bytes) -Value (Format-Bytes $hib.bytes) `
        -Detail ("实测 $($hib.bytes) bytes（$(Format-Bytes $hib.bytes)）；HibernateEnabled=$hibReg。" +
            "关闭休眠后该文件可释放，代价是失去休眠与「快速启动」。") `
        -Fix ('管理员执行 powercfg /h off 关闭休眠（等价于把 HibernateEnabled 置 0），文件随即可释放；' +
            '只想减小体积可用 powercfg /h /size 50（按物理内存百分比，需管理员）。') -NeedsAdmin $true
    [void]$safeItems.Add(@{ label = 'hiberfil.sys'; bytes = $hib.bytes; needsAdmin = $true })
}
else {
    Add-Item -List $items -Id 'slim:hiberfil' -Group '休眠' -Label 'hiberfil.sys（休眠镜像）' `
        -Status 'info' -Value '不存在（0 B）' `
        -Detail ("C:\hiberfil.sys 不存在；HibernateEnabled=$hibReg → 休眠已关闭，该项无可回收空间。" +
            $(if ($hib.error) { " 读取异常: $($hib.error)" } else { '' })) `
        -Fix '无需处理。若要恢复休眠需管理员执行 powercfg /h on，会重新占用数 GB。' -NeedsAdmin $false
}

# ---------------------------------------------------------------------------
# 2) pagefile.sys
# ---------------------------------------------------------------------------
$pf     = Get-FileBytes 'C:\pagefile.sys'
$pfMgr  = $null
$pfAuto = $null
try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem; $pfAuto = $cs.AutomaticManagedPagefile } catch { }
$pfSetting = '未知'
try {
    $pfs = Get-CimInstance -ClassName Win32_PageFileSetting
    if ($pfs) { $pfSetting = (@($pfs | ForEach-Object { "$($_.Name) $($_.InitialSize)/$($_.MaximumSize) MB" }) -join '；') }
    else { $pfSetting = '无自定义项' }
} catch { }
$pfReg = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'PagingFiles'
$pfUseTxt = ''
try {
    $pfu = Get-CimInstance -ClassName Win32_PageFileUsage
    if ($pfu) { $pfUseTxt = (@($pfu | ForEach-Object { "已分配 $($_.AllocatedBaseSize) MB / 当前用 $($_.CurrentUsage) MB / 峰值 $($_.PeakUsage) MB" }) -join '；') }
} catch { }

if ($pf.exists) {
    $pfDetail = "实测 $($pf.bytes) bytes（$(Format-Bytes $pf.bytes)）。" +
        "AutomaticManagedPagefile=$pfAuto（False=用户自定义大小，系统不会自己缩）；" +
        "Win32_PageFileSetting: $pfSetting；注册表 PagingFiles: $pfReg"
    if ($pfUseTxt) { $pfDetail += "；$pfUseTxt" }
    $pfDetail += "。该文件占用大但属于系统必需：不能直接删除，只能「缩小」或「迁到其它盘」。"
    Add-Item -List $items -Id 'slim:pagefile' -Group '虚拟内存' -Label 'pagefile.sys（分页文件）' `
        -Status (Get-SizeStatus $pf.bytes) -Value (Format-Bytes $pf.bytes) `
        -Detail $pfDetail `
        -Fix ('迁到其它盘（推荐 D 盘）：系统属性→高级→性能设置→高级→更改虚拟内存→取消「自动管理」→' +
            '选中 C: 设为「无分页文件」→ 选中 D: 设为「自定义大小」（如初始/最大各 8192-16384 MB，按物理内存 1-1.5 倍）→ 设置→确定→重启生效。' +
            '或命令行：wmic pagefileset where name="C:\\pagefile.sys" set InitialSize=8192,MaximumSize=8192（需管理员，改完重启）。' +
            '注意：完全关掉分页文件会让内存不足时程序直接崩溃，不建议；C 盘保留 1-2 GB 小块更稳。') -NeedsAdmin $true
}
else {
    Add-Item -List $items -Id 'slim:pagefile' -Group '虚拟内存' -Label 'pagefile.sys（分页文件）' `
        -Status 'info' -Value '不存在（0 B）' `
        -Detail "C:\pagefile.sys 不存在或不可读$(if ($pf.error) { ": $($pf.error)" } else { '' })。" `
        -Fix '' -NeedsAdmin $false
}

# ---------------------------------------------------------------------------
# 3) 系统还原（Win32_ShadowStorage / 还原点数量）
# ---------------------------------------------------------------------------
$ssBytes = [int64]0; $ssMax = [int64]0; $ssOk = $false; $ssErr = ''
try {
    $ss = Get-CimInstance -ClassName Win32_ShadowStorage -ErrorAction Stop
    foreach ($s in $ss) {
        $ssBytes += [int64]$s.UsedSpace
        $ssMax   += [int64]$s.MaxSpace
    }
    $ssOk = $true
}
catch { $ssErr = $_.Exception.Message }

$rpCount = -1; $rpErr = ''
try {
    $rps = Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop
    $rpCount = @($rps).Count
}
catch { $rpErr = $_.Exception.Message }

$srPct = ''
try {
    $src = Get-CimInstance -Namespace 'root/default' -ClassName SystemRestoreConfig -ErrorAction Stop
    if ($src) { $srPct = "DiskPercent=$($src.DiskPercent)" }
}
catch { }

if ($ssOk) {
    Add-Item -List $items -Id 'slim:restore' -Group '系统还原' -Label '系统还原占用' `
        -Status (Get-SizeStatus $ssBytes) -Value ("$(Format-Bytes $ssBytes) 已用 / $(Format-Bytes $ssMax) 上限") `
        -Detail ("UsedSpace=$ssBytes bytes（$(Format-Bytes $ssBytes)）；MaxSpace=$ssMax bytes（$(Format-Bytes $ssMax)）；" +
            "还原点数量=$rpCount；$srPct") `
        -Fix ('减小还原点上限：系统属性→系统保护→选中 C:→配置→把「最大使用量」滑块调小（会立即丢弃旧还原点）；' +
            '完全关闭：同一界面选「禁用系统保护」（需管理员）。注意关掉后无法用系统还原回滚驱动/更新故障。') -NeedsAdmin $true
}
else {
    $rpTxt = $(if ($rpCount -ge 0) { "还原点数量=$rpCount（Win32_ShadowCopy）" } else { "还原点数量=不可枚举" })
    Add-Item -List $items -Id 'slim:restore' -Group '系统还原' -Label '系统还原占用' `
        -Status 'skip' -Value '未测量（需管理员）' `
        -Detail ("本机 Win32_ShadowStorage 与 Win32_ShadowCopy 均无法初始化，读不到 UsedSpace/MaxSpace：" +
            "$ssErr（ShadowCopy: $rpErr）；$rpTxt；$srPct。" +
            "vssadmin list shadowstorage 同样提示需要提升的管理员权限。按用户核对的实际状态为「0 个还原点」，" +
            "若确实为零则该项可回收 0 GB。") `
        -Fix '以管理员身份运行 vssadmin list shadowstorage 查看实际占用；回收用 vssadmin delete shadows /for=C: /all /quiet（会删掉所有还原点，不可恢复）。' -NeedsAdmin $true
}

# ---------------------------------------------------------------------------
# 4) Windows.old / 升级残留
# ---------------------------------------------------------------------------
$wo = Get-DirBytes 'C:\Windows.old' -MaxMs 6000
if ($wo.exists -and $wo.bytes -gt 0) {
    Add-Item -List $items -Id 'slim:windowsold' -Group '升级残留' -Label 'Windows.old' `
        -Status (Get-SizeStatus $wo.bytes) -Value (Format-Bytes $wo.bytes) `
        -Detail ("$($wo.files) 文件 / $($wo.dirs) 目录 / $(Format-Bytes $wo.bytes)（耗时 $($wo.elapsedMs) ms）" +
            $(if ($wo.truncated) { '；已达单项时限，数值偏小（truncated）' } else { '' }) +
            $(if ($wo.denied -gt 0) { "；跳过 $($wo.denied) 个无权限项" } else { '' })) `
        -Fix '设置→系统→存储→清理建议→勾选「以前的 Windows 安装」删除；或管理员执行 cleanmgr /sageset:1 后 cleanmgr /sagerun:1。删除后无法回滚到旧版本。' -NeedsAdmin $true
    [void]$safeItems.Add(@{ label = 'Windows.old'; bytes = $wo.bytes; needsAdmin = $true })
}
else {
    $extraTxt = ''
    foreach ($p in @('C:\$Windows.~BT', 'C:\$Windows.~WS')) {
        $t = Get-DirBytes $p -MaxMs 2000
        if ($t.exists) { $extraTxt += "；$p 存在 $($t.files) 文件 $(Format-Bytes $t.bytes)" }
    }
    Add-Item -List $items -Id 'slim:windowsold' -Group '升级残留' -Label 'Windows.old' `
        -Status 'info' -Value '不存在（0 B）' `
        -Detail ("C:\Windows.old 不存在，无升级残留可回收$(if ($wo.error) { "（$($wo.error)）" } else { '' })$extraTxt。") `
        -Fix '无需处理。' -NeedsAdmin $false
    # $Windows.~BT / ~WS 若存在且大于 100MB 仍算安全可删的升级缓存
    foreach ($p in @('C:\$Windows.~BT', 'C:\$Windows.~WS')) {
        $t = Get-DirBytes $p -MaxMs 2000
        if ($t.exists -and $t.bytes -ge 104857600) {
            [void]$safeItems.Add(@{ label = $p; bytes = $t.bytes; needsAdmin = $true })
        }
    }
}

# ---------------------------------------------------------------------------
# 5) WinSxS（不递归！）
# ---------------------------------------------------------------------------
Add-Item -List $items -Id 'slim:winsxs' -Group '组件存储' -Label 'WinSxS（组件存储）' `
    -Status 'skip' -Value '未测量（需管理员）' `
    -Detail ('按要求不递归统计 C:\Windows\WinSxS：本机实测 Get-ChildItem -Recurse 在该目录取前 50 个文件就要 15.5s，' +
        '全量 88982 文件 / 11.5 GB 耗时 15.2s，会让整个探针超时；且表观大小本身不可信（大量硬链接会重复计入）。' +
        '真实可回收量必须用 DISM /Online /Cleanup-Image /AnalyzeComponentStore，该命令需要管理员权限。') `
    -Fix '管理员执行：DISM /Online /Cleanup-Image /AnalyzeComponentStore 查看「可回收的组件存储」；确认后执行 DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase（ResetBase 后不能再卸载已安装更新）。' -NeedsAdmin $true

# ---------------------------------------------------------------------------
# 6) 传递优化缓存
# ---------------------------------------------------------------------------
$doDir   = 'C:\Windows\SoftwareDistribution\DeliveryOptimization'
$doBytes = [int64]0; $doSrc = ''; $doNote = ''
$doScan  = Get-DirBytes $doDir -MaxMs 3000
if ($doScan.exists) {
    $doBytes = $doScan.bytes; $doSrc = '目录枚举'
    $doNote  = "$doDir：$($doScan.files) 文件 / $(Format-Bytes $doScan.bytes)（耗时 $($doScan.elapsedMs) ms）"
}
else {
    $perf = $null
    try { $perf = Get-DeliveryOptimizationPerfSnap -ErrorAction Stop } catch { }
    if ($perf) {
        $doBytes = [int64]$perf.CacheSizeBytes; $doSrc = 'Get-DeliveryOptimizationPerfSnap'
        $doNote  = ("$doDir 目录不存在；改用 Get-DeliveryOptimizationPerfSnap：CacheSizeBytes=$($perf.CacheSizeBytes)、" +
            "DownloadMode=$($perf.DownloadMode)、累计下载 $($perf.TotalBytesDownloaded) bytes / $($perf.FilesDownloaded) 文件")
    }
    else {
        $doNote = "$doDir 目录不存在，且 Get-DeliveryOptimizationPerfSnap 不可用"
    }
}
if ($doSrc) {
    Add-Item -List $items -Id 'slim:deliveryoptimization' -Group '缓存' -Label '传递优化缓存' `
        -Status (Get-SizeStatus $doBytes 'info') -Value (Format-Bytes $doBytes) `
        -Detail "$doNote（数据来源：$doSrc）" `
        -Fix '设置→Windows 更新→高级选项→传递优化→删除以前下载的更新文件；或管理员执行 Delete-DeliveryOptimizationCache -Force。' -NeedsAdmin $true
    if ($doBytes -gt 0) { [void]$safeItems.Add(@{ label = '传递优化缓存'; bytes = $doBytes; needsAdmin = $true }) }
}
else {
    Add-Item -List $items -Id 'slim:deliveryoptimization' -Group '缓存' -Label '传递优化缓存' `
        -Status 'skip' -Value '未测量' -Detail $doNote -Fix '' -NeedsAdmin $false
}

# ---------------------------------------------------------------------------
# 7) Windows 更新缓存（SoftwareDistribution\Download）
# ---------------------------------------------------------------------------
$wuDir = 'C:\Windows\SoftwareDistribution\Download'
$wu    = Get-DirBytes $wuDir -MaxMs 6000
if ($wu.exists) {
    Add-Item -List $items -Id 'slim:updatecache' -Group '缓存' -Label 'Windows 更新缓存' `
        -Status (Get-SizeStatus $wu.bytes 'info') -Value (Format-Bytes $wu.bytes) `
        -Detail ("$wuDir：$($wu.files) 文件 / $(Format-Bytes $wu.bytes)（耗时 $($wu.elapsedMs) ms）" +
            $(if ($wu.truncated) { '；已达单项时限，数值偏小（truncated）' } else { '' }) +
            $(if ($wu.denied -gt 0) { "；跳过 $($wu.denied) 个无权限项" } else { '' }) +
            "。安装完成后这里的残余更新包可安全清理。") `
        -Fix ('管理员：先停 wuauserv 与 bits 服务，再清空该目录内容，最后启动服务（不要删 Download 目录本身）：' +
            'Stop-Service wuauserv,bits -Force; Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force; Start-Service wuauserv,bits。') -NeedsAdmin $true
    if ($wu.bytes -gt 0) { [void]$safeItems.Add(@{ label = 'Windows 更新缓存'; bytes = $wu.bytes; needsAdmin = $true }) }
}
else {
    Add-Item -List $items -Id 'slim:updatecache' -Group '缓存' -Label 'Windows 更新缓存' `
        -Status 'skip' -Value '未测量' `
        -Detail "$wuDir 不存在或不可读$(if ($wu.error) { "（$($wu.error)）" } else { '' })" -Fix '' -NeedsAdmin $false
}

# ---------------------------------------------------------------------------
# 8) 系统临时目录 C:\Windows\Temp
# ---------------------------------------------------------------------------
$wt = Get-DirBytes 'C:\Windows\Temp' -MaxMs 6000
if ($wt.exists) {
    $wtDetail = "$($wt.files) 文件 / $(Format-Bytes $wt.bytes)（耗时 $($wt.elapsedMs) ms）" +
        $(if ($wt.truncated) { '；已达单项时限（truncated）' } else { '' })
    if ($wt.denied -gt 0) { $wtDetail += "；有 $($wt.denied) 个条目因权限不足被跳过，实际占用略大于实测值" }
    $wtStatus = 'ok'
    if (-not $elevated) { $wtStatus = 'info' }
    if ($wt.bytes -ge 2147483648) { $wtStatus = 'warn' }
    Add-Item -List $items -Id 'slim:systemp' -Group '临时文件' -Label 'C:\Windows\Temp' `
        -Status $wtStatus -Value (Format-Bytes $wt.bytes) -Detail $wtDetail `
        -Fix '管理员：Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue（正在被占用的文件会自动跳过，属正常）。' -NeedsAdmin $true
    if (-not $elevated) {
        # 非管理员读不全，但仍把测到的部分算进安全项，并在汇总里标注
        if ($wt.bytes -gt 0) { [void]$safeItems.Add(@{ label = 'Windows\Temp（可能偏小）'; bytes = $wt.bytes; needsAdmin = $true }) }
    }
    elseif ($wt.bytes -gt 0) { [void]$safeItems.Add(@{ label = 'Windows\Temp'; bytes = $wt.bytes; needsAdmin = $true }) }
}
else {
    Add-Item -List $items -Id 'slim:systemp' -Group '临时文件' -Label 'C:\Windows\Temp' `
        -Status 'skip' -Value '未测量' `
        -Detail "无法读取 C:\Windows\Temp$(if ($wt.error) { "（$($wt.error)）" } else { '' })" -Fix '' -NeedsAdmin $true
}

# ---------------------------------------------------------------------------
# 9) 用户临时目录 %TEMP%
# ---------------------------------------------------------------------------
$userTemp = [System.Environment]::ExpandEnvironmentVariables('%TEMP%')
$ut       = Get-DirBytes $userTemp -MaxMs 8000
if ($ut.exists) {
    $utDetail = "$userTemp：$($ut.files) 文件 / $(Format-Bytes $ut.bytes)（耗时 $($ut.elapsedMs) ms）" +
        $(if ($ut.truncated) { '；已达单项时限（truncated）' } else { '' }) +
        $(if ($ut.denied -gt 0) { "；跳过 $($ut.denied) 个无权限项" } else { '' })
    Add-Item -List $items -Id 'slim:usertemp' -Group '临时文件' -Label '用户临时目录 %TEMP%' `
        -Status (Get-SizeStatus $ut.bytes) -Value (Format-Bytes $ut.bytes) -Detail $utDetail `
        -Fix ('关闭占用该目录的程序后：Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue；' +
            '或设置→系统→存储→临时文件→勾选「临时文件」。不需要管理员。') -NeedsAdmin $false
    if ($ut.bytes -gt 0) { [void]$safeItems.Add(@{ label = '%TEMP%'; bytes = $ut.bytes; needsAdmin = $false }) }
}
else {
    Add-Item -List $items -Id 'slim:usertemp' -Group '临时文件' -Label '用户临时目录 %TEMP%' `
        -Status 'skip' -Value '未测量' `
        -Detail "%TEMP% 解析为「$userTemp」，无法读取$(if ($ut.error) { "（$($ut.error)）" } else { '' })" -Fix '' -NeedsAdmin $false
}

# ---------------------------------------------------------------------------
# 10) 各用户 Profile 下 AppData\Local 的 Top 10 大户
#    只做一级子目录；每个子目录独立计数（深层内容会被父目录和子目录重复计入，
#    因此下面的总和不等于 AppData\Local 实际占用，只用于找「谁最大」）。
# ---------------------------------------------------------------------------
$appRoots = New-Object System.Collections.ArrayList
foreach ($u in @($env:USERPROFILE)) {
    if ($u -and (Test-Path -LiteralPath (Join-Path $u 'AppData\Local'))) {
        [void]$appRoots.Add((Join-Path $u 'AppData\Local'))
    }
}
try {
    foreach ($up in (Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
        $al = Join-Path $up.FullName 'AppData\Local'
        if ((Test-Path -LiteralPath $al) -and ($appRoots -notcontains $al)) { [void]$appRoots.Add($al) }
    }
}
catch { }

$rows       = New-Object System.Collections.ArrayList
$skipped    = 0
$scanTrunc  = $false
$totalScans = 0
foreach ($root in $appRoots) {
    $budgetForRoot = [int][math]::Min(12000, [math]::Max(2000, (Get-Budget) - 3000))
    if ($budgetForRoot -lt 800) { $scanTrunc = $true; break }
    $rootSw = [System.Diagnostics.Stopwatch]::StartNew()
    $subs = @()
    try { $subs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) } catch { }
    foreach ($sub in $subs) {
        if ($rootSw.ElapsedMilliseconds -gt $budgetForRoot) { $scanTrunc = $true; break }
        if ((Get-Budget) -lt 700) { $scanTrunc = $true; break }
        $left    = $budgetForRoot - [int]$rootSw.ElapsedMilliseconds
        $perDir  = [int][math]::Min(2500, [math]::Max(300, $left))
        $d       = Get-DirBytes $sub.FullName -MaxMs $perDir
        $totalScans++
        if ($d.truncated) { $scanTrunc = $true }
        $skipped += [int]$d.denied
        if ($d.bytes -gt 0) {
            [void]$rows.Add([pscustomobject]@{
                name      = $sub.Name
                parent    = $root
                bytes     = [int64]$d.bytes
                files     = [int64]$d.files
                truncated = $d.truncated
                denied    = [int64]$d.denied
                ms        = $d.elapsedMs
            })
        }
    }
}

# 注意：不能写 Sort-Object -Property bytes —— OrderedDictionary/pscustomobject 上会静默不排序
$top10 = @($rows | Sort-Object -Property { [int64]$_.bytes } -Descending | Select-Object -First 10)
$sumBytes = [int64]0
foreach ($r in $top10) { $sumBytes += [int64]$r.bytes }

if ($top10.Count -gt 0) {
    $lines = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($r in $top10) {
        $i++
        [void]$lines.Add(("{0,2}. {1,-34} {2,10}  {3,7} 文件{4}{5}" -f $i, $r.name, (Format-Bytes $r.bytes), $r.files,
                    $(if ($r.truncated) { '  [未数完]' } else { '' }),
                    $(if ($r.denied -gt 0) { "  [跳过 $($r.denied) 项]" } else { '' })))
    }
    $noteLines = @(
        '',
        '注：每个子目录独立递归计数，父目录与子目录的深内容会互相重复计入（如 Temp 同时出现在 %TEMP% 项里），',
        '因此本表合计不等于 AppData\Local 真实占用，只用于判断「哪个程序最占地方」。',
        ("本次共扫描 $totalScans 个子目录，其中被跳过（无权限）条目累计 $skipped 个" +
            $(if ($scanTrunc) { '；存在未数完的目录（truncated）' } else { '' }) + '。')
    )
    Add-Item -List $items -Id 'slim:appdatalocal' -Group '用户数据' -Label 'AppData\Local Top 10 大户' `
        -Status 'info' -Value ("Top10 合计 $(Format-Bytes $sumBytes)") `
        -Detail ((($lines + $noteLines) -join "`n")) `
        -Fix ('按程序卸载/清理：缓存类目录（npm-cache、pnpm-cache、updater 下载包）可直接清；' +
            '应用数据目录（JianyingPro、Unity、Microsoft）请用各自程序的清理入口，不要手删，避免丢工程/登录态。') -NeedsAdmin $false
}
else {
    Add-Item -List $items -Id 'slim:appdatalocal' -Group '用户数据' -Label 'AppData\Local Top 10 大户' `
        -Status 'skip' -Value '未测量' -Detail '未枚举到任何非空的一级子目录（或预算耗尽）' -Fix '' -NeedsAdmin $false
}

# ---------------------------------------------------------------------------
# 11) 回收站
#   回收站里每个被删项是成对的：$R<id> 真实数据 + $I<id> 索引元信息。
#   只能统计 $R*，否则同一份数据会被计两遍（本机实测会正好翻倍）。
#   用自带栈遍历、按文件名前缀过滤，不能先 Get-DirBytes 再单独加直接文件（会重复计入）。
# ---------------------------------------------------------------------------
function Get-RecycleBytes {
    param([string]$Root, [int]$MaxMs = 5000)
    $res = [pscustomobject]@{ ok = $false; bytes = [int64]0; files = [int64]0; denied = [int64]0; truncated = $false; elapsedMs = 0 }
    if (-not [System.IO.Directory]::Exists($Root)) { return $res }
    $sw    = [System.Diagnostics.Stopwatch]::StartNew()
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    $res.ok = $true
    while ($stack.Count -gt 0) {
        if ($sw.ElapsedMilliseconds -gt $MaxMs) { $res.truncated = $true; break }
        $cur = [string]$stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo -ArgumentList $cur
            foreach ($f in $di.EnumerateFiles()) {
                try {
                    if ($f.Name -like '$I*') { continue }   # 索引文件，不是数据
                    $res.bytes += [int64]$f.Length
                    $res.files++
                }
                catch { $res.denied++ }
            }
            foreach ($d in $di.EnumerateDirectories()) { $stack.Push($d.FullName) }
        }
        catch { $res.denied++ }
    }
    $sw.Stop()
    $res.elapsedMs = [int]$sw.ElapsedMilliseconds
    return $res
}

$rbBytes = [int64]0; $rbFiles = [int64]0; $rbFound = $false; $rbDenied = 0; $rbTrunc = $false
foreach ($rb in @("C:\`$Recycle.Bin", "C:\`$Recycle.bin")) {
    if (-not [System.IO.Directory]::Exists($rb)) { continue }
    $rbFound = $true
    $rr = Get-RecycleBytes -Root $rb -MaxMs 5000
    $rbBytes  += [int64]$rr.bytes
    $rbFiles  += [int64]$rr.files
    $rbDenied += [int64]$rr.denied
    if ($rr.truncated) { $rbTrunc = $true }
    break
}
if ($rbFound) {
    Add-Item -List $items -Id 'slim:recyclebin' -Group '回收站' -Label '回收站' `
        -Status (Get-SizeStatus $rbBytes 'ok') -Value (Format-Bytes $rbBytes) `
        -Detail ("$rbFiles 个实体文件 / $(Format-Bytes $rbBytes)（只统计 `$R* 数据文件，已排除 `$I* 索引文件）" +
            $(if ($rbTrunc) { '；已达单项时限（truncated）' } else { '' }) +
            $(if ($rbDenied -gt 0) { "；跳过 $($rbDenied) 个无权限项" } else { '' })) `
        -Fix '清空回收站：Clear-RecycleBin -Force -ErrorAction SilentlyContinue（或用资源管理器右键「清空回收站」）。删除后不可恢复。' -NeedsAdmin $false
    if ($rbBytes -gt 0) { [void]$safeItems.Add(@{ label = '回收站'; bytes = $rbBytes; needsAdmin = $false }) }
}
else {
    Add-Item -List $items -Id 'slim:recyclebin' -Group '回收站' -Label '回收站' `
        -Status 'info' -Value '空（0 B）' -Detail '未找到回收站目录或无内容' -Fix '' -NeedsAdmin $false
}

# ---------------------------------------------------------------------------
# 12) 可安全回收合计
# ---------------------------------------------------------------------------
$safeTotal  = [int64]0
$safeNames  = New-Object System.Collections.ArrayList
$needAdmin  = 0
foreach ($s in $safeItems) {
    $safeTotal += [int64]$s.bytes
    [void]$safeNames.Add("$($s.label) $(Format-Bytes $s.bytes)")
    if ($s.needsAdmin) { $needAdmin++ }
}
$safeStatus = $(if ($safeTotal -ge 1073741824) { 'ok' } elseif ($safeTotal -gt 0) { 'info' } else { 'info' })
Add-Item -List $items -Id 'slim:safeTotal' -Group '汇总' -Label '可安全回收合计' `
    -Status $safeStatus -Value (Format-Bytes $safeTotal) `
    -Detail ("合计 $safeTotal bytes（$(Format-Bytes $safeTotal)）。" +
        "包含：" + $(if ($safeNames.Count -gt 0) { $safeNames -join '；' } else { '无（各项均为 0 或不可测）' }) + "。" +
        "其中 $needAdmin 项需要管理员权限才能清理。" +
        "不含：pagefile.sys（不能删，只能缩小或迁盘，属「可迁移」约 $(Format-Bytes $pf.bytes)）、" +
        "WinSxS（需 DISM 分析，未测）、系统还原（本机未测到）。") `
        -Fix ('清理顺序建议：先清 %TEMP% 与回收站（不需管理员、无风险），再处理 Windows 更新缓存与 Windows\Temp（需管理员），' +
            '最后考虑 pagefile 迁盘。') -NeedsAdmin $false

$elapsedMs = [int]$clock.ElapsedMilliseconds
$extra = @{
    elapsedMs        = $elapsedMs
    budgetMs         = $TotalBudget
    safeBytes        = $safeTotal
    safeGB           = [math]::Round($safeTotal / 1073741824.0, 2)
    pagefileBytes    = [int64]$pf.bytes
    hiberfilBytes    = [int64]$hib.bytes
    userTempBytes    = [int64]$ut.bytes
    recycleBytes     = [int64]$rbBytes
    updateCacheBytes = [int64]$wu.bytes
    freeBytes        = $cFree
    totalBytes       = $cTotal
    appDataScanned   = $totalScans
    appDataSkipped   = $skipped
    appDataTruncated = $scanTrunc
    elevated         = $elevated
}

Write-ProbeResult -Items $items -Extra $extra -Note (
    '只读分析探针：仅枚举目录/读取注册表与 CIM，绝不删除、移动或修改任何内容。' +
    '目录大小用流式 BFS 统计（DirectoryInfo + 显式栈 + 硬截止），不用 Get-ChildItem -Recurse。' +
    '所有字节数均为实测；测不到的项标 skip 并写明原因，不做估算。' +
    '前导勾选清理前请自行确认对应程序未在运行。'
)
