param([string]$ParamFile)

# ---------------------------------------------------------------------------
# perm.ps1 — 权限管理：逐应用权限明细 + 敏感权限排序.
#
# 与 privacy.ps1 的分工（同一个插件里不能重复报同一件事）：
#   privacy.ps1 只看"总开关"——每个 capability 的全局 Value、应用计数、广告 ID、
#   遥测、活动历史、定位总开关。它是"这一类权限整体开没开"。
#   本探针反过来只看"谁拿到了权限"：逐个应用的 Allow/Deny、最近一次使用的真实时间，
#   以及 broadFileSystemAccess（能读全盘）这种一旦给错就是灾难的单点。
#
# 数据源全部是 HKCU 下的 ConsentStore：
#   HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\<capability>
#     Value                 全局（"所有应用"）设定：Allow / Deny / Prompt
#     <应用包名>            打包应用，子键名就是 PackageFamilyName
#     NonPackaged\<路径键>  未打包的桌面程序，键名是路径把 \ 换成 #
#   每个应用子键下：Value（Allow/Deny/Prompt）、LastUsedTimeStart、LastUsedTimeStop（FILETIME）
#
# 读数口径（实测，本机 2026-11-17）：
#   * 29 个 capability 子键，顶层应用级条目 45 个；microphone 的 NonPackaged 下另有 4 个桌面程序
#   * LastUsedTimeStart/Stop 是 Windows FILETIME（自 1601 起的 100ns 计数）。
#     0 = 从未使用；[DateTime]::FromFileTime() 换算成可读时间。130000000000000000 量级是正常值
#     （约 2013 年），134258896224731820 → 2026-06-14 13:47。
#   * 顶层应用条目 45 个全读只要约 58 ms；枚举 capability 约 212 ms，含 NonPackaged 深读约 201 ms。
#     ConsentStore 是本探针唯一的数据源，所以整体很快，不需要缓存。
#   * 只读：本文件没有任何写操作。改权限请用户在设置里点，探针只把 fix 写成一句话。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList

$consentRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'

# capability 中文名。没列到的直接把英文名显示出来，不猜。
$capNames = @{
    'webcam'                 = '摄像头'
    'microphone'             = '麦克风'
    'location'               = '位置'
    'broadFileSystemAccess'  = '文件系统（全盘读取）'
    'contacts'               = '联系人'
    'phoneCall'              = '电话呼叫'
    'phoneCallHistory'       = '通话记录'
    'email'                  = '邮件'
    'userAccountInformation' = '账户信息'
    'appointments'           = '日历'
    'chat'                   = '消息'
    'radios'                 = '无线电'
    'bluetooth'              = '蓝牙'
    'bluetoothSync'          = '蓝牙同步'
    'documentsLibrary'       = '文档库'
    'picturesLibrary'        = '图片库'
    'videosLibrary'          = '视频库'
    'activity'               = '活动历史'
    'appDiagnostics'         = '应用诊断'
    'humanInterfaceDevice'   = '人体学输入设备'
    'serialCommunication'    = '串口'
    'usb'                    = 'USB'
    'cellularData'           = '蜂窝数据'
    'wifiData'               = 'Wi-Fi 数据'
    'userNotificationListener' = '通知监听'
    'gazeInput'              = '视线输入'
    'sensors.custom'         = '自定义传感器'
    'userDataTasks'          = '任务/待办'
    'wiFiDirect'             = 'Wi-Fi 直连'
}

# 敏感度排序：数字越小越危险。只有这些会被排进 Top N。
$capRank = @{
    'broadFileSystemAccess'  = 0   # 能读全盘，比摄像头更狠
    'webcam'                 = 1
    'microphone'             = 2
    'location'               = 3
    'contacts'               = 4
    'phoneCall'              = 5
    'phoneCallHistory'       = 5
    'email'                  = 6
    'userAccountInformation' = 7
}

function Get-CapName {
    param([string]$Cap)
    if ($capNames.ContainsKey($Cap)) { return $capNames[$Cap] }
    return $Cap
}

# FILETIME → 本地时间文本。0 是"从未使用"，不是 1601 年，不能直接换算。
function ConvertTo-FileTimeNum {
    param($Value)
    $n = [long]0
    if (-not [long]::TryParse([string]$Value, [ref]$n)) { return [long]0 }
    if ($n -le 0) { return [long]0 }
    return $n
}
function Format-FileTime {
    param($Value)
    $n = ConvertTo-FileTimeNum $Value
    if ($n -le 0) { return '从未' }
    try { return ([DateTime]::FromFileTime($n)).ToString('yyyy-MM-dd HH:mm') } catch { return '无法换算' }
}

# ConsentStore 子键名是注册表键名，打包应用名里的空格/特殊字符已经转义；
# NonPackaged 下的键名则是路径把 \ 换成 #。这里还原成人能读的名字。
function ConvertFrom-KeyName {
    param([string]$KeyName)
    $t = $KeyName -replace '#', '\'
    return $t
}

# 从 Sub 键名造一个稳定的 item id 片段：只留字母数字，其余变 -，全小写，最长 40。
$usedIds = @{}
function Get-IdSlug {
    param([string]$Name)
    $s = ($Name -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'entry' }
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).Trim('-') }
    $base = $s
    $i = 2
    while ($script:usedIds.ContainsKey($s)) { $s = "$base-$i"; $i++ }
    $script:usedIds[$s] = $true
    return $s
}

# ---------------------------------------------------------------------------
# 1. 逐应用权限明细
# ---------------------------------------------------------------------------
$entries = New-Object System.Collections.Generic.List[object]
$capCount = 0

$capKeys = @(Get-ChildItem -LiteralPath $consentRoot -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -ne 'NonPackaged' })
$capCount = $capKeys.Count

foreach ($cap in $capKeys) {
    $capName = $cap.PSChildName
    $capAllowed = (Format-RegValue (Get-RegValue -Path $cap.PSPath -Name 'Value')) -eq 'Allow'

    foreach ($sub in @(Get-ChildItem -LiteralPath $cap.PSPath -ErrorAction SilentlyContinue)) {
        if ($sub.PSChildName -eq 'NonPackaged') {
            # 桌面程序：capability\NonPackaged\<路径键>
            foreach ($np in @(Get-ChildItem -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue)) {
                $npStart = Get-RegValue -Path $np.PSPath -Name 'LastUsedTimeStart'
                $npStop = Get-RegValue -Path $np.PSPath -Name 'LastUsedTimeStop'
                $entries.Add([pscustomobject]@{
                    Capability = $capName
                    App        = ConvertFrom-KeyName $np.PSChildName
                    Value      = Format-RegValue (Get-RegValue -Path $np.PSPath -Name 'Value')
                    Start      = Format-FileTime $npStart
                    Stop       = Format-FileTime $npStop
                    Packaged   = $false
                    CapGlobal  = $capAllowed
                    StopNum    = ConvertTo-FileTimeNum $npStop
                })
            }
        } else {
            $pStart = Get-RegValue -Path $sub.PSPath -Name 'LastUsedTimeStart'
            $pStop = Get-RegValue -Path $sub.PSPath -Name 'LastUsedTimeStop'
            $entries.Add([pscustomobject]@{
                Capability = $capName
                App        = $sub.PSChildName
                Value      = Format-RegValue (Get-RegValue -Path $sub.PSPath -Name 'Value')
                Start      = Format-FileTime $pStart
                Stop       = Format-FileTime $pStop
                Packaged   = $true
                CapGlobal  = $capAllowed
                StopNum    = ConvertTo-FileTimeNum $pStop
            })
        }
    }
}

$hasConsent = $capCount -gt 0

if (-not $hasConsent) {
    Add-Item -List $items -Id 'perm:consentstore' -Group 'meta' -Label '权限记录' -Status 'skip' -Value '' `
        -Detail "ConsentStore 根键读不到或为空（$consentRoot）：本机没有应用级权限记录，或当前用户配置单元未加载，无法给出逐应用明细" -Fix ''
} else {
    Add-Item -List $items -Id 'perm:consentstore' -Group 'meta' -Label '权限记录规模' -Status 'info' `
        -Value "$capCount 类 · $($entries.Count) 条应用级记录" `
        -Detail "数据源 $consentRoot；每条记录 = 某个应用在某一类权限上的 Allow/Deny 与最近使用时间" -Fix ''
}

# ---------------------------------------------------------------------------
# 2. 一行汇总：多少应用能访问摄像头 / 麦克风
# ---------------------------------------------------------------------------
$camAllow = @($entries | Where-Object { $_.Capability -eq 'webcam' -and $_.Value -eq 'Allow' })
$micAllow = @($entries | Where-Object { $_.Capability -eq 'microphone' -and $_.Value -eq 'Allow' })
$camNames = @($camAllow | ForEach-Object { $_.App })
$micNames = @($micAllow | ForEach-Object { $_.App })

if (-not $hasConsent) {
    Add-Item -List $items -Id 'perm:webcam-global' -Group 'summary' -Label '摄像头/麦克风访问' -Status 'skip' -Value '' `
        -Detail '权限记录不可读，无法统计' -Fix ''
} else {
    $avStatus = 'info'
    if ($camAllow.Count -gt 0 -or $micAllow.Count -gt 0) { $avStatus = 'warn' }
    $avDetail = "摄像头 Allow：$(if($camNames.Count){$camNames -join '、'}else{'无'})；麦克风 Allow：$(if($micNames.Count){$micNames -join '、'}else{'无'})。这个数是「被明确授权」的应用数，不含已卸载但残留的记录。"
    Add-Item -List $items -Id 'perm:webcam-global' -Group 'summary' -Label '摄像头/麦克风访问' -Status $avStatus `
        -Value "摄像头 $($camAllow.Count) 个应用 · 麦克风 $($micAllow.Count) 个应用" `
        -Detail $avDetail `
        -Fix $(if ($camAllow.Count -gt 0 -or $micAllow.Count -gt 0) { '设置 > 隐私和安全性 > 摄像头/麦克风：把不用的应用逐个关掉（照相机类应用日常其实用不到常驻授权）' } else { '' })
}

# ---------------------------------------------------------------------------
# 3. broadFileSystemAccess —— 能读全盘，单独成行
# ---------------------------------------------------------------------------
$bfsApps = @($entries | Where-Object { $_.Capability -eq 'broadFileSystemAccess' })
$bfsAllowApps = @($bfsApps | Where-Object { $_.Value -eq 'Allow' })
$bfsGlobalHkcu = Format-RegValue (Get-RegValue -Path (Join-Path $consentRoot 'broadFileSystemAccess') -Name 'Value')
$bfsGlobalHklm = Format-RegValue (Get-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess' -Name 'Value')

if ($bfsAllowApps.Count -gt 0) {
    $bfsStatus = 'bad'
    $bfsValue = "$($bfsAllowApps.Count) 个应用持有（全局 $bfsGlobalHkcu）"
    $bfsDetail = ($bfsAllowApps | ForEach-Object { "$($_.App)（最近 $($_.Stop)）" }) -join '；'
    $bfsFix = '逐个撤销：设置 > 隐私和安全性 > 文件系统 → 关闭不需要的应用。这项权限绕过所有文件夹授权，一个恶意或小众应用拿到就等于能翻整块硬盘。'
} elseif ($bfsGlobalHkcu -eq 'Allow') {
    $bfsStatus = 'warn'
    $bfsValue = "0 个应用 · 全局 Allow"
    $bfsDetail = "全局开关是 Allow，但当前没有任何应用持有这条权限（HKCU 下 0 个应用子键）。也就是说门是开着的，只是还没人走进来——将来任何请求这项权限的应用只要被点过一次「允许」就直接生效。HKLM 侧：$bfsGlobalHklm。"
    $bfsFix = '把全局开关改成拒绝（设置 > 隐私和安全性 > 文件系统），或至少确认没有陌生应用能自行申请'
} else {
    $bfsStatus = 'ok'
    $bfsValue = "0 个应用 · 全局 $bfsGlobalHkcu"
    $bfsDetail = "没有应用持有全盘读取权限，全局开关也不是 Allow（HKLM 侧：$bfsGlobalHklm）"
    $bfsFix = ''
}
Add-Item -List $items -Id 'perm:broadfs' -Group 'summary' -Label '全盘文件访问权限' -Status $bfsStatus -Value $bfsValue -Detail $bfsDetail -Fix $bfsFix

# ---------------------------------------------------------------------------
# 4. 敏感度 Top N
# ---------------------------------------------------------------------------
$sensitive = @($entries |
    Where-Object { $_.Value -eq 'Allow' -and $capRank.ContainsKey($_.Capability) } |
    Sort-Object -Property @(
        @{ Expression = { $capRank[$_.Capability] } },
        @{ Expression = { $_.StopNum }; Descending = $true },
        @{ Expression = { $_.App } }
    ))

$topN = 10
$top = @($sensitive | Select-Object -First $topN)
if ($top.Count -gt 0) {
    $lines = @()
    $i = 0
    foreach ($t in $top) {
        $i++
        $lines += "$i) $($t.App) / $($t.Capability)（$(Get-CapName $t.Capability)）/ 最近 $($t.Stop)"
    }
    Add-Item -List $items -Id 'perm:sensitive-top' -Group 'summary' -Label '敏感权限 Top' -Status 'warn' `
        -Value "Top $($top.Count)（共 $($sensitive.Count) 条已授权敏感项）" `
        -Detail ($lines -join '；') `
        -Fix '按顺序看：排在前面的每一条都值得问一句「这个应用真的需要吗」。摄像头/麦克风/位置/全盘文件是四类最该收紧的权限。'
    # 逐条也报一遍，方便单独处理某一条
    $i = 0
    foreach ($t in $top) {
        $i++
        $rank = $capRank[$t.Capability]
        $st = if ($rank -le 2) { 'bad' } elseif ($rank -le 4) { 'warn' } else { 'info' }
        Add-Item -List $items -Id ("perm:top-$i") -Group 'sensitive' -Label "敏感授权 #$i" -Status $st `
            -Value "$($t.App) → $(Get-CapName $t.Capability)" `
            -Detail "capability=$($t.Capability) · 授权=$($t.Value) · 最近使用=$($t.Stop) · 首次=$($t.Start) · $(if($t.Packaged){'Store/打包应用'}else{'桌面程序'})" `
            -Fix '不需要就在设置里关掉'
    }
} else {
    Add-Item -List $items -Id 'perm:sensitive-top' -Group 'summary' -Label '敏感权限 Top' -Status 'ok' `
        -Value '0 条' -Detail '没有任何应用在摄像头/麦克风/位置/全盘文件/联系人/电话/邮件/账户信息这些高敏感权限上被明确授权' -Fix ''
}

# ---------------------------------------------------------------------------
# 5. 逐应用明细（按应用聚合：一个应用拿到哪几类权限）
# ---------------------------------------------------------------------------
$byApp = @{}
foreach ($e in $entries) {
    if (-not $byApp.ContainsKey($e.App)) { $byApp[$e.App] = New-Object System.Collections.Generic.List[object] }
    $byApp[$e.App].Add($e)
}

foreach ($appName in ($byApp.Keys | Sort-Object)) {
    $list = $byApp[$appName]
    $allowCaps = @($list | Where-Object { $_.Value -eq 'Allow' })
    $promptCaps = @($list | Where-Object { $_.Value -eq 'Prompt' })
    $denyCaps = @($list | Where-Object { $_.Value -eq 'Deny' })

    # 最敏感的那条决定这一行的颜色
    $rank = 99
    foreach ($a in $allowCaps) { if ($capRank.ContainsKey($a.Capability) -and $capRank[$a.Capability] -lt $rank) { $rank = $capRank[$a.Capability] } }
    $st = 'info'
    if ($allowCaps.Count -gt 0) { $st = if ($rank -le 2) { 'warn' } elseif ($rank -le 4) { 'warn' } else { 'info' } }
    if ($allowCaps.Count -eq 0 -and $denyCaps.Count -gt 0) { $st = 'ok' }

    $capText = @()
    foreach ($a in $allowCaps) { $capText += "$(Get-CapName $a.Capability)[允许]" }
    foreach ($a in $promptCaps) { $capText += "$(Get-CapName $a.Capability)[每次询问]" }
    foreach ($a in $denyCaps) { $capText += "$(Get-CapName $a.Capability)[拒绝]" }
    # 没有 Value 的记录（Windows 偶尔留下空壳键）也如实说明
    $otherCaps = @($list | Where-Object { $_.Value -ne 'Allow' -and $_.Value -ne 'Prompt' -and $_.Value -ne 'Deny' })
    foreach ($a in $otherCaps) { $capText += "$(Get-CapName $a.Capability)[无值]" }

    $lastStopNum = ($list | ForEach-Object { $_.StopNum } | Sort-Object -Descending | Select-Object -First 1)
    $lastStop = if ($lastStopNum -gt 0) { Format-FileTime $lastStopNum } else { '' }
    $packaged = @($list | Where-Object { $_.Packaged }).Count -gt 0

    $rowValue = if ($allowCaps.Count -gt 0) { "$($allowCaps.Count) 项已允许" }
        elseif ($denyCaps.Count -gt 0) { '已拒绝' }
        elseif ($promptCaps.Count -gt 0) { "$($promptCaps.Count) 项待询问" }
        else { '残留记录（无 Value）' }

    Add-Item -List $items -Id ("perm:app-" + (Get-IdSlug $appName)) -Group 'apps' -Label $appName -Status $st `
        -Value $rowValue `
        -Detail "$($capText -join '、')；最近使用=$(if($lastStop){$lastStop}else{'从未记录'})；$(if($packaged){'Store/打包应用'}else{'桌面程序'})" `
        -Fix $(if ($allowCaps.Count -gt 0) { '不需要就关掉；尤其是摄像头/麦克风/位置' } else { '' })
}

# ---------------------------------------------------------------------------
# 6. Windows 搜索索引范围（只读）
# ---------------------------------------------------------------------------
$crawlRoot = 'HKLM:\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex'
$searchRoots = @(Get-ChildItem -LiteralPath (Join-Path $crawlRoot 'SearchRoots') -ErrorAction SilentlyContinue)
$defaultRules = @(Get-ChildItem -LiteralPath (Join-Path $crawlRoot 'DefaultRules') -ErrorAction SilentlyContinue)
if ($searchRoots.Count -gt 0) {
    $rootUrls = @()
    $wholeDrive = 0
    foreach ($r in $searchRoots) {
        $url = Format-RegValue (Get-RegValue -Path $r.PSPath -Name 'URL')
        $rootUrls += $url
        # file:///C:\[guid]\ 这种形态覆盖整个盘根
        if ($url -match '^file:///[A-Za-z]:/?') { $wholeDrive++ }
    }
    $shown = @($rootUrls | Select-Object -First 6) -join '、'
    Add-Item -List $items -Id 'perm:search-scope' -Group 'readonly' -Label '搜索索引范围' -Status $(if ($wholeDrive -gt 0) { 'warn' } else { 'info' }) `
        -Value "$($searchRoots.Count) 个索引根 · $($defaultRules.Count) 条默认规则" `
        -Detail "索引根：$shown。覆盖整盘根的条目 $wholeDrive 个。索引内容会进 Windows 搜索库，本地可被搜索类工具读取；范围越大，被意外收录的文件越多（如整盘根）。" `
        -Fix $(if ($wholeDrive -gt 0) { '设置 > 隐私和安全性 > 搜索 Windows → 修改索引位置，去掉整个盘根、只留需要的文件夹' } else { '' })
} else {
    Add-Item -List $items -Id 'perm:search-scope' -Group 'readonly' -Label '搜索索引范围' -Status 'skip' -Value '' `
        -Detail "读不到 CrawlScopeManager\Windows\SystemIndex（$crawlRoot）：Windows Search 未安装或策略被锁定，无法统计索引范围" -Fix ''
}

# ---------------------------------------------------------------------------
# 7. 诊断数据查看器（只读）
# ---------------------------------------------------------------------------
$ddvKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack'
$ddvToast = Format-RegValue (Get-RegValue -Path $ddvKey -Name 'ShowedToastAtLevel')
$appxStore = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications'
$ddvPkg = @(Get-ChildItem -LiteralPath $appxStore -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like '*DiagnosticDataViewer*' })
if ($ddvPkg.Count -gt 0) {
    Add-Item -List $items -Id 'perm:diagviewer' -Group 'readonly' -Label '诊断数据查看器' -Status 'info' `
        -Value "已安装（$($ddvPkg.Count) 个包）" `
        -Detail '这台机器上装了诊断数据查看器，可以把系统上传前的诊断数据在本地打开看。ShowedToastAtLevel=' + $ddvToast -Fix ''
} else {
    Add-Item -List $items -Id 'perm:diagviewer' -Group 'readonly' -Label '诊断数据查看器' -Status 'info' `
        -Value '未安装' -Detail "AppxAllUserStore\Applications 里没有 DiagnosticDataViewer 包，HKCU 诊断键存在（ShowedToastAtLevel=$ddvToast，是 DiagTrack 的提示状态，不代表查看器已装）。未安装时看不到系统实际收集了什么，但也不产生额外的本地副本。" `
        -Fix '想核对系统到底收了多少诊断数据可从应用商店装「诊断数据查看器」（可选，装完能本地查看再上传的内容）'
}

# ---------------------------------------------------------------------------
# 8. 结论
# ---------------------------------------------------------------------------
$worst = @()
if ($bfsAllowApps.Count -gt 0) { $worst += "全盘读权限给到了 $($bfsAllowApps.Count) 个应用（最危险，先关这个）" }
elseif ($bfsGlobalHkcu -eq 'Allow') { $worst += '全盘读权限全局开着但没有应用持有（门开着没人进，建议直接改成拒绝）' }
$camMicApps = @(@($camNames) + @($micNames) | Sort-Object -Unique)
if ($camMicApps.Count -gt 0) { $worst += "摄像头/麦克风有 $($camMicApps.Count) 个应用被授权：$($camMicApps -join '、')" }
if ($sensitive.Count -gt 0) { $worst += "高敏感授权合计 $($sensitive.Count) 条（摄像头/麦克风/位置/全盘文件/联系人/电话/邮件/账户信息）" }
$worstText = if ($worst.Count -gt 0) { $worst -join '；' } else { '没有应用被授予高敏感权限' }

Add-Item -List $items -Id 'perm:conclusion' -Group 'summary' -Label '该关哪些' -Status $(if ($bfsAllowApps.Count -gt 0 -or $camAllow.Count -gt 0 -or $micAllow.Count -gt 0) { 'warn' } else { 'ok' }) `
    -Value "$($entries.Count) 条应用级记录中 $($sensitive.Count) 条是高敏感授权" `
    -Detail "$worstText。排序依据：敏感度优先（全盘文件 > 摄像头 > 麦克风 > 位置 > 联系人 > 电话 > 邮件 > 账户信息），同一权限内最近使用时间新的排前面——最近用过的应用现在很可能还在用这项权限。只读探针不代改，设置路径：设置 > 隐私和安全性 > 对应的权限页。" `
    -Fix $(if ($camAllow.Count -gt 0 -or $micAllow.Count -gt 0 -or $bfsAllowApps.Count -gt 0) { '先关摄像头/麦克风里不用的应用，再处理全盘文件权限' } else { '' })

Write-ProbeResult -Items $items -Extra @{
    capabilities        = $capCount
    appEntries          = $entries.Count
    webcamAllow         = $camAllow.Count
    microphoneAllow     = $micAllow.Count
    broadFsApps         = $bfsAllowApps.Count
    broadFsGlobalHkcu   = $bfsGlobalHkcu
    broadFsGlobalHklm   = $bfsGlobalHklm
    sensitiveAllow      = $sensitive.Count
    searchRoots         = $searchRoots.Count
    diagViewerInstalled = ($ddvPkg.Count -gt 0)
} -Note '只读：仅统计 HKCU\ConsentStore 下的应用级授权与最近使用时间，不做任何修改。privacy.ps1 负责各类权限的全局开关与遥测/广告 ID，本探针不重复那些结论。'
