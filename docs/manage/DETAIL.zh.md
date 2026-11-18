# Windows 插件化管理器 · 技术说明

> 版本 0.1.0 · 实测环境 Windows 10 专业版 (build 19045) · PowerShell 7.6.10 · 未提权
> 所有数字均为本机 2026-11-17 实测，不是估算。

## 1. 这个插件解决什么问题

Windows 没有一个地方能回答"这台机器上到底有哪些东西会被加载、哪些是开着的、关掉会怎样"。同一件事分散在十一个互不相通的注册点里：

| 注册点 | 权威数据源 | 本机实测条数 | 耗时 |
|---|---|---|---|
| 服务 | SCM（Service Control Manager） | 272 | 707 ms |
| 计划任务 | 任务计划程序 + `System32\Tasks` | 165 | 1267 ms |
| 开机自启 | Run/RunOnce 注册表十处 + 启动文件夹 + UWP StartupTask + 登录/开机触发的计划任务 + 自动启动的服务 + Active Setup | 136 | 1927 ms |
| 外壳扩展 | Shell Extensions 的 12 个 shellex 位置 + Approved 白名单 | 75 | 2306 ms |
| 已安装程序 | 三个 Uninstall 根（HKLM 64/32、HKCU） | 114 | 606 ms |
| AppX / MSIX | `Get-AppxPackage`（PS7 走 5.1 桥） | 100 | 3976 ms |
| 驱动 | `HKLM\SYSTEM\DriverDatabase` + `Win32_PnPSignedDriver` | 418 | 1611 ms |
| 防火墙规则 | COM `HNetCfg.FwPolicy2` | 546 | 1059 ms |
| 映像劫持（IFEO） | `HKLM\...\Image File Execution Options` 两个视图 | 86 | 521 ms |
| 文件关联 | `HKCU\...\FileExts` 的 UserChoice | 520 | 609 ms |
| 凭据提供程序 | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\Credential Providers` | 22 | 495 ms |

合计 **2320 条**注册点。另有独立的**系统修复**板块 8 项（详见 [REPAIR.zh.md](REPAIR.zh.md)），它不是注册点、没有开/关状态，所以不计入上面这张表，也不参与卡片分组。全部 12 个探针并行冷启动 **5400 ms**（含 8 项系统修复的 904 ms），缓存后 0 ms。

插件把它们折成**一张统一索引**，每一条都能回答四个问题：它是什么、开还是关、能不能安全改、改了怎么退回去。

## 2. 五个钩子

每个能力（一条索引项）都按同一套接口描述：

```
detect   读当前状态，不改任何东西
enable   打开
disable  关闭，且可逆
verify   重新读取，确认改动真的落地了
rollback 用 detect 捕获的值还原
```

v0.1 的实际覆盖：

- **detect**：十一个注册点全部 + 系统修复 8 项。
- **enable / disable / rollback**：服务、计划任务、开机自启、外壳扩展、防火墙规则（这五类是可逆的，`actions.ps1` 里各有自己的写路径与 undo 记录）。
- **单动词 uninstall**：已安装程序、AppX/MSIX、驱动包。这三类只有卸载/删包一种动作，属于 destructive，所以不给 enable/disable，正面按钮是「卸载」，并且先预演命令再执行（systemComponent=true 的拒绝、bound=true 的驱动包拒绝、非第三方驱动包拒绝）。
- **不接线**：映像劫持、文件关联、凭据提供程序。这三类在当前版本只做只读呈现（IFEO 一旦被劫持会标 `blocked` 并红显，但改它需要在系统目录里动注册表，风险不对等）。卸载按钮之所以要先预演再执行、并且拒绝 `bound=true` 的包，就是因为误删在用驱动就是蓝屏。

## 3. 风险分级

| 级别 | 含义 | 本机条数 |
|---|---|---|
| `blocked` | 受保护，UI 必须拒绝操作 | 30（全部是服务） |
| `reversible` | 有 enable/disable，且捕获了回滚值 | 1030（service 242 + firewall 542 + task 165 + com 78 + autorun 3） |
| `destructive` | 会删除东西，不一定可逆 | 632（drv 418 + program 114 + appx 100） |
| `readonly` | 只列不改 | 636（fileexts 520 + ifeo 86 + credprov 22 + repair 8） |

合计 2462 条（2454 条注册点 + 8 条系统修复）。

**受保护服务名单（35 个）**：`rpcss`、`rpcepmap`、`dcomlaunch`、`lsm`、`power`、`plugplay`、`bfe`、`eventlog`、`profsvc`、`samss`、`winlogon`、`wuauserv`、`trustedinstaller`、`msiserver`、`gpsvc`、`cryptsvc`、`dhcp`、`dnscache`、`nsi`、`netprofm`、`nlasvc`、`lanmanworkstation`、`lanmanserver`、`windefend`、`seclogon`、`sppsvc`、`themes`、`audiosrv`、`audioendpointbuilder`、`brokerinfrastructure`、`systemeventsbroker`、`staterepository`、`coremessaging`、`event system`、`devicesetupmanager`。

这些是"禁用后当时没事、重启就进不去桌面"的那一类，所以直接判为 `blocked`，界面上不给按钮。

另一条 `blocked` 规则：服务的可执行文件路径匹配 `\\drivers\\` 或 `.sys`，且 `acceptStop === false` → 内核态服务，停止它可能直接 bugcheck。

## 4. 目录结构

```
dsh-windows-toolbox/
├─ index.js              宿主：6 条 API 路由 + 6 个 agent 工具
├─ client.js             客户端：侧栏入口 + 主区面板（手写 React，不依赖宿主 UI 包）
├─ cordis.patch.yml      bundle patch（插入插件实例）
├─ icon.svg              插件图标
├─ lib/
│  ├─ sources.js         十二个源的声明 + 风险类 + 35 个受保护服务
│  ├─ normalize.js       把各探针的异构 JSON 归一成统一条目
│  ├─ explain.js         把原始行翻译成「是什么 / 在哪见 / 有什么作用 / 关了会怎样」（zh+en）
│  ├─ inventory.js       缓存与调度（TTL 5 分钟，单源失败不影响其他源）
│  └─ probes/
│     ├─ svc.ps1         服务
│     ├─ task.ps1        计划任务
│     ├─ autorun.ps1     开机自启
│     ├─ com.ps1         外壳扩展
│     ├─ program.ps1     已安装程序
│     ├─ appx.ps1        AppX / MSIX（PS7 → Windows PowerShell 桥接）
│     ├─ driver.ps1      驱动（注册表方案，不用 pnputil）
│     ├─ firewall.ps1    防火墙规则（COM HNetCfg.FwPolicy2）
│     ├─ ifeo.ps1        映像劫持
│     ├─ fileexts.ps1    文件关联
│     ├─ credprov.ps1    凭据提供程序
│     ├─ repair.ps1      系统修复：8 项配置漂移检查
│     ├─ featurelib.ps1  探针共享库（行形、UTF-8、错误收敛）
│     ├─ actions.ps1     enable / disable / rollback 的执行器（含防火墙九元组）
│     └─ host.ps1        主机事实（是否提权、用户名、系统版本）
├─ tests/
│  ├─ run-all.mjs        55 项检查（31 单元 + 24 真机）
│  └─ render.mjs         无头 React 渲染器：证明面板能挂载、能出数据（真实 12 源 fixture）
└─ docs/
   ├─ DETAIL.zh.md / DETAIL.md    本文
   ├─ SCOPE.zh.md / SCOPE.md      还能拆哪些注册点（含判定为不做的四项与理由）
   └─ REPAIR.zh.md / REPAIR.md    系统修复板块
```

## 5. 接口

### HTTP（宿主）

前缀 `/dsh-windows-toolbox/api/manage`，全部校验 host/origin，非本机来源一律拒绝。

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/status` | 主机事实 + 十二个源的计数与耗时。首次调用会跑全量探测 |
| GET | `/entries` | 统一索引，支持 `source` / `enabled` / `risk` / `q` / `limit` / `lang` 过滤 |
| GET | `/detail?id=` | 单条完整载荷 |
| POST | `/refresh` | 强制重跑（可指定源，并行） |
| POST | `/action` | enable / disable / rollback，**`dryRun` 默认 true** |
| POST | `/repair` | 系统修复八项：`{action:'scan'\|'fix', dryRun, ids}`，**`dryRun` 默认 true** |

### Agent 工具

`wpm_status`、`wpm_list`、`wpm_detail`、`wpm_refresh`、`wpm_action`、`wpm_repair`。
其中 `wpm_action` 的 `dryRun` 默认 **true**——不给明确 `dryRun:false` 就只预演。`wpm_repair` 同理，且描述里写死了「hosts 永不修改、UAC / 字体缓存 / 图标缓存只报告不自动修」。

## 6. 十五个坑（都是实测踩出来的）

### 6.1 PS7 加载不了 Appx 模块，而且不报错

```
在模块 'Appx' 中找到了 'Get-AppxPackage' 命令，但由于以下错误而无法加载该模块:
[Operation is not supported on this platform. (0x80131539)]
```

更糟的是 `Get-AppxPackage` **不抛异常、直接返回空**——看起来像"本机没有任何 AppX 应用"，是个静默假零。本机真实值是 100（`Get-AppxPackage` 在 Windows PowerShell 5.1 下）。

`appx.ps1` 的三级降级：① `Import-Module Appx -UseWindowsPowerShell` 后**验证 count > 0 才算成功**；② 用 `System32\WindowsPowerShell\v1.0\powershell.exe` 重跑自身；③ 读 `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications` 兜底。

旁证（用来判断"到底有没有 AppX"）：`AppxAllUserStore\Applications` 有 44 键、`%LOCALAPPDATA%\Packages` 有 87 个目录，但 `C:\Program Files\WindowsApps` 子目录数是 0——只看最后一个会得出完全错误的结论。

### 6.2 注册表路径里的字面量 `*` 必须用 `-LiteralPath`

`HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers` 这个路径里的 `*` 是**真实的键名**（通配符外壳扩展），用普通 `-Path` 会被当成通配符，PowerShell 去遍历整棵 Classes 树，实测 **> 2 分钟不结束**，被误判成卡死。

用 `-LiteralPath` 立即返回。首版 com 只读到 96 条就是因为这个 bug 静默漏读了一大片。

### 6.3 探测不存在的注册表键 ≈ 387 ms/次

实测：60 次对不存在的键 `Test-Path -LiteralPath` = **23240 ms**；60 次对不存在的子键 = **47003 ms**。

而批量枚举现存键很便宜——三个 CLSID 根全量枚举建索引只要 **1498 ms / 7711 条**，78 个现存键 `Get-ChildItem` 只要 **47 ms**。

`com.ps1` 因此从"每行试探 6-9 个可能不存在的路径"改成"每个根枚举一次进哈希表，解析只走内存"。**85.5 s → 9.81 s → 2.2 s**，78 条一条没少。

> 注意这条只适用于**注册表 provider**。文件系统上 `Test-Path` 对不存在的路径只要 1.62 ms/次（100 次 162 ms），批量探测很便宜。别把两个结论混用。

### 6.4 PowerShell 函数 `return` 会展开 List

`$rows` 是 `List[object]` 时直接 `return $rows`，调用方拿到的是被枚举后的结果（单元素时甚至变成 OrderedDictionary），随后 `.ToArray()` 抛：

```
方法调用失败，因为 [System.Collections.Specialized.OrderedDictionary] 不包含名为 'ToArray' 的方法。
```

修法：`return , $rows`（前置逗号）。任何返回 `List[object]` 的 PowerShell 函数都要这么写。

### 6.5 OrderedDictionary 让 `Sort-Object -Property <键>` 和 `Measure-Object -Sum` 静默失效

这不是报错，是**看起来正常但结果全错**：

```powershell
$rows | Sort-Object -Property bytes -Descending   # 原样输出，完全不排序
$rows | Sort-Object -Property { [int64]$_.bytes } -Descending   # 正确
```

同理 `$rows | Measure-Object -Property files -Sum` 返回空（字典的键不是 cmdlet 眼里的 PS 属性）。

本插件里 svc/task/autorun 走的是 PSCustomObject（安全），没有踩到；但同一套探针思想的下游（360 工具箱的大文件/重复文件/体检）踩了三个地方，全部改成 scriptblock 才对。**只要探针产出 OrderedDictionary，排序和求和都必须用 scriptblock 或手工 foreach。**

### 6.6 PowerShell 默认按系统代码页输出，Node 按 UTF-8 解码 → 中文全乱码

九个 `.ps1` 都用 `[Console]::Out.Write(...)`。PowerShell 默认用 936（GBK）编码输出，Node 按 UTF-8 解码，于是所有中文变成 `�ܾ������ܱ�������`。

之前只测 JSON 结构所以完全没暴露。修法：每个脚本在 `param(...)` 之后加

```powershell
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
```

**任何 PowerShell → Node 的 UTF-8 管道都必须加这一行。**

### 6.7 `pnputil /enum-drivers` 的本地化标签在中文控制台是坏的

它输出**本地化字段标签**（`发布名称:` / `类名:`），在 zh-CN 控制台被 OEM 代码页搞坏：`cmd /c chcp 65001 && pnputil /enum-drivers` 仍然输出 `Class Name: ��չ`，`[Console]::OutputEncoding` 设 936 或 65001 都无效。290 行输出、exit 0，英文标签正常、中文标签报废——任何按标签的解析静默匹配 0 条。

所以 `driver.ps1` 改用注册表：`HKLM:\SYSTEM\DriverDatabase` 下的 `DeviceIds` / `DriverFiles` / `DriverInfFiles` / `DriverPackages`。无编码问题、免提权、信息还更多（正反映射 + SignerScore + 是否第三方）。实测 250 个驱动包 + 168 个设备，1.5 s。

### 6.8 `new URL(...).pathname` 会百分号编码非 ASCII 路径

插件装在 `E:\DSHWORK\DSH插件\...`，`.pathname` 给出 `DSH%E6%8F%92%E4%BB%B6`，PowerShell 报「无法找到路径」，所有探测器全灭。必须用 `fileURLToPath(new URL(file, PROBE_ROOT))`。

### 6.9 外壳扩展值"为空串"和"值不存在"语义相反

`Shell Extensions\Approved` 里：
- CLSID **不在** Approved → 走正常加载路径（**是启用的**）
- CLSID 在 Approved 但**值为空串** → 被显式阻止（**是禁用的**）

首版把两者混成一个 `approved: ''`，导致 78 条全部显示"未知"。修法是探针额外返回 `inApproved` 布尔值，归一化层据此区分。

### 6.10 `New-Item -Force` 在注册表上会清空已存在的键（本人踩过，造成真实数据损失）

为绕开"探测不存在的键很贵"，首版的 tweaks 写路径里写了 `New-Item -Path $r.path -Force`，注释称其为"廉价空操作"。**这个假设是错的**：`-Force` 对**已存在**的键会**重建**它，丢弃全部值与子键，而且不报错。

隔离复现（`HKCU\Software\WpmProbeTest2`）：写入前 `a=111 b=keepme`，执行 `New-Item -Force` 后两者都消失。

真实后果：`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` 被清空成 0 个值。这台机器零还原点、RegBack 不含 HKCU、没有 .reg 备份、没有 Windows.old —— 只能靠事前的导出文件恢复了一部分。

正确写法：

```powershell
if ($null -eq (Get-Item -LiteralPath $r.path -ErrorAction SilentlyContinue)) {
    New-Item -Path $r.path -ErrorAction Stop | Out-Null
}
```

顺带纠正一个数字：**探测不存在的键用 `Get-Item` 只要约 10 ms**，387 ms 是 `Test-Path` 的数字。

> 这条只对**注册表 provider** 成立。文件系统上 `New-Item -ItemType Directory -Force` 实测是安全的（不会清空已存在目录的内容）。

### 6.11 `Get-NetFirewallRule` 在 PS7 下静默返回 0 条

和 6.1 的 AppX 假零同一类陷阱：NetSecurity 模块在 PS7 下拿到 0 条结果、不抛错，看起来像"本机没有防火墙规则"。经 `powershell.exe` 5.1 桥接才报 `Access is denied`。

`firewall.ps1` 因此走 COM 接口 `HNetCfg.FwPolicy2`（`New-Object -ComObject HNetCfg.FwPolicy2`），枚举 542 条规则只要 **44 ms**，且不需要管理员。

**但防火墙规则的 Name 不唯一**：542 条只有 324 个唯一名，加上方向还剩 131 组冲突，再加 `Profiles` 还剩 63 组。所以 `actions.ps1` 用**九元组** `name|dir|action|protocol|localPorts|remotePorts|app|profiles|serviceName` 做键，542/542 唯一；name 回退查询遇重名 > 1 时直接拒绝而不是猜。

### 6.12 PowerShell 的 `param` 块必须是第一条语句

`appx.ps1` 曾把 UTF-8 那行写在 `param(...)` 之前，PowerShell 把 `param` 当成"要调用的命令名"：

```
术语 'param' 不会被识别为 cmdlet、函数、脚本文件或可执行程序的名称。
```

它**打到 stderr 后继续执行脚本体**，而 Node 的 `parseJson()` 会跳过前导噪声，于是"看起来一切正常"，实际上参数一个都没绑上——5.1 降级路径变成永远不会执行的死代码。修好之后立刻暴露出第二个 bug（子进程无限 spawn，见下），因为原来那条分支根本走不到。

全库排查方式：`param` 之前不允许出现任何可执行语句。函数体内的 `param(...)` 不算。

### 6.13 修好参数绑定后炸出的 fork bomb

`-NativeOnly` 子进程里 step 1 被 `if (-not $NativeOnly)` 整段跳过 → `$rows` 仍为 `$null` → step 2 的 `if ($null -eq $rows)` 成立 → 又 spawn 一个 5.1 子进程 → 无限递归。挂死超过 180 秒。

修法：step 2 的条件加 `-not $NativeOnly`。并明确 `-NativeOnly` 的语义是「你是 5.1 子进程：原生枚举，不要走桥、不要再生子进程」——被 withhold 的是**桥**，不是**枚举**。原先把它写成"整段跳过 step 1"，语义正好相反。

### 6.14 解释层不能"复述自己"

`lib/explain.js` 要给每条索引一个白话解释。第一次统计覆盖率时我报了"78/78 条都有友好名"，**这是错的**——拿不到 CLSID 键的 `(default)` 时，代码回退到了 `PSChildName`，而它本身就是那个 GUID，等于用 GUID 证明自己有名字。

真实覆盖（78 条 com 实测）：CLSID 键 `(default)` 有名字 62、DLL 有 `FileDescription` 68、有 `CompanyName` 68（其中第三方 11）、任一来源可用 72；剩下 6 条的友好名其实躺在 `rawValue` 字段里（`Taskband Pin`、`Start Menu Pin`、`OLE DocFile Property Page`、`Summary Properties Page`）。最终从 `displayName || rawValue || dllDescription` 三处取，可达 78/78。

推论：**解释层的素材必须来自探针真实输出的字段**。`explain.js` 第一版引用了 `detail.dllDescription` / `detail.dllCompany`，而 `com.ps1` 从未输出这两个字段 → 全部 `origin: null`、`purpose` 退化。补上探针字段（读 `(Get-Item $server).VersionInfo`，按 DLL 路径去重缓存，24 个唯一 DLL / 78 条引用）后 `origin=thirdparty 11`、`origin=microsoft 57`，代价约 +215 ms。

### 6.15 解释层不能只给"类别"，必须指名到具体是哪一页 / 哪一项

用户原话：「文件夹「属性」对话框里多出来的一页……这里你需要讲明，多出来的是哪一页？具体对应哪项？右键菜单也是，你需要说明对应的是哪个右键菜单，而不是就一句对应右键菜单中的一项。」

根因是 `SHELLX_PLACEMENT`（16 个 `root|kind` → 一句中文/英文）只描述**位置类型**，于是同一类下的 78 条卡片正文一字不差。修法分三步，全部靠探针补字段（不是靠手写 78 条文案）：

1. `com.ps1` 读 CLSID 的 `PageTitle`，用 `SHLoadIndirectString`（`Add-Type` 内嵌 C# 声明 `shlwapi.dll`）解析真实页签名。全机只有 **6** 个 CLSID 带 `PageTitle`，解析结果是「以前的版本」。
2. `com.ps1` 读 `ImplementsVerbs`，把动词翻成用户看到的菜单文字（`startpin`/`startunpin` → 「固定到开始屏幕」/「从开始屏幕取消固定」，`taskbarpin`/`taskbarunpin` → 任务栏版本）。全机只有 **4** 条有动词。
3. 对两者都没有的，`explain.js` 用 `SHELLX_ITEM_LABEL` 表（30 个键，双键 `'<clsid>|<handlerKind>'`，兜底裸 clsid）给已验证的页签名；表里存**裸名**（`位置`、`安全`、`ReadyBoost`），包装（`「…」页` / `"…" tab`）只由调用处加一次——否则会得到 `「「位置」页」页`。

三个必须记住的边界：

- **类名不是菜单文字**。`ShellContextMenu Class`、`DfsShell Class`、`kdesktopshellext Class` 是 COM 的注册类名，右键菜单里根本不显示，当标题比不说更糟。判据 `looksLikeCode = /(^|\s)(Class|Handler|Extension|Extensions|Handler Class|Shell Extension)$|\bCLSID\b|^\{/i`。而厂商自己填的名字（`360压缩文件类型`）**就是**用户看到的菜单项，要用。
- **动词要存菜单项文本，不能存句子**。第一版 `startpin` 写成「把这一项固定到「开始」屏幕」，拼进 `what` 就变成「它加的是把这一项固定到「开始」屏幕」——半句话。现在表里只存 `固定到开始屏幕`，拼装处逐项加引号。这条有回归断言 `!/把这一项/.test(zh.what)` 守着。
- **不能拿占位符当名字**。无名设备 `(未命名)` 必须回落到设备 ID（`HTREE\ROOT\0`），否则会写出「它现在绑定的驱动 INF 是 (未命名)」。

实测（2462 行全量）：`where` 为空 **168 → 0**（修前全是 drv 设备行，整张卡只有一句类别描述）；英文输出里混入 CJK 引号 **67 → 0**；`what` 去重 **2207/2462**；com 的 `—具体是` 命中 **60/78**（剩余 18 条是没有 displayName、也没有 DLL 版本资源的系统 handler，宁可不写也不猜）。

## 7. 权限边界（未提权实测）

| 操作 | 结果 |
|---|---|
| HKCU 自启项改名 | ✅ 成功 |
| HKCU `...\Approved` 写值 | ✅ 成功 |
| HKLM `...\Approved` 写值 | ❌ 拒绝访问 |
| `Set-Service` | ❌ 拒绝访问 |
| `Disable-ScheduledTask` | ❌ 拒绝访问 |
| `pnputil /delete-driver` | 需管理员 |

`actions.ps1` 在写操作前就判断权限：未提权 + 非 dryRun + 源属于 `svc`/`task` → 直接返回

```json
{ "ok": false, "changed": false, "needsAdmin": true, "canElevate": true,
  "message": "该操作需要管理员权限。可在插件里点「以管理员身份重试」。" }
```

dryRun 不受权限影响，照常返回计划和 undo 记录。

## 8. 回滚是怎么做的

**每个改动先捕获 undo，再写。**

| 源 | disable | enable | rollback |
|---|---|---|---|
| svc | `Stop-Service` → `Set-Service -StartupType Disabled` | 恢复为 `Manual`（不是 Automatic，原启动类型存在 undo 里） | 按 undo 里的原 startMode 精确还原 |
| task | `Disable-ScheduledTask` | `Enable-ScheduledTask` | 还原原状态 |
| autorun（注册表） | 值改名为 `<name>.__disabled`（**不删除**） | 把 `.__disabled` 搬回 | 按 undo 还原 |
| autorun（启动文件夹） | 文件名加 `.disabled` 后缀 | 去掉后缀 | 还原 |
| com | `New-ItemProperty -Name <CLSID> -Value ''`（空串 = 阻止） | 写回 displayName | 按 `hadValue` 决定写回还是删值 |

已验证的真实闭环：HKCU RunOnce 项禁用后键名变 `Application Restart #0.__disabled`，回滚后变回原名；HKCU Approved 写入 CLSID 后回滚（`hadValue=false`）该 CLSID 消失、值计数回到 1。测试残留已清理。

拒绝路径也逐条验证过：`RpcSs` → `拒绝操作受保护服务: RpcSs`；不存在的服务 → `服务不存在: xxx`；`program` → `来源 program 不支持 enable/disable（已安装程序、AppX、驱动在本版本仅只读）`。

## 9. 测试

```bash
node tests/run-all-manage.mjs       # 55 项（31 单元 + 24 真机）
node tests/run-all-manage.mjs --unit-only  # 只跑单元（31 项）
node tests/render.mjs               # 单独渲染面板；WINDOWS_TOOLBOX_LANG=en 切英文
```

真机部分会真的启动十二个 PowerShell 探针并读本机状态，但**对 actions.ps1 与 repair.ps1 只跑 dryRun**，不写任何东西。

最后几项（真机段里的 `[render]`）跑的是 `tests/render.mjs`：在一个手写的迷你 React 运行时里挂载 `client.js`，断言组件树不抛错、词典 key 全部解析、真实数据上屏、侧栏 `order` 与 label 正确、任何 `fetch` 都不越出 `/dsh-windows-toolbox/api/manage/` 命名空间，并且 zh/en 两种语言各跑一遍。这是对「面板能正常显示」的自动证明——agent 点不进 DSH 自己的窗口。fixture 用的是从运行中的宿主抓下来的真实 12 源 / 2328 条读数。

## 10. 已知限制

1. **不碰 WinSxS / 组件存储**。这是设计红线：一旦动了组件存储的索引，Windows 累积更新会 9% 回滚，且错误信息是 `Component store is corrupt, please copy the original image and start again`——拷回文件救不了，坏的是索引。
2. **卸载不可撤销**。已安装程序 / AppX / 驱动提供「卸载」，但它只跑程序自己的卸载串或 pnputil，没有回滚记录；系统组件（systemComponent=true）、正在被设备使用的驱动包（bound=true）会被拒绝。
3. **未提权时服务与计划任务改不动**，只能预演。UI 会明确标注。
4. **外壳扩展的 `enabled` 判定依赖 Approved 白名单**，这是 Explorer 的一条旧代码路径；未列入 Approved 的扩展实际处于加载状态，所以默认算"启用"。
5. **驱动包版本号留空**。`DriverDatabase` 里的 `Version` 是二进制 blob，未解析。
6. **AppX 依赖 Windows PowerShell 桥接**。如果系统上 PowerShell 5.1 被移除，会降级到注册表模式（只能列出包名，拿不到版本与发布者）。
7. **面板的实际渲染未经浏览器验收**。agent 侧无法点击 DSH 自己的窗口（`HOST_INPUT_DENIED` / `INPUT_TARGET_UNAVAILABLE` / `WCU_POLICY_DENIED`），已改用无头 React harness 验证组件树能挂载、能出数据、词典 key 齐全（zh/en 双语），但视觉呈现需要人工确认。

## 11. 安装

```
plugin_manager install_bundle  target: E:\DSHWORK\DSH插件\dsh-windows-toolbox
```

装完 profile 里写的是 `link:E:/DSHWORK/DSH插件/dsh-windows-toolbox`——改代码即时生效，不需要重装。宿主与客户端都不需要重启 DSH 就已加载。
