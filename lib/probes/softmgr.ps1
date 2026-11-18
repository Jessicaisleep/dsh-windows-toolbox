param([string]$ParamFile)

# ---------------------------------------------------------------------------
# softmgr.ps1 — 软件管家：一键升级 / 卸载残留清扫 / 软件搬家可行性 / 软件权限管理.
#
# 这是本插件里第二个带写路径的探针（另一个是 junk.ps1），所以门槛定得比只读
# 探针高得多：
#
#   * dryRun 缺省为 true。leftover 的真删还需要 purge=true，两个开关缺一不可。
#   * 删任何注册表键/值之前必须 reg export 备份到
#     %LOCALAPPDATA%\dsh-windows-toolbox\regbackup\；导出失败 → 该项跳过并报错。
#   * 只用 Remove-ItemProperty / Remove-Item -LiteralPath，从不调用 reg delete。
#   * 绝不删除 C:\Windows 下的任何东西，也不删 Program Files 根目录，只删
#     "五个白名单根目录的直接子目录" 且名字确实包含 appName 的目录。
#   * upgrade 只调用 winget upgrade，绝不自己下载安装包再执行。
#   * 服务与计划任务即使命中残留也只报告不代删：删服务无法由本工具回滚，
#     且同名服务可能属于别的软件。
#
# migrate 本版只做可行性分析，没有任何写路径：Windows 没有"移动已安装程序"的
# 官方机制，360 的软件搬家靠重定向 + 批量改注册表与快捷方式，漏改一处软件就坏。
#
# 实测依据（本机 Win10 19045 / pwsh 7.6.10，2026-11-17）：
#   winget upgrade --include-unknown        约 1.2 s，13 行可升级
#   netsh advfirewall ... show rule all     约 0.9 s，542 条规则，输出 500 KB
#   reg export 非管理员可导出 HKLM 键（只读权限足够），删除才需要管理员
#   两者被重定向到文件后都是 UTF-8 字节；仍保留 OEM 代码页回退，别的机器不炸
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$scriptStart = Get-Date

# ===========================================================================
# 参数读取
# ===========================================================================
# Read-ProbeParams 没有 ParamFile 时返回 @{}（hashtable），有文件时返回 PSObject，
# 两种形状都要能取值，否则面板首屏（不带参数）会直接抛错。
function Get-ParamValue {
    param($Bag, [string]$Name)
    if ($null -eq $Bag) { return $null }
    if ($Bag -is [hashtable]) {
        if ($Bag.ContainsKey($Name)) { return $Bag[$Name] }
        return $null
    }
    $p = $Bag.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# 大小写不敏感的字面量包含。绝不用 -match：appName 由用户给出，含 . + ( ) 时
# 会被当成正则，轻则匹配错，重则枚举到不该删的键。
function Test-Contains {
    param([string]$Text, [string]$Needle)
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Needle)) { return $false }
    return ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-ShortLabel {
    param([string]$Text, [int]$Max = 12)
    $t = [string]$Text
    if ($t.Length -le $Max) { return $t }
    return $t.Substring(0, $Max - 1) + [char]0x2026
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList
$messages = [System.Collections.Generic.List[string]]::new()

$action = [string](Get-ParamValue $params 'action')
if (-not $action) { $action = 'scan' }
$action = $action.Trim().ToLowerInvariant()

$dryRaw = Get-ParamValue $params 'dryRun'
$dryRun = $true
if ($null -ne $dryRaw) {
    if ($dryRaw -eq $false -or "$dryRaw" -eq 'false') { $dryRun = $false }
}
$purgeRaw = Get-ParamValue $params 'purge'
$purge = $false
if ($purgeRaw -eq $true -or "$purgeRaw" -eq 'true') { $purge = $true }

$appName = [string](Get-ParamValue $params 'appName')
$appName = $appName.Trim()
$installPath = [string](Get-ParamValue $params 'installPath')
$installPath = $installPath.Trim().Trim('"')
$exePath = [string](Get-ParamValue $params 'exePath')
$exePath = $exePath.Trim().Trim('"')

$elevated = Test-Elevated

# ===========================================================================
# 外部命令：硬超时 + 原始字节解码
# ===========================================================================
# 不用 `& cmd | Out-String`：那没有超时，netsh / winget 卡住会把整个面板拖死。
# 用 Start-Process 重定向到临时文件，WaitForExit(ms) 到点就 Kill，然后按字节读回。
# 不能直接用 ReadToEnd：读回来的是"按某个编码解码过的字符串"，而 winget 与 netsh
# 输出的编码并不保证一致（本机实测两者都是 UTF-8，但中文系统上见过 GBK）。
function ConvertFrom-NativeBytes {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $start = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $start = 3 }
    $slice = $Bytes
    if ($start -gt 0) {
        $slice = New-Object byte[] ($Bytes.Length - $start)
        [Array]::Copy($Bytes, $start, $slice, 0, $slice.Length)
    }
    # 先按严格 UTF-8 试；不合法再退回 OEM 代码页（中文系统 936）。
    try {
        $strict = [System.Text.UTF8Encoding]::new($false, $true)
        return $strict.GetString($slice)
    } catch { }
    try {
        $oem = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name OEMCP).OEMCP
        return [System.Text.Encoding]::GetEncoding($oem).GetString($slice)
    } catch { }
    return [System.Text.Encoding]::Default.GetString($slice)
}

function Invoke-Capture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMs = 60000
    )
    $r = @{ ok = $false; exitCode = -1; stdout = ''; stderr = ''; timedOut = $false; ms = 0; error = '' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-sm-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        $outFile = Join-Path $dir 'out.bin'
        $errFile = Join-Path $dir 'err.bin'
        $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
        if ($null -eq $proc) {
            $r.error = '进程没有启动起来'
            return $r
        }
        $exited = $false
        try { $exited = $proc.WaitForExit($TimeoutMs) } catch { $exited = $false }
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            try { $proc.WaitForExit(3000) | Out-Null } catch { }
            $r.timedOut = $true
            $r.error = "超过 $TimeoutMs ms 未返回，已强制结束"
        }
        try { $proc.Refresh() } catch { }
        if ($proc.HasExited) { $r.exitCode = [int]$proc.ExitCode }
        try { if (Test-Path -LiteralPath $outFile) { $r.stdout = ConvertFrom-NativeBytes ([System.IO.File]::ReadAllBytes($outFile)) } } catch { }
        try { if (Test-Path -LiteralPath $errFile) { $r.stderr = ConvertFrom-NativeBytes ([System.IO.File]::ReadAllBytes($errFile)) } } catch { }
        $r.ok = (-not $r.timedOut)
    } catch {
        $r.error = [string]$_.Exception.Message
    } finally {
        $sw.Stop()
        $r.ms = [int]$sw.ElapsedMilliseconds
        try { [System.IO.Directory]::Delete($dir, $true) } catch { }
    }
    return $r
}

# ===========================================================================
# winget
# ===========================================================================
function Get-WingetPath {
    $c = Get-Command winget -ErrorAction SilentlyContinue
    if ($c) { return [string]$c.Source }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    return ''
}

# 解析 `winget upgrade` 的表格。
#
# 列宽是按"显示宽度"排的，中文名一个字符占两格，所以不能按字符下标切列；
# 而按 \s{2,} 切也不行：名字超长时 winget 只留一个空格，那几行会切出 6 段
# （本机的 "Microsoft Visual C++ 2015-2022 ... 14.42.34438" 就是这种）。
# 因此从右往左锚定：最后一段是 source（winget/msstore），往前依次是可用版本、
# 当前版本、包 ID，剩下的全部拼回名字。ID 与版本号都不含空格，这个假设成立。
function ConvertFrom-WingetUpgradeTable {
    param([string]$Text)
    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not $Text) { return $rows }
    $lines = $Text -split "\r?\n"
    # 数据从第一条分隔线之后开始；表头与"正在更新源"之类的前言都在它之前。
    $sepIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-{5,}\s*$') { $sepIndex = $i; break }
    }
    if ($sepIndex -lt 0) { return $rows }
    $sources = @('winget', 'msstore')
    for ($i = $sepIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $line -or -not $line.Trim()) { continue }
        if ($line -match '^\s*-{5,}\s*$') { continue }
        $tokens = @([regex]::Split($line.Trim(), '\s+') | Where-Object { $_ })
        if ($tokens.Count -lt 4) { continue }
        $last = $tokens.Count - 1
        $source = ''
        $availIdx = $last
        if ($sources -contains $tokens[$last].ToLowerInvariant()) {
            $source = $tokens[$last]
            $availIdx = $last - 1
        }
        $verIdx = $availIdx - 1
        $idIdx = $verIdx - 1
        if ($idIdx -lt 1) { continue }
        $id = $tokens[$idIdx]
        # 包 ID 形如 Git.Git / Microsoft.VCRedist.2015+.x86：必须带点、无中文。
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9\._\-\+]*$' -or $id -notmatch '\.') { continue }
        $nameEnd = $idIdx - 1
        $name = ''
        if ($nameEnd -ge 0) { $name = ($tokens[0..$nameEnd] -join ' ') }
        $rows.Add([pscustomobject]@{
            name      = $name
            id        = $id
            version   = $tokens[$verIdx]
            available = $tokens[$availIdx]
            source    = $source
        })
    }
    return $rows
}

function Get-WingetUpgrades {
    $res = @{ ok = $false; rows = @(); error = ''; ms = 0; timedOut = $false; missing = $false }
    $exe = Get-WingetPath
    if (-not $exe) {
        $res.missing = $true
        $res.error = '本机没有 winget'
        return $res
    }
    $cap = Invoke-Capture -FilePath $exe -TimeoutMs 60000 -Arguments @(
        'upgrade', '--include-unknown', '--accept-source-agreements')
    $res.ms = $cap.ms
    $res.timedOut = $cap.timedOut
    if ($cap.timedOut) {
        $res.error = $cap.error
        return $res
    }
    if ($cap.exitCode -ne 0) {
        $tail = (($cap.stdout -split "\r?\n") | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | '
        $res.error = "winget 退出码 $($cap.exitCode)：$tail"
        if (-not $res.error.Trim()) { $res.error = "winget 退出码 $($cap.exitCode)" }
        return $res
    }
    $res.rows = @(ConvertFrom-WingetUpgradeTable -Text $cap.stdout)
    $res.ok = $true
    return $res
}

# ===========================================================================
# 已安装程序（注册表 Uninstall 三根）
# ===========================================================================
function Get-InstalledApps {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $roots) {
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $dn = [string]$p.DisplayName
            if (-not $dn) { continue }
            $out.Add([pscustomobject]@{
                root            = $root
                psPath          = [string]$k.PSPath
                regPath         = [string]$k.Name
                keyName         = [string]$k.PSChildName
                displayName     = $dn
                version         = [string]$p.DisplayVersion
                installLocation = ([string]$p.InstallLocation).Trim().Trim('"')
                displayIcon     = [string]$p.DisplayIcon
                uninstallString = [string]$p.UninstallString
                installSource   = [string]$p.InstallSource
            })
        }
    }
    return $out
}

# 从 DisplayIcon 里取 .exe 路径：值是 "C:\a\b.exe,0" 这种，带引号也可能带逗号。
function Get-IconExePath {
    param([string]$DisplayIcon)
    if (-not $DisplayIcon) { return '' }
    $v = $DisplayIcon.Trim()
    if ($v.StartsWith('"')) {
        $end = $v.IndexOf('"', 1)
        if ($end -gt 1) { return $v.Substring(1, $end - 1) }
    }
    $v = ($v -replace ',\s*-?\d+\s*$', '').Trim().Trim('"')
    if ($v -match '\.exe$') { return $v }
    if (Test-Path -LiteralPath $v) { return $v }
    return ''
}

# ===========================================================================
# 目录统计（带权限跳过计数）
# ===========================================================================
# 用 .NET 枚举而不是 Get-ChildItem：Get-ChildItem -ErrorAction SilentlyContinue 遇到
# 拒绝访问的目录会静默返回空，无法区分"空目录"和"没权限"，而契约要求跳过并计数。
# 顺带处理 junction：不跟随 ReparsePoint，否则 Program Files 下的链接会让它绕圈。
function Get-DirStats {
    param([string]$Path, [int]$MaxEntries = 400000)
    $st = @{ bytes = [int64]0; files = 0; dirs = 0; denied = 0; truncated = $false; exists = $false }
    if (-not $Path) { return $st }
    if (-not (Test-Path -LiteralPath $Path)) { return $st }
    $st.exists = $true
    $stack = [System.Collections.Stack]::new()
    $stack.Push($Path)
    $seen = 0
    while ($stack.Count -gt 0) {
        $d = [string]$stack.Pop()
        $entries = $null
        try { $entries = [System.IO.Directory]::GetFileSystemEntries($d) } catch { $st.denied++; continue }
        foreach ($e in $entries) {
            $seen++
            if ($seen -gt $MaxEntries) { $st.truncated = $true; break }
            try {
                $attr = [System.IO.File]::GetAttributes($e)
                if (($attr -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    $st.dirs++
                    if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $stack.Push($e)
                } else {
                    try {
                        $st.bytes += [int64](New-Object System.IO.FileInfo($e)).Length
                        $st.files++
                    } catch { $st.denied++ }
                }
            } catch { $st.denied++ }
        }
        if ($st.truncated) { break }
    }
    return $st
}

# ===========================================================================
# 注册表备份（purge 的前置条件）
# ===========================================================================
function Get-RegBackupDir {
    return (Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox\regbackup')
}

function Backup-RegKey {
    param([string]$KeyPath)   # HKEY_LOCAL_MACHINE\... 或 HKEY_CURRENT_USER\...
    $r = @{ ok = $false; file = ''; error = '' }
    if (-not $KeyPath) { $r.error = '键路径为空'; return $r }
    $dir = Get-RegBackupDir
    try { [System.IO.Directory]::CreateDirectory($dir) | Out-Null } catch { }
    if (-not (Test-Path -LiteralPath $dir)) { $r.error = "备份目录不可写：$dir"; return $r }
    $safe = ($KeyPath -replace '[\\/:*?"<>|]', '_')
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80) }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $file = Join-Path $dir ("{0}-{1}.reg" -f $stamp, $safe)
    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
    if (-not (Test-Path -LiteralPath $reg)) { $r.error = '找不到 reg.exe'; return $r }
    # 键名里常有空格，必须自己加引号：-ArgumentList 传数组时 PowerShell 不会替你加，
    # 本机实测不加就报 "ERROR: Invalid syntax."。
    # 用 Invoke-Capture（重定向 stdout/stderr 到文件）而不是直接 Start-Process：
    # reg.exe 成功时会往 stdout 打一句「操作成功完成。」，不重定向就会漏进探针的 JSON 里，
    # 把解析器搞挂（实测输出首行是 The operation completed successfully）。
    $cap = Invoke-Capture -FilePath $reg -TimeoutMs 30000 -Arguments @(
        'export', ('"' + $KeyPath + '"'), ('"' + $file + '"'), '/y')
    if ($cap.timedOut) { $r.error = 'reg export 超时'; return $r }
    if ($cap.exitCode -ne 0) {
        $msg = ($cap.stderr + ' ' + $cap.stdout).Trim()
        if (-not $msg) { $msg = "退出码 $($cap.exitCode)" }
        $r.error = "reg export 失败：$msg"
        return $r
    }
    if (-not (Test-Path -LiteralPath $file)) { $r.error = 'reg export 报成功但没有生成文件'; return $r }
    $len = 0
    try { $len = (Get-Item -LiteralPath $file).Length } catch { }
    if ($len -lt 32) { $r.error = "备份文件异常（$len 字节）"; return $r }
    $r.ok = $true
    $r.file = $file
    return $r
}

# ===========================================================================
# 防火墙规则（netsh）
# ===========================================================================
# 解析方式不依赖界面语言：规则块之间用一长串 '-' 分隔，分隔线的上一行就是规则名。
# 字段名则中英双写（本机是英文标签，中文系统是"规则名称/已启用/程序/操作"），
# 认不出来的字段再用"值像不像路径"兜底找 Program。
function Get-FirewallRules {
    param([int]$TimeoutMs = 90000)
    $r = @{ ok = $false; total = 0; rules = @(); error = ''; timedOut = $false; ms = 0 }
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    if (-not (Test-Path -LiteralPath $netsh)) { $r.error = '找不到 netsh.exe'; return $r }
    $cap = Invoke-Capture -FilePath $netsh -TimeoutMs $TimeoutMs -Arguments @(
        'advfirewall', 'firewall', 'show', 'rule', 'name=all', 'verbose')
    $r.ms = $cap.ms
    $r.timedOut = $cap.timedOut
    if ($cap.timedOut) { $r.error = $cap.error; return $r }
    if ($cap.exitCode -ne 0 -and -not $cap.stdout) {
        $r.error = "netsh 退出码 $($cap.exitCode)"
        return $r
    }
    $lines = $cap.stdout -split "\r?\n"
    $seps = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-{5,}\s*$') { $seps.Add($i) }
    }
    $rules = [System.Collections.Generic.List[object]]::new()
    for ($s = 0; $s -lt $seps.Count; $s++) {
        $sep = $seps[$s]
        $nameLine = ''
        for ($b = $sep - 1; $b -ge 0; $b--) {
            if ($lines[$b] -and $lines[$b].Trim()) { $nameLine = $lines[$b].Trim(); break }
        }
        $name = ($nameLine -replace '^[^:]*:\s*', '').Trim()
        if (-not $name) { $name = $nameLine }
        $endIdx = $lines.Count - 1
        if ($s + 1 -lt $seps.Count) { $endIdx = $seps[$s + 1] - 2 }
        $cur = @{ name = $name; program = ''; enabled = ''; action = ''; direction = ''; grouping = '' }
        for ($j = $sep + 1; $j -le $endIdx -and $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            if (-not $line) { continue }
            $kv = [regex]::Match($line, '^\s*([^:]{1,40}?)\s*:\s*(.*)$')
            if (-not $kv.Success) { continue }
            $label = $kv.Groups[1].Value.Trim()
            $val = $kv.Groups[2].Value.Trim()
            if ($label -match '^(Program|程序|Programm)$') { $cur.program = $val }
            elseif ($label -match '^(Enabled|已启用|启用)$') { $cur.enabled = $val }
            elseif ($label -match '^(Action|操作)$') { $cur.action = $val }
            elseif ($label -match '^(Direction|方向)$') { $cur.direction = $val }
            elseif ($label -match '^(Grouping|组)$') { $cur.grouping = $val }
            elseif (-not $cur.program -and $val -match '^[A-Za-z]:\\|^%[A-Za-z]+%\\') { $cur.program = $val }
        }
        $rules.Add([pscustomobject]$cur)
    }
    $r.rules = @($rules)
    $r.total = $rules.Count
    $r.ok = $true
    return $r
}

# ===========================================================================
# 其他读取器
# ===========================================================================
$runKeyPaths = @(
    @{ ps = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; reg = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; label = 'HKLM Run' },
    @{ ps = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; reg = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; label = 'HKLM RunOnce' },
    @{ ps = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; reg = 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; label = 'HKLM Run(32)' },
    @{ ps = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; reg = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run'; label = 'HKCU Run' },
    @{ ps = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; reg = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\RunOnce'; label = 'HKCU RunOnce' }
)

function Get-RunEntries {
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $runKeyPaths) {
        $p = Get-ItemProperty -LiteralPath $k.ps -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $out.Add([pscustomobject]@{
                keyLabel = $k.label
                keyPsPath = $k.ps
                keyRegPath = $k.reg
                name = $prop.Name
                value = [string]$prop.Value
            })
        }
    }
    return $out
}

function Resolve-InstallTarget {
    param($Apps, [string]$Name, [string]$ExplicitPath)
    $t = @{ path = ''; source = ''; entry = $null; name = $Name; exists = $false }
    if ($ExplicitPath) {
        $p = $ExplicitPath.TrimEnd('\')
        if (Test-Path -LiteralPath $p) {
            $t.path = $p
            $t.source = 'installPath 参数'
            $t.exists = $true
            return $t
        }
    }
    if (-not $Name) { return $t }
    $cands = @($Apps | Where-Object { Test-Contains $_.displayName $Name })
    foreach ($c in $cands) {
        $loc = [string]$c.installLocation
        if ($loc) {
            $loc = $loc.TrimEnd('\')
            if (Test-Path -LiteralPath $loc) {
                $t.path = $loc; $t.source = 'Uninstall\InstallLocation'; $t.entry = $c; $t.exists = $true
                return $t
            }
        }
    }
    foreach ($c in $cands) {
        $ico = Get-IconExePath -DisplayIcon $c.displayIcon
        if ($ico) {
            $dir = Split-Path -Path $ico -Parent
            if ($dir -and (Test-Path -LiteralPath $dir)) {
                $t.path = $dir.TrimEnd('\'); $t.source = 'Uninstall\DisplayIcon'; $t.entry = $c; $t.exists = $true
                return $t
            }
        }
    }
    # 兜底：在几个常见安装根目录的一级子目录里按名字找。
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Contains $d.Name $Name) {
                $t.path = $d.FullName.TrimEnd('\'); $t.source = '目录名匹配'; $t.exists = $true
                return $t
            }
        }
    }
    return $t
}

function Test-PathUnder {
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    $p = $Path.TrimEnd('\').ToLowerInvariant()
    $r = $Root.TrimEnd('\').ToLowerInvariant()
    return ($p -eq $r -or $p.StartsWith($r + '\'))
}

# 写权限位判定。本机实测 Get-Acl 会把一些组合显示成数字（268435456 = GENERIC_ALL，
# -1610612736 = 0xA0000000 = READ|EXECUTE），所以不能只按枚举名比较。
function Test-WriteRights {
    param($Rights)
    try {
        $v = [uint64]([int64]$Rights -band 0xFFFFFFFF)
    } catch { return $false }
    $mask = [uint64]0x2 -bor [uint64]0x4 -bor [uint64]0x10 -bor [uint64]0x40 -bor [uint64]0x100 `
        -bor [uint64]0x10000 -bor [uint64]0x40000 -bor [uint64]0x80000 `
        -bor [uint64]0x10000000 -bor [uint64]0x40000000
    return (($v -band $mask) -ne 0)
}

function Format-Rights {
    param($Rights)
    $s = [string]$Rights
    if ($s -match '^\d+$') {
        $n = [uint64]([int64]$Rights -band 0xFFFFFFFF)
        if ($n -eq 0x10000000) { return 'GenericAll' }
        if ($n -eq 0x40000000) { return 'GenericWrite' }
        if ($n -eq 0xA0000000) { return 'GenericRead+Execute' }
        if ($n -eq 0x80000000) { return 'GenericRead' }
        if ($n -eq 0x20000000) { return 'GenericExecute' }
    }
    return $s
}

# ===========================================================================
# A. upgrade —— 一键升级
# ===========================================================================
function Invoke-UpgradeAction {
    param($List)
    $extra = @{ upgradable = 0; upgraded = 0; upgradeFailed = 0; wingetVersion = '' }
    $winget = Get-WingetPath
    if (-not $winget) {
        Add-Item -List $List -Id 'softmgr:upgrade-tool' -Group 'upgrade' -Label 'winget' -Status 'skip' `
            -Value '未安装' `
            -Detail '本机找不到 winget（App Installer），无法枚举可升级的软件。' `
            -Fix '从 Microsoft Store 安装「应用安装程序 / App Installer」' -NeedsAdmin $true
        $messages.Add('winget 不存在，upgrade 未执行')
        return $extra
    }
    $verCap = Invoke-Capture -FilePath $winget -TimeoutMs 20000 -Arguments @('--version')
    if ($verCap.stdout) { $extra.wingetVersion = $verCap.stdout.Trim() }

    # 注意：变量名不能叫 $list —— PowerShell 变量名不区分大小写，
    # 那会覆盖参数 $List（探针的输出列表），导致所有已产出的行丢失。
    $upg = Get-WingetUpgrades
    if ($upg.timedOut) {
        Add-Item -List $List -Id 'softmgr:upgrade-list' -Group 'upgrade' -Label '可升级清单' -Status 'skip' `
            -Value '超时' -Detail 'winget upgrade 在 60 s 内没有返回，已终止；没有改动任何软件。' `
            -Fix '稍后重试，或先手动运行 winget upgrade 看是否卡在更新源'
        $messages.Add('winget upgrade 超时')
        return $extra
    }
    if (-not $upg.ok) {
        Add-Item -List $List -Id 'softmgr:upgrade-list' -Group 'upgrade' -Label '可升级清单' -Status 'skip' `
            -Value '读取失败' -Detail $upg.error `
            -Fix '手动在终端运行 winget upgrade 查看具体报错'
        $messages.Add("winget upgrade 读取失败：$($upg.error)")
        return $extra
    }
    $rows = @($upg.rows)
    $extra.upgradable = $rows.Count

    if ($rows.Count -eq 0) {
        Add-Item -List $List -Id 'softmgr:upgrade-none' -Group 'upgrade' -Label '可升级软件' -Status 'ok' `
            -Value '0 个' -Detail 'winget 没有报告任何可升级的软件。' -Fix ''
        return $extra
    }

    Add-Item -List $List -Id 'softmgr:upgrade-summary' -Group 'upgrade' -Label '可升级软件' -Status 'warn' `
        -Value "$($rows.Count) 个" `
        -Detail "winget 用 $($upg.ms) ms 列出 $($rows.Count) 个可升级项。$(if ($dryRun) { '当前是预演：不会真的升级。' } else { '当前会逐个升级。' })" `
        -Fix $(if ($dryRun) { '确认清单后以 dryRun:false 重新执行才会真的升级' } else { '' })

    $seen = @{}
    $i = 0
    foreach ($row in $rows) {
        $i++
        $baseId = 'softmgr:upgrade-' + ($row.id -replace '[^A-Za-z0-9\.\-_]', '_')
        $id = $baseId
        if ($seen.ContainsKey($id)) { $id = "$baseId-$i" }
        $seen[$id] = $true

        $label = Get-ShortLabel -Text $(if ($row.name) { $row.name } else { $row.id })
        $plan = "将升级 $($row.name)：$($row.version) → $($row.available)"

        if ($dryRun) {
            Add-Item -List $List -Id $id -Group 'upgrade' -Label $label -Status 'warn' `
                -Value "$($row.version) → $($row.available)" `
                -Detail "$plan（预演，未执行）。包 ID：$($row.id)$(if ($row.source) { " · 源 $($row.source)" })" `
                -Fix '以 dryRun:false 执行 upgrade 才会真的升级'
            continue
        }

        # 真升级：只调 winget，绝不自己下载安装包再运行。
        $cap = Invoke-Capture -FilePath $winget -TimeoutMs 120000 -Arguments @(
            'upgrade', '--id', $row.id, '--silent',
            '--accept-package-agreements', '--accept-source-agreements')
        if ($cap.timedOut) {
            $extra.upgradeFailed++
            Add-Item -List $List -Id $id -Group 'upgrade' -Label $label -Status 'skip' `
                -Value '超时' -Detail "winget upgrade --id $($row.id) 超过 120 s 未返回，已终止；该包状态未知。" `
                -Fix '单独运行 winget upgrade --id 看它停在哪一步'
            continue
        }
        $tail = (($cap.stdout -split "\r?\n") | Where-Object { $_.Trim() } | Select-Object -Last 5) -join ' | '
        if ($cap.exitCode -eq 0) {
            $extra.upgraded++
            Add-Item -List $List -Id $id -Group 'upgrade' -Label $label -Status 'ok' `
                -Value "$($row.version) → $($row.available)" `
                -Detail "winget 退出码 0，用时 $($cap.ms) ms。包 ID：$($row.id)。输出末尾：$tail" `
                -Fix ''
        } else {
            $extra.upgradeFailed++
            Add-Item -List $List -Id $id -Group 'upgrade' -Label $label -Status 'bad' `
                -Value "失败，退出码 $($cap.exitCode)" `
                -Detail "winget upgrade --id $($row.id) 未能升级。输出末尾：$tail" `
                -Fix '手动运行同一条命令查看完整报错（常见原因是安装器需要交互或已被占用）'
        }
    }
    return $extra
}

# ===========================================================================
# B. leftover —— 卸载残留清扫
# ===========================================================================
function Invoke-LeftoverAction {
    param($List, [bool]$DryRun, [bool]$Purge)
    $extra = @{
        leftoverApp = $appName; leftoverFound = 0; purged = 0; purgeFailed = 0
        purgeSkipped = 0; backupDir = (Get-RegBackupDir)
    }
    if (-not $appName) {
        Add-Item -List $List -Id 'softmgr:leftover-input' -Group 'leftover' -Label '软件名' -Status 'skip' `
            -Value '未提供' -Detail '清扫残留需要 params.appName，例如 {"action":"leftover","appName":"Everything"}。' `
            -Fix '补上 appName 再执行'
        return $extra
    }
    $extra.leftoverApp = $appName

    $apps = Get-InstalledApps
    $found = 0

    # 全局安全闸：只要 Uninstall 里还有一条 InstallLocation 真实存在，就认为软件仍装着，
    # 此时任何"残留清扫"都极可能是在拆一个在用的软件。所有删除分支共用这个判断。
    $liveInstalls = @($apps | Where-Object {
            (Test-Contains $_.displayName $appName) -and $_.installLocation -and
            (Test-Path -LiteralPath ([string]$_.installLocation).TrimEnd('\'))
        })
    $appStillInstalled = ($liveInstalls.Count -gt 0)

    # ---- 1. Uninstall 注册表残留 -------------------------------------------
    $uninstallHits = @($apps | Where-Object { Test-Contains $_.displayName $appName })
    if ($uninstallHits.Count -eq 0) {
        Add-Item -List $List -Id 'softmgr:leftover-uninstall' -Group 'leftover' -Label '卸载注册表项' -Status 'ok' `
            -Value '0 处' -Detail "三个 Uninstall 根下没有 DisplayName 含「$appName」的键。" -Fix ''
    } else {
        Add-Item -List $List -Id 'softmgr:leftover-uninstall' -Group 'leftover' -Label '卸载注册表项' -Status 'warn' `
            -Value "$($uninstallHits.Count) 处" `
            -Detail "DisplayName 含「$appName」的键（含仍正常安装的条目，别把在用软件的卸载项删了）。" -Fix ''
        $n = 0
        foreach ($hit in $uninstallHits) {
            $found++
            $n++
            $iid = "softmgr:leftover-uninstall-$n"
            $ver = if ($hit.version) { $hit.version } else { '无版本' }
            # 安全闸：InstallLocation 还在 → 这个软件其实还装着，它的卸载项不是"残留"。
            # 删掉它，用户在「应用和功能」里就再也卸不掉这个软件了，所以这一项一律拒绝删除。
            $stillInstalled = ($hit.installLocation -and (Test-Path -LiteralPath $hit.installLocation))
            if (-not ($DryRun -or -not $Purge)) {
                if ($stillInstalled) {
                    $extra.purgeSkipped++
                    Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.displayName) -Status 'skip' `
                        -Value '未删除 · 软件仍在安装状态' `
                        -Detail "$($hit.displayName) 的 InstallLocation $($hit.installLocation) 依然存在，说明它没被卸载，这个卸载项是有效项不是残留。删了会让它在「应用和功能」里消失、无法正常卸载。键：$($hit.regPath)" `
                        -Fix '确认软件确实已卸载后再清扫；仍装着就先走正常卸载流程'
                    continue
                }
                # 真删：先备份，备份失败就跳过这一项。
                $bk = Backup-RegKey -KeyPath $hit.regPath
                if (-not $bk.ok) {
                    $extra.purgeFailed++
                    Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.displayName) -Status 'bad' `
                        -Value '未删除' -Detail "备份失败，已跳过：$($bk.error)。键：$($hit.regPath)" `
                        -Fix '检查 regbackup 目录权限后重试'
                } else {
                    $before = @(Get-ChildItem -LiteralPath $hit.psPath -ErrorAction SilentlyContinue).Count
                    Remove-Item -LiteralPath $hit.psPath -Recurse -Force -ErrorAction SilentlyContinue
                    $gone = -not (Test-Path -LiteralPath $hit.psPath)
                    if ($gone) {
                        $extra.purged++
                        Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.displayName) -Status 'ok' `
                            -Value '已删除' -Detail "卸载项已删除（含 $before 个子键），备份：$($bk.file)" -Fix ''
                    } else {
                        $extra.purgeFailed++
                        Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.displayName) -Status 'bad' `
                            -Value '删除失败' -Detail "已备份到 $($bk.file)，但删除没有生效（HKLM 需要管理员）。键：$($hit.regPath)" `
                            -Fix '以管理员身份运行后再清扫'
                    }
                }
            } else {
                Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.displayName) -Status 'warn' `
                    -Value $ver -Detail "$($hit.displayName)。键：$($hit.regPath)$(if ($hit.installLocation) { " · 安装位置 $($hit.installLocation)" })" `
                    -Fix $(if ($DryRun) { '确认后用 dryRun:false + purge:true 删除（会先 reg export 备份）' } else { '需要同时给 purge:true 才会删' })
            }
        }
    }

    # ---- 2. SOFTWARE 软件项残留（只枚举一级，绝不递归整棵） -------------------
    $softRoots = @('HKLM:\SOFTWARE', 'HKCU:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')
    $softHits = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $softRoots) {
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            if (Test-Contains $k.PSChildName $appName) {
                $softHits.Add([pscustomobject]@{
                    psPath = [string]$k.PSPath
                    regPath = [string]$k.Name
                    name = [string]$k.PSChildName
                    root = $root
                })
            }
        }
    }
    if ($softHits.Count -eq 0) {
        Add-Item -List $List -Id 'softmgr:leftover-softkey' -Group 'leftover' -Label '软件注册表项' -Status 'ok' `
            -Value '0 处' -Detail "HKLM\SOFTWARE、HKCU\SOFTWARE、WOW6432Node 的一级子键名里没有「$appName」。" -Fix ''
    } else {
        Add-Item -List $List -Id 'softmgr:leftover-softkey' -Group 'leftover' -Label '软件注册表项' -Status 'warn' `
            -Value "$($softHits.Count) 处" `
            -Detail "一级子键名含「$appName」的软件配置项。只枚举了一层，没有递归整棵注册表。" -Fix ''
        $n = 0
        foreach ($hit in $softHits) {
            $found++
            $n++
            $iid = "softmgr:leftover-softkey-$n"
            if (-not ($DryRun -or -not $Purge)) {
                if ($appStillInstalled) {
                    $extra.purgeSkipped++
                    Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'skip' `
                        -Value '未删除 · 软件仍在安装状态' `
                        -Detail "键：$($hit.regPath)。拒删原因：Uninstall 里该软件的 InstallLocation 仍然存在，说明软件还装着，这份软件配置很可能正在用。" `
                        -Fix '确认软件确实已卸载后再清扫'
                    continue
                }
                $bk = Backup-RegKey -KeyPath $hit.regPath
                if (-not $bk.ok) {
                    $extra.purgeFailed++
                    Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'bad' `
                        -Value '未删除' -Detail "备份失败，已跳过：$($bk.error)。键：$($hit.regPath)" `
                        -Fix '检查 regbackup 目录权限后重试'
                } else {
                    Remove-Item -LiteralPath $hit.psPath -Recurse -Force -ErrorAction SilentlyContinue
                    $gone = -not (Test-Path -LiteralPath $hit.psPath)
                    if ($gone) {
                        $extra.purged++
                        Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'ok' `
                            -Value '已删除' -Detail "注册表软件项已删除，备份：$($bk.file)" -Fix ''
                    } else {
                        $extra.purgeFailed++
                        Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'bad' `
                            -Value '删除失败' -Detail "已备份到 $($bk.file)，但删除没有生效。键：$($hit.regPath)" `
                            -Fix '以管理员身份运行后再清扫'
                    }
                }
            } else {
                Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'warn' `
                    -Value $hit.root -Detail "键：$($hit.regPath)" `
                    -Fix $(if ($DryRun) { '确认后用 dryRun:false + purge:true 删除' } else { '需要同时给 purge:true 才会删' })
            }
        }
    }

    # ---- 3. 文件残留（五个根目录的一级子目录） ------------------------------
    $fileRoots = [System.Collections.Generic.List[object]]::new()
    foreach ($rp in @(
            @{ p = $env:LOCALAPPDATA; label = 'LOCALAPPDATA' },
            @{ p = $env:APPDATA; label = 'APPDATA' },
            @{ p = $env:ProgramData; label = 'ProgramData' },
            @{ p = $env:ProgramFiles; label = 'Program Files' },
            @{ p = ${env:ProgramFiles(x86)}; label = 'Program Files (x86)' })) {
        if ($rp.p -and (Test-Path -LiteralPath $rp.p)) {
            $fileRoots.Add([pscustomobject]@{ path = $rp.p.TrimEnd('\'); label = $rp.label })
        }
    }
    $fileHits = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $fileRoots) {
        foreach ($d in (Get-ChildItem -LiteralPath $root.path -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Contains $d.Name $appName) {
                $st = Get-DirStats -Path $d.FullName
                $fileHits.Add([pscustomobject]@{
                    path = $d.FullName; name = $d.Name; root = $root.path; rootLabel = $root.label
                    bytes = [int64]$st.bytes; files = [int]$st.files; dirs = [int]$st.dirs
                    denied = [int]$st.denied; truncated = [bool]$st.truncated
                })
            }
        }
    }
    if ($fileHits.Count -eq 0) {
        Add-Item -List $List -Id 'softmgr:leftover-file' -Group 'leftover' -Label '文件残留' -Status 'ok' `
            -Value '0 个' -Detail "$($fileRoots.Count) 个根目录的一级子目录名里没有「$appName」。" -Fix ''
    } else {
        $tb = [int64]0
        $tf = 0
        foreach ($h in $fileHits) { $tb += $h.bytes; $tf += $h.files }
        Add-Item -List $List -Id 'softmgr:leftover-file' -Group 'leftover' -Label '文件残留' -Status 'warn' `
            -Value "$($fileHits.Count) 个目录 · $(Format-Size $tb)" `
            -Detail "合计 $tf 个文件。只按一级子目录名匹配，没有进 C:\Windows。" -Fix ''
        $n = 0
        foreach ($hit in $fileHits) {
            $found++
            $n++
            $iid = "softmgr:leftover-file-$n"
            $denyText = if ($hit.denied -gt 0) { " · 跳过 $($hit.denied) 个无权限项" } else { '' }
            $truncText = if ($hit.truncated) { ' · 已达枚举上限，大小是下限' } else { '' }
            $detail = "$($hit.rootLabel)：$($hit.path)。$($hit.files) 个文件 / $($hit.dirs) 个子目录，$(Format-Size $hit.bytes)$denyText$truncText"
            if (-not ($DryRun -or -not $Purge)) {
                if ($appStillInstalled) {
                    $extra.purgeSkipped++
                    Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'skip' `
                        -Value '未删除 · 软件仍在安装状态' `
                        -Detail "$detail。拒删原因：Uninstall 里该软件的 InstallLocation 仍然存在，说明软件还装着，这个目录很可能是它在用的数据目录。" `
                        -Fix '确认软件确实已卸载后再清扫'
                    continue
                }
                $safe = Test-SafePurgePath -Path $hit.path
                if (-not $safe.ok) {
                    $extra.purgeSkipped++
                    Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'skip' `
                        -Value '未删除' -Detail "$detail。拒删原因：$($safe.reason)" -Fix '如确需删除，请手动确认后删除'
                } else {
                    Remove-Item -LiteralPath $hit.path -Recurse -Force -ErrorAction SilentlyContinue
                    $gone = -not (Test-Path -LiteralPath $hit.path)
                    if ($gone) {
                        $extra.purged++
                        Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'ok' `
                            -Value "已删除 · $(Format-Size $hit.bytes)" -Detail $detail -Fix ''
                    } else {
                        $extra.purgeFailed++
                        Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'bad' `
                            -Value '删除失败' -Detail "$detail。可能有文件被占用，或需要管理员。" -Fix '关闭相关程序后重试，或以管理员身份执行'
                    }
                }
            } else {
                Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'warn' `
                    -Value (Format-Size $hit.bytes) -Detail $detail `
                    -Fix $(if ($DryRun) { '确认后用 dryRun:false + purge:true 删除这个目录' } else { '需要同时给 purge:true 才会删' })
            }
        }
    }

    # ---- 4. 服务残留 ------------------------------------------------------
    $svcHits = [System.Collections.Generic.List[object]]::new()
    $svcByName = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
            (Test-Contains $_.Name $appName) -or (Test-Contains $_.DisplayName $appName)
        })
    foreach ($s in $svcByName) {
        $svcHits.Add([pscustomobject]@{ name = $s.Name; display = $s.DisplayName; status = [string]$s.Status; path = '' })
    }
    foreach ($c in (Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
        $pn = [string]$c.PathName
        if (Test-Contains $pn $appName) {
            if (-not ($svcHits | Where-Object { $_.name -eq $c.Name })) {
                $svcHits.Add([pscustomobject]@{ name = [string]$c.Name; display = [string]$c.DisplayName; status = [string]$c.State; path = $pn })
            }
        }
    }
    if ($svcHits.Count -eq 0) {
        Add-Item -List $List -Id 'softmgr:leftover-service' -Group 'leftover' -Label '服务残留' -Status 'ok' `
            -Value '0 个' -Detail "服务名、显示名与二进制路径里都没有「$appName」。" -Fix ''
    } else {
        Add-Item -List $List -Id 'softmgr:leftover-service' -Group 'leftover' -Label '服务残留' -Status 'warn' `
            -Value "$($svcHits.Count) 个" -Detail '服务不会自动删除：删服务无法由本工具回滚，且同名服务可能属于别的软件。' `
            -Fix '确认后用管理员终端执行 sc.exe delete <服务名>'
        $n = 0
        foreach ($hit in $svcHits) {
            $found++
            $n++
            Add-Item -List $List -Id "softmgr:leftover-service-$n" -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'warn' `
                -Value "$($hit.status)" `
                -Detail "服务 $($hit.name)（$($hit.display)）$(if ($hit.path) { " · $($hit.path)" })。未自动删除。" `
                -Fix "以管理员执行 sc.exe delete `"$($hit.name)`"（确认不是在用软件的服务）" -NeedsAdmin $true
        }
    }

    # ---- 5. 计划任务残留 --------------------------------------------------
    $taskHits = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { Test-Contains $_.TaskName $appName })
    if ($taskHits.Count -eq 0) {
        Add-Item -List $List -Id 'softmgr:leftover-task' -Group 'leftover' -Label '计划任务残留' -Status 'ok' `
            -Value '0 个' -Detail "任务名里没有「$appName」。" -Fix ''
    } else {
        Add-Item -List $List -Id 'softmgr:leftover-task' -Group 'leftover' -Label '计划任务残留' -Status 'warn' `
            -Value "$($taskHits.Count) 个" -Detail '计划任务不会自动删除：需要管理员，且删掉后无法由本工具恢复。' `
            -Fix '确认后用管理员执行 Unregister-ScheduledTask -TaskName <名字> -Confirm:$false'
        $n = 0
        foreach ($hit in $taskHits) {
            $found++
            $n++
            Add-Item -List $List -Id "softmgr:leftover-task-$n" -Group 'leftover' -Label (Get-ShortLabel $hit.TaskName) -Status 'warn' `
                -Value $hit.TaskPath -Detail "任务 $($hit.TaskPath)$($hit.TaskName)。未自动删除。" `
                -Fix "Unregister-ScheduledTask -TaskName `"$($hit.TaskName)`" -TaskPath `"$($hit.TaskPath)`" -Confirm:`$false" -NeedsAdmin $true
        }
    }

    # ---- 6. 启动项残留 ----------------------------------------------------
    $runHits = [System.Collections.Generic.List[object]]::new()
    foreach ($e in (Get-RunEntries)) {
        if ((Test-Contains $e.name $appName) -or (Test-Contains $e.value $appName)) {
            $runHits.Add($e)
        }
    }
    if ($runHits.Count -eq 0) {
        Add-Item -List $List -Id 'softmgr:leftover-run' -Group 'leftover' -Label '启动项残留' -Status 'ok' `
            -Value '0 个' -Detail "Run/RunOnce（含 WOW6432Node）里没有值名或数据含「$appName」的项。" -Fix ''
    } else {
        Add-Item -List $List -Id 'softmgr:leftover-run' -Group 'leftover' -Label '启动项残留' -Status 'warn' `
            -Value "$($runHits.Count) 个" -Detail '登录时自动启动的残留项，删掉不影响已安装软件。' -Fix ''
        $n = 0
        foreach ($hit in $runHits) {
            $found++
            $n++
            $iid = "softmgr:leftover-run-$n"
            if (-not ($DryRun -or -not $Purge)) {
                $bk = Backup-RegKey -KeyPath $hit.keyRegPath
                if (-not $bk.ok) {
                    $extra.purgeFailed++
                    Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'bad' `
                        -Value '未删除' -Detail "备份失败，已跳过：$($bk.error)。位置：$($hit.keyLabel)" `
                        -Fix '检查 regbackup 目录权限后重试'
                } else {
                    # 只删值，不删键：Run 键属于系统，删掉键会连别人的启动项一起没。
                    Remove-ItemProperty -LiteralPath $hit.keyPsPath -Name $hit.name -Force -ErrorAction SilentlyContinue
                    $still = Get-RegValue -Path $hit.keyPsPath -Name $hit.name
                    if ($null -eq $still) {
                        $extra.purged++
                        Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'ok' `
                            -Value '已删除' -Detail "启动项值已删除（键保留），备份：$($bk.file)" -Fix ''
                    } else {
                        $extra.purgeFailed++
                        Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'bad' `
                            -Value '删除失败' -Detail "已备份到 $($bk.file)，但值仍然存在。位置：$($hit.keyLabel)" `
                            -Fix '以管理员身份运行后再清扫'
                    }
                }
            } else {
                Add-Item -List $List -Id $iid -Group 'leftover' -Label (Get-ShortLabel $hit.name) -Status 'warn' `
                    -Value $hit.keyLabel -Detail "$($hit.name) = $($hit.value)" `
                    -Fix $(if ($DryRun) { '确认后用 dryRun:false + purge:true 删除这个启动项' } else { '需要同时给 purge:true 才会删' })
            }
        }
    }

    $extra.leftoverFound = $found
    if ($found -eq 0) {
        $messages.Add("没有找到「$appName」的残留")
    } elseif (-not $Purge) {
        $guardNote = if ($appStillInstalled) { "（注意：Uninstall 显示它仍装着，purge 时会拒删这些项）" } else { '' }
        $messages.Add("找到 $found 处残留；当前是只读扫描，未改动任何东西$guardNote")
    } elseif ($DryRun) {
        $messages.Add("找到 $found 处残留；dryRun 仍为 true，未改动任何东西")
    } else {
        $guardText = if ($appStillInstalled) { "，其中因软件仍在安装状态而拒删 $($extra.purgeSkipped) 项" } else { '' }
        $messages.Add("已删除 $($extra.purged) 项，失败 $($extra.purgeFailed) 项，拒删 $($extra.purgeSkipped) 项$guardText")
    }
    return $extra
}

# 只允许删除"五个白名单根目录的直接子目录"，且目录名含 appName。
# 任何路径异常（等于根、在 C:\Windows 下、不在白名单根下）一律拒绝并说明原因。
function Test-SafePurgePath {
    param([string]$Path)
    $r = @{ ok = $false; reason = '' }
    if (-not $Path) { $r.reason = '路径为空'; return $r }
    $full = ''
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { $r.reason = '路径无法规范化'; return $r }
    if ($full.Length -lt 4) { $r.reason = '路径过短'; return $r }
    $roots = @()
    foreach ($p in @($env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($p) { $roots += $p.TrimEnd('\') }
    }
    $winDir = $env:SystemRoot
    if ($winDir -and (Test-PathUnder -Path $full -Root $winDir)) { $r.reason = "在系统目录 $winDir 下"; return $r }
    $parent = Split-Path -Path $full -Parent
    if (-not $parent) { $r.reason = '没有父目录'; return $r }
    $parentMatch = $false
    foreach ($root in $roots) {
        if ($parent.TrimEnd('\').Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) { $parentMatch = $true; break }
    }
    if (-not $parentMatch) { $r.reason = '不是白名单根目录的直接子目录'; return $r }
    $leaf = Split-Path -Path $full -Leaf
    if (-not (Test-Contains $leaf $appName)) { $r.reason = "目录名不含「$appName」"; return $r }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { $r.reason = '不是已存在的目录'; return $r }
    $r.ok = $true
    return $r
}

# ===========================================================================
# C. migrate —— 软件搬家（只做可行性分析，绝不真搬）
# ===========================================================================
function Invoke-MigrateAction {
    param($List)
    $extra = @{ migrateName = $appName; migratePath = ''; migrateWritable = $false }
    if (-not $appName -and -not $installPath) {
        Add-Item -List $List -Id 'softmgr:migrate-input' -Group 'migrate' -Label '目标软件' -Status 'skip' `
            -Value '未提供' -Detail '需要 params.appName 或 params.installPath。' `
            -Fix '例如 {"action":"migrate","appName":"Everything"}'
        return $extra
    }
    $apps = Get-InstalledApps
    $target = Resolve-InstallTarget -Apps $apps -Name $appName -ExplicitPath $installPath
    $shownName = if ($appName) { $appName } elseif ($installPath) { Split-Path -Path $installPath.TrimEnd('\') -Leaf } else { '未知' }
    $extra.migrateName = $shownName

    if (-not $target.exists) {
        Add-Item -List $List -Id ('softmgr:migrate-' + ($shownName -replace '[^A-Za-z0-9\.\-_\u4e00-\u9fa5]', '_')) -Group 'migrate' -Label (Get-ShortLabel $shownName) -Status 'skip' `
            -Value '找不到安装目录' `
            -Detail "Uninstall 的 InstallLocation / DisplayIcon 与常见安装根目录都没定位到「$shownName」的目录。搬家必须先知道目录在哪。" `
            -Fix '改用 params.installPath 直接指定安装目录再分析'
        return $extra
    }

    $dir = $target.path
    $extra.migratePath = $dir
    $st = Get-DirStats -Path $dir

    $inPF = (Test-PathUnder -Path $dir -Root $env:ProgramFiles) -or
            (Test-PathUnder -Path $dir -Root ${env:ProgramFiles(x86)}) -or
            (Test-PathUnder -Path $dir -Root $env:ProgramData)
    $onSystemDrive = $dir.StartsWith([System.IO.Path]::GetPathRoot($env:SystemRoot), [System.StringComparison]::OrdinalIgnoreCase)

    $denyText = if ($st.denied -gt 0) { "；跳过 $($st.denied) 个无权限项" } else { '' }
    $truncText = if ($st.truncated) { '；已达枚举上限，数值是下限' } else { '' }
    Add-Item -List $List -Id ('softmgr:migrate-size-' + ($shownName -replace '[^A-Za-z0-9\.\-_\u4e00-\u9fa5]', '_')) -Group 'migrate' -Label (Get-ShortLabel $shownName) -Status 'info' `
        -Value "$(Format-Size $st.bytes) · $($st.files) 文件" `
        -Detail "目录 $dir（来源：$($target.source)），$($st.dirs) 个子目录$denyText$truncText。$(if ($inPF) { '位于受保护的系统级目录下，普通账户默认不可写。' } else { '不在 Program Files/ProgramData 下。' })$(if ($onSystemDrive) { ' 位于系统盘。' } else { ' 不在系统盘。' })" `
        -Fix ''

    # ---- 注册表里有多少处绝对路径提到它 ------------------------------------
    $refPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $apps) {
        foreach ($f in @(
                @{ n = 'InstallLocation'; v = $e.installLocation },
                @{ n = 'UninstallString'; v = $e.uninstallString },
                @{ n = 'DisplayIcon'; v = $e.displayIcon },
                @{ n = 'InstallSource'; v = $e.installSource })) {
            if ((Test-Contains $f.v $dir) -or (Test-Contains $f.v $shownName)) {
                if ($f.v) { $refPaths.Add("Uninstall\$($e.keyName).$($f.n)") }
            }
        }
    }
    $svcRefs = [System.Collections.Generic.List[object]]::new()
    foreach ($c in (Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
        if (Test-Contains ([string]$c.PathName) $dir) {
            $svcRefs.Add($c)
            $refPaths.Add("服务 $($c.Name).ImagePath")
        }
    }
    $driverRefs = [System.Collections.Generic.List[object]]::new()
    foreach ($d in (Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction SilentlyContinue)) {
        if (Test-Contains ([string]$d.PathName) $dir) {
            $driverRefs.Add($d)
            $refPaths.Add("驱动 $($d.Name).ImagePath")
        }
    }
    $taskRefs = [System.Collections.Generic.List[object]]::new()
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $hit = $false
        foreach ($a in @($t.Actions)) {
            $txt = "$($a.Execute) $($a.Arguments) $($a.WorkingDirectory)"
            if (Test-Contains $txt $dir) { $hit = $true }
        }
        if ($hit) { $taskRefs.Add($t); $refPaths.Add("计划任务 $($t.TaskPath)$($t.TaskName)") }
    }
    $lnkRefs = [System.Collections.Generic.List[string]]::new()
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnkRoots = @(
            (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
            (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
            ([Environment]::GetFolderPath('Desktop'))
        )
        $checked = 0
        foreach ($lr in $lnkRoots) {
            if (-not $lr -or -not (Test-Path -LiteralPath $lr)) { continue }
            foreach ($lnk in (Get-ChildItem -LiteralPath $lr -Recurse -Filter *.lnk -ErrorAction SilentlyContinue)) {
                if ($checked -ge 200) { break }
                $checked++
                $targetPath = ''
                try { $targetPath = [string]$shell.CreateShortcut($lnk.FullName).TargetPath } catch { continue }
                if ($targetPath -and (Test-Contains $targetPath $dir)) { $lnkRefs.Add($lnk.FullName) }
            }
        }
    } catch { }

    $totalRefs = $refPaths.Count + $lnkRefs.Count
    $refSample = ''
    if ($totalRefs -gt 0) {
        $take = @($refPaths | Select-Object -First 6)
        if ($lnkRefs.Count -gt 0) { $take += "快捷方式 $($lnkRefs.Count) 个" }
        $refSample = ($take -join '、')
    }
    Add-Item -List $List -Id 'softmgr:migrate-refs' -Group 'migrate' -Label '绝对路径引用' -Status $(if ($totalRefs -gt 0) { 'warn' } else { 'info' }) `
        -Value "$totalRefs 处" `
        -Detail "注册表/服务/任务的绝对路径：$($refPaths.Count) 处；快捷方式：$($lnkRefs.Count) 个。$(if ($refSample) { "例如 $refSample。" })搬家要改的就是这些地方，漏一处软件就打不开或者找不到自己的文件。" `
        -Fix ''

    Add-Item -List $List -Id 'softmgr:migrate-deps' -Group 'migrate' -Label '服务/驱动依赖' -Status $(if (($svcRefs.Count + $driverRefs.Count) -gt 0) { 'warn' } else { 'info' }) `
        -Value "服务 $($svcRefs.Count) · 驱动 $($driverRefs.Count) · 任务 $($taskRefs.Count)" `
        -Detail $(if (($svcRefs.Count + $driverRefs.Count) -gt 0) { "有组件以服务/驱动形式加载：$((@($svcRefs | ForEach-Object { $_.Name }) + @($driverRefs | ForEach-Object { $_.Name })) -join '、')。搬家前必须全部停止，否则文件被占用改不动。" } else { '没有服务/驱动从该目录加载，文件的占用风险较低。' }) `
        -Fix ''

    # ---- 结论行：必须写透，含糊的"有一定风险"等于没说 ----------------------
    $conclusion = (@(
            'Windows 没有"移动已安装程序"的官方机制——安装路径在安装时被写进注册表、服务 ImagePath、计划任务和快捷方式，微软只提供卸载/重装。',
            '360 的软件搬家不是"搬"，而是把目录移到新位置后在原路径建立目录联接（junction），再批量改注册表和快捷方式里的绝对路径；它之所以能成功，是因为把这几类引用都枚举全了。',
            '任何一处漏改，软件就会打不开、找不到配置文件、或者升级时把新副本装回旧盘：报错形式通常是"找不到 xxx.dll/配置无效"，而不是"搬家失败"，所以事后很难判断是搬坏的。',
            "这个软件当前有 $totalRefs 处绝对路径引用和 $($svcRefs.Count + $driverRefs.Count) 个服务/驱动依赖，改动面不小。",
            '结论：风险高于收益。同样一次操作，卸载重装能得到干净的目标路径，出问题也能回退；搬家出问题往往只能整个重装，还要先收拾残留的联接和注册表项。'
        ) -join '')
    Add-Item -List $List -Id ('softmgr:migrate-' + ($shownName -replace '[^A-Za-z0-9\.\-_\u4e00-\u9fa5]', '_')) -Group 'migrate' -Label (Get-ShortLabel $shownName) -Status 'warn' `
        -Value "$(Format-Size $st.bytes) · $totalRefs 处引用" `
        -Detail $conclusion `
        -Fix '推荐路线 (a)：卸载 → 安装时把目标目录改到目标盘 → 重装。'

    Add-Item -List $List -Id 'softmgr:migrate-path-a' -Group 'migrate' -Label '路线 A：重装' -Status 'info' `
        -Value '卸载 → 改路径 → 重装' `
        -Detail "先正常卸载（保留配置的话提前备份 %APPDATA%\$shownName 与 %LOCALAPPDATA%\$shownName），再从安装包选择目标盘目录重装。唯一能拿到干净路径的办法，也是官方支持的唯一做法。" `
        -Fix ''

    Add-Item -List $List -Id 'softmgr:migrate-path-b' -Group 'migrate' -Label '路线 B：目录联接' -Status 'info' `
        -Value 'mklink /J' `
        -Detail "若只是某个大目录（缓存/素材库）占地方，把那一个目录移到目标盘，再在原位置建联接：mklink /J `"<原路径>`" `"<新路径>`"。需要管理员，且必须先停掉服务/退出程序，否则文件被占用会搬一半。这只是绕开程序本体，并没有真的搬走已安装的程序。" `
        -Fix '以管理员执行：mklink /J "<原路径>" "<新路径>"' -NeedsAdmin $true

    $messages.Add("migrate 只做分析，没有任何写操作；目录 $dir，引用 $totalRefs 处")
    return $extra
}

# ===========================================================================
# D. perm —— 软件权限管理（只读）
# ===========================================================================
function Invoke-PermAction {
    param($List)
    $extra = @{ permName = $appName; firewallTotal = 0; firewallMatched = 0 }
    if (-not $appName -and -not $exePath) {
        Add-Item -List $List -Id 'softmgr:perm-input' -Group 'perm' -Label '目标软件' -Status 'skip' `
            -Value '未提供' -Detail '需要 params.appName 或 params.exePath。' `
            -Fix '例如 {"action":"perm","appName":"Everything"}'
        return $extra
    }
    $apps = Get-InstalledApps
    $target = Resolve-InstallTarget -Apps $apps -Name $appName -ExplicitPath ''
    $dir = $target.path
    if (-not $dir -and $exePath) { $dir = Split-Path -Path $exePath -Parent }
    $shownName = if ($appName) { $appName } else { Split-Path -Path $exePath -Leaf }
    if (-not $shownName) { $shownName = Split-Path -Path $dir -Leaf }
    $extra.permName = $shownName

    $probeExe = ''
    if ($exePath -and (Test-Path -LiteralPath $exePath)) {
        $probeExe = $exePath
    } elseif ($dir -and (Test-Path -LiteralPath $dir)) {
        $cands = @(Get-ChildItem -LiteralPath $dir -Filter *.exe -File -ErrorAction SilentlyContinue)
        $pref = @($cands | Where-Object { Test-Contains $_.BaseName $shownName })
        if ($pref.Count -gt 0) { $probeExe = $pref[0].FullName }
        elseif ($cands.Count -gt 0) { $probeExe = $cands[0].FullName }
    }
    $matchKey = if ($dir) { $dir } else { $shownName }

    # ---- 1. 防火墙规则 ----------------------------------------------------
    # 在分支外先声明：结论行要用同一个去重后的列表，分支内看不到就会退化成
    # "按配置文件展开"的 12 条，与上面展示的 2 条对不上。
    $allowInUniq = [System.Collections.Generic.List[object]]::new()
    $fw = Get-FirewallRules
    if (-not $fw.ok) {
        Add-Item -List $List -Id 'softmgr:perm-firewall' -Group 'perm' -Label '防火墙规则' -Status 'skip' `
            -Value '读取失败' -Detail "netsh 未能解析：$($fw.error)" -Fix '以管理员身份重试，或手动运行 netsh advfirewall firewall show rule name=all'
    } else {
        $extra.firewallTotal = $fw.total
        $matched = @($fw.rules | Where-Object {
                (Test-Contains $_.program $matchKey) -or (Test-Contains $_.program $shownName)
            })
        $extra.firewallMatched = $matched.Count
        if ($fw.total -eq 0) {
            Add-Item -List $List -Id 'softmgr:perm-firewall' -Group 'perm' -Label '防火墙规则' -Status 'skip' `
                -Value '解析到 0 条' -Detail 'netsh 返回了内容但没解析出规则块，可能是输出格式变了。' `
                -Fix '手动运行 netsh advfirewall firewall show rule name=all verbose 对比'
        } else {
            $enabled = @($matched | Where-Object { $_.enabled -match '^(Yes|是)$' })
            $allowIn = @($matched | Where-Object {
                    ($_.enabled -match '^(Yes|是)$') -and ($_.action -match '^(Allow|允许)$') -and ($_.direction -match '^(In|入站|入)$')
                })
            # netsh 会把同一条规则按配置文件（域/专用/公用）重复列出，一条逻辑规则能占
            # 3~6 块。按「规则名 + 程序」去重再展示，否则 8 条明细全是同一个规则。
            $allowInUniq = [System.Collections.Generic.List[object]]::new()
            $seenRule = @{}
            foreach ($r in $allowIn) {
                $k = "$($r.name)|$($r.program)".ToLowerInvariant()
                if ($seenRule.ContainsKey($k)) { continue }
                $seenRule[$k] = $true
                $allowInUniq.Add($r)
            }
            $st = 'info'
            if ($allowInUniq.Count -gt 0) { $st = 'warn' }
            Add-Item -List $List -Id 'softmgr:perm-firewall' -Group 'perm' -Label '防火墙规则' -Status $st `
                -Value "命中 $($matched.Count) 条 / 共 $($fw.total) 条" `
                -Detail "netsh 用 $($fw.ms) ms 解析出 $($fw.total) 条规则；$(if ($dir) { "路径或名字匹配「$matchKey」" } else { "按名字匹配「$shownName」" })的 $($matched.Count) 条，其中已启用 $($enabled.Count) 条、入站放行 $($allowIn.Count) 条（按配置文件展开计数），去重后是 $($allowInUniq.Count) 条不同规则。入站放行意味着别的机器能主动连进来。" `
                -Fix $(if ($allowInUniq.Count -gt 0) { '在 Windows Defender 防火墙里检查这些入站规则是否仍然必要' } else { '' })
            $n = 0
            foreach ($m in ($allowInUniq | Select-Object -First 8)) {
                $n++
                Add-Item -List $List -Id "softmgr:perm-firewall-allow-$n" -Group 'perm' -Label (Get-ShortLabel $m.name) -Status 'warn' `
                    -Value "$($m.direction) $($m.action)" -Detail "规则 $($m.name) 允许入站$(if ($m.program) { "，程序 $($m.program)" })$(if ($m.grouping) { "，组 $($m.grouping)" })。" `
                    -Fix '不再需要时在防火墙高级设置里禁用该规则'
            }
        }
    }

    # ---- 2. 是否以管理员运行（AppCompatFlags Layers） ----------------------
    $layersKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
    $layers = Get-ItemProperty -LiteralPath $layersKey -ErrorAction SilentlyContinue
    $runAsItems = [System.Collections.Generic.List[object]]::new()
    if ($layers) {
        foreach ($p in $layers.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $val = [string]$p.Value
            if (-not (Test-Contains $val 'RUNASADMIN')) { continue }
            if ((Test-Contains $p.Name $matchKey) -or (Test-Contains $p.Name $shownName) -or ($probeExe -and (Test-Contains $p.Name $probeExe))) {
                $runAsItems.Add([pscustomobject]@{ exe = $p.Name; flags = $val })
            }
        }
    }
    if ($runAsItems.Count -gt 0) {
        Add-Item -List $List -Id 'softmgr:perm-runas' -Group 'perm' -Label '以管理员运行' -Status 'warn' `
            -Value '已设置 RUNASADMIN' `
            -Detail "HKCU 的 AppCompatFlags\Layers 里为 $(($runAsItems | ForEach-Object { $_.exe }) -join '、') 设了 RUNASADMIN：每次启动都会弹 UAC 并以完整管理员令牌运行。" `
            -Fix '若软件并不需要管理员权限，去掉该标志可缩小攻击面'
    } else {
        Add-Item -List $List -Id 'softmgr:perm-runas' -Group 'perm' -Label '以管理员运行' -Status 'ok' `
            -Value '未设置' `
            -Detail 'AppCompatFlags\Layers 里没有该程序的 RUNASADMIN 标志，启动时不会自动提权。' -Fix ''
    }

    # ---- 3. 安装目录 ACL ---------------------------------------------------
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
        $aclWhy = if ($dir) { "目录 $dir 不存在（软件可能已卸载，或路径写错），无法读取 ACL。" } else { '没有找到安装目录，无法读取 ACL。' }
        $aclFix = if ($dir) { '确认该目录是否存在；软件已卸载就无需分析权限' } else { '用 params.exePath 指定程序后再分析' }
        Add-Item -List $List -Id 'softmgr:perm-acl' -Group 'perm' -Label '目录权限' -Status 'skip' `
            -Value $(if ($dir) { '目录不存在' } else { '未定位到目录' }) -Detail $aclWhy -Fix $aclFix
    } else {
        $acl = Get-Acl -LiteralPath $dir -ErrorAction SilentlyContinue
        if (-not $acl) {
            Add-Item -List $List -Id 'softmgr:perm-acl' -Group 'perm' -Label '目录权限' -Status 'skip' `
                -Value '读取失败' -Detail "Get-Acl 无法读取 $dir。" -Fix ''
        } else {
            $writers = [System.Collections.Generic.List[object]]::new()
            $broad = [System.Collections.Generic.List[string]]::new()
            $broadNames = @('Everyone', 'BUILTIN\Users', 'Users', 'NT AUTHORITY\Authenticated Users', 'Authenticated Users', 'BUILTIN\Power Users')
            foreach ($ace in @($acl.Access)) {
                if ([string]$ace.AccessControlType -ne 'Allow') { continue }
                if (-not (Test-WriteRights $ace.FileSystemRights)) { continue }
                $id = [string]$ace.IdentityReference
                $writers.Add([pscustomobject]@{ id = $id; rights = (Format-Rights $ace.FileSystemRights) })
                foreach ($b in $broadNames) {
                    if ($id.Equals($b, [System.StringComparison]::OrdinalIgnoreCase)) {
                        if (-not ($broad -contains $id)) { $broad.Add($id) }
                    }
                }
            }
            $writerText = if ($writers.Count -gt 0) { (($writers | Select-Object -First 8 | ForEach-Object { "$($_.id)($($_.rights))" }) -join '、') } else { '无' }
            if ($broad.Count -gt 0) {
                Add-Item -List $List -Id 'softmgr:perm-acl' -Group 'perm' -Label '目录权限' -Status 'warn' `
                    -Value "$($writers.Count) 个主体可写 · 含普通用户组" `
                    -Detail "$dir 上有写权限的主体：$writerText。其中 $(($broad) -join '、') 是普通用户组，任何本机用户都能改这个目录里的程序文件——替换掉 exe 就能以该用户身份执行任意代码。" `
                    -Fix '把该目录权限收紧到 Administrators/SYSTEM 写、Users 只读'
            } else {
                Add-Item -List $List -Id 'softmgr:perm-acl' -Group 'perm' -Label '目录权限' -Status 'ok' `
                    -Value "$($writers.Count) 个主体可写" `
                    -Detail "$dir 上有写权限的主体：$writerText。没有 Everyone/Users 这类普通用户组。" -Fix ''
            }
        }
    }

    # ---- 4. 开机自启 + 计划任务最高权限 ------------------------------------
    $runHits = @()
    foreach ($e in (Get-RunEntries)) {
        if ((Test-Contains $e.name $shownName) -or (Test-Contains $e.value $matchKey) -or (Test-Contains $e.name $shownName)) {
            $runHits += $e
        }
    }
    $taskHi = [System.Collections.Generic.List[object]]::new()
    foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $hit = $false
        foreach ($a in @($t.Actions)) {
            $txt = "$($a.Execute) $($a.Arguments) $($a.WorkingDirectory)"
            if ((Test-Contains $txt $matchKey) -or (Test-Contains $txt $shownName)) { $hit = $true }
        }
        if ($hit -and [string]$t.Principal.RunLevel -eq 'Highest') { $taskHi.Add($t) }
    }
    $autoSt = 'ok'
    if ($runHits.Count -gt 0 -and $taskHi.Count -gt 0) { $autoSt = 'warn' } elseif ($runHits.Count -gt 0 -or $taskHi.Count -gt 0) { $autoSt = 'info' }
    Add-Item -List $List -Id 'softmgr:perm-autostart' -Group 'perm' -Label '开机自启' -Status $autoSt `
        -Value "$($runHits.Count) 个启动项" `
        -Detail $(if ($runHits.Count -gt 0) { "Run/RunOnce 命中：$(($runHits | ForEach-Object { "$($_.keyLabel)/$($_.name)" }) -join '、')。" } else { 'Run/RunOnce 里没有它的启动项。' }) `
        -Fix $(if ($runHits.Count -gt 0) { '不需要开机自启时在任务管理器启动项里禁用' } else { '' })

    if ($taskHi.Count -gt 0) {
        Add-Item -List $List -Id 'softmgr:perm-task-highest' -Group 'perm' -Label '最高权限任务' -Status 'warn' `
            -Value "$($taskHi.Count) 个" `
            -Detail "以 Principal.RunLevel=Highest 运行、且动作指向该程序的任务：$(($taskHi | Select-Object -First 5 | ForEach-Object { $_.TaskPath + $_.TaskName }) -join '、')。这类任务每次触发都以完整管理员权限运行。" `
            -Fix '确认这些任务仍然必要；不需要时删除或把运行级别降为最低' -NeedsAdmin $true
    } else {
        Add-Item -List $List -Id 'softmgr:perm-task-highest' -Group 'perm' -Label '最高权限任务' -Status 'ok' `
            -Value '0 个' -Detail '没有以最高权限运行、且指向该程序的计划任务。' -Fix ''
    }

    # ---- 5. Defender 排除项 ------------------------------------------------
    $excl = @()
    $exclRaw = @()
    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $exclRaw = @($mp.ExclusionPath)
    } catch { }
    $needAdminText = $false
    foreach ($e in $exclRaw) { if ("$e" -match 'N/A|administrator|管理员') { $needAdminText = $true } }
    if (-not $elevated -and ($needAdminText -or $exclRaw.Count -eq 0)) {
        Add-Item -List $List -Id 'softmgr:perm-defender' -Group 'perm' -Label 'Defender 排除' -Status 'skip' `
            -Value '需要管理员' `
            -Detail "非管理员读不到 Defender 排除列表（Get-MpPreference 返回 N/A）。没有证据说明它被排除，也没有证据说明没被排除。" `
            -Fix '以管理员身份重跑才能读到排除项' -NeedsAdmin $true
    } else {
        foreach ($e in $exclRaw) {
            $v = [string]$e
            if (-not $v -or $v -match 'N/A|administrator|管理员') { continue }
            if ((Test-Contains $v $matchKey) -or (Test-Contains $v $shownName) -or ($probeExe -and (Test-Contains $v $probeExe))) {
                $excl += $v
            }
        }
        if ($excl.Count -gt 0) {
            Add-Item -List $List -Id 'softmgr:perm-defender' -Group 'perm' -Label 'Defender 排除' -Status 'warn' `
                -Value "$($excl.Count) 条命中" `
                -Detail "Defender 排除路径命中：$(($excl | Select-Object -First 5) -join '、')。该目录不参与实时扫描。" `
                -Fix '确认排除仍然必要；恶意软件最爱在这个列表里给自己留位置' -NeedsAdmin $true
        } else {
            Add-Item -List $List -Id 'softmgr:perm-defender' -Group 'perm' -Label 'Defender 排除' -Status 'ok' `
                -Value "0 条命中（共 $(@($exclRaw | Where-Object { "$_" -notmatch 'N/A' }).Count) 条排除）" `
                -Detail '该程序不在 Defender 的排除路径里。' -Fix ''
        }
    }

    # ---- 结论行 ------------------------------------------------------------
    $loose = [System.Collections.Generic.List[string]]::new()
    if ($broad.Count -gt 0) { $loose.Add("安装目录对 $(($broad) -join '/') 可写") }
    if ($runAsItems.Count -gt 0) { $loose.Add('每次启动都请求管理员权限') }
    if ($taskHi.Count -gt 0) { $loose.Add("$($taskHi.Count) 个计划任务以最高权限运行") }
    if ($excl.Count -gt 0) { $loose.Add("被 Defender 排除（$($excl.Count) 条）") }
    if ($extra.firewallMatched -gt 0 -and $allowInUniq.Count -gt 0) {
        $loose.Add("$($allowInUniq.Count) 条入站放行规则")
    }
    if ($loose.Count -eq 0) {
        Add-Item -List $List -Id 'softmgr:perm-verdict' -Group 'perm' -Label '权限结论' -Status 'ok' `
            -Value '未发现过宽' -Detail '五项检查都没有命中：无普通用户组写权限、无自动提权、无最高权限任务、无 Defender 排除、无入站放行。' -Fix ''
    } else {
        Add-Item -List $List -Id 'softmgr:perm-verdict' -Group 'perm' -Label '权限结论' -Status 'warn' `
            -Value "$($loose.Count) 处过宽" `
            -Detail ("权限过宽的地方：" + ($loose -join '；') + '。这些本身不是漏洞，但任何一条被利用都能把权限从普通用户抬到更高。') `
            -Fix '按上面各项的修复建议逐条收紧，只保留确实需要的权限'
    }

    return $extra
}

# ===========================================================================
# scan —— 不带参数时的状态总览（只读）
# ===========================================================================
function Invoke-ScanAction {
    param($List)
    $extra = @{ scanAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

    # winget
    $winget = Get-WingetPath
    if (-not $winget) {
        Add-Item -List $List -Id 'softmgr:scan-winget' -Group 'status' -Label 'winget' -Status 'skip' `
            -Value '未安装' -Detail '一键升级依赖 winget（App Installer），本机找不到。' `
            -Fix '从 Microsoft Store 安装「应用安装程序」' -NeedsAdmin $true
    } else {
        $verCap = Invoke-Capture -FilePath $winget -TimeoutMs 20000 -Arguments @('--version')
        $ver = if ($verCap.stdout) { $verCap.stdout.Trim() } else { '版本读取失败' }
        # 变量名不能叫 $list：它与参数 $List 同名（PowerShell 不区分大小写），
        # 会覆盖探针的输出列表。
        $upg = Get-WingetUpgrades
        if ($upg.ok) {
            Add-Item -List $List -Id 'softmgr:scan-winget' -Group 'status' -Label 'winget' -Status 'ok' `
                -Value "$ver · $($upg.rows.Count) 个可升级" `
                -Detail "winget 可用，枚举可升级项用 $($upg.ms) ms。一键升级默认只预演，不会自动装东西。" `
                -Fix ''
        } elseif ($upg.timedOut) {
            Add-Item -List $List -Id 'softmgr:scan-winget' -Group 'status' -Label 'winget' -Status 'skip' `
                -Value "$ver · 清单超时" -Detail 'winget upgrade 60 s 未返回。' -Fix '稍后重试'
        } else {
            Add-Item -List $List -Id 'softmgr:scan-winget' -Group 'status' -Label 'winget' -Status 'warn' `
                -Value "$ver · 清单读取失败" -Detail $upg.error -Fix '手动运行 winget upgrade 看报错'
        }
    }

    # 已安装程序
    $apps = Get-InstalledApps
    Add-Item -List $List -Id 'softmgr:scan-installed' -Group 'status' -Label '已安装程序' -Status 'info' `
        -Value "$($apps.Count) 个" `
        -Detail '来自 HKLM/HKCU 三处 Uninstall 键中带 DisplayName 的条目，残留清扫与权限分析都以它为基准。' -Fix ''

    # 防火墙
    $fw = Get-FirewallRules
    if ($fw.ok) {
        Add-Item -List $List -Id 'softmgr:scan-firewall' -Group 'status' -Label '防火墙规则' -Status 'info' `
            -Value "$($fw.total) 条" `
            -Detail "netsh 用 $($fw.ms) ms 解析出 $($fw.total) 条规则，可用于按程序查规则。$(if ($fw.timedOut) { '（本次超时，数值可能不全）' })" `
            -Fix ''
    } else {
        Add-Item -List $List -Id 'softmgr:scan-firewall' -Group 'status' -Label '防火墙规则' -Status 'skip' `
            -Value '未读取' -Detail "netsh 读取失败：$($fw.error)" -Fix '以管理员身份重试'
    }

    # 备份目录
    $rb = Get-RegBackupDir
    $rbCount = @(Get-ChildItem -LiteralPath $rb -File -ErrorAction SilentlyContinue).Count
    $rbWritable = $false
    try {
        [System.IO.Directory]::CreateDirectory($rb) | Out-Null
        $rbWritable = Test-Path -LiteralPath $rb
    } catch { }
    $rbSt = 'info'
    if (-not $rbWritable) { $rbSt = 'warn' }
    Add-Item -List $List -Id 'softmgr:scan-backup' -Group 'status' -Label '注册表备份' -Status $rbSt `
        -Value "$rbCount 个文件" `
        -Detail "备份目录 $rb$(if ($rbWritable) { '，可写' } else { '，不可写——清扫前的备份会失败，届时不会执行任何删除' })。清残留会先 reg export 到这里。$(if (-not $rbWritable) { '' } else { '本次是只读扫描，没有写任何文件。' })" `
        -Fix $(if (-not $rbWritable) { '检查该目录权限' } else { '' })

    # 能力概览（说清楚哪些是只读、哪些会写）
    Add-Item -List $List -Id 'softmgr:scan-modes' -Group 'status' -Label '默认安全' -Status 'info' `
        -Value 'dryRun=true' `
        -Detail 'upgrade 默认只列清单；leftover 默认只扫描，真删需要 dryRun:false 且 purge:true；migrate 本版纯分析、没有写路径；perm 纯只读。' `
        -Fix ''
    Add-Item -List $List -Id 'softmgr:scan-elevated' -Group 'status' -Label '管理员' -Status $(if ($elevated) { 'ok' } else { 'warn' }) `
        -Value $(if ($elevated) { '是' } else { '否' }) `
        -Detail $(if ($elevated) { '已提权：HKLM 写操作与 Defender 排除项都能读。' } else { '未提权：HKLM 下的删除会失败，Defender 排除列表读不到（会如实标 skip）。' }) `
        -Fix $(if ($elevated) { '' } else { '需要清扫 HKLM 残留或查看 Defender 排除项时，以管理员身份运行' })

    return $extra
}

# ===========================================================================
# 分发
# ===========================================================================
$extra = @{}
switch ($action) {
    'upgrade' { $extra = Invoke-UpgradeAction -List $items }
    'leftover' { $extra = Invoke-LeftoverAction -List $items -DryRun $dryRun -Purge $purge }
    'migrate' { $extra = Invoke-MigrateAction -List $items }
    'perm' { $extra = Invoke-PermAction -List $items }
    'scan' { $extra = Invoke-ScanAction -List $items }
    default {
        Add-Item -List $items -Id 'softmgr:action' -Group 'status' -Label 'action' -Status 'skip' `
            -Value $action -Detail '未知的 action。支持 scan / upgrade / leftover / migrate / perm。' `
            -Fix '把 params.action 改成受支持的值'
    }
}

$extra['action'] = $action
$extra['dryRun'] = $dryRun
$extra['purge'] = $purge
$extra['appName'] = $appName
$extra['messages'] = @($messages)
$extra['elapsedMs'] = [int]((Get-Date) - $scriptStart).TotalMilliseconds

$note = '默认 dryRun=true：upgrade 只列清单，leftover 真删还需 purge=true 且先 reg export 备份；migrate 只做分析；perm 只读。'
if ($action -eq 'leftover' -and -not $dryRun) {
    $note = "本轮 dryRun=false。删除前已逐项 reg export 备份到 $(Get-RegBackupDir)；备份失败的项一律跳过未删。服务与计划任务只报告、不代删。"
}
Write-ProbeResult -Items $items -Extra $extra -Note $note
