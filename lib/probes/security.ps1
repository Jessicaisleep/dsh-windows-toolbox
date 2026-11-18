param([string]$ParamFile)

# ---------------------------------------------------------------------------
# security.ps1 — 安全防护体检（纯只读）
#
# This probe DECLARES readonly: it has no write path at all, so nothing here may
# call Set-*, New-ItemProperty, Remove-Item or reg write. Every value comes from
# a real read of the machine; a read that fails reports `skip` with the reason
# instead of a guess.
#
# Costs measured on this box (2026-11-17, non-elevated pwsh 7.6.10):
#   Get-MpComputerStatus      ~2500 ms  ← the single slowest call, must be given
#                                         room; it is NOT instant on a cold
#                                         Defender service
#   Get-NetFirewallProfile    ~1136 ms  (all three profiles in ONE call)
#   Get-SmbServerConfiguration ~886 ms  (SMB1 + both signature flags in ONE call)
#   NetBT interfaces           ~211 ms  (7 adapters)
#   Get-LocalUser Guest        ~109 ms
#   Get-ExecutionPolicy -List   ~43 ms
#   registry reads              ~10 ms each (Get-RegValue, never Test-Path)
#
# Several of these read machine-wide state and return values even without admin,
# but a few (Defender details, SMB1) can be trimmed for a non-elevated token on
# some builds — those failures surface as `skip`, never as a fabricated `ok`.
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList

$elevated = Test-Elevated
$timings = [ordered]@{}   # per-check wall time, reported in Extra so a slow row is visible
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

$sysPol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

# ---- 1. UAC ----------------------------------------------------------------
# Three separate knobs with three separate meanings, so three rows: EnableLUA is
# "is UAC on at all", ConsentPromptBehaviorAdmin is "does an admin get prompted
# for consent or for credentials", PromptOnSecureDesktop is "can a fake window
# click the prompt for you".
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lua = Format-RegValue (Get-RegValue -Path $sysPol -Name 'EnableLUA')
$consent = Format-RegValue (Get-RegValue -Path $sysPol -Name 'ConsentPromptBehaviorAdmin')
$secureDesk = Format-RegValue (Get-RegValue -Path $sysPol -Name 'PromptOnSecureDesktop')

if ($lua -eq 'unset') {
    Add-Item -List $items -Id 'security:uac-enablelua' -Group 'uac' -Label 'UAC 总开关' -Status 'skip' `
        -Value 'unset' -Detail 'HKLM\...\Policies\System 里没有 EnableLUA，无法判断 UAC 是否开启' `
        -Fix '把 EnableLUA 设为 1（需管理员，改完要重启）' -NeedsAdmin $true
} elseif ($lua -eq '0') {
    Add-Item -List $items -Id 'security:uac-enablelua' -Group 'uac' -Label 'UAC 总开关' -Status 'bad' `
        -Value 'EnableLUA=0' -Detail 'UAC 被完全关闭，任何程序都能不经提示拿到管理员权限' `
        -Fix '把 EnableLUA 设为 1 并重启（需管理员）。关闭 UAC 的机器上"以管理员身份运行"也不再有隔离' -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'security:uac-enablelua' -Group 'uac' -Label 'UAC 总开关' -Status 'ok' `
        -Value "EnableLUA=$lua" -Detail 'UAC 已启用，提权会经过确认' -Fix '保持现状；若被设为 0（关闭 UAC），任何程序都能静默提权，务必改回 1（需管理员）'
}

# 0 = 不提示直接提权, 1 = 安全桌面要求凭据, 2 = 安全桌面只确认, 5 = 默认(确认,
# 非 Windows 二进制才要求凭据). 0 and 1 are the two that weaken it.
$consentStatus = 'ok'
$consentDetail = '默认级别：管理员提权需在安全桌面确认'
$consentFix = '保持现状；ConsentPromptBehaviorAdmin=5 是默认级别，管理员提权需在安全桌面点"是"'
if ($consent -eq '0') {
    $consentStatus = 'bad'; $consentDetail = '提权完全不提示，程序可静默获得管理员权限'
    $consentFix = '把 ConsentPromptBehaviorAdmin 设为 5（默认）或 2，需管理员'
} elseif ($consent -eq '1') {
    $consentStatus = 'warn'; $consentDetail = '要求输入管理员密码而非确认，安全性够但易被密码弹窗疲劳战术利用'
    $consentFix = '如需与默认一致，把 ConsentPromptBehaviorAdmin 设为 5'
} elseif ($consent -eq 'unset') {
    $consentStatus = 'skip'; $consentDetail = 'HKLM\...\Policies\System 里没有这个值，无法判断提权提示方式'
    $consentFix = '把 ConsentPromptBehaviorAdmin 设为 5（需管理员）'
} elseif ($consent -ne '5' -and $consent -ne '2') {
    $consentStatus = 'info'; $consentDetail = "非常见取值 $consent，请对照 Microsoft 文档确认含义"
}
Add-Item -List $items -Id 'security:uac-consent' -Group 'uac' -Label '提权提示方式' -Status $consentStatus `
    -Value "ConsentPromptBehaviorAdmin=$consent" -Detail $consentDetail -Fix $consentFix -NeedsAdmin $true

if ($secureDesk -eq '0') {
    Add-Item -List $items -Id 'security:uac-securedesktop' -Group 'uac' -Label '安全桌面' -Status 'warn' `
        -Value 'PromptOnSecureDesktop=0' -Detail '提权提示画在普通桌面上，其它程序可以模拟点击确认' `
        -Fix '把 PromptOnSecureDesktop 设为 1（需管理员）' -NeedsAdmin $true
} elseif ($secureDesk -eq 'unset') {
    Add-Item -List $items -Id 'security:uac-securedesktop' -Group 'uac' -Label '安全桌面' -Status 'skip' `
        -Value 'unset' -Detail '没有 PromptOnSecureDesktop，无法判断提权提示是否在安全桌面' `
        -Fix '把 PromptOnSecureDesktop 设为 1（需管理员）' -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'security:uac-securedesktop' -Group 'uac' -Label '安全桌面' -Status 'ok' `
        -Value "PromptOnSecureDesktop=$secureDesk" -Detail '提权提示在独立安全桌面，普通程序无法伪造点击' -Fix '保持现状；若被改成 0 请改回 1，否则其它程序可模拟点击提权弹窗（需管理员）'
}
$timings['uac'] = $sw.ElapsedMilliseconds

# ---- 2. SmartScreen --------------------------------------------------------
# Two different stores. HKCU AppHost::EnableWebContentEvaluation is the per-user
# switch Settings > Apps > SmartScreen writes; the HKLM policy is what a
# managed machine enforces and it OVERRIDES the user switch.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$ssUser = Format-RegValue (Get-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost' -Name 'EnableWebContentEvaluation')
$ssPol = Format-RegValue (Get-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'EnableSmartScreen')

if ($ssUser -eq '0') {
    Add-Item -List $items -Id 'security:smartscreen-user' -Group 'smartscreen' -Label 'SmartScreen(用户)' -Status 'warn' `
        -Value 'EnableWebContentEvaluation=0' -Detail '已关闭应用与文件的 SmartScreen 检查，未知来源的下载不会被拦截' `
        -Fix '在 Windows 安全中心 > 应用和浏览器控制 > 基于声誉的保护 中开启 SmartScreen'
} elseif ($ssUser -eq 'unset') {
    Add-Item -List $items -Id 'security:smartscreen-user' -Group 'smartscreen' -Label 'SmartScreen(用户)' -Status 'info' `
        -Value 'unset' -Detail 'AppHost 下没有这个值，表示使用系统默认（开启），不是关闭' -Fix '无需处理；若想显式开启，把 EnableWebContentEvaluation 设为 1（HKCU，不需要管理员）'
} else {
    Add-Item -List $items -Id 'security:smartscreen-user' -Group 'smartscreen' -Label 'SmartScreen(用户)' -Status 'ok' `
        -Value "EnableWebContentEvaluation=$ssUser" -Detail 'SmartScreen 对下载内容生效' -Fix '保持现状；关闭后未知来源的下载将不再被拦截'
}

if ($ssPol -eq 'off' -or $ssPol -eq '0') {
    Add-Item -List $items -Id 'security:smartscreen-policy' -Group 'smartscreen' -Label 'SmartScreen(策略)' -Status 'bad' `
        -Value "EnableSmartScreen=$ssPol" -Detail '组策略强制关闭 SmartScreen，用户自己的开关会被覆盖' `
        -Fix '删除 HKLM\SOFTWARE\Policies\Microsoft\Windows\System 下的 EnableSmartScreen（需管理员）' -NeedsAdmin $true
} elseif ($ssPol -eq 'unset') {
    Add-Item -List $items -Id 'security:smartscreen-policy' -Group 'smartscreen' -Label 'SmartScreen(策略)' -Status 'ok' `
        -Value 'unset' -Detail '没有组策略覆盖，以用户设置为准' -Fix '无需处理；没有策略覆盖时用户设置生效'
} else {
    Add-Item -List $items -Id 'security:smartscreen-policy' -Group 'smartscreen' -Label 'SmartScreen(策略)' -Status 'ok' `
        -Value "EnableSmartScreen=$ssPol" -Detail '策略层已启用 SmartScreen' -Fix '保持现状；策略层开启时用户在设置里关不掉，这正是期望状态'
}
$timings['smartscreen'] = $sw.ElapsedMilliseconds

# ---- 3. Defender -----------------------------------------------------------
# Get-MpComputerStatus measured ~2.5 s here — the slowest single call in this
# probe. It throws (rather than returning null) when the Defender service is
# stopped or a third-party AV took over, and that is exactly the case where we
# must NOT invent a value: report `skip` with the exception text.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
} catch {
    $mp = $null
    $mpErr = $_.Exception.Message
}
if ($null -eq $mp) {
    Add-Item -List $items -Id 'security:defender-rtp' -Group 'defender' -Label '实时保护' -Status 'skip' `
        -Value '读取失败' -Detail "Get-MpComputerStatus 失败：$mpErr" -Fix '以管理员重跑本探针；若仍失败，检查 WinDefend 服务是否被第三方安全软件接管'
    Add-Item -List $items -Id 'security:defender-tamper' -Group 'defender' -Label '篡改防护' -Status 'skip' `
        -Value '读取失败' -Detail 'Defender 状态不可读，无法判断篡改防护' -Fix '以管理员重跑本探针；或检查第三方安全软件是否接管了 Defender'
    Add-Item -List $items -Id 'security:defender-engine' -Group 'defender' -Label '引擎版本' -Status 'skip' `
        -Value '读取失败' -Detail 'Defender 状态不可读，无法取引擎版本' -Fix '以管理员重跑本探针；或检查第三方安全软件是否接管了 Defender'
} else {
    $rtp = [string]$mp.RealTimeProtectionEnabled
    $av = [string]$mp.AntivirusEnabled
    $tamper = [string]$mp.IsTamperProtected
    $eng = [string]$mp.AMEngineVersion

    if ($rtp -eq 'True' -and $av -eq 'True') {
        Add-Item -List $items -Id 'security:defender-rtp' -Group 'defender' -Label '实时保护' -Status 'ok' `
            -Value "RealTimeProtectionEnabled=True · AntivirusEnabled=True" `
            -Detail 'Defender 正在实时拦截文件与进程' -Fix '保持现状；实时保护关闭后恶意文件可立即执行'
    } else {
        Add-Item -List $items -Id 'security:defender-rtp' -Group 'defender' -Label '实时保护' -Status 'bad' `
            -Value "RealTimeProtectionEnabled=$rtp · AntivirusEnabled=$av" `
            -Detail '实时保护或防病毒未启用，机器处于无防护状态（若装有第三方杀软，Defender 会让位）' `
            -Fix '在 Windows 安全中心重新开启实时保护；若装的是第三方杀软，请确认它自己的实时防护是开的' -NeedsAdmin $true
    }

    if ($tamper -eq 'True') {
        Add-Item -List $items -Id 'security:defender-tamper' -Group 'defender' -Label '篡改防护' -Status 'ok' `
            -Value 'IsTamperProtected=True' -Detail '恶意程序无法通过关掉 Defender 来绕过防护' -Fix '保持现状；篡改防护关闭后程序可自行关掉实时保护'
    } else {
        Add-Item -List $items -Id 'security:defender-tamper' -Group 'defender' -Label '篡改防护' -Status 'warn' `
            -Value "IsTamperProtected=$tamper" -Detail '篡改防护未开启，程序可以自行关闭 Defender 的实时保护' `
            -Fix 'Windows 安全中心 > 病毒和威胁防护 > 管理设置 中打开篡改防护' -NeedsAdmin $true
    }

    Add-Item -List $items -Id 'security:defender-engine' -Group 'defender' -Label '引擎版本' -Status 'info' `
        -Value "AMEngineVersion=$eng" -Detail 'Defender 反恶意软件引擎版本，仅作记录' -Fix '无需处理；引擎随 Windows 更新自动升级，长期不更新才需要检查更新'
}

try {
    $pref = Get-MpPreference -ErrorAction Stop
    $prefErr = ''
} catch {
    $pref = $null
    $prefErr = $_.Exception.Message
}
if ($null -eq $pref) {
    Add-Item -List $items -Id 'security:defender-pua' -Group 'defender' -Label 'PUA 防护' -Status 'skip' `
        -Value '读取失败' -Detail "Get-MpPreference 失败：$prefErr" -Fix '以管理员重跑本探针；或检查第三方安全软件是否接管了 Defender'
    Add-Item -List $items -Id 'security:defender-cfa' -Group 'defender' -Label '受控文件夹' -Status 'skip' `
        -Value '读取失败' -Detail 'Defender 偏好不可读，无法判断受控文件夹访问' -Fix '以管理员重跑本探针；或检查第三方安全软件是否接管了 Defender'
    Add-Item -List $items -Id 'security:defender-asr' -Group 'defender' -Label 'ASR 规则' -Status 'skip' `
        -Value '读取失败' -Detail 'Defender 偏好不可读，无法统计攻击面缩减规则' -Fix '以管理员重跑本探针；或检查第三方安全软件是否接管了 Defender'
} else {
    $pua = [string]$pref.PUAProtection
    # 0 关闭 / 1 阻止 / 2 审计
    $puaStatus = 'warn'; $puaDetail = '潜在不受欢迎程序不会被拦截'
    if ($pua -eq '1') { $puaStatus = 'ok'; $puaDetail = '潜在不受欢迎程序（捆绑安装器、广告软件）会被拦截' }
    elseif ($pua -eq '2') { $puaStatus = 'info'; $puaDetail = '审计模式：只记录不拦截' }
    Add-Item -List $items -Id 'security:defender-pua' -Group 'defender' -Label 'PUA 防护' -Status $puaStatus `
        -Value "PUAProtection=$pua" -Detail $puaDetail `
        -Fix $(if ($puaStatus -ne 'ok') { '把 PUAProtection 设为 1（阻止），需管理员' } else { '保持现状；阻止潜在垃圾软件后，捆绑安装器会被拦下' }) -NeedsAdmin ($puaStatus -ne 'ok')

    $cfa = [string]$pref.EnableControlledFolderAccess
    # 0 关闭 / 1 阻止 / 2 审计
    $cfaStatus = 'info'; $cfaDetail = '受控文件夹访问关闭，勒索软件可以直接改写文档目录'
    if ($cfa -eq '1') { $cfaStatus = 'ok'; $cfaDetail = '受控文件夹访问已启用，未授权程序不能改写受保护目录' }
    elseif ($cfa -eq '2') { $cfaStatus = 'info'; $cfaDetail = '审计模式：只记录篡改尝试，不阻止' }
    elseif ($cfa -eq '0') { $cfaStatus = 'ok'; $cfaDetail = '受控文件夹访问未启用（系统默认，不算异常）' }
    Add-Item -List $items -Id 'security:defender-cfa' -Group 'defender' -Label '受控文件夹' -Status $cfaStatus `
        -Value "EnableControlledFolderAccess=$cfa" -Detail $cfaDetail `
        -Fix $(if ($cfa -eq '0') { '可选加固：开启受控文件夹访问（阻止模式），需先在白名单里放行日常软件' } else { '保持现状；已启用时勒索软件改不了文档与图片目录' })

    $asrIds = @($pref.AttackSurfaceReductionRules_Ids)
    $asrCount = $asrIds.Count
    Add-Item -List $items -Id 'security:defender-asr' -Group 'defender' -Label 'ASR 规则' -Status $(if ($asrCount -gt 0) { 'ok' } else { 'info' }) `
        -Value "已配置 $asrCount 条" -Detail '攻击面缩减规则条数（含审计与阻止模式）' `
        -Fix $(if ($asrCount -eq 0) { '可选加固：用 Defender 的 ASR 阻止 Office 宏与脚本类常见注入手法' } else { '保持现状；已配置的规则会拦截宏与脚本注入，新增规则见 Microsoft 的 ASR 参考页' })
}
$timings['defender'] = $sw.ElapsedMilliseconds

# ---- 4. SMB1 + SMB signing (ONE call, ~886 ms) -----------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $smb = Get-SmbServerConfiguration -ErrorAction Stop
    $smbErr = ''
} catch {
    $smb = $null
    $smbErr = $_.Exception.Message
}
if ($null -eq $smb) {
    foreach ($pair in @(
            @('security:smb1', 'SMBv1 协议', 'Get-SmbServerConfiguration 失败'),
            @('security:smb-signing', 'SMB 签名', 'Get-SmbServerConfiguration 失败'))) {
        Add-Item -List $items -Id $pair[0] -Group 'smb' -Label $pair[1] -Status 'skip' `
            -Value '读取失败' -Detail "$($pair[2])：$smbErr" -Fix '以管理员重跑本探针；读取 SMB 服务器配置需要管理员权限' -NeedsAdmin $true
    }
} else {
    $smb1 = [string]$smb.EnableSMB1Protocol
    if ($smb1 -eq 'True') {
        Add-Item -List $items -Id 'security:smb1' -Group 'smb' -Label 'SMBv1 协议' -Status 'bad' `
            -Value 'EnableSMB1Protocol=True' -Detail 'SMBv1 有永恒之蓝一类远程执行漏洞，且已被微软弃用' `
            -Fix '关闭 SMBv1（Set-SmbServerConfiguration -EnableSMB1Protocol $false 或 控制面板 > 程序 > 启用或关闭 Windows 功能），需管理员并重启' -NeedsAdmin $true
    } else {
        Add-Item -List $items -Id 'security:smb1' -Group 'smb' -Label 'SMBv1 协议' -Status 'ok' `
            -Value 'EnableSMB1Protocol=False' -Detail 'SMBv1 已关闭，不受永恒之蓝类漏洞影响' -Fix '保持现状；不要为了老打印机 / 老 NAS 重新启用 SMBv1'
    }

    $reqSig = [string]$smb.RequireSecuritySignature
    $enSig = [string]$smb.EnableSecuritySignature
    # For a server, RequireSecuritySignature is the one that matters; the legacy
    # Enable flag alone does not reject unsigned clients.
    if ($reqSig -eq 'True') {
        Add-Item -List $items -Id 'security:smb-signing' -Group 'smb' -Label 'SMB 签名' -Status 'ok' `
            -Value "RequireSecuritySignature=$reqSig · EnableSecuritySignature=$enSig" `
            -Detail '要求签名，中间人无法篡改 SMB 会话内容' -Fix '保持现状；若这里是 False，可把 RequireSecuritySignature 设为 True 加固（需管理员）'
    } else {
        Add-Item -List $items -Id 'security:smb-signing' -Group 'smb' -Label 'SMB 签名' -Status 'warn' `
            -Value "RequireSecuritySignature=$reqSig · EnableSecuritySignature=$enSig" `
            -Detail '未强制签名，同一网络内的中间人可以篡改或重放 SMB 流量' `
            -Fix 'Set-SmbServerConfiguration -RequireSecuritySignature $true（需管理员；老式扫描仪/NAS 若只支持 SMB1 会连不上）' -NeedsAdmin $true
    }
}
$timings['smb'] = $sw.ElapsedMilliseconds

# ---- 5. LLMNR --------------------------------------------------------------
# Absent policy value means LLMNR is ON (the Windows default) — that is a real
# exposure, not "unknown", because the default is enabled.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$llmnr = Format-RegValue (Get-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast')
if ($llmnr -eq '0') {
    Add-Item -List $items -Id 'security:llmnr' -Group 'netname' -Label 'LLMNR' -Status 'ok' `
        -Value 'EnableMulticast=0' -Detail 'LLMNR 已关闭，Responder 一类的中毒攻击失去入口' -Fix '保持现状；若被改回开启，把 EnableMulticast 设为 0（需管理员）'
} elseif ($llmnr -eq 'unset') {
    Add-Item -List $items -Id 'security:llmnr' -Group 'netname' -Label 'LLMNR' -Status 'warn' `
        -Value 'unset(默认开启)' -Detail '没有策略值即系统默认开启；同名解析请求会被局域网内任何主机应答，可用于抓 NTLM 哈希' `
        -Fix '新建 HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient 的 EnableMulticast=0（DWORD，需管理员）' -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'security:llmnr' -Group 'netname' -Label 'LLMNR' -Status 'warn' `
        -Value "EnableMulticast=$llmnr" -Detail '该值不是 0，LLMNR 仍按默认开启' `
        -Fix '把 EnableMulticast 设为 0（需管理员）' -NeedsAdmin $true
}
$timings['llmnr'] = $sw.ElapsedMilliseconds

# ---- 6. NetBIOS over TCP/IP ------------------------------------------------
# NetbiosOptions: 0 = 由 DHCP 决定(通常启用), 1 = 启用, 2 = 禁用. Per adapter, so
# the row reports how many are explicitly disabled out of how many exist. 0 is
# counted as "not explicitly disabled" — that is the honest reading, even though
# the DHCP default may resolve to enabled.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$nbtRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
$nbtIfaces = @(Get-ChildItem -LiteralPath $nbtRoot -ErrorAction SilentlyContinue)
if ($nbtIfaces.Count -eq 0) {
    Add-Item -List $items -Id 'security:netbios' -Group 'netname' -Label 'NetBIOS over TCP' -Status 'skip' `
        -Value '无网卡条目' -Detail "读不到 $nbtRoot 下的网卡子键" -Fix '以管理员重跑；或检查 NetBT 服务是否被禁用'
} else {
    $disabled = 0; $enabled = 0; $dhcp = 0
    foreach ($iface in $nbtIfaces) {
        $opt = Get-RegValue -Path $iface.PSPath -Name 'NetbiosOptions'
        $optText = Format-RegValue $opt
        if ($optText -eq '2') { $disabled++ }
        elseif ($optText -eq '1') { $enabled++ }
        else { $dhcp++ }
    }
    $nbtStatus = 'warn'
    if ($disabled -eq $nbtIfaces.Count) { $nbtStatus = 'ok' }
    elseif ($enabled -gt 0) { $nbtStatus = 'bad' }
    Add-Item -List $items -Id 'security:netbios' -Group 'netname' -Label 'NetBIOS over TCP' -Status $nbtStatus `
        -Value "$($nbtIfaces.Count) 块网卡 · 禁用 $disabled · 启用 $enabled · DHCP默认 $dhcp" `
        -Detail 'NetBIOS 名称服务同样可被伪造应答套取 NTLM 哈希；2=禁用，1=启用，0=跟随 DHCP' `
        -Fix $(if ($nbtStatus -ne 'ok') { '在每块网卡的 IPv4 高级 > WINS 里选"禁用 TCP/IP 上的 NetBIOS"（或把 NetbiosOptions 设为 2，需管理员）' } else { '' }) `
        -NeedsAdmin ($nbtStatus -ne 'ok')
}
$timings['netbios'] = $sw.ElapsedMilliseconds

# ---- 7. AutoRun / AutoPlay -------------------------------------------------
# NoDriveTypeAutoRun is a bitmask (0xFF = all drives). 0x91 is the Windows
# default: 0x90 (no unknown/removable autoplay) + 0x01 (no unknown media).
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$autorunKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$ndt = Format-RegValue (Get-RegValue -Path $autorunKey -Name 'NoDriveTypeAutoRun')
$noAuto = Format-RegValue (Get-RegValue -Path $autorunKey -Name 'NoAutorun')
if ($ndt -eq 'unset') {
    Add-Item -List $items -Id 'security:autorun-drives' -Group 'autorun' -Label '自动播放策略' -Status 'warn' `
        -Value 'NoDriveTypeAutoRun=unset' -Detail '没有策略值，U 盘插入时的自动播放走系统默认，未知介质仍可能自动执行' `
        -Fix '新建上述键下的 NoDriveTypeAutoRun=255（DWORD，禁用所有驱动器的自动播放，需管理员）' -NeedsAdmin $true
} else {
    $ndtVal = 0
    $parsed = [int]::TryParse($ndt, [ref]$ndtVal)
    if ($parsed -and $ndtVal -ge 255) {
        Add-Item -List $items -Id 'security:autorun-drives' -Group 'autorun' -Label '自动播放策略' -Status 'ok' `
            -Value "NoDriveTypeAutoRun=$ndt" -Detail '所有驱动器的自动播放均已禁用' -Fix '保持现状；不要把 NoDriveTypeAutoRun 改回 0'
    } else {
        Add-Item -List $items -Id 'security:autorun-drives' -Group 'autorun' -Label '自动播放策略' -Status 'warn' `
            -Value "NoDriveTypeAutoRun=$ndt" -Detail '掩码未覆盖全部驱动器类型，部分介质插入后仍会触发自动播放' `
            -Fix '把 NoDriveTypeAutoRun 设为 255（需管理员）' -NeedsAdmin $true
    }
}
Add-Item -List $items -Id 'security:autorun-noautorun' -Group 'autorun' -Label 'NoAutorun 策略' -Status 'info' `
    -Value "NoAutorun=$noAuto" -Detail 'unset 表示未单独设置（以 NoDriveTypeAutoRun 掩码为准）' -Fix '无需处理；若想单独锁定自动运行，把 NoAutorun 设为 1（需管理员）'
$timings['autorun'] = $sw.ElapsedMilliseconds

# ---- 8. RDP ----------------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rdp = Format-RegValue (Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections')
if ($rdp -eq '0') {
    Add-Item -List $items -Id 'security:rdp' -Group 'remote' -Label '远程桌面' -Status 'warn' `
        -Value 'fDenyTSConnections=0' -Detail '远程桌面已开启，3389 端口对内网（若端口映射则对公网）暴露在暴力破解面前' `
        -Fix '不使用远程桌面就把它关掉：fDenyTSConnections=1（需管理员）；必须用时限制来源 IP 并开启 NLA' -NeedsAdmin $true
} elseif ($rdp -eq 'unset') {
    Add-Item -List $items -Id 'security:rdp' -Group 'remote' -Label '远程桌面' -Status 'skip' `
        -Value 'unset' -Detail '读不到 fDenyTSConnections，无法判断远程桌面是否开启' `
        -Fix '用 系统属性 > 远程 确认远程桌面状态' -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'security:rdp' -Group 'remote' -Label '远程桌面' -Status 'ok' `
        -Value "fDenyTSConnections=$rdp" -Detail '远程桌面已关闭' -Fix '保持现状；确实需要远程时再打开（fDenyTSConnections=0）并限制来源 IP'
}
$timings['rdp'] = $sw.ElapsedMilliseconds

# ---- 9. Guest account ------------------------------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $guest = Get-LocalUser -Name 'Guest' -ErrorAction Stop
    $guestErr = ''
} catch {
    $guest = $null
    $guestErr = $_.Exception.Message
}
if ($null -eq $guest) {
    Add-Item -List $items -Id 'security:guest' -Group 'accounts' -Label 'Guest 账户' -Status 'skip' `
        -Value '读取失败' -Detail "Get-LocalUser -Name Guest 失败：$guestErr" -Fix '以管理员重跑本探针；查询本地账户需要管理员权限'
} elseif ($guest.Enabled) {
    Add-Item -List $items -Id 'security:guest' -Group 'accounts' -Label 'Guest 账户' -Status 'bad' `
        -Value 'Enabled=True' -Detail 'Guest 是无需密码的匿名入口，开启后可被用来枚举共享与横向移动' `
        -Fix '禁用 Guest 账户：net user Guest /active:no（需管理员）' -NeedsAdmin $true
} else {
    Add-Item -List $items -Id 'security:guest' -Group 'accounts' -Label 'Guest 账户' -Status 'ok' `
        -Value 'Enabled=False' -Detail 'Guest 账户已禁用' -Fix '保持现状；不要启用 Guest，它无密码且可被远程利用'
}
$timings['guest'] = $sw.ElapsedMilliseconds

# ---- 10. PowerShell execution policy ---------------------------------------
# One row per scope is noise (all five usually read the same); collapse into one
# value that names the effective scope, and only the scopes that are actually
# defined.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $epList = @(Get-ExecutionPolicy -List -ErrorAction Stop)
    $epErr = ''
} catch {
    $epList = @()
    $epErr = $_.Exception.Message
}
if ($epList.Count -eq 0) {
    Add-Item -List $items -Id 'security:execution-policy' -Group 'powershell' -Label '执行策略' -Status 'skip' `
        -Value '读取失败' -Detail "Get-ExecutionPolicy -List 失败：$epErr" -Fix '以管理员重跑；或检查组策略是否限制了读取'
} else {
    $defined = @()
    $effective = 'Undefined'
    # Precedence: MachinePolicy > UserPolicy > Process > CurrentUser > LocalMachine
    foreach ($scopeName in @('MachinePolicy', 'UserPolicy', 'Process', 'CurrentUser', 'LocalMachine')) {
        $row = $epList | Where-Object { [string]$_.Scope -eq $scopeName } | Select-Object -First 1
        if (-not $row) { continue }
        $pol = [string]$row.ExecutionPolicy
        if ($pol -eq 'Undefined') { continue }
        $defined += "$scopeName=$pol"
        if ($effective -eq 'Undefined') { $effective = $pol }
    }
    if ($defined.Count -eq 0) {
        Add-Item -List $items -Id 'security:execution-policy' -Group 'powershell' -Label '执行策略' -Status 'warn' `
            -Value '全部 Undefined' -Detail '没有任何 scope 定义执行策略，脚本运行不受限制' `
            -Fix '把当前用户范围的执行策略设为 RemoteSigned（本探针只读，只提示不代改）'
    } else {
        # Bypass / Unrestricted at the effective scope is the only real risk here;
        # this probe is READ-ONLY and must never call Set-ExecutionPolicy itself.
        $epStatus = 'ok'
        if ($effective -in @('Bypass', 'Unrestricted')) { $epStatus = 'warn' }
        Add-Item -List $items -Id 'security:execution-policy' -Group 'powershell' -Label '执行策略' -Status $epStatus `
            -Value ("生效 $effective · " + ($defined -join ' · ')) `
            -Detail '执行策略只防误运行，不是安全边界；Bypass/Unrestricted 时任何 .ps1 都可直接跑' `
            -Fix $(if ($epStatus -ne 'ok') { '把生效 scope 改为 RemoteSigned（本工具不会替你改执行策略）' } else { '保持现状；RemoteSigned 允许本地脚本、拦下未签名的下载脚本' })
    }
}
$timings['executionpolicy'] = $sw.ElapsedMilliseconds

# ---- 11. VBS / DeviceGuard / LSA protection -------------------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$vbs = Format-RegValue (Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' -Name 'EnableVirtualizationBasedSecurity')
# 0 关闭 / 1 启用(未运行时不启) / 2 启用(运行时也启)
$vbsStatus = 'info'; $vbsDetail = 'VBS 未显式启用（系统默认，取决于硬件与策略）'
if ($vbs -eq '1' -or $vbs -eq '2') { $vbsStatus = 'ok'; $vbsDetail = '基于虚拟化的安全已启用，凭据保护有硬件隔离基础' }
elseif ($vbs -eq '0') { $vbsStatus = 'warn'; $vbsDetail = 'VBS 被显式关闭，Credential Guard / HVCI 一并失效' }
Add-Item -List $items -Id 'security:vbs' -Group 'deviceguard' -Label 'VBS 虚拟化安全' -Status $vbsStatus `
    -Value "EnableVirtualizationBasedSecurity=$vbs" -Detail $vbsDetail `
    -Fix $(if ($vbs -eq '0') { '把 EnableVirtualizationBasedSecurity 设为 1（需管理员并在 BIOS 开启虚拟化）' } else { '保持现状；可用 msinfo32 的"基于虚拟化的安全性"确认是否已在运行' }) `
    -NeedsAdmin ($vbs -eq '0')

$lsaPpl = Format-RegValue (Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL')
# unset = 未开 LSA 保护（Win11 22H2+ 默认开启，值可能仍不写）；1 = 启用；2 = 启用且 UEFI 变量锁定
if ($lsaPpl -eq '1' -or $lsaPpl -eq '2') {
    Add-Item -List $items -Id 'security:lsa-ppl' -Group 'deviceguard' -Label 'LSA 保护' -Status 'ok' `
        -Value "RunAsPPL=$lsaPpl" -Detail 'lsass 以受保护进程运行，Mimikatz 一类读内存抓密码会失败' -Fix '保持现状；若这里是 unset，可选加固：把 RunAsPPL 设为 1（需管理员，部分驱动会不兼容）'
} else {
    Add-Item -List $items -Id 'security:lsa-ppl' -Group 'deviceguard' -Label 'LSA 保护' -Status 'warn' `
        -Value "RunAsPPL=$lsaPpl" -Detail '未开启 LSA 保护，攻击者取得本地权限后可直接从 lsass 读凭据' `
        -Fix '把 HKLM\SYSTEM\CurrentControlSet\Control\Lsa 的 RunAsPPL 设为 1（DWORD，需管理员并重启）' -NeedsAdmin $true
}
$timings['deviceguard'] = $sw.ElapsedMilliseconds

# ---- 12. Firewall (all three profiles, ONE call ~1136 ms) ------------------
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $fw = @(Get-NetFirewallProfile -ErrorAction Stop)
    $fwErr = ''
} catch {
    $fw = @()
    $fwErr = $_.Exception.Message
}
if ($fw.Count -eq 0) {
    Add-Item -List $items -Id 'security:firewall' -Group 'firewall' -Label '防火墙' -Status 'skip' `
        -Value '读取失败' -Detail "Get-NetFirewallProfile 失败：$fwErr" -Fix '以管理员重跑本探针；读取防火墙配置需要管理员权限' -NeedsAdmin $true
} else {
    $off = @()
    $on = @()
    foreach ($p in $fw) {
        if ([string]$p.Enabled -eq 'True') { $on += [string]$p.Name } else { $off += [string]$p.Name }
    }
    if ($off.Count -eq 0) {
        Add-Item -List $items -Id 'security:firewall' -Group 'firewall' -Label '防火墙三档' -Status 'ok' `
            -Value "已开启：$(($on -join ' / '))" -Detail '三个网络配置档都在拦截入站连接' -Fix '保持现状；三个配置档都要保持开启，关掉公用档等于在咖啡厅裸奔'
    } else {
        Add-Item -List $items -Id 'security:firewall' -Group 'firewall' -Label '防火墙三档' -Status 'bad' `
            -Value "已关闭：$($off -join ' / ')（已开启：$($on -join ' / ')）" `
            -Detail '有关闭的配置档，处于该网络的入站连接不再被过滤' `
            -Fix 'Set-NetFirewallProfile -All -Enabled True（需管理员）' -NeedsAdmin $true
    }
}
$timings['firewall'] = $sw.ElapsedMilliseconds

# ---- 13. Device installation restrictions --------------------------------
# Normally unset (the key does not even exist) — that is the default state, so
# "unset" is `info`, not `warn`. This row is here so the panel shows the fact
# instead of silently omitting it.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$diRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$diPolicy = Format-RegValue (Get-RegValue -Path $diRoot -Name 'DenyUnspecified')
$diKeyExists = $null -ne (Get-Item -LiteralPath $diRoot -ErrorAction SilentlyContinue)
if (-not $diKeyExists) {
    Add-Item -List $items -Id 'security:device-install' -Group 'deviceguard' -Label '设备安装限制' -Status 'info' `
        -Value '策略未配置' -Detail '没有设备安装限制策略，插入新硬件时 Windows 会自动装驱动' -Fix '默认状态，无需处理；如需禁止未知设备自动安装，把 DenyUnspecified 设为 1（需管理员）'
} else {
    Add-Item -List $items -Id 'security:device-install' -Group 'deviceguard' -Label '设备安装限制' -Status 'info' `
        -Value "DenyUnspecified=$diPolicy" -Detail '已存在设备安装限制策略键' `
        -Fix $(if ($diPolicy -ne '1') { '如需禁止未知设备自动安装，把 DenyUnspecified 设为 1（需管理员）' } else { '' })
}
$timings['deviceinstall'] = $sw.ElapsedMilliseconds

$swTotal.Stop()

Write-ProbeResult -Items $items -Extra @{
    probeMs  = [int64]$swTotal.ElapsedMilliseconds
    timings  = $timings
    elevated = $elevated
} -Note $(if ($elevated) { '管理员上下文：所有项均可读。' } else { '普通权限：Defender 细节与 SMB 配置在部分系统上可能只返回部分字段，读不到的项会标 skip。' })
