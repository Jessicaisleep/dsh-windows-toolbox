/**
 * lib/capabilities.js — the fixed catalogue of things this toolbox can do.
 *
 * Every capability is one of five verbs over a Windows subsystem, described with
 * the same five hooks the sibling plugin uses for registry points:
 *
 *   detect   — read current state (always available, read-only)
 *   plan     — what a change would do, with numbers, before anything happens
 *   apply    — perform it
 *   verify   — re-read and confirm it happened
 *   rollback — put it back
 *
 * ## Two probe families
 *
 * The original five (junk / bigfiles / dupfiles / netdiag / health) each return
 * their own hand-shaped payload, because each needed a bespoke view: a target
 * table with checkboxes, a largest-files list, expandable hash groups, a link
 * walk, a four-column check list.
 *
 * Everything added after those follows lib/probes/featurelib.ps1 and returns the
 * same envelope: `{ ok, count, items[], summary, ...extra }` where each item is
 * `{ id, group, label, status, value, detail, fix, needsAdmin }`. That is why a
 * single `view: 'checks'` renderer draws all of them — the consistency is the
 * point, not an accident.
 *
 * ## Honesty rules baked into this table
 *
 * `coverage` records what the 360 utility actually does and what this plugin
 * does instead. Three capabilities are permanently `partial` and say so in the
 * UI rather than pretending:
 *
 *   popup    360 blocks popups with a resident hook; a DSH plugin is session
 *            scoped and unloadable, so this only FINDS the sources.
 * Four capabilities were removed outright rather than shipped as stubs —
 * reinstall, expandc, recovery and amiba — because none of them can be done
 * honestly from inside Windows. Do not reintroduce them as "blocked" rows:
 * a card that exists but never works is worse than no card.
 *
 * RISK vocabulary is deliberately the same as the plugin-manager's:
 *   readonly    — reads only, cannot change the machine
 *   reversible  — changes something that can be put back automatically
 *   destructive — removes data that cannot be recovered by this tool
 */

export const RISK = {
  readonly: 'readonly',
  reversible: 'reversible',
  destructive: 'destructive',
};

/**
 * Junk categories, mirrored from junklib.ps1. The ids are the contract between
 * the two layers; the panel groups by them and the probe validates against them.
 * `needsAdmin` here is for display only — the probe is the authority, because
 * only it can see whether the current process is actually elevated.
 */
export const JUNK_GROUPS = [
  {
    id: 'temp',
    label: '临时文件',
    labelEn: 'Temporary files',
    targets: ['user-temp', 'windows-temp', 'crash-dumps', 'wer-report'],
    note: '程序运行中产生的临时副本，删除后不影响已安装的软件',
  },
  {
    id: 'browser',
    label: '浏览器缓存',
    labelEn: 'Browser caches',
    targets: ['edge-cache', 'edge-code-cache', 'chrome-cache', 'chrome-code-cache', 'inet-cache'],
    note: '网页缓存与编译缓存，清理后首次打开网站会略慢；不会退出登录',
  },
  {
    id: 'system',
    label: '系统缓存',
    labelEn: 'System caches',
    targets: ['thumb-cache', 'icon-cache', 'prefetch', 'dns-cache'],
    note: '缩略图/图标缓存与预读取文件，清后会自动重建；正在被占用时会被跳过',
  },
  {
    id: 'update',
    label: '更新与传递优化',
    labelEn: 'Update caches',
    targets: ['wu-download', 'delivery-opt'],
    note: '已安装更新的下载副本，删除不影响系统版本；需要管理员权限',
  },
  {
    id: 'recycle',
    label: '回收站',
    labelEn: 'Recycle bin',
    targets: ['recycle-bin'],
    note: '清空后无法通过回收站恢复，确认再执行',
  },
  {
    id: 'privacy',
    label: 'Cookie 与登录痕迹',
    labelEn: 'Cookies',
    targets: ['edge-cookies', 'chrome-cookies', 'inet-cookies'],
    note: '清理后相关网站需要重新登录；浏览器正在运行时文件被独占，会如实跳过而不是假装清掉了',
  },
  {
    id: 'traces',
    label: '使用痕迹',
    labelEn: 'Usage traces',
    targets: ['recent-lnk', 'recent-auto', 'recent-custom', 'ps-history'],
    note: '最近打开的文件、任务栏跳转列表、命令行历史；清完不会影响已安装的软件',
  },
  {
    id: 'registry',
    label: '注册表残留',
    labelEn: 'Registry leftovers',
    targets: ['typed-paths', 'run-mru', 'uninstall-shells', 'binary-mru', 'mui-cache', 'app-paths', 'firewall-rules'],
    note: '只处理「指向的路径已经不存在」的项：失效的 MuiCache 显示名、App Paths 里指向已删程序的入口、以及防火墙规则里的死引用。每条删除前备份到 regbackup 可单独回滚；空壳卸载项、二进制 MRU 与防火墙规则只检测不删。默认值为空的 App Paths 子键会被跳过（它们通常还带着 UseURL/Path 等有效配置，删整键会误伤）',
  },
  {
    id: 'plugins',
    label: '浏览器扩展',
    labelEn: 'Browser extensions',
    targets: ['browser-extensions'],
    note: '只读发现，列出已装扩展的数量与来源；卸载有风险，请在浏览器的扩展页自己操作',
  },
];

/** Flattened id list, for validation. */
export const JUNK_IDS = new Set(JUNK_GROUPS.flatMap((g) => g.targets));

/**
 * Coverage vocabulary for the 22 features the user asked for by name.
 *   full     — this plugin does the whole job
 *   partial  — it does the honest half, and the UI says which half is missing
 *   readonly — it reports and advises, never changes anything
 *   blocked  — it is not possible from inside a plugin at all; the entry exists
 *              so the user sees WHY instead of wondering where the button went
 */
export const COVERAGE = {
  full: 'full',
  partial: 'partial',
  readonly: 'readonly',
  blocked: 'blocked',
};

/**
 * The capability table. `probe` names the PowerShell script under lib/probes/.
 * `view` tells the client which renderer to use:
 *
 *   junk    — target table with per-target checkboxes and a clean button
 *   files   — flat list of paths + byte counts
 *   groups  — expandable groups (duplicates)
 *   steps   — ordered link walk with a verdict bar
 *   checks  — the generic status list: label / status / value / detail / fix
 */
export const CAPABILITIES = [
  /* ------------------------------------------------------- the original five */
  {
    id: 'junk',
    probe: 'junk.ps1',
    view: 'junk',
    risk: RISK.destructive,
    label: '垃圾清理',
    labelEn: 'Junk cleanup',
    tagline: '扫描可安全删除的临时文件、缓存与回收站',
    detail: '只清理固定白名单内的目录内容，目录本身一定保留；需要管理员权限的目标在未提权时会明确跳过，不会假装清理成功。',
    actions: ['scan', 'clean'],
    defaultParams: {},
    group: 'cleanup',
    coverage: COVERAGE.full,
    needsAdmin: false,
  },
  {
    id: 'bigfiles',
    probe: 'bigfiles.ps1',
    view: 'files',
    risk: RISK.readonly,
    label: '大文件查找',
    labelEn: 'Large files',
    tagline: '找出占用空间最多的单个文件',
    detail: '按大小阈值递归扫描选定的根目录，只读不删。根目录只能按预设 id 选择，不接受任意路径，避免扫到共享或别人的目录。',
    actions: ['scan'],
    defaultParams: { root: 'user', minMb: 100, limit: 200 },
    group: 'cleanup',
    coverage: COVERAGE.full,
    needsAdmin: false,
  },
  {
    id: 'dupfiles',
    probe: 'dupfiles.ps1',
    view: 'groups',
    risk: RISK.readonly,
    label: '重复文件',
    labelEn: 'Duplicate files',
    tagline: '按内容哈希找出真正重复的文件',
    detail: '三级漏斗：先按大小分组，再比对前 64 KiB，最后对幸存者算全量 SHA256。只有全量哈希相同才算重复，不会把同名文件误报成重复。',
    actions: ['scan'],
    defaultParams: { root: 'user', minKb: 1024, limit: 100 },
    group: 'cleanup',
    coverage: COVERAGE.full,
    needsAdmin: false,
  },
  {
    id: 'netdiag',
    probe: 'netdiag.ps1',
    view: 'steps',
    risk: RISK.reversible,
    label: '断网急救箱',
    labelEn: 'Network repair',
    tagline: '上不了网？先找断在哪一环，再一键修',
    detail:
      '先按链路顺序检查网卡、IP、网关、DNS、外网、代理、hosts，报出第一个失败的环节——那是真正的故障点，后面的失败都是它的结果。另外两项体检：Wi-Fi 信号强度与实际收发速率、以及把五个公共 DNS 和当前设置的 DNS 逐个实测一遍给出排名。修的时候给 7 个动作：清 DNS 缓存、重续 IP、重置 Winsock、重置 TCP/IP、重置 WinHTTP 代理、清 IE 代理、重启网卡。免提权的三项能直接跑；需要管理员的三项会给出完整命令并提示用「以管理员身份重试」；重置类要重启才完全生效，界面上会明说。DNS 只接受五个公开候选或「自动获取」，改之前先把旧值备份到磁盘并给出回滚命令。',
    actions: ['scan', 'repair', 'dnspick'],
    defaultParams: { action: 'scan' },
    group: 'network',
    coverage: COVERAGE.full,
    needsAdmin: false,
  },
  {
    id: 'health',
    probe: 'health.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '系统体检',
    labelEn: 'Health check',
    tagline: '磁盘、内存、服务、设备、防护一次过一遍',
    detail: '每项都给出实测值、判定阈值和修复方向，不给没有依据的分数。只读，不自动修复任何问题。',
    actions: ['scan'],
    defaultParams: {},
    group: 'system',
    coverage: COVERAGE.full,
    needsAdmin: false,
  },
  {
    id: 'proc',
    probe: 'proc.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '任务管理器',
    labelEn: 'Task manager',
    tagline: '谁在偷吃 CPU、内存和磁盘',
    detail:
      'CPU 占用是两次采样求差算出来的（不是读 Get-Process 那个累计值），已排除 Idle 与 System。给出 CPU / 内存 / 磁盘 IO 各前 5 名、总览和一句白话说结论。只读，不结束任何进程。',
    actions: ['scan'],
    defaultParams: {},
    group: 'system',
    coverage: COVERAGE.full,
    needsAdmin: false,
  },
  {
    id: 'diskhealth',
    probe: 'diskhealth.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '硬盘健康',
    labelEn: 'Disk health',
    tagline: '提前发现硬盘要坏的前兆',
    detail:
      '控制器报告的健康状态、型号、总线、序列号、分区占用都能直接读到。SMART 详细读数（通电小时、温度、磨损、读写错误）需要管理员权限；NVMe 盘的「故障预测」走的是 Windows 只枚举 ATA/SATA 的通道，本机拿不到——这两条会分开如实说明，不会填 0 假装健康。',
    actions: ['scan'],
    defaultParams: {},
    group: 'system',
    coverage: COVERAGE.partial,
    needsAdmin: false,
  },

  /* ---------------------------------------------- 系统安全防护 / 隐私 / 权限 */
  {
    id: 'security',
    probe: 'security.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '系统安全防护',
    labelEn: 'System security',
    tagline: 'UAC、Defender、SMB、RDP、Autorun、LSA 一次过一遍',
    detail: '360 把它叫「防黑加固」。这里只读报告每一项的当前值和安全基线，并指出差在哪——不改任何设置。每一项都带原始注册表/WMI 读数，不是评分。',
    actions: ['scan'],
    defaultParams: {},
    group: 'system',
    coverage: COVERAGE.readonly,
    needsAdmin: false,
  },
  {
    id: 'privacy',
    probe: 'privacy.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '隐私保镖',
    labelEn: 'Privacy guard',
    tagline: '遥测、广告 ID、定位、活动历史、应用权限总览',
    detail: '读 Windows 的 ConsentStore 与隐私相关策略，报告哪些开关是开的、哪些应用拿到了敏感权限。只读。',
    actions: ['scan'],
    defaultParams: {},
    group: 'system',
    coverage: COVERAGE.readonly,
    needsAdmin: false,
  },
  {
    id: 'perm',
    probe: 'perm.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '权限管理',
    labelEn: 'App permissions',
    tagline: '逐个应用看谁拿到了摄像头、麦克风、文件系统权限',
    detail: '和 privacy 不重复：那边看全局开关，这边看逐应用明细。能把「哪个应用在什么时候用过摄像头」追到具体时间，也能发现「门是开着的但还没有人走进来」这种隐患。只读。',
    actions: ['scan'],
    defaultParams: {},
    group: 'system',
    coverage: COVERAGE.readonly,
    needsAdmin: false,
  },
  {
    id: 'popup',
    probe: 'popup.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '弹窗过滤',
    labelEn: 'Popup sources',
    tagline: '找出弹窗的源头：进程、计划任务、已装软件、通知设置',
    detail: '360 用常驻钩子实时拦截；DSH 插件是会话级、可随时卸载的，挂不了 SetWinEventHook。所以这里不做拦截，只公布弹窗来源让用户自己关——数可见窗口、识别可疑窗口、追到计划任务与安装的软件。',
    actions: ['scan'],
    defaultParams: {},
    group: 'system',
    coverage: COVERAGE.partial,
    needsAdmin: false,
  },

  /* ------------------------------------------------------------ 网络与提速 */
  {
    id: 'speedtest',
    probe: 'speedtest.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '宽带测速',
    labelEn: 'Speed test',
    tagline: '下载、上传、延迟、抖动，多端点回退',
    detail: '纯只读 HTTP 测速，不装任何东西。单点结果不可信——本机实测同一网络两轮相差 3 倍，所以列表里会同时给出所用端点与回退情况，告诉你这个数字有多可信。',
    actions: ['scan'],
    defaultParams: {},
    group: 'network',
    coverage: COVERAGE.full,
    needsAdmin: false,
  },
  {
    id: 'homepage',
    probe: 'homepage.ps1',
    view: 'checks',
    risk: RISK.reversible,
    label: '主页防护',
    labelEn: 'Homepage guard',
    tagline: '检查浏览器主页是否被改，快捷方式有没有被塞网址',
    detail: '扫 IE 起始页、策略、Edge/Chrome 启动页，以及桌面与开始菜单里所有 .lnk 的目标行有没有被追加 URL。发现被改时可以写回（默认预演，写前自动 reg export 备份）。',
    actions: ['scan', 'apply'],
    defaultParams: {},
    group: 'system',
    coverage: COVERAGE.full,
    needsAdmin: false,
  },

  /* ---------------------------------------------------------- 磁盘与急救 */
  {
    id: 'slim',
    probe: 'slim.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '系统盘瘦身',
    labelEn: 'Slim system drive',
    tagline: 'pagefile、休眠、Windows.old、更新缓存、AppData 大头',
    detail: '只算不改。特别会点出 pagefile 这种「不能删只能迁」的项目，避免用户以为删掉就省空间。WinSxS 不递归（枚举极慢），指向 DISM 分析命令。',
    actions: ['scan'],
    defaultParams: {},
    group: 'cleanup',
    coverage: COVERAGE.readonly,
    needsAdmin: false,
  },
  {
    id: 'rescue',
    probe: 'rescue.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '系统急救箱',
    labelEn: 'System rescue',
    tagline: '待重启、sfc/DISM、还原点、事件日志、Defender',
    detail: '把「系统到底有没有坏」拆成可判定的项：sfc 与 DISM 在未提权时会如实 skip 而不是报通过；Get-WinEvent 无匹配事件是正常情况，会记成 0 条而不是读取失败。只读，不自动修任何东西。',
    actions: ['scan'],
    defaultParams: {},
    group: 'system',
    coverage: COVERAGE.readonly,
    needsAdmin: false,
  },
  {
    id: 'backup',
    probe: 'backup.ps1',
    view: 'checks',
    risk: RISK.reversible,
    label: '备份还原',
    labelEn: 'Backup / restore',
    tagline: '导出注册表键，并在改任何东西之前自动备份',
    detail: '本机零还原点、VSS 停用，所以「创建还原点」这条路不通。可行的备份是把要改的注册表键 reg export 到 %LOCALAPPDATA%\\dsh-windows-toolbox\\regbackup，恢复时 reg import 回去。默认预演，只有 dryRun:false 才落盘。',
    actions: ['scan', 'apply'],
    defaultParams: {},
    group: 'system',
    coverage: COVERAGE.partial,
    needsAdmin: false,
  },

  /* ------------------------------------------------------- 应用与外壳管理 */
  {
    id: 'software',
    probe: 'software.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '软件管家',
    labelEn: 'Software manager',
    tagline: '已装程序、官网目录命中、winget 可升级清单',
    detail: '官网目录只收录厂商自己的下载页——没有第三方下载站、没有短链、没有聚合页。可升级清单来自 winget 的本地元数据，不联网猜版本。安装与升级动作本版本不接线，只给命令让用户自己执行。',
    actions: ['scan'],
    defaultParams: {},
    group: 'apps',
    coverage: COVERAGE.partial,
    needsAdmin: false,
  },
  {
    id: 'softmgr',
    probe: 'softmgr.ps1',
    view: 'checks',
    risk: RISK.reversible,
    label: '软件管家进阶',
    labelEn: 'Software deep clean',
    tagline: '卸载残留、软件搬家可行性、软件权限',
    detail: '卸载后会留下三类残渣：安装目录、AppData 配置、注册表键。这里只扫描并列出证据，不删。软件搬家只做可行性分析（目标盘空间、占用进程、链接点），不真的搬——搬移正在被引用的目录会毁掉已装程序。',
    actions: ['scan', 'apply'],
    defaultParams: { action: 'scan' },
    group: 'apps',
    coverage: COVERAGE.partial,
    needsAdmin: false,
  },
  {
    id: 'drivers',
    probe: 'drivers.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '驱动清单',
    labelEn: 'Driver inventory',
    tagline: '第三方驱动包、问题设备、未签名驱动',
    detail: '从注册表 DriverDatabase 枚举驱动包并折回设备，不用 pnputil 的本地化文本（那玩意在中文控制台下会被代码页搞坏，静默匹配 0 条）。只读。',
    actions: ['scan'],
    defaultParams: {},
    group: 'apps',
    coverage: COVERAGE.readonly,
    needsAdmin: false,
  },
  {
    id: 'drivers2',
    probe: 'drivers2.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '驱动更新检查',
    labelEn: 'Driver update check',
    tagline: '缺驱动的硬件、偏旧的驱动、厂商官网入口',
    detail: '必须说清楚：Windows 本地没有厂商最新版本数据库，所以这里不会、也不能声称检测到了新版本。它只报「哪些硬件没有驱动」和「哪些驱动日期偏旧」，并给出厂商官网，去哪下载由用户决定。',
    actions: ['scan'],
    defaultParams: {},
    group: 'apps',
    coverage: COVERAGE.partial,
    needsAdmin: false,
  },
  {
    id: 'contextmenu',
    probe: 'contextmenu.ps1',
    view: 'checks',
    risk: RISK.reversible,
    label: '右键管理',
    labelEn: 'Context menu',
    tagline: '资源管理器右键菜单项的启用与屏蔽',
    detail: '枚举 12 个 shellex 挂载位置，用 Shell Extensions\\Approved 的空串机制屏蔽单项（值必须存在且为空=阻止，删掉值不等于禁用）。HKCU 免提权可写，HKLM 需要管理员。默认预演。',
    actions: ['scan', 'apply'],
    defaultParams: {},
    group: 'apps',
    coverage: COVERAGE.full,
    needsAdmin: false,
  },
  {
    id: 'winsettings',
    probe: 'winsettings.ps1',
    view: 'checks',
    risk: RISK.reversible,
    label: 'WINDOWS 设置',
    labelEn: 'Windows settings',
    tagline: '深色模式、扩展名、任务栏、24 小时制等常用开关',
    detail: '只读扫描 38 项常用设置并报告当前值。写回只支持 HKCU 项（免提权），且先校验值类型——DWORD 传字符串会「写了但不生效」，所以这类请求直接拒绝。Win11 专有项在 Win10 上如实报「未设置=系统默认」。',
    actions: ['scan', 'apply'],
    defaultParams: { action: 'scan' },
    group: 'system',
    coverage: COVERAGE.partial,
    needsAdmin: false,
  },
  {
    id: 'phone',
    probe: 'phone.ps1',
    view: 'checks',
    risk: RISK.readonly,
    label: '手机助手',
    labelEn: 'Phone link',
    tagline: 'Phone Link、已配对设备、WPD 与 MTP 驱动状态',
    detail: 'AppX 枚举必须走 5.1 桥接并验证条数大于零——PS7 下 Get-AppxPackage 会静默返回空，看起来像「没装任何应用」。设备列表区分「当前连接」与「历史配对」，不会把幽灵记录报成已连接。',
    actions: ['scan'],
    defaultParams: {},
    group: 'apps',
    coverage: COVERAGE.readonly,
    needsAdmin: false,
  },
  {
    id: 'tweaks',
    probe: 'tweaks.ps1',
    view: 'checks',
    risk: RISK.reversible,
    label: '优化预设',
    labelEn: 'Tweak presets',
    tagline: '51 项常用优化，逐项预演后再动手',
    detail: '数据来自 winutil（MIT），只保留注册表值与服务启动类型两类改动，丢掉了原项目里 27 条任意 PowerShell 脚本。默认预演；真写之前把每个键 reg export 备份，备份失败就中止。',
    actions: ['scan', 'apply'],
    defaultParams: { action: 'scan' },
    group: 'system',
    coverage: COVERAGE.partial,
    needsAdmin: true,
  },
  {
    id: 'shredder',
    probe: 'shredder.ps1',
    view: 'checks',
    risk: RISK.destructive,
    label: '文件粉碎机',
    labelEn: 'File shredder',
    tagline: '覆盖写后删除指定文件（SSD 上无效，会说明原因）',
    detail: '只接受显式传入的单个文件路径：不收通配符、不递归目录、拒绝系统目录与可执行扩展名、拒绝硬链接与重解析点。默认预演。SSD 上覆盖写会被主控重映射，真实效果有限——这一点会写在结果里，不当作能保证销毁。',
    actions: ['scan', 'apply'],
    defaultParams: {},
    group: 'cleanup',
    coverage: COVERAGE.partial,
    needsAdmin: false,
  },
];

export const CAPABILITY_BY_ID = new Map(CAPABILITIES.map((c) => [c.id, c]));
export const CAPABILITY_IDS = new Set(CAPABILITIES.map((c) => c.id));

/** Capability groups, so 27 entries stay navigable in a narrow sidebar. */
export const CAPABILITY_GROUPS = [
  { id: 'cleanup', label: '清理与空间', labelEn: 'Cleanup & space' },
  { id: 'system', label: '系统与安全', labelEn: 'System & security' },
  { id: 'network', label: '网络', labelEn: 'Network' },
  { id: 'apps', label: '应用与外壳', labelEn: 'Apps & shell' },
];
export const CAPABILITY_GROUP_IDS = new Set(CAPABILITY_GROUPS.map((g) => g.id));

/** Scan roots, mirrored from rootlib.ps1. Display only — the probe resolves. */
export const SCAN_ROOTS = [
  { id: 'user', label: '用户目录', labelEn: 'User profile' },
  { id: 'downloads', label: '下载', labelEn: 'Downloads' },
  { id: 'desktop', label: '桌面', labelEn: 'Desktop' },
  { id: 'documents', label: '文档', labelEn: 'Documents' },
  { id: 'pictures', label: '图片', labelEn: 'Pictures' },
];
export const SCAN_ROOT_IDS = new Set(SCAN_ROOTS.map((r) => r.id));
