param([string]$ParamFile)

# ---------------------------------------------------------------------------
# popup.ps1 — 弹窗 / 广告窗口：只读发现 + 能力边界说明
#
# ★ 能力边界（这段是重点，别把它当免责声明删掉）
# ---------------------------------------------------------------------------
# 真正的"实时拦截"在本插件里做不到，也不该假装能做：
#   * 要在窗口创建的那一刻拦下它，必须常驻一个进程，用 SetWinEventHook 监听
#     EVENT_OBJECT_CREATE / EVENT_OBJECT_SHOW，并在回调里判断+隐藏/关闭。
#   * DSH 插件的生命周期是**会话级**的：探针是一次性进程，跑完就退出，随时可能
#     被卸载。挂不了常驻钩子，也拿不到持续的事件流。
#   * 就算能挂，拦完还要能"放行"——一旦判错就是把用户正在用的窗口关掉。
# 所以本探针只做**能诚实做到**的那部分：把已经出现在屏幕上的窗口数清楚，标出
# 特征可疑的，再把"源头在哪"找出来（计划任务、已装软件、通知设置），让用户自己
# 关源头。全程只读：不杀进程、不隐藏窗口、不改任何窗口属性 —— 那会误伤用户程序。
#
# 两个实测得来的实现细节：
#   * 只靠 IsWindowVisible 会把一堆看不见的 UWP 壳算成"可见窗口"。必须再查
#     DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED=14)，cloaked!=0 的是被 DWM
#     隐藏的"假可见"（本机实测 ApplicationFrameWindow / TextInputHost 的
#     CoreWindow 都是 cloaked=2）。
#   * Add-Type 要 ~0.8s，枚举本身只要 ~60ms。别在循环里反复 Add-Type。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
# 本文件按项目惯例保存为不带 BOM 的 UTF-8，只有 PowerShell 7 能正确解析中文。
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items  = New-ProbeList

# ===========================================================================
# 1. 枚举当前可见顶层窗口
# ===========================================================================
$winRows = @()
$enumErr = ''

if (-not ('WinSnap' -as [type])) {
    $cs = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class WinRow {
    public long Handle;
    public string Title;
    public string ClassName;
    public uint Pid;
    public int Left;
    public int Top;
    public int Width;
    public int Height;
    public int Cloaked;
    public bool Visible;
    public long Owner;
}

public class WinSnap {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("dwmapi.dll")]
    private static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

    private const uint GW_OWNER = 4;
    private const int DWMWA_CLOAKED = 14;

    public static WinRow[] All() {
        List<WinRow> list = new List<WinRow>();
        EnumWindowsProc cb = delegate(IntPtr hWnd, IntPtr lParam) {
            try {
                // 注意：这里**不**过滤 IsWindowVisible。过滤掉的话调用方就永远数不到
                // 隐藏窗口，也就算不出"顶层窗口总数"（本机 195 个顶层窗口里只有 13
                // 个是可见的）。把可见性作为字段带回去，由 PowerShell 侧分类。
                StringBuilder sbTitle = new StringBuilder(512);
                GetWindowTextW(hWnd, sbTitle, sbTitle.Capacity);

                StringBuilder sbClass = new StringBuilder(256);
                GetClassNameW(hWnd, sbClass, sbClass.Capacity);

                uint pid = 0;
                GetWindowThreadProcessId(hWnd, out pid);

                RECT rc;
                int w = 0, h = 0;
                int left = 0, top = 0;
                if (GetWindowRect(hWnd, out rc)) {
                    left = rc.Left;
                    top = rc.Top;
                    w = rc.Right - rc.Left;
                    if (w < 0) { w = 0; }
                    h = rc.Bottom - rc.Top;
                    if (h < 0) { h = 0; }
                }

                int cloaked = 0;
                try { DwmGetWindowAttribute(hWnd, DWMWA_CLOAKED, out cloaked, 4); } catch { cloaked = 0; }

                long owner = 0;
                try { owner = GetWindow(hWnd, GW_OWNER).ToInt64(); } catch { owner = 0; }

                WinRow r = new WinRow();
                r.Handle = hWnd.ToInt64();
                r.Title = sbTitle.ToString();
                r.ClassName = sbClass.ToString();
                r.Pid = pid;
                r.Left = left;
                r.Top = top;
                r.Width = w;
                r.Height = h;
                r.Cloaked = cloaked;
                r.Visible = IsWindowVisible(hWnd);
                r.Owner = owner;
                list.Add(r);
            } catch { }
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        GC.KeepAlive(cb);
        return list.ToArray();
    }
}
'@
    try {
        Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop
    } catch {
        $enumErr = $_.Exception.Message
    }
}

$visible = @()
$cloakedCount = 0
$totalTop = 0
$hiddenCount = 0
if ('WinSnap' -as [type]) {
    try {
        $all = [WinSnap]::All()
        $totalTop = @($all).Count
        foreach ($w in $all) {
            if (-not [bool]$w.Visible) { $hiddenCount++; continue }
            if ([int]$w.Cloaked -ne 0) { $cloakedCount++; continue }
            $visible += $w
        }
    } catch { $enumErr = $_.Exception.Message }
}

# 进程名表：一次取全，别在窗口循环里按 Id 一个个 Get-Process（215 个进程）。
$procNames = @{}
foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
    if (-not $procNames.ContainsKey([int]$p.Id)) { $procNames[[int]$p.Id] = [string]$p.ProcessName }
}
function Get-ProcName([int]$procId) {
    if ($procNames.ContainsKey($procId)) { return $procNames[$procId] }
    return "pid$procId"
}

# 有标题的可见窗口才是用户真正看得到的东西；无标题的单独统计（本身就是可疑特征之一）。
$titled = @($visible | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Title) })
$untitled = @($visible | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Title) })

if ($enumErr -and $visible.Count -eq 0) {
    Add-Item -List $items -Id 'popup:windows' -Group '窗口' -Label '可见顶层窗口' -Status 'skip' `
        -Value '未取到' -Detail "user32 窗口枚举不可用：$enumErr" `
        -Fix '确认进程能访问当前窗口站（WinSta0\Default）；在服务/会话 0 里跑探针会拿不到用户桌面'
} else {
    Add-Item -List $items -Id 'popup:windows' -Group '窗口' -Label '可见顶层窗口' -Status 'info' `
        -Value "$($titled.Count) 个有标题 · $($untitled.Count) 个无标题" `
        -Detail "顶层窗口共 $totalTop 个：未可见 $hiddenCount 个、被 DWM cloaked（假可见）$cloakedCount 个已排除，剩 $($visible.Count) 个真正显示在屏幕上的"
}

# ---- 按进程归组 ----
# 预先初始化：后面 Extra 里要读 $groups.Count，没有窗口时它不能是未定义变量。
$groups = @{}
if ($titled.Count -gt 0) {
    foreach ($w in $titled) {
        $pn = Get-ProcName ([int]$w.Pid)
        if (-not $groups.ContainsKey($pn)) { $groups[$pn] = 0 }
        $groups[$pn]++
    }
    # 绝不用 Sort-Object -Property <键> 排哈希表 —— 会静默不排序。用 scriptblock。
    $ordered = $groups.GetEnumerator() | Sort-Object -Property { $_.Value } -Descending
    $top = @($ordered | Select-Object -First 8)
    $topText = ($top | ForEach-Object { "$($_.Key)×$($_.Value)" }) -join '、'
    Add-Item -List $items -Id 'popup:window-groups' -Group '窗口' -Label '按进程归组（Top 8）' -Status 'info' `
        -Value "$($groups.Count) 个进程持有窗口" `
        -Detail "最多窗口的进程：$topText" `
        -Fix ''

    $seen = @{}
    foreach ($g in $ordered) {
        $pn = [string]$g.Key
        $slug = (($pn -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLower()
        if (-not $slug) { $slug = 'unknown' }
        $id = "popup:window-$slug"
        if ($seen.ContainsKey($id)) { $seen[$id]++; $id = "$id-$($seen[$id])" } else { $seen[$id] = 1 }

        $mine = @($titled | Where-Object { (Get-ProcName ([int]$_.Pid)) -eq $pn })
        $titles = @($mine | ForEach-Object { [string]$_.Title } | Where-Object { $_ } | Select-Object -First 3)
        # 一个进程挂很多窗口本身就是特征（本机实测 360tray 挂了 20 个隐藏窗口）。
        $st = 'info'
        if ($mine.Count -ge 8) { $st = 'warn' }
        Add-Item -List $items -Id $id -Group '窗口' -Label "窗口 · $pn" -Status $st `
            -Value "$($mine.Count) 个可见窗口 · pid $([int]$mine[0].Pid)" `
            -Detail ("标题：" + (($titles -join ' / '))) `
            -Fix $(if ($st -eq 'warn') { '这个进程挂了较多窗口，若其中有你不认识的，去它的设置里关掉推广/资讯' } else { '' })
    }
}

# ===========================================================================
# 2. 可疑窗口特征
# ===========================================================================
# 四条特征都是**可复核的事实描述**，不是"我觉得像广告"。本机实测这些标尺在
# 13 个可见窗口上全部为 0 —— 也就是这台机器此刻没有可疑窗口，如实报 0，别凑数。
$adWords = '推荐|活动|抽奖|红包|广告|推广|资讯|福利|限时|免费领|下载安装|弹'
$suspicious = @()
foreach ($w in $visible) {
    $t = [string]$w.Title
    $c = [string]$w.ClassName
    $flags = @()

    if ([string]::IsNullOrWhiteSpace($t)) { $flags += '无标题' }
    if (([int]$w.Left -lt 0 -or [int]$w.Top -lt 0) -and [int]$w.Width -gt 0 -and [int]$w.Height -gt 0) {
        $flags += '在屏幕外'
    }
    if ([int]$w.Width -gt 0 -and [int]$w.Height -gt 0 -and [int]$w.Width -lt 200 -and [int]$w.Height -lt 100) {
        $flags += '尺寸异常小'
    }
    if ($c -like 'Chrome_WidgetWin*' -and [string]::IsNullOrWhiteSpace($t)) { $flags += 'Chromium 无标题壳' }
    if ($t -and $t -match $adWords) { $flags += '标题含广告词' }

    # "无标题" 对纯工具窗口（如 WorkerW / DummyDWMListenerWindow）是正常形态，
    # 单独一条不算可疑；必须还带上其它特征才算。
    if ($flags.Count -gt 0) {
        $suspicious += [pscustomobject]@{
            title  = $t
            cls    = $c
            pid    = [int]$w.Pid
            pname  = (Get-ProcName ([int]$w.Pid))
            flags  = $flags
            rect   = "$([int]$w.Left),$([int]$w.Top) $([int]$w.Width)x$([int]$w.Height)"
        }
    }
}
$hardSuspicious = @($suspicious | Where-Object {
    ($_.flags -contains '在屏幕外') -or ($_.flags -contains '尺寸异常小') -or
    ($_.flags -contains '标题含广告词') -or ($_.flags -contains 'Chromium 无标题壳')
})

if ($hardSuspicious.Count -eq 0) {
    Add-Item -List $items -Id 'popup:suspicious' -Group '可疑窗口' -Label '可疑窗口特征' -Status 'ok' `
        -Value '0 个' `
        -Detail "在 $($visible.Count) 个可见窗口里，没有屏幕外、尺寸异常小、Chromium 无标题壳或标题含广告词的窗口" `
        -Fix ''
} else {
    $hs = @{}
    foreach ($s in $hardSuspicious) {
        $slug = (($s.pname -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLower()
        if (-not $slug) { $slug = 'unknown' }
        $id = "popup:suspicious-$slug"
        if ($hs.ContainsKey($id)) { $hs[$id]++; $id = "$id-$($hs[$id])" } else { $hs[$id] = 1 }
        Add-Item -List $items -Id $id -Group '可疑窗口' -Label "可疑 · $($s.pname)" -Status 'warn' `
            -Value ($s.flags -join ' + ') `
            -Detail "标题「$($s.title)」· 类 $($s.cls) · pid $($s.pid) · 位置 $($s.rect)" `
            -Fix '本探针不会替你关窗口（会误伤正常程序）；自己确认来源后，去该软件的设置里关掉推广/资讯，或卸载'
    }
}

# ===========================================================================
# 3. 任务栏 / 通知区域 / 专注助手（只读）
# ===========================================================================
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$taskbarBits = [ordered]@{
    ShowTaskViewButton = '任务视图按钮'
    TaskbarDa          = '小组件（资讯与兴趣）'
    ShowCopilotButton  = 'Copilot 按钮'
    TaskbarMn          = '聊天按钮'
    ShowSecondsInSystemClock = '时钟显示秒'
}
$bits = @()
foreach ($k in $taskbarBits.Keys) {
    $v = Format-RegValue (Get-RegValue -Path $adv -Name $k)
    $bits += "$($taskbarBits[$k])=$v"
}
# 这几个值在本机全是 ABSENT（未写就表示"系统默认"），所以统一按 unset 展示，
# 不把"没这个键"说成"已关闭"。
$widget = Format-RegValue (Get-RegValue -Path $adv -Name 'TaskbarDa')
$widgetStatus = 'info'
$widgetFix = ''
if ($widget -eq '1') {
    $widgetStatus = 'warn'
    $widgetFix = '关闭「小组件」：任务栏右键 → 任务栏设置 → 小组件；它会在后台拉资讯并弹通知'
} elseif ($widget -eq 'unset') {
    $widgetFix = '该值未显式写入（系统默认开启）；如不想看资讯，在任务栏设置里手动关掉小组件'
}
Add-Item -List $items -Id 'popup:taskbar' -Group '设置' -Label '任务栏开关' -Status $widgetStatus `
    -Value ($bits -join ' · ') `
    -Detail 'unset 表示该值没写过，走系统默认（不是"已关闭"）' -Fix $widgetFix

# 通知：NotifyIconSettings 里的推广图标，和每 App 的通知开关。
$notifRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$notifKeys = @(Get-ChildItem -LiteralPath $notifRoot -ErrorAction SilentlyContinue)
if ($notifKeys.Count -eq 0) {
    Add-Item -List $items -Id 'popup:notifications' -Group '设置' -Label '应用通知开关' -Status 'skip' `
        -Value '未取到' -Detail '读不到 Notifications\Settings，无法统计被关掉通知的应用' `
        -Fix '在 设置 → 系统 → 通知 里手动检查'
} else {
    $disabled = @()
    foreach ($k in $notifKeys) {
        $e = Get-RegValue -Path $k.PSPath -Name 'Enabled'
        if ($null -ne $e -and [int]$e -eq 0) { $disabled += [string]$k.PSChildName }
    }
    Add-Item -List $items -Id 'popup:notifications' -Group '设置' -Label '应用通知开关' -Status 'info' `
        -Value "$($notifKeys.Count) 个应用 · $($disabled.Count) 个已关闭" `
        -Detail $(if ($disabled.Count -gt 0) { '已关闭通知：' + (($disabled | Select-Object -First 8) -join '、') } else { '所有登记的应用都开着通知' }) `
        -Fix $(if ($disabled.Count -gt 0) { '' } else { '不想被弹的软件，逐个在 设置 → 通知 里关掉，比事后追窗口有效' })
}

# 专注助手：Win11 把状态搬进 CloudStore 的二进制 blob，格式未公开。
# 本机实测 HKCU\...\QuietHours 根本不存在，CloudStore 里只有一个 116 字节的
# REG_BINARY，解不出可靠状态 —— 所以这里必须 skip，不许拿二进制猜一个值出来。
$quietLegacy = Get-RegValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\QuietHours' -Name 'Enabled'
$quietCloud = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\{d20ef109-4a16-4d8d-916d-4c9821e18612}$windows.data.donotdisturb.quiethourssettings\windows.data.donotdisturb.quiethourssettings'
$cloudData = Get-RegValue -Path $quietCloud -Name 'Data'
if ($null -ne $quietLegacy) {
    $qt = Format-RegValue $quietLegacy
    Add-Item -List $items -Id 'popup:quiethours' -Group '设置' -Label '专注助手' -Status $(if ($qt -eq '1') { 'warn' } else { 'ok' }) `
        -Value $qt -Detail '读自旧版 QuietHours\Enabled' `
        -Fix $(if ($qt -eq '1') { '关掉专注助手，否则它可能把你想看的通知也压掉' } else { '' })
} elseif ($null -ne $cloudData) {
    $len = 0
    try { $len = @($cloudData).Count } catch { $len = 0 }
    Add-Item -List $items -Id 'popup:quiethours' -Group '设置' -Label '专注助手' -Status 'skip' `
        -Value "状态不可读（CloudStore blob $len 字节）" `
        -Detail 'Win11 把专注助手状态存在 CloudStore 的未公开二进制 blob 里，旧版 QuietHours 键已不存在；本探针不解析未公开格式，也不猜' `
        -Fix '在 设置 → 系统 → 通知 → 专注助手 里手动查看当前状态'
} else {
    Add-Item -List $items -Id 'popup:quiethours' -Group '设置' -Label '专注助手' -Status 'skip' `
        -Value '状态不可读' `
        -Detail 'QuietHours 键与 CloudStore 项都不存在，无法判断专注助手状态' `
        -Fix '在 设置 → 系统 → 通知 → 专注助手 里手动查看'
}

# ===========================================================================
# 4. 容易弹广告的计划任务（只读）
# ===========================================================================
# Get-ScheduledTask 本机约 0.9s（165 个任务），可以接受；不要为了快改成读注册表
# 树，那样拿不到 Enabled 状态。
$taskPattern = '360|驱动精灵|DriverGenius|驱动人生|sougou|搜狗|baidu|百度|腾讯|2345|鲁大师|Kingsoft|WPS|迅雷|Thunder|猎豹|Cheetah|推广|弹窗'
$allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
$hitTasks = @($allTasks | Where-Object { ([string]$_.TaskName) -match $taskPattern })
if ($allTasks.Count -eq 0) {
    Add-Item -List $items -Id 'popup:scheduled' -Group '计划任务' -Label '广告类计划任务' -Status 'skip' `
        -Value '未取到' -Detail 'Get-ScheduledTask 没有返回任务，无法判断' `
        -Fix '用 taskschd.msc 手动检查' -NeedsAdmin $true
} elseif ($hitTasks.Count -eq 0) {
    Add-Item -List $items -Id 'popup:scheduled' -Group '计划任务' -Label '广告类计划任务' -Status 'ok' `
        -Value "0 个（共 $($allTasks.Count) 个任务）" `
        -Detail '名字里没有 360 / 驱动精灵 / 搜狗 / 百度 / 腾讯 / WPS / 迅雷 / 猎豹 等触发器的任务' `
        -Fix ''
} else {
    $enabledHits = @($hitTasks | Where-Object { $_.State -ne 'Disabled' })
    $st = if ($enabledHits.Count -gt 0) { 'warn' } else { 'ok' }
    foreach ($t in $hitTasks) {
        $tn = [string]$t.TaskName
        $slug = (($tn -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLower()
        if (-not $slug) { $slug = 'task' }
        $ist = if ($t.State -eq 'Disabled') { 'info' } else { 'warn' }
        Add-Item -List $items -Id "popup:task-$slug" -Group '计划任务' -Label "计划任务 · $tn" -Status $ist `
            -Value ([string]$t.State) `
            -Detail "路径 $([string]$t.TaskPath) · 作者 $([string]$t.Author)" `
            -Fix $(if ($t.State -eq 'Disabled') { '' } else { '关掉它：taskschd.msc → 找到该任务 → 禁用（需要管理员）' }) `
            -NeedsAdmin ($t.State -ne 'Disabled')
    }
    Add-Item -List $items -Id 'popup:scheduled' -Group '计划任务' -Label '广告类计划任务' -Status $st `
        -Value "$($hitTasks.Count) 个命中 · $($enabledHits.Count) 个仍在启用" `
        -Detail "共扫描 $($allTasks.Count) 个计划任务" `
        -Fix $(if ($enabledHits.Count -gt 0) { '启用的这些是弹窗的常见来源，禁用前先确认不是你在用的功能（如自动更新）' } else { '' }) `
        -NeedsAdmin ($enabledHits.Count -gt 0)
}

# ===========================================================================
# 5. 已装软件里的广告大户（只读）
# ===========================================================================
$adAppsPattern = '360|驱动精灵|驱动人生|搜狗|猎豹|WPS|迅雷|2345|鲁大师|金山'
$uniRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)
$allProgs = @()
$uniRead  = 0
foreach ($r in $uniRoots) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    $uniRead++
    # 必须先 Get-ChildItem 再逐个子键取属性：对根键直接 Get-ItemProperty 只拿到
    # 根键自己的值（空的），会得出"共查 0 条已装程序"的假结论。
    foreach ($k in (Get-ChildItem -LiteralPath $r -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.DisplayName) { $allProgs += $p }
    }
}
$adApps = @($allProgs | Where-Object { ([string]$_.DisplayName) -match $adAppsPattern })

if ($uniRead -eq 0) {
    Add-Item -List $items -Id 'popup:adsoft' -Group '软件' -Label '广告大户软件' -Status 'skip' `
        -Value '未取到' -Detail '三个 Uninstall 注册表根都读不到' `
        -Fix '确认当前账户能读取 HKLM/HKCU 的 Uninstall 键后重跑'
} elseif ($adApps.Count -eq 0) {
    Add-Item -List $items -Id 'popup:adsoft' -Group '软件' -Label '广告大户软件' -Status 'ok' `
        -Value "0 个（共 $($allProgs.Count) 条）" `
        -Detail '短名单（360 / 驱动精灵 / 驱动人生 / 搜狗 / 猎豹 / WPS / 迅雷 / 2345 / 鲁大师 / 金山）都没命中' `
        -Fix ''
} else {
    $as = @{}
    foreach ($a in $adApps) {
        $dn = [string]$a.DisplayName
        $slug = (($dn -replace '[^A-Za-z0-9]+', '-').Trim('-')).ToLower()
        if (-not $slug) { $slug = 'app' }
        $id = "popup:adsoft-$slug"
        if ($as.ContainsKey($id)) { $as[$id]++; $id = "$id-$($as[$id])" } else { $as[$id] = 1 }
        Add-Item -List $items -Id $id -Group '软件' -Label "软件 · $dn" -Status 'warn' `
            -Value ([string]$a.DisplayVersion) `
            -Detail "发布者 $([string]$a.Publisher)" `
            -Fix '在它自己的设置里关掉「推广/资讯/热点/消息推送」，并取消开机自启；不常用就卸载'
    }
    Add-Item -List $items -Id 'popup:adsoft' -Group '软件' -Label '广告大户软件' -Status 'warn' `
        -Value "$($adApps.Count) 个（共 $($allProgs.Count) 条）" `
        -Detail '这些软件是弹窗的主要来源，关源头比事后拦窗口有效' -Fix ''
}

# ===========================================================================
# 6. 结论行：把能力边界写死
# ===========================================================================
$suspectText = if ($hardSuspicious.Count -gt 0) { "当前检测到 $($hardSuspicious.Count) 个特征可疑的窗口" } else { '当前没检测到特征可疑的窗口' }
Add-Item -List $items -Id 'popup:boundary' -Group '结论' -Label '能力边界' `
    -Status $(if ($hardSuspicious.Count -gt 0 -or @($hitTasks | Where-Object { $_.State -ne 'Disabled' }).Count -gt 0) { 'warn' } else { 'info' }) `
    -Value '实时拦截不可行' `
    -Detail ("$suspectText。实时拦截需要常驻进程用 SetWinEventHook 监听 EVENT_OBJECT_CREATE/EVENT_OBJECT_SHOW " +
             "并在回调里判断处置；DSH 插件是会话级、可随时卸载的，挂不了这种钩子，所以本插件不做拦截。" +
             "它能做的是：数清当前可见窗口、标出特征可疑的、找出弹窗源头（计划任务 / 已装软件 / 通知与任务栏设置），" +
             "由你自己关掉源头。全程只读，不杀进程、不隐藏窗口 —— 自动关窗口一旦判错就会误伤正在用的程序。") `
    -Fix '想真的拦弹窗：用系统自带的「设置 → 通知」逐项关闭，或卸载广告大户；别用会自动结束进程的工具'

Write-ProbeResult -Items $items -Extra ([ordered]@{
    topLevelWindows = $totalTop
    hiddenWindows   = $hiddenCount
    visibleWindows  = $visible.Count
    cloakedWindows  = $cloakedCount
    titledWindows   = $titled.Count
    untitledWindows = $untitled.Count
    procGroups      = $groups.Count
    suspicious      = $hardSuspicious.Count
    adTasks         = $hitTasks.Count
    adTasksEnabled  = @($hitTasks | Where-Object { $_.State -ne 'Disabled' }).Count
    adSoftware      = $adApps.Count
    installedProgs  = $allProgs.Count
    enumError       = $enumErr
}) -Note "只读：枚举可见顶层窗口（IsWindowVisible + DWM cloaked 双重判定）、按进程归组、标可疑特征、查计划任务与已装软件。实时弹窗拦截需要常驻进程 + SetWinEventHook，本插件生命周期不允许，故不做拦截，也不杀进程/隐藏窗口。"
