# 360 工具箱（dsh-windows-toolbox 的「工具箱」页签）

把 360 安全卫士里真正能落地的那部分系统维护功能拆出来，做成 **29 个可审计的、只读优先的能力**，跑在 DSH 里。不装驱动、不常驻、不弹广告、不给没有依据的分数。

**不做什么**：不做实时拦截（没有常驻进程，挂不了 `SetWinEventHook`），不做杀毒引擎（没有特征库，不扫恶意代码），不删系统文件（删除只发生在固定白名单内的缓存目录，目录本身一定保留）。

本文所有读数都是在本机（Windows 10 专业版 22H2 · 19045.7846 · 64 位、PS7、**未提权**、内存 31.8 GB、2 块 NVMe SSD）上实跑探针得到的，核对日期 2026-11-17。测不到的项在表里写 skip，不折算成通过。

## 能力总览

| 维度 | 实测值 |
| --- | --- |
| 能力数 | 29（`lib/capabilities.js` 的 `CAPABILITIES.length`） |
| 分组 | cleanup 6 / system 15 / network 2 / apps 6 |
| coverage 分布 | full 9 / partial 9 / readonly 7 / blocked 4 |
| 动词 | scan（全部 25 项）、clean（junk）、apply（homepage / backup / softmgr / contextmenu / winsettings / tweaks / shredder）、repair（netdiag）、dnspick（netdiag） |
| 有写动作的能力 | 9（junk 清理 / netdiag 修复与 DNS 切换 / homepage / backup / softmgr / contextmenu / winsettings / tweaks / shredder 的 apply） |
| 需要管理员 | 1（`tweaks`，只在真写 HKLM 项时才要） |
| 探针 | `lib/probes/*.ps1` 共 44 个 = 25 个能力探针 + 12 个注册点探针 + featurelib / junklib / rootlib 三个库 + actions / elevated / host / broker 四个基础设施 |
| 面板视图 | checks 25 个能力共用 `ChecksList`；junk=表、bigfiles=表、dupfiles=表、netdiag=分步 |

### coverage 四个值分别是什么意思

coverage 描述的是**能力的完整度**，不是评分，也不代表风险。

- **full（9 项）**：这个能力要干的事在我们范围内已经做全了。读的是完整数据，或者写动作也接了线（带预演与备份）。缺的只有操作系统本身不允许的部分，那部分单独写在「已知限制」里。
- **partial（9 项）**：只做了一部分，缺哪部分在下面能力表里逐项写明。共同点是：检测侧做全了，动作侧（拦截、下载、搬移、修复、自动装）没接线，或者做了也达不到 360 的效果。
- **readonly（7 项）**：只检测、给结论、给证据，**不给修复按钮**。原因要么是修复动作必须管理员（`sfc` / `DISM` / `pnputil` / `Set-Service`），要么是修复本身有害（例如把隐私开关全部反过来关一遍，会连带关掉需要它们的应用）。
- **blocked（4 项）**：本机条件不允许，能力自己会给出被什么挡住。4 项全部是硬约束：C 盘扩容被 608 MB 恢复分区挡住（空隙只有 32.5 KB），文件误删恢复被 SSD+TRIM 挡住，系统重装需要重启进另一个环境，变形虫防护的固件层攻击在 OS 内无解。

## 25 个能力总表

「本机实测读数」列是这一轮探针的原始取样，耗时含 PowerShell 启动与 WMI 查询。

### 清理与空间（cleanup，6 项）

| 能力 | coverage | actions | 需要管理员 | 本机实测读数 |
| --- | --- | --- | --- | --- |
| 垃圾清理 junk | full | scan+clean | 否 | 9 组 31 个目标，17200 个文件 / 2.01 GB，4 个目标因未提权跳过 |
| 大文件查找 bigfiles | full | scan | 否 | 根目录=用户目录，197703 个文件 / 44.9 GB，命中 49 个 ≥100 MB，8282 ms |
| 重复文件 dupfiles | full | scan | 否 | 根目录=下载，3032 个文件，全量哈希 44 个，22 组，可回收 63.6 MB，458 ms |
| 系统盘瘦身 slim | readonly | scan | 否 | C 可用 165.19 / 302.03 GB（54.7%）；pagefile 48.83 GB；hiberfil 不存在；Windows.old 不存在；13 项 4648 ms |
| C 盘扩容 expandc | blocked | scan | 否 | C 结束于 324420992512，恢复分区起始于 324421025792，中间只隔 32.5 KB；两块盘最大连续未分配 1.0 MB |
| 文件粉碎机 shredder | partial | scan+apply | 否 | 2 块 SSD / 0 块 HDD，TRIM 已开（DisableDeleteNotify=0）→ 结果里直接标「SSD 上覆盖写无效」 |

- 垃圾清理为什么 full：9 组 31 个目标的白名单固定、清理动作接了线、未提权的目标会明确 skip 而不是假装成功。它是本项目两个标 `destructive` 的能力之一（另一个是文件粉碎机）。

#### 9 个分组与 31 个目标

分组 id 只能取自这 9 个（`lib/capabilities.js` 的 `JUNK_GROUPS`，`lib/probes/junklib.ps1` 是唯一的目标定义处）；两处数量由测试断言强制一致。

| 组 | 名称 | 目标 | 这组怎么处理 |
| --- | --- | --- | --- |
| temp | 临时文件 | user-temp / windows-temp / crash-dumps / wer-report | 程序运行中产生的临时副本，删除后不影响已安装的软件 |
| browser | 浏览器缓存 | edge-cache / edge-code-cache / chrome-cache / chrome-code-cache / inet-cache | 网页缓存与编译缓存，清理后首次打开网站会略慢；不会退出登录 |
| system | 系统缓存 | thumb-cache / icon-cache / prefetch / dns-cache | 缩略图/图标缓存与预读取文件，清后会自动重建；正在被占用时会被跳过 |
| update | 更新与传递优化 | wu-download / delivery-opt | 已安装更新的下载副本，删除不影响系统版本；需要管理员权限 |
| recycle | 回收站 | recycle-bin | 清空后无法通过回收站恢复，确认再执行 |
| privacy | Cookie 与登录痕迹 | edge-cookies / chrome-cookies / inet-cookies | 清理后相关网站需要重新登录；浏览器正在运行时文件被独占，会如实跳过而不是假装清掉了 |
| traces | 使用痕迹 | recent-lnk / recent-auto / recent-custom / ps-history | 最近打开的文件、任务栏跳转列表、命令行历史；清完不会影响已安装的软件 |
| registry | 注册表残留 | typed-paths / run-mru / uninstall-shells / binary-mru / mui-cache / app-paths / firewall-rules | 只处理「指向的路径已经不存在」的项。每条删除前备份到 regbackup 可单独回滚；空壳卸载项、二进制 MRU 与防火墙规则只检测不删；默认值为空的 App Paths 子键会被跳过 |
| plugins | 浏览器扩展 | browser-extensions | 只读发现，列出已装扩展的数量与来源；卸载有风险，请在浏览器的扩展页自己操作 |

前五组（temp / browser / system / update / recycle）对应 360 `sweeper/okctree.xml` 里的 `sysclean`；后四组是我们照 360 的另外四个一级分类（`privacyclean` / `traceclean` / `register` / `pluginclean`）自己实现的，其中 `plugin` 只做到「发现」——360 的插件库在服务端，本地没有任何可复用的清单。

- 文件粉碎机为什么 partial：覆盖写删除的机制做了，但本机全是 SSD，主控会把逻辑块重映射到新物理块，旧块留在原地等 GC → 达不到「物理销毁」的目标，能力自己会写这句。
- 系统盘瘦身为什么 readonly：只算不改是对的。pagefile 48.83 GB（52428800000 字节）不能删只能迁，休眠文件关掉要管理员；把「点一下省 48 GB」做成按钮会毁掉休眠和崩溃转储。

### 系统与安全（system，15 项）

| 能力 | coverage | actions | 需要管理员 | 本机实测读数 |
| --- | --- | --- | --- | --- |
| 系统体检 health | full | scan | 否 | 11 项 ok8 / warn3 / bad0，4207 ms；pagefile 48.8 GB vs 内存 31.8 GB |
| 任务管理器 proc | full | scan | 否 | 19 项；进程 208 个、CPU 总占用 30.4%、内存 36.4%；Top1 是 pwsh 8.8%（含它自己），采样窗口 1.52 s |
| 硬盘健康 diskhealth | partial | scan | 否 | 7 项 ok5 / skip2；两块 NVMe 均 Healthy；SMART 详细读数与故障预测都是 skip（原因见下） |
| 系统安全防护 security | readonly | scan | 否 | 24 项 ok13 / warn6 / info5；SMB 签名未强制、LLMNR 未设、LSA 保护未设 |
| 隐私保镖 privacy | readonly | scan | 否 | 34 项；29 项权限 / 45 条应用级条目；定位全局关闭，遥测未设 |
| 权限管理 perm | readonly | scan | 否 | 33 项；29 类权限 / 46 条应用级记录；3 条 bad（相机、录音机拿到麦克风） |
| 变形虫防护 amiba | blocked | scan | 否 | 30 项 ok7 / warn12 / info11；「已开 1 项 · 未配置 4 项」；固件级 BadUSB 明确写无解 |
| 弹窗过滤 popup | partial | scan | 否 | 17 项；5 个可见窗口；32 个通知应用里 17 个已关；专注助手状态不可读 → skip |
| 主页防护 homepage | full | scan+apply | 否 | 95 个 .lnk 中 0 个被塞网址；IE 主页 about:blank；默认浏览器 Edge |
| 文件误删恢复 recovery | blocked | scan | 否 | TRIM 已开、2 块 NVMe SSD；卷影副本未提权不可读 → 恢复概率接近零 |
| 系统急救箱 rescue | readonly | scan | 否 | 12 项 ok5 / warn3 / skip2；sfc 与 DISM 未提权时如实 skip |
| 备份还原 backup | partial | scan+apply | 否 | 还原点 0 个、VSS 停用；已导出 14 个 .reg 共 6.24 KB |
| 系统重装 reinstall | blocked | scan | 否 | 11 项；WinRE 与 BitLocker 要管理员 → skip；重装动作本身不由插件执行 |
| WINDOWS 设置 winsettings | partial | scan+apply | 否 | 38 项 ok21 / info16 / skip1；深色模式、扩展名、隐藏文件读得准 |
| 优化预设 tweaks | partial | scan+apply | **是**（写 HKLM 时） | 51 项 ok5 / warn46（46 项未应用），1175 ms |

- 系统安全防护为什么 readonly：它读的是原始注册表与 WMI 值，并对照基线指出差在哪。把「SMB 签名未强制」一键改成强制会断开老 NAS 与共享打印机，这个代价不该由插件替用户决定。
- 任务管理器为什么 full：它和 360 的「任务管理器」做的是同一件事——找出当前占用的程序。CPU 比例用两次采样之间的进程时间差算（直接读 `Get-Process` 的 CPU 属性累计值会得出「开机以来平均占用」，和用户此刻感受到的完全不是一回事），并排除 Idle 进程。Top 榜里的 pwsh 常常就是插件自己在跑的那次探针，本机实测已把它写进读数里而不是藏掉。
- 硬盘健康为什么 partial：两块 NVMe 的控制器健康状态、容量、分区表、盘符都读到了。SMART 的两条路各自失败，而且**失败原因完全不同**，所以分两条 skip 写清：`Get-StorageReliabilityCounter` 抛 `CimException`（`NativeErrorCode=AccessDenied`、HResult=0x80070005）——这是权限问题，提权后能拿到；`MSStorageDriver_FailurePredictStatus` 类定义存在但**实例数为 0**——该 WMI 只枚举 ATA/SATA，NVMe 硬件通道根本不暴露，提权也没用。所有 SMART 字段为 null，没有一处填 0 假装读到了。
- 权限管理为什么 readonly：它的价值是发现「门开着」，例如相机权限全局开着但没有任何应用用过。关掉哪个由用户决定。
- 变形虫防护为什么 blocked：名字沿用 360，实际覆盖的是 USB 设备安装限制、可移动存储策略、横向渗透面。BadUSB 伪装成键盘后固件可以重写、可以枚举成任何设备类，任何 OS 内策略都跑在它后面，所以结论里直接写「只能物理层解决」。防不住的还有一层：设备安装限制策略在本机有 4 项处于未配置。
- 弹窗过滤为什么 partial：见下面 22 项对照表第 1 行。
- 备份还原为什么 partial：注册表导出这条路做完了（写前自动 `reg export`，改坏了 `reg import` 回去）。系统还原点做不到：本机 0 个还原点、VSS 停用，且创建还原点要管理员。
- 系统重装为什么 blocked：重装要重启进另一个环境，插件没有这个生命周期。前置检查（恢复分区、BitLocker、Windows.old、机型）做全了，但 WinRE 状态与 BitLocker 状态都需要管理员才能读，本机两项都是 skip。
- 优化预设为什么 partial：51 条里只保留注册表值与服务启动类型两类改动，丢掉了上游 winutil 的 27 条任意 PowerShell 脚本（那段是不可审计的任意执行）。

### 网络（network，2 项）

| 能力 | coverage | actions | 需要管理员 | 本机实测读数 |
| --- | --- | --- | --- | --- |
| 断网诊断 netdiag | full | scan+repair+dnspick | 否（重置类要） | scan 10 步全通过：WLAN 已连接、192.168.0.105、网关 192.168.0.1、网关 ping 1043 ms、DNS 20 ms、外网 HTTP 200 / 605 ms、代理未启用、hosts 0 条，3701 ms；另有 WiFi 体检与 DNS 优选两行 |
| 宽带测速 speedtest | full | scan | 否 | 下载 1.78 Mbps、上传 2.77 Mbps、延迟 358 ms（warn），3/3 端点可用，耗时 40.2 s（预算 45 s） |

- 断网诊断 full 说的是**诊断**完整：按链路顺序（网卡 → IP → 网关 → DNS → 外网 → 代理 → hosts）给出第一个断点，另加 WiFi 体检（信号、频段、收发速率）与 DNS 优选（7 个候选逐个实测）。它有三个动词：`scan` 只读；`repair` 七项修复里 flushdns / renew-dhcp / reset-ie-proxy 免提权，reset-winsock / reset-tcpip / reset-proxy / restart-adapter 要管理员（本机实测 `executed=3 skippedNeedsAdmin=4`，flushdns 真跑过：缓存 67 条 → 4 条，exit 0，59 ms）；`dnspick` 只接受五个已实测可达的公共 DNS 或 `auto`，改前备份到 `backups\dns-<时间戳>.json` 并同时给出回滚命令。`restart-adapter` 与 `reset-tcpip` 的真执行路径没有在真机验证过——本机无法提权，只能验证到「明确 skip 并给出完整命令」这一步。
- 宽带测速的 1.78 Mbps 是这轮取样的真值，同一网络两轮能差数倍，所以结果里同时给出所用端点与回退状态。延迟 358 ms 判 warn。

### 应用与外壳（apps，6 项）

| 能力 | coverage | actions | 需要管理员 | 本机实测读数 |
| --- | --- | --- | --- | --- |
| 软件管家 software | partial | scan | 否 | 已装 114 条；目录 198 条中已装 11 / 未装 187 |
| 软件管家进阶 softmgr | partial | scan+apply | 否 | winget v1.29.380，13 个可升级；防火墙规则 542 条；dryRun 默认 true |
| 驱动清单 drivers | readonly | scan | 否 | 250 个驱动包，第三方 oem*.inf 16 个（NVIDIA、Intel×6、Micro-Star、Logitech×2） |
| 驱动更新检查 drivers2 | partial | scan | 否 | 缺驱动 0 台；168 行签名驱动记录去重后 106 个，超 730 天的第三方 10 个 |
| 右键管理 contextmenu | full | scan+apply | 否 | 78 项 ok10 / info68；12 个 shellex 挂载位置 |
| 手机助手 phone | readonly | scan | 否 | Phone Link 1.25072.81.0 已装；4 个便携设备记录全部「未连接（历史记录）」；结论「当前没有连接手机」 |

- 软件管家 partial：目录查询与官网直链给全了（198 条），安装/升级/卸载的执行**没有接线**——只给命令让用户自己跑。原因见红线二：不经用户确认的静默安装是不可回滚的写操作。
- 软件管家进阶 partial：卸载残留扫描与软件搬家可行性分析做了，真搬没做。搬一个正被引用的目录会毁掉已装程序，且符号链接方案在 Windows 上跨卷不可靠。
- 驱动更新检查 partial：Windows 本地没有厂商最新版本数据库，所以这项**不声称检测到新版本**。它只报「哪些硬件没有驱动」和「哪些驱动日期偏旧」，再给厂商官网。9 个 `DriverDate` 是 1989 年及以前的占位值，已排除在排序之外。
- 手机助手 readonly：能读的是 Phone Link 的安装状态、便携设备历史、WPD 与 MTP 驱动栈。手机侧的文件管理、投屏、备份需要手机端 App 与常驻连接，做不到。

## 22 项 360 功能覆盖度对照表

这是本文的核心。**做不到的项直接写做不到和原因**，不换算成「部分支持」凑数。

| # | 360 功能 | 对应能力 | 我们能做的 | 做不到的部分与原因 |
| --- | --- | --- | --- | --- |
| 1 | 弹窗过滤 | popup（partial） | 数出当前有几个可见窗口、哪些在屏幕外、把弹窗追到计划任务与已装软件、统计 32 个应用的通知开关 | **实时拦截做不到**。拦截要常驻进程用 `SetWinEventHook` 监听 `EVENT_OBJECT_CREATE` / `EVENT_OBJECT_SHOW`，DSH 插件是会话级、可随时卸载的，挂不了这种钩子。本机现有 5 个可见窗口、32 个通知应用里 17 个已关，能告诉用户该关谁，关的动作得自己做 |
| 2 | 权限管理 | perm（readonly） | 29 类权限 / 46 条应用级记录逐条列出，能定位「哪个应用拿到了摄像头」，也能指出「门开着但没人用」 | 不给一键关。关掉某个应用的麦克风会连带毁掉它的语音功能，取舍必须用户自己做。真要改走系统设置 |
| 3 | 主页防护 | homepage（full） | 读 IE 起始页、搜索页、组策略锁、Edge/Chrome 启动页，扫 95 个 .lnk 的目标行有没有被追加网址；发现被改可写回，默认预演 | 只覆盖 IE / Edge / Chrome。其它浏览器（360 浏览器、Firefox、Brave）的启动页机制各异，未接线。本机 95 个快捷方式里 0 个被塞网址，Chrome 未安装 |
| 4 | 变形虫防护 | amiba（blocked） | USB 设备安装限制、可移动存储策略、SMB/远程注册表/WinRM/RDP 等横向渗透面逐项读值 | **查杀做不到**。360 的变形虫是能自我变形逃避特征匹配的恶意程序，拦它要内核驱动 + 实时特征库 + 行为监控，这三样都不在只读插件的范围里。本机这个能力实际只覆盖固件层与策略层，且 4 项关键策略处于未配置 |
| 5 | 系统安全防护 | security（readonly） | UAC、Defender（实时保护/篡改防护/PUA/受控文件夹/ASR）、SMBv1 与签名、RDP、自动播放、LSA 保护、执行策略，24 项带原始注册表值 | 不改任何设置。SMB 签名未强制、LLMNR 未设这两条改下去会断老设备，代价写进结论由用户决定 |
| 6 | 手机助手 | phone（readonly） | Phone Link 安装状态、已配对与历史设备、WPD/MTP 驱动栈、USB 与便携设备服务状态 | **手机侧功能全部做不到**：文件管理、投屏、短信、手机清理都要手机端 App + 常驻连接。本机 4 个便携设备记录全是历史记录，当前没连手机 |
| 7 | 软件管家 | software + softmgr（partial） | 198 条官网直链目录（11 分类）、已装 114 条程序与目录的匹配、winget 本地可升级清单（13 个）、卸载残留证据、防火墙规则 542 条 | **不代装、不代卸、不搬家**。安装/升级只给命令；软件搬家只做可行性分析（目标盘空间、占用进程、链接点），真搬会毁掉已装程序 |
| 8 | 隐私保镖 | privacy（readonly） | 遥测、广告 ID、定位、活动历史、29 项权限与 45 条应用级条目 | 只报告不修改。本机 30 项 warn 里大部分是「权限全局开着」，逐个关会连带关掉正版软件的正常功能 |
| 9 | 主页修复 | homepage 的 apply 侧（full） | 发现主页被改时写回原值，**默认 dryRun**，写前自动 `reg export` 备份，备份失败就中止 | 只修注册表与快捷方式这两类劫持。浏览器同步下发的启动页、扩展层劫持、DNS 层劫持不在范围内 |
| 10 | 文件粉碎机 | shredder（partial） | 对显式传入的单个文件做覆盖写后删除；拒收通配符、不递归目录、拒绝系统目录与可执行扩展名、拒绝硬链接与重解析点 | **SSD 上无效**。本机 2 块盘全是 SSD 且 TRIM 已开（`DisableDeleteNotify=0`），覆盖写会被主控重映射到新物理块，旧块留在原地等 GC。结果里直接写这句，不当作能保证销毁。真正的解法是全盘加密 |
| 11 | 文件误删恢复 | recovery（blocked） | 判断能不能恢复：TRIM 开关、介质类型（SSD/HDD）、卷健康、卷影副本与还原点状态、回收站残留 | **恢复动作做不到，也不该做**。本机 2 块 NVMe SSD + TRIM 已开，删掉的文件主控会标为可回收并最终擦物理块，真实恢复概率接近零。给一个「一键恢复」按钮只会骗用户继续往盘里写数据，把最后一点机会也毁掉 |
| 12 | 断网急救箱 | netdiag（full） | 10 步链路顺序定位第一个断点：网卡 → IP → 网关 → DNS → 外网 → 代理 → hosts，另加 WiFi 体检（信号/频段/收发速率）与 DNS 优选（7 个候选逐个实测）；`repair` 七项修复（flushdns / renew-dhcp / reset-winsock / reset-tcpip / reset-proxy / reset-ie-proxy / restart-adapter），`dnspick` 切 DNS | 七项修复里三项免提权（flushdns 已真跑：缓存 67 → 4 条，exit 0，59 ms；renew-dhcp；reset-ie-proxy），四项要管理员且**在本机无法提权，只验证到「明确 skip 并给出完整命令」**。reset-winsock 与 reset-tcpip 还要重启才完全生效，所以列在「不自动重启」里。DNS 只接受五个已实测可达的公共 DNS 或 auto，改前备份并给回滚命令 |
| 13 | 宽带测速器 | speedtest（full） | 下载/上传/延迟/抖动，3 个 HTTP 端点、首个成功即通过、40 s 内给结果 | 不装任何测速组件，纯 HTTP；结果受单次取样波动影响，所以同时给端点与回退状态。本机下载 1.78 Mbps、上传 2.77 Mbps、延迟 358 ms |
| 14 | 系统盘瘦身 | slim（readonly） | 算出 pagefile / 休眠 / Windows.old / 更新缓存 / AppData 各占多少，13 项 | **不执行瘦身**。本机 pagefile 48.83 GB 不能删只能迁（迁要重启）；关休眠要管理员；WinSxS 枚举极慢（全量 88982 文件 / 11.5 GB 要 15.2 s）所以不递归，改成指向 `DISM /Online /Cleanup-Image /AnalyzeComponentStore` |
| 15 | 系统急救箱 | rescue（readonly） | 待重启标记、组件存储包数、还原点数量、24 小时系统错误、最近更新、病毒库、设备健康、启动项缺失 | **不自动修**，且核心修复工具要管理员：本机 `sfc` exit 1、`DISM` exit 740（都是权限不足），如实 skip。真跑这两条要提权，且 DISM 会长时间占用系统 |
| 16 | C 盘扩容 | expandc（blocked） | 完整磁盘几何：分区起止字节、紧邻对象、未分配空间、恢复分区位置、代价分析 | **本机扩不了**。C 结束于 324420992512，紧跟着就是 608 MB 恢复分区（起始 324421025792），中间只有 32.5 KB 对齐空隙。磁盘管理只能吃尾部紧邻的未分配空间，做不到隔一个分区扩容；删恢复分区会让 WinRE 失效。两块盘最大连续未分配都只有 1.0 MB |
| 17 | 查找大文件 / 重复文件 | bigfiles + dupfiles（full） | 大文件：按阈值递归扫（本机 197703 文件 / 44.9 GB，命中 49 个）；重复文件：三级漏斗（大小分组 → 前 64 KiB → 全量 SHA256，本机 22 组 / 63.6 MB） | **只报告不删除**。删文件不可回滚，删之前该由人看一眼路径 |
| 18 | 系统重装 | reinstall（blocked） | 重装前检查：恢复分区、BitLocker、Windows.old、机型、账户、存储控制器、网卡、电源计划 | **重装动作做不到**。它要重启进 WinPE 写盘，插件没有这个生命周期。且本机 WinRE 与 BitLocker 状态都要管理员才能读，两项都是 skip |
| 19 | 备份还原 | backup（partial） | 注册表键导出到 `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup`（本机已存 16 个 .reg），改坏了 `reg import` 回去；默认预演 | **系统级备份还原做不到**。本机还原点 0 个、VSS/SDRSVC/swprv 全 Stopped，创建还原点要管理员；系统镜像备份（wbadmin）同样要提权且要独立卷。能保的只有「我改过的这几个键」 |
| 20 | 驱动安装 | drivers + drivers2（readonly / partial） | 250 个驱动包与第三方 oem*.inf 16 个的清单、缺驱动的硬件（本机 0 台）、偏旧驱动（超 730 天的第三方 10 个）、厂商官网入口 | **不自动下载、不自动安装**。Windows 本地没有厂商最新版本数据库，无法判断「有没有新版本」；安装要 `pnputil /add-driver`（管理员）或设备管理器，两者都不该由只读插件代劳 |
| 21 | 右键管理 | contextmenu（full） | 枚举 12 个 shellex 挂载位置、78 项当前状态、按项启用/屏蔽，HKCU 免提权可写 | 屏蔽机制依赖 `Shell Extensions\Approved` 的空串（值存在且为空 = 阻止，删值不等于禁用）。HKLM 层的项要管理员 |
| 22 | WINDOWS 设置 | winsettings（partial） | 38 项常用设置读当前值并支持 HKCU 项写回：深色模式、显示扩展名、显示隐藏文件、任务栏、24 小时制等 | HKLM 项不写（要管理员）；Win11 专有项在 Win10 上如实报「未设置 = 系统默认」；DWORD 传字符串会「写了但不生效」，所以这类请求直接拒绝 |

### 一句话汇总

- **做全了（full）**：垃圾清理、大文件、重复文件、断网诊断、宽带测速、系统体检、任务管理器、主页防护、右键管理。
- **只做一部分（partial）**：弹窗过滤、备份还原、软件管家、软件管家进阶、驱动更新检查、硬盘健康、WINDOWS 设置、优化预设、文件粉碎机。
- **只检测不给修（readonly）**：系统安全防护、隐私保镖、权限管理、系统盘瘦身、系统急救箱、驱动清单、手机助手。
- **本机条件不允许（blocked）**：变形虫防护、C 盘扩容、文件误删恢复、系统重装。
- **彻底做不到、只在文档里承认的**：弹窗实时拦截、变形虫查杀、手机侧全部功能、文件误删恢复、C 盘扩容、重装执行、sfc/DISM 修复（要管理员）、软件搬家执行、驱动自动下载安装、系统级备份还原。网络重置与 DNS 切换**是接了线的**，但其中三个要管理员的动作（重置 winsock / 重置 TCP-IP / 重启网卡）在本机无法提权，只验证到「明确 skip 并给出完整命令」。

## 三条设计红线

### 红线一：只读优先

25 项里 16 项是纯 `scan`，读注册表、WMI、事件日志、文件系统，不改任何状态。9 项带写动作的，写之前都要过下面两条。

只读不是「保守」，是这几个能力的结论本身就够用：`netdiag` 告诉用户断在哪一环，`security` 告诉用户哪条基线没达，用户有自己的处置方式。反过来做自动修复，一旦修错就没有回退路径。

### 红线二：写操作默认 dryRun，写前必备份

- 所有 apply 入口默认 `dryRun = true`。`softmgr` 的探针输出里直接带 `dryRun: true`。
- 面板是**两步确认**：宿主先跑一遍预演，把「会改哪个键、从什么改成什么」摊给用户看，用户确认后才以 `dryRun=false` 执行。`client.js` 里 `deriveApplyParams` 负责从行数据反推出 apply 参数。
- 真写之前先 `reg export` 到 `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup`，**备份失败就中止整个动作**。本机已存 16 个 .reg。
- `contextmenu` 用 `Shell Extensions\Approved` 的空串机制屏蔽，不删值——删值等于「未声明」，加载行为由 shell 自己决定，不可预测。

### 红线三：绝不编造，测不到就 skip

- 未提权时 `sfc` / `DISM` / 卷影副本 / WinRE / BitLocker 一律输出 `status: "skip"` 并写明原因，**不折算成 ok**。本机 `rescue` 两项 skip、`reinstall` 两项 skip、`recovery` 一项 skip、`slim` 一项 skip、`backup` 一项 skip、`winsettings` 一项 skip。
- 读不到的项标 info 并直接说读不到。`popup` 的专注助手状态存在 CloudStore blob 里（116 字节未公开格式），探针写的是「不解析未公开格式，也不猜」，不是猜一个值。
- `drivers2` 明确写「本地无新版数据库」，所以不会声称检测到新版本。
- `Runner.run()` 永不抛错：探针崩了就把错误写进那一个 slot，其它能力照常出结果。一个能力失败不该拖垮整个面板。

## 软件目录政策：只给官网直链

`lib/presets/softwares.json` 现在是 **198 条 / 11 分类**，全部是厂商自己的域名。

| 分类 | 条数 | 分类 | 条数 |
| --- | --- | --- | --- |
| 聊天通讯 im | 11 | 办公文档 office | 18 |
| 浏览器 browser | 13 | 输入法 input | 10 |
| 影音播放 media | 30 | 图形图像 graphics | 12 |
| 开发工具 dev | 25 | 实用工具 utility | 25 |
| 系统工具 system | 21 | 安全防护 security | 13 |
| 网络工具 network | 20 | | |

顶层字段：`version: 1`、`captured: "2026-11-17"`、`policy: "official-only"`、`policyNote`、`note`、`categories`、`softwares`。

### 强制执行器

`tools/verify-catalog.mjs` 不是建议，是闸门。它对每条的两处 URL（`homepage` / `downloadPage`）逐项检查：

1. 必须是 `https:` 且能被 `new URL()` 解析。
2. host 不得命中 `FORBIDDEN_HOSTS`：softonic.com、filehippo.com、cnet.com、download.com、softpedia.com 等下载站。
3. host 不得命中 `FORBIDDEN_EXACT_HOSTS` 短链表：is.gd、buff.ly、rb.gy、cutt.ly、shorturl.at 等。**必须整 host 相等匹配**——早期用子串匹配是真 bug：`https://www.capcut.cn/` 因为含 `t.cn` 被误判成短链；反过来 `evil-t.cn` 也必须被拦。
4. 不得是裸 IP（`/^\d+\.\d+\.\d+\.\d+$/`）。
5. 路径不得含 `/s?`、`/link?`、`/redirect`、`mydown`、`/softdown`、`/download.php?id=` 这类跳转片段。
6. `github.com/<org>` 不算违规，但只给 WARN，要求人工确认发布者就是上游作者（本机 14 条 WARN 全在这一类）。

`--offline` 只跑形态与政策；不带参数时额外做可达性探测。

### 198 条是怎么来的

`lib/presets/` 下有一个 base 和三个分片：`softwares.json`（base）+ `softwares-A.json`(35 行) + `softwares-B.json`(44 行) + `softwares-C.json`(48 行)。`node tools/merge-catalog.mjs --dry-run` 的本轮实测：

```
base entries      : 198
shard A           : 35 rows, 35 accepted
shard B           : 44 rows, 44 accepted
shard C           : 48 rows, 48 accepted
added             : 0
replaced (by id)  : 127
total             : 198
categories        : 11
VERDICT: PASS
```

也就是说三个分片是**按 id 覆盖** base 里已存在的 127 条，不是往空目录里追加（`added 0`）。这符合当前工作方式：分片是「本轮修订过的条目」，merge 把它们盖回 base，`total` 不变。

### 怎么加一条新条目

1. 写进 `softwares-A.json` / `B` / `C` 里任意一个分片，字段与 base 条目一致（`id`、两侧 URL 等）。分片只是「待合并的修订集」，放哪个都不影响结果。
2. `node tools/merge-catalog.mjs`（先 `--dry-run` 看 `accepted` 与 `replaced` 数，确认后再去掉 `--dry-run` 真正写回 `softwares.json`）。
3. `node tools/verify-catalog.mjs --offline` 必须 PASS 且 WARN 里没有新增的非 github 项。
4. 需要联网确认可达性时，去掉 `--offline` 再跑一次。

只收录能确认是官方域名的条目——宁可少一条，也不给一个会跳去下载站的链接。

### 驱动与优化预设

- `lib/presets/drivers.json`：20 个厂商 + 10 个 USB 厂商 + 15 个类别，`captured: "2026-11-17"`。厂商键用 PCI vendor id（1002 / 1022 / 1028 …），由 `tools/verify-drivers.mjs` 校验（`--offline` 只查形态，本机 PASS）。
- `lib/presets/tweaks.json`：51 条，源 ChrisTitusTech/winutil，MIT，`captured: "2026-11-17"`。只保留注册表值与服务启动类型两类改动，上游那 27 条任意 PowerShell 脚本全部丢弃。

## 目录结构

```
dsh-windows-toolbox/   （两半共一个目录，本文件只描述工具箱那一半）
├─ index.js              宿主端入口：分别挂载 mountManage / mountToolbox，一半挂了另一半照常
├─ lib/host-toolbox.js   工具箱半的宿主端：6 条路由 + 5 个工具（API 前缀 /dsh-windows-toolbox/api/toolbox）
├─ lib/host-manage.js    插件化管理半的宿主端（本文件不述，见 ../manage/DETAIL.zh.md）
├─ client.js             合并面板（由 tools/merge-client.mjs 生成，勿手改）：顶部两个页签切换两半
├─ package.json          link 安装入口，dsh.client.immediately = true
├─ cordis.patch.yml      insert 声明
├─ icon.svg              面板图标（左半窗口栅格 = 管理器，右半工具箱）
├─ README.md             速览
├─ docs/
│  ├─ DETAIL.zh.md       合并插件总述（两半共用部分）
│  ├─ DETAIL.md          英文版
│  ├─ manage/            插件化管理半的文档（DETAIL / SCOPE / REPAIR，各双语）
│  └─ toolbox/           本文与英文版
├─ lib/
│  ├─ capabilities.js    25 个能力的唯一事实来源（CAPABILITIES / CAPABILITY_GROUPS / COVERAGE / RISK / JUNK_GROUPS / SCAN_ROOTS）
│  ├─ runner.js          缓存与并发：TTL 5 分钟，run() 永不抛错，参数白名单
│  ├─ ps.js              探针调用层：-ParamFile 传参，UTF-8 解析，120 s 默认超时
│  ├─ probes/            44 个 .ps1 = 25 个能力探针 + 12 个注册点探针 + featurelib/junklib/rootlib + actions/elevated/host/broker，另有 CONTRACT.md
│  └─ presets/           softwares.json（198）+ softwares-A|B|C.json + drivers.json + tweaks.json
├─ locale/               zh.json / en.json（只有面板标题与描述，术语表内置在 client.js）
├─ tests/
│  ├─ run-all.mjs        聚合器：顺序跑两半，任一失败即 exit 1
│  ├─ run-all-toolbox.mjs 本半的单元 + 实跑，38 项
│  └─ render.mjs         无头 React 挂载 client.js，两半各断言
└─ tools/
   ├─ verify-catalog.mjs  "只给官网"强制执行器
   ├─ verify-drivers.mjs  驱动预设校验
   ├─ merge-catalog.mjs   分片合并回 base
   ├─ merge-client.mjs    两半 client.js → 合并面板（带一致性硬校验）
   ├─ merge-render-fixtures.mjs  从旧 harness 机械提取真实 fixture
   ├─ smoke-merged.mjs    合并结构验收：13 路由 / 12 工具 / 0 残留旧前缀
   ├─ audit-probes.mjs    探针客观验收器（语法、禁用 API、UTF-8 头、param 位置）
   └─ probe-shapes.mjs    探针输入/输出形态快照
```

宿主 6 条路由（前缀 `/dsh-windows-toolbox/api/toolbox`）：`GET /status`、`GET /result?id=`、`POST /run`、`POST /apply`、`POST /elevated`、`POST /clean`。
工具 5 个：`tb360_status`、`tb360_scan`、`tb360_apply`、`tb360_clean`、`tb360_elevated`。

## 踩过的坑

每一条都是真机上复现过、并且已经修掉的。症状 → 根因 → 修法。

1. **调用方拿到裸数组，`.Count` 变 4 个元素分别计数**
   症状：函数返回 4 项，调用方 `$r.Count` 得到 4 个 1，而不是 1 个 4。
   根因：PowerShell 函数 `return $list` 会把 `List[object]` 枚举展开，管道吐成 4 个对象。
   修法：`return , $list`，用逗号包一层防止展开。

2. **参数静默不绑定，`$DryRun` 永远是默认值**
   症状：传了 `-DryRun $false`，探针仍按 true 走，没有任何报错。
   根因：`param()` 必须是脚本第一条语句。把 `[Console]::OutputEncoding = ...` 那行放在 `param()` 前面，`param` 就被当成命令名，参数块整段失效。
   修法：`param()` 永远放第一行，UTF-8 设置行放到它后面。

3. **Node 收到乱码，JSON.parse 在第一个中文处炸**
   症状：探针输出里中文变成 `���`，`parseJson` 抛 SyntaxError。
   根因：PowerShell 默认按控制台代码页（936）输出，Node 按 UTF-8 解码。
   修法：每个 .ps1 都设 `[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false`（`$false` = 不写 BOM，BOM 同样会让 JSON.parse 失败）。

4. **`Sort-Object -Property bytes` 安静地什么都没排**
   症状：大文件表顺序随机，不报错。
   根因：行是 `OrderedDictionary`，`-Property <键名>` 对字典行是静默空操作。
   修法：用 scriptblock `Sort-Object { [int64]$_.bytes } -Descending`。

5. **`Measure-Object -Property bytes -Sum` 返回空**
   症状：总和是空值，写进 JSON 变 `null`。
   根因：同上，字典行不吃属性名。
   修法：`foreach` 累加，或 `($rows | Measure-Object { [int64]$_.bytes } -Sum)`。

6. **探针跑 387 ms 就为一个不存在的注册表键**
   症状：一个只查「有没有配过」的项拖慢整轮扫描。
   根因：对不存在的键 `Test-Path` 要 387 ms/次（每次都走完整路径解析 + 权限检查）。
   修法：用 `Get-RegValue` 直接读值（约 10 ms）——读不到就是没配。注意文件系统的 `Test-Path` 只要 1.6 ms，那一侧可以照用。

7. **硬编码 `$env:USERPROFILE\Documents` 得到假零**
   症状：文档目录报 0 个文件，实际里面有几十 GB。
   根因：已知文件夹会被重定向。本机 Documents → E:、Downloads → E:、Desktop → D:、Pictures → D:，用户目录下那几个壳目录是空的。
   修法：读注册表 `User Shell Folders` 拿真实路径，再回落到默认值。

8. **`Get-WinEvent` 在没有匹配事件时抛异常**
   症状：系统错误统计把「0 条事件」报成读取失败。
   根因：无匹配时它抛 `NoMatchingEventsFoundException`，不返回空集合。
   修法：捕获该异常当作 0 条，只有其它异常才算失败。

9. **单点 HTTP 探测把人骗了**
   症状：同一端点一次 527 ms 通过、一次 6 s 超时，结论在两轮之间翻转。
   根因：单点探测落在一个慢端点或一次瞬时拥塞上。
   修法：多端点并按顺序回退，**首个成功即通过**，同时把「用了哪个端点、回退了几次」写进结果。

10. **把没插网线的网卡判成「拿不到 IP」**
    症状：网卡明明正常，报告说本机 IP 异常。
    根因：已断开的网卡会带一个 `169.254.x.x`（APIPA）地址，被当成有效 IP 参与判定。本机蓝牙网卡就是 `169.254.127.184`。
    修法：判定前先按 `Status` 过滤，只对 `Up` 的网卡做 APIPA 检查。

11. **「最紧张的磁盘」指向了还剩 937 GB 的那块**
    症状：健康检查把 E: 报成最紧张的盘，实际它剩 937.1 GB。
    根因：按 used% 挑。E: 是 1907.7 GB 大盘，50.9% 已用听起来高，但剩下的绝对空间远超 C: 的 165.2 GB。
    修法：按磁盘自身容量分级判定，同时给出绝对剩余量，不单看百分比。

12. **`New-Item -Force` 把已存在的注册表键清空**
    症状：写一个值，结果该键下原有的子键和值全没了。
    根因：`New-Item -Force` 对已存在的键是重建语义。
    修法：先 `Get-Item`（或 `Test-Path`）判断存在，不存在才建。

13. **给 `$HOME` / `$pid` / `$args` 赋值，静默失败**
    症状：脚本里明明赋了值，后面读到的是原值或空。
    根因：这三个是只读自动变量，在 `-ErrorAction SilentlyContinue` 下赋值失败但不报错。
    修法：换名字（`$profileHome`、`$procId`、`$scriptArgs`），并在写探针时把这条列进禁用名单（`audit-probes.mjs` 会查）。

14. **`@($list)` 在 PS7.6 上抛 `Argument types do not match`**
    症状：把 `New-Object List[object]` 包成数组时抛类型错误。
    根因：PS7.6 对 `New-Object` 出来的泛型 List 做数组转换会踩到类型绑定问题。
    修法：改用 `[System.Collections.Generic.List[object]]::new()`。

15. **`reg.exe` 成功时把中文提示打进 stdout，污染 JSON**
    症状：JSON 前面多了一行「操作成功完成。」，解析失败。
    根因：`reg.exe` 成功时往 stdout 输出本地化提示。
    修法：`reg ... > $tmpFile 2>&1`，从临时文件读结果，或整体重定向到 `$null` 并只用退出码判断。

16. **`[Parser]` 是无效类型名，静默返回 `$null`**
    症状：语法检查全部通过，连写坏的脚本也通过。
    根因：`[Parser]` 不是可用类型别名，PowerShell 把它当字符串/`$null` 处理，`ParseFile` 调用没有发生。
    修法：写全名 `[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)`。

17. **禁用 API 检查把 `-Fix` 里的建议文案当成真实调用**
    症状：一条只出现在提示文字里的 `Set-Service` 被判成违规调用。
    根因：直接在原始文本上跑正则，注释和字符串里的内容也参与匹配。
    修法：先剥注释和字符串（解析成 token 流再比对），只检查真正的命令 token。

## 权限边界：未提权能做什么

本机全程未提权，下面是逐条实测结论。

| 操作 | 未提权 | 说明 |
| --- | --- | --- |
| 读 HKLM / HKCR | 可以 | 只读枚举正常 |
| 读 HKCU、写 HKCU | **可以** | 所以 `contextmenu`、`winsettings` 的 HKCU 项、`tweaks` 的 HKCU 项都能真写 |
| 写 HKLM | 不行 | 需要管理员。`tweaks` 因此标 `needsAdmin` |
| `reg export` / `reg import` | 可以 | 备份机制不依赖提权，本机 14 个 .reg 都是未提权导出的 |
| `Get-Service` / 读服务状态 | 可以 | |
| `Set-Service` / 改服务启动类型 | 不行 | 需要管理员 |
| `Disable-ScheduledTask` | 不行 | 需要管理员；计划任务只能读（本机读到 360ZipUpd×2 已 Disabled） |
| `pnputil /add-driver`、删驱动包 | 不行 | 需要管理员 |
| `sfc /scannow` | 不行 | 本机 exit 1，探针如实 skip |
| `DISM /Online /Cleanup-Image` | 不行 | 本机 exit 740，探针如实 skip |
| 卷影副本 / 创建还原点 | 不行 | 本机读卷影副本被拒，`recovery` 该项 skip |
| 读 WinRE 状态、读 BitLocker | 不行 | `reinstall` 两项 skip |
| `Get-CimInstance`（磁盘、内存、事件） | 可以 | 大部分只读读数靠它 |
| 枚举已装程序（注册表 Uninstall） | 可以 | 本机 114 条 |
| 读 `Get-AppxPackage` | 需要桥接 | PS7 下直接调用会静默返回空，必须走 5.1 桥接并验证条数大于零 |

## 测试与验证

```powershell
# 全套：单元 + 实跑探针
node tests/run-all.mjs

# 只跑单元（快，不落盘）
node tests/run-all.mjs --unit-only

# 渲染面板并校验文案、fetch 调用
node tests/render.mjs

# 探针客观验收：语法、禁用 API、UTF-8 头、param 位置（--no-run 不真跑探针）
node tools/audit-probes.mjs
node tools/audit-probes.mjs --no-run

# 目录与预设校验（--offline 不联网）
node tools/verify-catalog.mjs --offline
node tools/verify-drivers.mjs --offline
node tools/merge-catalog.mjs --dry-run
```

本轮实测读数：

| 命令 | 结果 |
| --- | --- |
| `node tests/run-all-toolbox.mjs` | **PASS 38/38**（含 live：junk 9 组 31 目标 / 17200 文件、bigfiles、dupfiles、netdiag、health、缓存组、render 双语） |
| `node tests/run-all.mjs --unit-only` | **PASS 22/22**（本半），含「面板与探针对垃圾目标数一致」；聚合器实测 toolbox 22 + manage 24 |
| `node tests/render.mjs`（`WINDOWS_TOOLBOX_PANEL=toolbox`） | 合并侧栏 order 7、label「WINDOWS工具箱」、`aria-selected` 页签切到「工具箱」、字典键定义 246 / 使用 59，文本节点 84，字符 995，DNS 表单真的被点开（`formChars 1449`） |
| `node tools/audit-probes.mjs` | **44/44 probes clean，VERDICT PASS** |
| `node tools/verify-catalog.mjs --offline` | **198 entries / 11 categories，WARN 14（全是 github.com 待人工确认），VERDICT PASS** |
| `node tools/verify-drivers.mjs --offline` | **20 vendors / 10 usb vendors / 15 classes，VERDICT PASS** |

三次 junk 取样都不完全一致（探针单独跑 12801 文件 / 2082011223 字节，测试套件里 12783 文件 / 2080592913 字节，文档复核时 12831 文件 / 2082971509 字节），属于缓存目录本身在变，不是读取错误。表里写的是复核那一次。

## 安装

```powershell
# 已在 desktop profile 里，link 安装（改代码即时生效）
# D:\Program Files (x86)\DSH_Data\profiles\desktop\package.json 里的写法：
#   "dsh-windows-toolbox": "link:E:/DSHWORK/DSH插件/dsh-windows-toolbox"
```

从插件市场安装时，让它落成 link 形态而不是拷贝：

```
plugin_manager action:install_bundle target:"link:E:/DSHWORK/DSH插件/dsh-windows-toolbox"
```

**宿主端不热重载。** 只改 `client.js` 这类客户端代码，面板刷新即可；改 `index.js` 或 `lib/` 下的宿主侧代码，必须让宿主重新加载插件：

```powershell
$body = '{"name":"dsh-windows-toolbox","enabled":false}'
Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:51923/dsh-market/toggle' `
  -ContentType 'application/json' -Body $body `
  -Headers @{ origin = 'http://127.0.0.1:51923'; referer = 'http://127.0.0.1:51923/' }

$body = '{"name":"dsh-windows-toolbox","enabled":true}'
Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:51923/dsh-market/toggle' `
  -ContentType 'application/json' -Body $body `
  -Headers @{ origin = 'http://127.0.0.1:51923'; referer = 'http://127.0.0.1:51923/' }
```

`origin` 与 `referer` 两个头不能少，缺了会被同源策略挡掉。该路由只接受 POST，`GET` 返回 405。

改完验证：`GET http://127.0.0.1:51923/dsh-windows-toolbox/api/toolbox/status` 能返回 25 个能力的 status 才算宿主重新加载成功。

## 已知限制

逐条写实话，这些不是待办，是设计上做不到或不该做的事。

1. **弹窗实时拦截做不到。** 要常驻进程用 `SetWinEventHook` 监听窗口创建事件，DSH 插件是会话级、可随时卸载的，挂不了这种钩子。`popup` 只公布来源。
2. **变形虫查杀做不到。** 没有内核驱动、没有实时特征库、没有行为监控。这个能力覆盖的是 USB 设备安装限制与横向渗透面。
3. **BadUSB 在固件层无解。** 伪装成键盘的设备固件可以重写、可以枚举成任何设备类，任何 OS 内策略都跑在它后面。只能物理层解决。
4. **SSD + TRIM 上文件粉碎无效。** 本机 2 块 NVMe SSD、TRIM 已开，覆盖写会被主控重映射，旧物理块留在原地等 GC。真正的解法是全盘加密。
5. **文件误删恢复的概率接近零。** 同上，SSD 上删除即标记可回收。这里只给判断依据，不提供恢复按钮——给按钮会骗用户继续往盘里写数据。
6. **C 盘扩容被恢复分区挡住。** C 结束于 324420992512，恢复分区起始于 324421025792，中间只有 32.5 KB；两块盘最大连续未分配 1.0 MB。删恢复分区会让 WinRE 失效。
7. **DISM 与 sfc 要提权。** 本机 exit 740 / exit 1，探针如实 skip。这两条也不该由插件在后台跑：DISM 会长时间占用系统。
8. **软件搬家和驱动自动下载未接线。** 搬家只做可行性分析（搬正被引用的目录会毁掉已装程序）；驱动只给清单与厂商官网，因为 Windows 本地没有厂商最新版本数据库。
9. **系统级备份还原做不到。** 本机还原点 0 个、VSS 停用。能保的是「我改过的那几个注册表键」。
10. **系统重装只能做前置检查。** 重装要重启进另一个环境，插件没有这个生命周期。
11. **软件安装/升级只给命令。** 静默安装是不可回滚的写操作，必须由用户执行。
12. **部分读数依赖管理员，未提权时是 skip。** 本轮 skip 项：`rescue` 的 sfc/DISM、`recovery` 的卷影副本、`reinstall` 的 WinRE/BitLocker、`slim` 的系统还原、`backup` 的导出（未请求）、`winsettings` 的 1 项、`popup` 的专注助手状态（未公开格式，不解析）。
13. **测速结果受单次取样影响。** 同一网络两轮能差数倍，所以同时给出端点与回退状态。本机下载 1.78 Mbps、上传 2.77 Mbps、延迟 358 ms。
14. **`Get-AppxPackage` 在 PS7 下静默返回空。** 已装应用枚举必须走 5.1 桥接并验证条数大于零，否则看起来像「一个应用都没装」。
15. **面板视觉需人工确认。** `tests/render.mjs` 能验服务端渲染出的文案与 fetch 调用，验不了像素。深色模式、窄屏折行、长文件路径截断（`truncateMid`）都要人眼看一遍。
