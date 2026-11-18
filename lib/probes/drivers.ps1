# drivers.ps1 — 驱动清单探针（只读，不安装不删除任何东西）。
#
# 为什么要绕开 pnputil /enum-drivers：
#   pnputil 的字段标签会被本地化（"发布名称:" / "原始名称:" / "类 GUID:"），
#   zh-CN 控制台下 PowerShell 抓到的标签被 OEM 代码页破坏，任何基于标签的解
#   析都会静默匹配不到、报出"0 个驱动包"（本机 2026-11-17 实测就是 0 条假零）。
#   注册表没有这个问题：不需要管理员、比 pnputil 读到的还多（多出
#   SignerScore / StatusFlags / NeedsReconfig），且就是 pnputil 背后那份存储。
#
# 三条数据源，故意分开：
#   * 驱动包 — HKLM\SYSTEM\DriverDatabase\DriverPackages，一个包一行。一个包可
#              以被多个设备共用，也可以没绑定任何设备（孤立包）。
#   * 设备   — Win32_PnPSignedDriver，一个设备实例一行：现在哪个驱动绑在哪个
#              硬件上。第三方包按 InfName（oemNN.inf）回连到设备。
#   * 故障设备 — Win32_PnPEntity 里 ConfigManagerErrorCode 非 0 的。
#
# 只读。
param([string]$ParamFile)

# Node 按 UTF-8 读我们的 stdout；不写这一行 PowerShell 会按控制台代码页
# （zh-CN 是 936/GBK）编码，所有中文到上层就是乱码。
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items  = New-ProbeList
$sw     = [System.Diagnostics.Stopwatch]::StartNew()

$infRoot = 'HKLM:\SYSTEM\DriverDatabase\DriverInfFiles'
$pkgRoot = 'HKLM:\SYSTEM\DriverDatabase\DriverPackages'

# ConfigManagerErrorCode → 中文解释。只列真实会遇到的那几个，其余兜底。
$codeText = @{
    1  = '设备未正确配置（资源冲突或配置不完整）'
    3  = '驱动程序已损坏，或系统内存不足'
    9  = '硬件密钥无效（注册表里的设备信息与硬件不符）'
    10 = '设备无法启动'
    12 = '资源不足，无法启动设备'
    14 = '设备需要重启后才能正常工作'
    18 = '需要重新安装驱动程序'
    19 = '注册表里的配置信息损坏'
    22 = '设备已被禁用（设备管理器里手动停用）'
    24 = '设备不存在（幽灵设备，曾插过、当前未接入）'
    28 = '驱动未安装'
    31 = '无法加载该设备的驱动程序'
    32 = '驱动程序的启动类型错误'
    43 = '已被 Windows 停止，因为该设备报告了问题'
    52 = '无法验证设备驱动的数字签名'
}

# ---------------------------------------------------------------------------
# 1. 驱动包存储（注册表，绝不解析 pnputil 文本）
# ---------------------------------------------------------------------------
# DriverInfFiles 把逻辑 inf 名（oemNN.inf，或 acpi.inf 这类微软自带名）映射到
# DriverPackages 下的真实包键。oemNN.inf 正是 Win32_PnPSignedDriver 报的
# InfName，所以这张表同时就是回连设备的 join 键。
$logicalToPackage = @{}
foreach ($k in (Get-ChildItem -LiteralPath $infRoot -ErrorAction SilentlyContinue)) {
    $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
    if ($null -eq $p) { continue }
    $target = [string]$p.Active
    if (-not $target) { $target = [string]$p.'(default)' }
    if ($target) { $logicalToPackage[$k.PSChildName] = $target }
}

$packageToLogical = @{}
foreach ($kv in $logicalToPackage.GetEnumerator()) {
    if (-not $packageToLogical.ContainsKey($kv.Value)) { $packageToLogical[$kv.Value] = $kv.Key }
}

$pkgRows = @()
foreach ($k in (Get-ChildItem -LiteralPath $pkgRoot -ErrorAction SilentlyContinue)) {
    $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
    if ($null -eq $p) { continue }
    $key     = $k.PSChildName
    $logical = [string]$packageToLogical[$key]
    $infName = [string]$p.'(default)'
    if (-not $infName) { $infName = ($key -replace '_[^_]+$', '') }

    # ImportDate 是 8 字节 FILETIME。Version 那个 48 字节 blob 的解码方式在不同
    # 版本间不稳定，这里不猜，版本号一律取绑定的设备行。
    $importDate = ''
    $raw = $p.ImportDate
    if ($raw -is [byte[]] -and $raw.Length -ge 8) {
        try {
            $importDate = ([DateTime]::FromFileTimeUtc([BitConverter]::ToInt64($raw, 0))).ToString('yyyy-MM-dd')
        } catch { $importDate = '' }
    }

    $pkgRows += [ordered]@{
        key          = $key
        logical      = $logical
        infName      = $infName
        provider     = [string]$p.Provider
        signer       = [string]$p.SignerName
        signerScore  = [string]$p.SignerScore
        needsReconfig = ([int]$p.NeedsReconfig -gt 0)
        importDate   = $importDate
        thirdParty   = ($logical -like 'oem*.inf')
    }
}

# ---------------------------------------------------------------------------
# 2. 设备实例（Win32_PnPSignedDriver：168 条，含驱动版本与日期）
# ---------------------------------------------------------------------------
$devRows = @()
foreach ($d in (Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue)) {
    $dateObj = $null
    $dateIso = ''
    $rawDate = [string]$d.DriverDate
    if ($rawDate) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($rawDate, [ref]$parsed)) {
            # 伪值：Intel 芯片组驱动会报 1968-07-18（GUID epoch，本质是"没日期"）。
            if ($parsed.Year -ge 2000 -and $parsed.Year -le 2100) {
                $dateObj = $parsed
                $dateIso = $parsed.ToString('yyyy-MM-dd')
            }
        }
    }
    $provider = [string]$d.DriverProviderName
    # IsSigned 是三态，不是布尔：True=已签名，False=明确未签名，NULL=这个设备实例
    # 根本没绑驱动（本机实测 2 条 NULL：Intel Tile Device、HTREE\ROOT\0）。
    # 用 [bool] 强转会把 NULL 变成 False，凭空造出"未签名驱动"。
    $sig = 'unknown'
    if ($null -ne $d.IsSigned) { if ([bool]$d.IsSigned) { $sig = 'signed' } else { $sig = 'unsigned' } }
    $devRows += [ordered]@{
        name      = [string]$d.DeviceName
        deviceId  = [string]$d.DeviceID
        infName   = [string]$d.InfName
        version   = [string]$d.DriverVersion
        provider  = $provider
        dateIso   = $dateIso
        dateObj   = $dateObj
        deviceClass = [string]$d.DeviceClass
        sigState  = $sig
        isMs      = ($provider -eq 'Microsoft' -or $provider -like 'Microsoft *')
    }
}

$boundByInf = @{}
foreach ($d in $devRows) {
    $n = [string]$d.infName
    if (-not $n) { continue }
    if (-not $boundByInf.ContainsKey($n)) {
        $boundByInf[$n] = New-Object System.Collections.Generic.List[object]
    }
    $boundByInf[$n].Add($d)
}

function Format-DevRow {
    param($Row)
    $head = (@([string]$Row.name, [string]$Row.version) | Where-Object { $_ }) -join ' '
    if (-not $head) { $head = [string]$Row.deviceId }
    $tail = @()
    if ($Row.dateIso) { $tail += [string]$Row.dateIso }
    if ($Row.provider) { $tail += [string]$Row.provider }
    if ($tail.Count -gt 0) { return ($head + ' / ' + ($tail -join ' / ')) }
    return $head
}

$packagesTotal = @($pkgRows).Count
$thirdPkgs     = @($pkgRows | Where-Object { $_.thirdParty })
$thirdCount    = $thirdPkgs.Count

# ---------------------------------------------------------------------------
# 3. 输出：驱动包总量 / 第三方包逐条
# ---------------------------------------------------------------------------
if ($packagesTotal -eq 0) {
    Add-Item -List $items -Id 'drivers:packages' -Group '驱动包' -Label '驱动包存储' -Status 'skip' `
        -Detail '读不到 HKLM\SYSTEM\DriverDatabase\DriverPackages，无法判定驱动包数量（可能是注册表不可读或系统版本过旧）' `
        -Fix '确认当前账户能读取 HKLM\SYSTEM\DriverDatabase；必要时用管理员重新运行探针'
} else {
    Add-Item -List $items -Id 'drivers:packages' -Group '驱动包' -Label '驱动包总数' -Status 'info' `
        -Value ("共 {0} 个，其中第三方（oem*.inf）{1} 个" -f $packagesTotal, $thirdCount) `
        -Detail '微软 in-box 驱动包（acpi.inf 等）无法卸载，只有 oemNN.inf 这类第三方包能删；数量本身不代表好坏，异常膨胀说明装过很多次驱动没清理'
}

if ($thirdCount -gt 0) {
    Add-Item -List $items -Id 'drivers:thirdparty' -Group '第三方驱动包' -Label '第三方驱动包汇总' -Status 'info' `
        -Value ("{0} 个" -f $thirdCount) `
        -Detail '第三方包只能用 pnputil /delete-driver <oemNN.inf> /uninstall 移除；升级驱动后旧包会留在存储里，长期会积累' `
        -Fix '设备管理器 → 右键设备 → 更新驱动程序；装完新驱动后用 pnputil /enum-drivers 核对旧 oem 包是否还在'
} else {
    Add-Item -List $items -Id 'drivers:thirdparty' -Group '第三方驱动包' -Label '第三方驱动包汇总' -Status 'ok' `
        -Value '0 个' -Detail '驱动存储里只有微软 in-box 包，没有第三方 oem*.inf 包'
}

# 第三方包按 oem 编号排序后逐条展开。
foreach ($pk in ($thirdPkgs | Sort-Object -Property { [int]($_.logical -replace '\D', '') })) {
    $oem = [string]$pk.logical -replace '\.inf$', ''
    $bound = $boundByInf[[string]$pk.logical]
    $boundCount = 0
    $devText = '当前没有设备绑定这个包（可能是给已移除的硬件装的，或装完没生效）'
    if ($null -ne $bound -and $bound.Count -gt 0) {
        $boundCount = $bound.Count
        $names = @($bound | ForEach-Object { [string]$_.name } | Where-Object { $_ } | Select-Object -First 3)
        if ($names.Count -gt 0) {
            $devText = "已绑定 {0} 个设备：{1}{2}" -f $boundCount, ($names -join '、'), $(if ($boundCount -gt $names.Count) { ' 等' } else { '' })
        }
    }
    $ver = ''
    if ($null -ne $bound -and $bound.Count -gt 0) { $ver = [string]$bound[0].version }

    $detail = @()
    $detail += ("原始 inf：{0}" -f $(if ($pk.infName) { $pk.infName } else { '(未知)' }))
    $detail += $devText
    if ($pk.provider) { $detail += ("提供者：{0}" -f $pk.provider) }
    if ($pk.importDate) { $detail += ("导入日期：{0}" -f $pk.importDate) }
    if ($pk.needsReconfig) { $detail += 'StatusFlags 标记需要重新配置（NeedsReconfig=1）' }

    Add-Item -List $items -Id ("drivers:thirdparty-{0}" -f $oem) -Group '第三方驱动包' `
        -Label ("{0} （{1}）" -f $pk.logical, $(if ($ver) { $ver } else { '版本见绑定设备' })) `
        -Status $(if ($boundCount -gt 0) { 'ok' } else { 'info' }) `
        -Value $(if ($pk.provider) { $pk.provider } else { '提供者未记录' }) `
        -Detail ($detail -join '；') `
        -Fix '要移除这个旧包：pnputil /delete-driver <oemNN.inf> /uninstall（需管理员）；要升级：设备管理器里更新对应设备的驱动'
}

# ---------------------------------------------------------------------------
# 4. 设备与故障设备
# ---------------------------------------------------------------------------
$deviceCount = @($devRows).Count
if ($deviceCount -eq 0) {
    Add-Item -List $items -Id 'drivers:devices' -Group '设备' -Label '已安装设备驱动' -Status 'skip' `
        -Detail 'Win32_PnPSignedDriver 返回 0 条，无法枚举设备驱动（WMI/CIM 服务可能未响应）' `
        -Fix '运行 winmgmt /verifyrepository 检查 WMI 存储；重启后重试'
} else {
    $withName = @($devRows | Where-Object { $_.name }).Count
    $dated    = @($devRows | Where-Object { $_.dateIso }).Count
    Add-Item -List $items -Id 'drivers:devices' -Group '设备' -Label '已安装设备驱动' -Status 'info' `
        -Value ("{0} 个设备实例" -f $deviceCount) `
        -Detail ("{0} 个有设备名（其余是打印队列等无名字条目）；{1} 个驱动的日期可信（其余要么没日期，要么是 1968 那种伪值）" -f $withName, $dated)
}

$problemRows = @()
foreach ($e in (Get-CimInstance -ClassName Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue)) {
    # 幽灵设备（Present=False）不是故障，是曾经插过、现在没接的硬件。
    if ($null -ne $e.Present -and -not $e.Present) { continue }
    $problemRows += [ordered]@{
        name = [string]$e.Name
        devId = [string]$e.DeviceID
        code = [int]$e.ConfigManagerErrorCode
        pnpClass = [string]$e.PNPClass
        status = [string]$e.Status
    }
}

if ($problemRows.Count -eq 0) {
    Add-Item -List $items -Id 'drivers:problems' -Group '故障设备' -Label '有问题的设备' -Status 'ok' `
        -Value '0 个' `
        -Detail 'ConfigManagerErrorCode 全为 0，没有报错设备（幽灵设备已排除，它们只是当前没接入的旧硬件）'
} else {
    $i = 0
    foreach ($pr in $problemRows) {
        $i++
        $code = $pr.code
        $txt = $codeText[$code]
        if (-not $txt) { $txt = '设备管理器里有详细说明' }
        Add-Item -List $items -Id ("drivers:problem-{0:D2}" -f $i) -Group '故障设备' `
            -Label $(if ($pr.name) { $pr.name } else { $pr.devId }) -Status 'bad' `
            -Value ("错误码 {0}：{1}" -f $code, $txt) `
            -Detail ("类别 {0}；状态 {1}；设备 ID {2}" -f $(if ($pr.pnpClass) { $pr.pnpClass } else { '未知' }), $(if ($pr.status) { $pr.status } else { '未知' }), $pr.devId) `
            -Fix '设备管理器 → 右键该设备 → 卸载设备（勾选删除驱动）→ 扫描硬件改动；仍不行就重装官方驱动' `
            -NeedsAdmin $true
    }
}

# ---------------------------------------------------------------------------
# 5. 未签名驱动（Win32_PnPSignedDriver 里 IsSigned=False）
# ---------------------------------------------------------------------------
$unsigned = @($devRows | Where-Object { $_.sigState -eq 'unsigned' })
$sigUnknown = @($devRows | Where-Object { $_.sigState -eq 'unknown' })
if ($deviceCount -eq 0) {
    Add-Item -List $items -Id 'drivers:unsigned' -Group '签名' -Label '未签名驱动' -Status 'skip' `
        -Detail '设备列表为空，无法判断驱动签名状态'
} elseif ($unsigned.Count -eq 0) {
    Add-Item -List $items -Id 'drivers:unsigned' -Group '签名' -Label '未签名驱动' -Status 'ok' `
        -Value '0 个' `
        -Detail ("{0} 个设备实例的 IsSigned 全为 True{1}；这个类本身只列已签名驱动，真正的阻断检查在「设备安装设置」里" -f $deviceCount, $(if ($sigUnknown.Count -gt 0) { "（另有 $($sigUnknown.Count) 个实例没有绑驱动、IsSigned 为空，不算未签名）" } else { '' }))
} else {
    $i = 0
    foreach ($u in $unsigned) {
        $i++
        Add-Item -List $items -Id ("drivers:unsigned-{0:D2}" -f $i) -Group '签名' `
            -Label $(if ($u.name) { $u.name } else { $u.deviceId }) -Status 'warn' `
            -Value ("未签名 {0}" -f $(if ($u.version) { $u.version } else { '版本未知' })) `
            -Detail ("驱动日期 {0}；提供者 {1}；类别 {2}" -f $(if ($u.dateIso) { $u.dateIso } else { '未知' }), $(if ($u.provider) { $u.provider } else { '未知' }), $(if ($u.deviceClass) { $u.deviceClass } else { '未知' })) `
            -Fix '换成厂商签名版驱动；确认来源可信后再手动信任，不要长期保留未签名驱动'
    }
}

# ---------------------------------------------------------------------------
# 6. 驱动日期过旧：最旧 Top 10（第三方优先，不足再补微软）
# ---------------------------------------------------------------------------
$datedThird = @($devRows | Where-Object { $_.dateObj -and -not $_.isMs })
$datedAll   = @($devRows | Where-Object { $_.dateObj })
$oldPool = $datedThird
if ($oldPool.Count -lt 10) {
    $seen = @{}
    foreach ($r in $oldPool) { $seen[[string]$r.deviceId] = $true }
    $oldPool = @($oldPool) + @($datedAll | Where-Object { -not $seen.ContainsKey([string]$_.deviceId) })
}
# 注意：行是 OrderedDictionary，不能用 Sort-Object -Property <键名>（对字典是静默
# 空操作），必须用 scriptblock 取 dateObj。
$oldest = @($oldPool | Sort-Object -Property { $_.dateObj } | Select-Object -First 10)

if ($oldest.Count -eq 0) {
    Add-Item -List $items -Id 'drivers:oldest' -Group '驱动日期' -Label '最旧的驱动' -Status 'skip' `
        -Detail '没有任何设备带可信的驱动日期，无法排序（DriverDate 缺失或全是伪值）'
} else {
    $now = Get-Date
    $n = 0
    foreach ($r in $oldest) {
        $n++
        $ageYears = [math]::Round((($now - $r.dateObj).TotalDays / 365.25), 1)
        # 超过 2 年没更新只是提醒，不代表坏；超过 4 年更容易在新系统上出兼容问题。
        $st = 'info'
        if ($ageYears -ge 4) { $st = 'warn' }
        Add-Item -List $items -Id ("drivers:oldest-{0:D2}" -f $n) -Group '驱动日期' `
            -Label $(if ($r.name) { $r.name } else { $r.deviceId }) -Status $st `
            -Value ("{0}（{1} 年）" -f $r.dateIso, $ageYears) `
            -Detail ("版本 {0}；提供者 {1}；类别 {2}{3}" -f $(if ($r.version) { $r.version } else { '未知' }), $(if ($r.provider) { $r.provider } else { '未知' }), $(if ($r.deviceClass) { $r.deviceClass } else { '未知' }), $(if ($r.isMs) { '；微软自带驱动，随系统更新' } else { '；第三方驱动，建议去厂商官网核对新版本' })) `
            -Fix $(if ($r.isMs) { '微软自带的通用驱动，日常靠 Windows Update 更新，一般不用管' } else { '到主板/显卡/外设厂商官网下载对应型号的最新驱动安装' })
    }
}

# ---------------------------------------------------------------------------
# 7. 四类关键驱动：显卡 / 芯片组 / 网卡 / 存储控制器
# ---------------------------------------------------------------------------
# 网卡要排掉微软的虚拟适配器（WAN Miniport、Wi-Fi Direct、蓝牙 PAN 等），
# 否则会拿一堆虚拟设备当"网卡"。
$virtualNetPat = 'WAN Miniport|Wi-Fi Direct|Bluetooth|Teredo|ISATAP|Kernel Debug|Virtual Adapter|环回|Loopback'

$keyGroups = @(
    @{ id = 'gpu';     label = '显卡驱动'; cls = @('DISPLAY') },
    @{ id = 'chipset'; label = '芯片组驱动'; cls = @('SYSTEM') },
    @{ id = 'net';     label = '网卡驱动'; cls = @('NET') },
    @{ id = 'storage'; label = '存储控制器驱动'; cls = @('SCSIADAPTER', 'HDC') }
)

foreach ($kg in $keyGroups) {
    $rows = @($devRows | Where-Object { $_.deviceClass -and ($kg.cls -contains ([string]$_.deviceClass).ToUpper()) })
    if ($kg.id -eq 'chipset') {
        # 芯片组只留第三方厂商的（Intel/AMD 的 INF），排除微软自己的 ACPI/Composite 之类。
        $rows = @($rows | Where-Object { -not $_.isMs })
    }
    if ($kg.id -eq 'net') {
        $rows = @($rows | Where-Object { -not $_.isMs -and ([string]$_.name) -notmatch $virtualNetPat })
    }

    if ($rows.Count -eq 0) {
        Add-Item -List $items -Id ("drivers:key-{0}" -f $kg.id) -Group '关键驱动' -Label $kg.label -Status 'skip' `
            -Detail ("在设备驱动里没找到 {0} 类的条目，可能是驱动未装（设备管理器里显示为未知设备）或该类名在本机不同" -f ($kg.cls -join '/')) `
            -Fix '设备管理器 → 按类别展开，确认该类是否有带黄色感叹号的未知设备'
        continue
    }

    $rows = @($rows | Sort-Object -Property { $_.dateObj } -Descending)
    $first = $rows[0]
    $lines = @()
    foreach ($r in $rows) { $lines += (Format-DevRow $r) }
    Add-Item -List $items -Id ("drivers:key-{0}" -f $kg.id) -Group '关键驱动' `
        -Label ("{0}（{1} 项）" -f $kg.label, $rows.Count) -Status 'info' `
        -Value $(if ($first.version) { $first.version } else { '版本未记录' }) `
        -Detail (($lines | Select-Object -First 6) -join '；') `
        -Fix '到厂商官网按型号下载最新驱动：显卡→NVIDIA/AMD/Intel，芯片组/网卡→主板厂商支持页，存储控制器→主板芯片组驱动包'
}

$elapsed = $sw.ElapsedMilliseconds
$note = ("驱动探针完成：驱动包 {0} 个（第三方 {1}），设备 {2} 个，故障设备 {3} 个，最旧驱动取 Top 10；数据来自注册表 DriverDatabase + WMI，未调用 pnputil（zh-CN 下其文本会乱码导致假零）。耗时 {4}ms。" -f `
    $packagesTotal, $thirdCount, $deviceCount, $problemRows.Count, $elapsed)

Write-ProbeResult -Items $items -Extra @{
    packagesTotal = $packagesTotal
    thirdPartyCount = $thirdCount
    deviceCount   = $deviceCount
    problemCount  = $problemRows.Count
    unsignedCount = $unsigned.Count
    oldestListed  = $oldest.Count
    elapsedMs     = $elapsed
} -Note $note
