param([string]$ParamFile)

# ---------------------------------------------------------------------------
# shredder.ps1 — 文件粉碎（DANGEROUS）。默认 dryRun，只接受显式文件路径。
#
# 这个探针是本插件里唯一会删文件的写路径，所以每一条限制都写在代码里而不是
# 写在文档里：
#
#   * 只接受 params.paths 里逐个列出的**文件**。不递归、不展开通配符、
#     不删目录；含 * ? [ ] 的路径一律拒绝（不是当字面量处理，是直接拒绝，
#     否则调用方以为自己在写 glob，实际删掉的是一个同名文件）。
#   * 路径先 Resolve 成绝对路径，再做黑名单前缀比较（比较时带尾部分隔符，
#     否则 C:\Windows 的 StartsWith 会把 C:\Windows10Backup 也算进去）。
#   * 系统/可执行扩展名、系统目录、AppData、重解析点（符号链接/联接）、
#     硬链接（>1 个链接名）、非固定盘（网络/可移动）一律拒绝。
#   * 单文件 ≤100 MB，单次 ≤50 个文件、总量 ≤500 MB。
#   * 真删只有显式 dryRun=false 才会发生：先用随机字节覆盖同样长度并落盘
#     (Flush(true))，再 Remove-Item -LiteralPath -Force，两步各报耗时。
#
# 为什么还要内建一行"SSD 上粉碎无效"：这台机器 DisableDeleteNotify=0（TRIM
# 开启）且两块盘都是 SSD。覆盖写入经过 FTL 重映射后落到的是**新的**物理块，
# 旧块只会被 TRIM 标记、由主控决定何时擦除，覆盖根本触不到原数据。真正能解决
# "删掉也能恢复"的是全盘加密（BitLocker）：盘上存的本来就是密文。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList
$started = Get-Date
$isElevated = Test-Elevated

# 缺省 dryRun = true。只有显式传 false 才真删。
$dryRun = -not ($params.PSObject.Properties.Name -contains 'dryRun' -and $params.dryRun -eq $false)

$MAX_FILE_BYTES = [int64]100 * 1MB
$MAX_FILES = 50
$MAX_TOTAL_BYTES = [int64]500 * 1MB

$WILDCARD = '[*?\[\]]'
$BLOCK_EXT = @('.sys', '.dll', '.exe', '.msi', '.ocx', '.drv', '.cpl')

# 黑名单目录：全部规范成"绝对路径 + 结尾不带分隔符"，比较时统一加 '\' 前缀。
$blockDirs = [System.Collections.Generic.List[string]]::new()
foreach ($cand in @($env:SystemRoot, $env:windir, 'C:\Windows',
                    $env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\Program Files', 'C:\Program Files (x86)',
                    $env:ProgramData, 'C:\ProgramData',
                    $(if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'AppData' }))) {
    if (-not $cand) { continue }
    $n = ''
    try { $n = [System.IO.Path]::GetFullPath([string]$cand).TrimEnd('\') } catch { $n = '' }
    if ($n -and -not $blockDirs.Contains($n)) { $blockDirs.Add($n) }
}

function Format-Size {
    param($Bytes)
    $b = [double]$Bytes
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N2} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N1} KB' -f ($b / 1KB)) }
    return ('{0} B' -f [int64]$b)
}

# 判断 $Path 是否落在 $Dir 之下（必须带边界，避免 C:\Windows 吃掉 C:\WindowsOld）。
function Test-UnderDir {
    param([string]$Path, [string]$Dir)
    if (-not $Path -or -not $Dir) { return $false }
    $p = $Path.TrimEnd('\')
    $d = $Dir.TrimEnd('\')
    if ($p.Equals($d, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($d + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

# 一条路径命中哪条黑名单（返回原因文本，未命中返回空串）。
function Get-BlockReason {
    param([string]$FullPath)
    foreach ($d in $blockDirs) {
        if (Test-UnderDir -Path $FullPath -Dir $d) { return "位于受保护目录 $d 下" }
    }
    # 任何层级的 System32 / SysWOW64 都算系统目录（含非 C: 安装、或被移动过的路径）。
    foreach ($seg in ($FullPath -split '\\')) {
        if ($seg -ieq 'System32') { return '路径中包含 System32 目录' }
        if ($seg -ieq 'SysWOW64') { return '路径中包含 SysWOW64 目录' }
    }
    return ''
}

# ---- 0. TRIM / SSD / 加密 只读读数 -------------------------------------------
$trimRaw = @(& fsutil behavior query DisableDeleteNotify 2>&1 | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
$trimText = ($trimRaw -join ' ')
$ntfsVal = $null
$refsVal = $null
foreach ($line in $trimRaw) {
    if ($line -match 'NTFS\s+DisableDeleteNotify\s*=\s*(\d+)') { $ntfsVal = [int]$matches[1] }
    elseif ($line -match 'ReFS\s+DisableDeleteNotify\s*=\s*(\d+)') { $refsVal = [int]$matches[1] }
}
if ($null -ne $ntfsVal -or $null -ne $refsVal) {
    $ntfsText = if ($null -ne $ntfsVal) { [string]$ntfsVal } else { '未返回' }
    $refsText = if ($null -ne $refsVal) { [string]$refsVal } else { '未返回' }
    $trimStatus = 'info'
    $trimDetail = '0 = TRIM 已开启（删除后由主控回收物理块），1 = TRIM 被禁用。'
    if ($null -ne $ntfsVal -and $ntfsVal -ne 0) {
        $trimStatus = 'warn'
        $trimDetail = '1 = TRIM 已被禁用：SSD 回收不到已删块，长期会掉速；但这也意味着旧数据块留在原地，覆盖写入反而更容易碰到它。'
    }
    Add-Item -List $items -Id 'shredder:trim-status' -Group 'shred' -Label 'TRIM 状态' -Status $trimStatus `
        -Value ("NTFS=$ntfsText · ReFS=$refsText") -Detail $trimDetail `
        -Fix $(if ($trimStatus -eq 'warn') { '恢复 TRIM：fsutil behavior set DisableDeleteNotify 0（需管理员）' } else { '' }) `
        -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'shredder:trim-status' -Group 'shred' -Label 'TRIM 状态' -Status 'skip' `
        -Value '读取失败' -Detail ("fsutil behavior query DisableDeleteNotify 没有返回可解析的 NTFS/ReFS 行：{0}" -f $trimText) `
        -Fix '在管理员 PowerShell 里手动运行 fsutil behavior query DisableDeleteNotify' -NeedsAdmin $true
}

$pdList = @()
try { $pdList = @(Get-PhysicalDisk -ErrorAction Stop) } catch { $pdList = @() }
$mediaRows = [System.Collections.Generic.List[object]]::new()
$ssdCount = 0
$hddCount = 0
$unknownCount = 0
foreach ($pd in $pdList) {
    $mt = 'Unknown'
    if ($pd.MediaType) { $mt = [string]$pd.MediaType }
    if ($mt -eq 'SSD') { $ssdCount++ } elseif ($mt -eq 'HDD') { $hddCount++ } else { $unknownCount++ }
    $mediaRows.Add([ordered]@{
        deviceId = [string]$pd.DeviceId
        name = [string]$pd.FriendlyName
        mediaType = $mt
        busType = if ($pd.BusType) { [string]$pd.BusType } else { '' }
        sizeBytes = [int64]$pd.Size
    })
}
if ($pdList.Count -gt 0) {
    Add-Item -List $items -Id 'shredder:media-type' -Group 'shred' -Label '磁盘介质' -Status 'info' `
        -Value ("SSD {0} 块 · HDD {1} 块" -f $ssdCount, $hddCount) `
        -Detail ((($mediaRows | ForEach-Object { "$($_.deviceId):$($_.name)=$($_.mediaType)" }) -join ' · ') +
            $(if ($unknownCount -gt 0) { "（其中 $unknownCount 块介质类型未知）" } else { '' })) `
        -Fix ''
} else {
    Add-Item -List $items -Id 'shredder:media-type' -Group 'shred' -Label '磁盘介质' -Status 'skip' `
        -Value '读取失败' -Detail 'Get-PhysicalDisk 没有返回结果（Storage 模块缺失或查询被拒）' -Fix ''
}

# 内建的核心事实行：SSD + TRIM 下覆盖写为什么无效。
$ssdEffective = ($ssdCount -gt 0 -and $hddCount -eq 0)
Add-Item -List $items -Id 'shredder:ssd-warning' -Group 'shred' -Label 'SSD 粉碎无效' -Status $(if ($ssdEffective) { 'warn' } else { 'info' }) `
    -Value $(if ($ssdEffective) { "本机 $ssdCount 块盘全是 SSD · TRIM=$([string]$ntfsVal)" } else { '存在非 SSD 介质' }) `
    -Detail '覆盖写在 SSD 上不能保证销毁原数据：主控把新写入重映射到新的物理块，旧块只被 TRIM 标记、由固件决定何时擦除，覆盖写根本触不到原物理块。' `
    -Fix '需要"删除后不可恢复"就上全盘加密：BitLocker 加密后盘上是密文，删不删都读不出来'

# BitLocker 状态（只读）。非管理员下 Get-BitLockerVolume 会先卡 5 s 再报
# 「拒绝访问」（实测 5.2 s），所以在提权前直接不调用，直接给 skip——结论一样，
# 省掉那 5 秒。
$blRow = $null
if (-not $isElevated) {
    Add-Item -List $items -Id 'shredder:bitlocker' -Group 'shred' -Label 'BitLocker' -Status 'skip' `
        -Value '需要管理员' -Detail 'Get-BitLockerVolume 在非管理员下报「拒绝访问」（本探针因此直接跳过，避免无谓等待），当前进程未提权，无法读取 C: 的加密状态' `
        -Fix '以管理员身份运行后重跑，或手动执行 manage-bde -status C:' -NeedsAdmin $true
} else {
    try {
        $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        $blRow = [ordered]@{ mount = 'C:'; status = [string]$bl.ProtectionStatus; method = [string]$bl.EncryptionMethod }
    } catch { $blRow = $null }
    if ($blRow) {
        $protected = ($blRow.status -eq 'On')
        Add-Item -List $items -Id 'shredder:bitlocker' -Group 'shred' -Label 'BitLocker' -Status $(if ($protected) { 'ok' } else { 'warn' }) `
            -Value ("C: {0} · {1}" -f $blRow.status, $blRow.method) `
            -Detail $(if ($protected) { '盘上数据是密文，物理块残留不构成泄露。' } else { '未加密：删除后的数据块仍可被取证工具恢复，粉碎只是心理安慰。' }) `
            -Fix $(if ($protected) { '' } else { '对系统盘启用 BitLocker（需 TPM 与管理员）' })
    } else {
        Add-Item -List $items -Id 'shredder:bitlocker' -Group 'shred' -Label 'BitLocker' -Status 'skip' `
            -Value '读取失败' -Detail 'Get-BitLockerVolume 在提权后仍报错（BitLocker 功能未安装或卷不可用）' `
            -Fix '手动执行 manage-bde -status C: 确认' -NeedsAdmin $true
    }
}

# ---- 1. 逐条校验调用方给的路径 -----------------------------------------------
$rawPaths = @()
if ($params.PSObject.Properties.Name -contains 'paths') { $rawPaths = @($params.paths) }

$files = [System.Collections.Generic.List[object]]::new()
$messages = [System.Collections.Generic.List[string]]::new()
$accepted = 0
$rejected = 0
$acceptedBytes = [int64]0
$freedBytes = [int64]0
$deletedCount = 0
$failedCount = 0

if ($rawPaths.Count -eq 0) {
    Add-Item -List $items -Id 'shredder:input' -Group 'shred' -Label '待碎文件' -Status 'info' `
        -Value '没有传入文件' `
        -Detail 'params.paths 为空。本探针只处理调用方逐条列出的文件，不会扫描目录、也不会猜测目标。' -Fix ''
} else {
    Add-Item -List $items -Id 'shredder:input' -Group 'shred' -Label '待碎文件' -Status 'info' `
        -Value ("收到 {0} 条路径" -f $rawPaths.Count) `
        -Detail ("模式 {0}。逐条校验：通配符/系统目录/系统扩展名/重解析点/非固定盘/大小与数量上限。" -f `
            $(if ($dryRun) { 'dryRun（只报计划）' } else { '真删（覆盖后删除）' })) -Fix ''

    $n = 0
    foreach ($raw in $rawPaths) {
        $n++
        $idx = $n
        $text = [string]$raw
        $reason = ''
        $full = ''
        $info = $null

        # --- 1a. 基本形状 ---
        if (-not $text -or -not $text.Trim()) {
            $reason = '空路径'
        } elseif ($text -match $WILDCARD) {
            $reason = '路径包含通配符（* ? [ ]），本探针只接受显式文件路径，不做 glob 展开'
        } elseif ($text -match '^\\\\') {
            $reason = 'UNC 网络路径不受支持'
        }

        # --- 1b. 解析成绝对路径 ---
        if (-not $reason) {
            $resolved = $null
            try { $resolved = Resolve-Path -LiteralPath $text -ErrorAction Stop } catch { $resolved = $null }
            if ($null -eq $resolved) {
                $reason = '路径不存在或无法解析'
            } else {
                try { $full = [System.IO.Path]::GetFullPath([string]$resolved.ProviderPath) }
                catch { $reason = '无法转成绝对路径' }
            }
        }

        # --- 1c. 必须是普通文件，不能是目录/重解析点 ---
        if (-not $reason) {
            $fi = $null
            try { $fi = Get-Item -LiteralPath $full -Force -ErrorAction Stop } catch { $fi = $null }
            if ($null -eq $fi) {
                $reason = '无法读取该路径的属性'
            } elseif ($fi.PSIsContainer) {
                $reason = '这是一个目录；本探针只删文件，绝不删目录'
            } elseif (($fi.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $reason = '这是一个重解析点（符号链接/联接），拒绝跟随'
            } else {
                $info = $fi
            }
        }

        # --- 1d. 黑名单目录 / 系统扩展名 ---
        if (-not $reason -and $info) {
            $br = Get-BlockReason -FullPath $full
            if ($br) { $reason = $br }
            else {
                $ext = [System.IO.Path]::GetExtension($full)
                if ($ext -and ($BLOCK_EXT -contains $ext.ToLowerInvariant())) {
                    $reason = "扩展名 $ext 属于系统/可执行文件，拒绝粉碎"
                }
            }
        }

        # --- 1e. 必须是本地固定磁盘 ---
        if (-not $reason -and $info) {
            $dt = 'Unknown'
            try { $dt = [string](New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($full))).DriveType }
            catch { $dt = 'Unknown' }
            if ($dt -ne 'Fixed') { $reason = "所在卷类型为 $dt，只处理本地固定磁盘" }
        }

        # --- 1f. 大小与总量 ---
        if (-not $reason -and $info) {
            $len = [int64]$info.Length
            if ($len -gt $MAX_FILE_BYTES) {
                $reason = ("单文件 {0} 超过上限 {1}" -f (Format-Size $len), (Format-Size $MAX_FILE_BYTES))
            } elseif ($accepted -ge $MAX_FILES) {
                $reason = "超过单次文件数上限 $MAX_FILES"
            } elseif (($acceptedBytes + $len) -gt $MAX_TOTAL_BYTES) {
                $reason = ("累计将达 {0}，超过单次总量上限 {1}" -f (Format-Size ($acceptedBytes + $len)), (Format-Size $MAX_TOTAL_BYTES))
            }
        }

        # --- 1g. 硬链接（覆盖会连带毁掉另一个名字下的数据） ---
        if (-not $reason -and $info) {
            $links = @()
            try { $links = @(& fsutil hardlink list "$full" 2>&1 | Where-Object { $_.Trim() }) } catch { $links = @() }
            if ($links.Count -gt 1) {
                $reason = ("该文件有 {0} 个硬链接名，覆盖会连带破坏其它名字下的数据" -f $links.Count)
            }
        }

        # --- 1h. 处置 ---
        if ($reason) {
            $rejected++
            $labelPath = if ($full) { $full } elseif ($text) { $text } else { '(空)' }
            $files.Add([ordered]@{
                index = $idx
                path = $labelPath
                ok = $false
                reason = $reason
                bytes = [int64]0
                action = 'rejected'
            })
            Add-Item -List $items -Id "shredder:file-$idx" -Group 'shred' -Label "文件 $idx" -Status 'skip' `
                -Value ("拒绝：" + $reason) -Detail $labelPath -Fix ''
            continue
        }

        $accepted++
        $len = [int64]$info.Length
        $acceptedBytes += $len

        if ($dryRun) {
            $files.Add([ordered]@{
                index = $idx; path = $full; ok = $true; reason = ''; bytes = $len; action = 'would-shred'
                overwriteMs = 0; deleteMs = 0
            })
            Add-Item -List $items -Id "shredder:file-$idx" -Group 'shred' -Label "文件 $idx" -Status 'warn' `
                -Value ("将覆盖并删除 " + (Format-Size $len)) `
                -Detail ("$full · 当前大小 $len 字节（dryRun，未改动任何文件）") -Fix ''
            continue
        }

        # 真删：覆盖 → 删除。任何一步失败都保留原因，不吞掉。
        $owMs = 0
        $delMs = 0
        $owOk = $false
        $delOk = $false
        $err = ''

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $fs = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $fs.SetLength($len)
                $buf = New-Object byte[] (1MB)
                $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                $left = $len
                while ($left -gt 0) {
                    $chunk = [int][Math]::Min([int64]$buf.Length, $left)
                    $rng.GetBytes($buf)
                    $fs.Write($buf, 0, $chunk)
                    $left -= $chunk
                }
                $fs.Flush($true)
                $owOk = $true
            } finally { $fs.Dispose() }
        } catch {
            $err = "覆盖失败：" + [string]$_.Exception.Message
        }
        $sw.Stop(); $owMs = [int]$sw.ElapsedMilliseconds

        if ($owOk) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                $delOk = -not (Test-Path -LiteralPath $full)
                if (-not $delOk) { $err = '删除后文件仍然存在' }
            } catch {
                $err = "删除失败：" + [string]$_.Exception.Message
            }
            $sw.Stop(); $delMs = [int]$sw.ElapsedMilliseconds
        }

        if ($delOk) {
            $deletedCount++
            $freedBytes += $len
            $messages.Add(("已粉碎 {0}（{1} 字节，覆盖 {2} ms、删除 {3} ms）" -f $full, $len, $owMs, $delMs))
            $files.Add([ordered]@{
                index = $idx; path = $full; ok = $true; reason = ''; bytes = $len; action = 'shredded'
                overwriteMs = $owMs; deleteMs = $delMs
            })
            Add-Item -List $items -Id "shredder:file-$idx" -Group 'shred' -Label "文件 $idx" -Status 'ok' `
                -Value ("已粉碎 " + (Format-Size $len)) `
                -Detail ("$full · 覆盖 $owMs ms · 删除 $delMs ms") -Fix ''
        } else {
            $failedCount++
            $messages.Add("粉碎失败 $full：$err")
            $files.Add([ordered]@{
                index = $idx; path = $full; ok = $false; reason = $err; bytes = $len; action = 'failed'
                overwriteMs = $owMs; deleteMs = $delMs
            })
            Add-Item -List $items -Id "shredder:file-$idx" -Group 'shred' -Label "文件 $idx" -Status 'bad' `
                -Value '粉碎失败' -Detail ("$full · $err（覆盖 ${owMs}ms，删除 ${delMs}ms）") `
                -Fix '确认文件没有被其它程序占用'
        }
    }

    # --- 1i. 计划/结果汇总行 ---
    if ($dryRun) {
        Add-Item -List $items -Id 'shredder:plan' -Group 'shred' -Label '执行计划' -Status $(if ($accepted -gt 0) { 'warn' } else { 'info' }) `
            -Value ("将覆盖并删除 {0} 个文件，共 {1}" -f $accepted, (Format-Size $acceptedBytes)) `
            -Detail ("通过校验 {0} 个 · 拒绝 {1} 个 · 共 {2} 字节。dryRun=true，磁盘上没有任何改动；确认后再传 dryRun=false。" -f `
                $accepted, $rejected, $acceptedBytes) `
            -Fix $(if ($accepted -gt 0) { '确认清单无误后传 dryRun:false 执行' } else { '' })
    } else {
        Add-Item -List $items -Id 'shredder:plan' -Group 'shred' -Label '执行结果' -Status $(if ($failedCount -gt 0) { 'bad' } elseif ($deletedCount -gt 0) { 'ok' } else { 'info' }) `
            -Value ("已删除 {0} 个文件，释放 {1}" -f $deletedCount, (Format-Size $freedBytes)) `
            -Detail ("通过校验 {0} 个 · 拒绝 {1} 个 · 失败 {2} 个 · 释放 {3} 字节" -f `
                $accepted, $rejected, $failedCount, $freedBytes) -Fix ''
    }
}

$elapsed = [int]((Get-Date) - $started).TotalMilliseconds
Write-ProbeResult -Items $items -Extra @{
    dryRun        = $dryRun
    elevated      = $isElevated
    requested     = $rawPaths.Count
    accepted      = $accepted
    rejected      = $rejected
    failed        = $failedCount
    deleted       = $deletedCount
    plannedBytes  = $acceptedBytes
    totalBytes    = $acceptedBytes
    freed         = $freedBytes
    limits        = [ordered]@{
        maxFileBytes  = $MAX_FILE_BYTES
        maxFiles      = $MAX_FILES
        maxTotalBytes = $MAX_TOTAL_BYTES
        blockExt      = $BLOCK_EXT
        blockDirs     = @($blockDirs)
    }
    trim = [ordered]@{ ntfs = $ntfsVal; refs = $refsVal; raw = $trimText }
    media = @($mediaRows)
    files         = @($files)
    messages      = @($messages)
    elapsedMs     = $elapsed
} -Note '默认 dryRun：只报计划、不动磁盘。SSD + TRIM 下覆盖写无法保证销毁原数据，真正的解法是全盘加密。'
