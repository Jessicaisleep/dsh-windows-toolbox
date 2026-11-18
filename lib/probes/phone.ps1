param([string]$ParamFile)

# ---------------------------------------------------------------------------
# phone.ps1 — 手机连接 / 便携设备（只读）
#
# 回答四个问题：能不能连手机、连上了没有、用什么连（MTP / Phone Link）、
# 缺什么。全部只读，不装不删不改配置。
#
# THE TRAP THIS FILE EXISTS TO AVOID
# ----------------------------------
# 在 PowerShell 7 下 Get-AppxPackage 会这样失败：
#   在模块 'Appx' 中找到了 'Get-AppxPackage' 命令，但由于以下错误而无法加载该模块:
#   [Operation is not supported on this platform. (0x80131539)]
# 而且**不抛错、直接返回空表**。看起来就像"本机没装任何 AppX"，是静默假零。
# 本机实测真实数量是 100。所以任何一次 AppX 读取都必须先用 count > 0 验真，
# 不能只看"命令在不在"。
#
# AppX 三段式（与同作者 dsh-windows-toolbox 的 appx.ps1 同一思路）：
#   1. WinPS 兼容桥 Import-Module Appx -UseWindowsPowerShell，验证 count>0；
#   2. 失败则用 System32 下的 powershell.exe 5.1 子进程 + -EncodedCommand 取 JSON；
#   3. 再失败则读注册表 AppxAllUserStore\Applications（条目少，只是不撒谎的兜底）。
# 桥接回来的对象是**反序列化**的：Version 变字符串、方法全丢，所以每个字段都
# 用 try/catch 防御式读取。
#
# 其它两处本机实测的坑，写在这里省下一次调试：
#   * Get-PnpDevice -PresentOnly 在没有匹配项时抛「未找到匹配的 Win32_PnPEntity
#     对象」并以 exit 1 结束（-ErrorAction SilentlyContinue 也压不住 CIM 查询
#     错误）。所以一律取全量再按 .Present 过滤。
#   * Win32_PnPEntity 里**没有** PNPClass='WPD' 的实例，vivo 手机也查不到。
#     想拿便携设备必须回落到 Get-PnpDevice -Class WPD；两路都查、按 DeviceID 去重。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
# 注意：本文件按项目惯例保存为**不带 BOM 的 UTF-8**，只有 PowerShell 7 才能正确
# 解析其中的中文。所以 5.1 只以子进程身份出现，且给它的 -EncodedCommand 内容是
# 纯 ASCII（中文只出现在父进程这一侧）。别把本脚本整份丢给 powershell.exe 5.1 跑。
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items  = New-ProbeList

# ===========================================================================
# 1. 手机相关 AppX：Phone Link / 跨设备组件
# ===========================================================================
$appxPattern = 'YourPhone|PhoneLink|CrossDevice|PhoneExperience'
$appxCount   = 0
$appxSource  = 'empty'
$appxRows    = @()
$appxNote    = ''

function Get-AppxInventory {
    $inv = [ordered]@{ rows = @(); source = 'empty'; count = 0 }

    # ---- (1) 本进程：PS7 走兼容桥，5.1 走原生 ----
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    }
    $probe = @(Get-AppxPackage -ErrorAction SilentlyContinue)
    if ($probe.Count -gt 0) {
        $rows = foreach ($a in $probe) {
            $ver = ''
            try { $ver = [string]$a.Version } catch { }
            $fam = ''
            try { $fam = [string]$a.PackageFamilyName } catch { }
            $loc = ''
            try { $loc = [string]$a.InstallLocation } catch { }
            [pscustomobject]@{
                name     = [string]$a.Name
                family   = $fam
                version  = $ver
                location = $loc
            }
        }
        $inv.rows   = @($rows)
        $inv.source = if ($PSVersionTable.PSVersion.Major -ge 7) { 'bridged' } else { 'native' }
        $inv.count  = $probe.Count
        return $inv
    }

    # ---- (2) 5.1 子进程 ----
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps51) {
        # 子进程脚本用单引号 here-string：里面不出现双引号，免得和 -EncodedCommand
        # 的引号转义互相打架。子进程里显式把 stdout 设成 UTF-8，父进程按 UTF-8 解，
        # 中文才不会变乱码（5.1 重定向时的默认编码是系统代码页）。
        $child = @'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
try { $p = @(Get-AppxPackage) } catch { $p = @() }
$rows = foreach ($x in $p) {
    [pscustomobject]@{
        name     = [string]$x.Name
        family   = [string]$x.PackageFamilyName
        version  = [string]$x.Version
        location = [string]$x.InstallLocation
    }
}
$json = ConvertTo-Json -InputObject @{ rows = @($rows); count = $p.Count } -Depth 4 -Compress
[Console]::Out.Write($json)
'@
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($child))
        try {
            $si = New-Object System.Diagnostics.ProcessStartInfo
            $si.FileName  = $ps51
            $si.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc"
            $si.UseShellExecute        = $false
            $si.RedirectStandardOutput = $true
            $si.RedirectStandardError  = $true
            $si.CreateNoWindow         = $true
            $si.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
            $pi = [System.Diagnostics.Process]::Start($si)
            # 先 ReadToEnd 再等退出：反过来的话管道满了会互相等死。
            $out = $pi.StandardOutput.ReadToEnd()
            $null = $pi.StandardError.ReadToEnd()
            if (-not $pi.WaitForExit(20000)) {
                try { $pi.Kill() } catch { }
            } elseif (-not [string]::IsNullOrWhiteSpace($out)) {
                $parsed = $out | ConvertFrom-Json
                if ($parsed -and $parsed.count -gt 0) {
                    $inv.rows   = @($parsed.rows)
                    $inv.source = 'ps51'
                    $inv.count  = [int]$parsed.count
                    return $inv
                }
            }
        } catch { }
    }

    # ---- (3) 注册表兜底：键名形如 Name_Version_neutral_~_Publisher ----
    $store = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications'
    $keys = @(Get-ChildItem -LiteralPath $store -ErrorAction SilentlyContinue)
    if ($keys.Count -gt 0) {
        $rows = foreach ($k in $keys) {
            $parts = ([string]$k.PSChildName) -split '_'
            [pscustomobject]@{
                name     = if ($parts.Count -ge 1) { $parts[0] } else { '' }
                family   = [string]$k.PSChildName
                version  = if ($parts.Count -ge 2) { $parts[1] } else { '' }
                location = ''
            }
        }
        $inv.rows   = @($rows)
        $inv.source = 'registry'
        $inv.count  = $keys.Count
    }
    return $inv
}

$appx = Get-AppxInventory
$appxRows   = @($appx.rows)
$appxCount  = [int]$appx.count
$appxSource = [string]$appx.source

$appxNote = switch ($appxSource) {
    'bridged'  { 'Appx 模块经 WinPS 兼容桥读取' }
    'native'   { '本进程即 Windows PowerShell 5.1，原生读取' }
    'ps51'     { '本进程读不到，改由 powershell.exe 5.1 子进程读取' }
    'registry' { '两条 API 都读不到，退化为注册表登记清单（条目偏少，仅供参考）' }
    default    { '三条路径都读不到 AppX 清单' }
}

if ($appxCount -eq 0) {
    Add-Item -List $items -Id 'phone:appx-inventory' -Group 'AppX' -Label 'AppX 清单' -Status 'skip' `
        -Value '0 个包' `
        -Detail "三条路径（WinPS 桥 / 5.1 子进程 / 注册表兜底）都没拿到包。$appxNote" `
        -Fix '确认 Appx 相关服务与注册表可读后重跑；此处不是"本机没装 AppX"的结论'
} else {
    $phoneRows = @($appxRows | Where-Object {
        ([string]$_.name   -match $appxPattern) -or
        ([string]$_.family -match $appxPattern)
    })

    if ($phoneRows.Count -eq 0) {
        Add-Item -List $items -Id 'phone:appx-phonelink' -Group 'AppX' -Label 'Phone Link（手机连接）' -Status 'skip' `
            -Value '未安装' `
            -Detail "在 $appxCount 个 AppX 包里没找到 YourPhone / PhoneLink / CrossDevice（来源：$appxSource）" `
            -Fix '从 Microsoft Store 安装「手机连接 / Phone Link」（包名 Microsoft.YourPhone），登录同一微软账户后可同步通知与剪贴板'
    } else {
        foreach ($p in $phoneRows) {
            $n = [string]$p.name
            $slug = if ($n -match 'YourPhone') { 'phonelink' }
                    elseif ($n -match 'CrossDevice') { 'crossdevice' }
                    elseif ($n -match 'PhoneExperience') { 'phoneexperience' }
                    else { (($n -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLower() }
            $ver = [string]$p.version
            if (-not $ver) { $ver = '版本未知' }
            Add-Item -List $items -Id "phone:appx-$slug" -Group 'AppX' -Label "AppX · $n" -Status 'ok' `
                -Value "已安装 · $ver" `
                -Detail "family=$([string]$p.family)；安装位置 $([string]$p.location)" `
                -Fix '剪贴板共享与投屏需要它在手机与电脑两端登录同一微软账户'
        }
    }
}

# ===========================================================================
# 2. 已连接的便携设备（WPD / MTP）
# ===========================================================================
# 两路都查：Get-PnpDevice 有 Problem 字段但可能整类不存在；Win32_PnPEntity 更通用
# 但本机实测根本没有 PNPClass='WPD' 的实例。各自的产出按 DeviceID 合并。
$rawDevices = @()
$deviceSrc  = ''

$wpdDevs = @()
try { $wpdDevs = @(Get-PnpDevice -Class WPD -ErrorAction SilentlyContinue) } catch { $wpdDevs = @() }
if ($wpdDevs.Count -gt 0) {
    $deviceSrc = 'Get-PnpDevice'
    foreach ($d in $wpdDevs) {
        $rawDevices += [pscustomobject]@{
            name     = [string]$d.FriendlyName
            deviceId = [string]$d.InstanceId
            present  = [bool]$d.Present
            status   = [string]$d.Status
            problem  = [string]$d.Problem
            cls      = [string]$d.Class
            source   = 'Get-PnpDevice'
        }
    }
}

$pnp = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue)
$pnpHits = @($pnp | Where-Object {
    ([string]$_.PNPClass -eq 'WPD') -or
    ([string]$_.Name -match 'MTP|Android|iPhone|Apple Mobile|便携设备|Portable Device')
})
foreach ($d in $pnpHits) {
    $rawDevices += [pscustomobject]@{
        name     = [string]$d.Name
        deviceId = [string]$d.DeviceID
        present  = [bool]$d.Present
        status   = [string]$d.Status
        problem  = if ([int]$d.ConfigManagerErrorCode -eq 0) { 'CM_PROB_NONE' } else { "ConfigManagerErrorCode=$([int]$d.ConfigManagerErrorCode)" }
        cls      = [string]$d.PNPClass
        source   = 'Win32_PnPEntity'
    }
}
if ($pnpHits.Count -gt 0 -and $deviceSrc -eq '') { $deviceSrc = 'Win32_PnPEntity' }
if ($deviceSrc -eq '' -and $pnp.Count -gt 0) { $deviceSrc = 'Win32_PnPEntity' }

# 去重：同一个 DeviceID 只留一行，优先保留"在线"的那条。
$devMap = [ordered]@{}
foreach ($d in $rawDevices) {
    $k = [string]$d.deviceId
    if (-not $k) { $k = [string]$d.name }
    if (-not $devMap.Contains($k)) { $devMap[$k] = $d }
    elseif ($d.present -and -not $devMap[$k].present) { $devMap[$k] = $d }
}
$devices = @($devMap.Values)
$connectedUsb = @($devices | Where-Object { $_.present -and ([string]$_.deviceId) -match '^USB\\' })
$connectedAny = @($devices | Where-Object { $_.present })

if ($rawDevices.Count -eq 0) {
    Add-Item -List $items -Id 'phone:device' -Group '便携设备' -Label '便携设备' -Status 'skip' `
        -Value '未取到' `
        -Detail "Get-PnpDevice -Class WPD 与 Win32_PnPEntity 都没有返回可用条目（PnPEntity 共 $($pnp.Count) 条）" `
        -Fix '确认 PnpDevice 模块可用、CIM 可读后重跑'
} else {
    $seenIds = @{}
    foreach ($d in ($devices | Sort-Object { $_.present } -Descending)) {
        $nm = [string]$d.name
        if (-not $nm) { $nm = '(无友好名)' }
        $slug = (($nm -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLower()
        if (-not $slug) { $slug = 'unknown' }
        $id = "phone:device-$slug"
        if ($seenIds.ContainsKey($id)) { $seenIds[$id]++; $id = "$id-$($seenIds[$id])" } else { $seenIds[$id] = 1 }

        $st   = if ($d.present) { 'ok' } else { 'info' }
        $val  = if ($d.present) { '已连接' } else { '未连接（历史记录）' }
        $prob = [string]$d.problem
        $probText = if ($prob -and $prob -ne 'CM_PROB_NONE') { " · 问题码 $prob" } else { '' }
        $det = "状态 $([string]$d.status) · 类 $([string]$d.cls)$probText · $([string]$d.deviceId)"
        $fix = ''
        if (-not $d.present) { $fix = '这只是历史记录（幽灵设备），当前没有插着它；无需处理' }
        elseif ($prob -and $prob -ne 'CM_PROB_NONE') { $fix = '设备管理器里更新/重装 MTP 驱动' }
        Add-Item -List $items -Id $id -Group '便携设备' -Label "便携设备 · $nm" -Status $st -Value $val -Detail $det -Fix $fix
    }
}

# ===========================================================================
# 3. 手机助手类软件（Uninstall 三根）
# ===========================================================================
$helperPattern = '华为手机助手|HiSuite|爱思助手|iTools|豌豆荚|Wandoujia|腾讯手机管家|360手机助手|小米助手|MobileGo|手机助手|vivo\s*手机助手|互传|EasyShare|Samsung\s*(Kies|Smart\s*Switch)'
$uniRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)
$allProgs = @()
$uniRead  = 0
foreach ($r in $uniRoots) {
    # 这三个根是固定路径、只查 3 次，Test-Path 的 387ms 坑在这里不成立；
    # 而 Get-ChildItem 在 SilentlyContinue 下分不清"空"和"不存在"。
    if (-not (Test-Path -LiteralPath $r)) { continue }
    $uniRead++
    # 必须先 Get-ChildItem 再逐个子键 Get-ItemProperty：直接对根键 Get-ItemProperty
    # 只会读到根键自己的值（这里是空的），于是"共查 0 条已装程序"—— 本机实测踩过。
    foreach ($k in (Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.DisplayName) { $allProgs += $p }
    }
}
$helpers = @($allProgs | Where-Object { ([string]$_.DisplayName) -match $helperPattern })

if ($uniRead -eq 0) {
    Add-Item -List $items -Id 'phone:helper' -Group '手机助手' -Label '手机助手类软件' -Status 'skip' `
        -Value '未取到' -Detail '三个 Uninstall 注册表根都读不到，无法判断是否装了手机助手' `
        -Fix '确认当前账户能读取 HKLM/HKCU 的 Uninstall 键后重跑'
} elseif ($helpers.Count -eq 0) {
    Add-Item -List $items -Id 'phone:helper' -Group '手机助手' -Label '手机助手类软件' -Status 'info' `
        -Value "0 个（共查 $($allProgs.Count) 条已装程序）" `
        -Detail '没有华为手机助手 / 爱思助手 / 豌豆荚 / 腾讯手机管家 / 360手机助手 / 小米助手 / MobileGo 等厂商助手' `
        -Fix '厂商助手不是必需品：传文件用系统自带 MTP 即可；需要刷机、备份、截图时才装对应厂商的工具'
} else {
    $hSeen = @{}
    foreach ($h in $helpers) {
        $dn = [string]$h.DisplayName
        $slug = (($dn -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLower()
        if (-not $slug) { $slug = 'helper' }
        $id = "phone:helper-$slug"
        if ($hSeen.ContainsKey($id)) { $hSeen[$id]++; $id = "$id-$($hSeen[$id])" } else { $hSeen[$id] = 1 }
        Add-Item -List $items -Id $id -Group '手机助手' -Label "手机助手 · $dn" -Status 'info' `
            -Value ([string]$h.DisplayVersion) `
            -Detail "发布者 $([string]$h.Publisher) · 注册表键 $([string]$h.PSChildName)" `
            -Fix '这类工具通常常驻后台并附带推送；不常用时建议卸载或关闭开机自启'
    }
}

# ===========================================================================
# 4. WPD 服务（Windows Portable Devices）
# ===========================================================================
# WPDBusEnum 的 Manual/Stopped 是**正常默认值**：插上设备时由 ShellHWDetection
# 触发按需启动。所以只有 Disabled 才算问题，别把默认状态报成故障。
$wpdSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='WPDBusEnum'" -ErrorAction SilentlyContinue
$shellHw = Get-Service -Name ShellHWDetection -ErrorAction SilentlyContinue
$shellText = if ($shellHw) { "$($shellHw.Status)/$($shellHw.StartType)" } else { 'absent' }

if (-not $wpdSvc) {
    Add-Item -List $items -Id 'phone:wpd-service' -Group '服务' -Label 'WPD 服务（WPDBusEnum）' -Status 'skip' `
        -Value '未取到' -Detail 'Win32_Service 查不到 WPDBusEnum，无法判断便携设备服务状态' `
        -Fix '用 services.msc 手动确认「Windows Portable Device Enumerator Service」是否存在'
} else {
    $st = 'ok'
    if ([string]$wpdSvc.StartMode -eq 'Disabled') { $st = 'warn' }
    elseif ([string]$wpdSvc.Status -ne 'OK') { $st = 'warn' }
    Add-Item -List $items -Id 'phone:wpd-service' -Group '服务' -Label 'WPD 服务（WPDBusEnum）' -Status $st `
        -Value "$($wpdSvc.State)/$($wpdSvc.StartMode)" `
        -Detail "Manual + Stopped 是正常默认（插设备时按需启动）；设备到达通知由 ShellHWDetection 负责，当前 $shellText" `
        -Fix $(if ($st -ne 'ok') { '把 WPDBusEnum 启动类型改回「手动」并启动（需管理员）' } else { '' }) `
        -NeedsAdmin ($st -ne 'ok')
}

# ===========================================================================
# 5. MTP 驱动是否正常
# ===========================================================================
$wudf   = Get-Service -Name 'WUDFRd' -ErrorAction SilentlyContinue
$upflt  = Get-Service -Name 'WpdUpFltr' -ErrorAction SilentlyContinue
$usbWpd = @($devices | Where-Object { ([string]$_.deviceId) -match '^USB\\' })
$usbBroken = @($usbWpd | Where-Object { $_.present -and [string]$_.problem -and [string]$_.problem -ne 'CM_PROB_NONE' })
$wudfText = if ($wudf) { "$($wudf.Status)/$($wudf.StartType)" } else { 'absent' }
# 注意：WUDFRd / WpdUpFltr 是**内核驱动**，只出现在 Get-Service / Win32_SystemDriver 里，
# Win32_Service 查不到它们（本机实测返回空）。用 Win32_Service 查会把"正常"误判成 skip。

if (-not $wudf) {
    Add-Item -List $items -Id 'phone:mtp-driver' -Group '驱动' -Label 'MTP 驱动栈' -Status 'skip' `
        -Value '未取到' -Detail 'Get-Service 查不到 WUDFRd（用户模式驱动框架），无法判断 MTP 驱动栈' `
        -Fix '设备管理器 → 查看 → 显示隐藏的设备，确认「便携设备」下无黄色感叹号'
} else {
    $st = 'ok'
    if ([string]$wudf.Status -ne 'Running') { $st = 'warn' }
    elseif ($usbBroken.Count -gt 0) { $st = 'warn' }
    Add-Item -List $items -Id 'phone:mtp-driver' -Group '驱动' -Label 'MTP 驱动栈' -Status $st `
        -Value "WUDFRd $wudfText" `
        -Detail "WpdUpFltr $(if ($upflt) { "$($upflt.Status)/$($upflt.StartType)" } else { 'absent' })；WPD 类设备 $($devices.Count) 条，其中 USB 通道 $($usbWpd.Count) 条，报错 $($usbBroken.Count) 条" `
        -Fix $(if ($st -ne 'ok') { '启动 WUDFRd；若插手机后显示「无法识别的设备」，在设备管理器卸载该设备后重插让系统重装 MTP 驱动' } else { '' }) `
        -NeedsAdmin ($st -ne 'ok')
}

# ===========================================================================
# 6. 结论行：能做什么 / 缺什么
# ===========================================================================
$phoneNow = $connectedAny.Count
$head = if ($phoneNow -gt 0) { "检测到 $phoneNow 台在线便携设备" } else { '当前没有连接手机' }
$body = '传文件：系统自带 MTP，插 USB 后在资源管理器里直接读写手机存储（手机端需选「传输文件/MTP」，不能选「仅充电」）。' +
        '投屏：Windows 自带「无线显示器」需要手机支持 Miracast；其它情况要装手机端 App（Phone Link 或厂商投屏）。' +
        '剪贴板/通知共享：只有 Phone Link（Microsoft.YourPhone）能做，且手机与电脑要登录同一个微软账户并通过蓝牙配对。'
Add-Item -List $items -Id 'phone:conclusion' -Group '结论' -Label '手机连接能力' -Status 'info' `
    -Value $head `
    -Detail $body `
    -Fix $(if ($phoneNow -eq 0) { '要传文件就插 USB 线并选「传输文件」；要剪贴板共享先装/登录 Phone Link' } else { '' })

Write-ProbeResult -Items $items -Extra ([ordered]@{
    appxCount      = $appxCount
    appxSource     = $appxSource
    appxPhoneMatch = if ($appxRows.Count -gt 0) { @($appxRows | Where-Object { ([string]$_.name -match $appxPattern) -or ([string]$_.family -match $appxPattern) }).Count } else { 0 }
    wpdDevices     = $devices.Count
    connected      = $phoneNow
    connectedUsb   = $connectedUsb.Count
    helperApps     = $helpers.Count
    mtpDrivers     = $usbWpd.Count
}) -Note "AppX 读数来自 $appxSource（共 $appxCount 个包），已按 count>0 验真，避免 PS7 下 Appx 模块静默返回空表造成的假零。便携设备两路查阅（Get-PnpDevice -Class WPD / Win32_PnPEntity）后按 DeviceID 去重；未连接的历史设备标为幽灵设备。全程只读。"
