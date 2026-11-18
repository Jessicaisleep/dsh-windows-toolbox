param([string]$ParamFile)

# ---------------------------------------------------------------------------
# homepage.ps1 — 主页/启动页与浏览器劫持排查
#
# Three separate things are being measured, and they fail differently:
#
#   1. What the browser will actually open — IE Start/Search Page, Edge and
#      Chrome `Preferences` (homepage + session.startup_urls). The policy row
#      exists because HKLM policy Start Page OVERRIDES the user's HKCU value;
#      reporting only HKCU would tell the user a value that is not in effect.
#   2. Shortcut hijacking — a .lnk whose target or arguments carry an http(s)
#      URL. 95 .lnk files across Desktop / Public Desktop / both Start Menus
#      scanned in ~780 ms here; 0 carried a URL. This is the classic "我的浏览器
#      被改了" vector that leaves the registry untouched.
#   3. The write path — action='fix' + target + value, HKCU ONLY.
#
# Write rules (CONTRACT.md 4.2/4.3):
#   * dryRun defaults to TRUE; only an explicit dryRun:false writes.
#   * `reg export` the target key first; if that fails, ABORT and write nothing.
#   * Never `New-Item -Force` on a registry key (it wipes existing values).
#   * The only values this probe may ever write are
#     HKCU\Software\Microsoft\Internet Explorer\Main :: Start Page / Search Page.
#     target is validated against a fixed allow-list, so no caller can aim this
#     at an arbitrary registry path.
#
# Timings on this box (2026-11-17): Edge Preferences JSON parse ~206 ms for a
# 319 KB file, .lnk scan ~780 ms, all registry reads < 60 ms total.
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList

$action = [string]$params.action
if (-not $action) { $action = 'scan' }
$dryRun = $true
if ($null -ne $params.dryRun) { $dryRun = [bool]$params.dryRun }

$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
$timings = [ordered]@{}

$ieKey = 'HKCU:\Software\Microsoft\Internet Explorer\Main'
$iePolKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Internet Explorer\Main'

# ---- 1. IE home / search ---------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ieStartRaw = Get-RegValue -Path $ieKey -Name 'Start Page'
$ieSearchRaw = Get-RegValue -Path $ieKey -Name 'Search Page'
$ieStart = Format-RegValue $ieStartRaw
$ieSearch = Format-RegValue $ieSearchRaw

# A home page pointing somewhere that is not about:blank / a Microsoft URL is the
# textbook symptom of a hijack; about:blank is the Windows default.
$ieStartStatus = 'ok'
$ieStartDetail = '主页为空白页（Windows 默认）'
if ($ieStart -eq 'unset') {
    $ieStartStatus = 'skip'; $ieStartDetail = 'HKCU\...\Internet Explorer\Main 里没有 Start Page，读不到当前主页'
} elseif ($ieStart -match '^about:') {
    $ieStartStatus = 'ok'
} elseif ($ieStart -match '^https?://(www\.)?(microsoft|msn|live|bing)\.') {
    $ieStartStatus = 'info'; $ieStartDetail = '主页指向微软自家站点，属常见默认值'
} else {
    $ieStartStatus = 'warn'; $ieStartDetail = '主页被指向了非微软默认地址，可能是被改过或第三方软件设定的'
}
Add-Item -List $items -Id 'homepage:ie-start' -Group 'ie' -Label 'IE 主页' -Status $ieStartStatus `
    -Value $ieStart -Detail $ieStartDetail `
    -Fix $(if ($ieStartStatus -eq 'warn' -or $ieStartStatus -eq 'skip') { '改成 about:blank 或你自己要的站点（本探针 action=fix target=ie-start 可改，默认预演不写）' } else { '保持现状；about:blank 是 Windows 默认主页，没有被改成推广页' })

$ieSearchStatus = 'ok'
$ieSearchDetail = '搜索页为微软默认地址'
if ($ieSearch -eq 'unset') {
    $ieSearchStatus = 'skip'; $ieSearchDetail = '没有 Search Page 值，读不到当前搜索页'
} elseif ($ieSearch -notmatch 'microsoft\.com') {
    $ieSearchStatus = 'warn'; $ieSearchDetail = '搜索页被换成了非微软地址，搜索请求可能被中间人收集'
}
Add-Item -List $items -Id 'homepage:ie-search' -Group 'ie' -Label 'IE 搜索页' -Status $ieSearchStatus `
    -Value $ieSearch -Detail $ieSearchDetail `
    -Fix $(if ($ieSearchStatus -eq 'warn' -or $ieSearchStatus -eq 'skip') {
        '改回 http://go.microsoft.com/fwlink/?LinkId=54896 或你在用的搜索引擎（本探针 action=fix target=ie-search 可改）'
    } else { '保持现状；搜索页仍是微软默认地址，没有被替换成第三方搜索' })

# Policy lock: when HKLM sets Start Page, the HKCU value above is not what runs.
$iePol = Format-RegValue (Get-RegValue -Path $iePolKey -Name 'Start Page')
if ($iePol -eq 'unset') {
    Add-Item -List $items -Id 'homepage:ie-policy' -Group 'ie' -Label 'IE 主页策略锁' -Status 'ok' `
        -Value 'unset' -Detail '没有组策略覆盖，上面的 HKCU 值就是实际生效的主页' -Fix '无需处理；没有策略覆盖时 IE 会按用户自己的主页设置走'
} else {
    Add-Item -List $items -Id 'homepage:ie-policy' -Group 'ie' -Label 'IE 主页策略锁' -Status 'warn' `
        -Value "Start Page=$iePol" -Detail '组策略强制指定了主页，覆盖用户自己的设置；在策略被删掉之前改 HKCU 不会生效' `
        -Fix '删除 HKLM\SOFTWARE\Policies\Microsoft\Internet Explorer\Main 下的 Start Page（需管理员）' -NeedsAdmin $true
}
$timings['ie'] = $sw.ElapsedMilliseconds

# ---- 2. Edge / Chrome startup pages ---------------------------------------
# `Preferences` is a big JSON blob (319 KB here). ConvertFrom-Json on it costs
# ~206 ms — acceptable, but done once per browser, never in a loop.
# Missing keys are the normal case: a browser that has never had its startup
# page customised simply has no `session` key. That is NOT a read failure, so it
# reports `info` with the real reason rather than `skip`.
function Add-BrowserStartup {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Id,
        [string]$Label,
        [string]$PrefPath
    )
    if (-not (Test-Path -LiteralPath $PrefPath)) {
        Add-Item -List $List -Id $Id -Group 'browser' -Label $Label -Status 'skip' `
            -Value '未安装' -Detail "找不到 $PrefPath，$Label 未安装或从未启动过" -Fix '若确实要用这个浏览器，启动一次后重跑本探针即可读到启动页；不需要就不用管'
        return
    }
    try {
        $pref = Get-Content -LiteralPath $PrefPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Add-Item -List $List -Id $Id -Group 'browser' -Label $Label -Status 'skip' `
            -Value '解析失败' -Detail "$Label 的 Preferences 不是合法 JSON：$($_.Exception.Message)" -Fix '关掉浏览器后重跑本探针；若仍失败，可能是配置被写坏，删除该 Preferences 文件后浏览器会重建默认配置'
        return
    }
    # NOT $home: `$HOME` is an automatic READ-ONLY variable holding the user's
    # profile path. Assigning to it fails silently under $ErrorActionPreference =
    # 'SilentlyContinue', leaving the profile path in the variable — the first
    # version of this function reported "homepage=C:\Users\<user>" because of it.
    $homePage = ''
    if ($pref.PSObject.Properties.Name -contains 'homepage') { $homePage = [string]$pref.homepage }
    $urls = @()
    if ($pref.session -and $pref.session.PSObject.Properties.Name -contains 'startup_urls') {
        $urls = @($pref.session.startup_urls | Where-Object { $_ })
    }
    $hasHome = ($homePage -ne '')
    $hasUrls = ($urls.Count -gt 0)

    if (-not $hasHome -and -not $hasUrls) {
        Add-Item -List $List -Id $Id -Group 'browser' -Label $Label -Status 'info' `
            -Value '未自定义启动页' -Detail "$Label 的 Preferences 里没有 homepage / session.startup_urls，启动时按默认新标签页打开" -Fix '无需处理；没有自定义启动页说明没有被改成推广页'
        return
    }
    $parts = @()
    if ($hasHome) { $parts += "homepage=$homePage" }
    if ($hasUrls) { $parts += "启动页=$($urls -join ' , ')" }
    $value = $parts -join ' · '

    # Same hijack heuristic as IE: anything that is not a well-known search /
    # portal / about: page is worth flagging.
    $suspects = @()
    foreach ($u in @($urls + @($homePage))) {
        if (-not $u) { continue }
        if ($u -match '^about:') { continue }
        if ($u -match '^https?://(www\.)?(google|bing|microsoft|msn|live|baidu|so|duckduckgo|yandex)\.') { continue }
        if ($u -match '^https?://') { $suspects += $u }
    }
    if ($suspects.Count -gt 0) {
        Add-Item -List $List -Id $Id -Group 'browser' -Label $Label -Status 'warn' `
            -Value $value -Detail "启动页里有非常见门户地址：$($suspects -join ' , ')。浏览器启动页不会写注册表，只能改配置文件，所以劫持常藏在这里" `
            -Fix "在 $Label 设置 > 启动时 里删掉不认识的页面"
    } else {
        Add-Item -List $List -Id $Id -Group 'browser' -Label $Label -Status 'ok' `
            -Value $value -Detail '启动页指向常见的门户/搜索站点' -Fix '保持现状；启动页指向常见门户说明没有被改成推广页'
    }
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Add-BrowserStartup -List $items -Id 'homepage:edge-startup' -Label 'Edge 启动页' `
    -PrefPath (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Preferences')
Add-BrowserStartup -List $items -Id 'homepage:chrome-startup' -Label 'Chrome 启动页' `
    -PrefPath (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Preferences')
$timings['browserprefs'] = $sw.ElapsedMilliseconds

# ---- 3. Shortcut hijack scan ----------------------------------------------
# Recursive on purpose: Start Menu shortcuts live in per-app subfolders, and the
# non-recursive version of this scan misses nearly all of them (4 found vs 95).
# desktop.ini is skipped explicitly even though it is not a .lnk, because some
# hijackers rename their payload to it.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lnkRoots = @()
foreach ($folder in @('Desktop', 'CommonDesktopDirectory', 'StartMenu', 'CommonStartMenu')) {
    $p = [Environment]::GetFolderPath($folder)
    if ($p -and (Test-Path -LiteralPath $p)) { $lnkRoots += $p }
}
$lnkRoots = @($lnkRoots | Select-Object -Unique)

$lnkScanned = 0
$lnkHits = New-ProbeList
$lnkError = ''
$shell = $null
try { $shell = New-Object -ComObject WScript.Shell -ErrorAction Stop }
catch { $lnkError = $_.Exception.Message }

if (-not $shell) {
    Add-Item -List $items -Id 'homepage:lnk-scan' -Group 'shortcut' -Label '快捷方式扫描' -Status 'skip' `
        -Value '无法创建 WScript.Shell' -Detail $lnkError -Fix ''
} elseif ($lnkRoots.Count -eq 0) {
    Add-Item -List $items -Id 'homepage:lnk-scan' -Group 'shortcut' -Label '快捷方式扫描' -Status 'skip' `
        -Value '找不到扫描目录' -Detail '桌面与开始菜单路径都不可读' -Fix ''
} else {
    foreach ($root in $lnkRoots) {
        $files = @(Get-ChildItem -LiteralPath $root -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            if ($f.Name -ieq 'desktop.ini') { continue }
            $lnkScanned++
            try { $sc = $shell.CreateShortcut($f.FullName) } catch { continue }
            # `$args` is an automatic variable too — keep it out of the way for the
            # same reason as $HOME above.
            $lnkTarget = [string]$sc.TargetPath
            $lnkArgs = [string]$sc.Arguments
            if ("$lnkTarget $lnkArgs" -match 'https?://') {
                $lnkHits.Add([ordered]@{
                    id         = "homepage:lnk:$lnkScanned"
                    group      = 'shortcut'
                    label      = $f.Name
                    status     = 'bad'
                    value      = $(if ($lnkArgs) { "$lnkTarget $lnkArgs" } else { $lnkTarget })
                    detail     = $f.FullName
                    fix        = '删除这个快捷方式，并在确认原程序没被替换后再重建'
                    needsAdmin = $false
                })
            }
        }
    }
    if ($lnkHits.Count -eq 0) {
        Add-Item -List $items -Id 'homepage:lnk-scan' -Group 'shortcut' -Label '快捷方式扫描' -Status 'ok' `
            -Value "扫描 $lnkScanned 个 .lnk · 0 个含网址" `
            -Detail "目录：$($lnkRoots -join ' ; ')。快捷方式的目标或参数里没有 http/https，没有被改写去打开某个网址" -Fix '保持现状；扫到的快捷方式里没有带网址的目标或参数'
    } else {
        Add-Item -List $items -Id 'homepage:lnk-scan' -Group 'shortcut' -Label '快捷方式扫描' -Status 'bad' `
            -Value "扫描 $lnkScanned 个 .lnk · $($lnkHits.Count) 个含网址" `
            -Detail '有快捷方式的目标或参数里带 http/https 地址，点击会打开被指定的页面' `
            -Fix '检查下面列出的每个快捷方式，删掉被改过的那个'
    }
    foreach ($h in $lnkHits) { $items.Add($h) }
}
$timings['shortcuts'] = $sw.ElapsedMilliseconds

# ---- 4. Default browser ----------------------------------------------------
# UserChoice is a hash-protected key; we only READ the ProgId. It cannot be
# written programmatically on Win10+ without breaking the hash, so this probe
# deliberately offers no fix beyond sending the user to Settings.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$progId = Format-RegValue (Get-RegValue -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice' -Name 'ProgId')
$progName = switch -Regex ($progId) {
    '^MSEdge' { 'Microsoft Edge' }
    '^ChromeHTML' { 'Google Chrome' }
    '^FirefoxURL' { 'Mozilla Firefox' }
    '^IE\.' { 'Internet Explorer' }
    '^BraveHTML' { 'Brave' }
    '^OperaStable' { 'Opera' }
    '^360' { '360 浏览器' }
    '^QQBrowser' { 'QQ 浏览器' }
    default { $progId }
}
Add-Item -List $items -Id 'homepage:default-browser' -Group 'browser' -Label '默认浏览器' -Status 'info' `
    -Value "$progName（$progId）" -Detail 'UserChoice 带哈希校验，只能通过 设置 > 应用 > 默认应用 修改，写注册表会被系统重置' `
    -Fix $(if ($progId -eq 'unset') { '未读到 UserChoice，可在 设置 > 应用 > 默认应用 里指定' } else { '无需处理；想换默认浏览器去 设置 > 应用 > 默认应用 改，写注册表会被系统哈希校验重置' })
$timings['defaultbrowser'] = $sw.ElapsedMilliseconds

# ---- 5. write path (HKCU IE only, dryRun by default) ----------------------
$changed = 0
$backupFiles = New-ProbeList
$backupError = ''
$writeError = ''
# Join-Path validates the DRIVE and returns $null under SilentlyContinue when the
# drive does not exist, which made an unwritable backup target look like a
# missing %LOCALAPPDATA%. Plain concatenation keeps the real path so New-Item /
# reg export can fail with their own, accurate error.
$backupDir = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA.TrimEnd('\') + '\dsh-windows-toolbox\regbackup' } else { '' }

# The allow-list is the whole safety story here: a target string can only ever
# resolve to one of these two value names inside ONE fixed key.
$writeTargets = @{
    'ie-start'  = @{ name = 'Start Page'; label = 'IE 主页' }
    'ie-search' = @{ name = 'Search Page'; label = 'IE 搜索页' }
}

if ($action -eq 'fix') {
    $target = [string]$params.target
    $newValue = [string]$params.value

    if (-not $writeTargets.ContainsKey($target)) {
        Add-Item -List $items -Id 'homepage:write' -Group 'write' -Label '写入设置' -Status 'skip' `
            -Value '未执行' -Detail "target='$target' 不在允许列表内；只允许 ie-start / ie-search" `
            -Fix '调用时传 target=ie-start 或 ie-search' -NeedsAdmin $false
    } elseif ([string]::IsNullOrWhiteSpace($newValue)) {
        Add-Item -List $items -Id 'homepage:write' -Group 'write' -Label '写入设置' -Status 'skip' `
            -Value '未执行' -Detail 'value 为空，没有可写入的内容' -Fix '传一个非空的网址' -NeedsAdmin $false
    } elseif ($newValue.Length -gt 2048 -or $newValue -match '[\x00-\x1f\x7f]') {
        # The whole C0 block plus DEL. An earlier version excluded \x0a/\x0d
        # (thinking of text files) and let "about:`nblank" through into the
        # registry — a URL there has no legitimate newline, so nothing is exempt.
        Add-Item -List $items -Id 'homepage:write' -Group 'write' -Label '写入设置' -Status 'skip' `
            -Value '未执行' -Detail 'value 超长或含控制字符，拒绝写入' -Fix '传一个正常长度的网址' -NeedsAdmin $false
    } elseif ($dryRun) {
        $t = $writeTargets[$target]
        Add-Item -List $items -Id 'homepage:write' -Group 'write' -Label '写入设置' -Status 'info' `
            -Value '将执行（预演）' `
            -Detail "把 $ieKey 的 $($t.name) 从当前值 '$ieStart' 改为 '$newValue'；当前 dryRun=true，没有写入任何内容" `
            -Fix '' -NeedsAdmin $false
    } else {
        $t = $writeTargets[$target]
        # Backup first, and fail closed: a write we cannot back up is a write we
        # do not make (CONTRACT.md 4.3).
        if (-not $backupDir) {
            $backupError = '%LOCALAPPDATA% 为空，无法确定备份目录'
        } else {
        try {
            if (-not (Test-Path -LiteralPath $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction Stop | Out-Null
            }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $regPath = 'HKCU\Software\Microsoft\Internet Explorer\Main'
            $outFile = Join-Path $backupDir "$stamp-ie-main.reg"
            & reg export $regPath $outFile /y 2>&1 | Out-Null
            # File existence alone is not proof: reg.exe writes nothing and returns
            # 1 when the key is unreadable. Check the exit code too.
            if ($LASTEXITCODE -ne 0) {
                $backupError = "reg export 返回 $LASTEXITCODE（$regPath）"
            } elseif (-not (Test-Path -LiteralPath $outFile)) {
                $backupError = "reg export 没有生成文件：$outFile"
            } else {
                $backupFiles.Add($outFile)
            }
        } catch {
            $backupError = $_.Exception.Message
        }
        }

        if ($backupError) {
            Add-Item -List $items -Id 'homepage:write' -Group 'write' -Label '写入设置' -Status 'bad' `
                -Value '已中止' -Detail "无法备份注册表（$backupError），没有写入任何内容" `
                -Fix '检查 %LOCALAPPDATA% 是否可写后重试' -NeedsAdmin $false
        } else {
            try {
                # *** Never New-Item -Force on an existing key: it wipes values. ***
                if ($null -eq (Get-Item -LiteralPath $ieKey -ErrorAction SilentlyContinue)) {
                    New-Item -Path $ieKey -ErrorAction Stop | Out-Null
                }
                New-ItemProperty -LiteralPath $ieKey -Name $t.name -Value $newValue -PropertyType String -Force -ErrorAction Stop | Out-Null
                $changed = 1
                Add-Item -List $items -Id 'homepage:write' -Group 'write' -Label '写入设置' -Status 'ok' `
                    -Value "已写入 $($t.name)" -Detail "新值：$newValue · 备份：$($backupFiles[0])" -Fix '' -NeedsAdmin $false
            } catch {
                $writeError = $_.Exception.Message
                Add-Item -List $items -Id 'homepage:write' -Group 'write' -Label '写入设置' -Status 'bad' `
                    -Value '写入失败' -Detail "$writeError（备份已在 $($backupFiles[0])，可用它还原）" -Fix '' -NeedsAdmin $false
            }
        }
    }
}

$swTotal.Stop()

Write-ProbeResult -Items $items -Extra @{
    action      = $action
    dryRun      = $dryRun
    changed     = $changed
    probeMs     = [int64]$swTotal.ElapsedMilliseconds
    timings     = $timings
    lnkScanned  = $lnkScanned
    lnkHits     = $lnkHits.Count
    lnkRoots    = @($lnkRoots)
    backupDir   = $backupDir
    backups     = @($backupFiles.ToArray())
} -Note $(if ($action -ne 'fix') { '只读扫描：没有写入任何内容。' }
         elseif ($dryRun) { '预演：没有写入任何内容（要真写需显式传 dryRun=false）。' }
         else { '写操作已完成，修改前的注册表已导出到 backups 里的文件。' })
