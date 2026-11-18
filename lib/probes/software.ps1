# software.ps1 — 软件清单探针（只读，不安装不卸载任何东西）。
#
# 三组数据：
#   a) 已安装程序 — 三个 Uninstall 根（HKLM 64 位 / HKLM WOW6432Node / HKCU）。
#      114 条有 DisplayName 的是真实程序，另外 15 个只有 UninstallString 的存根
#      跳过（它们不是用户能看见的软件）。
#   b) 软件目录匹配 — 拿 lib\presets\softwares.json 里的 uninstallMatch 去匹配
#      DisplayName，算出"装了哪些 / 还差哪些"。
#   c) 可升级 — winget upgrade。用 upgrade 而不是 `list --upgrade-available`：
#      本机实测 upgrade 只要 968ms，list --upgrade-available 要 9310ms。
#
# 为什么不对 114 条程序各做一行：面板表格会被撑爆且没有信息增量。这里做分组
# 统计 + 只把关键条目（可升级的每一条、目录里未装的推荐 10 个）铺开。
#
# 只读。
param([string]$ParamFile)

# Node 按 UTF-8 读 stdout；不写这行 PowerShell 用控制台代码页（936/GBK）编码，
# 中文到上层就是乱码。
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items  = New-ProbeList
$sw     = [System.Diagnostics.Stopwatch]::StartNew()

# winget 的硬超时。默认 20s，params.wingetTimeoutMs 可覆盖。
$wingetTimeoutMs = 20000
if ($params -and $params.PSObject.Properties['wingetTimeoutMs']) {
    $t = 0
    if ([int]::TryParse([string]$params.wingetTimeoutMs, [ref]$t) -and $t -ge 3000 -and $t -le 120000) { $wingetTimeoutMs = $t }
}

# ---------------------------------------------------------------------------
# a) 已安装程序：三个 Uninstall 根
# ---------------------------------------------------------------------------
$roots = @(
    @{ path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';            scope = 'HKLM 64位' },
    @{ path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; scope = 'HKLM 32位' },
    @{ path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall';            scope = 'HKCU 当前用户' }
)

$progs   = @()
$stubs   = 0
$rootHits = [ordered]@{}

foreach ($r in $roots) {
    $n = 0
    # 这里对"可能不存在"的注册表键用一次 Test-Path 是必要的：Get-ChildItem 本身
    # 会报错，而 ErrorAction SilentlyContinue 下无法区分"空"和"不存在"。三个根
    # 都是固定路径、只查 3 次，不会踩到 387ms 的性能坑。
    $exists = Test-Path -LiteralPath $r.path
    if (-not $exists) { $rootHits[$r.scope] = 0; continue }
    foreach ($k in (Get-ChildItem -LiteralPath $r.path -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $p) { continue }
        $name = [string]$p.DisplayName
        if (-not $name) { $stubs++; continue }
        $n++

        # SystemComponent=1 的条目是系统内部组件，正常不在"应用和功能"里显示；
        # 这里仍然计入（用户搜得到它们），但标注出来。
        $sysComp = $false
        if ($null -ne $p.SystemComponent -and [int]$p.SystemComponent -eq 1) { $sysComp = $true }

        $sizeMb = 0
        if ($null -ne $p.EstimatedSize) {
            try { $sizeMb = [math]::Round(([int64]$p.EstimatedSize) / 1024, 1) } catch { $sizeMb = 0 }
        }

        $progs += [ordered]@{
            name      = $name
            version   = [string]$p.DisplayVersion
            publisher = [string]$p.Publisher
            installDate = [string]$p.InstallDate
            sizeMb    = $sizeMb
            location  = [string]$p.InstallLocation
            scope     = $r.scope
            systemComponent = $sysComp
            key       = $k.PSChildName
        }
    }
    $rootHits[$r.scope] = $n
}

$installedCount = @($progs).Count

if ($installedCount -eq 0) {
    Add-Item -List $items -Id 'software:installed' -Group '已安装程序' -Label '已安装程序总数' -Status 'skip' `
        -Detail '三个 Uninstall 注册表根都读不到条目，无法统计已安装程序（可能是注册表不可读）' `
        -Fix '确认当前账户能读取 HKLM/HKCU 的 Uninstall 键后重跑探针'
} else {
    $withVer = @($progs | Where-Object { $_.version }).Count
    $withDate = @($progs | Where-Object { $_.installDate -match '^\d{8}$' })
    $withDateCount = $withDate.Count
    $sysCompCount = @($progs | Where-Object { $_.systemComponent }).Count
    $partText = (@($rootHits.Keys | ForEach-Object { '{0} {1}' -f $_, $rootHits[$_] }) -join '、')
    Add-Item -List $items -Id 'software:installed' -Group '已安装程序' -Label '已安装程序总数' -Status 'info' `
        -Value ("{0} 条" -f $installedCount) `
        -Detail ("按注册表根拆分：{0}；其中 {1} 条有版本号，{2} 条有安装日期，{3} 条标了 SystemComponent（系统内部组件）；另有 {4} 个只有卸载命令、没有 DisplayName 的存根已跳过" -f $partText, $withVer, $withDateCount, $sysCompCount, $stubs)
}

# 最近安装的 5 个：安装日期是可排序的真实字段，用来回答"最近装了什么"。
$recent = @($progs | Where-Object { $_.installDate -match '^\d{8}$' } | Sort-Object -Property { $_.installDate } -Descending | Select-Object -First 5)
if ($recent.Count -gt 0) {
    $lines = @()
    foreach ($r in $recent) {
        $d = $r.installDate
        $shown = '{0}-{1}-{2}' -f $d.Substring(0, 4), $d.Substring(4, 2), $d.Substring(6, 2)
        $lines += ('{0}（{1}，{2}）' -f $r.name, $(if ($r.version) { $r.version } else { '版本未知' }), $shown)
    }
    Add-Item -List $items -Id 'software:recent' -Group '已安装程序' -Label '最近安装的 5 个' -Status 'info' `
        -Value $recent[0].name -Detail (($lines) -join '；')
}

# 有安装目录但目录已经不存在 → 典型的卸载残留，值得报出来。
$staleDirs = @()
foreach ($p in $progs) {
    $loc = [string]$p.location
    if (-not $loc) { continue }
    $loc = $loc.Trim().Trim('"')
    if ($loc.Length -lt 4) { continue }
    if ($loc -notmatch '^[A-Za-z]:\\') { continue }
    # 文件系统 Test-Path 很便宜（≈1.6ms），只查前 60 条，避免极端机器上拖慢。
    if ($staleDirs.Count -ge 60) { break }
    $staleDirs += $p
}
$stale = @($staleDirs | Where-Object { -not (Test-Path -LiteralPath ([string]$_.location).Trim().Trim('"')) })
if ($staleDirs.Count -gt 0) {
    if ($stale.Count -eq 0) {
        Add-Item -List $items -Id 'software:stale' -Group '已安装程序' -Label '残留的安装目录' -Status 'ok' `
            -Value '0 条' -Detail ("检查了 {0} 条带安装路径的程序，目录都还在" -f $staleDirs.Count)
    } else {
        $lines = @()
        foreach ($s in ($stale | Select-Object -First 8)) { $lines += ('{0} → {1}' -f $s.name, $s.location) }
        Add-Item -List $items -Id 'software:stale' -Group '已安装程序' -Label '残留的安装目录' -Status 'warn' `
            -Value ("{0} 条" -f $stale.Count) `
            -Detail ("{0}；这些程序在注册表里还登记着安装路径，但目录已经不在了（多半是手动删过文件夹，或卸载没清干净）" -f ($lines -join '；')) `
            -Fix '确认不再使用后，在「设置 → 应用」里卸载，或用 Windows 安装程序的修复/卸载清掉注册表残留'
    }
}

# ---------------------------------------------------------------------------
# b) 软件目录匹配
# ---------------------------------------------------------------------------
$catalogPath = Join-Path $PSScriptRoot '..\presets\softwares.json'
if ($params -and $params.PSObject.Properties['catalogPath'] -and $params.catalogPath) {
    $catalogPath = [string]$params.catalogPath
}

$catalog    = $null
$catalogErr = ''
if (-not (Test-Path -LiteralPath $catalogPath)) {
    $catalogErr = "目录文件不存在：$catalogPath"
} else {
    try {
        $raw = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 -ErrorAction Stop
        $catalog = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $catalogErr = "目录文件解析失败：$($_.Exception.Message)"
    }
}

$catalogTotal   = 0
$matchedEntries = @()
$missingEntries = @()
if ($null -eq $catalog -or -not $catalog.PSObject.Properties['softwares']) {
    if (-not $catalogErr) { $catalogErr = '目录文件里没有 softwares 数组' }
    Add-Item -List $items -Id 'software:catalog' -Group '软件目录' -Label '软件目录匹配' -Status 'skip' `
        -Detail ("{0}；跳过目录匹配（已安装程序的统计不受影响）" -f $catalogErr) `
        -Fix '确认 lib\presets\softwares.json 存在且是合法 JSON；或用 params.catalogPath 指定别的目录文件'
} else {
    $swList = @($catalog.softwares)
    $catalogTotal = $swList.Count

    # DisplayName 先小写一次，避免 N×M 次重复转小写。
    $lowerNames = @($progs | ForEach-Object { ([string]$_.name).ToLowerInvariant() })

    foreach ($s in $swList) {
        $pats = @($s.uninstallMatch | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
        if ($pats.Count -eq 0) {
            # 没有匹配规则的条目直接算未安装，并在汇总里说明，不静默丢弃。
            $missingEntries += [ordered]@{ id = [string]$s.id; name = [string]$s.name; category = [string]$s.category; hit = $null; noRule = $true }
            continue
        }
        $hit = $null
        for ($i = 0; $i -lt $lowerNames.Count; $i++) {
            foreach ($pat in $pats) {
                if ($lowerNames[$i].Contains($pat)) { $hit = $progs[$i]; break }
            }
            if ($hit) { break }
        }
        $entry = [ordered]@{
            id       = [string]$s.id
            name     = [string]$s.name
            nameEn   = [string]$s.nameEn
            category = [string]$s.category
            winget   = [string]$s.winget
            homepage = [string]$s.homepage
            downloadPage = [string]$s.downloadPage
            hit      = $hit
            noRule   = $false
        }
        if ($hit) { $matchedEntries += $entry } else { $missingEntries += $entry }
    }

    $matchedCount = $matchedEntries.Count
    $missingCount = $missingEntries.Count

    if ($matchedCount -gt 0) {
        # 按类别归类写进 detail，比平铺一堆名字好读。
        $byCat = @{}
        foreach ($m in $matchedEntries) {
            $c = [string]$m.category
            if (-not $c) { $c = 'others' }
            if (-not $byCat.ContainsKey($c)) { $byCat[$c] = @() }
            $ver = ''
            if ($m.hit -and $m.hit.version) { $ver = ' ' + $m.hit.version }
            $byCat[$c] += ('{0}（{1}{2}）' -f $m.name, [string]$m.hit.name, $ver)
        }
        $catNames = [ordered]@{}
        if ($catalog.PSObject.Properties['categories']) {
            foreach ($cp in $catalog.categories.PSObject.Properties) { $catNames[$cp.Name] = [string]$cp.Value.zh }
        }
        $catText = @()
        foreach ($c in ($byCat.Keys | Sort-Object)) {
            $label = $catNames[$c]
            if (-not $label) { $label = $c }
            $catText += ('{0}：{1}' -f $label, ($byCat[$c] -join '、'))
        }
        Add-Item -List $items -Id 'software:catalog-installed' -Group '软件目录' `
            -Label ("目录内已安装（共 {0} 款）" -f $matchedCount) -Status 'info' `
            -Value ("{0} 款" -f $matchedCount) `
            -Detail (($catText) -join '；')
    } else {
        Add-Item -List $items -Id 'software:catalog-installed' -Group '软件目录' -Label '目录内已安装' -Status 'info' `
            -Value '0 款' -Detail '软件目录里的 uninstallMatch 一条都没匹配到已安装程序的 DisplayName'
    }

    Add-Item -List $items -Id 'software:catalog-missing' -Group '软件目录' `
        -Label ("目录内未安装（共 {0} 款）" -f $missingCount) -Status 'info' `
        -Value ("{0} 款" -f $missingCount) `
        -Detail ("软件目录共 {0} 款，已装 {1} 款，未装 {2} 款；未装的常用软件在下面挑 10 个列出，其余完整清单见 softwares.json" -f $catalogTotal, $matchedCount, $missingCount)

    # 未装里挑 10 个推荐。先用一份人工优先级（常用/必装），不够再按类别顺序补齐。
    $preferKeys = @('微信', 'WPS', 'Chrome', 'Visual Studio Code', '7-Zip', 'Everything',
                    'PotPlayer', 'Bitwarden', '网易云音乐', 'ToDesk', 'Firefox', 'Bandizip',
                    'Notepad++', 'Docker', 'Snipaste', 'PowerToys')
    $picked = @()
    $pickedIds = @{}
    foreach ($k in $preferKeys) {
        if ($picked.Count -ge 10) { break }
        foreach ($m in $missingEntries) {
            if ($pickedIds.ContainsKey($m.id)) { continue }
            $nm = ([string]$m.name) + ' ' + ([string]$m.nameEn)
            if ($nm.IndexOf($k, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $picked += $m
                $pickedIds[$m.id] = $true
                break
            }
        }
    }
    if ($picked.Count -lt 10) {
        foreach ($m in $missingEntries) {
            if ($picked.Count -ge 10) { break }
            if ($pickedIds.ContainsKey($m.id)) { continue }
            $picked += $m
            $pickedIds[$m.id] = $true
        }
    }

    $n = 0
    foreach ($m in $picked) {
        $n++
        $dl = [string]$m.downloadPage
        if (-not $dl) { $dl = [string]$m.homepage }
        Add-Item -List $items -Id ("software:recommend-{0:D2}" -f $n) -Group '软件推荐' `
            -Label ("{0}（{1}）" -f $m.name, $(if ($m.category) { $m.category } else { '未分类' })) -Status 'info' `
            -Value $(if ($m.winget) { $m.winget } else { '无 winget 包名' }) `
            -Detail ("未安装。{0}{1}" -f $(if ($dl) { "官网：$dl" } else { '目录里没登记官网地址' }), $(if ($m.noRule) { '；该条目没有 uninstallMatch 规则，只能按名字判断' } else { '' })) `
            -Fix $(if ($dl) { "从官网下载安装：$dl" } else { "用 winget 安装：winget install --id $($m.winget)" })
    }
}

# ---------------------------------------------------------------------------
# c) 可升级：winget upgrade（不用 list --upgrade-available，慢 10 倍）
# ---------------------------------------------------------------------------
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
if (-not $wingetCmd) {
    Add-Item -List $items -Id 'software:upgradable' -Group '可升级' -Label '可升级软件' -Status 'skip' `
        -Detail '未安装 winget（Windows 的「应用安装程序」App Installer 缺失），无法检查可升级软件' `
        -Fix '从 Microsoft Store 安装「应用安装程序 / App Installer」，或从 https://aka.ms/getwinget 下载安装'
} else {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'winget'
    # 用参数数组，不拼字符串：winget 的 --include-unknown 之类不需要 shell 解释。
    foreach ($a in @('upgrade', '--include-unknown', '--accept-source-agreements', '--disable-interactivity')) {
        $psi.ArgumentList.Add($a)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    # 必须显式指定 UTF-8：winget 按 UTF-8 输出，默认按控制台代码页解会乱码。
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.StandardErrorEncoding  = New-Object System.Text.UTF8Encoding $false

    $proc    = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $wkOut   = ''
    $wkErr   = ''
    $timedOut = $false
    $wkStart = $sw.ElapsedMilliseconds
    try {
        $null = $proc.Start()
        # 先挂异步读，再 WaitForExit：否则输出超过缓冲区会死锁。
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($wingetTimeoutMs)) {
            $timedOut = $true
            try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
        } else {
            $null = $outTask.Wait(5000)
            $null = $errTask.Wait(5000)
            $wkOut = [string]$outTask.Result
            $wkErr = [string]$errTask.Result
        }
    } catch {
        $wkErr = [string]$_.Exception.Message
    }
    $wkMs = $sw.ElapsedMilliseconds - $wkStart
    $wkExit = -1
    try { if (-not $timedOut) { $wkExit = [int]$proc.ExitCode } } catch { }

    # 没有可用升级时 winget 返回 0x8A15002B（无匹配应用）；那是"正常但没结果"，
    # 不是失败。用十进制比，方便阅读。
    $noUpgradeCodes = @(0, -1978335189, -1978335212)

    if ($timedOut) {
        Add-Item -List $items -Id 'software:upgradable' -Group '可升级' -Label '可升级软件' -Status 'skip' `
            -Detail ("winget upgrade 超过 {0} 秒仍未返回，已强制终止（和「未安装 winget」是两回事，winget 本身存在）" -f [int]($wingetTimeoutMs / 1000)) `
            -Fix '手动在 PowerShell 里跑 winget upgrade --include-unknown 看是否卡在源更新上；可先执行 winget source update'
    } else {
        $lines = @()
        if ($wkOut) { $lines = @($wkOut -split "`r?`n") }

        $rows = @()
        $sawHeader = $false
        foreach ($ln in $lines) {
            $t = ([string]$ln).Trim()
            if (-not $t) { continue }
            # 分隔线（全横线，可能带空格）
            if ($t -match '^[-\s]+$') { continue }
            # 表头行
            if ($t -match '^Name\s+ID\s+Version' -or $t -match '^名称\s+ID\s+版本') { $sawHeader = $true; continue }
            # 末尾汇总行
            if ($t -match '升级可用' -or $t -match 'upgrades available' -or $t -match 'upgrade available') { continue }
            if ($t -match '^没有找到' -or $t -match 'No installed package') { continue }
            # 进度/提示噪音
            if ($t -match '^\s*[\\|/-]\s*$' -or $t -match '^已尝试' -or $t -match '正在尝试') { continue }

            # 不能只按"连续 2 个以上空格"切：名称列宽度固定，名称一长就把列间
            # 填充吃光了。本机实测这两行整行只剩单空格分隔：
            #   Microsoft Visual C++ 2015-2022 Redistributable (x86) - 14.42.34438
            #   Microsoft.VCRedist.2015+.x86 14.42.34438.0 14.52.37029.0 winget
            # 所以按空白全切，再从右往左回推：源 / 可用 / 当前 / ID，剩下的算名称。
            $tok1 = @([regex]::Split($t, '\s+') | Where-Object { $_ -ne '' })
            if ($tok1.Count -lt 4) { continue }
            $isVer = {
                param([string]$s)
                if (-not $s) { return $false }
                if ($s -match '^\d+(\.\d+)*$') { return $true }
                if ($s -eq 'Unknown' -or $s -eq '未知') { return $true }
                return $false
            }
            $idx = $tok1.Count - 1
            $src = ''
            # 末尾的源列（winget / msstore / store / 空）不是版本号时先摘掉。
            if (-not (& $isVer $tok1[$idx])) { $src = [string]$tok1[$idx]; $idx-- }
            if ($idx -lt 3) { continue }
            $avail   = [string]$tok1[$idx]; $idx--
            $current = [string]$tok1[$idx]; $idx--
            $pkgId   = [string]$tok1[$idx]; $idx--
            if (-not (& $isVer $avail) -or -not (& $isVer $current)) { continue }
            # ID 里不会出现空格，但必须有"厂商.包名"的形状，否则是名称被截断的残片。
            if ($pkgId -notmatch '\.' -or $pkgId -match '^\d') { continue }
            $nameParts = @()
            for ($i = 0; $i -le $idx; $i++) { $nameParts += [string]$tok1[$i] }
            $pkgName = ($nameParts -join ' ').Trim()
            if (-not $pkgName) { $pkgName = $pkgId }
            $rows += [ordered]@{
                name = $pkgName; id = $pkgId; current = $current; available = $avail; source = $src
            }
        }

        $upCount = $rows.Count
        if ($upCount -eq 0) {
            if ($noUpgradeCodes -contains $wkExit) {
                Add-Item -List $items -Id 'software:upgradable' -Group '可升级' -Label '可升级软件' -Status 'ok' `
                    -Value '0 个' -Detail ("winget 退出码 {0}，没有可升级的程序（耗时 {1}ms）" -f $wkExit, $wkMs)
            } else {
                Add-Item -List $items -Id 'software:upgradable' -Group '可升级' -Label '可升级软件' -Status 'skip' `
                    -Detail ("winget upgrade 没有解析出任何数据行，退出码 {0}{1}；耗时 {2}ms" -f $wkExit, $(if ($wkErr) { "，stderr: " + $wkErr.Trim() } else { '' }), $wkMs) `
                    -Fix '手动跑 winget upgrade --include-unknown 看真实输出；若源未配置好，先执行 winget source update'
            }
        } else {
            Add-Item -List $items -Id 'software:upgradable' -Group '可升级' -Label '可升级软件汇总' -Status 'warn' `
                -Value ("{0} 个" -f $upCount) `
                -Detail ("winget upgrade 报告 {0} 个可升级（耗时 {1}ms）。逐条升级：winget upgrade --id <包 ID>；全部升级：winget upgrade --all" -f $upCount, $wkMs) `
                -Fix 'winget upgrade --all --include-unknown 一次性升级；升级前确认没有正在运行的程序占用文件'

            foreach ($r in $rows) {
                # id 用 winget 包 ID，保证唯一且能直接拿去 upgrade。
                $safe = ($r.id -replace '[^A-Za-z0-9\.\-_]', '_')
                Add-Item -List $items -Id ("software:upgradable-{0}" -f $safe) -Group '可升级' `
                    -Label $r.name -Status 'warn' `
                    -Value ("{0} → {1}" -f $r.current, $r.available) `
                    -Detail ("winget 包 ID：{0}；来源：{1}" -f $r.id, $(if ($r.source) { $r.source } else { '未知' })) `
                    -Fix ("升级：winget upgrade --id {0}" -f $r.id)
            }
        }
    }
}

$elapsed = $sw.ElapsedMilliseconds
$note = ("软件探针完成：已安装程序 {0} 条（跳过 {1} 个无名字存根），软件目录 {2} 款（已装 {3}），可升级见 software:upgradable；winget 硬超时 {4}s。耗时 {5}ms。" -f `
    $installedCount, $stubs, $catalogTotal, $matchedEntries.Count, [int]($wingetTimeoutMs / 1000), $elapsed)

Write-ProbeResult -Items $items -Extra @{
    installedCount = $installedCount
    stubCount      = $stubs
    catalogTotal   = $catalogTotal
    catalogMatched = $matchedEntries.Count
    elapsedMs      = $elapsed
} -Note $note
