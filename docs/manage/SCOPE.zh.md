# 范围评估：Windows 还有哪些注册点该进 WPM

> 实测环境：Windows 10 专业版 build 19045 · PowerShell 7.6.10 · **未提权** · 2026-11-17
> 所有条数与耗时都是本机实测，脚本可复现，不是估算。

## 0. 先定一条判据

WPM 管的是**注册点**（registration point）：某样东西在系统里登记了自己，于是会被加载、被调用、被列为候选。
判一个新注册点要不要进 WPM，看的不是"这个键有多少条"，而是下面四条同时成立几条：

| 判据 | 说明 |
|---|---|
| **只有一处权威数据源** | 读一次就能完整取到，不需要 DISM、不需要联网、不需要管理员 |
| **有可逆语义** | 开/关是同一件事的两面，undo 能用检测值直接还原 |
| **关错能恢复** | 误操作不产生不可逆后果（不删文件、不重置协议栈、不破坏用户绑定） |
| **单独看有意义** | 一条记录离开上下文也能回答"它是什么、开了吗、关掉会怎样" |

四条全中 → 拆独立管理页；中了前两条但不可逆 → 只作检索引擎的一列（只读）；中不了 → 不做。

这条判据是这次评估的主要产出：8 个候选里有 4 个条数都上千或上百，但只有 1 个真正值得做管理页。

## 1. 结论表（8 个候选）

| 候选 | 条数（实测） | 只读枚举耗时 | 可逆 | 改动风险 | 需管理员 | 判定 |
|---|---|---|---|---|---|---|
| 防火墙规则 | **542**（343 启用） | **44 ms**（COM） | 是，undo = 原 `Enabled` | 关错规则：对应程序/端口的网络被挡或放开；无数据损失 | 读：否；写：**是** | **纳入 · 独立管理页 + enable/disable** |
| IFEO 映像劫持 | **86**（64 位 43 + WOW6432Node 43） | **595 ms** | 否（本版只读） | 恶意劫持的检测价值 >> 管理价值；删错会让兼容性修复或漏洞缓解静默失效 | 读：否；写：是（不提供） | **纳入 · 独立页，只读，劫持项标 bad** |
| 文件关联 FileExts | **520**（163 有真关联） | **88 ms**（.NET 逐键） | **否**（UserChoice 有 Hash 绑定） | 绕过 Hash 改 ProgId 会被系统自动重置，用户以为改成功了 | 否（HKCU） | **不纳入独立页 · 只作检索引擎一列（只读）** |
| 凭据提供程序 | **22** | **4 ms** | 否（本版只读） | 删掉一个 = 少一种登录方式，可能把自己锁在系统外 | 读：否；写：是 | **不纳入独立页 · 只作检索引擎一列（只读）** |
| Winsock LSP | **14** | **5 ms** | 否（只能 `netsh winsock reset` 全量重置） | 重置会断掉所有网络连接，需重启；LSP 链顺序错乱直接断网 | 是 | **不做** |
| 打印提供程序 | **2** | **2 ms** | 否 | 就两个系统组件，删了打印不工作，永远不该被用户点 | 是 | **不做** |
| ShellNew | **7** | **147 ms**（.NET 逐子键） | 是（删/new 一个子键） | 只影响右键"新建"菜单；价值不足以撑一页 | 写：是 | **不做** |
| CBS 组件包 | **1680** | **6 ms**（.NET） | 否 | `CurrentState` 是位掩码，离了 DISM 无法翻译成"装好了/坏了/待重启" | 读：否；写：是（DISM） | **不做** |

> 条数与耗时的口径说明：耗时都是**只读枚举**这一件事，不含后续字段解析以外的处理。
> 作为对照：`netsh advfirewall firewall show rule name=all verbose` 实测 943 ms / 10251 行，被 COM 的 44 ms 替代。
> 遍历整棵 `HKLM\SOFTWARE\Classes` 找 ShellNew 实测 1741 ms（顶层）/ 3365 ms（通配）/ 9063 ms（深层递归），改用逐子键 `OpenSubKey('ShellNew')` 后 147 ms。

## 2. 逐个说明

### 2.1 防火墙规则 —— 唯一真正值得做管理页的

**为什么值得**：它是这四个判据全中的唯一一个。542 条规则每条都是"允许/阻止某个程序或端口"，`Enabled` 就是一个布尔开关，关掉的效果和删除规则在行为上等价但完全可逆。

**为什么用 COM 而不是 netsh 或注册表**：

| 方法 | 耗时 | 问题 |
|---|---|---|
| `netsh advfirewall firewall show rule name=all verbose` | 943 ms / 10251 行 | 解析文本，字段靠正则，出错无声 |
| `Get-NetFirewallRule`（NetSecurity 模块） | 1162 ms | **PS7 下静默返回 0 条**；powershell.exe 桥接报 "Access is denied"（System Error 5）。本机这条路不可用 |
| 注册表 `FirewallRules` 键 | 67 ms 读 + 94 ms 解析 | 值形如 `v2.30\|Action=Allow\|Active=FALSE\|...`，能读能写，但绕过防火墙服务校验 |
| **`New-Object -ComObject HNetCfg.FwPolicy2`** | **44 ms 全字段** | 官方路径，字段是强类型属性 |

**Name 不是唯一键 —— 这是接线时踩到的真坑**：542 条规则只有 324 个唯一 Name。`name+direction` 仍有 131 组冲突，加上 `Profiles` 仍有 63 组冲突，甚至同名的两条规则状态可以不同（网络发现的 `SSDP-In` 有两条：`Profiles=5 Enabled=False` 和 `Profiles=2 Enabled=True`，netsh 也确认）。
最终用**九元组** `name|dir|action|protocol|localPorts|remotePorts|app|profiles|serviceName` 才做到 542/542 唯一。所以：

- 条目 id 用九元组，不用 Name。
- `actions.ps1` 没有 `keyPath` 时按 Name 回退，**重名超过 1 条直接拒绝**并要求传 `keyPath`，不猜。

**写权限实测**：`$rule.Enabled = <原值>` 在未提权时抛 `E_ACCESSDENIED 0x80070005`，规则保持原状——COM setter 失败是干净的，不会半写。写操作因此进 `$writeNeedsAdmin`，未提权时返回 `needsAdmin:true` 让面板提示提权重试。

**备份**：`reg export` 该键免提权可成功（77 ms / 314632 字节），所以每次写入前导出一份到 `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\<时间戳>-firewallrules.reg`；导出失败就中止写入，不写。

**没做的**：不给程序路径补 `VersionInfo`（发布者/版本）。全量实测 5161 ms——64 个路径在 System32 冷启动极慢。字段留空好过让一页慢五秒。

### 2.2 IFEO 映像劫持 —— 不做管理，必须做检测

`Image File Execution Options` 下每个子键以 exe 名命名，如果里面有个 `Debugger` 值，那么**启动那个 exe 时实际运行的是 Debugger 指向的程序**，原程序根本不会启动。这是真实在用的恶意软件持久化手法，正常机器不该有这一项。

**本机实测**：64 位视图 43 个键、WOW6432Node 43 个，**没有任何 Debugger 值**。值名分布是 `MitigationOptions`×78、`CFGOptions`×4、`DisableExceptionChainValidation`×4、`DisableUserModeCallbackFilter`×2、`MinimumStackCommitInBytes`×2——都是 Windows 自己的漏洞利用防护（exploit protection）写的。

**判定理由**：检测价值 >> 管理价值。一个 43 条、平时全是系统缓解项、只在被入侵时才有 `Debugger` 的列表，用户一周看一次就够，但它必须**在列表里醒着**。所以：

- 独立成一个 source，让它在来源条和侧栏可见。
- `riskOf()` 里 `detail.hijacked === true` → 返回 `RISK.blocked`，于是劫持项按 blocked 排序规则**排到最前面**并显示红色，和受保护服务同一个视觉层级。
- 写入不提供：删错一个 `MitigationOptions` 会让对应程序的漏洞缓解静默失效，而用户看不出任何变化。

### 2.3 文件关联 —— 有数据，但不能改

**实测**：520 个扩展名，其中 515 个有 `UserChoice` 子键，但**只有 163 个带 `Progid` 值**（注意本机值名是 `Progid`，小写 d；PowerShell 属性名区分大小写，匹配必须两边都试）。352 个 `UserChoice` 键完全没有任何值——卸载软件留下的空壳，这正是"双击没反应/总是弹选择框"的常见原因，值得让用户看见。

**为什么不可逆**：`UserChoice` 里还有一个 `Hash` 值（本机样本 `NRGqFLyZwMc=`），Windows 用它校验 ProgId 没有被第三方改过。直接改 ProgId 而不重算 Hash，系统会在登录/重启后**静默重置回原值**——用户以为改成功了，实际没有。重算 Hash 是未公开算法，不做。

所以：只读列出（扩展名 → 当前 ProgId → 实际打开命令，ProgId→命令解析 67/79 命中，9 ms），`actions: []`，解释卡片明说"要改请走系统「默认应用」界面"。

**性能坑**：逐扩展名用 `Get-ItemProperty -LiteralPath` 三次（UserChoice / OpenWithProgids / OpenWithList）实测 **34210 ms**，灾难级。改用 `[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey()` 逐子键直接 `GetValue` 后降到 88 ms。探针里零通配符。

### 2.4 凭据提供程序 —— 22 条，只读，安全视角

**实测**：22 个 CLSID，全部有显示名和可解析的 `InprocServer32` DLL（10 ms）。样本：`{01A30791-…}` = Automatic Redeployment Credential Provider / `mgmtrefreshcredprov.dll`，`{25CBB996-…}` = GenericProvider / `credprovs.dll`。

**为什么只读**：每个提供程序就是一种登录方式。删掉 = 少一种登录方式，最坏情况把自己锁在系统外面，而且恢复需要另一条登录路径。这个代价和"看列表"的收益不成比例。

**为什么仍然值得进索引**：两个可检测信号——
- `dllMissing`：注册的 DLL 已经不在 → 该登录方式被跳过，这就是"PIN/指纹选项突然消失"的常见原因。
- `inSystemDir === false`：DLL 不在 Windows 目录 → 第三方组件，而这类组件能读取锁屏时输入的口令，来源不明的值得核实。

22 条里有 12 条不是已知白名单项，全部 22 条 DLL 都在 System32。

### 2.5 Winsock LSP —— 不做

14 项，5 ms 能读。但：

- 14 项全是系统组件（`mswsock.dll`、`wshqos.dll`）。`PackedCatalogItem` 是 888 字节的二进制，用 Unicode/ASCII 两种方式扫都**只扫得出 ProtocolName，扫不出 DLL 路径**——探针没法可靠说出"这一项是谁"。`netsh winsock show catalog`（143 ms / 575 行）也一样，Provider Path 全文只有 `%SystemRoot%\system32\mswsock.dll`。
- 没有单项开关。唯一的"修复"是 `netsh winsock reset`，那是**全量重置**，会断掉所有网络连接并要求重启。

一个只能全量重置、连"这一项是什么"都说不清的列表，放进来只会诱导用户去点那个 reset。不做。

### 2.6 打印提供程序 —— 不做

2 项（Internet Print Provider / `inetpp.dll`，LanMan Print Services / `win32spl.dll`），1 ms。固定两个系统组件，删任一个打印就不工作，没有"管理"这个动作存在。不做。

### 2.7 ShellNew —— 不做

7 项：`.bmp .contact .library-ms .lnk .rtf .txt Folder`。找到了一条 147 ms 的可行枚举法（`LocalMachine.OpenSubKey('SOFTWARE\Classes')` 后逐子键 `OpenSubKey('ShellNew')`，避免整树遍历），技术上完全能做。

但它的作用域只有右键"新建"菜单里的那几项，开关它既不影响任何程序的加载，也不影响任何文件的行为。撑不起一页，塞进索引也只是噪音。不做。

### 2.8 CBS 组件包 —— 不做

1680 条，6 ms（.NET 直读）。问题在语义：`CurrentState` 是位掩码（样本值 64），离开 DISM 无法翻译成"已安装/已损坏/待重启"。而且组件包**没有单独的开关**——不存在"关掉这一个包"这个动作，只能 uninstall 走 DISM 并触发重启。

一个 1680 行、状态码用户看不懂、动作只有"卸载并重启"的列表，是那种看着很专业、实际每次打开都只能关掉的页面。不做。

## 3. 对照 360「系统修复 / 优化加速」板块

用户指出 360 的系统修复板块其实是"一类可开关的系统项集合"，和 WPM 是同一件事的两种叫法。这个观察部分成立，但**两者不是同一个轴**，值得说清楚：

- WPM 的 source 是**注册点**：某样东西登记了自己，会被加载/调用。问题形如"这条是什么、开了吗"。
- 360 系统修复的多数项是**配置漂移检查**：某个值应该等于 X 但现在是 Y。问题形如"这项被改了吗、改回去"。

注册点是"一堆同类的行"，配置检查是"一堆各自独立的断言"。后者不需要列表视图，需要的是"发现问题 → 一键修"。硬塞进 WPM 的 source 表格里，每一行都是一条孤例，反而没有价值。

逐项映射（本机实测）：

| 360 系统修复项 | 落在 WPM 的哪个 source | 本机实测 | 结论 |
|---|---|---|---|
| 启动项过多 | **autorun**（+ svc / task） | autorun 3 条 | 已有，可管 |
| 系统服务配置 | **svc** | 272 条 | 已有，可管 |
| 计划任务异常 | **task** | 165 条 | 已有，可管 |
| 桌面图标 / 快捷方式劫持 | **com**（外壳扩展）+ **ifeo**（启动劫持） | com 78 / ifeo 86（0 劫持） | 已有。桌面 `.lnk` 0 个；快捷方式目标需逐文件 WSH 解析，不在注册点范围 |
| 系统时间异常 | **svc**（`w32time`） | Running / Manual | 已有 |
| Windows Update 相关服务状态 | **svc**（`wuauserv` / `BITS`） | Running/Manual；Stopped/Manual | 已有 |
| LSP 修复 | 新候选 **winsock** | 14 项 / 5 ms | **不纳入**（见 2.5，只能全量 reset） |
| hosts 异常 | **无 source**（是文件，不是注册点） | 存在，0 条有效条目，53 ms | 不做：属文件完整性检查 |
| IE / 浏览器设置被篡改 | **无 source** | `HKCU\…\Internet Explorer\Main` 24 个值，16 ms | 不做：policy 值检查，非注册点 |
| DNS 设置 | **无 source** | 静态 DNS 的接口 0 个，41 ms | 不做：同上 |
| 网络连接数限制 | **无 source** | `Tcpip\Parameters` 相关值 0 个，31 ms | 不做：同上 |
| UAC 设置 | **无 source** | `EnableLUA=1` / `ConsentPromptBehaviorAdmin=5`，17 ms | 不做：同上 |
| 注册表冗余项 | **无 source** | — | 不做：需要全树扫描，成本与误判都高 |
| 字体缓存损坏 | **无 source**（文件） | `FontCache` 目录 0 个文件 | 不做 |
| 图标缓存损坏 | **无 source**（文件） | `IconCache.db` 存在 + 16 个 `iconcache*`，37 ms | 不做：属文件清理，与 tb360 工具箱重叠 |

合计 15 项里 **6 项落在已有 source 上**（autorun / svc / task / com / ifeo），1 项落在评估过的新候选（winsock，判定不纳入），8 项属**另一类能力**（配置漂移 / 文件完整性），不是 WPM 该长的东西。

**结论**：不因为"360 有这个"就往 WPM 里加配置检查。真要做那 8 项，正确形态是一个独立的"系统修复"插件（断言-检测-修复三段式），不是一个 source。

## 4. 落地清单

新增 4 个 source（sources.js 从 7 项 → **11 项**）：

| source | 用途 | 条数 | 探针耗时 | risk | actions |
|---|---|---|---|---|---|
| `firewall` | 防火墙规则 | 542 | 1314 ms | reversible | `enable` / `disable` |
| `ifeo` | IFEO 映像劫持 | 86 | 595 ms | readonly（劫持项升 blocked） | `[]` |
| `fileexts` | 文件关联 | 520 | 696 ms | readonly | `[]` |
| `credprov` | 凭据提供程序 | 22 | 551 ms | readonly | `[]` |

统一索引从 1150 条 → **2320 条**。`node tests\run-all.mjs` → **PASS 47/47**（原 43 项 + 新增 4 个 source 各 1 项枚举断言）。

## 5. 关于 client.js（只读核对，未改动）

`client.js` 属另一条改动线，本次一行未碰。落盘时点复核了它对新 source 的处理，结论是**已经自动跟上了**，不需要为新 source 再改：

- 侧栏与来源条从 `status.sources` 动态生成 → 新 source 自动出现。
- 行/卡片的动作按钮由 `canAct = actions.length > 0` 决定，`actions` 来自后端 `/status` 里的 source summary，**不是硬编码的 source 名列表**。所以 `firewall`（`actions: ['enable','disable']`）自动拿到按钮，三个只读 source 自动落到 `readonlyNote`（「此项在本版本仅只读。」）。
- 风险徽章走 `RISK_KEY` 表，`readonly` → 「只读」，`blocked` → 「受保护」红色。

早前版本的 `client.js` 里 `canAct` 曾是硬编码的 `['svc','task','autorun','com']`、列表行也曾对非 blocked/destructive 一律渲染按钮——这两处在本次落盘前已被另一条改动线修掉，当前实现读的是后端声明。**新增 source 只需在 `sources.js` 里诚实声明 `actions`，面板会自己跟上。**
