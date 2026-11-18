/**
 * sources.js - the registration points this plugin knows about.
 *
 * One entry per "place Windows loads something from". Each declares which probe
 * produces it, how its rows are named, what risk class it carries, and which
 * user-visible actions are legal on it.
 *
 * The five hooks every capability is described by (the plugin's core idea):
 *   detect   - read current state without changing anything
 *   enable   - turn it on
 *   disable  - turn it off, reversibly
 *   verify   - re-read to confirm the change landed
 *   rollback - undo a change using the value captured by detect
 *
 * This version ships detect for all eleven sources, enable/disable for the five
 * reversible ones (svc, task, autorun, com, firewall), and uninstall for the
 * three destructive ones (program, appx, drv). Uninstall is destructive by
 * definition, so those sources carry exactly one verb and the probe -- not the
 * UI -- decides per row whether that row may be removed (Microsoft-signed
 * driver packages and SystemComponent programs are refused there). The four
 * newer sources that carry no reliable reversible operation are marked readonly
 * with `actions: []`.
 *
 * WHICH registration points earned a slot is an evidence question, not a taste
 * question: docs/SCOPE.md records, for the eight candidates that were measured,
 * how many rows exist on this machine, what the enumeration costs, whether a
 * reversible toggle exists at all, and what breaks if the edit is wrong.
 */

/** Risk classes, ordered by how much they can hurt. */
export const RISK = {
  readonly: 'readonly',        // listing only; nothing can change
  reversible: 'reversible',    // has an enable/disable with a captured rollback
  destructive: 'destructive',  // removes something; not always undoable
  blocked: 'blocked',          // protected; the UI must refuse to act
};

/**
 * Services Windows needs to boot or to stay usable. Disabling any of these is a
 * "works until reboot, then doesn't" class of mistake, so they are reported as
 * risk=blocked and no action is offered.
 *
 * Kept deliberately short and mechanical: only names that are genuinely
 * load-bearing. A longer list would refuse legitimate cleanup.
 */
export const PROTECTED_SERVICES = new Set([
  'rpcss', 'rpcepmap', 'dcomlaunch', 'lsm', 'power', 'plugplay', 'bfe',
  'eventlog', 'profsvc', 'samss', 'winlogon', 'wuauserv', 'trustedinstaller',
  'msiserver', 'gpsvc', 'cryptsvc', 'dhcp', 'dnscache', 'nsi', 'netprofm',
  'nlasvc', 'lanmanworkstation', 'lanmanserver', 'wuauserv', 'windefend',
  'seclogon', 'sppsvc', 'themes', 'audiosrv', 'audioendpointbuilder',
  'brokerinfrastructure', 'systemeventsbroker', 'staterepository',
  'coremessaging', 'event system', 'devicesetupmanager',
]);

/** Publisher prefixes that mean "this is Microsoft's own component". */
const MS_PUBLISHERS = [
  'microsoft', 'microsoft corporation', 'microsoft windows',
  'microsoft®', 'windows',
];

/**
 * The registration points, in the order the panel shows them.
 *
 * `probe` is the file name under lib/probes/. `shape` says how to read that
 * probe's JSON:
 *   array  - the whole payload is the row list
 *   rows   - payload.rows is the row list
 *   multi  - payload has several row lists; `lists` names them
 */
export const SOURCES = [
  {
    id: 'svc',
    label: '服务',
    labelEn: 'Services',
    probe: 'svc.ps1',
    shape: 'array',
    risk: RISK.reversible,
    actions: ['enable', 'disable'],
    // Windows services in this state can be changed without a reboot.
    description: 'Windows 服务（HKLM\\SYSTEM\\CurrentControlSet\\Services + SCM）',
  },
  {
    id: 'task',
    label: '计划任务',
    labelEn: 'Scheduled tasks',
    probe: 'task.ps1',
    shape: 'array',
    risk: RISK.reversible,
    actions: ['enable', 'disable'],
    description: '任务计划程序（\\Windows\\System32\\Tasks + Task Scheduler 服务）',
  },
  {
    id: 'autorun',
    label: '开机自启',
    labelEn: 'Autostart',
    probe: 'autorun.ps1',
    shape: 'array',
    risk: RISK.reversible,
    actions: ['enable', 'disable'],
    // Six mechanisms, because a startup manager that shows one of them is not a
    // startup manager: this box has 2 Run values and 136 things that actually
    // start (61 auto services, 37 logon/boot tasks, 36 Active Setup stubs).
    description: '开机会自动运行的东西：Run/RunOnce 十处注册表项、启动文件夹、UWP StartupTask、登录/开机触发的计划任务、自动启动的服务、Active Setup',
  },
  {
    id: 'com',
    label: '外壳扩展',
    labelEn: 'Shell extensions',
    probe: 'com.ps1',
    shape: 'rows',
    risk: RISK.reversible,
    actions: ['enable', 'disable'],
    description: '右键菜单 / 属性页 / 拖放处理程序 + Shell Extensions\\Approved 白名单',
  },
  {
    id: 'program',
    label: '已安装程序',
    labelEn: 'Installed programs',
    probe: 'program.ps1',
    shape: 'rows',
    risk: RISK.destructive,
    // `uninstall` is the only verb here: a program has no enabled/disabled
    // state. actions.ps1 refuses enable/disable for it and points at uninstall.
    actions: ['uninstall'],
    description: '卸载注册表（HKLM 64/32 位 + HKCU）里的 Add/Remove Programs 条目',
  },
  {
    id: 'appx',
    label: 'AppX / MSIX',
    labelEn: 'AppX / MSIX',
    probe: 'appx.ps1',
    shape: 'rows',
    risk: RISK.destructive,
    actions: ['uninstall'],
    description: '打包应用（Get-AppxPackage；PS7 下经 Windows PowerShell 桥接）',
  },
  {
    id: 'drv',
    label: '驱动',
    labelEn: 'Drivers',
    probe: 'driver.ps1',
    shape: 'multi',
    lists: [
      { key: 'packages', label: '驱动包', labelEn: 'Driver packages' },
      { key: 'devices', label: '已绑定设备', labelEn: 'Bound devices' },
    ],
    risk: RISK.destructive,
    // Only third-party oemNN.inf packages actually uninstall; the probe decides
    // per package (Microsoft-signed ones are refused there, not here).
    actions: ['uninstall'],
    description: '驱动存储（HKLM\\SYSTEM\\DriverDatabase）+ 已绑定设备（Win32_PnPSignedDriver）',
  },
  {
    id: 'firewall',
    label: '防火墙规则',
    labelEn: 'Firewall rules',
    probe: 'firewall.ps1',
    shape: 'array',
    risk: RISK.reversible,
    actions: ['enable', 'disable'],
    description: 'Windows 防火墙入站/出站规则（HNetCfg.FwPolicy2 COM；启停通过规则 Enabled 属性）',
  },
  {
    id: 'ifeo',
    label: 'IFEO 映像劫持',
    labelEn: 'IFEO image hijack',
    probe: 'ifeo.ps1',
    shape: 'array',
    // Read-only by nature: writing a Debugger value IS the attack, so the panel
    // reports hijacks instead of offering to create one. riskOf() upgrades any
    // row that has a Debugger value to blocked, which sorts it to the top.
    risk: RISK.readonly,
    actions: [],
    description: '映像文件执行选项（HKLM\\...\\Image File Execution Options，64/32 位视图）：检测 Debugger 劫持',
  },
  {
    id: 'fileexts',
    label: '文件关联',
    labelEn: 'File associations',
    probe: 'fileexts.ps1',
    shape: 'array',
    // No reversible toggle exists: UserChoice is guarded by an HMAC (Hash) over
    // progid+user+sid, so writing a different Progid is silently reverted by
    // Windows unless that hash is recomputed. Reported as a read-only column
    // rather than faking enable/disable buttons.
    risk: RISK.readonly,
    actions: [],
    description: '每用户文件类型关联（HKCU\\...\\Explorer\\FileExts：UserChoice / OpenWithProgids / OpenWithList）',
  },
  {
    id: 'credprov',
    label: '凭据提供程序',
    labelEn: 'Credential providers',
    probe: 'credprov.ps1',
    shape: 'array',
    // Removing a provider changes how you sign in - a lockout risk - and
    // registration is not a boolean. Detection only.
    risk: RISK.readonly,
    actions: [],
    description: '登录界面凭据提供程序（HKLM\\...\\Authentication\\Credential Providers + InprocServer32 DLL）',
  },
  {
    id: 'repair',
    label: '系统修复',
    labelEn: 'System repair',
    probe: 'repair.ps1',
    // repair.ps1 answers with {ok,count,items[],summary,action,dryRun,...} - the
    // featurelib envelope. Its row list lives under `items`, so this source
    // needs the `items` shape; `rows`/`multi` would read nothing or, worse,
    // pick up the `ids` parameter array as a row list.
    shape: 'items',
    // Each row is a configuration-drift finding, not a registration point, so
    // there is nothing to switch on or off: enable/disable would have to be
    // faked. The fix is a block-level operation (POST /api/repair) that runs
    // assert -> detect -> fix per finding, so per-row actions stay empty.
    risk: RISK.readonly,
    actions: [],
    description: '八项配置漂移检查（hosts / IE 主页 / DNS / 连接数 / UAC / 冗余注册表项 / 字体缓存 / 图标缓存）',
  },
];

/** Lookup by id. */
export const SOURCE_BY_ID = new Map(SOURCES.map((s) => [s.id, s]));

/**
 * Does this service binary look like a kernel driver?
 *
 * Written as an explicit alternation because the obvious `/drv|kernel/i` does
 * NOT match the word "drivers" ("drv" is not a substring of "drivers") — it
 * silently let every kernel driver through as reversible, caught by
 * tests/run-all.mjs on 2026-11-17.
 */
const KERNEL_PATH = /\\drivers\\|\.sys\b/i;

/**
 * Risk for one normalized entry: the source default, downgraded for protected
 * and Microsoft-owned components.
 */
export function riskOf(source, entry) {
  if (source.id === 'svc' && PROTECTED_SERVICES.has(String(entry.name).toLowerCase())) {
    return RISK.blocked;
  }
  // The autostart view reports services and logon tasks as well as Run values,
  // so the same refusals have to apply there. Otherwise the 61 service rows in
  // the startup list would look switchable while the identical rows in the
  // service list are marked protected -- and clicking one would come back with
  // "拒绝操作受保护服务" from actions.ps1 after the user already agreed to a UAC.
  if (source.id === 'autorun' && String(entry.detail?.where ?? '') === 'ref-service') {
    if (PROTECTED_SERVICES.has(String(entry.name).toLowerCase())) return RISK.blocked;
    // DoService refuses a kernel driver outright (no AcceptStop on drivers, and
    // stopping one can bugcheck the box), so the row must not offer a toggle.
    if (KERNEL_PATH.test(String(entry.detail?.path ?? ''))) return RISK.blocked;
  }
  if (source.id === 'autorun' && String(entry.detail?.where ?? '') === 'activesetup') {
    // Not switchable at all (see autorun.ps1 / actions.ps1): reporting it as
    // reversible would put a toggle on screen that can only fail.
    return RISK.readonly;
  }
  if (source.id === 'svc' && entry.detail?.acceptStop === false && KERNEL_PATH.test(String(entry.detail?.path ?? ''))) {
    // Kernel-mode service: stopping it can bugcheck the box.
    return RISK.blocked;
  }
  if (source.id === 'ifeo' && entry.detail?.hijacked) {
    // A Debugger value under IFEO means "launch this instead of that program".
    // There is no legitimate reason for it to be there on a normal machine, so
    // the row is promoted to blocked: it sorts above every actionable row, the
    // UI shows it in the "look at this first" colour, and no action is offered
    // (activating a debugger is the attack itself, not a fix).
    return RISK.blocked;
  }
  return source.risk;
}

/** True when the publisher looks like Microsoft itself. */
export function isMicrosoft(publisher) {
  const p = String(publisher ?? '').toLowerCase().trim();
  if (!p) return false;
  return MS_PUBLISHERS.some((m) => p.startsWith(m));
}
