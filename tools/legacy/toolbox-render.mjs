/**
 * Mounts a DSH client panel in a miniature React runtime with a stubbed host
 * (slots / locale / fetch), re-rendering until the tree settles.
 *
 * Why this exists: the agent cannot click into the DSH window — the desktop-input
 * lane refuses to target a DSH host executable (HOST_INPUT_DENIED), and opening
 * the GUI URL in a browser lane is refused too (WCU_POLICY_DENIED). So "does the
 * panel actually mount and paint" is otherwise unverifiable. This catches
 * ReferenceErrors, missing dict keys, undeclared state, bad element types,
 * mojibake, and URLs that escape the plugin namespace.
 *
 * Not a browser: no layout, no CSS, no real React reconciliation. It proves the
 * component tree renders without throwing and produces the expected strings.
 *
 *   node harness.mjs <path-to-client.js>
 *   TB360_LANG=en  node harness.mjs ...   # render the English dictionary
 *   TB360_DEBUG=1  node harness.mjs ...   # dump render passes and text
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const CLIENT = process.argv[2] ?? fileURLToPath(new URL('../client.js', import.meta.url));
const src = readFileSync(CLIENT, 'utf8');
const LANG = process.env.TB360_LANG ?? 'zh';
const MAX_PASSES = 30;

/* ------------------------------------------------------------- fake react */

const React = {
  createElement(type, props, ...children) {
    const kids = children.length === 1 ? children[0] : (children.length ? children : undefined);
    return { type, props: props ?? {}, children: kids };
  },
  Fragment: Symbol('Fragment'),
};

/**
 * Frames persist across passes so useState keeps its value, like real hooks.
 * Instance identity = visit order within a pass. A component that mounts or
 * unmounts between passes can inherit its predecessor's slots — acceptable here
 * because this harness proves the tree paints, it is not a faithful reconciler.
 */
let frames = [];
let hookStack = [];
let visitOrder = 0;
let dirty = false;
let effects = [];

function useSlot(init) {
  const frame = hookStack[hookStack.length - 1];
  if (!frame) throw new Error('hook called outside a component');
  const i = frame.cursor++;
  if (!frame.slots) frame.slots = [];
  if (!(i in frame.slots)) frame.slots[i] = { v: typeof init === 'function' ? init() : init };
  return frame.slots[i];
}

function depsChanged(prev, next) {
  if (!prev || !next) return true;
  if (prev.length !== next.length) return true;
  return next.some((d, i) => !Object.is(d, prev[i]));
}

React.useState = (init) => {
  const slot = useSlot(init);
  const set = (next) => {
    const value = typeof next === 'function' ? next(slot.v) : next;
    if (!Object.is(value, slot.v)) { slot.v = value; dirty = true; }
  };
  return [slot.v, set];
};
React.useRef = (init) => useSlot({ current: init }).v;
React.useMemo = (fn, deps) => {
  const slot = useSlot(null);
  if (slot.seeded && !depsChanged(slot.deps, deps)) return slot.v;
  slot.v = fn();
  slot.deps = deps;
  slot.seeded = true;
  return slot.v;
};
React.useCallback = (fn, deps) => React.useMemo(() => fn, deps);
React.useEffect = (fn, deps) => {
  const slot = useSlot(null);
  if (slot.seeded && !depsChanged(slot.deps, deps)) return;
  slot.deps = deps;
  slot.seeded = true;
  effects.push(fn);
};

function expand(node, depth) {
  if (depth > 80) throw new Error('render tree too deep — possible infinite recursion');
  if (node == null || node === false || node === true) return node;
  if (typeof node === 'string' || typeof node === 'number') return String(node);
  if (Array.isArray(node)) return node.map((n) => expand(n, depth + 1));
  if (typeof node !== 'object') return node;

  const { type, props } = node;
  if (type === React.Fragment) return expand(props?.children ?? node.children, depth + 1);

  if (typeof type === 'function') {
    const frame = frames[visitOrder] ?? (frames[visitOrder] = { cursor: 0, slots: [] });
    frame.cursor = 0;
    visitOrder += 1;
    hookStack.push(frame);
    try {
      return expand(type(props ?? {}), depth + 1);
    } finally {
      hookStack.pop();
    }
  }

  if (typeof type === 'string') {
    const kids = props?.children ?? node.children;
    return { type, props: { ...props, children: expand(kids, depth + 1) } };
  }

  throw new Error(`element type is not renderable: ${String(type)}`);
}

/* --------------------------------------------------------------- fixtures */

const HOST = { interpreter: 'pwsh (PS 7)', elevated: false, user: '26035', os: 'Microsoft Windows 10 专业版 (build 19045)' };

const FIXTURES = {
  'dsh-360-toolbox': {
    ns: '/dsh-360-toolbox/',
    // Captured from the live host on 2026-11-17 (29 capabilities, real probe output).
    payloads: {
      '/status': {
        "ok": true,
        "name": "dsh-360-toolbox",
        "version": "0.1.0",
        "host": {
          "interpreter": "pwsh (PS 7)",
          "elevated": false,
          "user": "26035",
          "os": "Microsoft Windows 10 专业版 (build 19045)"
        },
        "catalogue": [
          {
            "id": "junk",
            "label": "垃圾清理",
            "labelEn": "Junk cleanup",
            "tagline": "扫描可安全删除的临时文件、缓存与回收站",
            "detail": "只清理固定白名单内的目录内容，目录本身一定保留；需要管理员权限的目标在未提权时会明确跳过，不会假装清理成功。",
            "risk": "destructive",
            "actions": [
              "scan",
              "clean"
            ],
            "defaultParams": {},
            "view": "junk",
            "group": "cleanup",
            "coverage": "full",
            "needsAdmin": false
          },
          {
            "id": "bigfiles",
            "label": "大文件查找",
            "labelEn": "Large files",
            "tagline": "找出占用空间最多的单个文件",
            "detail": "按大小阈值递归扫描选定的根目录，只读不删。根目录只能按预设 id 选择，不接受任意路径，避免扫到共享或别人的目录。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {
              "root": "user",
              "minMb": 100,
              "limit": 200
            },
            "view": "files",
            "group": "cleanup",
            "coverage": "full",
            "needsAdmin": false
          },
          {
            "id": "dupfiles",
            "label": "重复文件",
            "labelEn": "Duplicate files",
            "tagline": "按内容哈希找出真正重复的文件",
            "detail": "三级漏斗：先按大小分组，再比对前 64 KiB，最后对幸存者算全量 SHA256。只有全量哈希相同才算重复，不会把同名文件误报成重复。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {
              "root": "user",
              "minKb": 1024,
              "limit": 100
            },
            "view": "groups",
            "group": "cleanup",
            "coverage": "full",
            "needsAdmin": false
          },
          {
            "id": "netdiag",
            "label": "断网急救箱",
            "labelEn": "Network repair",
            "tagline": "上不了网？先找断在哪一环，再一键修",
            "detail": "先按链路顺序检查网卡、IP、网关、DNS、外网、代理、hosts，报出第一个失败的环节——那是真正的故障点，后面的失败都是它的结果。另外两项体检：Wi-Fi 信号强度与实际收发速率、以及把五个公共 DNS 和当前设置的 DNS 逐个实测一遍给出排名。修的时候给 7 个动作：清 DNS 缓存、重续 IP、重置 Winsock、重置 TCP/IP、重置 WinHTTP 代理、清 IE 代理、重启网卡。免提权的三项能直接跑；需要管理员的三项会给出完整命令并提示用「以管理员身份重试」；重置类要重启才完全生效，界面上会明说。DNS 只接受五个公开候选或「自动获取」，改之前先把旧值备份到磁盘并给出回滚命令。",
            "risk": "reversible",
            "actions": [
              "scan",
              "repair",
              "dnspick"
            ],
            "defaultParams": {
              "action": "scan"
            },
            "view": "steps",
            "group": "network",
            "coverage": "full",
            "needsAdmin": false
          },
          {
            "id": "health",
            "label": "系统体检",
            "labelEn": "Health check",
            "tagline": "磁盘、内存、服务、设备、防护一次过一遍",
            "detail": "每项都给出实测值、判定阈值和修复方向，不给没有依据的分数。只读，不自动修复任何问题。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "full",
            "needsAdmin": false
          },
          {
            "id": "proc",
            "label": "任务管理器",
            "labelEn": "Task manager",
            "tagline": "谁在偷吃 CPU、内存和磁盘",
            "detail": "CPU 占用是两次采样求差算出来的（不是读 Get-Process 那个累计值），已排除 Idle 与 System。给出 CPU / 内存 / 磁盘 IO 各前 5 名、总览和一句白话说结论。只读，不结束任何进程。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "full",
            "needsAdmin": false
          },
          {
            "id": "diskhealth",
            "label": "硬盘健康",
            "labelEn": "Disk health",
            "tagline": "提前发现硬盘要坏的前兆",
            "detail": "控制器报告的健康状态、型号、总线、序列号、分区占用都能直接读到。SMART 详细读数（通电小时、温度、磨损、读写错误）需要管理员权限；NVMe 盘的「故障预测」走的是 Windows 只枚举 ATA/SATA 的通道，本机拿不到——这两条会分开如实说明，不会填 0 假装健康。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "partial",
            "needsAdmin": false
          },
          {
            "id": "security",
            "label": "系统安全防护",
            "labelEn": "System security",
            "tagline": "UAC、Defender、SMB、RDP、Autorun、LSA 一次过一遍",
            "detail": "360 把它叫「防黑加固」。这里只读报告每一项的当前值和安全基线，并指出差在哪——不改任何设置。每一项都带原始注册表/WMI 读数，不是评分。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "readonly",
            "needsAdmin": false
          },
          {
            "id": "privacy",
            "label": "隐私保镖",
            "labelEn": "Privacy guard",
            "tagline": "遥测、广告 ID、定位、活动历史、应用权限总览",
            "detail": "读 Windows 的 ConsentStore 与隐私相关策略，报告哪些开关是开的、哪些应用拿到了敏感权限。只读。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "readonly",
            "needsAdmin": false
          },
          {
            "id": "perm",
            "label": "权限管理",
            "labelEn": "App permissions",
            "tagline": "逐个应用看谁拿到了摄像头、麦克风、文件系统权限",
            "detail": "和 privacy 不重复：那边看全局开关，这边看逐应用明细。能把「哪个应用在什么时候用过摄像头」追到具体时间，也能发现「门是开着的但还没有人走进来」这种隐患。只读。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "readonly",
            "needsAdmin": false
          },
          {
            "id": "amiba",
            "label": "变形虫防护",
            "labelEn": "BadUSB guard",
            "tagline": "USB 设备安装限制、可移动存储策略、横向渗透面",
            "detail": "结论必须说清楚：BadUSB 在操作系统里防不住。伪装成键盘的设备固件可以重写、可以枚举成任何设备类，任何策略都跑在它后面。这里能做的是收紧设备安装与可移动存储策略，并把「只能物理层解决」写进结论，不假装挡住了。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "blocked",
            "needsAdmin": false
          },
          {
            "id": "popup",
            "label": "弹窗过滤",
            "labelEn": "Popup sources",
            "tagline": "找出弹窗的源头：进程、计划任务、已装软件、通知设置",
            "detail": "360 用常驻钩子实时拦截；DSH 插件是会话级、可随时卸载的，挂不了 SetWinEventHook。所以这里不做拦截，只公布弹窗来源让用户自己关——数可见窗口、识别可疑窗口、追到计划任务与安装的软件。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "partial",
            "needsAdmin": false
          },
          {
            "id": "speedtest",
            "label": "宽带测速",
            "labelEn": "Speed test",
            "tagline": "下载、上传、延迟、抖动，多端点回退",
            "detail": "纯只读 HTTP 测速，不装任何东西。单点结果不可信——本机实测同一网络两轮相差 3 倍，所以列表里会同时给出所用端点与回退情况，告诉你这个数字有多可信。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "network",
            "coverage": "full",
            "needsAdmin": false
          },
          {
            "id": "homepage",
            "label": "主页防护",
            "labelEn": "Homepage guard",
            "tagline": "检查浏览器主页是否被改，快捷方式有没有被塞网址",
            "detail": "扫 IE 起始页、策略、Edge/Chrome 启动页，以及桌面与开始菜单里所有 .lnk 的目标行有没有被追加 URL。发现被改时可以写回（默认预演，写前自动 reg export 备份）。",
            "risk": "reversible",
            "actions": [
              "scan",
              "apply"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "full",
            "needsAdmin": false
          },
          {
            "id": "slim",
            "label": "系统盘瘦身",
            "labelEn": "Slim system drive",
            "tagline": "pagefile、休眠、Windows.old、更新缓存、AppData 大头",
            "detail": "只算不改。特别会点出 pagefile 这种「不能删只能迁」的项目，避免用户以为删掉就省空间。WinSxS 不递归（枚举极慢），指向 DISM 分析命令。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "cleanup",
            "coverage": "readonly",
            "needsAdmin": false
          },
          {
            "id": "expandc",
            "label": "C 盘扩容",
            "labelEn": "Expand C:",
            "tagline": "能不能扩、被谁挡着、要付什么代价",
            "detail": "纯只读评估。磁盘管理只能吃尾部紧邻的未分配空间，做不到隔一个分区扩容；本机 C 后面紧贴恢复分区，所以结论会直接说不能扩以及为什么。删恢复分区会让 WinRE 失效，这个代价会写进结论。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "cleanup",
            "coverage": "blocked",
            "needsAdmin": false
          },
          {
            "id": "recovery",
            "label": "文件误删恢复",
            "labelEn": "Deleted file recovery",
            "tagline": "重建还是放弃：看 TRIM、硬盘类型和删除时间",
            "detail": "SSD 上一个文件被删后，主控会把它标记为可回收并最终擦除物理块，覆盖写根本触不到原块——所以本机的真实恢复概率接近零。这里给出判断依据（TRIM 开关、介质类型、卷状态），不提供假装能恢复的按钮。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "blocked",
            "needsAdmin": false
          },
          {
            "id": "rescue",
            "label": "系统急救箱",
            "labelEn": "System rescue",
            "tagline": "待重启、sfc/DISM、还原点、事件日志、Defender",
            "detail": "把「系统到底有没有坏」拆成可判定的项：sfc 与 DISM 在未提权时会如实 skip 而不是报通过；Get-WinEvent 无匹配事件是正常情况，会记成 0 条而不是读取失败。只读，不自动修任何东西。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "readonly",
            "needsAdmin": false
          },
          {
            "id": "backup",
            "label": "备份还原",
            "labelEn": "Backup / restore",
            "tagline": "导出注册表键，并在改任何东西之前自动备份",
            "detail": "本机零还原点、VSS 停用，所以「创建还原点」这条路不通。可行的备份是把要改的注册表键 reg export 到 %LOCALAPPDATA%\\dsh-360-toolbox\\regbackup，恢复时 reg import 回去。默认预演，只有 dryRun:false 才落盘。",
            "risk": "reversible",
            "actions": [
              "scan",
              "apply"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "partial",
            "needsAdmin": false
          },
          {
            "id": "reinstall",
            "label": "系统重装",
            "labelEn": "Reinstall readiness",
            "tagline": "重装前必须知道的：WinRE、BitLocker、Windows.old、机型",
            "detail": "重装这一步无法由插件代劳——它要重启进另一个环境。这里只做重装前检查：恢复分区是否完好、BitLocker 是否开着（开着不先挂起会锁盘）、有没有 Windows.old、是不是笔记本。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "system",
            "coverage": "blocked",
            "needsAdmin": false
          },
          {
            "id": "software",
            "label": "软件管家",
            "labelEn": "Software manager",
            "tagline": "已装程序、官网目录命中、winget 可升级清单",
            "detail": "官网目录只收录厂商自己的下载页——没有第三方下载站、没有短链、没有聚合页。可升级清单来自 winget 的本地元数据，不联网猜版本。安装与升级动作本版本不接线，只给命令让用户自己执行。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "apps",
            "coverage": "partial",
            "needsAdmin": false
          },
          {
            "id": "softmgr",
            "label": "软件管家进阶",
            "labelEn": "Software deep clean",
            "tagline": "卸载残留、软件搬家可行性、软件权限",
            "detail": "卸载后会留下三类残渣：安装目录、AppData 配置、注册表键。这里只扫描并列出证据，不删。软件搬家只做可行性分析（目标盘空间、占用进程、链接点），不真的搬——搬移正在被引用的目录会毁掉已装程序。",
            "risk": "reversible",
            "actions": [
              "scan",
              "apply"
            ],
            "defaultParams": {
              "action": "scan"
            },
            "view": "checks",
            "group": "apps",
            "coverage": "partial",
            "needsAdmin": false
          },
          {
            "id": "drivers",
            "label": "驱动清单",
            "labelEn": "Driver inventory",
            "tagline": "第三方驱动包、问题设备、未签名驱动",
            "detail": "从注册表 DriverDatabase 枚举驱动包并折回设备，不用 pnputil 的本地化文本（那玩意在中文控制台下会被代码页搞坏，静默匹配 0 条）。只读。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "apps",
            "coverage": "readonly",
            "needsAdmin": false
          },
          {
            "id": "drivers2",
            "label": "驱动更新检查",
            "labelEn": "Driver update check",
            "tagline": "缺驱动的硬件、偏旧的驱动、厂商官网入口",
            "detail": "必须说清楚：Windows 本地没有厂商最新版本数据库，所以这里不会、也不能声称检测到了新版本。它只报「哪些硬件没有驱动」和「哪些驱动日期偏旧」，并给出厂商官网，去哪下载由用户决定。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "apps",
            "coverage": "partial",
            "needsAdmin": false
          },
          {
            "id": "contextmenu",
            "label": "右键管理",
            "labelEn": "Context menu",
            "tagline": "资源管理器右键菜单项的启用与屏蔽",
            "detail": "枚举 12 个 shellex 挂载位置，用 Shell Extensions\\Approved 的空串机制屏蔽单项（值必须存在且为空=阻止，删掉值不等于禁用）。HKCU 免提权可写，HKLM 需要管理员。默认预演。",
            "risk": "reversible",
            "actions": [
              "scan",
              "apply"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "apps",
            "coverage": "full",
            "needsAdmin": false
          },
          {
            "id": "winsettings",
            "label": "WINDOWS 设置",
            "labelEn": "Windows settings",
            "tagline": "深色模式、扩展名、任务栏、24 小时制等常用开关",
            "detail": "只读扫描 38 项常用设置并报告当前值。写回只支持 HKCU 项（免提权），且先校验值类型——DWORD 传字符串会「写了但不生效」，所以这类请求直接拒绝。Win11 专有项在 Win10 上如实报「未设置=系统默认」。",
            "risk": "reversible",
            "actions": [
              "scan",
              "apply"
            ],
            "defaultParams": {
              "action": "scan"
            },
            "view": "checks",
            "group": "system",
            "coverage": "partial",
            "needsAdmin": false
          },
          {
            "id": "phone",
            "label": "手机助手",
            "labelEn": "Phone link",
            "tagline": "Phone Link、已配对设备、WPD 与 MTP 驱动状态",
            "detail": "AppX 枚举必须走 5.1 桥接并验证条数大于零——PS7 下 Get-AppxPackage 会静默返回空，看起来像「没装任何应用」。设备列表区分「当前连接」与「历史配对」，不会把幽灵记录报成已连接。",
            "risk": "readonly",
            "actions": [
              "scan"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "apps",
            "coverage": "readonly",
            "needsAdmin": false
          },
          {
            "id": "tweaks",
            "label": "优化预设",
            "labelEn": "Tweak presets",
            "tagline": "51 项常用优化，逐项预演后再动手",
            "detail": "数据来自 winutil（MIT），只保留注册表值与服务启动类型两类改动，丢掉了原项目里 27 条任意 PowerShell 脚本。默认预演；真写之前把每个键 reg export 备份，备份失败就中止。",
            "risk": "reversible",
            "actions": [
              "scan",
              "apply"
            ],
            "defaultParams": {
              "action": "scan"
            },
            "view": "checks",
            "group": "system",
            "coverage": "partial",
            "needsAdmin": true
          },
          {
            "id": "shredder",
            "label": "文件粉碎机",
            "labelEn": "File shredder",
            "tagline": "覆盖写后删除指定文件（SSD 上无效，会说明原因）",
            "detail": "只接受显式传入的单个文件路径：不收通配符、不递归目录、拒绝系统目录与可执行扩展名、拒绝硬链接与重解析点。默认预演。SSD 上覆盖写会被主控重映射，真实效果有限——这一点会写在结果里，不当作能保证销毁。",
            "risk": "destructive",
            "actions": [
              "scan",
              "apply"
            ],
            "defaultParams": {},
            "view": "checks",
            "group": "cleanup",
            "coverage": "partial",
            "needsAdmin": false
          }
        ],
        "capabilities": [
          {
            "id": "junk",
            "cached": true,
            "itemCount": 6,
            "at": 1794919995560
          },
          {
            "id": "bigfiles",
            "cached": true,
            "itemCount": 0,
            "at": 1794919995560
          },
          {
            "id": "dupfiles",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "netdiag",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "health",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "security",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "privacy",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "perm",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "amiba",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "popup",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "speedtest",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "homepage",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "slim",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "expandc",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "recovery",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "rescue",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "backup",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "reinstall",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "software",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "softmgr",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "drivers",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "drivers2",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "contextmenu",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "winsettings",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "phone",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "tweaks",
            "cached": false,
            "itemCount": 0,
            "at": 0
          },
          {
            "id": "shredder",
            "cached": false,
            "itemCount": 0,
            "at": 0
          }
        ],
        "groups": [
          {
            "id": "cleanup",
            "label": "清理与空间",
            "labelEn": "Cleanup & space"
          },
          {
            "id": "system",
            "label": "系统与安全",
            "labelEn": "System & security"
          },
          {
            "id": "network",
            "label": "网络",
            "labelEn": "Network"
          },
          {
            "id": "apps",
            "label": "应用与外壳",
            "labelEn": "Apps & shell"
          }
        ],
        "junkGroups": [
          {
            "id": "temp",
            "label": "临时文件",
            "labelEn": "Temporary",
            "targets": [
              "user-temp",
              "windows-temp"
            ]
          },
          {
            "id": "browser",
            "label": "浏览器缓存",
            "labelEn": "Browser",
            "targets": [
              "edge-cache"
            ]
          }
        ],
        "scanRoots": [
          {
            "id": "user",
            "label": "用户目录"
          },
          {
            "id": "downloads",
            "label": "下载"
          }
        ]
      },
      '/result?id=junk': {
        "ok": true,
        "cached": false,
        "items": [
          {
            "id": "user-temp",
            "label": "用户临时文件",
            "path": "C:\\Users\\26035\\AppData\\Local\\Temp",
            "kind": "dirContent",
            "exists": true,
            "blocked": false,
            "needsAdmin": false,
            "files": 5795,
            "bytes": 619128167,
            "note": ""
          },
          {
            "id": "windows-temp",
            "label": "系统临时文件",
            "path": "C:\\Windows\\Temp",
            "kind": "dirContent",
            "exists": true,
            "blocked": true,
            "needsAdmin": true,
            "files": 292,
            "bytes": 143514433,
            "note": ""
          },
          {
            "id": "crash-dumps",
            "label": "崩溃转储",
            "path": "C:\\Users\\26035\\AppData\\Local\\CrashDumps",
            "kind": "dirContent",
            "exists": true,
            "blocked": false,
            "needsAdmin": false,
            "files": 10,
            "bytes": 14807622,
            "note": ""
          },
          {
            "id": "wer-report",
            "label": "错误报告缓存",
            "path": "C:\\Users\\26035\\AppData\\Local\\Microsoft\\Windows\\WER",
            "kind": "dirContent",
            "exists": false,
            "blocked": false,
            "needsAdmin": false,
            "files": 0,
            "bytes": 0,
            "note": ""
          },
          {
            "id": "inet-cache",
            "label": "IE/系统网络缓存",
            "path": "C:\\Users\\26035\\AppData\\Local\\Microsoft\\Windows\\INetCache",
            "kind": "dirContent",
            "exists": true,
            "blocked": false,
            "needsAdmin": false,
            "files": 75,
            "bytes": 1234158,
            "note": ""
          },
          {
            "id": "edge-cache",
            "label": "Edge 缓存",
            "path": "C:\\Users\\26035\\AppData\\Local\\Microsoft\\Edge\\User Data\\Default\\Cache",
            "kind": "dirContent",
            "exists": true,
            "blocked": false,
            "needsAdmin": false,
            "files": 589,
            "bytes": 392021388,
            "note": ""
          }
        ],
        "meta": {
          "action": "scan",
          "totalBytes": 2077738341,
          "totalFiles": 12740,
          "freed": 0,
          "deleted": 0,
          "elevated": false
        }
      },
      '/result?id=netdiag': {
        "ok": true,
        "items": [
          {
            "id": "link",
            "label": "网卡连接",
            "status": "ok",
            "detail": "已连接: WLAN",
            "group": "",
            "value": "",
            "ms": 0
          },
          {
            "id": "ip",
            "label": "IP 地址",
            "status": "ok",
            "detail": "WLAN=192.168.0.105",
            "group": "",
            "value": "",
            "ms": 0
          },
          {
            "id": "gateway-config",
            "label": "默认网关",
            "status": "ok",
            "detail": "192.168.0.1",
            "group": "",
            "value": "",
            "ms": 0
          },
          {
            "id": "gateway-ping",
            "label": "网关连通",
            "status": "ok",
            "detail": "网关 192.168.0.1 可达",
            "group": "",
            "value": "",
            "ms": 1039
          },
          {
            "id": "dns",
            "label": "域名解析",
            "status": "ok",
            "detail": "DNS 服务器: 119.6.6.6, 192.168.0.1",
            "group": "",
            "value": "",
            "ms": 28
          },
          {
            "id": "internet",
            "label": "外网访问",
            "status": "ok",
            "detail": "连通: http://www.msftconnecttest.com/connecttest.txt -> HTTP 200",
            "group": "",
            "value": "",
            "ms": 344
          },
          {
            "id": "proxy",
            "label": "代理设置",
            "status": "ok",
            "detail": "未启用系统代理（进程级环境变量不在检查范围）",
            "group": "",
            "value": "",
            "ms": 0
          },
          {
            "id": "hosts",
            "label": "hosts 文件",
            "status": "ok",
            "detail": "共 0 条自定义映射",
            "group": "",
            "value": "",
            "ms": 0
          },
          {
            "id": "wifi:信号",
            "label": "Wi-Fi 信号",
            "status": "ok",
            "detail": "WLAN: SSID=Chen 信号=87% 频段/信道=802.11ax/48 收=138Mbps 发=1815Mbps —— 收 138Mbps / 发 1815Mbps 相差约 13.2 倍（发送远高于接收），可能是驱动或协商异常（省电模式、干扰、或驱动把速率协商错了）",
            "group": "WiFi 体检",
            "value": "SSID=Chen 信号=87% 频段/信道=802.11ax/48 收=138Mbps 发=1815Mbps",
            "ms": 102
          },
          {
            "id": "dns:优选",
            "label": "DNS 优选",
            "status": "ok",
            "detail": "当前设置的 DNS 排第 2 名（共 7 个测出结果），118ms vs 最快 106ms，差距不足以建议切换。223.5.5.5（阿里 DNS）=106ms  192.168.0.1（当前设置）=118ms  119.6.6.6（当前设置）=125ms  114.114.114.114（114 DNS）=139ms  119.29.29.29（腾讯 DNS）=144ms  1.1.1.1（Cloudflare）=269ms  8.8.8.8（Google DNS）=342ms；测试域名 www.baidu.com（各服务器各一次，-Server 查询不走系统缓存）",
            "group": "DNS 优选",
            "value": "最快=106 ms（223.5.5.5） 当前=118 ms",
            "ms": 1299
          }
        ],
        "meta": {
          "action": "scan",
          "verdict": "网络链路各环节正常",
          "firstFail": "",
          "online": true,
          "elapsedMs": 5157,
          "adapters": [
            {
              "name": "蓝牙网络连接",
              "description": "Bluetooth Device (Personal Area Network)",
              "status": "Disconnected",
              "linkSpeed": "3 Mbps",
              "mac": "5C-B4-7E-DD-04-6D",
              "virtual": false
            },
            {
              "name": "以太网",
              "description": "Realtek Gaming 2.5GbE Family Controller",
              "status": "Disconnected",
              "linkSpeed": "0 bps",
              "mac": "34-5A-60-4E-BA-73",
              "virtual": false
            },
            {
              "name": "WLAN",
              "description": "Intel(R) Wi-Fi 6E AX211 160MHz",
              "status": "Up",
              "linkSpeed": "1.8 Gbps",
              "mac": "5C-B4-7E-DD-04-69",
              "virtual": false
            }
          ],
          "ipConfig": [
            {
              "interface": "WLAN",
              "up": true,
              "addresses": [
                "192.168.0.105"
              ],
              "gateways": [
                "192.168.0.1"
              ],
              "dhcp": "Enabled",
              "apipa": false
            },
            {
              "interface": "蓝牙网络连接",
              "up": false,
              "addresses": [
                "169.254.127.184"
              ],
              "gateways": [],
              "dhcp": "Enabled",
              "apipa": false
            },
            {
              "interface": "以太网",
              "up": false,
              "addresses": [
                "169.254.168.255"
              ],
              "gateways": [],
              "dhcp": "Enabled",
              "apipa": false
            }
          ],
          "dnsServers": [
            "119.6.6.6",
            "192.168.0.1"
          ],
          "proxy": {
            "enabled": false,
            "server": "",
            "bypass": "",
            "autoConfig": ""
          },
          "winhttp": "Current WinHTTP proxy settings:\r\n\r\n    Direct access (no proxy server).",
          "hostsPath": "C:\\Windows\\System32\\drivers\\etc\\hosts",
          "hostsBlocked": 0,
          "hostsEntries": []
        }
      },
      '/result?id=perm': {
        "ok": true,
        "cached": false,
        "items": [
          {
            "id": "perm:consentstore",
            "group": "meta",
            "label": "权限记录规模",
            "status": "info",
            "value": "29 类 · 46 条应用级记录",
            "detail": "数据源 HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore；每条记录 = 某个应用在某一类权限上的 Allow/Deny 与最近使用时间",
            "fix": "",
            "needsAdmin": false
          },
          {
            "id": "perm:webcam-global",
            "group": "summary",
            "label": "摄像头/麦克风访问",
            "status": "warn",
            "value": "摄像头 1 个应用 · 麦克风 2 个应用",
            "detail": "摄像头 Allow：Microsoft.WindowsCamera_8wekyb3d8bbwe；麦克风 Allow：Microsoft.WindowsCamera_8wekyb3d8bbwe、Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe。这个数是「被明确授权」的应用数，不含已卸载但残留的记录。",
            "fix": "设置 > 隐私和安全性 > 摄像头/麦克风：把不用的应用逐个关掉（照相机类应用日常其实用不到常驻授权）",
            "needsAdmin": false
          },
          {
            "id": "perm:broadfs",
            "group": "summary",
            "label": "全盘文件访问权限",
            "status": "warn",
            "value": "0 个应用 · 全局 Allow",
            "detail": "全局开关是 Allow，但当前没有任何应用持有这条权限（HKCU 下 0 个应用子键）。也就是说门是开着的，只是还没人走进来——将来任何请求这项权限的应用只要被点过一次「允许」就直接生效。HKLM 侧：Allow。",
            "fix": "把全局开关改成拒绝（设置 > 隐私和安全性 > 文件系统），或至少确认没有陌生应用能自行申请",
            "needsAdmin": false
          },
          {
            "id": "perm:sensitive-top",
            "group": "summary",
            "label": "敏感权限 Top",
            "status": "warn",
            "value": "Top 3（共 3 条已授权敏感项）",
            "detail": "1) Microsoft.WindowsCamera_8wekyb3d8bbwe / webcam（摄像头）/ 最近 从未；2) Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe / microphone（麦克风）/ 最近 2026-06-14 13:47；3) Microsoft.WindowsCamera_8wekyb3d8bbwe / microphone（麦克风）/ 最近 从未",
            "fix": "按顺序看：排在前面的每一条都值得问一句「这个应用真的需要吗」。摄像头/麦克风/位置/全盘文件是四类最该收紧的权限。",
            "needsAdmin": false
          },
          {
            "id": "perm:top-1",
            "group": "sensitive",
            "label": "敏感授权 #1",
            "status": "bad",
            "value": "Microsoft.WindowsCamera_8wekyb3d8bbwe → 摄像头",
            "detail": "capability=webcam · 授权=Allow · 最近使用=从未 · 首次=从未 · Store/打包应用",
            "fix": "不需要就在设置里关掉",
            "needsAdmin": false
          },
          {
            "id": "perm:top-2",
            "group": "sensitive",
            "label": "敏感授权 #2",
            "status": "bad",
            "value": "Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe → 麦克风",
            "detail": "capability=microphone · 授权=Allow · 最近使用=2026-06-14 13:47 · 首次=2026-06-14 13:47 · Store/打包应用",
            "fix": "不需要就在设置里关掉",
            "needsAdmin": false
          },
          {
            "id": "perm:top-3",
            "group": "sensitive",
            "label": "敏感授权 #3",
            "status": "bad",
            "value": "Microsoft.WindowsCamera_8wekyb3d8bbwe → 麦克风",
            "detail": "capability=microphone · 授权=Allow · 最近使用=从未 · 首次=从未 · Store/打包应用",
            "fix": "不需要就在设置里关掉",
            "needsAdmin": false
          },
          {
            "id": "perm:app-c-program-files-x86-microsoft-edge-appli",
            "group": "apps",
            "label": "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
            "status": "info",
            "value": "残留记录（无 Value）",
            "detail": "麦克风[无值]；最近使用=2026-06-16 15:26；桌面程序",
            "fix": "",
            "needsAdmin": false
          }
        ],
        "meta": {
          "summary": {
            "total": 33,
            "ok": 0,
            "warn": 7,
            "bad": 3,
            "info": 23,
            "skip": 0
          }
        }
      },
      '/result?id=slim': {
        "ok": true,
        "cached": false,
        "items": [
          {
            "id": "slim:disk",
            "group": "磁盘",
            "label": "C 盘容量 / 可用",
            "status": "info",
            "value": "可用 165.21 GB / 总 302.03 GB",
            "detail": "已用 136.82 GB，可用率 54.7%。以下各项的回收价值以该可用量为参照。",
            "fix": "",
            "needsAdmin": false
          },
          {
            "id": "slim:hiberfil",
            "group": "休眠",
            "label": "hiberfil.sys（休眠镜像）",
            "status": "info",
            "value": "不存在（0 B）",
            "detail": "C:\\hiberfil.sys 不存在；HibernateEnabled=0 → 休眠已关闭，该项无可回收空间。",
            "fix": "无需处理。若要恢复休眠需管理员执行 powercfg /h on，会重新占用数 GB。",
            "needsAdmin": false
          },
          {
            "id": "slim:pagefile",
            "group": "虚拟内存",
            "label": "pagefile.sys（分页文件）",
            "status": "bad",
            "value": "48.83 GB",
            "detail": "实测 52428800000 bytes（48.83 GB）。AutomaticManagedPagefile=False（False=用户自定义大小，系统不会自己缩）；Win32_PageFileSetting: c:\\pagefile.sys 50000/50000 MB；注册表 PagingFiles: c:\\pagefile.sys 50000 50000；已分配 50000 MB / 当前用 689 MB / 峰值 6457 MB。该文件占用大但属于系统必需：不能直接删除，只能「缩小」或「迁到其它盘」。",
            "fix": "迁到其它盘（推荐 D 盘）：系统属性→高级→性能设置→高级→更改虚拟内存→取消「自动管理」→选中 C: 设为「无分页文件」→ 选中 D: 设为「自定义大小」（如初始/最大各 8192-16384 MB，按物理内存 1-1.5 倍）→ 设置→确定→重启生效。或命令行：wmic pagefileset where name=\"C:\\\\pagefile.sys\" set InitialSize=8192,MaximumSize=8192（需管理员，改完重启）。注意：完全关掉分页文件会让内存不足时程序直接崩溃，不建议；C 盘保留 1-2 GB 小块更稳。",
            "needsAdmin": true
          },
          {
            "id": "slim:restore",
            "group": "系统还原",
            "label": "系统还原占用",
            "status": "skip",
            "value": "未测量（需管理员）",
            "detail": "本机 Win32_ShadowStorage 与 Win32_ShadowCopy 均无法初始化，读不到 UsedSpace/MaxSpace：初始化失败 （ShadowCopy: 初始化失败 ）；还原点数量=不可枚举；DiskPercent=15。vssadmin list shadowstorage 同样提示需要提升的管理员权限。按用户核对的实际状态为「0 个还原点」，若确实为零则该项可回收 0 GB。",
            "fix": "以管理员身份运行 vssadmin list shadowstorage 查看实际占用；回收用 vssadmin delete shadows /for=C: /all /quiet（会删掉所有还原点，不可恢复）。",
            "needsAdmin": true
          },
          {
            "id": "slim:windowsold",
            "group": "升级残留",
            "label": "Windows.old",
            "status": "info",
            "value": "不存在（0 B）",
            "detail": "C:\\Windows.old 不存在，无升级残留可回收（目录不存在）；C:\\$Windows.~BT 存在 5 文件 14.9 KB；C:\\$Windows.~WS 存在 7 文件 216.3 KB。",
            "fix": "无需处理。",
            "needsAdmin": false
          },
          {
            "id": "slim:winsxs",
            "group": "组件存储",
            "label": "WinSxS（组件存储）",
            "status": "skip",
            "value": "未测量（需管理员）",
            "detail": "按要求不递归统计 C:\\Windows\\WinSxS：本机实测 Get-ChildItem -Recurse 在该目录取前 50 个文件就要 15.5s，全量 88982 文件 / 11.5 GB 耗时 15.2s，会让整个探针超时；且表观大小本身不可信（大量硬链接会重复计入）。真实可回收量必须用 DISM /Online /Cleanup-Image /AnalyzeComponentStore，该命令需要管理员权限。",
            "fix": "管理员执行：DISM /Online /Cleanup-Image /AnalyzeComponentStore 查看「可回收的组件存储」；确认后执行 DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase（ResetBase 后不能再卸载已安装更新）。",
            "needsAdmin": true
          }
        ],
        "meta": {
          "summary": {
            "total": 13,
            "ok": 1,
            "warn": 1,
            "bad": 1,
            "info": 8,
            "skip": 2
          }
        }
      },
    },
    mustShow: LANG === 'zh'
      ? ['360 工具箱', '清理与空间', '垃圾清理', '大文件查找', '用户临时文件']
      : ['360 Toolbox', 'Cleanup & space', 'Junk cleanup', 'Large files'],
    // Visible strings the interaction test clicks / looks for. Group and
    // capability names come from the host's /status, the form title from the
    // panel dictionary — both are what a user actually reads on screen.
    labels: LANG === 'zh'
      ? { networkGroup: '网络', dnsCap: '断网诊断', dnsFormTitle: '切换到这个 DNS' }
      : { networkGroup: 'Network', dnsCap: 'Adapter', dnsFormTitle: 'Switch to this DNS' },
  },

  'dsh-windows-plugin-manager': {
    ns: '/dsh-windows-plugin-manager/',
    // Captured from the live host on 2026-11-17 (11 sources / 2320 entries, real explain text).
    payloads: {
      '/status': {
  "ok": true,
  "name": "dsh-windows-plugin-manager",
  "version": "0.1.0",
  "host": {
    "interpreter": "pwsh (PS 7)",
    "elevated": false,
    "user": "26035",
    "os": "Microsoft Windows 10 专业版 (build 19045)"
  },
  "total": 2320,
  "elapsedMs": 0,
  "sources": [
    {
      "id": "svc",
      "label": "服务",
      "labelEn": "Services",
      "risk": "reversible",
      "actions": [
        "enable",
        "disable"
      ],
      "total": 272,
      "enabled": 108,
      "disabled": 164,
      "unknown": 0,
      "ms": 963,
      "at": 1794920069912,
      "stale": false,
      "error": "",
      "meta": {}
    },
    {
      "id": "task",
      "label": "计划任务",
      "labelEn": "Scheduled tasks",
      "risk": "reversible",
      "actions": [
        "enable",
        "disable"
      ],
      "total": 165,
      "enabled": 131,
      "disabled": 34,
      "unknown": 0,
      "ms": 1317,
      "at": 1794920071229,
      "stale": false,
      "error": "",
      "meta": {}
    },
    {
      "id": "autorun",
      "label": "开机自启",
      "labelEn": "Autostart",
      "risk": "reversible",
      "actions": [
        "enable",
        "disable"
      ],
      "total": 3,
      "enabled": 3,
      "disabled": 0,
      "unknown": 0,
      "ms": 754,
      "at": 1794920071983,
      "stale": false,
      "error": "",
      "meta": {}
    },
    {
      "id": "com",
      "label": "外壳扩展",
      "labelEn": "Shell extensions",
      "risk": "reversible",
      "actions": [
        "enable",
        "disable"
      ],
      "total": 78,
      "enabled": 78,
      "disabled": 0,
      "unknown": 0,
      "ms": 2342,
      "at": 1794920074325,
      "stale": false,
      "error": "",
      "meta": {
        "approvedCount": 36,
        "blockedCount": 0,
        "clsidCount": 7711
      }
    },
    {
      "id": "program",
      "label": "已安装程序",
      "labelEn": "Installed programs",
      "risk": "destructive",
      "actions": [],
      "total": 114,
      "enabled": 114,
      "disabled": 0,
      "unknown": 0,
      "ms": 599,
      "at": 1794920074924,
      "stale": false,
      "error": "",
      "meta": {
        "stubCount": 15
      }
    },
    {
      "id": "appx",
      "label": "AppX / MSIX",
      "labelEn": "AppX / MSIX",
      "risk": "destructive",
      "actions": [],
      "total": 100,
      "enabled": 100,
      "disabled": 0,
      "unknown": 0,
      "ms": 3983,
      "at": 1794920078907,
      "stale": false,
      "error": "",
      "meta": {
        "mode": "enumerated",
        "host": "7.6.10",
        "count": 100
      }
    },
    {
      "id": "drv",
      "label": "驱动",
      "labelEn": "Drivers",
      "risk": "destructive",
      "actions": [],
      "total": 418,
      "enabled": 45,
      "disabled": 205,
      "unknown": 168,
      "ms": 1699,
      "at": 1794920080606,
      "stale": false,
      "error": "",
      "meta": {
        "oemCount": 16
      }
    },
    {
      "id": "firewall",
      "label": "防火墙规则",
      "labelEn": "Firewall rules",
      "risk": "reversible",
      "actions": [
        "enable",
        "disable"
      ],
      "total": 542,
      "enabled": 343,
      "disabled": 199,
      "unknown": 0,
      "ms": 1107,
      "at": 1794920081713,
      "stale": false,
      "error": "",
      "meta": {}
    },
    {
      "id": "ifeo",
      "label": "IFEO 映像劫持",
      "labelEn": "IFEO image hijack",
      "risk": "readonly",
      "actions": [],
      "total": 86,
      "enabled": 86,
      "disabled": 0,
      "unknown": 0,
      "ms": 562,
      "at": 1794920082275,
      "stale": false,
      "error": "",
      "meta": {}
    },
    {
      "id": "fileexts",
      "label": "文件关联",
      "labelEn": "File associations",
      "risk": "readonly",
      "actions": [],
      "total": 520,
      "enabled": 163,
      "disabled": 357,
      "unknown": 0,
      "ms": 605,
      "at": 1794920082880,
      "stale": false,
      "error": "",
      "meta": {}
    },
    {
      "id": "credprov",
      "label": "凭据提供程序",
      "labelEn": "Credential providers",
      "risk": "readonly",
      "actions": [],
      "total": 22,
      "enabled": 22,
      "disabled": 0,
      "unknown": 0,
      "ms": 485,
      "at": 1794920083365,
      "stale": false,
      "error": "",
      "meta": {}
    }
  ]
},
      '/entries': {
  "ok": true,
  "total": 2320,
  "shown": 2,
  "rows": [
    {
      "id": "com:machine:HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\*\\shellex\\ContextMenuHandlers\\\u0001\u0001360Zip",
      "source": "com",
      "kind": "shellext",
      "name": "360Zip",
      "state": "",
      "enabled": true,
      "path": "D:\\Program Files (x86)\\360\\360zip\\360ZipExt64.dll",
      "version": "",
      "publisher": "",
      "scope": "machine",
      "view": "64",
      "risk": "reversible",
      "detail": {
        "source": "com",
        "kind": "shellext",
        "name": "360Zip",
        "rawName": "\u0001\u0001360Zip",
        "displayName": "360压缩文件类型",
        "clsid": "{9179176E-B763-3200-8500-BB1B90B3D5DE}",
        "rawValue": "",
        "handlerKind": "ContextMenuHandlers",
        "classRoot": "AllFiles",
        "scope": "machine",
        "view": "64",
        "server": "D:\\Program Files (x86)\\360\\360zip\\360ZipExt64.dll",
        "serverType": "InprocServer32",
        "inApproved": true,
        "approved": "360压缩 Shell Extension",
        "keyPath": "HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\*\\shellex\\ContextMenuHandlers\\\u0001\u0001360Zip",
        "dllDescription": "360ZipExt",
        "dllCompany": "360.cn"
      },
      "explain": {
        "kindLabel": "右键菜单扩展",
        "what": "一个外壳扩展。它不会自己运行，但会在资源管理器的菜单或属性对话框里增加一项。",
        "where": "在任意文件上右键时出现的菜单项",
        "purpose": "由「360ZipExt」提供，注册名是「360压缩文件类型」。",
        "ifOff": "关掉之后这一项菜单/选项卡会消失，功能本身不受影响。它是可以随时恢复的开关，不会卸载程序。",
        "origin": "thirdparty",
        "originName": "360.cn",
        "facts": [
          [
            "由哪个文件提供",
            "D:\\Program Files (x86)\\360\\360zip\\360ZipExt64.dll"
          ],
          [
            "CLSID",
            "{9179176E-B763-3200-8500-BB1B90B3D5DE}"
          ]
        ]
      }
    },
    {
      "id": "com:machine:HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\*\\shellex\\ContextMenuHandlers\\EPP",
      "source": "com",
      "kind": "shellext",
      "name": "EPP",
      "state": "",
      "enabled": true,
      "path": "C:\\Program Files\\Windows Defender\\shellext.dll",
      "version": "",
      "publisher": "",
      "scope": "machine",
      "view": "64",
      "risk": "reversible",
      "detail": {
        "source": "com",
        "kind": "shellext",
        "name": "EPP",
        "rawName": "EPP",
        "displayName": "",
        "clsid": "{09A47860-11B0-4DA5-AFA5-26D86198A780}",
        "rawValue": "",
        "handlerKind": "ContextMenuHandlers",
        "classRoot": "AllFiles",
        "scope": "machine",
        "view": "64",
        "server": "C:\\Program Files\\Windows Defender\\shellext.dll",
        "serverType": "InprocServer32",
        "inApproved": true,
        "approved": "EPP",
        "keyPath": "HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\*\\shellex\\ContextMenuHandlers\\EPP",
        "dllDescription": "Microsoft Security Client 外壳扩展",
        "dllCompany": "Microsoft Corporation"
      },
      "explain": {
        "kindLabel": "右键菜单扩展",
        "what": "一个外壳扩展。它不会自己运行，但会在资源管理器的菜单或属性对话框里增加一项。",
        "where": "在任意文件上右键时出现的菜单项",
        "purpose": "由「Microsoft Security Client 外壳扩展」提供。",
        "ifOff": "关掉之后这一项菜单/选项卡会消失，功能本身不受影响。它是可以随时恢复的开关，不会卸载程序。",
        "origin": "microsoft",
        "originName": "Microsoft Corporation",
        "facts": [
          [
            "由哪个文件提供",
            "C:\\Program Files\\Windows Defender\\shellext.dll"
          ],
          [
            "CLSID",
            "{09A47860-11B0-4DA5-AFA5-26D86198A780}"
          ]
        ]
      }
    }
  ]
},
    },
    mustShow: LANG === 'zh'
      ? ['Windows 插件化管理器', '防火墙', 'IFEO', '360Zip', '2320']
      : ['Windows Plugin Manager', 'Firewall', '360Zip'],
  },
};

/* --------------------------------------------------------------- fake host */

const registered = {};
const resolved = {};
const seen = new Set();
const mod = { id: null };
const fetchLog = [];

function lookup(path) {
  const cfg = FIXTURES[mod.id];
  if (!cfg) throw new Error(`no fixtures for module ${mod.id}`);
  // Longest prefix wins so '/result?id=junk' beats '/result'.
  const keys = Object.keys(cfg.payloads).filter((k) => path.includes(k)).sort((a, b) => b.length - a.length);
  return keys.length ? cfg.payloads[keys[0]] : { ok: true };
}

const sandbox = {
  window: {
    __ModuleLoader__: {
      load(spec) {
        mod.id = spec.id;
        mod.exports = spec.factory((name) => {
          if (name === 'react') return React;
          throw new Error(`unexpected require(${name})`);
        });
      },
    },
  },
  document: { baseURI: 'http://127.0.0.1:57469/' },
  URL, URLSearchParams,
  fetch: async (url, init) => {
    const path = String(url);
    fetchLog.push(`${init?.method ?? 'GET'} ${path}`);
    return { ok: true, status: 200, json: async () => lookup(path) };
  },
  console,
  setTimeout, clearTimeout, queueMicrotask,
  setInterval: () => 0, clearInterval: () => {}, requestAnimationFrame: () => 0,
  Promise, Set, Map, Error, JSON, Object, Array, Number, String, Boolean, Math, RegExp, Date,
  isNaN, parseInt, parseFloat, isFinite,
};

vm.createContext(sandbox);
vm.runInContext(src, sandbox, { filename: CLIENT });

if (!mod.exports) throw new Error('client.js did not call __ModuleLoader__.load');
if (!FIXTURES[mod.id]) throw new Error(`harness has no fixtures for ${mod.id} — add them before trusting a pass`);

const ctx = {
  effect(fn) { const off = fn(); return typeof off === 'function' ? off : () => {}; },
  locale: {
    register(ns, dict) {
      registered.ns = ns;
      const layer = dict?.[LANG] ?? dict;
      registered.dict = layer;
      Object.assign(resolved, layer);
    },
    // client.js does `t = ctx.locale.bind(NS)`, so THIS function is what the
    // panel really calls — the missing-key check has to live here.
    bind() {
      return (k) => {
        seen.add(k);
        const v = resolved[k];
        if (v === undefined) throw new Error(`missing dict key: ${k}`);
        return v;
      };
    },
  },
  theme: { token() { return ''; } },
  inject(names, fn) {
    const stub = {};
    for (const n of names) {
      stub[n] = n === 'layout'
        ? { selectPanel() {}, panelInfo: { getSnapshot: () => ({}) } }
        : {};
    }
    fn(stub);
  },
  slots: {
    inject(_name, fn) { fn(); return () => {}; },
    register(spec, render) {
      if (spec.name === 'main') registered.main = { spec, render };
      if (spec.name === 'sidebar.panellist') registered.sidebar = { spec, render };
      return () => {};
    },
  },
};

mod.exports.apply(ctx);

if (!registered.dict) throw new Error('no locale dictionary registered — apply() bailed out');
if (!registered.main) throw new Error('main slot not registered');
if (!registered.sidebar) throw new Error('sidebar.panellist slot not registered');

/* ------------------------------------------------------- mount + re-render */

const t = (k) => resolved[k] ?? k;  // client.js binds its own; this is a fallback

let tree = null;

/**
 * Render until nothing is dirty. Extracted so the test can also drive the panel
 * the way a user does — click a capability card, then settle again — instead of
 * only ever observing the default screen.
 */
async function settle() {
  for (let pass = 0; pass < MAX_PASSES; pass += 1) {
    visitOrder = 0;
    dirty = false;
    effects = [];
    tree = expand(registered.main.render({ t }), 0);
    if (process.env.TB360_DEBUG) console.error(`pass ${pass}: effects=${effects.length} dirty=${dirty}`);
    for (const fn of effects) fn();
    // Effects start promise chains (status → getJSON → fetch). Drain macrotasks so
    // every await in those chains resolves before deciding whether to re-render.
    for (let i = 0; i < 8; i += 1) await new Promise((r) => setTimeout(r, 0));
    if (process.env.TB360_DEBUG) console.error(`pass ${pass}: settled dirty=${dirty} fetch=${fetchLog.length}`);
    if (!dirty) break;
    if (pass === MAX_PASSES - 1) throw new Error(`panel never settled after ${MAX_PASSES} passes`);
  }
  return tree;
}

await settle();

/**
 * Find the first clickable node whose visible text contains `needle`, then fire
 * its onClick and settle. This is how the harness proves an interaction leads
 * somewhere — the previous version only ever checked the landing screen, which
 * is exactly how "the button is there but nothing is behind it" survived.
 */
function textOf(node) {
  if (node == null || node === false) return '';
  if (typeof node === 'string') return node;
  if (Array.isArray(node)) return node.map(textOf).join(' ');
  if (typeof node !== 'object') return '';
  if (!('type' in node)) return '';
  // expand() keeps children under props.children, not node.children.
  let out = textOf(node.props?.children);
  for (const [k, v] of Object.entries(node.props ?? {})) {
    if (k === 'style' || k === 'children' || /^on/.test(k)) continue;
    if (typeof v === 'string') out += ` ${v}`;
  }
  return out;
}

function findClickable(node, needle, acc = []) {
  if (node == null || node === false) return acc;
  if (Array.isArray(node)) { node.forEach((n) => findClickable(n, needle, acc)); return acc; }
  if (typeof node !== 'object' || !('type' in node)) return acc;
  const clickable = typeof node.props?.onClick === 'function';
  if (clickable && textOf(node).includes(needle)) acc.push(node);
  findClickable(node.props?.children, needle, acc);
  return acc;
}

async function clickText(needle) {
  const hits = findClickable(tree, needle);
  if (!hits.length && process.env.TB360_DEBUG) { const all = findClickable(tree, ''); console.error('CLICKABLES:', JSON.stringify(all.slice(0,12).map((n)=>textOf(n).slice(0,60)))); }
  if (!hits.length) throw new Error(`no clickable node mentions "${needle}" — the harness cannot reach that screen`);
  hits[0].props.onClick({ stopPropagation() {}, preventDefault() {} });
  await settle();
}

const sidebarGlyph = expand(registered.sidebar.render({ size: 16 }), 0);

/* --------------------------------------------------------------- validate */

const texts = [];
const badTypes = new Set();
const urls = [];
(function walk(node) {
  if (node == null || node === false) return;
  if (typeof node === 'string') { texts.push(node); return; }
  if (Array.isArray(node)) { node.forEach(walk); return; }
  if (typeof node !== 'object') return;
  if (!('type' in node)) return;  // style objects / plain prop values
  if (typeof node.type !== 'string' || !/^[a-z][a-z0-9]*$/.test(node.type)) badTypes.add(String(node.type));
  for (const [k, v] of Object.entries(node.props ?? {})) {
    if (k === 'style') continue;
    if (typeof v === 'function' && /^on[A-Z]/.test(k)) continue;
    walk(v);
    if (typeof v === 'string' && v.startsWith('/')) urls.push(v);
  }
}(tree));

if (badTypes.size) throw new Error(`non-HTML element types survived expansion: ${[...badTypes].join(', ')}`);

const joined = texts.join(' ');
if (/\uFFFD/.test(joined)) throw new Error('rendered text contains U+FFFD (mojibake)');
if (!texts.length) throw new Error('panel rendered no text at all');

const cfg = FIXTURES[mod.id];
const strayUrls = [...new Set(urls.filter((u) => u.startsWith('/') && !u.startsWith(cfg.ns)))];
if (strayUrls.length) throw new Error(`panel produced URLs outside ${cfg.ns}: ${strayUrls.join(', ')}`);

// The panel must paint real data, not just its chrome.
const absent = cfg.mustShow.filter((s) => !joined.includes(s));
if (process.env.TB360_DEBUG) {
  console.error('--- DEBUG ---');
  console.error('absent:', absent);
  console.error('fetch:', fetchLog);
  console.error('text:', joined.slice(0, 1200));
}
if (absent.length) throw new Error(`panel did not paint expected content: ${absent.join(' | ')}`);

if (!seen.size) throw new Error('panel never called t() — the dictionary check proved nothing');

/* ------------------------------------------------- user-driven interaction */
/**
 * Everything above only ever looks at the landing screen, which is exactly how
 * a control can exist and still be unreachable: the panel opens on 'junk', so
 * no other capability's UI was ever exercised. Drive it like a user — switch to
 * the network group, open the DNS capability, and assert the parameter form is
 * actually on screen with the values it is supposed to offer.
 */
let interaction = null;

if (mod.id === 'dsh-360-toolbox') {
  await clickText(cfg.labels.networkGroup);
  const afterGroup = textOf(tree);
  if (!afterGroup.includes(cfg.labels.dnsCap)) {
    throw new Error(`clicking the network group did not reach the DNS capability: ${afterGroup.slice(0, 240)}`);
  }

  // The scan result is served from the cache for this capability, so the panel
  // paints real rows before asking for anything.
  await clickText(cfg.labels.dnsCap);
  if (!fetchLog.some((line) => line.includes('/result?id=netdiag'))) {
    throw new Error('selecting the DNS capability never asked the host for its cached result');
  }

  const formText = textOf(tree);
  const missingDns = [
    cfg.labels.dnsFormTitle,   // "切换到这个 DNS" — the form's own heading
    '223.5.5.5',               // a candidate the panel must always offer
    '119.6.6.6',               // the resolver this machine actually uses
  ].filter((s) => !formText.includes(s));
  if (missingDns.length) {
    throw new Error(`DNS form is not usable on screen — missing ${missingDns.join(', ')}`);
  }

  interaction = { group: cfg.labels.networkGroup, capability: cfg.labels.dnsCap, formChars: formText.length };
}


console.log(JSON.stringify({
  ok: true,
  moduleId: mod.id,
  lang: LANG,
  slots: {
    main: registered.main.spec.key ?? null,
    sidebar: registered.sidebar.spec.id ?? null,
    order: registered.sidebar.spec.order ?? null,
    label: registered.sidebar.spec.label?.(),
    sidebarGlyph: sidebarGlyph?.type?.name ?? sidebarGlyph?.type ?? null,
  },
  dictKeysDefined: Object.keys(registered.dict).length,
  dictKeysUsed: seen.size,
  textNodes: texts.length,
  chars: joined.length,
  fetchCalls: [...new Set(fetchLog)],
  mustShowFound: cfg.mustShow.length,
  interaction,
  sample: joined.slice(0, 300),
}, null, 2));
