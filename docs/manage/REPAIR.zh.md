# 系统修复（repair）

对照 360 安全卫士的「系统修复 / 优化加速」。360 的系统修复列表有 15 项，其中 6 项已经是本插件现有的 source（启动项 → `autorun`、服务 → `svc`、计划任务 → `task`、快捷方式劫持 → `com` + `ifeo`、系统时间 → `w32time`、Windows Update → `wuauserv` + `BITS`），1 项（winsock 重置）已判定不做。

**剩下的 8 项不是「注册点」，而是「配置漂移」**：没有某个可以启用/禁用的对象，只有「这个设置现在是什么值、本来应该是什么值」。所以它们不塞进 `SOURCES` 的开关卡片，而是单独一个板块，每一项走同一套三段式：

```
assert（这项本来应该是什么样）
  → detect（现在实测是什么样）
    → fix（怎么无损地改回去）
```

- 探针：`lib/probes/repair.ps1`（固定输出 8 行，行形与 featurelib 族完全一致）
- 路由：`POST /dsh-windows-toolbox/api/manage/repair`
- 工具：`wpm_repair`
- 前端：面板顶部的「系统修复」条（与卡片区并列，不参与 source 分组）

## 参数

| 参数 | 取值 | 默认 | 说明 |
| --- | --- | --- | --- |
| `action` | `scan` \| `fix` | `scan` | `scan` 只读；`fix` 才会走到写路径 |
| `dryRun` | `true` \| `false` | **`true`** | `fix` + `dryRun=false` 才真的写盘/写注册表 |
| `ids` | `string[]` | 全部 | 只处理这些 id：`hosts` / `ie` / `dns` / `netconn` / `uac` / `redundant` / `fontcache` / `iconcache` |

写路径的三条硬约束（沿用 `actions.ps1` 的既有契约）：

1. 默认 `dryRun`。非 `dryRun` 的写之前一律 `reg export` 整键备份到 `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\`，**备份失败即中止，不写半截**。
2. 绝不对已存在的注册表键用 `New-Item -Force`（会重建键、丢弃全部值与子键）。本探针只用 `Set-ItemProperty` / `Remove-ItemProperty`，**从不建键**。
3. 需要管理员（HKLM）的写，未提权时直接 `skip` 并说明原因，不做半截写。

## 八项逐条

### 1. `hosts` — hosts 文件异常

| | |
| --- | --- |
| 检测什么 | `C:\Windows\System32\drivers\etc\hosts` 的**非注释有效行**：被指向的 IP、被重定向的域名 |
| 怎么判 | 名字是 localhost 系列之外、IP 是 `0.0.0.0` / `127.0.0.1` / `::1` / `::` → **屏蔽**（warn）；IP 不是 loopback → **重定向**（bad）；只有注释或用户自己的正常映射 → ok |
| 修复动作 | **只做无损快照**：把原文件复制成 `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\hosts.<stamp>.bak`。**内容一律不改**（hosts 是运维和开发者会主动改的文件，自动改写风险远大于收益） |
| 需要管理员 | 否（读文件；写快照是写到用户目录） |
| 本机实测（2026-11-17） | `status=ok`，`value="0 条有效 / 824 B"`，detail：有效条目 0 条，屏蔽 0、重定向 0 |

### 2. `ie` — IE 浏览器设置被篡改

| | |
| --- | --- |
| 检测什么 | `HKCU\Software\Microsoft\Internet Explorer\Main` 的 `Start Page` / `Search Page` / `Default_Page_URL` / `Search Bar` / `Local Page` |
| 怎么判 | `Start Page` 为 `about:blank` → 正常；指向非微软域 → **劫持**（bad）；其它漂移 → warn。`Search Page` / `Default_Page_URL` 同样按微软域集合判定 |
| 修复动作 | `Set-ItemProperty -Name 'Start Page' -Value 'about:blank'`（HKCU，写前 `reg export` 备份整键，写完读回校验） |
| 需要管理员 | 否（HKCU） |
| 本机实测（2026-11-17） | `status=ok`，`value="24 个值 / Start=about:blank"`，`Search Page=http://go.microsoft.com/fwlink/?LinkId=54896` |

> 说明：IE 已被微软退役，但这一项仍会被老式安装器/捆绑包写入——它不是「IE 有没有用」的问题，而是「有没有人改过你浏览器的默认入口」的证据。

### 3. `dns` — DNS 设置异常

| | |
| --- | --- |
| 检测什么 | `HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\*` 下每个接口的 `NameServer`（静态）与 `DhcpNameServer`（DHCP 下发） |
| 怎么判 | 静态 DNS 属于常见公共 DNS（`114.114.114.114`、`8.8.8.8`、`223.5.5.5`、`1.1.1.1` 等）或内网段 → ok；静态且非常见地址 → warn。**不做可达性探测**（不 ping、不查 53 端口），只比对地址 |
| 修复动作 | 无自动修复。detail 给出人工步骤：改回「自动获取 DNS」（`Set-DnsClientServerAddress`，需要管理员） |
| 需要管理员 | 是 |
| 本机实测（2026-11-17） | `status=ok`，`value="静态 0 / 共 8 个接口"`，DHCP 下发 DNS 的 2 个（WLAN `119.6.6.6 192.168.0.1`） |

> 为什么读注册表而不调 `Get-DnsClientServerAddress`：后者本机实测 378 ms，`netsh interface ip show config` 97 ms，而读 8 个接口的注册表值是 25 ms 量级。同一条信息，选最便宜的量法。

### 4. `netconn` — 网络连接数限制

| | |
| --- | --- |
| 检测什么 | `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters` 与 `...\Tcpip6\Parameters` 下 `TcpNumConnections` / `MaxUserPort` / `TcpTimedWaitDelay` / `MaxConnections` / `TcpMaxHalfOpen` / `TcpMaxHalfOpenRetried` |
| 怎么判 | **这些值默认不存在就是正常**。存在即视为被「优化加速」类工具改过 → warn；值不在合理范围 → bad |
| 修复动作 | 逐值 `Remove-ItemProperty`（**不用 `reg delete`**），写前 `reg export` 备份整键。未提权直接 skip |
| 需要管理员 | 是（HKLM） |
| 本机实测（2026-11-17） | `status=ok`，`value="0 个被改写的连接数限制"`，六个值全部未设置 |

### 5. `uac` — UAC 设置

| | |
| --- | --- |
| 检测什么 | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` 的 `EnableLUA` / `ConsentPromptBehaviorAdmin` / `PromptOnSecureDesktop` / `FilterAdministratorToken` |
| 怎么判 | `EnableLUA` 未设置或 ≠1 → **bad**（UAC 被关）；`ConsentPromptBehaviorAdmin` `5`（默认）或 `2`（最严）→ 正常，`0` → **bad**，其它 → warn；`PromptOnSecureDesktop=0` → warn。`FilterAdministratorToken` 为 `0` 或未设置是 Windows 默认（内置 Administrator 不过滤），**不算漂移** |
| 修复动作 | 无自动修复（需要注销/重启才生效，属「需要重启的修复」，本板块不做）。detail 给出应写回的值 |
| 需要管理员 | 是 |
| 本机实测（2026-11-17） | `status=ok`，`value="EnableLUA=1 / ConsentPromptBehaviorAdmin=5"`，`PromptOnSecureDesktop=1`，`FilterAdministratorToken=unset` |

### 6. `redundant` — 注册表冗余项

| | |
| --- | --- |
| 检测什么 | 启动项五处（`HKLM`/`HKCU` × `Run`/`RunOnce`，含 `WOW6432Node`）与卸载项三个根（`HKLM Uninstall`、`HKLM WOW6432Node Uninstall`、`HKCU Uninstall`）里，**指向不存在的可执行文件**的条目 |
| 怎么判 | 从命令行解析出可执行文件（处理带引号/不带引号带空格/`DisplayIcon` 的 `,0` 图标索引后缀/`.ico` 图标路径），再用 `Test-Path` 判存在。**三态**：存在 → 活；确定不存在 → 死；测不到（ACL 拒绝、裸文件名无法解析）→ **不判死** |
| 修复动作 | **只删死启动项值**（逐值 `reg export` 备份整键 + `Remove-ItemProperty` + 读回校验）。**卸载项只报告，不删除**——卸载项残缺并不影响系统运行，删了反而可能让「程序和功能」列表说谎 |
| 需要管理员 | 是（HKLM 部分） |
| 本机实测（2026-11-17） | `status=info`，`value="启动项 3 条（死路径 0）/ 卸载项 130 个（死路径 2）"`，两条真死路径：`Bun -> C:\Users\26035\.bun\bin\bun.exe`、`夸克网盘 -> ...\Programs\QuarkCloudDrive\quark_cloud_drive.exe` |

> **这一项踩过两个真坑，都改掉了**：
> 1. `DisplayIcon` 的 `.ico` 路径被当成可执行文件判死，导致 `Git`、`原神`、`Adobe Photoshop` 等 7 个项目误报。现在 `.ico/.png/.bmp/.jpg/.gif/.svg` 结尾一律回退到 `UninstallString` 再判。
> 2. `Test-Path` 对 ACL 保护目录**抛 `UnauthorizedAccessException` 而不是返回 `false`**，被当成「不存在」，`Intel Package Cache` 因此误报。现在 catch 成 `$null`（测不到），不判死。

### 7. `fontcache` — 字体缓存

| | |
| --- | --- |
| 检测什么 | `C:\Windows\ServiceProfiles\LocalService\AppData\Local\FontCache` 的可枚举性、文件总大小、是否存在 `~FontCache-FontFace*.dat` 冲突文件；附带 `C:\Windows\System32\FNTCACHE.DAT` 与 `FontCache` 服务状态 |
| 怎么判 | 目录不可读 → **skip**（写清「需要管理员」，不是「不存在」）；目录真的不存在 → warn；存在 `~FontCache-FontFace*` → bad |
| 修复动作 | 无自动修复（要停 `FontCache` 服务，本板块不做需要停服务的修复）。detail 给出人工步骤 |
| 需要管理员 | 是 |
| 本机实测（2026-11-17） | `status=skip`，`value=""`，detail：`拒绝访问（UnauthorizedAccessException）。该目录的 ACL 只允许 LocalService 读取，当前会话未提权` |

> **坑**：不能用 `[System.IO.Directory]::Exists()` 判这个目录——本机它对被 ACL 挡住的目录返回 `False`，会误判成「目录不存在」。必须用 `Get-ChildItem -ErrorAction Stop` 的 try/catch，按异常类型分支。

### 8. `iconcache` — 图标缓存

| | |
| --- | --- |
| 检测什么 | `%LOCALAPPDATA%\Microsoft\Windows\Explorer` 下 `*iconcache*` 与 `IconCache.db` 的文件数、总大小、0 字节数量、`iconcache_idx.db` 大小 |
| 怎么判 | **0 字节不判损坏**——`iconcache_*.db` 是 Windows 懒分配，本机 15 个文件里 12 个常年 0 字节，属正常。只有 `iconcache_idx.db` 为 0 字节，或 `IconCache.db` 存在且 0 字节 → warn |
| 修复动作 | 无自动修复（要重启 `explorer.exe`）。detail 给出人工步骤 |
| 需要管理员 | 否（用户目录） |
| 本机实测（2026-11-17） | `status=ok`，`value="15 个文件 / 1031.5 KB / 0 字节 0 个"`，`iconcache_idx.db = 7416 B` |

> 同一天早些时候的测量是「15 个文件 / 2055.3 KB / 0 字节 11 个」——Explorer 会在使用中重写这批文件，所以**这项的数字会变，属正常**，判据里不能把 0 字节数量当硬指标。

## 本机整体结果（2026-11-17，未提权 pwsh 7）

```
action=scan  count=8
summary: { total: 8, ok: 6, warn: 0, bad: 0, info: 1, skip: 1 }
elevated: false
timings (三次取样): hosts 13 / 13 / 13, ie 37 / 32 / 30, dns 23 / 23 / 18, netconn 48 / 50 / 47,
                   uac 17 / 18 / 17, redundant 215 / 236 / 211, fontcache 4 / 6 / 4, iconcache 12 / 13 / 9   // ms
整轮 wall clock: 952 / 1041 / 939 ms
```

`redundant` 是唯一耗时过两百毫秒的项（211–236 ms，130 个卸载子键逐个 `Test-Path`）。其余七项加起来不到 160 ms。取样差异来自文件系统缓存与 Explorer 抖动，不是逻辑变化。

`action=fix&dryRun=true` 时，detail 末尾会追加一行 `| dryRun：...`，说明「本来会做什么、备份到哪」。本机只有 `hosts` 会追加（因为其余各项当时都是 ok，没有该修的东西）。

真实写路径已单独验证过：造一个指向不存在 exe 的 `HKCU\...\Run` 值 → `fix dryRun=true` 报 warn「启动项 4 条（死路径 1）」→ `fix dryRun=false` 报 ok「已删除 1 个死启动项」→ 注册表读回确认值已消失、备份 `.reg` 文件已生成。

## 为什么不做成 source 的 enable/disable

`lib/sources.js` 里 `repair` 声明的是 `risk: readonly` + `actions: []`。

理由：现有 11 个 source 的每一行都是**注册点**——某个服务、某个计划任务、某个 CLSID，可以「启用」或「禁用」。而这一板块的每一行是**一条结论**（「hosts 目前 0 条有效条目」），它没有 enabled/disabled 状态，硬造一个只会让前端出现两个按不动的假按钮。

修复的真实粒度是**整块**（把 Start Page 写回 about:blank、删掉若干个死启动项值），不是「这一行」。所以它走独立的 `POST /api/repair`，`dryRun` 默认 `true`，前端还要「预演 → 确认执行」两步。

## 相关文件

| 文件 | 作用 |
| --- | --- |
| `lib/probes/repair.ps1` | 探针本体，8 项检测 + 可修项的写路径 |
| `lib/probes/featurelib.ps1` | 共享库（`Read-ProbeParams` / `New-ProbeList` / `Add-Item` / `Write-ProbeResult` / `Get-RegValue` / `Test-Elevated`） |
| `lib/sources.js` | `repair` source 声明（`shape: 'items'`） |
| `lib/normalize.js` | `items` 信封分支 + `repair` 的行特化 |
| `lib/explain.js` | `repair` 的 `SOURCE_KIND` 与按 checkId 的 WHERE 表（zh/en 成对） |
| `index.js` | `POST /api/repair` 路由、`wpm_repair` 工具、`?lang=` 重算 explain |
| `client.js` | 面板顶部的「系统修复」条 |
