param([string]$ParamFile)

# ---------------------------------------------------------------------------
# winsettings.ps1 —— Win10/11 常用设置项的当前值 + 人话解释 + 改法
#
# 一行一个设置项，给：当前原始值、这个值意味着什么、要改的话动哪个键、需不需要
# 管理员。目标不是"把所有设置都列出来"，而是把用户真的会去改的那些讲清楚。
#
# ---- 性能（本机 2026-11-17 实测，决定实现方式）
#   Get-ItemProperty 读一个**不存在的子键** = 1088ms/次；本文件要读 30+ 个键，
#   里面必然有不存在/无权访问的，用 provider 会直接慢到十几秒。所以全程走
#   [Microsoft.Win32.RegistryKey]：OpenSubKey 命中与未命中都 <1ms，且打开过的
#   键在 $keyCache 里复用。整份报告实测 <200ms。
#
# ---- 继承的坑
#   1. 绝不对注册表键用 Test-Path（387ms/次）；用 OpenSubKey 返回 null 判断。
#   2. 文件名 Test-Path 是便宜的（1.6ms），hiberfil.sys 这种就该直接测文件。
#   3. Win11 才有的项（TaskbarAl / TaskbarDa / TaskbarSd）在 Win10 上就是
#      unset，这不是"读失败"，要如实报"未设置=系统默认"，不能猜一个值。
#   4. NetworkList\Profiles 本机是非管理员不可读（Requested registry access is
#      not allowed），必须落成 skip 并说明原因，不能静默当 0。
#
# 写操作只有 set，且**只允许 HKCU**（HKLM 一律拒绝，让用户自己去组策略/设置里
# 改），默认 dryRun，写前 reg export 备份到 %LOCALAPPDATA%\dsh-windows-toolbox\regbackup\。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList

$action = [string]$params.action
if (-not $action) { $action = 'scan' }
$dryRun = $true
if ($null -ne $params.dryRun -and "$($params.dryRun)" -eq 'False') { $dryRun = $false }
$isElevated = Test-Elevated

# ---- 注册表读取层 ----------------------------------------------------------
$rkLM = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$rkCU = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)

# 打开过的键缓存起来：同一个键下的多个值只 OpenSubKey 一次。
$keyCache = @{}
function Get-KeyCached {
    param([string]$Hive, [string]$Path)
    $ck = "$Hive|$Path"
    if ($keyCache.ContainsKey($ck)) { return $keyCache[$ck] }
    $root = if ($Hive -eq 'HKLM') { $rkLM } else { $rkCU }
    if ($null -eq $root) { return $null }
    $k = $null
    try { $k = $root.OpenSubKey($Path) } catch { $k = $null }
    $keyCache[$ck] = $k
    return $k
}

# 读一个值。区分三态：键不存在 / 值不存在 / 读到了。
# 这个区分很重要——"键都没有"和"值没设置"对用户的含义不同。
function Get-Val {
    param([string]$Hive, [string]$Path, [string]$Name)
    $k = Get-KeyCached -Hive $Hive -Path $Path
    if ($null -eq $k) {
        # 键打不开也可能是权限不足而不是不存在，两种情况都记成"不可读"，
        # 由调用方决定报 skip。
        return [ordered]@{ exists = $false; found = $false; value = $null; kind = '' }
    }
    $has = $false
    foreach ($n in $k.GetValueNames()) {
        if ($n -eq $Name) { $has = $true; break }
    }
    if (-not $has) {
        return [ordered]@{ exists = $true; found = $false; value = $null; kind = '' }
    }
    $v = $k.GetValue($Name, $null)
    $kd = ''
    try { $kd = [string]$k.GetValueKind($Name) } catch { }
    return [ordered]@{ exists = $true; found = $true; value = $v; kind = $kd }
}

# 原始值的短文本（byte[] 显示成 "158 30 7 128 ..."）
function Show-Val {
    param($r)
    if (-not $r.found) { return '未设置' }
    $v = $r.value
    if ($null -eq $v) { return '(空)' }
    if ($v -is [byte[]]) {
        if ($v.Length -eq 0) { return '(空字节数组)' }
        return (($v | ForEach-Object { $_.ToString() }) -join ' ')
    }
    return [string]$v
}

# ---- 设置项定义 ------------------------------------------------------------
# hive  HKCU / HKLM
# kind  int: DWORD；str: REG_SZ；也可以只是说明用
# explain 拿真实值返回 @{t=人话; s=状态}；未设置/键不存在由外层统一处理
$defs = @(
    # ---------------- 深色模式 ----------------
    @{
        id = 'winsettings:dark-mode-apps'; group = '深色模式'; label = '应用深色模式'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        name = 'AppsUseLightTheme'; kind = 'int'
        fix = '设置 → 个性化 → 颜色 → 选择"深色"；或写 HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme=0'
        explain = {
            param($v)
            if ([int]$v -eq 0) { @{ t = '深色（应用）'; s = 'ok' } } else { @{ t = '浅色（应用）'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:dark-mode-system'; group = '深色模式'; label = '系统界面深色模式'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        name = 'SystemUsesLightTheme'; kind = 'int'
        fix = '设置 → 个性化 → 颜色 → 选择"深色"；或写 SystemUsesLightTheme=0'
        explain = {
            param($v)
            if ([int]$v -eq 0) { @{ t = '深色（任务栏/开始菜单）'; s = 'ok' } } else { @{ t = '浅色（任务栏/开始菜单）'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:transparency'; group = '深色模式'; label = '透明效果'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        name = 'EnableTransparency'; kind = 'int'
        fix = '设置 → 个性化 → 颜色 → 透明效果 开/关；或写 EnableTransparency=0 关闭'
        explain = {
            param($v)
            if ([int]$v -eq 0) { @{ t = '已关闭（不透明）'; s = 'info' } } else { @{ t = '已开启（毛玻璃）'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:color-accent-taskbar'; group = '深色模式'; label = '强调色用于任务栏/开始'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        name = 'ColorPrevalence'; kind = 'int'
        fix = '设置 → 个性化 → 颜色 → "在开始菜单和任务栏上显示主题色"；或写 ColorPrevalence=1'
        explain = {
            param($v)
            if ([int]$v -eq 1) { @{ t = '已启用（任务栏用强调色）'; s = 'ok' } } else { @{ t = '未启用（跟随深/浅色）'; s = 'info' } }
        }
    },

    # ---------------- 资源管理器 ----------------
    @{
        id = 'winsettings:explorer-hide-file-ext'; group = '资源管理器'; label = '隐藏已知文件扩展名'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        name = 'HideFileExt'; kind = 'int'
        fix = '资源管理器 → 查看 → 文件扩展名；或写 HideFileExt=0 显示扩展名'
        explain = {
            param($v)
            # 隐藏扩展名是钓鱼文件伪装成 .jpg.exe 的前提，标 warn 有意义。
            if ([int]$v -eq 1) { @{ t = '隐藏中（扩展名不可见，有伪装文件风险）'; s = 'warn' } } else { @{ t = '显示扩展名'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:explorer-hidden'; group = '资源管理器'; label = '显示隐藏文件'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        name = 'Hidden'; kind = 'int'
        fix = '资源管理器 → 查看 → 显示/隐藏 → 隐藏的项目；或写 Hidden=1 显示'
        explain = {
            param($v)
            if ([int]$v -eq 1) { @{ t = '显示隐藏文件'; s = 'ok' } } else { @{ t = '不显示隐藏文件'; s = 'info' } }
        }
    },
    @{
        id = 'winsettings:explorer-superhidden'; group = '资源管理器'; label = '显示受保护的系统文件'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        name = 'ShowSuperHidden'; kind = 'int'
        fix = '资源管理器 → 查看 → 显示/隐藏 → 受保护的操作系统文件；或写 ShowSuperHidden=1'
        explain = {
            param($v)
            if ([int]$v -eq 1) { @{ t = '显示系统文件（误删风险）'; s = 'warn' } } else { @{ t = '不显示系统文件'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:explorer-launch-to'; group = '资源管理器'; label = '打开资源管理器时进入'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        name = 'LaunchTo'; kind = 'int'
        fix = '文件夹选项 → 常规 → 打开文件资源管理器时打开：此电脑/快速访问；或写 LaunchTo=1(此电脑)/2(快速访问)'
        explain = {
            param($v)
            switch ([int]$v) {
                1 { @{ t = '此电脑'; s = 'ok' } }
                2 { @{ t = '快速访问'; s = 'ok' } }
                default { @{ t = "未知取值 $v"; s = 'warn' } }
            }
        }
    },
    @{
        id = 'winsettings:explorer-recent'; group = '资源管理器'; label = '在快速访问显示最近使用文件'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Explorer'
        name = 'ShowRecent'; kind = 'int'
        fix = '文件夹选项 → 常规 → 隐私；或写 HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ShowRecent=0'
        explain = {
            param($v)
            if ([int]$v -eq 0) { @{ t = '不显示（隐私更好）'; s = 'ok' } } else { @{ t = '显示最近文件'; s = 'info' } }
        }
    },
    @{
        id = 'winsettings:explorer-frequent'; group = '资源管理器'; label = '在快速访问显示常用文件夹'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Explorer'
        name = 'ShowFrequent'; kind = 'int'
        fix = '文件夹选项 → 常规 → 隐私；或写 HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ShowFrequent=0'
        explain = {
            param($v)
            if ([int]$v -eq 0) { @{ t = '不显示常用文件夹'; s = 'ok' } } else { @{ t = '显示常用文件夹'; s = 'info' } }
        }
    },

    # ---------------- 任务栏 ----------------
    @{
        id = 'winsettings:taskbar-alignment'; group = '任务栏'; label = '任务栏图标对齐'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        name = 'TaskbarAl'; kind = 'int'
        fix = '设置 → 个性化 → 任务栏 → 任务栏行为 → 任务栏对齐方式；或写 TaskbarAl=0(左)/1(居中)。Win10 无此项'
        explain = {
            param($v)
            if ([int]$v -eq 0) { @{ t = '左对齐'; s = 'ok' } } else { @{ t = '居中'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:taskbar-search'; group = '任务栏'; label = '搜索框模式'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Search'
        name = 'SearchboxTaskbarMode'; kind = 'int'
        fix = '任务栏右键 → 搜索 → 隐藏/仅图标/搜索框；或写 HKCU\Software\Microsoft\Windows\CurrentVersion\Search\SearchboxTaskbarMode=0(隐藏)/1(图标)/2(框)'
        explain = {
            param($v)
            switch ([int]$v) {
                0 { @{ t = '已隐藏'; s = 'ok' } }
                1 { @{ t = '仅显示图标'; s = 'ok' } }
                2 { @{ t = '显示搜索框'; s = 'info' } }
                default { @{ t = "未知取值 $v"; s = 'warn' } }
            }
        }
    },
    @{
        id = 'winsettings:taskbar-taskview'; group = '任务栏'; label = '任务视图按钮'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        name = 'ShowTaskViewButton'; kind = 'int'
        fix = '任务栏右键 → 显示"任务视图"按钮；或写 ShowTaskViewButton=0/1'
        explain = {
            param($v)
            if ([int]$v -eq 1) { @{ t = '显示'; s = 'info' } } else { @{ t = '隐藏'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:taskbar-widgets'; group = '任务栏'; label = '小组件按钮（Win11）'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        name = 'TaskbarDa'; kind = 'int'
        fix = '任务栏右键 → 任务栏设置 → 小组件 关；或写 TaskbarDa=0。Win10 无此项'
        explain = {
            param($v)
            if ([int]$v -eq 1) { @{ t = '显示（有资讯推送）'; s = 'warn' } } else { @{ t = '已关闭'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:taskbar-chat'; group = '任务栏'; label = '聊天按钮（Win11）'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        name = 'TaskbarSd'; kind = 'int'
        fix = '任务栏右键 → 任务栏设置 → 聊天 关；或写 TaskbarSd=0。Win10 无此项'
        explain = {
            param($v)
            if ([int]$v -eq 1) { @{ t = '显示'; s = 'info' } } else { @{ t = '已关闭'; s = 'ok' } }
        }
    },

    # ---------------- 系统功能 ----------------
    @{
        id = 'winsettings:system-rdp'; group = '系统'; label = '远程桌面（RDP）'
        hive = 'HKLM'; path = 'SYSTEM\CurrentControlSet\Control\Terminal Server'
        name = 'fDenyTSConnections'; kind = 'int'
        fix = '设置 → 系统 → 远程桌面 → 开/关；或写 HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections=1 关闭（需管理员）'
        explain = {
            param($v)
            if ([int]$v -eq 1) { @{ t = '已拒绝连接（RDP 关闭）'; s = 'ok' } } else { @{ t = '允许远程连接（RDP 开启）'; s = 'warn' } }
        }
    },
    @{
        id = 'winsettings:system-faststartup'; group = '系统'; label = '快速启动（休眠引导）'
        hive = 'HKLM'; path = 'SYSTEM\CurrentControlSet\Control\Session Manager\Power'
        name = 'HiberbootEnabled'; kind = 'int'
        fix = '控制面板 → 电源选项 → 选择电源按钮的功能 → 启用快速启动；或写 HiberbootEnabled=0 关闭（需管理员，且需先开启休眠）'
        explain = {
            param($v)
            if ([int]$v -eq 1) { @{ t = '已开启（关机时休眠内核）'; s = 'info' } } else { @{ t = '已关闭'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:system-clipboard-history'; group = '系统'; label = '剪贴板历史'
        hive = 'HKCU'; path = 'Software\Microsoft\Clipboard'
        name = 'EnableClipboardHistory'; kind = 'int'
        fix = '设置 → 系统 → 剪贴板 → 剪贴板历史记录；或写 HKCU\Software\Microsoft\Clipboard\EnableClipboardHistory=1'
        explain = {
            param($v)
            if ([int]$v -eq 1) { @{ t = '已开启（Win+V 可看历史）'; s = 'info' } } else { @{ t = '已关闭'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:system-storagesense'; group = '系统'; label = '存储感知'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
        name = '01'; kind = 'int'
        fix = '设置 → 系统 → 存储 → 存储感知 开/关；或写 HKCU\...\StorageSense\Parameters\StoragePolicy\01=1 开启'
        explain = {
            param($v)
            if ([int]$v -eq 1) { @{ t = '已开启（自动清临时文件）'; s = 'ok' } } else { @{ t = '已关闭'; s = 'info' } }
        }
    },
    @{
        id = 'winsettings:system-quiet-hours'; group = '系统'; label = '专注助手（免打扰）'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
        name = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED'; kind = 'int'
        fix = '设置 → 系统 → 专注助手；该值控制通知横幅是否显示。为 0 表示全局关了通知'
        explain = {
            param($v)
            if ([int]$v -eq 0) { @{ t = '通知横幅已全局关闭'; s = 'warn' } } else { @{ t = '通知横幅正常显示'; s = 'ok' } }
        }
    },
    # 文件系统项：hiberfil.sys 存不存在直接决定休眠能不能用，比读注册表准。
    @{
        id = 'winsettings:system-hibernate-file'; group = '系统'; label = '休眠文件 hiberfil.sys'
        hive = 'FILE'; path = 'C:\hiberfil.sys'; name = ''; kind = 'file'
        fix = '以管理员运行 powercfg /hibernate on 开启休眠（生成该文件）；powercfg /hibernate off 关闭并删除'
        explain = { param($v) $null }
    },

    # ---------------- 显示 ----------------
    @{
        id = 'winsettings:display-transfocusing'; group = '显示'; label = '窗口透明/聚焦效果'
        hive = 'HKCU'; path = 'Control Panel\Desktop'
        name = 'TransFocusing'; kind = 'int'
        fix = '设置 → 个性化 → 颜色 → 透明效果；或写 HKCU\Control Panel\Desktop\TransFocusing=0'
        explain = {
            param($v)
            if ([int]$v -eq 0) { @{ t = '已关闭'; s = 'info' } } else { @{ t = '已开启'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:display-animations'; group = '显示'; label = '窗口动画（最小化/最大化）'
        hive = 'HKCU'; path = 'Control Panel\Desktop\WindowMetrics'
        name = 'MinAnimate'; kind = 'str'
        fix = '设置 → 辅助功能 → 视觉效果 → 动画效果；或写 HKCU\Control Panel\Desktop\WindowMetrics\MinAnimate=0 关闭'
        explain = {
            param($v)
            if ("$v" -eq '0') { @{ t = '已关闭动画（更快）'; s = 'ok' } } else { @{ t = '动画开启'; s = 'ok' } }
        }
    },
    @{
        id = 'winsettings:display-userpreferencesmask'; group = '显示'; label = '视觉效果位掩码 UserPreferencesMask'
        hive = 'HKCU'; path = 'Control Panel\Desktop'
        name = 'UserPreferencesMask'; kind = 'bytes'
        fix = '设置 → 辅助功能 → 视觉效果，或"性能选项"里逐项勾选；直接改这个二进制值容易写错，建议走设置界面'
        explain = {
            param($v)
            @{ t = '位掩码，控制菜单淡入/阴影/平滑滚动等（需逐位解读）'; s = 'info' }
        }
    },
    @{
        id = 'winsettings:display-menushowdelay'; group = '显示'; label = '菜单弹出延迟'
        hive = 'HKCU'; path = 'Control Panel\Desktop'
        name = 'MenuShowDelay'; kind = 'str'
        fix = 'HKCU\Control Panel\Desktop\MenuShowDelay（毫秒，400 是默认，调小到 0-100 菜单更快弹出）'
        explain = {
            param($v)
            $n = 0; [void][int]::TryParse("$v", [ref]$n)
            if ($n -le 100) { @{ t = "${n}ms（比默认 400ms 快）"; s = 'ok' } }
            elseif ($n -ge 400) { @{ t = "${n}ms（默认值，略慢）"; s = 'info' } }
            else { @{ t = "${n}ms"; s = 'info' } }
        }
    },
    @{
        id = 'winsettings:display-dragfullwindows'; group = '显示'; label = '拖动时显示窗口内容'
        hive = 'HKCU'; path = 'Control Panel\Desktop'
        name = 'DragFullWindows'; kind = 'str'
        fix = '性能选项 → 拖动时显示窗口内容；或写 HKCU\Control Panel\Desktop\DragFullWindows=1'
        explain = {
            param($v)
            if ("$v" -eq '1') { @{ t = '显示完整内容'; s = 'ok' } } else { @{ t = '只显示边框（更省资源）'; s = 'info' } }
        }
    },

    # ---------------- 时间与语言 ----------------
    @{
        id = 'winsettings:time-24hour'; group = '时间与语言'; label = '时间格式（24 小时制判断）'
        hive = 'HKCU'; path = 'Control Panel\International'
        name = 'sTimeFormat'; kind = 'str'
        fix = '设置 → 时间和语言 → 语言和区域 → 修改时间格式；大写 H 是 24 小时制，小写 h 配 t 是 12 小时制'
        explain = {
            param($v)
            $s = "$v"
            # .NET 自定义格式里 H=24 小时制，h=12 小时制。用 H 判断而不是猜。
            if ($s -cmatch 'H') { @{ t = "24 小时制（格式 $s）"; s = 'ok' } }
            else { @{ t = "12 小时制（格式 $s）"; s = 'info' } }
        }
    },
    @{
        id = 'winsettings:time-shortdate'; group = '时间与语言'; label = '短日期格式'
        hive = 'HKCU'; path = 'Control Panel\International'
        name = 'sShortDate'; kind = 'str'
        fix = '设置 → 时间和语言 → 语言和区域 → 修改日期格式；或写 sShortDate=yyyy/M/d'
        explain = { param($v) @{ t = "格式 $v"; s = 'info' } }
    },
    @{
        id = 'winsettings:locale-name'; group = '时间与语言'; label = '系统区域'
        hive = 'HKCU'; path = 'Control Panel\International'
        name = 'LocaleName'; kind = 'str'
        fix = '设置 → 时间和语言 → 语言和区域 → 首选语言/区域格式'
        explain = { param($v) @{ t = "$v"; s = 'ok' } }
    },

    # ---------------- Windows 更新 ----------------
    @{
        id = 'winsettings:update-active-hours-start'; group = 'Windows 更新'; label = '活动时间开始'
        hive = 'HKLM'; path = 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        name = 'ActiveHoursStart'; kind = 'int'
        fix = '设置 → Windows 更新 → 高级选项 → 活动时间；或写 ActiveHoursStart（整点 0-23，需管理员）'
        explain = { param($v) @{ t = "$v 点开始（该时段内不自动重启）"; s = 'ok' } }
    },
    @{
        id = 'winsettings:update-active-hours-end'; group = 'Windows 更新'; label = '活动时间结束'
        hive = 'HKLM'; path = 'SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        name = 'ActiveHoursEnd'; kind = 'int'
        fix = '设置 → Windows 更新 → 高级选项 → 活动时间；或写 ActiveHoursEnd（整点 0-23，需管理员）'
        explain = { param($v) @{ t = "$v 点结束"; s = 'ok' } }
    },
    @{
        id = 'winsettings:update-auoptions'; group = 'Windows 更新'; label = '自动更新策略 AuOptions'
        hive = 'HKLM'; path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
        name = 'AuOptions'; kind = 'int'
        fix = '组策略 → 计算机配置 → 管理模板 → Windows 组件 → Windows 更新；2=仅通知 3=自动下载通知安装 4=自动安装'
        explain = {
            param($v)
            switch ([int]$v) {
                2 { @{ t = '仅通知（不自动下载）'; s = 'ok' } }
                3 { @{ t = '自动下载、通知后安装'; s = 'info' } }
                4 { @{ t = '自动下载并自动安装'; s = 'info' } }
                default { @{ t = "取值 $v"; s = 'info' } }
            }
        }
    },
    @{
        id = 'winsettings:network-metered-default'; group = 'Windows 更新'; label = '默认媒体成本（计量连接判定）'
        hive = 'HKLM'; path = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\DefaultMediaCost'
        name = 'Default'; kind = 'int'
        fix = '设置 → 网络 → 属性 → 按流量计费的连接。该值 1=非计量 2=计量（需管理员）'
        explain = {
            param($v)
            if ([int]$v -eq 2) { @{ t = '计量连接（省流量，更新会延后）'; s = 'info' } } else { @{ t = '非计量连接'; s = 'ok' } }
        }
    },

    # ---------------- 隐私 ----------------
    @{
        id = 'winsettings:privacy-telemetry'; group = '隐私'; label = '诊断数据级别（遥测）'
        hive = 'HKLM'; path = 'SOFTWARE\Policies\Microsoft\Windows\DataCollection'
        name = 'AllowTelemetry'; kind = 'int'
        fix = '设置 → 隐私 → 诊断和反馈 → 诊断数据；企业版可用组策略写 AllowTelemetry=0（需管理员）'
        explain = {
            param($v)
            switch ([int]$v) {
                0 { @{ t = '安全（最少数据，仅企业版生效）'; s = 'ok' } }
                1 { @{ t = '基本'; s = 'ok' } }
                3 { @{ t = '完整（数据最多）'; s = 'warn' } }
                default { @{ t = "取值 $v"; s = 'info' } }
            }
        }
    },
    @{
        id = 'winsettings:privacy-publish-activities'; group = '隐私'; label = '发布活动历史'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\Privacy'
        name = 'PublishUserActivities'; kind = 'int'
        fix = '设置 → 隐私 → 活动历史记录 → 在此设备上存储我的活动；或写 PublishUserActivities=0'
        explain = {
            param($v)
            if ([int]$v -eq 0) { @{ t = '不发布（更私密）'; s = 'ok' } } else { @{ t = '会记录并发布活动'; s = 'warn' } }
        }
    },
    @{
        id = 'winsettings:privacy-advertising-id'; group = '隐私'; label = '广告 ID'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
        name = 'Enabled'; kind = 'int'
        fix = '设置 → 隐私 → 常规 → 允许应用使用广告 ID；或写 AdvertisingInfo\Enabled=0'
        explain = {
            param($v)
            if ([int]$v -eq 0) { @{ t = '已关闭（不追踪投放）'; s = 'ok' } } else { @{ t = '已开启（应用可获取广告 ID）'; s = 'warn' } }
        }
    },
    @{
        id = 'winsettings:privacy-location'; group = '隐私'; label = '定位权限'
        hive = 'HKCU'; path = 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
        name = 'Value'; kind = 'str'
        fix = '设置 → 隐私和安全性 → 位置；或写 ConsentStore\location 的 Value=Deny/Allow'
        explain = {
            param($v)
            switch -Regex ("$v") {
                '^Deny$' { @{ t = '已拒绝（应用拿不到定位）'; s = 'ok' } }
                '^Allow$' { @{ t = '已允许'; s = 'info' } }
                default { @{ t = "$v"; s = 'info' } }
            }
        }
    }
)

# ---- 逐项读数 --------------------------------------------------------------
foreach ($d in $defs) {
    # 文件系统项单独处理：hiberfil.sys 的存在性比注册表更直接。
    if ($d.hive -eq 'FILE') {
        $exists = Test-Path -LiteralPath $d.path -PathType Leaf
        if ($exists) {
            $sz = 0
            try { $sz = (Get-Item -LiteralPath $d.path).Length } catch { }
            $mb = [Math]::Round($sz / 1MB, 0)
            Add-Item -List $items -Id $d.id -Group $d.group -Label $d.label -Status 'ok' `
                -Value "存在（$mb MB）" -Detail '休眠已启用；快速启动依赖它' -Fix $d.fix -NeedsAdmin $true
        }
        else {
            Add-Item -List $items -Id $d.id -Group $d.group -Label $d.label -Status 'info' `
                -Value '不存在' -Detail '休眠未启用，快速启动也因此不可用（本机 powercfg /a 同样报"休眠 尚未启用"）' `
                -Fix $d.fix -NeedsAdmin $true
        }
        continue
    }

    $r = Get-Val -Hive $d.hive -Path $d.path -Name $d.name
    $raw = Show-Val $r

    if (-not $r.exists) {
        # 键打不开：可能是权限不足（非管理员读 HKLM 部分键），也可能是真不存在。
        # 两种情况都不该编一个值，报 skip 并写清楚。
        Add-Item -List $items -Id $d.id -Group $d.group -Label $d.label -Status 'skip' `
            -Value '键不可读' -Detail "打不开 $($d.hive)\$($d.path)（可能不存在或当前权限不足）" `
            -Fix $d.fix -NeedsAdmin ($d.hive -eq 'HKLM')
        continue
    }

    if (-not $r.found) {
        # 值不存在 ≠ 出错：Win10 上很多 Win11 专有项就是没这个值，系统按默认走。
        $hint = if ($d.name -in @('TaskbarAl', 'TaskbarDa', 'TaskbarSd')) {
            '（该项是 Win11 专有设置，Win10 上没有这个值属正常）'
        }
        else { '系统按默认行为处理' }
        Add-Item -List $items -Id $d.id -Group $d.group -Label $d.label -Status 'info' `
            -Value '未设置' -Detail "该值不存在，$hint" -Fix $d.fix -NeedsAdmin ($d.hive -eq 'HKLM')
        continue
    }

    $ex = & $d.explain $r.value
    $text = if ($ex -and $ex.t) { [string]$ex.t } else { $raw }
    $st = if ($ex -and $ex.s) { [string]$ex.s } else { 'info' }
    $detail = "原始值：$raw"
    if ($r.kind) { $detail += "（$($r.kind)）" }
    $detail += " · 位置 $($d.hive)\$($d.path)\$($d.name)"

    Add-Item -List $items -Id $d.id -Group $d.group -Label $d.label -Status $st `
        -Value $text -Detail $detail -Fix $d.fix -NeedsAdmin ($d.hive -eq 'HKLM')
}

# ---- 当前连接的计量状态 ----------------------------------------------------
# NetworkList\Profiles 在非管理员下是"Requested registry access is not allowed"
# （本机 2026-11-17 实测：键路径确实存在，但 OpenSubKey 直接抛异常）。这正是
# 五态里 skip 的典型场景——读不到就是读不到，绝不拿 DefaultMediaCost 的全局
# 默认值冒充"当前连接是否计量"。
$curProfile = ''
try {
    $cp = Get-NetConnectionProfile
    if ($cp) { $curProfile = [string]@($cp)[0].Name }
} catch { }

$meteredId = 'winsettings:network-current-metered'
$pl = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles'
$profRoot = $null
$profErr = ''
try { $profRoot = $rkLM.OpenSubKey($pl) } catch { $profRoot = $null; $profErr = 'Requested registry access is not allowed（权限不足）' }
if ($null -eq $profRoot) {
    if (-not $profErr) { $profErr = '键不存在' }
    Add-Item -List $items -Id $meteredId -Group 'Windows 更新' -Label '当前连接是否按流量计费' -Status 'skip' `
        -Value '不可读' `
        -Detail ("无法读取 $pl（$profErr）。非管理员默认无权访问该键，因此无法判断当前连接" + $(if ($curProfile) { "「$curProfile」" } else { '' }) + '是否计量' `
        ) -Fix '以管理员身份运行探针可读取；或看 设置 → 网络和 Internet → 属性 → 按流量计费的连接' -NeedsAdmin $true
}
else {
    $names = @($profRoot.GetSubKeyNames())
    $hit = $null
    foreach ($n in $names) {
        $sk = $null
        try { $sk = $profRoot.OpenSubKey($n) } catch { $sk = $null }
        if ($null -eq $sk) { continue }
        $pn = [string]$sk.GetValue('ProfileName')
        $cost = $sk.GetValue('Cost')
        $managed = $sk.GetValue('Managed')
        $sk.Close()
        # Cost: 0=未限制 1=固定 2=可变(计量) 4=未知；Managed=1 表示用户手动设为计量
        if ($curProfile -and $pn -eq $curProfile) { $hit = @{ name = $pn; cost = $cost; managed = $managed }; break }
    }
    $profRoot.Close()
    if ($null -eq $hit) {
        Add-Item -List $items -Id $meteredId -Group 'Windows 更新' -Label '当前连接是否按流量计费' -Status 'skip' `
            -Value '未匹配到当前连接' `
            -Detail ("读到 $($names.Count) 个网络配置，但没有一个的 ProfileName 等于「$curProfile」" `
            ) -Fix '网络配置可能属于已断开的网络；重新连接后重跑，或到 设置 → 网络和 Internet 查看'
    }
    else {
        $isMetered = ([int]$hit.cost -eq 2) -or ([int]$hit.managed -eq 1)
        if ($isMetered) {
            Add-Item -List $items -Id $meteredId -Group 'Windows 更新' -Label '当前连接是否按流量计费' -Status 'info' `
                -Value "计量（$($hit.name)）" -Detail "Cost=$($hit.cost) Managed=$($hit.managed) · 计量连接下 Windows 更新会延后下载" `
                -Fix '设置 → 网络和 Internet → 属性 → 关闭"按流量计费的连接"'
        }
        else {
            Add-Item -List $items -Id $meteredId -Group 'Windows 更新' -Label '当前连接是否按流量计费' -Status 'ok' `
                -Value "非计量（$($hit.name)）" -Detail "Cost=$($hit.cost) Managed=$($hit.managed)" `
                -Fix '如需省流量可在 设置 → 网络和 Internet → 属性 里设为计量'
        }
    }
}

# ===========================================================================
# 写路径：set —— 只许 HKCU
# ===========================================================================
$writeResult = $null
if ($action -eq 'set') {
    $settingId = ([string]$params.setting).Trim()
    $newValue = $params.value

    $def = $null
    foreach ($d in $defs) { if ($d.id -eq $settingId) { $def = $d; break } }

    $actId = 'winsettings:action-set'
    if (-not $settingId) {
        Add-Item -List $items -Id $actId -Group '操作' -Label 'set 参数不足' -Status 'skip' `
            -Value '未执行' -Detail '缺少 params.setting，不知道要改哪一项' `
            -Fix '例如 {"action":"set","setting":"winsettings:dark-mode-apps","value":0}'
    }
    elseif ($null -eq $def) {
        Add-Item -List $items -Id $actId -Group '操作' -Label "set $settingId" -Status 'skip' `
            -Value '未执行' -Detail "没有这个设置项：$settingId" `
            -Fix 'setting 必须是本报告里出现过的 winsettings:<id>'
    }
    elseif ($def.hive -ne 'HKCU') {
        # 刻意不支持写 HKLM：系统级设置改错影响面大，且非管理员必然失败。
        Add-Item -List $items -Id $actId -Group '操作' -Label "set $($def.label)" -Status 'bad' `
            -Value '拒绝：仅支持 HKCU' -Detail "该项在 $($def.hive)\$($def.path)，本工具只改当前用户设置" `
            -Fix "请手动改：$($def.fix)" -NeedsAdmin $true
        $writeResult = [ordered]@{ setting = $settingId; applied = $false; refused = 'HKLM 只读' }
    }
    elseif ($null -eq $newValue -or "$newValue" -eq '') {
        Add-Item -List $items -Id $actId -Group '操作' -Label "set $($def.label)" -Status 'skip' `
            -Value '未执行' -Detail '缺少 params.value' -Fix '带上 value，例如 0 / 1 / "yyyy/M/d"'
    }
    else {
        # 目标值按 kind 转换：DWORD 必须是整数，否则 SetValue 会写成字符串、
        # 系统读不到（这类"写了但没生效"最难查，所以提前转好并校验）。
        $conv = $null
        $convErr = ''
        if ($def.kind -eq 'int') {
            $n = 0
            if ([int]::TryParse("$newValue", [ref]$n)) { $conv = $n }
            else { $convErr = "该项是 DWORD，值必须是整数，收到 '$newValue'" }
        }
        elseif ($def.kind -eq 'bytes') {
            $convErr = '该项是二进制位掩码，本工具不写（容易写坏），请用设置界面'
        }
        else {
            $conv = [string]$newValue
        }

        if ($convErr) {
            Add-Item -List $items -Id $actId -Group '操作' -Label "set $($def.label)" -Status 'skip' `
                -Value '未执行' -Detail $convErr -Fix $def.fix
        }
        else {
            $cur = Get-Val -Hive $def.hive -Path $def.path -Name $def.name
            $curTxt = Show-Val $cur
            $kindEnum = if ($def.kind -eq 'int') { [Microsoft.Win32.RegistryValueKind]::DWord } else { [Microsoft.Win32.RegistryValueKind]::String }

            if ($dryRun) {
                Add-Item -List $items -Id $actId -Group '操作' -Label "set $($def.label)" -Status 'info' `
                    -Value 'dryRun（未写入）' `
                    -Detail "计划：把 HKCU\$($def.path)\$($def.name) 从 '$curTxt' 改为 '$conv'" `
                    -Fix '确认无误后以 {"dryRun":false} 重跑才会真正写入'
                $writeResult = [ordered]@{ setting = $settingId; applied = $false; dryRun = $true; from = $curTxt; to = "$conv" }
            }
            else {
                # 先备份。备份失败就中止——宁可什么都不改，也不要在没有退路时动注册表。
                $backupPath = ''
                $backupOk = $false
                $backupErr = ''
                try {
                    $bkDir = Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox\regbackup'
                    if (-not (Test-Path -LiteralPath $bkDir)) {
                        New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
                    }
                    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                    $backupPath = Join-Path $bkDir ("winsettings-HKCU-$stamp.reg")
                    $out = & reg.exe export "HKCU\$($def.path)" $backupPath /y 2>&1
                    $backupOk = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $backupPath)
                    if (-not $backupOk) { $backupErr = ($out -join ' ').Trim() }
                }
                catch {
                    $backupErr = $_.Exception.Message
                }
                if (-not $backupOk) {
                    if (-not $backupErr) { $backupErr = 'reg export 未产出备份文件（键可能不存在）' }
                    Add-Item -List $items -Id $actId -Group '操作' -Label "set $($def.label)" -Status 'bad' `
                        -Value '已中止' -Detail "备份失败，按约定不写注册表：$backupErr" `
                        -Fix '确认该键存在且有写权限后重试'
                    $writeResult = [ordered]@{ setting = $settingId; applied = $false; backupError = $backupErr }
                }
                else {
                    $err = ''
                    $applied = $false
                    try {
                        # OpenSubKey(...,$true) 拿可写句柄；键不存在时才 CreateSubKey。
                        # 绝不 New-Item -Force（会清空整个键）。
                        $wk = $rkCU.OpenSubKey($def.path, $true)
                        if ($null -eq $wk) { $wk = $rkCU.CreateSubKey($def.path) }
                        if ($null -eq $wk) { throw "无法打开或创建 HKCU\$($def.path)" }
                        $wk.SetValue($def.name, $conv, $kindEnum)
                        $wk.Close()
                        $applied = $true
                    }
                    catch {
                        $err = $_.Exception.Message
                    }
                    if ($applied) {
                        Add-Item -List $items -Id $actId -Group '操作' -Label "set $($def.label)" -Status 'ok' `
                            -Value '已写入' -Detail "HKCU\$($def.path)\$($def.name)：'$curTxt' → '$conv'；备份：$backupPath" `
                            -Fix $def.fix
                        $writeResult = [ordered]@{ setting = $settingId; applied = $true; from = $curTxt; to = "$conv"; backupPath = $backupPath }
                    }
                    else {
                        Add-Item -List $items -Id $actId -Group '操作' -Label "set $($def.label)" -Status 'bad' `
                            -Value '写入失败' -Detail "写入 HKCU\$($def.path) 出错：$err（备份在 $backupPath）" `
                            -Fix '检查权限后用备份 .reg 还原，或改用设置界面'
                        $writeResult = [ordered]@{ setting = $settingId; applied = $false; error = $err; backupPath = $backupPath }
                    }
                }
            }
        }
    }
}

# ---- 收尾 ------------------------------------------------------------------
foreach ($k in $keyCache.Values) { if ($null -ne $k) { try { $k.Close() } catch { } } }
foreach ($h in @($rkLM, $rkCU)) { if ($null -ne $h) { try { $h.Close() } catch { } } }

$extra = [ordered]@{
    action   = $action
    dryRun   = $dryRun
    # defs 是静态定义表；currentMeteredRow 是运行时才追加的（读当前连接），
    # 所以总行数 = defs + 1，两个数都报出来免得对不上。
    defined  = $defs.Count
    settings = $defs.Count + 1
}
if ($null -ne $writeResult) { $extra.writeResult = $writeResult }

Write-ProbeResult -Items $items -Extra $extra -Note @'
Win10/11 常用设置项的当前读数与改法。状态语义：ok=当前处于常见的安全/合理状态；warn=存在一定风险或不符合常见期望（如隐藏了文件扩展名、RDP 开着、广告 ID 开着）；info=仅供参考的中性状态或"未设置=系统默认"；skip=该键读不到（权限不足或确实不存在），未编造取值。写操作 set 仅支持 HKCU，默认 dryRun，写前 reg export 备份到 %LOCALAPPDATA%\dsh-windows-toolbox\regbackup\，备份失败即中止；HKLM 项一律拒绝并提示手动修改。部分项（透明聚焦、夜晚模式）因存储为二进制位掩码/CloudStore blob 无法可靠解析，已如实跳过或只报原始值。
'@
