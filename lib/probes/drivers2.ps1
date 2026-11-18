param([string]$ParamFile)

# ---------------------------------------------------------------------------
# drivers2.ps1 — 未安装/缺驱动的硬件（A） + 偏旧驱动（B），纯只读。
#
# 分工：drivers.ps1 负责「驱动包枚举 + 异常设备概览」，本探针只做两件它没做的事：
#   A. 逐台判「到底是缺驱动 / 被禁用 / 已拔出 / 启动失败」——这四种在 UI 上要给
#      完全不同的建议，只报一句"设备异常"等于没报。
#   B. 找出日期偏旧的驱动，并给出**厂商官网**；绝不声称"检测到新版本"。
#
# 为什么不用 pnputil：zh-CN 控制台代码页会把它的字段名打成乱码，按标签解析会
# 静默匹配不到（详见同作者 driver.ps1 的实测）。这里全部走 CIM / PnP，注册表
# 与 API 都不受代码页影响。
#
# 性能实测（本机，2026-11-17，Windows 10 19045 / pwsh 7.6）：
#   Get-PnpDevice                        ≈ 330 ms / 254 台
#   Get-CimInstance Win32_PnPSignedDriver ≈ 1000 ms / 168 行
#   Get-PnpDeviceProperty                  ≈ 500 ms / 次  ← 逐台查会直接吃掉 30s 预算
# 所以：先按 ConfigManagerErrorCode / Status / Present 把 254 台筛成"真正要报的
# 几台"，再只对这几台查 HardwareID 属性；并且设了 6 秒属性查询预算，超预算就
# 回落 Get-PnpDevice 实体自带的 HardwareID（数据同源，见 A-2 注释）。
#
# 只读：本文件不出现任何 pnputil /add-driver、Update-Driver、SetupAPI 写入调用。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params  = Read-ProbeParams -ParamFile $ParamFile
$items   = New-ProbeList
$started = Get-Date

# ---------------------------------------------------------------------------
# 常量表
# ---------------------------------------------------------------------------

# CM_PROB_* → 中文含义。只收录本探针真的会碰到的码，没把握的码不猜，
# 统一落到「错误码 N」并让 detail 说明含义未知（宁可少说，不能编）。
$cmCodeText = @{
    1  = '设备未配置（无可用驱动或配置未完成）'
    2  = '驱动加载失败'
    3  = '驱动可能损坏，或内存/资源不足'
    4  = '设备未正常工作（驱动或注册表可能损坏）'
    10 = '设备无法启动'
    12 = '找不到足够的可用资源'
    14 = '需要重启计算机后才能正常工作'
    18 = '需要重新安装驱动'
    19 = '注册表可能已损坏'
    22 = '设备已被禁用'
    24 = '设备不存在或驱动未安装完整'
    28 = '驱动未安装'
    31 = 'Windows 无法加载该设备所需的驱动'
    32 = '该设备的驱动服务已被禁用'
    37 = '驱动无法初始化'
    39 = '驱动无法加载（可能损坏或缺失）'
    43 = '已因报告问题被 Windows 停止'
    44 = '已被应用程序或服务关闭'
    45 = '设备当前未连接到计算机（幽灵设备）'
}

# 内建最小厂商映射：drivers.json 缺失时的兜底，键为 PCI 的 VEN_ 或 USB 的 VID_
# （四位大写十六进制）。只放有**官方**驱动下载页的厂商；查不到就给通用指引，
# 不编一个像官网的地址。
$builtinVendors = @{
    '8086' = @{ name = 'Intel';  page = 'https://www.intel.cn/content/www/cn/zh/support/detect.html' }
    '8087' = @{ name = 'Intel';  page = 'https://www.intel.cn/content/www/cn/zh/support/detect.html' }
    '10DE' = @{ name = 'NVIDIA'; page = 'https://www.nvidia.cn/Download/index.aspx' }
    '1002' = @{ name = 'AMD';    page = 'https://www.amd.com/zh-hans/support' }
    '1022' = @{ name = 'AMD';    page = 'https://www.amd.com/zh-hans/support' }
    '10EC' = @{ name = 'Realtek'; page = 'https://www.realtek.com/Download/List?cate_id=584' }
    '0BDA' = @{ name = 'Realtek'; page = 'https://www.realtek.com/Download/List?cate_id=584' }
    '14E4' = @{ name = 'Broadcom'; page = 'https://www.broadcom.com/support/download-search' }
    '168C' = @{ name = 'Qualcomm Atheros'; page = 'https://www.qualcomm.com/support' }
    '0CF3' = @{ name = 'Qualcomm Atheros'; page = 'https://www.qualcomm.com/support' }
    '1028' = @{ name = 'Dell';   page = 'https://www.dell.com/support/home/zh-cn' }
    '17AA' = @{ name = 'Lenovo'; page = 'https://support.lenovo.com.cn/' }
    '1043' = @{ name = 'ASUS';   page = 'https://www.asus.com.cn/support/' }
    '1462' = @{ name = 'MSI';    page = 'https://cn.msi.com/support' }
    '1458' = @{ name = 'Gigabyte'; page = 'https://www.gigabyte.cn/Support' }
    '046D' = @{ name = 'Logitech'; page = 'https://support.logi.com/' }
    '0BC2' = @{ name = 'Seagate'; page = 'https://www.seagate.com/cn/zh/support/downloads/' }
    '1058' = @{ name = 'Western Digital'; page = 'https://support.wdc.com/downloads.aspx' }
    '0781' = @{ name = 'SanDisk'; page = 'https://www.westerndigital.com/zh-cn/support' }
    '2717' = @{ name = 'Xiaomi'; page = 'https://www.mi.com/service/' }
    '05E3' = @{ name = 'Genesys Logic'; page = 'http://www.genesyslogic.com.tw/' }
    '0A12' = @{ name = 'Cambridge Silicon Radio'; page = 'https://www.qualcomm.com/support' }
    '413C' = @{ name = 'Dell';   page = 'https://www.dell.com/support/home/zh-cn' }
    '17EF' = @{ name = 'Lenovo'; page = 'https://support.lenovo.com.cn/' }
}

# 厂商名（Win32_PnPSignedDriver 的 DriverProviderName）→ 官网。用来给偏旧驱动
# 指路；Microsoft 自带驱动没有厂商页，单独说明。
$providerPages = @{
    'intel'                  = 'https://www.intel.cn/content/www/cn/zh/support/detect.html'
    'intel corporation'      = 'https://www.intel.cn/content/www/cn/zh/support/detect.html'
    'nvidia'                 = 'https://www.nvidia.cn/Download/index.aspx'
    'nvidia corporation'     = 'https://www.nvidia.cn/Download/index.aspx'
    'realtek'                = 'https://www.realtek.com/Download/List?cate_id=584'
    'realtek semiconductor corp.' = 'https://www.realtek.com/Download/List?cate_id=584'
    'amd'                    = 'https://www.amd.com/zh-hans/support'
    'advanced micro devices' = 'https://www.amd.com/zh-hans/support'
    'logitech'               = 'https://support.logi.com/'
    'broadcom'               = 'https://www.broadcom.com/support/download-search'
    'qualcomm atheros'      = 'https://www.qualcomm.com/support'
    'qualcomm'               = 'https://www.qualcomm.com/support'
    'micro-star int''l co., ltd.' = 'https://cn.msi.com/support'
    'asustek computer inc.'  = 'https://www.asus.com.cn/support/'
    'dell'                   = 'https://www.dell.com/support/home/zh-cn'
    'lenovo'                 = 'https://support.lenovo.com.cn/'
}

# 旧日期阈值：契约要求按真实日期算。730 天 = 2 年。
# 允许调用方用 -ParamFile 传 oldDays 覆盖（面板可能要"只列 1 年以上"），非法值一律回落默认，
# 不给 0 / 负数 / 非数字留出把整个 B 段变成空列表的机会。
# Read-ProbeParams 无文件时返回 @{}、有文件时返回 PSCustomObject，两种都要能取：
# 对 PSCustomObject 用 $p['k'] 索引实测取不到值（返回空），必须走 PSObject.Properties。
function Get-ParamValue {
    param($Params, [string]$Name)
    if ($null -eq $Params) { return $null }
    if ($Params -is [System.Collections.IDictionary]) {
        if ($Params.Contains($Name)) { return $Params[$Name] }
        return $null
    }
    $prop = $Params.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

$oldDays = 730
$rawDays = Get-ParamValue -Params $params -Name 'oldDays'
$parsedDays = 0
if ($null -ne $rawDays -and [int]::TryParse([string]$rawDays, [ref]$parsedDays)) {
    if ($parsedDays -ge 30 -and $parsedDays -le 7300) { $oldDays = $parsedDays }
}
# 注意：$oldDays 在这里就定型，后面所有阈值判断与文案都用它，不再重算。

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

# 设备名 → 可用于 id 的片段。中文保留（\p{L} 含 CJK），其余非字母数字压成 '-'。
# 末尾附一段 InstanceId 的短哈希：两台「未知设备」名字相同，不加哈希就会撞 id。
function ConvertTo-SafeIdPart {
    param([string]$Text, [string]$Seed)
    $s = ''
    if ($Text) { $s = [regex]::Replace($Text, '[^\p{L}\p{N}]+', '-').Trim('-').ToLower() }
    if (-not $s) { $s = 'unknown' }
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).Trim('-') }
    $sha = [System.Security.Cryptography.SHA1]::HashData(
        [System.Text.Encoding]::UTF8.GetBytes([string]$Seed))
    $hex = ([System.BitConverter]::ToString($sha) -replace '-', '').Substring(0, 6).ToLower()
    return "$s-$hex"
}

# label 控制在 12 字以内（契约要求），超了截断加省略号。
function Limit-Label {
    param([string]$Text, [int]$Max = 12)
    if (-not $Text) { return '未知设备' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 1) + '…'
}

# 从 HardwareID / CompatibleID / InstanceId 里解析 VEN/DEV（PCI）或 VID/PID（USB）。
# 返回 @{ Ven=..; Dev=..; Vid=..; Pid=..; VendorKey=.. }，取不到就是空串。
function Resolve-Ids {
    param([string[]]$HardwareIds, [string[]]$CompatibleIds, [string]$InstanceId)
    $r = @{ Ven = ''; Dev = ''; Vid = ''; Pid = ''; VendorKey = '' }
    $hay = @()
    if ($HardwareIds)   { $hay += $HardwareIds }
    if ($CompatibleIds) { $hay += $CompatibleIds }
    if ($InstanceId)    { $hay += $InstanceId }

    foreach ($h in $hay) {
        if (-not $h) { continue }
        if (-not $r.Ven -and $h -match 'VEN_([0-9A-Fa-f]{4})') { $r.Ven = $Matches[1].ToUpper() }
        if (-not $r.Dev -and $h -match 'DEV_([0-9A-Fa-f]{4})') { $r.Dev = $Matches[1].ToUpper() }
        if (-not $r.Vid -and $h -match 'VID_([0-9A-Fa-f]{4})') { $r.Vid = $Matches[1].ToUpper() }
        if (-not $r.Pid -and $h -match 'PID_([0-9A-Fa-f]{4})') { $r.Pid = $Matches[1].ToUpper() }
    }
    # PCI 的 VEN_ 优先当厂商键；没有再看 USB 的 VID_。两者都是 PCI/USB 的
    # 厂商 ID 空间，内建表里按四位十六进制存放。
    if ($r.Ven)     { $r.VendorKey = $r.Ven }
    elseif ($r.Vid) { $r.VendorKey = $r.Vid }
    return $r
}

# ---------------------------------------------------------------------------
# 厂商预设：lib/presets/drivers.json 优先，缺失时用内建最小映射并如实标注。
# ---------------------------------------------------------------------------
$presetPath = Join-Path (Join-Path $PSScriptRoot '..') 'presets/drivers.json'
$vendorMap  = @{}
$presetState = 'missing'          # missing | loaded | invalid
if (Test-Path -LiteralPath $presetPath) {
    try {
        $rawPreset = Get-Content -LiteralPath $presetPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # 约定形状：{ vendors: { "8086": { name, driverPage } } }；也兼容 data.vendors。
        $vset = $rawPreset.vendors
        if (-not $vset -and $rawPreset.data) { $vset = $rawPreset.data.vendors }
        if ($vset) {
            foreach ($p in $vset.PSObject.Properties) {
                $page = [string]$p.Value.driverPage
                if (-not $page) { $page = [string]$p.Value.page }
                $nm = [string]$p.Value.name
                if ($page -or $nm) {
                    $vendorMap[$p.Name.ToUpper()] = @{ name = $nm; page = $page }
                }
            }
            if ($vendorMap.Count -gt 0) { $presetState = 'loaded' } else { $presetState = 'invalid' }
        } else {
            $presetState = 'invalid'
        }
    } catch {
        $presetState = 'invalid'
    }
}
if ($presetState -ne 'loaded') {
    foreach ($k in $builtinVendors.Keys) { $vendorMap[$k] = $builtinVendors[$k] }
}

# ===========================================================================
# A. 未安装 / 缺驱动的硬件
# ===========================================================================

$allDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue)
$scannedDevices = $allDevices.Count

# 分桶：只有 bucket 落在 bad* 里的设备才是用户需要处理的对象。
#   missing      代码 28 / 1 / 18 —— 真的没驱动或驱动残缺
#   cannotstart  代码 10           —— 有驱动但起不来（常见于驱动版本不匹配）
#   stopped      代码 43           —— 被 Windows 主动停掉（设备报错）
#   disabled     代码 22           —— 用户/软件禁用，不是缺驱动
#   notpresent   代码 45 / 24 / Present=False —— 已拔出或幽灵设备，什么都不用做
#   other        Status 异常但码是别的
$bucketOrder = @('missing', 'cannotstart', 'stopped', 'disabled', 'other')
$buckets = @{
    missing = [System.Collections.Generic.List[object]]::new()
    cannotstart = [System.Collections.Generic.List[object]]::new()
    stopped = [System.Collections.Generic.List[object]]::new()
    disabled = [System.Collections.Generic.List[object]]::new()
    other = [System.Collections.Generic.List[object]]::new()
    notpresent = [System.Collections.Generic.List[object]]::new()
}

foreach ($d in $allDevices) {
    $code = 0
    try { $code = [int]$d.ConfigManagerErrorCode } catch { $code = 0 }
    $problem = [string]$d.Problem
    $status  = [string]$d.Status
    $present = $d.Present

    # 幽灵判定优先：45 / CM_PROB_PHANTOM / Present=False 三者任一成立，都不是
    # "缺驱动"，而是"这台机器上现在没有这硬件"。
    $isPhantom = ($code -eq 45) -or ($problem -eq 'CM_PROB_PHANTOM') -or ($present -eq $false)

    $bucket = $null
    if ($isPhantom)                    { $bucket = 'notpresent' }
    elseif ($code -eq 22)              { $bucket = 'disabled' }
    elseif ($code -eq 28 -or $code -eq 1 -or $code -eq 18) { $bucket = 'missing' }
    elseif ($code -eq 24)              { $bucket = 'notpresent' }
    elseif ($code -eq 10)              { $bucket = 'cannotstart' }
    elseif ($code -eq 43)              { $bucket = 'stopped' }
    elseif ($code -ne 0)               { $bucket = 'other' }
    elseif ($status -eq 'Error' -or $status -eq 'Degraded') { $bucket = 'other' }
    # Status=Unknown 且码为 0 且 Present=True 的设备，实测是 PnP 的未标注状态，
    # 既没有错误码也没有问题描述，报出来只会制造噪音 —— 计入总数，不算问题。

    if ($bucket -and $buckets.ContainsKey($bucket)) { $buckets[$bucket].Add($d) }
}

$missingTotal = 0
foreach ($b in $bucketOrder) { $missingTotal += $buckets[$b].Count }
$notPresentTotal = $buckets['notpresent'].Count

# ---- A-2. 逐台取 HardwareID ----
# Get-PnpDeviceProperty(DEVPKEY_Device_HardwareIds) 是权威来源，但实测 500 ms/
# 次；对它逐台调用会把 30s 预算烧光。所以只对上面筛出来的问题设备调用，并且
# 设 6 秒总预算：超预算就回落到 Get-PnpDevice 实体自带 / Win32_PnPEntity 的
# HardwareID（同源数据，实测与 DEVPKEY 一致），并在 detail 里注明回落过。
$propBudgetMs = 6000
$propSpentMs  = 0
$propFallbacks = 0
# 回落 2 用的 Win32_PnPEntity 惰性字典（首次真正需要时才枚举，避免白付 340 ms）
$pnpEntityMap = $null

function Get-DeviceHardwareIds {
    param($Device, [string]$InstanceId)
    $ids = @()
    $usedFallback = $false

    $p = $null
    if ($InstanceId -and $propSpentMs -lt $propBudgetMs) {
        $t0 = Get-Date
        $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue
        $script:propSpentMs += [int]((Get-Date) - $t0).TotalMilliseconds
    } elseif ($InstanceId) {
        $usedFallback = $true
    }
    if ($p -and $p.Data) { $ids = @($p.Data) }

    if (-not $ids -or $ids.Count -eq 0) {
        # 回落 1：Get-PnpDevice 实体自带的 HardwareID（同一次 PnP 查询的结果）
        $own = $Device.HardwareID
        if ($own) { $ids = @($own); if (-not $p) { $usedFallback = $true } }
    }
    if ((-not $ids -or $ids.Count -eq 0) -and $InstanceId) {
        # 回落 2：CIM Win32_PnPEntity。实测单条 -Filter 也要 327 ms、全量枚举 340 ms，
        # 单条查询并不便宜，所以第一次用到时枚举一次建 PNPDeviceID 字典，后续命中即可。
        # （-Filter 里的实例 ID 含反斜杠和 &，转义很容易写错，字典法顺带避开这个坑。）
        if ($null -eq $script:pnpEntityMap) {
            $script:pnpEntityMap = @{}
            $allEnt = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue
            foreach ($e in @($allEnt)) {
                $pk = [string]$e.PNPDeviceID
                if ($pk -and -not $script:pnpEntityMap.ContainsKey($pk)) { $script:pnpEntityMap[$pk] = $e }
            }
        }
        if ($script:pnpEntityMap.ContainsKey($InstanceId)) {
            $ent = $script:pnpEntityMap[$InstanceId]
            if ($ent -and $ent.HardwareID) { $ids = @($ent.HardwareID); $usedFallback = $true }
        }
    }
    return @{ Ids = @($ids); Fallback = $usedFallback }
}

function Get-DeviceCompatibleIds {
    param($Device, [string]$InstanceId)
    $ids = @()
    if ($InstanceId -and $propSpentMs -lt $propBudgetMs) {
        $t0 = Get-Date
        $p = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_CompatibleIds' -ErrorAction SilentlyContinue
        $script:propSpentMs += [int]((Get-Date) - $t0).TotalMilliseconds
        if ($p -and $p.Data) { $ids = @($p.Data) }
    }
    if (-not $ids -or $ids.Count -eq 0) {
        if ($Device.CompatibleID) { $ids = @($Device.CompatibleID) }
    }
    return @($ids)
}

# 单台最多报 10 条，防止一台机器几十台坏设备把面板刷爆；被截掉的写进 detail。
$detailCap = 10
$reported = 0
$suppressed = 0
$seenInstance = @{}

foreach ($b in $bucketOrder) {
    foreach ($dev in $buckets[$b]) {
        $inst = [string]$dev.InstanceId
        if ($inst -and $seenInstance.ContainsKey($inst)) { continue }
        if ($inst) { $seenInstance[$inst] = $true }

        if ($reported -ge $detailCap) { $suppressed++; continue }

        $code = 0
        try { $code = [int]$dev.ConfigManagerErrorCode } catch { $code = 0 }
        $friendly = [string]$dev.FriendlyName
        if (-not $friendly) { $friendly = [string]$dev.Name }
        if (-not $friendly) { $friendly = '未知设备' }
        $className = [string]$dev.Class
        if (-not $className) { $className = [string]$dev.PNPClass }

        $hwInfo = Get-DeviceHardwareIds -Device $dev -InstanceId $inst
        $hw = @($hwInfo.Ids)
        if ($hwInfo.Fallback) { $propFallbacks++ }
        $compat = Get-DeviceCompatibleIds -Device $dev -InstanceId $inst
        $ids = Resolve-Ids -HardwareIds $hw -CompatibleIds $compat -InstanceId $inst

        $firstHw = ''
        if ($hw.Count -gt 0 -and $hw[0]) { $firstHw = [string]$hw[0] }

        # 厂商页：drivers.json 优先，内建兜底
        $vName = ''
        $vPage = ''
        if ($ids.VendorKey -and $vendorMap.ContainsKey($ids.VendorKey)) {
            $vName = [string]$vendorMap[$ids.VendorKey].name
            $vPage = [string]$vendorMap[$ids.VendorKey].page
        }

        $codeText = ''
        if ($cmCodeText.ContainsKey($code)) { $codeText = [string]$cmCodeText[$code] }
        elseif ($code -ne 0) { $codeText = "错误码 $code（含义未收录）" }

        # 状态的中文定性——这一句是 A-4 的核心：缺驱动 / 被禁用 / 已拔出 必须分开说。
        switch ($b) {
            'missing'     { $stateText = '真的没有可用驱动'; $st = 'bad' }
            'cannotstart' { $stateText = '有驱动但设备起不来'; $st = 'bad' }
            'stopped'     { $stateText = '被 Windows 停止（设备报错）'; $st = 'bad' }
            'disabled'    { $stateText = '被禁用，不是缺驱动'; $st = 'warn' }
            default       { $stateText = '状态异常'; $st = 'warn' }
        }

        $idPart = ConvertTo-SafeIdPart -Text $friendly -Seed $inst
        $valBits = @()
        if ($code -ne 0) { $valBits += "错误码 $code" } else { $valBits += "Status $([string]$dev.Status)" }
        $valBits += $stateText
        $value = ($valBits -join ' · ')

        $det = @()
        $det += "名称：$friendly"
        if ($className) { $det += "类别：$className" }
        if ($codeText) { $det += "代码含义：$codeText" }
        if ($firstHw) { $det += "HardwareID：$firstHw" }
        $venBits = @()
        if ($ids.Ven) { $venBits += "VEN $($ids.Ven)" }
        if ($ids.Dev) { $venBits += "DEV $($ids.Dev)" }
        if ($ids.Vid) { $venBits += "VID $($ids.Vid)" }
        if ($ids.Pid) { $venBits += "PID $($ids.Pid)" }
        if ($venBits.Count -gt 0) { $det += ($venBits -join ' / ') }
        if ($vName) { $det += "厂商：$vName" }
        if ($hwInfo.Fallback) { $det += '属性查询超预算/无结果，已回落 PnP 实体自带 HardwareID' }
        $detail = ($det -join '；')

        $fixBits = @()
        if ($b -eq 'disabled') {
            $fixBits += '这是被禁用，不需要装驱动：设备管理器里右键「启用设备」'
        } elseif ($b -eq 'stopped') {
            $fixBits += '先在设备管理器查看该设备的「事件」页确认报错原因，再考虑回滚/重装驱动'
        } else {
            $fixBits += '设备管理器里右键该设备 → 更新驱动程序 → 自动搜索；或到厂商官网按型号下载'
        }
        if ($vPage) { $fixBits += "厂商驱动页：$vPage" }
        elseif ($ids.VendorKey) { $fixBits += "厂商 ID $($ids.VendorKey) 未收录官方下载页，请按机器型号到品牌支持站查找" }
        else { $fixBits += '没有解析出厂商 ID（可能是通用总线设备），按机器品牌/型号到品牌支持站查找' }
        $fix = ($fixBits -join '；')

        Add-Item -List $items -Id "drv2:missing-$idPart" -Group 'missing' `
            -Label (Limit-Label -Text $friendly) -Status $st -Value $value -Detail $detail `
            -Fix $fix -NeedsAdmin $false
        $reported++
    }
}

# ---- A-1/A-5 汇总行：几台、分别是什么、去哪下 ----
# 「缺驱动」这个词只留给真的需要装/修驱动的三桶（missing / cannotstart / stopped）。
# 被禁用的设备虽然也是"要处理"，但它明明有驱动，混进来会让 0 台缺驱动的机器报成 1 台。
$needDriverTotal = $buckets['missing'].Count + $buckets['cannotstart'].Count + $buckets['stopped'].Count
$disabledTotal   = $buckets['disabled'].Count
$countStatus = 'ok'
if ($needDriverTotal -gt 0) { $countStatus = 'bad' }
elseif ($disabledTotal -gt 0) { $countStatus = 'warn' }

$countValueBits = @("缺驱动 $needDriverTotal 台")
if ($disabledTotal -gt 0) { $countValueBits += "被禁用 $disabledTotal 台" }
$countValue = ($countValueBits -join '，')

$countDetailBits = @()
$countDetailBits += "共扫描 $scannedDevices 台 PnP 设备"
if ($missingTotal -gt 0) {
    $partBits = @()
    foreach ($b in $bucketOrder) {
        $n = $buckets[$b].Count
        if ($n -le 0) { continue }
        switch ($b) {
            'missing'     { $partBits += "缺驱动 $n" }
            'cannotstart' { $partBits += "无法启动 $n" }
            'stopped'     { $partBits += "被停止 $n" }
            'disabled'    { $partBits += "被禁用 $n（有驱动，只需启用）" }
            default       { $partBits += "其他异常 $n" }
        }
    }
    $countDetailBits += ('需处理：' + ($partBits -join '、'))
} else {
    $countDetailBits += '未发现缺驱动 / 无法启动 / 被禁用的设备'
}
if ($notPresentTotal -gt 0) {
    # 这一句是 A-4 的另一种体现：幽灵设备不是"缺驱动"，不能混进上面那个数。
    $countDetailBits += "另有 $notPresentTotal 台已拔出/幽灵设备（代码 45/24 或 Present=False），它们不占缺驱动名额、也不用装驱动"
}
if ($suppressed -gt 0) { $countDetailBits += "问题设备超过 $detailCap 台，另有 $suppressed 台未逐条列出" }
$countDetail = ($countDetailBits -join '；')

# 一台设备都没采到，说明 "0 台缺驱动" 不是结论而是测不到：这种情况下只出一行
# skip，不能先报 ok 再补一行 skip（同一个 id 出两行，UI 会重复渲染）。
if ($scannedDevices -eq 0) {
    Add-Item -List $items -Id 'drv2:missing-count' -Group 'missing' `
        -Label '缺驱动硬件' -Status 'skip' -Value '未采集到设备列表' `
        -Detail 'Get-PnpDevice 返回 0 台设备，可能 WMI/Plug-and-Play 服务异常，本项未测到' `
        -Fix '检查 Plug and Play 服务（PlugPlay）是否运行' -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'drv2:missing-count' -Group 'missing' `
        -Label '缺驱动硬件' -Status $countStatus -Value $countValue -Detail $countDetail `
        -Fix $(if ($missingTotal -gt 0) { '按下面各行的厂商驱动页下载，或先跑一次 Windows Update 的可选驱动更新' } else { '' }) `
        -NeedsAdmin $false
}

# ===========================================================================
# B. 偏旧驱动（客观事实，不声称"有新版"）
# ===========================================================================

$signed = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue)
$signedState = 'ok'
if ($signed.Count -eq 0) { $signedState = 'empty' }

# 同一款驱动会在 Win32_PnPSignedDriver 里重复出现（每个设备实例一行，本机 168 行
# → 108 个不同的 名称+版本+日期 组合）。不去重的话 Top 10 会被同一个 INF 占满。
$dedup = @{}
foreach ($s in $signed) {
    $name = [string]$s.DeviceName
    if (-not $name) { continue }
    $ver  = [string]$s.DriverVersion
    $dtRaw = $s.DriverDate
    $dt = $null
    if ($dtRaw) { try { $dt = [datetime]$dtRaw } catch { $dt = $null } }
    # CIM 里 DriverDate 已被解析成本地 DateTime（实测本机输出 2006/6/21 8:00:00，
    # 不是带时区的字符串），所以直接相减即可，不做时区再换算。
    $key = "$name|$ver|$($dtRaw)"
    if ($dedup.ContainsKey($key)) { continue }

    $prov = [string]$s.DriverProviderName
    # 1968-07-18 / 1970 这类日期是 INF 里的哨兵值（没填日期），不是真实发布日。
    # 把它们当"最旧驱动"排进 Top 10 会把真正该看的第三方驱动挤掉，所以单独归类。
    $sentinel = $false
    if ($dt -and $dt.Year -lt 1990) { $sentinel = $true }

    $ageDays = $null
    if ($dt) { $ageDays = [math]::Round(((Get-Date) - $dt).TotalDays, 0) }

    $dedup[$key] = [pscustomobject]@{
        Name     = $name
        Version  = $ver
        Date     = $dt
        Prov     = $prov
        Class    = [string]$s.DeviceClass
        Sentinel = $sentinel
        AgeDays  = $ageDays
        IsInbox  = ($prov -eq 'Microsoft')
    }
}

$allRows = @($dedup.Values)
$oldAll = @($allRows | Where-Object { $null -ne $_.AgeDays -and $_.AgeDays -gt $oldDays })
$sentinelRows = @($oldAll | Where-Object { $_.Sentinel })
$oldReal = @($oldAll | Where-Object { -not $_.Sentinel })
$oldInbox = @($oldReal | Where-Object { $_.IsInbox })
# 只有第三方厂商的驱动才谈得上"去厂商官网更新"；Microsoft 自带驱动随 Windows
# 更新走，把它们排进 Top 10 只会让每一行都指向同一个无边界的入口。
$oldThird = @($oldReal | Where-Object { -not $_.IsInbox })

# 契约警告：绝不对 OrderedDictionary 行用 Sort-Object -Property <键>（静默不排序）。
# 这里行是 PSCustomObject，仍然统一用 scriptblock 取日期，避免踩同一个坑。
$topOld = @($oldThird | Sort-Object -Property { $_.Date } | Select-Object -First 10)

foreach ($r in $topOld) {
    $dtTxt = $r.Date.ToString('yyyy-MM-dd')
    $yearsTxt = [math]::Round($r.AgeDays / 365.25, 1)
    $page = ''
    $pkey = $r.Prov.ToLower()
    if ($providerPages.ContainsKey($pkey)) { $page = $providerPages[$pkey] }

    $st = 'warn'
    $idPart = ConvertTo-SafeIdPart -Text $r.Name -Seed "$($r.Name)|$($r.Version)|$($r.Date)"
    $detBits = @("提供方：$($r.Prov)", "类别：$($r.Class)", "发布日期距今 $yearsTxt 年")
    if ($page) { $detBits += "厂商驱动页：$page" } else { $detBits += '该厂商未收录官方下载页，请按机器品牌到支持站查找' }
    $fixBits = @()
    if ($page) { $fixBits += "到厂商官网按型号查最新驱动：$page" } else { $fixBits += '到机器品牌支持站按型号查驱动' }
    $fixBits += '是否有新版需要你自己在官网上核对——本探针没有版本数据库，不判定"已过期"'

    Add-Item -List $items -Id "drv2:old-$idPart" -Group 'old' `
        -Label (Limit-Label -Text $r.Name) -Status $st `
        -Value "$dtTxt · $($r.Version)" -Detail ($detBits -join '；') `
        -Fix ($fixBits -join '；') -NeedsAdmin $false
}

# 偏旧驱动的总览行：把"第三方 N 个 / 微软自带 M 个 / 占位日期 K 个"一次说清，
# 免得用户以为 Top 10 就是全部，也免得 0 条时面板一片空白看不出结论。
$oldCountStatus = 'info'
if ($topOld.Count -eq 0) { $oldCountStatus = 'ok' }
$oldCountValue = "$($oldThird.Count) 个第三方驱动早于 2 年"
$oldCountDetailBits = @()
$oldCountDetailBits += "共 $($signed.Count) 行签名驱动记录，去重后 $($allRows.Count) 个（名称+版本+日期）"
$oldCountDetailBits += "超过 $oldDays 天的：第三方 $($oldThird.Count) 个、Microsoft 自带 $($oldInbox.Count) 个"
if ($sentinelRows.Count -gt 0) {
    $oldCountDetailBits += "另有 $($sentinelRows.Count) 个的 DriverDate 是占位值（1989 年及以前，多为芯片组 INF 未填日期），未参与 Top 排序"
}
if ($topOld.Count -gt 0) { $oldCountDetailBits += '下面按日期升序列出最旧的 10 个第三方驱动' }
$oldCountDetail = ($oldCountDetailBits -join '；')

if ($signedState -eq 'empty') {
    Add-Item -List $items -Id 'drv2:old-count' -Group 'old' `
        -Label '偏旧驱动统计' -Status 'skip' -Value '未采集到驱动记录' `
        -Detail 'Win32_PnPSignedDriver 返回 0 行，可能是 WMI 仓库异常，本项未测到' `
        -Fix '可运行 winmgmt /verifyrepository 检查 WMI 仓库' -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'drv2:old-count' -Group 'old' `
        -Label '偏旧驱动统计' -Status $oldCountStatus -Value $oldCountValue -Detail $oldCountDetail `
        -Fix '' -NeedsAdmin $false
}

# 内建说明：Windows 本地没有"最新驱动版本"数据库。
# 这一行是本探针的边界声明，必须存在——否则"驱动偏旧"很容易被读成"检测到有新版"。
$vcount = [math]::Round($propSpentMs / 1000, 1)
Add-Item -List $items -Id 'drv2:boundary' -Group 'old' `
    -Label '判断边界' -Status 'info' -Value '本地无新版数据库' `
    -Detail ('Windows 本地没有"厂商最新驱动版本"数据库，唯一官方途径是 Windows Update 或厂商官网；' +
              '本探针只报「哪些驱动日期偏旧 + 厂商官网在哪」，不会、也不能声称检测到了新版本。' +
              '日期取自 INF 的 DriverDate，厂商重新签名而内容不变时这个日期也会变，故仅作参考。') `
    -Fix '' -NeedsAdmin $false

# 需要管理员才能做的事：本探针只读，一件都不代做。
Add-Item -List $items -Id 'drv2:admin-ops' -Group 'missing' `
    -Label '需要管理员' -Status 'info' -Value '3 类操作' `
    -Detail ('这些必须你自己在管理员环境执行，本探针不代做：' +
              '① 手动装 INF：pnputil /add-driver <路径>\*.inf /install；' +
              '② 触发驱动扫描/取可选驱动：设置 → Windows 更新 → 可选更新 → 驱动程序更新；' +
              '③ 重装某台设备的驱动：设备管理器 → 右键 → 卸载设备（勾选删除驱动）→ 重新扫描硬件改动。' +
              '删除驱动包用 pnputil /delete-driver oemNN.inf /uninstall，有风险，本工具不提供。') `
    -Fix '以管理员身份打开终端后自行执行；本探针是只读的' -NeedsAdmin $true

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
$noteBits = @()
if ($presetState -eq 'loaded') { $noteBits += '厂商映射来自 lib/presets/drivers.json' }
elseif ($presetState -eq 'missing') { $noteBits += 'drivers.json missing，已用内建最小厂商映射' }
else { $noteBits += 'drivers.json 存在但无法解析，已用内建最小厂商映射' }
$noteBits += "需装/修驱动的问题设备 $needDriverTotal 台，被禁用 $disabledTotal 台，已拔出/幽灵 $notPresentTotal 台"
$noteBits += "偏旧第三方驱动 $($oldThird.Count) 个（阈值 $oldDays 天）"
$noteBits += ('耗时 ' + [int](((Get-Date) - $started).TotalMilliseconds) + ' ms')

Write-ProbeResult -Items $items -Extra @{
    scannedDevices   = $scannedDevices
    missingTotal     = $missingTotal
    needDriverTotal  = $needDriverTotal
    notPresentTotal  = $notPresentTotal
    reportedDevices  = $reported
    suppressedDevices = $suppressed
    bucketMissing    = $buckets['missing'].Count
    bucketCannotStart = $buckets['cannotstart'].Count
    bucketStopped    = $buckets['stopped'].Count
    bucketDisabled   = $buckets['disabled'].Count
    bucketOther      = $buckets['other'].Count
    signedRows       = $signed.Count
    dedupedDrivers   = $allRows.Count
    oldThirdParty    = $oldThird.Count
    oldInbox         = $oldInbox.Count
    sentinelDates    = $sentinelRows.Count
    propertyFallbacks = $propFallbacks
    propertyMs       = $propSpentMs
    vendorPreset     = $presetState
    vendorPresetMissing = ($presetState -ne 'loaded')
    oldThresholdDays = $oldDays
} -Note ($noteBits -join '；')
