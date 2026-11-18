param([string]$ParamFile)

# ---------------------------------------------------------------------------
# contextmenu.ps1 —— 右键菜单 / 属性页 / 拖放 / 复制钩子（shell 扩展）清单
#
# 覆盖 12 个 shellex 位置 × 3 个注册表视图，外加 Shell Extensions\Approved
# 允许列表的阻止状态。每个条目给：CLSID、友好名、服务端 DLL、挂载位置、
# 以及它当前是"加载中 / 已阻止 / 不在允许列表"中的哪一种。
#
# 写操作（disable / enable）只动 Approved 里的一个值，默认 dryRun。
#
# ---- 继承自 com.ps1 的五个坑（都是实测出来的，破坏任一条就从 2 秒变几分钟）
#
#  1. 注册表路径含字面量 `*`。Classes\*\shellex 里的 `*` 是真键名，用
#     -Path 会被 provider 当通配符遍历整棵 Classes 树（本机 7443 个 CLSID
#     键），实测 >120s 不返回，看起来就是卡死。-LiteralPath 4ms 返回。
#     **本文件一律走 [Microsoft.Win32.RegistryKey]，字符串路径没有通配符
#     语义，从根上不可能再犯。**
#
#  2. 绝不对可能不存在的注册表键用 Test-Path（实测 387ms/次）。判断存在性
#     用 Get-Item -LiteralPath -ErrorAction SilentlyContinue（≈10-25ms）。
#     更狠的是 **Get-ItemProperty 读一个不存在的子键实测 1088ms/次**（本机
#     2026-11-17 复测 5 次共 5966ms）—— 逐条试探 CLSID 的服务端键是这套
#     探针里最贵的一步。所以本文件先把 CLSID 根 GetSubKeyNames() 一次取全
#     （7443 个名字 33ms），需要时直接用名字 OpenSubKey（命中/未命中都是
#     <1ms），永远不"试探"。
#
#  3. 键名可能带前导控制字符（本机真实存在：`\x01\x01 360Zip`）。Windows 用
#     它把条目钉在菜单顶部；显示前必须剥掉 ^[\x00-\x1f]+，但写回/定位时要用
#     原始键名。
#
#  4. Approved 的三态必须分开，com.ps1 曾把"不在列表"和"值为空串"混成一件：
#        该 CLSID 在 Approved 里根本没有值 → 不在列表（Explorer 照常加载）
#        在列表里且值为 ''            → 已阻止（这就是可逆的关闭开关）
#        在列表里且值为非空串        → 已允许（正常加载）
#     三者语义完全不同，本文件用 blocked / approvedName / inApproved 三个字段
#     分开表达，绝不折叠成一个空串。
#
#  5. 枚举"现存的键"是便宜的（三个 CLSID 根全量 1498ms / 7711 条），所以先
#     建索引再查，不要逐条试探。本文件的做法更省：只在真的需要友好名时按名
#     OpenSubKey，42 个唯一 CLSID 合计 24ms。
#
# 只读语义：本探针的 scan 动作从不写注册表；disable/enable 是唯一的写路径，
# 且默认 dryRun，写前 reg export 备份，备份失败即中止。
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList

$action = [string]$params.action
if (-not $action) { $action = 'scan' }
# 缺省 dryRun = true：任何没显式说 dryRun:false 的调用都只会得到计划。
$dryRun = $true
if ($null -ne $params.dryRun -and "$($params.dryRun)" -eq 'False') { $dryRun = $false }
$targetClsid = ([string]$params.clsid).Trim()
$targetScope = ([string]$params.scope).Trim().ToLowerInvariant()
$isElevated = Test-Elevated

# ---- 注册表视图 ------------------------------------------------------------
# 一次开三个根句柄，之后所有读取都在内存里走。
#
# 坑：**不能用 Registry32 视图去读 `SOFTWARE\Classes`**。WOW64 重定向只作用于
# HKLM\SOFTWARE\Classes 下的少数几个子键（CLSID / Interface 等），`Classes`
# 本身是 32/64 共享的——用 OpenBaseKey(...,Registry32) + 'SOFTWARE\Classes'
# 会读到和 64 位视图一模一样的内容，于是 78 行被原样复制成 156 行，位置计数
# 也对不上。32 位那份必须显式写 `SOFTWARE\WOW6432Node\Classes` 的字符串路径。
# 所以三个句柄统一用 Registry64，视图差异靠路径表达。
$hiveLM64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$hiveLM32 = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$hiveCU = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)

$views = @(
    @{ id = '64'; root = $hiveLM64; base = 'SOFTWARE\Classes'; hiveName = 'HKLM'; hiveShort = 'HKLM'; clsRootBase = 'SOFTWARE\Classes\CLSID'; scope = 'machine' },
    @{ id = '32'; root = $hiveLM32; base = 'SOFTWARE\WOW6432Node\Classes'; hiveName = 'HKLM'; hiveShort = 'HKLM'; clsRootBase = 'SOFTWARE\WOW6432Node\Classes\CLSID'; scope = 'machine' },
    @{ id = 'user'; root = $hiveCU; base = 'SOFTWARE\Classes'; hiveName = 'HKCU'; hiveShort = 'HKCU'; clsRootBase = 'SOFTWARE\Classes\CLSID'; scope = 'user' }
)

# 安全开关子键：不抛异常地尝试打开，失败返回 $null。
function Open-Sub {
    param($Root, [string]$Path)
    if ($null -eq $Root -or -not $Path) { return $null }
    try { return $Root.OpenSubKey($Path) } catch { return $null }
}

# ---- CLSID 名字索引（坑 2）------------------------------------------------
# 只要名字列表，不要 Key 对象：GetSubKeyNames() 7443 个 33ms，而逐个
# Get-ChildItem 建 Key 对象要 1.8s。存在性判断全部命中这个 HashSet。
$clsidNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($v in $views) {
    $cr = Open-Sub -Root $v.root -Path $v.clsRootBase
    if ($null -eq $cr) { continue }
    foreach ($n in $cr.GetSubKeyNames()) { [void]$clsidNames.Add($n) }
    $cr.Close()
}

# 每个 CLSID 只解析一次（42 个唯一值 → 24ms）；重复的 78 行共用结果。
$clsidCache = @{}
function Resolve-ClsidInfo {
    param([string]$Clsid)
    if (-not $Clsid) { return $null }
    if ($clsidCache.ContainsKey($Clsid)) { return $clsidCache[$Clsid] }

    $info = [ordered]@{ displayName = ''; server = ''; serverType = ''; company = '' }
    # 三个根按顺序找：64 位优先（Explorer 是 64 位进程），再 32 位，最后用户级。
    $key = $null
    foreach ($v in $views) {
        $key = Open-Sub -Root $v.root -Path ($v.clsRootBase + '\' + $Clsid)
        if ($null -ne $key) { $info.view = $v.id; break }
    }
    if ($null -eq $key) { $clsidCache[$Clsid] = $info; return $info }

    try {
        $dn = $key.GetValue('')
        if ($dn) { $info.displayName = [string]$dn }
        # 服务端子键只按名字开，绝不逐个子键试读；InprocServer32 优先，
        # 因为那才是 Explorer 真正 LoadLibrary 的那个。
        foreach ($st in @('InprocServer32', 'LocalServer32', 'InprocHandler32')) {
            $sk = Open-Sub -Root $key -Path $st
            if ($null -eq $sk) { continue }
            $sv = [string]$sk.GetValue('')
            $sk.Close()
            if (-not $sv) { continue }
            if ($st -eq 'InprocServer32' -or -not $info.server) {
                $info.server = $sv
                $info.serverType = $st
            }
        }
    } finally { $key.Close() }

    # 友好名兜底：CLSID 的 (default) 常是空的（DLL 自己声明菜单文字），
    # 这时读服务端 DLL 的 FileDescription——比显示一串 {GUID} 有用得多。
    # 30 个左右的 DLL 各 9ms，且只对真的缺名字的 CLSID 做。
    if (-not $info.displayName -and $info.server) {
        $dll = $info.server.Trim('"')
        # 展开 %SystemRoot% 这类环境变量再判断存在性；文件系统 Test-Path 很便宜。
        $expanded = [Environment]::ExpandEnvironmentVariables($dll)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            try {
                $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($expanded)
                if ($fvi.FileDescription) { $info.displayName = [string]$fvi.FileDescription }
                if ($fvi.CompanyName) { $info.company = [string]$fvi.CompanyName }
            } catch { }
        }
    }
    $clsidCache[$Clsid] = $info
    return $info
}

# ---- 12 个 shellex 位置 ----------------------------------------------------
# sub 是 Classes 下的相对路径。`*` 在这里是**字面量键名**（坑 1）：全文件
# 走 RegistryKey，字符串路径没有通配符语义，所以这里留着星号是安全的。
$classRoots = @(
    @{ sub = '*';                    tag = 'allfiles'; label = '所有文件' },
    @{ sub = 'AllFilesystemObjects'; tag = 'allfs';    label = '所有文件系统对象' },
    @{ sub = 'Directory';            tag = 'directory'; label = '文件夹' },
    @{ sub = 'Directory\Background'; tag = 'background'; label = '文件夹空白处' },
    @{ sub = 'Folder';               tag = 'folder';    label = '文件夹（含虚拟）' },
    @{ sub = 'Drive';                tag = 'drive';     label = '驱动器' },
    @{ sub = 'LibraryFolder';        tag = 'library';   label = '库' }
)
$handlerKinds = @(
    @{ name = 'ContextMenuHandlers'; label = '右键菜单' },
    @{ name = 'PropertySheetHandlers'; label = '属性页' },
    @{ name = 'DragDropHandlers'; label = '拖放' },
    @{ name = 'CopyHookHandlers'; label = '复制钩子' }
)

$clsidRe = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'

# 收集行（先收集再统一渲染：Approved 状态要读完两个侧才知道）
$rows = New-Object System.Collections.Generic.List[object]
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$locationHits = @{}

foreach ($v in $views) {
    foreach ($cr in $classRoots) {
        foreach ($hk in $handlerKinds) {
            $locPath = $v.base + '\' + $cr.sub + '\shellex\' + $hk.name
            $locKey = Open-Sub -Root $v.root -Path $locPath
            if ($null -eq $locKey) { continue }

            $names = @($locKey.GetSubKeyNames())
            if ($names.Count -gt 0) {
                $locId = "$($v.id)|$($cr.sub)|$($hk.name)"
                $locationHits[$locId] = $names.Count
            }

            foreach ($rawName in $names) {
                $entryKey = Open-Sub -Root $locKey -Path $rawName
                if ($null -eq $entryKey) { continue }
                $rawValue = [string]$entryKey.GetValue('')
                $entryKey.Close()

                # CLSID 可能写在这个键的 (default) 里，也可能**键名本身就是
                # CLSID**（本机 78 条里有 33 条如此，此时 (default) 存的是
                # "Taskband Pin" 这类显示文字）。两种都要认。
                $clsid = ''
                if ($rawValue -match $clsidRe) { $clsid = $rawValue }
                elseif ($rawName -match $clsidRe) { $clsid = $rawName }

                # 坑 3：剥掉前导控制字符再显示；原始键名保留下来供定位。
                $cleanName = ($rawName -replace '^[\x00-\x1f]+', '').Trim()

                $dedupe = "$($cr.sub)|$($hk.name)|$rawName|$($v.id)"
                if (-not $seen.Add($dedupe)) { continue }

                $rows.Add([ordered]@{
                    view        = $v.id
                    scope       = $v.scope
                    hiveShort   = $v.hiveShort
                    classSub    = $cr.sub
                    classTag    = $cr.tag
                    classLabel  = $cr.label
                    handlerKind = $hk.name
                    handlerLabel = $hk.label
                    rawName     = $rawName
                    cleanName   = $cleanName
                    rawValue    = $rawValue
                    clsid       = $(if ($clsid) { $clsid.ToUpperInvariant() } else { '' })
                    keyPath     = $v.hiveName + '\' + $locPath + '\' + $rawName
                })
            }
            $locKey.Close()
        }
    }
}

# ---- Shell Extensions\Approved（坑 4：三态分开）----------------------------
# 允许列表是按 CLSID 记的，三个视图各自一份。这里保存"每个 CLSID 在每个
# scope 里的值"，因为 disable/enable 要写的正是这个位置。
# 结构：approvedByScope[scope][CLSID] = @{ inList = bool; value = string }
$approvedByScope = @{
    machine = @{}
    user    = @{}
}
$approvedCounts = @{ 'machine64' = 0; 'machine32' = 0; 'user' = 0 }
$approvedBlocked = 0

# 注意 WOW6432Node 下那份是"32 位视图"的允许列表，语义上仍属 machine scope，
# 但写操作要落在用户实际选的那个视图上，所以两个分开记账。
$approvedSources = @(
    @{ root = $hiveLM64; path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'; tag = 'machine64'; scope = 'machine' },
    @{ root = $hiveLM32; path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'; tag = 'machine32'; scope = 'machine' },
    @{ root = $hiveCU;   path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'; tag = 'user'; scope = 'user' }
)
foreach ($src in $approvedSources) {
    $ak = Open-Sub -Root $src.root -Path $src.path
    if ($null -eq $ak) { continue }
    foreach ($n in $ak.GetValueNames()) {
        if (-not $n) { continue }               # 跳过 (default)
        $val = $ak.GetValue($n, $null)
        $txt = if ($null -eq $val) { '' } else { [string]$val }
        $approvedCounts[$src.tag]++
        if ($txt -eq '') { $approvedBlocked++ }
        $key = $n.ToUpperInvariant()
        if (-not $approvedByScope[$src.scope].ContainsKey($key)) {
            $approvedByScope[$src.scope][$key] = [ordered]@{
                inList = $true
                value  = $txt
                tag    = $src.tag
                path   = $src.path
            }
        }
    }
    $ak.Close()
}

# ---- 渲染每一行 ------------------------------------------------------------
$counts = @{ loaded = 0; blocked = 0; notListed = 0 }
# id 去重表。必须在循环前初始化：script 作用域的哈希表不会凭空出现，
# 之前写成 $script:menuIdSeen.ContainsKey() 会静默返回 $false 并让所有同 id
# 行撞车（client.js 用 id 当 React key，撞车会导致列表错乱）。
$idSeen = @{}
foreach ($r in $rows) {
    $info = $null
    if ($r.clsid) { $info = Resolve-ClsidInfo -Clsid $r.clsid }
    $displayName = ''
    $server = ''
    if ($info) { $displayName = [string]$info.displayName; $server = [string]$info.server }
    if (-not $displayName) { $displayName = $r.cleanName }
    if (-not $displayName) { $displayName = $r.clsid }

    # 状态判定：user scope 的行先看 HKCU 的允许列表，其余看 machine。
    $scopeList = $approvedByScope[$r.scope]
    $inApproved = $false
    $isBlocked = $false
    if ($r.clsid -and $scopeList.ContainsKey($r.clsid)) {
        $rec = $scopeList[$r.clsid]
        $inApproved = [bool]$rec.inList
        $isBlocked = ($rec.value -eq '')
    }

    if (-not $r.clsid) {
        # 连 CLSID 都解析不出来的条目（存的是 ProgID/裸名），Explorer 照样
        # 会加载，但没法用 Approved 开关控制——如实报 skip 而不是猜。
        $status = 'skip'
        $value = '无 CLSID'
        $detail = '该条目的键名与默认值都不是 CLSID，无法用 Approved 开关控制'
        $fix = ''
        $counts.notListed++
    }
    elseif ($isBlocked) {
        $status = 'warn'
        $value = '已阻止'
        $detail = 'Approved 里该 CLSID 的值为空串，Explorer 不会加载这个扩展'
        $fix = 'enable 可恢复加载'
        $counts.blocked++
    }
    elseif ($inApproved) {
        $status = 'ok'
        $value = '已允许'
        $detail = '已在 Approved 允许列表里，且值为非空串'
        $fix = '如需关闭用 disable'
        $counts.loaded++
    }
    else {
        $status = 'info'
        $value = '加载中'
        $detail = '不在 Approved 允许列表里；Explorer 默认仍然加载它'
        $fix = '如需关闭用 disable（会写入空串值）'
        $counts.notListed++
    }

    $where = "$($r.hiveShort)$($r.classLabel) · $($r.handlerLabel)"
    if ($r.view -ne '64') { $where += " · $(if ($r.view -eq '32') { '32 位' } else { '用户级' })" }

    $detailParts = New-Object System.Collections.Generic.List[string]
    $detailParts.Add($detail)
    $detailParts.Add($where)
    if ($server) { $detailParts.Add("DLL: $server") }
    else { $detailParts.Add('未找到服务端 DLL（可能由 Explorer 自身实现）') }

    # id 契约：menu:<位置>-<kind 简写>-<clsid 前 9 字符>。同 CLSID 在不同位置
    # 要分成不同行（挂载位置不同，效果也不同），所以把位置带进 id。
    $slug = $r.clsid
    if (-not $slug) { $slug = $r.cleanName }
    if ($slug.Length -gt 9) { $slug = $slug.Substring(0, 9) }
    $kindTag = switch ($r.handlerKind) {
        'ContextMenuHandlers' { 'context' }
        'PropertySheetHandlers' { 'propsheet' }
        'DragDropHandlers' { 'dragdrop' }
        'CopyHookHandlers' { 'copyhook' }
        default { 'handler' }
    }
    $locTag = $r.classTag
    $id = "menu:$locTag-$kindTag-$slug"

    # id 必须全局唯一：同一 CLSID 出现在多个视图（64/32/user）时补后缀。
    if ($idSeen.ContainsKey($id)) {
        $idSeen[$id]++
        $id = "$id-$($idSeen[$id])"
    }
    else {
        $idSeen[$id] = 1
    }

    Add-Item -List $items -Id $id -Group $r.classSub -Label $displayName -Status $status `
        -Value $value -Detail ($detailParts -join ' | ') -Fix $fix `
        -NeedsAdmin ($r.scope -eq 'machine')
}

# ===========================================================================
# 写路径：disable / enable —— 只改 Approved 里的一个值
# ===========================================================================
# 语义（坑 4）：Approved 里值为 ''  = 阻止；值为非空串 = 允许；不在列表 = 不
# 干预。所以 disable 就是写空串，enable 就是写回 displayName。**不删值**：
# 删掉会变成"不在列表"，语义从"用户显式关闭"退化成"从未表态"，回滚时无法
# 区分这是谁干的。
#
# 三个铁律：
#   1. 默认 dryRun —— 没显式 dryRun:false 只报计划。
#   2. 写前 reg export 备份，备份失败立即中止（绝不冒险写）。
#   3. HKLM 未提权 → needsAdmin，不尝试写（会静默失败或弹 UAC 卡住）。
$writeResult = $null

if ($action -eq 'disable' -or $action -eq 'enable') {
    $wanted = if ($action -eq 'disable') { '' } else { $null }

    if (-not $targetClsid) {
        Add-Item -List $items -Id "menu:action-$action" -Group '操作' -Label "$action 参数不足" `
            -Status 'skip' -Value '未执行' `
            -Detail '缺少 params.clsid，无法定位要改的允许列表值' `
            -Fix '调用时带上 clsid，例如 {"action":"disable","clsid":"{GUID}","scope":"machine"}'
    }
    elseif ($targetScope -ne 'machine' -and $targetScope -ne 'user') {
        Add-Item -List $items -Id "menu:action-$action" -Group '操作' -Label "$action 参数不足" `
            -Status 'skip' -Value '未执行' `
            -Detail "scope 只能是 machine 或 user，收到的是 '$targetScope'" `
            -Fix 'scope 传 machine（HKLM）或 user（HKCU）'
    }
    else {
        $cls = $targetClsid.ToUpperInvariant()

        # 目标键：machine 落在 64 位视图（Explorer 是 64 位进程），user 落 HKCU。
        if ($targetScope -eq 'machine') {
            $tRoot = $hiveLM64
            $tPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'
            $tHive = 'HKLM'
        }
        else {
            $tRoot = $hiveCU
            $tPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'
            $tHive = 'HKCU'
        }

        # 先确认这个 CLSID 真的在允许列表里。不在列表时 enable 没东西可写回
        # （没有历史 displayName 可恢复），disable 倒是可以新建一个空串值。
        $rec = $approvedByScope[$targetScope]
        $known = $null
        if ($rec -and $rec.ContainsKey($cls)) { $known = $rec[$cls] }

        # enable 需要一个"恢复成什么"的名字：优先用 CLSID 的 displayName，
        # 取不到再退成 CLSID 本身（Approved 的值只用于显示，不必等于原值）。
        if ($null -eq $wanted) {
            $ri = Resolve-ClsidInfo -Clsid $cls
            if ($ri -and $ri.displayName) { $wanted = [string]$ri.displayName }
            else { $wanted = $cls }
        }

        $planText = if ($action -eq 'disable') { "写入空串（阻止加载）" } else { "写入 '$wanted'（允许加载）" }
        $isAdminNeeded = ($targetScope -eq 'machine') -and (-not $isElevated)

        # 先看 dryRun：即便当前没提权、将来真写会被拒，dryRun 也该把计划
        # 说清楚（用户得先看到"要写什么"才能决定要不要提权重跑）。所以
        # needsAdmin 判断放在 dryRun 之后，只在真要落盘时才拦。
        if ($dryRun) {
            $existText = if ($known) { "当前值='$($known.value)'" } else { '当前不在允许列表里（新建值）' }
            $admNote = if ($isAdminNeeded) { '【注意】写 HKLM 需要管理员，当前进程未提权；真写前请以管理员重跑。' } else { '' }
            Add-Item -List $items -Id "menu:action-$action-$($cls.Substring(0,[Math]::Min(9,$cls.Length)))" `
                -Group '操作' -Label "$action $cls" -Status 'info' -Value 'dryRun（未写入）' `
                -Detail ("计划：在 $tHive\$tPath 里把该 CLSID 的值$planText；$existText。$admNote").Trim() `
                -Fix '确认无误后以 {"dryRun":false} 重跑才会真正写入' `
                -NeedsAdmin ($targetScope -eq 'machine')
            $writeResult = [ordered]@{ action = $action; clsid = $cls; scope = $targetScope; applied = $false; dryRun = $true; needsAdmin = $isAdminNeeded }
        }
        elseif ($isAdminNeeded) {
            Add-Item -List $items -Id "menu:action-$action-$($cls.Substring(0,[Math]::Min(9,$cls.Length)))" `
                -Group '操作' -Label "$action $cls" -Status 'bad' -Value '需要管理员' `
                -Detail "计划：在 $tHive\$tPath 里把该 CLSID 的值$planText；当前进程未提权，写 HKLM 会被拒绝" `
                -Fix '以管理员身份重新运行探针后再执行本操作' -NeedsAdmin $true
            $writeResult = [ordered]@{ action = $action; clsid = $cls; scope = $targetScope; applied = $false; needsAdmin = $true }
        }
        else {
            # ---- 真写：先备份，备份失败就中止 ------------------------------
            $backupPath = ''
            $backupOk = $false
            $backupErr = ''
            try {
                $bkDir = Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox\regbackup'
                if (-not (Test-Path -LiteralPath $bkDir)) {
                    New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
                }
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $backupPath = Join-Path $bkDir ("approved-$tHive-$stamp.reg")
                # reg export 的键名必须带 hive 前缀且不含 PowerShell 的
                # Registry:: 提供程序前缀。
                $regKey = "$tHive\$tPath"
                $out = & reg.exe export $regKey $backupPath /y 2>&1
                $backupOk = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $backupPath)
                if (-not $backupOk) { $backupErr = ($out -join ' ').Trim() }
            }
            catch {
                $backupErr = $_.Exception.Message
            }

            if (-not $backupOk) {
                if (-not $backupErr) { $backupErr = 'reg export 未产出备份文件' }
                Add-Item -List $items -Id "menu:action-$action-$($cls.Substring(0,[Math]::Min(9,$cls.Length)))" `
                    -Group '操作' -Label "$action $cls" -Status 'bad' -Value '已中止' `
                    -Detail "备份失败，按约定不写注册表：$backupErr" `
                    -Fix '检查 %LOCALAPPDATA% 写权限与 reg.exe 是否可用后重试' `
                    -NeedsAdmin ($targetScope -eq 'machine')
                $writeResult = [ordered]@{ action = $action; clsid = $cls; scope = $targetScope; applied = $false; backupError = $backupErr }
            }
            else {
                $err = ''
                $applied = $false
                try {
                    # 用 .NET 打开已存在的键并只改一个值。绝不 New-Item -Force
                    # （会重建键、清空该键下所有值和子键）。
                    $wk = $tRoot.OpenSubKey($tPath, $true)
                    if ($null -eq $wk) {
                        # 允许列表键本身不存在（极少见）：CreateSubKey 对已存在
                        # 的键不会销毁内容，实测已验证。
                        $wk = $tRoot.CreateSubKey($tPath)
                    }
                    if ($null -eq $wk) { throw "无法打开或创建 $tHive\$tPath（权限不足）" }
                    if ($action -eq 'disable') {
                        $wk.SetValue($cls, '', [Microsoft.Win32.RegistryValueKind]::String)
                    }
                    else {
                        $wk.SetValue($cls, $wanted, [Microsoft.Win32.RegistryValueKind]::String)
                    }
                    $wk.Close()
                    $applied = $true
                }
                catch {
                    $err = $_.Exception.Message
                }

                if ($applied) {
                    Add-Item -List $items -Id "menu:action-$action-$($cls.Substring(0,[Math]::Min(9,$cls.Length)))" `
                        -Group '操作' -Label "$action $cls" -Status 'ok' -Value '已写入' `
                        -Detail "已把 $tHive\$tPath 里该 CLSID 的值$planText；备份：$backupPath" `
                        -Fix '重启资源管理器（或注销）后生效' `
                        -NeedsAdmin $false
                    $writeResult = [ordered]@{ action = $action; clsid = $cls; scope = $targetScope; applied = $true; backupPath = $backupPath }
                }
                else {
                    Add-Item -List $items -Id "menu:action-$action-$($cls.Substring(0,[Math]::Min(9,$cls.Length)))" `
                        -Group '操作' -Label "$action $cls" -Status 'bad' -Value '写入失败' `
                        -Detail "写入 $tHive\$tPath 时出错：$err（备份已存于 $backupPath）" `
                        -Fix '确认权限后重试；必要时用备份 .reg 双击还原' `
                        -NeedsAdmin ($targetScope -eq 'machine')
                    $writeResult = [ordered]@{ action = $action; clsid = $cls; scope = $targetScope; applied = $false; error = $err; backupPath = $backupPath }
                }
            }
        }
    }
}

# ---- 收尾 ----------------------------------------------------------------
foreach ($h in @($hiveLM64, $hiveLM32, $hiveCU)) {
    if ($null -ne $h) { try { $h.Close() } catch { } }
}

$extra = [ordered]@{
    locations    = $locationHits.Count
    locationHits = $locationHits
    approved     = $approvedCounts
    approvedBlockedValues = $approvedBlocked
    states       = $counts
    action       = $action
    dryRun       = $dryRun
}
if ($null -ne $writeResult) { $extra.writeResult = $writeResult }

Write-ProbeResult -Items $items -Extra $extra -Note @'
右键菜单/属性页/拖放/复制钩子扩展清单。状态语义：ok=已在 Approved 允许列表且值为非空（正常加载）；info=不在允许列表（Explorer 默认仍加载）；warn=值为空串（已被显式阻止）；skip=条目拿不到 CLSID，无法用 Approved 开关控制；bad=写操作未能执行（缺权限/备份失败/写入出错）。写操作只改 Approved 中的一个值，默认 dryRun，写前 reg export 备份到 %LOCALAPPDATA%\dsh-windows-toolbox\regbackup\，备份失败即中止。改完需重启资源管理器生效。
'@
