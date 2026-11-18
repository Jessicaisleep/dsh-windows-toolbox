# repair.ps1 - 「系统修复」板块的检测/修复探针（对照 360 安全卫士的「系统修复」）。
#
# 与其余 11 个 source 不同，这里查的不是「注册点」，而是「配置漂移」：每一项都是
#
#   assert（这项本来应该是什么样）→ detect（现在实测是什么样）→ fix（怎么无损地改回去）
#
# 八项固定输出八行，行形与 featurelib 族完全一致：
#   { id, group, label, status, value, detail, fix, needsAdmin }
#
# 参数（全部可选）：
#   action = scan | fix   默认 scan。scan 只读；fix 才会走到写路径（无感修复）。
#   dryRun = true | false 默认 true。fix + dryRun=false 才真的写盘/写注册表。
#   ids    = string[]     只修这些 id；缺省 = 全部可修项。
#
# 写路径的三条硬约束（全部来自本插件踩过的坑）：
#   * 默认 dryRun；非 dryRun 前先用 reg export 把整键备份到
#     %LOCALAPPDATA%\dsh-windows-toolbox\regbackup\，备份失败即中止，不写。
#   * 绝不对已存在的注册表键用 New-Item -Force（会重建键、丢弃全部值与子键）。
#     本文件只用 Set-ItemProperty / Remove-ItemProperty，从不建键。
#   * 需要管理员的写（HKLM）在未提权时直接 skip 并说明，不做半截写。
#
# 不做需要重启 / DISM / 分区操作的修复：UAC 改动要注销才生效，字体缓存要停服务，
# 图标缓存要重启资源管理器——这三项只检测，fix 字段写清人工步骤。

param([string]$ParamFile)

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile

# ---- parameters -----------------------------------------------------------
$action = 'scan'
if ($params -and $params.action) {
    $a = ([string]$params.action).Trim().ToLowerInvariant()
    if ($a -eq 'fix') { $action = 'fix' }
}
$dryRun = $true
if ($params -and $null -ne $params.dryRun) { $dryRun = [bool]$params.dryRun }

$onlyIds = @()
if ($params -and $params.ids) {
    $onlyIds = @($params.ids | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

$fixMode = ($action -eq 'fix')
$ALL_IDS = @('hosts', 'ie', 'dns', 'netconn', 'uac', 'redundant', 'fontcache', 'iconcache')
$fixIds = @()
if ($fixMode) {
    if ($onlyIds.Count -gt 0) { $fixIds = $onlyIds } else { $fixIds = $ALL_IDS }
}

$elevated = Test-Elevated
$items    = New-ProbeList
$timings  = [ordered]@{}

function Test-FixWanted {
    param([string]$Id)
    if (-not $fixMode) { return $false }
    return ($fixIds -contains $Id)
}

# ---- backup helpers -------------------------------------------------------
$BACKUP_DIR = Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox\regbackup'

function New-BackupStamp {
    return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

# Export a whole registry key. Returns the file path, or $null when the export
# did not happen - callers must abort their write on $null (same contract as
# actions.ps1's Backup-FirewallRules).
function Backup-RegKey {
    param([string]$RegPath)

    if (-not (Test-Path -LiteralPath $BACKUP_DIR)) {
        New-Item -ItemType Directory -Path $BACKUP_DIR -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Test-Path -LiteralPath $BACKUP_DIR)) { return $null }

    $stamp = New-BackupStamp
    $safe  = ($RegPath -replace '[\\/:*?"<>|]', '_')
    $file  = Join-Path $BACKUP_DIR ("$stamp-" + $safe + '.reg')

    & reg export $RegPath $file /y 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return $file
}

# Copy a file into the backup directory. Used by the hosts item, whose only
# automatic repair is a lossless snapshot (content is never rewritten).
function Backup-File {
    param([string]$Path, [string]$Name)

    if (-not (Test-Path -LiteralPath $BACKUP_DIR)) {
        New-Item -ItemType Directory -Path $BACKUP_DIR -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not (Test-Path -LiteralPath $BACKUP_DIR)) { return $null }

    $stamp = New-BackupStamp
    $dest  = Join-Path $BACKUP_DIR ("$Name" + '.' + $stamp + '.bak')
    Copy-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $dest)) { return $null }
    return $dest
}

# ---- small parsers --------------------------------------------------------

# Pull the executable out of a command line as written in Run / RunOnce /
# UninstallString. Handles the quoted form ("C:\a b\x.exe" /flag) and the
# unquoted form (C:\a b\x.exe -flag) by cutting right after the extension.
function Get-ExeFromCommand {
    param([string]$Command)
    if (-not $Command) { return '' }
    $c = [System.Environment]::ExpandEnvironmentVariables($Command.Trim())
    # DisplayIcon carries a ",<index>" suffix; it is not part of the path.
    $c = ($c -replace ',\s*-?\d+\s*$', '').Trim()
    if (-not $c) { return '' }

    if ($c.StartsWith('"')) {
        $end = $c.IndexOf('"', 1)
        if ($end -le 1) { return '' }
        $q = $c.Substring(1, $end - 1)
        # A quoted icon/bitmap is not an executable: report nothing so the
        # caller can fall back to UninstallString instead of judging a false path.
        if ($q -match '(?i)\.(ico|png|bmp|jpg|jpeg|gif|svg)$') { return '' }
        return $q
    }

    $m = [regex]::Match($c, '^(?<p>[^"].+?\.(exe|com|bat|cmd|dll|ps1|vbs|lnk|scr))(\s|,|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups['p'].Value }
    if ($c -match '(?i)\.(ico|png|bmp|jpg|jpeg|gif|svg)$') { return '' }
    # Last resort: an extension we do not recognise. Take the first token, which
    # is right for "msiexec.exe /I{...}" but wrong for an unquoted path with
    # spaces - those are filtered out by the caller via Test-ExeExists' $null.
    return (($c -split '\s+')[0])
}

# $true / $false, or $null when the target cannot be judged (empty, a bare file
# name we cannot resolve, or a path the ACL refuses to let us look at).
# $null is reported as "unjudged", never as dead.
function Test-ExeExists {
    param([string]$Path)

    if (-not $Path) { return $null }
    $p = [System.Environment]::ExpandEnvironmentVariables($Path.Trim())
    if (-not $p) { return $null }
    if ($p.StartsWith('"')) { $p = $p.Trim('"') }
    if ($p -match ',\s*-?\d+$') { $p = ($p -split ',')[0].Trim() }
    if (-not $p) { return $null }

    if ($p -match '^[A-Za-z]:[\\/]' -or $p.StartsWith('\\\\')) {
        # Test-Path on a path under a protected directory throws
        # UnauthorizedAccessException instead of returning $false. That is
        # "cannot look", not "does not exist" - return $null so the caller
        # reports an unjudged entry rather than a healthy program as dead.
        try { return (Test-Path -LiteralPath $p -ErrorAction Stop) } catch { return $null }
    }
    # Bare name or relative path: Windows resolves those from System32 and the
    # Windows directory. Probing those two beats claiming a healthy entry dead.
    foreach ($base in @((Join-Path $env:SystemRoot 'System32'), $env:SystemRoot)) {
        if (-not $base) { continue }
        try {
            if (Test-Path -LiteralPath (Join-Path $base $p) -ErrorAction Stop) { return $true }
        } catch { return $null }
    }
    return $false
}

function Get-UrlHostName {
    param([string]$Url)
    if (-not $Url) { return '' }
    $u = $null
    if ([System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$u) -and $u) {
        return $u.Host.ToLowerInvariant()
    }
    return ''
}

function Test-TrustedHost {
    param([string]$HostName)
    if (-not $HostName) { return $false }
    $h = $HostName.ToLowerInvariant()
    $suffixes = @('microsoft.com', 'bing.com', 'msn.com', 'live.com', 'windows.com', 'windowsupdate.com', 'office.com')
    foreach ($s in $suffixes) {
        if ($h -eq $s -or $h.EndsWith('.' + $s)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# 1. hosts 文件
# ---------------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsStatus = 'skip'
$hostsValue = ''
$hostsDetail = '期望：hosts 只含注释与用户自己的本地映射，没有把厂商域名指走的改写。'
$hostsFix = '把 hosts 原样快照到 %LOCALAPPDATA%\dsh-windows-toolbox\regbackup\（无损，不删改任何条目）。'
$hostsAdmin = $false
$hostsBytes = 0
$activeCount = 0
$blockedCount = 0
$redirectCount = 0
$badHosts = @()

try {
    $hostsItem = Get-Item -LiteralPath $hostsPath -ErrorAction Stop
    $hostsBytes = [int64]$hostsItem.Length
    $lines = @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop)
    foreach ($line in $lines) {
        $t = ([string]$line).Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('#')) { continue }
        $t = ($t -split '\s+#')[0].Trim()
        if (-not $t) { continue }
        $parts = @($t -split '\s+')
        if ($parts.Count -lt 2) { continue }
        $ip = $parts[0]
        $names = @($parts[1..($parts.Count - 1)])

        # The stock localhost lines are not an anomaly; anything else pointed at
        # a loopback/0.0.0.0 address is a block, and any other address is a
        # redirect away from the real host.
        $isLoop = ($ip -eq '0.0.0.0' -or $ip -eq '127.0.0.1' -or $ip -eq '::1' -or $ip -eq '::')
        $allLocalNames = $true
        foreach ($n in $names) {
            if ($n -notmatch '^(localhost|localhost\.localdomain|broadcasthost|ip6-localhost|ip6-loopback|local)$') {
                $allLocalNames = $false
            }
        }
        $activeCount++
        if ($isLoop) {
            if (-not $allLocalNames) { $blockedCount++; $badHosts += ("$ip " + ($names -join ' ')) }
        } else {
            $redirectCount++
            $badHosts += ("$ip " + ($names -join ' '))
        }
    }

    $hostsStatus = 'ok'
    if ($redirectCount -gt 0) { $hostsStatus = 'bad' }
    elseif ($blockedCount -gt 0) { $hostsStatus = 'warn' }

    $hostsValue = "$activeCount 条有效 / $hostsBytes B"
    $hostsDetail = "期望：hosts 只含注释与用户自己的本地映射，没有把厂商域名指走的改写。实测：有效条目 $activeCount 条，其中屏蔽 $blockedCount 条、重定向 $redirectCount 条。"
    if ($badHosts.Count -gt 0) {
        $sample = @($badHosts | Select-Object -First 5) -join '; '
        $hostsDetail += " 异常：$sample"
        if ($badHosts.Count -gt 5) { $hostsDetail += " 等 $($badHosts.Count) 条" }
    }

    if (Test-FixWanted -Id 'hosts') {
        if ($dryRun) {
            $hostsDetail += " | dryRun：将把 hosts 快照到 regbackup 目录，不改动任何条目。"
        } else {
            $bak = Backup-File -Path $hostsPath -Name 'hosts'
            if ($bak) {
                $hostsValue += " | 已快照 $(Split-Path -Leaf $bak)"
                $hostsDetail += " | 已快照：$bak（原文件未改动）。"
            } else {
                $hostsFix = '快照失败（Copy-Item 或备份目录不可写），已中止，hosts 未被改动。'
                $hostsDetail += " | 快照失败：备份目录 $BACKUP_DIR 不可写。"
            }
        }
    }
    if (-not (Test-Path -LiteralPath $hostsPath)) { $hostsStatus = 'skip' }
} catch {
    $hostsStatus = 'skip'
    $hostsDetail = "无法读取 $hostsPath：$($_.Exception.GetType().Name)。"
}
$timings['hosts'] = $sw.ElapsedMilliseconds
Add-Item -List $items -Id 'hosts' -Group '网络与名称解析' -Label 'hosts 文件异常' `
    -Status $hostsStatus -Value $hostsValue -Detail $hostsDetail -Fix $hostsFix -NeedsAdmin $hostsAdmin

# ---------------------------------------------------------------------------
# 2. IE 浏览器设置
# ---------------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ieKey = 'HKCU:\Software\Microsoft\Internet Explorer\Main'
$ieReg = 'HKCU\Software\Microsoft\Internet Explorer\Main'
$ieStatus = 'skip'
$ieValue = ''
$ieDetail = '期望：Start Page = about:blank（或用户自设页），Search Page / Default_Page_URL 指向微软域。'
$ieFix = '把 Start Page 改回 about:blank（HKCU，写前 reg export 备份整键）。'
$ieProps = $null
try { $ieProps = Get-ItemProperty -LiteralPath $ieKey -ErrorAction Stop } catch { $ieProps = $null }

if ($null -eq $ieProps) {
    $ieStatus = 'skip'
    $ieDetail = "无法读取 $ieKey（键不存在或无权限）。"
} else {
    $ieCount = @($ieProps.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }).Count
    $startPage = [string]$ieProps.'Start Page'
    $searchPage = [string]$ieProps.'Search Page'
    $defaultPage = [string]$ieProps.'Default_Page_URL'
    $localPage = [string]$ieProps.'Local Page'

    $drift = @()
    $hijack = $false

    if ($startPage) {
        if ($startPage -eq 'about:blank') {
            # normal
        } else {
            $sh = Get-UrlHostName -Url $startPage
            if (-not $sh) { $drift += "Start Page=$startPage" }
            elseif (-not (Test-TrustedHost -HostName $sh)) { $hijack = $true; $drift += "Start Page=$startPage" }
        }
    }
    if ($searchPage -and $searchPage -ne 'about:blank') {
        $sh = Get-UrlHostName -Url $searchPage
        if ($sh -and -not (Test-TrustedHost -HostName $sh)) { $drift += "Search Page=$searchPage" }
    }
    if ($defaultPage -and $defaultPage -ne 'about:blank') {
        $sh = Get-UrlHostName -Url $defaultPage
        if ($sh -and -not (Test-TrustedHost -HostName $sh)) { $drift += "Default_Page_URL=$defaultPage" }
    }

    $ieStatus = 'ok'
    if ($hijack) { $ieStatus = 'bad' }
    elseif ($drift.Count -gt 0) { $ieStatus = 'warn' }

    $ieValue = "$ieCount 个值 / Start=$($startPage -replace '^\s*$','(未设置)')"
    $ieDetail = "期望：Start Page = about:blank（或用户自设页），Search Page / Default_Page_URL 指向微软域。实测：主键 $ieCount 个值，Start Page=$startPage，Search Page=$searchPage，Local Page=$localPage。"
    if ($drift.Count -gt 0) { $ieDetail += " 漂移：$($drift -join '; ')" }

    # Parenthesised on purpose: in command-argument mode `-and` would be parsed
    # as a parameter of Test-FixWanted and the whole condition silently dropped.
    if ((Test-FixWanted -Id 'ie') -and $ieStatus -ne 'ok') {
        if ($dryRun) {
            $ieDetail += " | dryRun：将把 Start Page 写回 about:blank（其余值不动）。"
        } else {
            $bak = Backup-RegKey -RegPath $ieReg
            if (-not $bak) {
                $ieFix = '备份失败（reg export），已中止写入，注册表未被改动。'
                $ieDetail += " | 备份失败，已中止写入。"
            } else {
                Set-ItemProperty -LiteralPath $ieKey -Name 'Start Page' -Value 'about:blank' -ErrorAction SilentlyContinue
                $after = [string](Get-RegValue -Path $ieKey -Name 'Start Page')
                if ($after -eq 'about:blank') {
                    $ieStatus = 'ok'
                    $ieValue = "$ieCount 个值 / Start=about:blank（已修复）"
                    $ieDetail += " | 已把 Start Page 写回 about:blank，备份：$bak"
                } else {
                    $ieDetail += " | 写入后读回仍为 $after，备份：$bak"
                }
            }
        }
    }
}
$timings['ie'] = $sw.ElapsedMilliseconds
Add-Item -List $items -Id 'ie' -Group '浏览器' -Label 'IE 浏览器设置被篡改' `
    -Status $ieStatus -Value $ieValue -Detail $ieDetail -Fix $ieFix -NeedsAdmin $false

# ---------------------------------------------------------------------------
# 3. DNS 设置
# ---------------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dnsRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
$dnsStatus = 'skip'
$dnsValue = ''
$dnsDetail = '期望：所有启用网卡要么用 DHCP 下发的 DNS，要么用常见公共 DNS；没有指向非常见地址的静态配置。'
$dnsFix = '把静态 DNS 改回自动获取（Set-DnsClientServerAddress，需要管理员）。'
$COMMON_DNS = @(
    '223.5.5.5', '223.6.6.6', '119.29.29.29', '114.114.114.114', '114.114.115.115',
    '180.76.76.76', '8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '9.9.9.9',
    '208.67.222.222', '208.67.220.220'
)

$ifaces = @(Get-ChildItem -LiteralPath $dnsRoot -ErrorAction SilentlyContinue)
if ($ifaces.Count -eq 0) {
    $dnsStatus = 'skip'
    $dnsDetail = "无法枚举 $dnsRoot 下的网络接口。"
} else {
    $staticList = @()
    $dhcpCount = 0
    foreach ($ifc in $ifaces) {
        $ns = [string](Get-RegValue -Path $ifc.PSPath -Name 'NameServer')
        $dh = [string](Get-RegValue -Path $ifc.PSPath -Name 'DhcpNameServer')
        if ($ns -and $ns.Trim()) { $staticList += [ordered]@{ guid = $ifc.PSChildName; servers = $ns.Trim() } }
        elseif ($dh -and $dh.Trim()) { $dhcpCount++ }
    }

    $odd = @()
    foreach ($s in $staticList) {
        foreach ($one in @($s.servers -split '[\s,;]+')) {
            $ip = $one.Trim()
            if (-not $ip) { continue }
            if ($COMMON_DNS -contains $ip) { continue }
            if ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|127\.)') { continue }
            $odd += "$($s.guid)=$ip"
        }
    }

    $dnsStatus = 'ok'
    if ($odd.Count -gt 0) { $dnsStatus = 'warn' }
    $dnsValue = "静态 $($staticList.Count) / 共 $($ifaces.Count) 个接口"
    $dnsDetail = "期望：所有启用网卡要么用 DHCP 下发的 DNS，要么用常见公共 DNS。实测：注册表共 $($ifaces.Count) 个接口，静态配置 DNS 的 $($staticList.Count) 个，DHCP 下发 DNS 的 $dhcpCount 个。"
    if ($staticList.Count -gt 0) {
        $shown = @($staticList | ForEach-Object { "$($_.guid)=$($_.servers)" }) -join '; '
        $dnsDetail += " 静态：$shown"
    }
    if ($odd.Count -gt 0) { $dnsDetail += " 非常见地址：$($odd -join '; ')" }
    $dnsDetail += ' 未做可达性探测，只比对地址是否属于常见公共 DNS 或内网段。'
}
$timings['dns'] = $sw.ElapsedMilliseconds
Add-Item -List $items -Id 'dns' -Group '网络与名称解析' -Label 'DNS 设置异常' `
    -Status $dnsStatus -Value $dnsValue -Detail $dnsDetail -Fix $dnsFix -NeedsAdmin $true

# ---------------------------------------------------------------------------
# 4. 网络连接数限制
# ---------------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$tcpKeys = @(
    @{ ps = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters';  reg = 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' },
    @{ ps = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'; reg = 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' }
)
$LIMIT_NAMES = @('TcpNumConnections', 'MaxUserPort', 'TcpTimedWaitDelay', 'MaxConnections', 'TcpMaxHalfOpen', 'TcpMaxHalfOpenRetried')
$limitHits = @()
$limitKeyRead = 0
foreach ($tk in $tcpKeys) {
    foreach ($n in $LIMIT_NAMES) {
        $v = Get-RegValue -Path $tk.ps -Name $n
        if ($null -ne $v -and "$v" -ne '') {
            $limitHits += [ordered]@{ key = $tk.reg; name = $n; value = [string]$v; psPath = $tk.ps }
        }
    }
    $limitKeyRead++
}

$netStatus = 'ok'
$netValue = '0 个被改写的连接数限制'
$netDetail = '期望：TCP 连接数相关值不存在（Windows 默认值即可）。实测：TcpNumConnections / MaxUserPort / TcpTimedWaitDelay / MaxConnections / TcpMaxHalfOpen / TcpMaxHalfOpenRetried 全部未设置。'
$netFix = '删除这些值即可回到系统默认（HKLM，写前 reg export 备份）。'
if ($limitKeyRead -eq 0) {
    $netStatus = 'skip'
    $netDetail = '无法读取 Tcpip\Parameters 注册表键。'
} elseif ($limitHits.Count -gt 0) {
    $netStatus = 'warn'
    $netValue = "$($limitHits.Count) 个被改写的连接数限制"
    $shown = @($limitHits | ForEach-Object { "$($_.name)=$($_.value)" }) -join '; '
    $netDetail = "期望：TCP 连接数相关值不存在（Windows 默认值即可）。实测：$shown。"

    if (Test-FixWanted -Id 'netconn') {
        if (-not $elevated) {
            $netDetail += ' | 未提权，跳过修复（写 HKLM 需要管理员）。'
        } elseif ($dryRun) {
            $netDetail += " | dryRun：将删除 $($limitHits.Count) 个值（写前 reg export 备份）。"
        } else {
            $removed = 0
            $failed = @()
            foreach ($h in $limitHits) {
                $bak = Backup-RegKey -RegPath $h.key
                if (-not $bak) { $failed += "$($h.name)（备份失败）"; continue }
                Remove-ItemProperty -LiteralPath $h.psPath -Name $h.name -ErrorAction SilentlyContinue
                if ($null -eq (Get-RegValue -Path $h.psPath -Name $h.name)) { $removed++ }
                else { $failed += "$($h.name)（删除后仍在）" }
            }
            $netValue = "已删除 $removed 个被改写的连接数限制"
            $netDetail += " | 已删除 $removed 个值。"
            if ($failed.Count -gt 0) { $netDetail += " 未成功：$($failed -join '; ')" ; $netStatus = 'warn' }
            else { $netStatus = 'ok' }
        }
    }
}
$timings['netconn'] = $sw.ElapsedMilliseconds
Add-Item -List $items -Id 'netconn' -Group '网络与名称解析' -Label '网络连接数限制' `
    -Status $netStatus -Value $netValue -Detail $netDetail -Fix $netFix -NeedsAdmin $true

# ---------------------------------------------------------------------------
# 5. UAC 设置
# ---------------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$enableLua = Get-RegValue -Path $uacKey -Name 'EnableLUA'
$consent   = Get-RegValue -Path $uacKey -Name 'ConsentPromptBehaviorAdmin'
$secureDesk = Get-RegValue -Path $uacKey -Name 'PromptOnSecureDesktop'
$filterAdm = Get-RegValue -Path $uacKey -Name 'FilterAdministratorToken'

$uacStatus = 'ok'
$uacDetail = ''
$uacFix = '把 EnableLUA 写回 1、ConsentPromptBehaviorAdmin 写回 5（写前 reg export 备份，改动需注销或重启才生效）。'
$uacValue = "EnableLUA=$(Format-RegValue $enableLua) / ConsentPromptBehaviorAdmin=$(Format-RegValue $consent)"

if ($null -eq $enableLua -and $null -eq $consent) {
    $uacStatus = 'skip'
    $uacDetail = "无法读取 $uacKey 下的 UAC 值。"
} else {
    $notes = @()
    if ($null -eq $enableLua) { $uacStatus = 'bad'; $notes += 'EnableLUA 未设置（UAC 关闭）' }
    elseif ([string]$enableLua -ne '1') { $uacStatus = 'bad'; $notes += "EnableLUA=$enableLua（UAC 未启用）" }

    if ($null -eq $consent) {
        if ($uacStatus -eq 'ok') { $uacStatus = 'warn' }
        $notes += 'ConsentPromptBehaviorAdmin 未设置'
    } else {
        $c = [string]$consent
        if ($c -eq '0') {
            $uacStatus = 'bad'
            $notes += 'ConsentPromptBehaviorAdmin=0（提权不提示）'
        } elseif ($c -eq '5' -or $c -eq '2') {
            # 5 = 默认（仅对非 Windows 二进制弹窗），2 = 最严（始终在安全桌面确认）
        } else {
            if ($uacStatus -eq 'ok') { $uacStatus = 'warn' }
            $notes += "ConsentPromptBehaviorAdmin=$c（非 5/2 的非常规档）"
        }
    }

    if ($null -ne $secureDesk -and [string]$secureDesk -eq '0') {
        if ($uacStatus -eq 'ok') { $uacStatus = 'warn' }
        $notes += 'PromptOnSecureDesktop=0（确认框不在安全桌面）'
    }

    $uacDetail = "期望：EnableLUA=1，ConsentPromptBehaviorAdmin=5（默认）或 2（最严），PromptOnSecureDesktop=1。实测：EnableLUA=$(Format-RegValue $enableLua)，ConsentPromptBehaviorAdmin=$(Format-RegValue $consent)，PromptOnSecureDesktop=$(Format-RegValue $secureDesk)，FilterAdministratorToken=$(Format-RegValue $filterAdm)。"
    if ($notes.Count -gt 0) { $uacDetail += " 偏差：$($notes -join '; ')" }
    $uacDetail += ' FilterAdministratorToken 为 0/未设置是 Windows 默认（内置管理员不过滤），不算漂移。'
    if (Test-FixWanted -Id 'uac') {
        $uacDetail += ' | 未执行自动修复：UAC 改动需要注销或重启才生效，本板块不做需要重启的修复。'
    }
}
$timings['uac'] = $sw.ElapsedMilliseconds
Add-Item -List $items -Id 'uac' -Group '系统策略' -Label 'UAC 设置' `
    -Status $uacStatus -Value $uacValue -Detail $uacDetail -Fix $uacFix -NeedsAdmin $true

# ---------------------------------------------------------------------------
# 6. 注册表冗余项（启动项 / 卸载项里的死路径）
# ---------------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$runKeys = @(
    @{ ps = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              reg = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              scope = 'machine' },
    @{ ps = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';          reg = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';          scope = 'machine' },
    @{ ps = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';  reg = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';  scope = 'machine' },
    @{ ps = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              reg = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';              scope = 'user' },
    @{ ps = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';          reg = 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';          scope = 'user' }
)
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)

$startupTotal = 0
$deadStartup = @()
foreach ($rk in $runKeys) {
    $props = Get-ItemProperty -LiteralPath $rk.ps -ErrorAction SilentlyContinue
    if ($null -eq $props) { continue }
    foreach ($p in $props.PSObject.Properties) {
        if ($p.Name -like 'PS*') { continue }
        $startupTotal++
        $exe = Get-ExeFromCommand -Command ([string]$p.Value)
        $exists = Test-ExeExists -Path $exe
        if ($exists -eq $false) {
            $deadStartup += [ordered]@{
                name = $p.Name; data = [string]$p.Value; exe = $exe
                psPath = $rk.ps; regKey = $rk.reg; scope = $rk.scope
            }
        }
    }
}

$uninstallTotal = 0
$deadUninstall = @()
foreach ($root in $uninstallRoots) {
    foreach ($sub in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $uninstallTotal++
        $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }
        $label = [string]$props.DisplayName
        if (-not $label) { continue }

        $target = ''
        if ($props.DisplayIcon) { $target = Get-ExeFromCommand -Command ([string]$props.DisplayIcon) }
        if (-not $target -and $props.UninstallString) { $target = Get-ExeFromCommand -Command ([string]$props.UninstallString) }
        if (-not $target) { continue }
        if ($target -match '(?i)\.(ico|png|bmp|jpg)$') { continue }

        $exists = Test-ExeExists -Path $target
        if ($exists -eq $false) {
            $deadUninstall += [ordered]@{ name = $label; target = $target; key = $sub.PSChildName }
        }
    }
}

$redStatus = 'ok'
$redValue = "启动项 $startupTotal 条（死路径 $($deadStartup.Count)）/ 卸载项 $uninstallTotal 个（死路径 $($deadUninstall.Count)）"
$redDetail = "期望：每个启动项与卸载项都指向一个实际存在的可执行文件。实测：枚举 $startupTotal 条启动项、$uninstallTotal 个卸载项。"
$redFix = '删除指向不存在文件的启动项值（写前 reg export 备份；HKLM 需要管理员）。卸载项只报告，不删除。'
if ($deadStartup.Count -gt 0 -or $deadUninstall.Count -gt 0) {
    $redStatus = 'warn'
    if ($deadStartup.Count -gt 0) {
        $s = @($deadStartup | ForEach-Object { "$($_.name) -> $($_.exe)" }) -join '; '
        $redDetail += " 死启动项：$s。"
    }
    if ($deadUninstall.Count -gt 0) {
        $s = @($deadUninstall | ForEach-Object { "$($_.name) -> $($_.target)" }) -join '; '
        $redDetail += " 死卸载项：$s。"
    }
    if ($deadStartup.Count -eq 0) { $redStatus = 'info' }
}

if ($startupTotal -eq 0 -and $uninstallTotal -eq 0) {
    $redStatus = 'skip'
    $redDetail = '无法枚举启动项与卸载项注册表键。'
}

if ((Test-FixWanted -Id 'redundant') -and $deadStartup.Count -gt 0) {
    $needAdmin = @($deadStartup | Where-Object { $_.scope -eq 'machine' }).Count -gt 0
    if ($needAdmin -and -not $elevated) {
        $redDetail += ' | 未提权，跳过修复（删除 HKLM 启动项需要管理员）。'
    } elseif ($dryRun) {
        $redDetail += " | dryRun：将删除 $($deadStartup.Count) 个死启动项值（写前 reg export 备份）。"
    } else {
        $removed = 0
        $failed = @()
        foreach ($d in $deadStartup) {
            $bak = Backup-RegKey -RegPath $d.regKey
            if (-not $bak) { $failed += "$($d.name)（备份失败）"; continue }
            Remove-ItemProperty -LiteralPath $d.psPath -Name $d.name -ErrorAction SilentlyContinue
            $still = Get-RegValue -Path $d.psPath -Name $d.name
            if ($null -eq $still) { $removed++ } else { $failed += "$($d.name)（删除后仍在）" }
        }
        $redValue = "已删除 $removed 个死启动项 / 卸载项死路径 $($deadUninstall.Count) 个（未删除）"
        $redDetail += " | 已删除 $removed 个死启动项值。"
        if ($failed.Count -gt 0) { $redDetail += " 未成功：$($failed -join '; ')"; $redStatus = 'warn' }
        else { $redStatus = 'ok' }
    }
}
$timings['redundant'] = $sw.ElapsedMilliseconds
Add-Item -List $items -Id 'redundant' -Group '系统策略' -Label '注册表冗余项' `
    -Status $redStatus -Value $redValue -Detail $redDetail -Fix $redFix -NeedsAdmin $true

# ---------------------------------------------------------------------------
# 7. 字体缓存
# ---------------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$fcDir = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\AppData\Local\FontCache'
$fcStatus = 'skip'
$fcValue = ''
$fcDetail = ''
$fcFix = '停止 FontCache 服务后删除 FontCache 目录内容，Windows 会重建（需要管理员；本板块不做需要停服务的修复）。'
$fcAdmin = $true
$fcError = ''
$fcEntries = $null

try {
    $fcEntries = @(Get-ChildItem -LiteralPath $fcDir -Force -ErrorAction Stop)
} catch {
    $fcError = $_.Exception.GetType().Name
    $fcEntries = $null
}

if ($null -eq $fcEntries) {
    $fcStatus = 'skip'
    if ($fcError -match 'UnauthorizedAccess') {
        $fcDetail = "无法枚举 $fcDir：拒绝访问（$fcError）。该目录的 ACL 只允许 LocalService 读取，当前会话未提权，测不到大小与冲突文件。"
        $fcAdmin = $true
    } elseif ($fcError -match 'DirectoryNotFound') {
        $fcStatus = 'warn'
        $fcDetail = "目录 $fcDir 不存在；Windows 会在首次需要时重建，但这也可能意味着缓存路径被改过。"
        $fcAdmin = $false
    } else {
        $fcDetail = "无法枚举 $fcDir：$fcError。"
    }
} else {
    $fcBytes = [int64]0
    $fcFiles = 0
    $conflict = @()
    foreach ($e in $fcEntries) {
        if ($e.PSIsContainer) { continue }
        $fcFiles++
        $fcBytes += [int64]$e.Length
        if ($e.Name -like '~FontCache-FontFace*') { $conflict += $e.Name }
    }
    $fcStatus = 'ok'
    if ($conflict.Count -gt 0) { $fcStatus = 'bad' }
    $fcValue = "$fcFiles 个文件 / $([math]::Round($fcBytes / 1MB, 2)) MB"
    $fcDetail = "期望：FontCache 目录可读、无 ~FontCache-FontFace.dat 冲突文件。实测：$fcFiles 个文件，合计 $fcBytes B。"
    if ($conflict.Count -gt 0) { $fcDetail += " 冲突文件：$($conflict -join '; ')" }
    $fcAdmin = -not $elevated
}
$timings['fontcache'] = $sw.ElapsedMilliseconds
Add-Item -List $items -Id 'fontcache' -Group '本地缓存' -Label '字体缓存' `
    -Status $fcStatus -Value $fcValue -Detail $fcDetail -Fix $fcFix -NeedsAdmin $fcAdmin

# ---------------------------------------------------------------------------
# 8. 图标缓存
# ---------------------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$icDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
$icStatus = 'skip'
$icValue = ''
$icDetail = ''
$icFix = '重启资源管理器（explorer.exe）后删除 iconcache_*.db，Windows 会重建（本板块不做需要重启的修复）。'
$icFiles = @()
try {
    $icFiles = @(Get-ChildItem -LiteralPath $icDir -File -ErrorAction Stop |
        Where-Object { $_.Name -like '*iconcache*' -or $_.Name -eq 'IconCache.db' })
} catch {
    $icFiles = @()
}

if ($icFiles.Count -eq 0) {
    $icStatus = 'skip'
    $icValue = '0 个缓存文件'
    $icDetail = "在 $icDir 下没有找到 iconcache_*.db 或 IconCache.db（目录不存在或未生成）。"
} else {
    $icBytes = [int64]0
    $zero = 0
    $idxSize = -1
    $legacySize = -1
    foreach ($f in $icFiles) {
        $len = [int64]$f.Length
        $icBytes += $len
        if ($len -eq 0) { $zero++ }
        if ($f.Name -eq 'iconcache_idx.db') { $idxSize = $len }
        if ($f.Name -eq 'IconCache.db') { $legacySize = $len }
    }

    $icStatus = 'ok'
    $notes = @()
    if ($idxSize -eq 0) { $icStatus = 'warn'; $notes += 'iconcache_idx.db 为 0 字节（索引缺失，图标会重建）' }
    if ($legacySize -eq 0) { $icStatus = 'warn'; $notes += 'IconCache.db 为 0 字节' }
    if ($idxSize -lt 0) { $notes += '没有 iconcache_idx.db（当前 Windows 版本可能只维护阈值文件）' }

    $icValue = "$($icFiles.Count) 个文件 / $([math]::Round($icBytes / 1KB, 1)) KB / 0 字节 $zero 个"
    $icDetail = "期望：iconcache_idx.db 存在且非空，缓存文件齐全。实测：$($icFiles.Count) 个 iconcache 文件，合计 $icBytes B，其中 0 字节 $zero 个；iconcache_idx.db 大小 $(if ($idxSize -lt 0) { '不存在' } else { "$idxSize B" })。0 字节的 iconcache_*.db 是 Windows 的懒分配常态，不判为损坏。"
    if ($notes.Count -gt 0) { $icDetail += " 异常：$($notes -join '; ')" }
}
$timings['iconcache'] = $sw.ElapsedMilliseconds
Add-Item -List $items -Id 'iconcache' -Group '本地缓存' -Label '图标缓存' `
    -Status $icStatus -Value $icValue -Detail $icDetail -Fix $icFix -NeedsAdmin $false

# ---------------------------------------------------------------------------
$extra = @{
    action   = $action
    dryRun   = $dryRun
    elevated = $elevated
    ids      = @($fixIds)
    timings  = $timings
}
Write-ProbeResult -Items $items -Extra $extra -Note 'repair: 8 项配置漂移检查（assert → detect → fix）'
