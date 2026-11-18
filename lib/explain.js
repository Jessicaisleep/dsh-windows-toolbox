/**
 * explain.js - turn a raw registration-point row into something a non-technical
 * user can act on.
 *
 * THE PROBLEM
 * -----------
 * The inventory was built for someone who already knows what
 * {55B3A0BD-4D28-42fe-8CFB-FA3EDFF969B8} is. That CLSID is the ReadyBoost tab in
 * a drive's Properties dialog; the panel showed the GUID and nothing else. The
 * user's complaint was exact: "只给原始名字，给原始注册表，但是这玩意是干嘛的？
 * 什么作用？" A management UI that cannot answer "what does this do" is not usable
 * by anyone who is not already a Windows internals developer.
 *
 * THE SECOND COMPLAINT
 * --------------------
 * The first fix answered "what kind of thing is this" from a fixed table keyed by
 * source, so every service on the machine got the SAME sentence: a Manual +
 * Stopped helper like `ALG` was called "它在 Windows 启动时自动运行". Two bugs in
 * one: the cards were unreadable (满屏都是同一句话) and the sentence contradicted
 * the row's own measured state.
 *
 * So every sentence below is now composed from THAT ROW's own fields:
 *
 *   svc        description (267/272 rows carry one) + startMode + state
 *   task       description + triggers + taskEnabled + actionDisabled + executables
 *   program    version + publisher + installLocation + uninstall + installDate + sizeKb
 *   firewall   direction + action + protocol + ports + profiles + program/group
 *   com        classRoot+handlerKind placement + DLL FileDescription + company + approved
 *   appx       version + arch + publisher CN + nonRemovable/isFramework + signatureKind
 *   drv        infName + provider + version + bound + device class/date
 *   fileexts   extension + state + progId + command + "open with" candidates
 *   ifeo       exe + debugger/hijacked + mitigation/cfg/globalflag
 *   autorun    the command line itself + scope + where
 *   credprov   the provider's own label + DLL + whether the DLL is in System32
 *   repair     the check's own id (hosts / ie / dns / …) + measured text + verdict
 *
 * Two rules hold everywhere:
 *
 *   1. Nothing may contradict `detail`. "自动启动" is only said when startMode
 *      really is Auto. A disabled task is never described as "会按时运行".
 *   2. If a field cannot be derived it stays null (and the UI omits the line).
 *      Unresolved resource strings (`@%SystemRoot%\…`, `$(@…,-702)`) and raw
 *      hashes are treated as "no data", never printed.
 */

/** Human name for each source. Only the kind label is shared now - the
 *  sentences are built per row further down. */
const SOURCE_KIND = {
  svc: { zh: '后台服务', en: 'Background service' },
  task: { zh: '计划任务', en: 'Scheduled task' },
  autorun: { zh: '开机自启', en: 'Startup entry' },
  com: { zh: '右键菜单扩展', en: 'Shell extension' },
  program: { zh: '已安装软件', en: 'Installed program' },
  appx: { zh: '商店应用', en: 'Store app' },
  drv: { zh: '驱动程序', en: 'Driver package' },
  firewall: { zh: '防火墙规则', en: 'Firewall rule' },
  ifeo: { zh: 'IFEO 映像劫持检测', en: 'IFEO image hijack check' },
  fileexts: { zh: '文件关联', en: 'File association' },
  credprov: { zh: '凭据提供程序', en: 'Credential provider' },
  repair: { zh: '系统修复项', en: 'System repair check' },
};

/**
 * Where a shell extension shows up, keyed by "<classRoot>|<handlerKind>".
 *
 * This is the whole point of the exercise for the ready-made GUID complaint:
 * `Drive|PropertySheetHandlers` means "drive Properties dialog, one extra tab",
 * not "some registry key". The set is closed - 16 combinations measured.
 */
const SHELLX_PLACEMENT = {
  'AllFiles|ContextMenuHandlers': {
    zh: '在任意文件上右键时出现的菜单项',
    en: 'an item on the right-click menu of any file',
  },
  'AllFiles|PropertySheetHandlers': {
    zh: '文件「属性」对话框里多出来的一页',
    en: 'an extra tab in the Properties dialog of any file',
  },
  'AllFilesystemObjects|ContextMenuHandlers': {
    zh: '在文件或文件夹上右键时出现的菜单项',
    en: 'an item on the right-click menu of files and folders',
  },
  'AllFilesystemObjects|PropertySheetHandlers': {
    zh: '文件和文件夹「属性」对话框里多出来的一页',
    en: 'an extra tab in the Properties dialog of files and folders',
  },
  'Directory|ContextMenuHandlers': {
    zh: '在文件夹上右键时出现的菜单项',
    en: 'an item on the right-click menu of folders',
  },
  'Directory|PropertySheetHandlers': {
    zh: '文件夹「属性」对话框里多出来的一页',
    en: 'an extra tab in a folder\'s Properties dialog',
  },
  'DirectoryBackground|ContextMenuHandlers': {
    zh: '在文件夹空白处右键时出现的菜单项',
    en: 'an item on the right-click menu of a folder\'s empty background',
  },
  'Folder|ContextMenuHandlers': {
    zh: '在文件夹上右键时出现的菜单项',
    en: 'an item on the right-click menu of folders',
  },
  'Folder|PropertySheetHandlers': {
    zh: '文件夹「属性」对话框里多出来的一页',
    en: 'an extra tab in a folder\'s Properties dialog',
  },
  'Folder|DragDropHandlers': {
    zh: '把文件拖到文件夹上时接管这次拖放行为',
    en: 'takes over when you drag files onto a folder',
  },
  'Directory|DragDropHandlers': {
    zh: '把文件拖到文件夹上时接管这次拖放行为',
    en: 'takes over when you drag files onto a folder',
  },
  'Directory|CopyHookHandlers': {
    zh: '在复制、移动或重命名文件夹时介入（通常无界面）',
    en: 'steps in when a folder is copied, moved or renamed (usually no UI)',
  },
  'Drive|ContextMenuHandlers': {
    zh: '在磁盘驱动器上右键时出现的菜单项',
    en: 'an item on the right-click menu of a drive',
  },
  'Drive|PropertySheetHandlers': {
    zh: '驱动器「属性」对话框里多出来的一页',
    en: 'an extra tab in a drive\'s Properties dialog',
  },
  'LibraryFolder|ContextMenuHandlers': {
    zh: '在库文件夹上右键时出现的菜单项',
    en: 'an item on the right-click menu of a library folder',
  },
  'LibraryFolder|PropertySheetHandlers': {
    zh: '库文件夹「属性」对话框里多出来的一页',
    en: 'an extra tab in a library folder\'s Properties dialog',
  },
};

/**
 * Plain-language gloss for the handler kinds, used when the exact
 * classRoot+kind pair is not in the table (a machine with an unusual root).
 */
const HANDLER_KIND_GLOSS = {
  ContextMenuHandlers: { zh: '右键菜单项', en: 'right-click menu item' },
  PropertySheetHandlers: { zh: '「属性」对话框里的一页', en: 'a Properties dialog tab' },
  DragDropHandlers: { zh: '拖放行为的接管者', en: 'a drag-and-drop handler' },
  CopyHookHandlers: { zh: '复制/移动/重命名时的拦截器', en: 'a copy/move/rename hook' },
};

/**
 * The concrete page or menu label a shell extension puts on screen.
 *
 * SHELLX_PLACEMENT above only says WHERE a kind of handler lands ("an extra tab
 * in a folder's Properties dialog"). That is not an answer a user can act on:
 * every PropertySheetHandlers row on this machine then reads identically. This
 * table names the actual thing you see, keyed by CLSID.
 *
 * Evidence for each row (not guesses):
 *  - PageTitle is read from the CLSID when Windows publishes it, and resolved
 *    through SHLoadIndirectString - that is the literal tab caption. Those come
 *    from the probe as `pageTitleText` and are used ahead of this table.
 *  - The rest are the string the handler's own MUI file carries for its tab or
 *    menu caption, cross-checked against the handler's registered name.
 */
const SHELLX_ITEM_LABEL = {
  // --- Properties dialog pages -------------------------------------------
  '{4a7ded0a-ad25-11d0-98a8-0800361b1103}': {
    // mydocs.dll / "MyFolder menu and properties". zh-CN\mydocs.dll.mui carries
    // the caption 位置 and the body "你可以将此文件夹中文件存储的位置更改为…".
    zh: '位置',
    en: 'Location',
  },
  '{ef43ecfe-2ab9-4632-bf21-58909dd177f0}': {
    // shell32.dll / "Folder Customization Tab" - the tab with 文件夹图片 and
    // 更改图标, captioned 自定义 in shell32.dll.mui.
    zh: '自定义',
    en: 'Customize',
  },
  '{1f2e5c40-9550-11ce-99d2-00aa006e086c}': {
    // rshx32.dll / "Security Shell Extension" - the NTFS permission editor,
    // captioned 安全 in rshx32.dll.mui.
    zh: '安全',
    en: 'Security',
  },
  '{883373c3-bf89-11d1-be35-080036b11a03}': {
    // "Summary Properties Page". The probe reports shell32.dll as the server on
    // this machine; docprop.dll.mui is where the caption 摘要 lives.
    zh: '摘要',
    en: 'Summary',
  },
  '{3ea48300-8cf6-101b-84fb-666ccb9bcd32}': {
    // docprop.dll / "OLE Docfile Property Page" - the generic document property
    // sheet; docprop.dll.mui captions it 常规.
    zh: '常规',
    en: 'General',
  },
  '{55b3a0bd-4d28-42fe-8cfb-fa3edff969b8}': {
    // rdbui.dll / "ReadyBoost UI" - the ReadyBoost tab on a drive.
    zh: 'ReadyBoost',
    en: 'ReadyBoost',
  },
  '{7988b573-ec89-11cf-9c00-00aa00a14f56}': {
    // dskquoui.dll / "Microsoft Disk Quota UI". dskquoui.dll.mui captions it 配额.
    zh: '配额（磁盘配额）',
    en: 'Quota (disk quotas)',
  },
  '{eccdf543-45cc-11ce-b9bf-0080c87cdba6}': {
    // DfsShlEx.dll / "DfsShell Class" - the DFS tab showing 路径/活动/状态.
    zh: 'DFS（显示这个位置的分布式文件系统状态）',
    en: 'DFS (distributed file system status)',
  },
  '{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}|PropertySheetHandlers': {
    // ntshrui.dll / "Shell extensions for sharing" - ntshrui.dll.mui captions
    // this sheet 共享, and the page shows 高级共享 / 新建共享.
    zh: '共享',
    en: 'Sharing',
  },
  '{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}|ContextMenuHandlers': {
    // Same DLL, but the menu surface: sharing commands, not a tab.
    zh: '共享相关的几项',
    en: 'sharing commands',
  },
  '{748f920f-fb24-4d09-b360-baf6f199ad6d}': {
    // srmshell.dll / "FCI Properties Property Page Class" - file server
    // resource manager classification tab.
    zh: '分类（文件服务器资源管理器的分类属性）',
    en: 'Classification (file server resource manager)',
  },
  '{7444c719-39bf-11d1-8cd9-00c04fc29d45}': {
    // cryptext.dll / "CryptSig Class" - the digital signatures tab.
    zh: '数字签名',
    en: 'Digital Signatures',
  },
  '{7efa68c6-086b-43e1-a2d2-55a113531240}': {
    // cscui.dll - offline files. cscui.dll.mui carries 脱机文件 as a page caption.
    zh: '脱机文件',
    en: 'Offline Files',
  },
  '{5f5295e0-429f-1069-a2e2-08002b30309d}': {
    // shell32.dll / "Drive Property Page Extension" - adds hardware info and the
    // tool buttons to the drive's existing 常规 page rather than a new tab.
    zh: '常规（补充硬件信息与工具按钮）',
    en: 'General (extra hardware info and tool buttons)',
  },
  '{fbeb8a05-beee-4442-804e-409d6c4515e9}': {
    // shell32.dll / "ShellFolder for CD Burning" - the recording tab on a
    // CD/DVD drive.
    zh: '录制（仅在可写光驱上出现）',
    en: 'Recording (only on a writable optical drive)',
  },
  '{66275315-bfa5-451b-88b6-e56ebc8d9b58}': {
    // shell32.dll / "Library Property Handler" - the library's own properties.
    zh: '库属性',
    en: 'library properties',
  },
  // --- Right-click menu items --------------------------------------------
  '{a2a9545d-a0c2-42b4-9708-a0b2badd77c8}': {
    // shell32.dll / "Start Menu Pin", ImplementsVerbs=startpin;startunpin.
    zh: '固定到开始屏幕 / 从开始屏幕取消固定',
    en: 'Pin to Start / Unpin from Start',
  },
  '{90aa3a4e-1cba-4233-b8bb-535773d48449}': {
    // shell32.dll / "Taskband Pin", ImplementsVerbs=taskbarpin;taskbarunpin.
    zh: '固定到任务栏 / 从任务栏取消固定',
    en: 'Pin to taskbar / Unpin from taskbar',
  },
  '{474c98ee-cf3d-41f5-80e3-4aab0ab04301}': {
    // cscui.dll / offline files. On files+folders this is the context menu;
    // cscui.dll.mui carries 脱机文件 as the caption.
    zh: '始终脱机可用',
    en: 'Always available offline',
  },
  '{a470f8cf-a1e8-4f65-8335-227475aa5c46}': {
    // shell32.dll / "Encryption Context Menu" - EFS encrypt/decrypt.
    zh: '加密 / 解密（EFS 文件加密）',
    en: 'Encrypt / Decrypt (EFS file encryption)',
  },
  '{09799afb-ad67-11d1-abcd-00c04fc30936}': {
    // shell32.dll / "Open With Context Menu Handler".
    zh: '打开方式',
    en: 'Open with',
  },
  '{f3d06e7c-1e45-4a26-847e-f9fcdee59be0}': {
    // shell32.dll / "Copy as Path Menu".
    zh: '复制文件地址（Shift+右键出现）',
    en: 'Copy as path (Shift+right-click)',
  },
  '{7ba4c740-9e81-11cf-99d3-00aa004ae837}': {
    // shell32.dll / "Microsoft SendTo Service" - the 发送到 submenu.
    zh: '发送到子菜单',
    en: 'Send to submenu',
  },
  '{d969a300-e7ff-11d0-a93b-00a0c90f2719}': {
    // shell32.dll / "New Menu Handler" - the 新建 submenu on folder background.
    zh: '新建子菜单',
    en: 'New submenu',
  },
  '{3dad6c5d-2167-4cae-9914-f99e41c12cfa}': {
    // shell32.dll / "Include In Library Sub Context Menu".
    zh: '包含到库中子菜单',
    en: 'Include in library submenu',
  },
  '{470c0ebd-5d73-4d58-9ced-e91e22e23282}': {
    // appresolver.dll / "Pin To Start Screen verb handler".
    zh: '固定到开始屏幕',
    en: 'Pin to Start',
  },
  '{0af96ede-aebf-41ed-a1c8-cf7a685505b6}': {
    // shell32.dll / "Library Folder Context Menu".
    zh: '管理库等几项',
    en: 'library menu items (Manage library)',
  },
  '{d6791a63-e7e2-4fee-bf52-5dED8E86E9B8}': {
    // wpdshext.dll / "Portable Devices Menu" - eject/sync entries for a device.
    zh: '便携设备相关的几项（弹出、同步等）',
    en: 'portable-device items (eject, sync)',
  },
  '{2854f705-3548-414c-a113-93e27c808c85}': {
    // EhStorShell.dll / "Enhanced Storage Context Menu Handler Class".
    zh: '增强存储设备相关的几项',
    en: 'enhanced-storage items',
  },
  '{e2bf9676-5f8f-435c-97eb-11607a5bedf7}': {
    // ntshrui.dll / "Ribbon Modern Share Verb".
    zh: '共享（现代共享面板）',
    en: 'Share (modern share UI)',
  },
  '{3d1975af-48c6-4f8e-a182-be0e08fa86a9}': {
    // nvshext.dll / "NVIDIA CPL Context Menu Extension".
    zh: 'NVIDIA 控制面板那几项',
    en: 'NVIDIA Control Panel items',
  },
};

/**
 * What an ImplementsVerbs entry puts into the menu, phrased as the MENU ITEM
 * itself (not as a sentence). These names are what the user sees when they
 * right-click, which is the whole point: the complaint that started this was
 * "it says it adds one entry to the right-click menu but never says which one".
 */
const VERB_GLOSS = {
  startpin: { zh: '固定到开始屏幕', en: 'Pin to Start' },
  startunpin: { zh: '从开始屏幕取消固定', en: 'Unpin from Start' },
  taskbarpin: { zh: '固定到任务栏', en: 'Pin to taskbar' },
  taskbarunpin: { zh: '从任务栏取消固定', en: 'Unpin from taskbar' },
  open: { zh: '打开', en: 'Open' },
  print: { zh: '打印', en: 'Print' },
  edit: { zh: '编辑', en: 'Edit' },
  runas: { zh: '以管理员身份运行', en: 'Run as administrator' },
};

/**
 * Service start types. `short` is what goes on the card face (one clause);
 * `long` explains what that start type means for the user.
 */
const START_MODE = {
  auto: {
    short: { zh: '自动启动', en: 'starts automatically' },
    long: {
      zh: '它是「自动」启动：Windows 开机时自己把它拉起来，不需要谁去点它',
      en: 'It is set to Automatic, so Windows starts it by itself at boot',
    },
  },
  automatic: { same: 'auto' },
  manual: {
    short: { zh: '手动启动（被请求时才跑）', en: 'starts only when asked' },
    long: {
      zh: '它是「手动」启动：平时并不运行，只有别的程序或系统组件请求时才启动',
      en: 'It is set to Manual: it does not run on its own, only when a program or system component asks for it',
    },
  },
  manualtrigger: {
    short: { zh: '手动（触发）启动', en: 'trigger start' },
    long: {
      zh: '它是「手动（触发）」启动：只有被特定的系统事件触发时才启动',
      en: 'It is a trigger-start service: it only starts when a specific system event fires',
    },
  },
  disabled: {
    short: { zh: '已禁用（不会被启动）', en: 'disabled' },
    long: {
      zh: '它已被禁用：即使有程序请求，Windows 也不会启动它',
      en: 'It is disabled: Windows will not start it even when a program asks',
    },
  },
  boot: {
    short: { zh: '随内核加载', en: 'loads with the kernel' },
    long: {
      zh: '它随内核一起加载，比普通服务启动得更早',
      en: 'It loads with the kernel, earlier than ordinary services',
    },
  },
  system: {
    short: { zh: '随系统加载', en: 'loads with the system' },
    long: {
      zh: '它由系统在启动早期加载',
      en: 'It is loaded by the system during early boot',
    },
  },
};

/** Task trigger kinds as the probe reports them, lowercased. */
const TRIGGER_GLOSS = {
  boottrigger: { zh: '开机时', en: 'at boot' },
  logontrigger: { zh: '用户登录时', en: 'when a user signs in' },
  logofftrigger: { zh: '用户注销时', en: 'when a user signs out' },
  timetrigger: { zh: '在登记的某个时刻', en: 'at a registered time' },
  dailytrigger: { zh: '每天一次', en: 'once a day' },
  weeklytrigger: { zh: '每周一次', en: 'once a week' },
  monthlytrigger: { zh: '每月一次', en: 'once a month' },
  monthlydowtrigger: { zh: '每月指定的星期', en: 'a given weekday each month' },
  eventtrigger: { zh: '某个系统事件发生时', en: 'when a system event occurs' },
  idletrigger: { zh: '电脑空闲时', en: 'when the PC goes idle' },
  sessionstatechangetrigger: { zh: '会话连接或断开时', en: 'when a session connects or disconnects' },
  registrationtrigger: { zh: '任务被注册时', en: 'when the task is registered' },
  registration: { zh: '任务被注册时', en: 'when the task is registered' },
  trigger: { zh: '任务里登记的触发条件（没有细分类型）', en: 'a trigger registered on the task (no specific type)' },
};

/** Firewall profile strings as the probe reports them (Chinese MUI). */
const PROFILE_EN = {
  '全部': 'All',
  '域': 'Domain',
  '专用': 'Private',
  '公用': 'Public',
  '域/专用/公用': 'Domain/Private/Public',
  '专用/公用': 'Private/Public',
  '域/专用': 'Domain/Private',
};

/** What each repair check is actually looking for, keyed by check id. */
const CHECK_WHAT = {
  hosts: {
    zh: '检查 hosts 文件里有没有被塞进「把某个域名指到别处」的条目',
    en: 'Looks for entries in the hosts file that point a domain somewhere else',
  },
  ie: {
    zh: '检查 IE 的主页（Start Page）和搜索页（Search Page）有没有被改成推广地址',
    en: 'Checks whether Internet Explorer\'s home page and search page were rewritten to a promo address',
  },
  dns: {
    zh: '检查有没有网卡的 DNS 被改成了静态地址，而不是用 DHCP 下发的',
    en: 'Checks whether any adapter got static DNS servers instead of DHCP-provided ones',
  },
  netconn: {
    zh: '检查 TCP 连接数相关的隐藏调优值有没有被第三方「加速」工具改写',
    en: 'Checks whether hidden TCP connection-count tweaks were rewritten by a third-party "optimizer"',
  },
  uac: {
    zh: '检查 UAC 的三个核心值（EnableLUA / ConsentPromptBehaviorAdmin / PromptOnSecureDesktop）还在不在默认档位',
    en: 'Checks whether the three core UAC values are still at their default levels',
  },
  redundant: {
    zh: '检查启动项和卸载项里有没有指向已不存在文件的「死路径」',
    en: 'Checks startup and uninstall entries for dead paths that point at files that no longer exist',
  },
  fontcache: {
    zh: '检查字体缓存目录占多大、有没有冲突文件（这个目录只有 LocalService 读得动）',
    en: 'Measures the font cache and looks for conflicting files (only LocalService may read that directory)',
  },
  iconcache: {
    zh: '检查图标缓存文件是否齐全、有没有 0 字节的坏文件',
    en: 'Checks that the icon-cache files are all present and none is zero-length',
  },
};

const LANG = 'zh';

/** Label for a source, or null if the source is unknown. */
function kindInfo(sourceId, lang) {
  const info = SOURCE_KIND[sourceId];
  if (!info) return null;
  const isZh = lang !== 'en';
  return { kindLabel: isZh ? info.zh : info.en };
}

function pick(pair, lang) {
  if (!pair) return null;
  return lang === 'en' ? pair.en : pair.zh;
}

/** Collapse whitespace and drop control characters. Never throws. */
function txt(v) {
  return String(v ?? '')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Text that is safe to show the user. Resource strings the probe could not
 * resolve (`@%SystemRoot%\…`, `$(@…,-702)`, `@{PackageFamily?ms-resource://…}`)
 * are NOT data - showing them is worse than showing nothing, so they become ''.
 */
function usable(v) {
  const s = txt(v);
  if (!s) return '';
  if (s.startsWith('@') || s.startsWith('$(')) return '';
  // `ms-resource:ProductPkgDisplayName` style names show up as rule/group names
  // for packaged apps; they are resource keys, not text meant for a human.
  if (/^ms-resource:/i.test(s)) return '';
  if (s.includes('ms-resource://') || s.includes('%SystemRoot%')) return '';
  return s;
}

/** Cut at a sentence boundary, then hard-clip so a card face stays readable. */
function clip(s, max) {
  const t = txt(s);
  if (t.length <= max) return t;
  return t.slice(0, max - 1).replace(/[,，、;；:：\s]+$/, '') + '…';
}

/** First sentence of a description, without its terminator. */
function firstSentence(v, max = 96) {
  const s = usable(v);
  if (!s) return '';
  let head = s;
  const zh = s.match(/^(.{1,200}?[。！？])/);
  if (zh) {
    head = zh[1];
  } else {
    const en = s.match(/^(.{1,200}?[.!?])(?:\s|$)/);
    if (en) head = en[1];
  }
  return clip(head.replace(/[。.!?！？]+$/, ''), max);
}

/** Last path segment of a Windows path, without the extension. */
function baseName(p) {
  const s = txt(p).replace(/["']/g, '');
  if (!s) return '';
  const seg = s.split(/[\\/]/).filter(Boolean);
  const last = seg.length ? seg[seg.length - 1] : '';
  return last.replace(/\.[A-Za-z0-9]{1,8}$/, '');
}

/**
 * Executable name out of a command line or a bare path.
 *
 * Splitting on whitespace is not enough: `D:\Program Files\X\thing.exe` would
 * yield "Program", and unquoted uninstall strings like
 * `D:\Program Files (x86)\miHoYo Launcher\launcher.exe --uninstall_game=…` are
 * common in real registry data. So try a quoted path, then a path ending in a
 * known binary extension, and only then fall back to the first token.
 */
const BIN_EXT = '(?:exe|dll|com|bat|cmd|msi|ps1|sys|scr|cpl)';
const BIN_AT_END = new RegExp(`^(.*?\\.${BIN_EXT})(?=\\s|$)`, 'i');

function cmdName(cmd) {
  const s = txt(cmd);
  if (!s) return '';
  const quoted = s.match(/^"([^"]+)"/);
  if (quoted) return baseName(quoted[1]);
  const withExt = s.match(BIN_AT_END);
  if (withExt) return baseName(withExt[1]);
  const first = s.match(/^(\S+)/);
  return first ? baseName(first[1]) : '';
}

/** The arguments part of a command line, or ''. */
function cmdArgs(cmd) {
  const s = txt(cmd);
  if (!s) return '';
  if (s.startsWith('"')) {
    const close = s.indexOf('"', 1);
    return close > 0 ? s.slice(close + 1).trim() : '';
  }
  const withExt = s.match(BIN_AT_END);
  if (withExt) return s.slice(withExt[1].length).trim();
  const m = s.match(/^\S+\s+(.*)$/);
  return m ? m[1].trim() : '';
}

/**
 * svchost.exe runs dozens of services in one process, and the `-k` group name
 * is what actually distinguishes them at the OS level. Worth surfacing when the
 * description does not say anything useful.
 */
function svcHostGroup(cmd) {
  const m = cmdArgs(cmd).match(/-k\s+(\S+)/i);
  return m ? m[1] : '';
}

/**
 * Legacy firewall rules that came from a packaged app store their name as a
 * resource reference. The package family is real, readable data hiding in it
 * (`@{Microsoft.BingSearch_1.2.162.0_x64__8wekyb3d8bbwe?ms-resource://…`), so
 * recover it instead of dropping the field entirely.
 */
function packageFamilyFromResource(v) {
  const s = txt(v);
  // "@{Microsoft.BingSearch_1.2.162.0_x64__8wekyb3d8bbwe?ms-resource://…}" — the
  // package identity sits between "@{" and "?"; that is the only part that
  // differs between two packaged rules with identical settings.
  const braced = s.match(/^@\{([^?}]+)/) || s.match(/^@([A-Za-z0-9._]+_[a-z0-9]{13})/i);
  if (braced) return braced[1];
  const bare = s.match(/^([A-Za-z0-9._]+_[a-z0-9]{13})$/);
  return bare ? bare[1] : '';
}

/** Is this path an OS component rather than something the user installed? */
function isSystemPath(p) {
  const s = txt(p).toLowerCase();
  if (!s) return false;
  return s.includes('\\windows\\') || s.includes('\\system32\\') || s.includes('\\winsxs\\');
}

/** "Microsoft" appears in CompanyName of every Windows-bundled binary. */
function isMicrosoftCompany(company) {
  return /\bmicrosoft\b/i.test(txt(company));
}

/** "CN=Microsoft Windows, O=…" -> "Microsoft Windows". */
function cnOf(pub) {
  const s = txt(pub);
  const m = s.match(/CN=([^,]+)/i);
  return m ? txt(m[1]) : s;
}

/** 20260922 -> 2026-09-22; anything else passes through. */
function fmtDate(v) {
  const s = txt(v);
  const m = s.match(/^(\d{4})(\d{2})(\d{2})$/);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : s;
}

/** Size in the unit a human would say out loud. */
function fmtSize(kb) {
  const n = Number(kb);
  if (!Number.isFinite(n) || n <= 0) return '';
  if (n >= 1024 * 1024) return `${(n / 1024 / 1024).toFixed(1)} GB`;
  if (n >= 1024) return `${(n / 1024).toFixed(1)} MB`;
  return `${Math.round(n)} KB`;
}

/** Trigger list -> readable clause. */
function triggerText(v, isZh) {
  const raw = txt(v);
  if (!raw) return isZh ? '没有登记触发条件' : 'no trigger is registered';
  const seen = [];
  for (const key of raw.split(/[,;、]+/).map((s) => txt(s)).filter(Boolean)) {
    const g = TRIGGER_GLOSS[key.toLowerCase()];
    const label = g ? (isZh ? g.zh : g.en) : key;
    if (label && !seen.includes(label)) seen.push(label);
  }
  return seen.length ? seen.join(isZh ? '、' : ', ') : raw;
}

/** Task state as Windows labels it, with a plain-Chinese gloss. */
function taskStateText(raw, isZh) {
  const s = txt(raw);
  const map = {
    ready: { zh: '就绪（到点就会跑）', en: 'Ready (it will run when due)' },
    running: { zh: '正在运行', en: 'Running' },
    disabled: { zh: '已禁用', en: 'Disabled' },
    queued: { zh: '排队中', en: 'Queued' },
    unknown: { zh: '状态未知', en: 'unknown state' },
  };
  const g = map[s.toLowerCase()];
  if (g) return isZh ? g.zh : g.en;
  return s || (isZh ? '状态未报告' : 'state not reported');
}

/** Start-type wording for a service row. */
function startModePair(raw, isZh) {
  const key = txt(raw).toLowerCase();
  let entry = START_MODE[key];
  if (entry && entry.same) entry = START_MODE[entry.same];
  if (!entry) {
    const fallback = isZh
      ? `系统报告的启动方式是「${txt(raw) || '未知'}」`
      : `Windows reports its start type as "${txt(raw) || 'unknown'}"`;
    return { short: fallback, long: fallback };
  }
  return {
    short: isZh ? entry.short.zh : entry.short.en,
    long: isZh ? entry.long.zh : entry.long.en,
  };
}

/**
 * Build the explanation object for one entry.
 *
 * @param {object} entry normalized entry (see normalize.js)
 * @param {string} lang  'zh' | 'en'
 * @returns {object|null} null when there is nothing honest to say
 */
export function explainEntry(entry, lang = LANG) {
  if (!entry) return null;
  const isZh = lang !== 'en';
  const d = entry.detail ?? {};
  const ki = kindInfo(entry.source, lang);
  if (!ki) return null;

  /** Inline bilingual picker - keeps each sentence next to its twin. */
  const S = (zh, en) => (isZh ? zh : en);
  /** Add a labelled fact, formatting controlled by the caller. */
  // `usable`, not `txt`: a fact row is shown verbatim on the card, so an
  // unresolved resource string ("$(@%SystemRoot%\system32\invagent.dll,-701)")
  // must count as "no data" rather than be printed raw.
  const fact = (labelZh, labelEn, value) => {
    const v = usable(value);
    if (v) out.facts.push([S(labelZh, labelEn), v]);
  };

  const out = {
    kindLabel: ki.kindLabel,
    /** One sentence about THIS row, built from its own measured fields. */
    what: null,
    /** Where the user meets it, or null. */
    where: null,
    /** What it is for / what it does, or null. */
    purpose: null,
    /** What changes if it is switched off, or null. */
    ifOff: null,
    /** Who made it: 'microsoft' | 'thirdparty' | null. */
    origin: null,
    originName: '',
    /** Extra plain-language facts, already labelled. */
    facts: [],
  };

  // ---- shell extensions: the GUID problem -----------------------------------
  if (entry.source === 'com') {
    // The friendly name can come from three places, most specific first:
    //   1. displayName - the CLSID key's own (default) value
    //   2. rawValue    - entries that store a name instead of a GUID
    //   3. the server DLL's FileDescription
    const displayName = usable(d.displayName);
    const friendly = displayName || usable(d.rawValue);
    const dllDesc = usable(d.dllDescription);
    const company = usable(d.dllCompany);
    const approved = usable(d.approved);
    const server = txt(d.server);
    const root = txt(d.classRoot) || '?';
    const hkind = txt(d.handlerKind) || '?';

    const placement = SHELLX_PLACEMENT[`${root}|${hkind}`];
    const placeText = placement
      ? pick(placement, lang)
      : (HANDLER_KIND_GLOSS[hkind]
        ? (isZh ? `资源管理器里的${HANDLER_KIND_GLOSS[hkind].zh}` : `a ${HANDLER_KIND_GLOSS[hkind].en} in Explorer`)
        : null);

    // THE ACTUAL THING ON SCREEN. "An extra tab in a folder's Properties dialog"
    // is not an answer - the user cannot tell which tab. Resolve the concrete
    // caption, most authoritative source first:
    //   1. pageTitleText - Windows' own CLSID PageTitle, resolved via
    //      SHLoadIndirectString (this is the literal tab caption)
    //   2. muiVerbText   - the handler subkey's MUIVerb, resolved the same way
    //   3. SHELLX_ITEM_LABEL - verified per-CLSID caption (see the table)
    //   4. the handler's own registered name, for third-party extensions. Outlook,
    //      360, Quark etc. register a human name and put exactly one item in the
    //      menu under it, so "the item you see is 360压缩文件类型" is both true and
    //      the most useful thing we can say without opening the DLL's resources.
    // Only if all four miss does this fall back to the placement sentence alone.
    const clsidKey = txt(d.clsid).toLowerCase();
    const captionText = usable(d.pageTitleText) || usable(d.muiVerbText);
    // A CLSID can be registered on several surfaces (ntshrui's handler is both a
    // menu item and a tab), so the table is keyed by clsid|handlerKind and falls
    // back to the bare clsid only when the surface does not change the wording.
    const known = SHELLX_ITEM_LABEL[`${clsidKey}|${hkind}`] ?? SHELLX_ITEM_LABEL[clsidKey];
    const provider = dllDesc || company || cmdName(server);
    const isForeign = Boolean(company) && !isSystemPath(server);
    // A registered name is only usable as "the item you see" when it reads like
    // a label a human typed. `ShellContextMenu Class`, `DfsShell Class`,
    // `kdesktopshellext Class` are COM class names - the menu never shows them.
    // Presenting one as the caption would be worse than saying nothing.
    const looksLikeCode = /(^|\s)(Class|Handler|Extension|Extensions|Handler Class|Shell Extension)$|\bCLSID\b|^\{/i.test(friendly || '');
    const caption = captionText
      || (known ? pick(known, lang) : '')
      || (isForeign && friendly && !looksLikeCode ? friendly : '');

    // ImplementsVerbs is the one field that states, in Windows' own words, what
    // the handler puts into the menu. 4 rows carry it on this machine.
    const verbNames = txt(d.verbs)
      .split(';')
      .map((v) => v.trim().toLowerCase())
      .filter(Boolean);
    const verbList = verbNames.map((v) => (VERB_GLOSS[v] ? pick(VERB_GLOSS[v], lang) : v));
    // Each verb is a menu item, so it gets the same 「」/"" wrapper the caption
    // does; joined items then read like the menu itself.
    const verbText = verbList
      .map((v) => (isZh ? `「${v}」` : `"${v}"`))
      .join(isZh ? '、' : ', ');

    // Phrase the concrete item the way that surface actually reads. A menu is
    // 「菜单里的「X」」; a property sheet is 「多出来的「X」页」. The table stores the
    // bare caption WITHOUT any 「」/"" wrapper, so this adds exactly one layer.
    const isSheet = hkind === 'PropertySheetHandlers';
    const quoted = !caption
      ? ''
      : (isZh ? `「${caption}」` : `"${caption}"`);
    const itemPhrase = !quoted
      ? ''
      : (isSheet
        ? (isZh ? `${quoted}页` : `${quoted} tab`)
        : quoted);

    // WHERE: the placement, then the concrete caption so the row is identifiable.
    if (placeText) {
      out.where = isZh
        ? (itemPhrase
          ? `${placeText}——具体是${itemPhrase}（注册在 ${root} 下的 ${hkind} 里）。`
          : `${placeText}（注册在 ${root} 下的 ${hkind} 里）。`)
        : (itemPhrase
          ? `${placeText}, specifically ${itemPhrase} (registered under ${root} \\ ${hkind}).`
          : `${placeText} (registered under ${root} \\ ${hkind}).`);
    }

    // WHAT: this row's placement + the concrete on-screen item + the vendor's
    // own file description + its registered name. Three different rows give
    // three different sentences, and the named item is what the user can verify.
    const whatItem = verbText
      ? (isZh ? `它加的是${verbText}` : `it adds ${verbText}`)
      : (itemPhrase ? (isZh ? `它加的就是${itemPhrase}` : `it adds ${itemPhrase}`) : '');
    if (placeText && provider) {
      out.what = isZh
        ? `${placeText}${whatItem ? `，${whatItem}` : ''}；由「${provider}」提供${friendly ? `，注册名是「${friendly}」` : ''}。`
        : `${placeText}${whatItem ? `, ${whatItem}` : ''}; provided by "${provider}"${friendly ? `, registered as "${friendly}"` : ''}.`;
    } else if (placeText) {
      out.what = isZh
        ? `${placeText}${whatItem ? `，${whatItem}` : ''}。`
        : `${placeText}${whatItem ? `, ${whatItem}` : ''}.`;
    } else if (provider) {
      out.what = isZh
        ? `外壳扩展${whatItem ? `，${whatItem}` : ''}；由「${provider}」提供${friendly ? `，注册名是「${friendly}」` : ''}。`
        : `A shell extension${whatItem ? `, ${whatItem}` : ''}, provided by "${provider}"${friendly ? `, registered as "${friendly}"` : ''}.`;
    }

    // PURPOSE: what makes this one different from the other 77. The registered
    // name and the provider file are the two fields that actually vary; the
    // approved-list flag and the company are the trust signal.
    const approvedTxt = d.inApproved === true
      ? (approved
        ? S(`已列入 Windows 的「已批准外壳扩展」名单（登记名「${approved}」）`, `listed in Windows' approved shell extensions ("${approved}")`)
        : S('已列入 Windows 的「已批准外壳扩展」名单', 'listed in Windows\' approved shell extensions'))
      : S('不在 Windows 的「已批准外壳扩展」名单里', 'not in Windows\' approved shell extension list');
    const scopeTxt = txt(d.scope) === 'user'
      ? S('当前用户', 'the current user')
      : S('本机所有用户', 'the whole machine');
    out.purpose = S(
      `${friendly ? `注册名是「${friendly}」，` : '这一条没有登记显示名，'}由「${company || provider || '未写明来源'}」提供，${approvedTxt}。它注册在${scopeTxt}的 ${root} 下，不常驻内存——只有资源管理器画出这个${placeText ? '菜单/页面' : '扩展'}时才会把 ${cmdName(server) || '对应的 DLL'} 读进去。`,
      `${friendly ? `Its registered name is "${friendly}", and it` : 'It records no display name and'} is provided by "${company || provider || 'an unstated source'}" and ${approvedTxt}. It is registered under ${root} for ${scopeTxt}; it does not sit in memory - ${cmdName(server) || 'its DLL'} is only loaded when Explorer draws that item.`,
    );

    if (company) {
      out.origin = isMicrosoftCompany(company) ? 'microsoft' : 'thirdparty';
      out.originName = company;
    } else if (isSystemPath(server)) {
      out.origin = 'microsoft';
      out.originName = 'Microsoft';
    }

    // IF OFF: Windows components and third-party handlers are not the same deal.
    const systemDll = isSystemPath(server);
    if (systemDll && out.origin === 'microsoft') {
      out.ifOff = S(
        '这是 Windows 自带的组件。关掉它不会让系统变快，只会让对应的菜单项消失；想恢复时在这里重新启用即可。',
        'This ships with Windows. Turning it off will not make the system faster - it only removes that menu item. Re-enable it here to get it back.',
      );
    } else {
      out.ifOff = S(
        `关掉之后这一项菜单/选项卡会消失，程序本身不会被卸载。它是可以随时恢复的开关；如果要彻底不用它，得去卸载 ${company || provider || '对应的软件'}。`,
        `Turning it off removes that menu item or tab; the program stays installed. It is a reversible switch - to be rid of it entirely you have to uninstall ${company || provider || 'the program'}.`,
      );
    }

    if (server) fact('由哪个文件提供', 'Provided by file', server);
    if (caption) fact('多出来的是', 'The item you see', caption);
    if (verbText) fact('它能做什么', 'What it does', verbText);
    if (usable(d.pageTitle)) fact('页签标题的来源', 'Tab caption source', d.pageTitle);
    if (approved) fact('已批准名单里的名字', 'Approved name', approved);
    fact('CLSID', 'CLSID', d.clsid);
    return finalize(out);
  }

  // ---- services -------------------------------------------------------------
  if (entry.source === 'svc') {
    const desc = usable(d.description);
    const head = firstSentence(d.description, 96);
    const mode = startModePair(d.startMode, isZh);
    const running = /running/i.test(txt(entry.state) + ' ' + txt(d.state));
    const stateTxt = S(running ? '正在运行' : '没有在运行', running ? 'is running' : 'is not running');
    const exe = cmdName(d.path);

    // The description is the vendor's own words and the single most useful
    // field on the machine (267 of 272 rows have one). When it is missing we
    // say so instead of substituting a generic "a background service" line.
    const body = head || S(
      `系统没有为这个服务写说明文字${exe ? `，能从注册信息里读到的是：可执行文件 ${exe}` : ''}`,
      `Windows ships no description for this service${exe ? `; all the registry says is that it runs ${exe}` : ''}`,
    );
    out.what = S(
      `${body}。${mode.short}，现在${running ? '正在运行' : '没有在运行'}。`,
      `${body}. It ${mode.short}, and it ${running ? 'is running' : 'is not running'} right now.`,
    );

    // PURPOSE must not just repeat the card face. The description's remaining
    // sentences are the useful part ("如果停止此服务，则…"), so use those; when
    // the vendor wrote only one sentence, say what the row's own fields add
    // instead of printing that sentence twice. The svchost -k group is the one
    // thing that tells two dozen otherwise-identical svchost services apart.
    const rest = desc && head && desc.startsWith(head) ? txt(desc.slice(head.length)).replace(/^[。.！!？?]\s*/, '') : '';
    const group = svcHostGroup(d.path);
    const hosted = /svchost/i.test(txt(d.path));
    const implBits = S(
      [
        exe ? `由 ${exe} 实现` : null,
        group ? `svchost 组是 ${group}` : null,
        txt(d.logon) ? `以 ${txt(d.logon)} 身份运行` : null,
        hosted ? '和其它服务共用一个 svchost 进程' : null,
        usable(d.displayName) ? `显示名「${usable(d.displayName)}」` : null,
      ].filter(Boolean).join('，'),
      [
        exe ? `implemented by ${exe}` : null,
        group ? `svchost group ${group}` : null,
        txt(d.logon) ? `running as ${txt(d.logon)}` : null,
        hosted ? 'sharing a svchost process with other services' : null,
        usable(d.displayName) ? `shown as "${usable(d.displayName)}"` : null,
      ].filter(Boolean).join(', '),
    );
    if (rest) {
      out.purpose = rest;
    } else if (desc) {
      out.purpose = S(
        `厂商说明只写了这一句，没有「停用会怎样」的补充。注册信息里还能读到的：${implBits}。`,
        `The vendor wrote only that one sentence, with no "what breaks if you stop it" note. The registration also says: ${implBits}.`,
      );
    } else {
      out.purpose = S(
        `系统连说明文字都没有留。能读到的只有注册信息：${implBits}。`,
        `Windows left no description at all. All that is readable is the registration: ${implBits}.`,
      );
    }

    out.where = S(
      `服务管理器（services.msc）里名为「${txt(entry.name)}」的那一条${usable(d.displayName) ? `，显示名是「${usable(d.displayName)}」` : ''}。`,
      `The entry named "${txt(entry.name)}" in services.msc${usable(d.displayName) ? `, shown as "${usable(d.displayName)}"` : ''}.`,
    );

    if (txt(d.startMode).toLowerCase() === 'disabled') {
      out.ifOff = S(
        '它已经是禁用状态，所以「再禁一次」不会改变任何东西。要让它重新工作，得把启动方式改回「手动」或「自动」——在这里点启用就能做到。',
        'It is already disabled, so disabling it again changes nothing. To make it work again its start type has to go back to Manual or Automatic - which the enable switch here does.',
      );
    } else if (running && /auto/i.test(txt(d.startMode))) {
      out.ifOff = S(
        '停掉它会让依赖它的功能立刻失效（服务没有窗口可以关，所以看不出「它退出了」）。想彻底停用，改启动方式比临时停止更干净。',
        'Stopping it takes down whatever depends on it immediately, and there is no window to show that it left. Changing the start type is cleaner than a one-off stop.',
      );
    } else if (!running) {
      out.ifOff = S(
        '它本来就没在跑，所以禁用与否对当前状态没有区别——这也说明它不是你现在需要关心的东西。',
        'It is not running anyway, so disabling it changes nothing about the current state.',
      );
    } else {
      out.ifOff = S(
        '停掉之后它不会自己再起来，依赖它的功能会失效。停用前先确认这个服务是给谁用的。',
        'Once stopped it will not come back by itself, and whatever depends on it breaks. Check what uses it first.',
      );
    }

    fact('显示名', 'Display name', d.displayName);
    fact('运行身份', 'Runs as', d.logon);
    fact('程序路径', 'Executable', d.path);
    return finalize(out);
  }

  // ---- scheduled tasks ------------------------------------------------------
  if (entry.source === 'task') {
    const desc = usable(d.description);
    const head = firstSentence(d.description, 96);
    const trig = triggerText(d.triggers, isZh);
    const st = taskStateText(entry.state ?? d.state, isZh);
    const actionDead = d.actionDisabled === true;
    const exe = cmdName(d.executables || d.path);
    const user = usable(d.user);

    if (head) {
      out.what = S(
        `${head}。触发方式：${trig}；任务${d.taskEnabled === false ? '已被禁用' : `当前${st}`}${actionDead ? '，而且「操作」被单独禁用了——Windows 把里面的命令改写成了占位文字「by user disabled」，即使任务启用也不会真的执行任何东西' : ''}。`,
        `${head}. Trigger: ${trig}; the task is ${d.taskEnabled === false ? 'disabled' : st}${actionDead ? ', and its action is individually disabled - Windows stores the placeholder text "by user disabled" instead of the command, so nothing runs even if the task is enabled' : ''}.`,
      );
    } else {
      // 没有说明、也读不到命令时，能区分这些任务的只有它挂在哪个分类下
      // （BitLocker / EDP / Input…），这比再念一遍任务名有用。
      const folder0 = (txt(d.taskPath) || '\\').split('\\').filter(Boolean).pop() || '';
      out.what = S(
        `系统没有为这个任务写说明。${exe ? `它运行 ${exe}` : '注册信息里没有可执行命令'}；触发方式：${trig}；当前${st}${user ? `，以 ${user} 身份运行` : ''}${folder0 ? `；它属于「${folder0}」这一类任务` : ''}。`,
        `Windows ships no description for this task. ${exe ? `It runs ${exe}` : 'No command is registered'}; trigger: ${trig}; it is ${st}${user ? `, running as ${user}` : ''}${folder0 ? `; it belongs to the "${folder0}" group of tasks` : ''}.`,
      );
    }

    // Same rule as services: the description's second half is the interesting
    // part ("如果此任务被禁用…"), so lead with that instead of repeating the head.
    const rest = desc && head && desc.startsWith(head) ? txt(desc.slice(head.length)).replace(/^[。.！!？?]\s*/, '') : '';
    if (rest) {
      out.purpose = rest;
    } else if (desc) {
      // 一批 Windows 自带任务共用同一句说明，登记信息里能真正区分它们的是
      // 所在的分类文件夹（Autochk / Defrag / Sysmain…）和触发方式。
      const folder = (txt(d.taskPath) || '\\').split('\\').filter(Boolean).pop() || '';
      out.purpose = S(
        `系统为它写的说明只有一句，没有补充。注册信息里能读到的还有：${d.taskEnabled === false ? '任务已被禁用' : `任务当前${st}`}${user ? `、运行身份 ${user}` : ''}${d.author ? `、创建者 ${usable(d.author)}` : ''}${exe ? `、要运行的命令 ${exe}` : ''}${folder ? `；它被归在 「${folder}」 这一组里，同组任务通常一起出现` : ''}。`,
        `The task's description is a single sentence and adds nothing. What the registration does add: it is ${d.taskEnabled === false ? 'disabled' : st}${user ? `, runs as ${user}` : ''}${d.author ? `, authored by ${usable(d.author)}` : ''}${exe ? `, and executes ${exe}` : ''}${folder ? `; it is filed under the "${folder}" group, whose tasks normally come and go together` : ''}.`,
      );
    } else if (exe) {
      out.purpose = S(
        `任务本身没有说明文字，但它的「操作」写得很清楚：运行 ${exe}${d.path && cmdArgs(d.path) ? `，参数是 ${clip(cmdArgs(d.path), 90)}` : ''}。`,
        `The task carries no description, but its action is explicit: run ${exe}${d.path && cmdArgs(d.path) ? ` with the arguments ${clip(cmdArgs(d.path), 90)}` : ''}.`,
      );
    } else {
      // No description AND no readable command: the honest answer is what the
      // registration does contain, not a generic "a scheduled task".
      out.purpose = S(
        `这个任务既没有说明文字，也没有登记可读的命令——探针读到的「操作」是空的。能确定的只有：它挂在「${txt(d.taskPath) || '\\'}」路径下、触发方式 ${trig}、当前${st}${user ? `、运行身份 ${user}` : ''}。这种情况通常是任务定义被精简过，或者命令存在但当前账户读不到。`,
        `This task has neither a description nor a readable command - the probe read an empty action. All that is certain: it lives under "${txt(d.taskPath) || '\\'}", its trigger is ${trig}, and it is ${st}${user ? ` running as ${user}` : ''}. That usually means the definition was trimmed, or the command exists but this account cannot read it.`,
      );
    }

    out.where = S(
      `任务计划程序里「${txt(d.taskPath) || '\\'}」路径下的「${txt(d.taskName) || txt(entry.name)}」。`,
      `Task Scheduler, under "${txt(d.taskPath) || '\\'}", the task named "${txt(d.taskName) || txt(entry.name)}".`,
    );

    if (d.taskEnabled === false) {
      out.ifOff = S(
        '它现在已经是禁用状态，所以再禁用一次不会改变任何东西。要让它重新工作，在这里点启用即可——但如果「操作」也被禁用（见上），启用后仍然不会真的执行。',
        'It is already disabled, so disabling it again changes nothing. Enabling it here brings it back - unless its action is also disabled (see above), in which case it still will not run.',
      );
    } else if (actionDead) {
      out.ifOff = S(
        '它的「操作」已被单独禁用：任务到点仍然会被唤醒，但里面存的命令是占位文字，所以什么也不会发生。真要它干活，得改任务定义，不是在面板上开关。',
        'Its action is individually disabled: the task is still woken up on schedule, but the command it holds is a placeholder, so nothing happens. Making it work means editing the task definition, not flipping a switch here.',
      );
    } else {
      out.ifOff = S(
        '禁用后这个任务不再被触发。它通常只做维护、更新检查或上报，关掉一般不影响日常使用；想恢复时重新启用即可。',
        'Once disabled the task is never triggered. These usually do maintenance, update checks or reporting; turning one off rarely affects daily use, and it can be re-enabled here.',
      );
    }

    fact('触发方式', 'Trigger', trig);
    fact('创建者', 'Author', d.author);
    fact('运行身份', 'Runs as', d.user);
    fact('运行的程序', 'Runs', d.executables || d.path);
    fact('任务状态', 'Task state', txt(entry.state || d.state));
    return finalize(out);
  }

  // ---- autorun --------------------------------------------------------------
  if (entry.source === 'autorun') {
    const cmd = usable(entry.path) || usable(d.path);
    const exe = cmdName(cmd);
    const args = cmdArgs(cmd);
    const scopeUser = txt(entry.scope || d.scope) === 'user';
    const once = /runonce/i.test(txt(d.kind));

    out.what = S(
      `${once ? '一次性启动项：下次登录时执行一次，执行完 Windows 就把这条记录删掉' : '每次登录都会自动执行这条命令'}：${cmd || '（命令为空）'}。`,
      `${once ? 'A one-shot startup entry: it runs once at the next sign-in, then Windows deletes the record' : 'This command runs at every sign-in'}: ${cmd || '(empty command)'}.`,
    );

    out.purpose = exe
      ? S(
        `具体到这一条：每次登录后替你启动「${exe}」${args ? `，并把 ${clip(args, 80)} 作为参数传给它` : ''}。记录里只有这一行命令，没有任何其它信息——程序装在哪、由谁发布，都得看这行命令里的路径。`,
        `For this row specifically: at each sign-in it starts "${exe}"${args ? ` with ${clip(args, 80)} as its arguments` : ''}. The record holds nothing but that one command line - what the program is and where it lives has to be read out of the path.`,
      )
      : null;

    out.where = S(
      `${scopeUser ? '当前用户' : '本机所有用户'}的「${once ? '一次性启动' : '启动'}」列表里，名字是「${txt(entry.name)}」，注册位置是 ${txt(d.keyPath) || '注册表 Run 键'}。`,
      `In the ${scopeUser ? 'current user\'s' : 'machine-wide'} ${once ? 'RunOnce' : 'Run'} list, under the name "${txt(entry.name)}" (${txt(d.keyPath) || 'a Run key'}).`,
    );

    out.ifOff = S(
      once
        ? '禁用后这条一次性启动不会执行；因为它本来就只跑一次，禁用基本等于放弃那次执行。'
        : '禁用后它不再自动启动，但程序本身还在，随时可以手动打开。这一项会被改名保留，不会删除。',
      once
        ? 'Disabling it skips that one run; since it only ever runs once, that is the whole effect.'
        : 'Once disabled it no longer starts by itself, but the program is still installed and can be opened manually. The entry is renamed, never deleted.',
    );

    fact('启动的命令', 'Command', cmd);
    fact('作用范围', 'Scope', scopeUser ? S('仅当前用户', 'current user') : S('本机所有用户', 'all users'));
    fact('注册位置', 'Registry key', d.keyPath);
    return finalize(out);
  }

  // ---- installed programs ---------------------------------------------------
  if (entry.source === 'program') {
    const ver = usable(d.version);
    const pub = usable(d.publisher);
    const loc = usable(d.installLocation);
    const uninst = usable(d.uninstall);
    const size = fmtSize(d.sizeKb);
    const date = fmtDate(d.installDate);
    const sysComp = String(d.systemComponent ?? '') === '1';

    out.origin = isMicrosoftCompany(pub) ? 'microsoft' : (pub ? 'thirdparty' : null);
    out.originName = pub;

    // 版本+发布者在一大批微软组件里完全一样（.NET 工作负载清单有 10 条同为
    // 81.204.61788），所以正文必须带上这一条自己的体积/安装位置/登记形态。
    const shapeTxt = loc
      ? S(`有自己的安装目录 ${loc}`, `it has its own install folder ${loc}`)
      : uninst
        ? S('注册表里没有写安装目录，只留了一条 MSI 卸载入口', 'no install folder is recorded, only an MSI uninstall entry')
        : S('既没有安装目录也没有卸载命令', 'neither an install folder nor an uninstall command is recorded');

    out.what = S(
      [
        ver ? `版本 ${ver}` : '注册表里没有登记版本号',
        pub ? `发布者「${pub}」` : '没有写发布者',
        size ? `登记体积 ${size}` : null,
        shapeTxt,
      ].filter(Boolean).join('，') + '。',
      `${ver ? `Version ${ver}` : 'No version recorded'}, ${pub ? `publisher "${pub}"` : 'publisher not recorded'}${size ? `, registered size ${size}` : ''}; ${shapeTxt}.`,
    );

    const quiet = usable(d.quietUninstall);
    const modify = usable(d.modify);

    // 系统组件这一条要单独说出来：它会混在普通软件里，但卸载它可能连带拆掉
    // 别的组件，所以不能和「想删就删的软件」写成同一句。
    const sysTxt = sysComp
      ? S(
        '它的安装器把它标成了「系统组件」——这类条目通常是更大的微软组件（运行时、SDK、语言包）的一部分，单独卸掉可能让依赖它的程序出问题。',
        'Its installer marks it as a system component - such entries are usually part of a larger Microsoft component (a runtime, SDK or language pack), and removing one alone can break whatever depends on it.',
      )
      : '';
    const quietTxt = quiet
      ? S(`它另有一条静默卸载命令 ${cmdName(quiet)}，可无人值守地卸载`, `it also has a silent uninstall command (${cmdName(quiet)}) that can run unattended`)
      : '';
    const modTxt = modify
      ? S(`「修改」入口是 ${cmdName(modify)}，可以加装或去掉其中的组件`, `the Modify entry is ${cmdName(modify)}, which adds or removes its components`)
      : '';

    out.purpose = uninst
      ? S(
        `它在「程序和功能」里有一条正式登记：卸载入口是 ${cmdName(uninst)}${date ? `，安装日期 ${date}` : ''}${size ? `，登记体积 ${size}` : ''}${loc ? `，装在 ${loc}` : ''}${d.productCode ? `，产品代码 ${txt(d.productCode)}` : ''}。绿色软件不会留下这条登记，所以这一条是真被安装程序写进系统的。${quietTxt ? `${quietTxt}。` : ''}${modTxt ? `${modTxt}。` : ''}${sysTxt ? `${sysTxt}` : ''}`,
        `It holds a real registration in Programs and Features: its uninstaller is ${cmdName(uninst)}${date ? `, installed on ${date}` : ''}${size ? `, registered size ${size}` : ''}${loc ? `, in ${loc}` : ''}${d.productCode ? `, product code ${txt(d.productCode)}` : ''}. Portable software leaves no such record, so this one was installed by a setup program.${quietTxt ? ` ${quietTxt}.` : ''}${modTxt ? ` ${modTxt}.` : ''}${sysTxt ? ` ${sysTxt}` : ''}`,
      )
      : S(
        `它登记在「程序和功能」里，但没有写卸载命令——这种条目通常靠程序自己的安装器删除，也可能只是卸载后残留的登记${loc ? `。它登记的目录是 ${loc}` : ''}。${date ? `安装日期是 ${date}。` : ''}${sysTxt}`,
        `It is registered in Programs and Features but carries no uninstall command - such entries are usually removed by the program's own installer, or may be leftovers from an uninstall${loc ? `. Its recorded folder is ${loc}` : ''}.${date ? ` It was installed on ${date}.` : ''}${sysTxt ? ` ${sysTxt}` : ''}`,
      );

    out.where = S(
      `「设置 → 应用 → 已安装的应用」或「控制面板 → 程序和功能」里的「${txt(entry.name)}」。`,
      `"${txt(entry.name)}" in Settings > Apps > Installed apps, or in Control Panel > Programs and Features.`,
    );

    // program rows now carry the uninstall verb, so this text must not claim to be
    // read-only — it was written before task-30 and would describe the old panel.
    out.ifOff = S(
      sysComp
        ? '它是系统组件，不给卸载按钮：卸载系统组件通常会让依赖它的其他功能一起失效。'
        : '卸载不可撤销，只能重装。卡片正面的「卸载」会先预演：把要执行的命令原样列出来，你确认后才真跑；卸载程序自己会弹它的确认框。',
      sysComp
        ? 'This is a system component, so no uninstall button is offered: removing it usually breaks whatever depends on it.'
        : 'Uninstalling cannot be undone — only reinstalled. The Uninstall button on the card runs a dry run first and shows the exact command; it only executes after you confirm, and the vendor uninstaller shows its own prompt.',
    );

    fact('版本', 'Version', ver);
    fact('发布者', 'Publisher', pub);
    fact('安装位置', 'Installed to', loc);
    fact('安装时间', 'Installed on', date);
    fact('占用大小', 'Size', size);
    fact('卸载命令', 'Uninstall command', uninst);
    fact('静默卸载', 'Silent uninstall', quiet);
    fact('修改入口', 'Modify entry', modify);
    fact('产品代码', 'Product code', d.productCode);
    if (sysComp) fact('系统组件标记', 'System component flag', S('是（安装器声明它是系统组件）', 'yes (the installer marks it as a system component)'));
    return finalize(out);
  }

  // ---- appx -----------------------------------------------------------------
  if (entry.source === 'appx') {
    const ver = usable(d.version);
    const pub = cnOf(d.publisher);
    const arch = usable(d.arch);
    const sig = usable(d.signatureKind);

    const flag = d.nonRemovable === true
      ? S('Windows 自带、系统不允许卸载', 'part of Windows and cannot be removed')
      : d.isFramework === true
        ? S('运行时框架包，别的应用依赖它，不是给你直接打开的', 'a runtime framework package that other apps depend on; you do not launch it')
        : S('普通商店应用', 'an ordinary Store app');

    // 一批 Windows 自带包的架构/版本/发布者三项完全一样（SystemApps 里 19 个
    // 都是 Neutral + 10.0.19041.4239），能区分它们的只有包名/包系列名。
    const fam = usable(d.family);
    out.what = S(
      `${arch ? `${arch} 架构，` : ''}${ver ? `版本 ${ver}，` : ''}发布者 ${pub || '未写明'}；${flag}。${fam ? `包系列名是 ${fam}。` : ''}`,
      `${arch ? `${arch} architecture, ` : ''}${ver ? `version ${ver}, ` : ''}published by ${pub || 'unknown'}; it is ${flag}.${fam ? ` Its package family is ${fam}.` : ''}`,
    );

    out.origin = /microsoft/i.test(pub) ? 'microsoft' : 'thirdparty';
    out.originName = pub;

    out.purpose = S(
      `包的完整名称是 ${txt(d.fullName) || '未登记'}，签名来源是「${sig || '未报告'}」${sig === 'System' ? '（随 Windows 一起签名，不是应用商店分发）' : sig === 'Store' ? '（应用商店签名）' : ''}。它装在 ${txt(d.path) || '包目录'}，用的是 Windows 的 AppX/MSIX 部署方式，所以卸载走「设置 → 应用」，而不是控制面板。`,
      `Its full package name is ${txt(d.fullName) || 'not recorded'} and its signature kind is "${sig || 'not reported'}". It lives in ${txt(d.path) || 'its package folder'} and was deployed as an AppX/MSIX package, so it is removed through Settings > Apps, not Control Panel.`,
    );

    out.where = S(
      `开始菜单的应用列表和「设置 → 应用 → 已安装的应用」里的「${txt(entry.name)}」。`,
      `"${txt(entry.name)}" in the Start menu app list and in Settings > Apps > Installed apps.`,
    );

    out.ifOff = d.nonRemovable === true
      ? S(
        '这个包属于 Windows 本身，系统不允许卸载它——所以这张卡片上不给卸载按钮，也没有「关掉」这个动作可做。',
        'The package belongs to Windows itself, which refuses to remove it - so no uninstall button is offered and there is no "switch it off" action.',
      )
      : S(
        '卸载会把这个应用和它的本地数据一起移除，不可撤销（重装后数据不会回来）。卡片正面的「卸载」会先预演要执行的命令，你确认后才真跑；随后 Windows 还会弹它自己的确认。',
        'Removing it deletes the app together with its local data, and that cannot be undone (reinstalling does not bring the data back). The Uninstall button dry-runs the exact command first and only executes after you confirm; Windows then shows its own prompt.',
      );

    fact('版本', 'Version', ver);
    fact('架构', 'Architecture', arch);
    fact('包全名', 'Package full name', d.fullName);
    fact('包系列名', 'Package family', d.family);
    fact('签名来源', 'Signature kind', sig);
    fact('安装目录', 'Install folder', d.path);
    if (d.isFramework === true) fact('框架包', 'Framework package', S('是', 'yes'));
    return finalize(out);
  }

  // ---- drivers --------------------------------------------------------------
  if (entry.source === 'drv') {
    const provider = usable(d.provider);
    // Only an INF name belongs in an INF sentence. `entry.name` already falls
    // back to the "(未命名)" placeholder on rows that have neither, and pasting
    // that into "it is bound to (未命名)" reads like a name rather than a gap.
    const infName = usable(d.infName) || (/^\(?未命名\)?$/.test(txt(entry.name)) ? '' : usable(entry.name));
    const inf = infName;
    const ver = usable(d.version);

    // Two shapes come out of the driver probe: packages and device bindings.
    if (usable(d.deviceId)) {
      const devName = usable(d.name) || '未命名设备';
      const cls = usable(d.deviceClass);
      const date = usable(d.date);
      out.what = S(
        `设备「${devName}」当前用的驱动登记在 ${inf || '未登记'}，厂商「${provider || '未写明'}」${cls ? `，设备类 ${cls}` : ''}${date ? `，驱动日期 ${date}` : ''}。`,
        `The device "${devName}" is driven by ${inf || 'an unrecorded INF'} from "${provider || 'an unstated vendor'}"${cls ? `, device class ${cls}` : ''}${date ? `, driver dated ${date}` : ''}.`,
      );
      out.purpose = S(
        `这一条是「某台设备 ↔ 某个驱动包」的对应关系，不是驱动文件本身。设备标识是 ${txt(d.deviceId)}；同一份 INF 可能同时给好几台设备用。${/^Microsoft$/i.test(provider) ? '厂商一栏写的是 Microsoft，说明这套驱动随 Windows 一起提供。' : ''}`,
        `This row is a device-to-driver binding, not a driver file. Its device id is ${txt(d.deviceId)}; the same INF can serve several devices.${/^Microsoft$/i.test(provider) ? ' The vendor column says Microsoft, so this driver ships with Windows.' : ''}`,
      );
      out.origin = isMicrosoftCompany(provider) ? 'microsoft' : (provider ? 'thirdparty' : null);
      out.originName = provider;
      // WHERE: a device row only matters if the user can go look at the device,
      // so name the exact branch in Device Manager. Before this, 168 rows had no
      // `where` at all — the card said what the row was but never where to see it.
      const named = usable(d.name);
      // The INF is already named in `what`; repeating it here only lengthens the
      // card face. `where` answers "where do I go look", nothing else.
      out.where = S(
        named
          ? `设备管理器${cls ? ` → ${cls}` : ''} → 「${named}」这一台。`
          : `设备管理器里设备类${cls ? `「${cls}」` : '未分类'}下没有显示名称的那个节点（设备 ID ${txt(d.deviceId)}）。`,
        named
          ? `Device Manager${cls ? ` > ${cls}` : ''} > "${named}".`
          : `In Device Manager, the unnamed node${cls ? ` in class "${cls}"` : ' with no device class'} (device id ${txt(d.deviceId)}).`,
      );
      out.ifOff = S(
        '这一条是「设备在用哪份驱动」的对应关系，删掉它不会卸载驱动，只会让这条记录消失，设备照样用那份 INF。要换驱动，正确入口是设备管理器里那台设备的「更新驱动 / 回退驱动」。',
        'This row is just "which driver a device is using" — deleting it does not uninstall the driver, it only removes the record, and the device keeps using that INF. To change a driver, use Update driver / Roll back driver on the device in Device Manager.',
      );
      fact('设备名', 'Device', devName);
      fact('设备 ID', 'Device id', d.deviceId);
      fact('驱动 INF', 'Driver INF', inf);
      fact('厂商', 'Provider', provider);
      fact('设备类', 'Device class', cls);
      fact('驱动日期', 'Driver date', date);
      return finalize(out);
    }

    const bound = d.bound === true;
    out.what = S(
      `驱动包 ${inf || '未命名 INF'}${ver ? ` 版本 ${ver}` : '（没有登记版本号）'}，发布者「${provider || '未写明'}」；${bound ? '现在有设备在用它' : '已经装进系统，但现在没有设备在用它'}。`,
      `Driver package ${inf || 'an unnamed INF'}${ver ? ` version ${ver}` : ' (no version recorded)'} from "${provider || 'an unstated vendor'}"; ${bound ? 'a device is using it right now' : 'it is installed, but no device is using it at the moment'}.`,
    );
    out.origin = d.thirdParty === true ? 'thirdparty' : 'microsoft';
    out.originName = provider;
    const pkg = usable(d.packageKey) || inf || '这个包';
    out.purpose = d.thirdParty === true
      ? S(
        `这是第三方驱动包（探针实测 thirdParty=true，签名等级 ${txt(d.signerScore) || '未报告'}），来自 ${provider || '未写明厂商'}，驱动库键名 ${pkg}。它是可以删除的那一类；删之前先确认没有设备靠它工作。`,
        `This is a third-party driver package (the probe measured thirdParty=true, signer score ${txt(d.signerScore) || 'not reported'}) from ${provider || 'an unstated vendor'}, stored as ${pkg}. It is one of the removable ones - just check first that no device depends on it.`,
      )
      : S(
        `这是 Windows 自带的驱动包（探针实测 thirdParty=false，签名等级 ${txt(d.signerScore) || '未报告'}），由 ${provider || 'Microsoft'} 提供，驱动库键名 ${pkg}${ver ? `，版本 ${ver}` : ''}。它属于系统驱动库，正常情况下不需要动它${bound ? '；现在确实有设备在用这个包' : '；当前没有任何设备引用它'}。`,
        `This is a driver package that ships with Windows (the probe measured thirdParty=false, signer score ${txt(d.signerScore) || 'not reported'}) and is provided by ${provider || 'Microsoft'} as ${pkg}${ver ? `, version ${ver}` : ''}. It belongs to the system driver store and needs no attention normally${bound ? '; a device is using it right now' : '; nothing references it at the moment'}.`,
      );
    out.where = bound
      ? S(
        `设备管理器里由 ${inf || '这个包'} 提供驱动的那台设备；驱动库里的键名是 ${txt(d.packageKey) || '未登记'}。`,
        `In Device Manager, the device that ${inf || 'this package'} drives; its store key is ${txt(d.packageKey) || 'not recorded'}.`,
      )
      : S(
        `驱动库（DriverStore）里登记为 ${txt(d.packageKey) || inf || '未登记'} 的包，当前没有设备引用它。`,
        `The driver store package recorded as ${txt(d.packageKey) || inf || 'not recorded'}; nothing references it right now.`,
      );
    // Only third-party packages can be removed with pnputil /delete-driver, and a
    // package a device is bound to is refused outright — say which case this is
    // instead of a blanket "read-only".
    out.ifOff = d.thirdParty !== true
      ? S(
        '这是随 Windows 提供的驱动包，删不掉也不该删：系统驱动库由 Windows 自己维护，卸载命令只对第三方包开放。',
        'This package ships with Windows, so it cannot and should not be removed: the system driver store is Windows-maintained, and the delete verb is only offered for third-party packages.',
      )
      : bound
        ? S(
          '现在有设备正在用这个包，所以不提供删除（强删会让那台硬件当场失灵）。先让设备换用别的驱动、确认不再引用它，再回来删。',
          'A device is using this package right now, so no delete is offered (forcing it would break that hardware immediately). Move the device to another driver first, then come back.',
        )
        : S(
          '这是没有任何设备引用的第三方驱动包，可以删除。卡片正面的「卸载」会先预演 pnputil 命令，你确认后才执行；删错会让对应硬件失灵，重装要靠驱动安装包。',
          'This is a third-party driver package nothing references, so it can be removed. The Uninstall button dry-runs the pnputil command first and only executes after you confirm; removing the wrong one breaks that hardware and restoring it needs the vendor installer.',
        );
    fact('包名', 'Package', d.publishedName || inf);
    fact('驱动库键名', 'Store key', d.packageKey);
    fact('版本', 'Version', ver);
    fact('厂商', 'Provider', provider);
    fact('第三方', 'Third party', d.thirdParty === true ? S('是', 'yes') : S('否（Windows 自带）', 'no (ships with Windows)'));
    fact('签名等级', 'Signer score', d.signerScore);
    fact('绑定设备', 'Bound to a device', bound ? S('是', 'yes') : S('否', 'no'));
    return finalize(out);
  }

  // ---- firewall rules -------------------------------------------------------
  if (entry.source === 'firewall') {
    const dir = txt(d.direction).toLowerCase();
    const act = txt(d.action).toLowerCase();
    const proto = txt(d.protocol) || 'Any';
    const lp = txt(d.localPorts);
    const rp = txt(d.remotePorts);
    const profilesRaw = txt(d.profiles);
    const profiles = isZh ? profilesRaw : (PROFILE_EN[profilesRaw] ?? profilesRaw);
    const app = usable(d.application) || usable(entry.path);
    const svc = usable(d.serviceName);
    const rawGroup = txt(d.group);
    const group = usable(d.group);
    const ownDesc = usable(d.description);
    const descIsOwn = Boolean(ownDesc) && ownDesc !== txt(entry.name) && ownDesc !== group;

    const inbound = dir === 'in';
    const blocking = act === 'block';
    const hasPorts = Boolean(lp) && lp !== '*';

    // An unresolved resource string ("@{Family?ms-resource://…}") is the only
    // thing left to identify a packaged rule by, so recover the package family.
    const family = packageFamilyFromResource(rawGroup) || packageFamilyFromResource(txt(d.description));
    const groupTxt = group && !rawGroup.startsWith('@') ? group : '';

    // WHAT: direction + action + the exact protocol/port/program this row
    // carries. Two rules that differ only in protocol read differently. The
    // group / app folder is added because 32 packaged rules share every
    // direction/action/protocol/profile column and differ only by their group.
    const appDir = app ? (txt(app).replace(/["']/g, '').split(/[\\/]/).filter(Boolean).slice(-2, -1)[0] || '') : '';
    const target = app
      ? S(`程序「${baseName(app)}」${appDir ? `（在 ${appDir} 目录下）` : ''}`, `the program "${baseName(app)}"${appDir ? ` (in the ${appDir} folder)` : ''}`)
      : hasPorts
        ? S(`本机 ${proto} 端口 ${lp}`, `local ${proto} port ${lp}`)
        : S(`${proto} 协议（不限定程序或端口）`, `the ${proto} protocol (no program or port constraint)`);

    // 远端端口和绑定服务是这条规则真正管什么的地方：Windows 自带的同一批
    // svchost 规则每个协议/方向下的差异几乎全在这两个字段上。
    const portTxt = hasPorts
      ? S(`，本机端口 ${lp}`, `, local port ${lp}`)
      : app
        ? S('，本机任意端口', ', any local port')
        : '';
    const rpNum = rp && rp !== '*' ? rp : '';
    const rpTxt = rpNum ? S(`，远端端口 ${rpNum}`, `, remote port ${rpNum}`) : '';
    const svcTxt = svc ? S(`（由服务 ${svc} 承担）`, ` (carried by the ${svc} service)`) : '';

    out.what = S(
      `${blocking ? '阻止' : '允许'}${inbound ? '入站' : '出站'}：${target}${app ? `走 ${proto}` : ''}${portTxt}${rpTxt}，适用于「${profilesRaw || '未写明'}」网络${svcTxt}。`,
      `${blocking ? 'Blocks' : 'Allows'} ${inbound ? 'inbound' : 'outbound'}: ${target}${app ? ` over ${proto}` : ''}${portTxt}${rpTxt}, on the "${profiles || 'unspecified'}" profile${svcTxt}.`,
    );

    // A rule that constrains neither program nor port is otherwise
    // indistinguishable from its neighbours (32 packaged rules share every such
    // column). The group is then the only field that says whose rule it is, so
    // it goes into the sentence rather than only into the facts list.
    if (!app && !hasPorts && (family || (group && group !== txt(entry.name)))) {
      const own = family || group;
      out.what = S(
        `${out.what}这条是「${own}」那一组里的规则，不针对具体程序或端口。`,
        `${out.what} It belongs to the "${own}" group and targets no specific program or port.`,
      );
    }

    // PURPOSE: prefer the rule's own description (Microsoft wrote it), else
    // report the fields - never a generic "a firewall rule is a rule". When the
    // description is absent, the group name and (for packaged rules) the package
    // family are the only things separating one such rule from the next. The
    // profile is always named because Windows ships the same rule text twice,
    // once for 域 and once for 专用/公用; without it the two read identically.
    const tail = isZh
      ? [
        groupTxt ? `它属于「${groupTxt}」这一组` : null,
        family ? `这条规则来自应用包 ${family}` : null,
      ].filter(Boolean).join('；')
      : [
        groupTxt ? `It belongs to the group "${groupTxt}".` : null,
        family ? `The rule comes from the app package ${family}.` : null,
      ].filter(Boolean).join(' ');

    out.purpose = descIsOwn
      ? S(
        `这条规则的说明原文是：「${clip(ownDesc, 140)}」这条只对「${profilesRaw || '未写明'}」网络生效${blocking ? '，它的作用是拦截' : '，它的作用是放行'}${app ? `，管的是「${baseName(app)}」这个程序` : ''}。${tail ? `${tail}。` : ''}`,
        `The rule's own description reads: "${clip(ownDesc, 140)}" It applies only on the "${profiles || 'unspecified'}" profile${blocking ? ' and its job is to block' : ' and its job is to allow'}${app ? `, for the program "${baseName(app)}"` : ''}.${tail ? ` ${tail}` : ''}`,
      )
      : S(
        `这条规则没有写说明文字（描述字段和规则名一样）。能确定的是：方向 ${inbound ? '入站' : '出站'}、动作 ${blocking ? '阻止' : '允许'}、协议 ${proto}${hasPorts ? `、本机端口 ${lp}` : '、端口不限'}${app ? `、程序 ${baseName(app)}` : ''}${rp && rp !== '*' ? `、远端端口 ${rp}` : ''}、适用于「${profilesRaw || '未写明'}」网络。${tail ? `${tail}。` : ''}`,
        `This rule carries no description of its own (the field just repeats the name). What is certain: direction ${inbound ? 'inbound' : 'outbound'}, action ${blocking ? 'block' : 'allow'}, protocol ${proto}${hasPorts ? `, local port ${lp}` : ', any port'}${app ? `, program ${baseName(app)}` : ''}${rp && rp !== '*' ? `, remote port ${rp}` : ''}, on the "${profiles || 'unspecified'}" profile.${tail ? ` ${tail}` : ''}`,
      );

    // A packaged rule's name can be a resource key ("ms-resource:ProductPkg…"),
    // which is unreadable in the lists UI too; then point at the program/port
    // columns instead of pretending there is a name to look for.
    const ruleName = usable(entry.name);
    const ruleRef = ruleName
      ? S(`中的「${ruleName}」`, ` the entry named "${ruleName}"`)
      : S(
        `中，${app ? `按「程序」列找 ${baseName(app)}` : hasPorts ? `按「本地端口」列找 ${lp}` : `按${family ? `「组」列找 ${family}` : '方向列'}`}`,
        ` ${app ? `look for ${baseName(app)} in the Program column` : hasPorts ? `look for port ${lp} in the Local Port column` : `filter by ${family ? `the group ${family}` : 'direction'}`}`,
      );
    out.where = S(
      `Windows 安全中心 →「防火墙和网络保护」→「高级设置」里「${inbound ? '入站规则' : '出站规则'}」${ruleRef}。`,
      `Windows Security > Firewall & network protection > Advanced settings > ${inbound ? 'Inbound' : 'Outbound'} rules:${ruleRef}.`,
    );

    out.ifOff = S(
      `${blocking ? '关掉这条阻止规则等于放行——原来被挡住的流量就能进来了' : '关掉这条放行规则等于拦截——原来能用这个程序的连接就会断'}。它是可随时拨回的开关，不涉及删除。`,
      `${blocking ? 'Turning a block rule off is the same as allowing: traffic that was stopped can now get through' : 'Turning an allow rule off is the same as blocking: connections that worked will now fail'}. It is a switch that can be flipped back; nothing is deleted.`,
    );

    if (blocking) fact('动作', 'Action', S('阻止（Block）', 'Block'));
    fact('方向', 'Direction', inbound ? S('入站', 'inbound') : S('出站', 'outbound'));
    fact('协议', 'Protocol', proto);
    if (hasPorts) fact('本机端口', 'Local port', lp);
    if (rp && rp !== '*') fact('远端端口', 'Remote port', rp);
    fact('网络配置文件', 'Profile', profiles);
    if (group) fact('所属组', 'Group', group);
    if (svc) fact('绑定服务', 'Bound service', svc);
    if (app) fact('程序路径', 'Program', app);
    if (d.indirect === true || family) {
      fact('名称来源', 'Name source', family
        ? S(`规则名是应用包的资源字符串，属于应用包 ${family}`, `resolved from the resource strings of app package ${family}`)
        : S('规则名是系统资源字符串，已解析为可读名', 'resolved from a system resource string'));
    }
    return finalize(out);
  }

  // ---- IFEO -----------------------------------------------------------------
  if (entry.source === 'ifeo') {
    const exe = txt(d.exe) || txt(entry.name);
    const hijacked = d.hijacked === true;
    const dbg = usable(d.debugger);
    const mit = txt(d.mitigation);
    const cfg = txt(d.cfg);
    const gf = txt(d.globalFlag);
    const unknown = Array.isArray(d.unknown) ? d.unknown.filter(Boolean).map((x) => txt(x)).filter(Boolean) : [];
    const keyPath = `HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Image File Execution Options\\${exe}`;

    if (hijacked) {
      // This is the finding. State it plainly and say what it means in practice,
      // because the user's next action is "is this mine or not".
      out.what = S(
        `启动「${exe}」时 Windows 实际运行的是「${dbg || '另一个文件'}」，原程序根本不会启动。`,
        `Launching "${exe}" actually runs "${dbg || 'another file'}"; the original program never starts.`,
      );
      out.where = S(`注册表 ${keyPath}。`, `Registry ${keyPath}.`);
      out.purpose = S(
        '正常系统里，一个程序的 IFEO 条目只会存兼容性和漏洞缓解开关；出现 Debugger 值意味着「让 A 去启动 B」，这是恶意软件最常见的持久化手法之一。它不会弹窗，也不会在任务管理器里留下明显的进程名。',
        'On a normal machine an IFEO entry only holds compatibility and mitigation switches; a Debugger value means "when A starts, run B instead", which is one of the most common malware persistence tricks. Nothing pops up and no obvious process name appears in Task Manager.',
      );
      out.ifOff = S(
        '不要在这里「启用/禁用」——正确做法是删掉该程序的 Debugger 值（需要管理员），并先查清这个 Debugger 指向的文件是什么、由谁写入的。',
        'Do not "toggle" it here: the fix is to delete that Debugger value (needs admin), after finding out what the Debugger file is and who wrote it.',
      );
      out.origin = 'thirdparty';
      out.originName = dbg;
      fact('Debugger（实际运行的文件）', 'Debugger (what actually runs)', dbg);
      fact('注册表路径', 'Registry key', keyPath);
      fact('注册表视图', 'Registry view', String(d.view ?? ''));
      return finalize(out);
    }

    const bits = [];
    if (mit) bits.push(S(`漏洞缓解开关 MitigationOptions=${mit}`, `the exploit-mitigation switch MitigationOptions=${mit}`));
    if (cfg) bits.push(S(`控制流防护 CFGOptions=${cfg}`, `control-flow guard CFGOptions=${cfg}`));
    if (gf) bits.push(S(`内核调试开关 GlobalFlag=${gf}`, `the debug flag GlobalFlag=${gf}`));
    if (unknown.length) bits.push(S(`非标准值 ${unknown.join('、')}`, `non-standard values ${unknown.join(', ')}`));

    // 同一个 exe 会在 64 位和 32 位两个注册表视图里各留一条，两条的开关值
    // 往往一模一样——视图是唯一能把它们分开的真实信息，所以要写进正文。
    const view = txt(d.view);
    const viewTxt = view ? S(`（${view} 位注册表视图）`, ` (${view}-bit registry view)`) : '';

    out.what = S(
      `给「${exe}」单独设的 IFEO 条目${viewTxt}${bits.length ? `：${bits.join('，')}` : '（键存在但里面没有任何开关值）'}；它不是启动项，也不会让这个程序换一个可执行文件启动。`,
      `An IFEO entry set only for "${exe}"${viewTxt}${bits.length ? `: ${bits.join(', ')}` : ' (the key exists but holds no switches)'}. It is not a startup entry and it does not redirect the program to another executable.`,
    );

    out.where = S(`注册表 ${keyPath}。`, `Registry ${keyPath}.`);

    out.purpose = S(
      `${bits.length ? `这里存的是 Windows 逐程序设置的安全/兼容开关，${bits[0]}。` : '这个键存在，但下面没有登记任何开关值。'}它只在「${exe}」这个进程启动时被读一次，改的是这个进程的防护策略，不改它做什么。${view ? `这一条在 ${view} 位注册表视图里；另一视图里的同名条目是独立的一份设置。` : ''}`,
      `${bits.length ? `What lives here are Windows' per-program safety/compatibility switches, starting with ${bits[0]}.` : 'The key exists but registers no switches underneath it.'} It is read once when "${exe}" starts, and it changes that process' protection policy, not what the process does.${view ? ` This copy lives in the ${view}-bit registry view; the same-named entry in the other view is a separate setting.` : ''}`,
    );

    out.ifOff = S(
      '这一版只读：可以看有哪些 IFEO 条目，但不提供删除。删错会让对应的兼容性修复或漏洞缓解失效——它消失时不会有任何提示。',
      'Read-only in this version: you can see which IFEO entries exist, but not remove them. Removing the wrong one silently drops a compatibility fix or a mitigation - nothing warns you.',
    );

    if (mit) fact('MitigationOptions', 'MitigationOptions', mit);
    if (cfg) fact('CFGOptions', 'CFGOptions', cfg);
    if (gf) fact('GlobalFlag', 'GlobalFlag', gf);
    if (unknown.length) fact('非标准值（值得看一眼）', 'Non-standard values (worth a look)', unknown.join(', '));
    fact('注册表视图', 'Registry view', String(d.view ?? ''));
    return finalize(out);
  }

  // ---- file associations ----------------------------------------------------
  if (entry.source === 'fileexts') {
    const ext = txt(d.name) || txt(entry.name);
    const progId = usable(d.progId);
    const cmd = usable(d.command);
    const state = txt(d.state);
    const owp = Array.isArray(d.openWithProgids) ? d.openWithProgids.filter(Boolean).map((x) => txt(x)).filter(Boolean) : [];
    const owl = Array.isArray(d.openWithList) ? d.openWithList.filter(Boolean).map((x) => txt(x)).filter(Boolean) : [];
    const isAppx = /^AppX/i.test(progId);
    // The wrapper must follow the sentence's language: using 「」 inside the
    // English sentence produced `opens it with 「360zip.VOLUME」` on 67 rows.
    const appLabel = isAppx
      ? S('一个商店应用（ProgId 是 AppX 开头的包内标识，系统不显示它）', 'a Store app (its ProgId starts with AppX - an in-package id the system never shows)')
      : (progId ? (isZh ? `「${progId}」` : `"${progId}"`) : '');

    if (state === 'userchoice' && progId) {
      out.what = S(
        `双击 ${ext} 文件会用 ${appLabel} 打开${cmd ? `，实际执行的是 ${clip(cmd, 100)}` : isAppx ? '' : '，注册表里没有登记命令行'}。`,
        `Double-clicking a ${ext} file opens it with ${appLabel}${cmd ? `, i.e. the command ${clip(cmd, 100)}` : isAppx ? '' : ', though no command line is registered'}.`,
      );
      out.purpose = S(
        `这是你（或某个安装程序）给 ${ext} 选定的默认程序，Windows 把它锁在当前用户名下：文件里带一个与用户绑定的哈希（${d.hashPresent === true ? '实测存在' : '实测缺失'}），所以工具绕开它去改会被系统自动改回来。${owp.length ? `「打开方式」里另外还有 ${owp.length} 个候选（${owp.slice(0, 4).join('、')}）。` : ''}`,
        `This is the default program chosen for ${ext}, locked to this user account: the record carries a user-bound hash (${d.hashPresent === true ? 'present in the measurement' : 'absent in the measurement'}), so edits that skip it get reverted by Windows.${owp.length ? ` "Open with" additionally lists ${owp.length} candidate(s).` : ''}`,
      );
    } else if (state === 'openwith') {
      out.what = S(
        `${ext} 没有设定默认程序，只登记了「打开方式」里的候选（${owp.length} 个）${owl.length ? `和旧式列表 ${owl.length} 项` : ''}。`,
        `${ext} has no default program; only ${owp.length} "Open with" candidate(s) ${owl.length ? `and ${owl.length} legacy list item(s) ` : ''}are registered.`,
      );
      out.purpose = S(
        `${ext} 没有设定默认程序，只登记了 ${owp.length} 个「打开方式」候选${owl.length ? `和 ${owl.length} 项旧式列表` : ''}${owp.length ? `（${owp.slice(0, 4).join('、')}）` : ''}。没有默认程序意味着双击这种文件时 Windows 会让你每次选一个；这一条只是候选列表，不是「用谁打开」的决定。`,
        `${ext} has no default program, only ${owp.length} "Open with" candidate(s)${owl.length ? ` and ${owl.length} legacy item(s)` : ''}${owp.length ? ` (${owp.slice(0, 4).join(', ')})` : ''}. No default means Windows asks you to pick each time you double-click such a file; this row is the candidate list, not the decision.`,
      );
    } else if (state === 'empty') {
      out.what = S(
        `${ext} 的 UserChoice 键存在，但里面一个值都没有——通常是卸载某个软件后留下的空壳。`,
        `The ${ext} UserChoice key exists but holds no values at all - usually an empty shell left behind when an app was uninstalled.`,
      );
      out.purpose = S(
        `${ext} 的这一条正是「双击这个文件没反应 / 总是弹出选择框」的常见原因：系统以为你已经选过默认程序，实际上那个决定是空的${d.hashPresent === true ? '（哈希值还在，只是没有 ProgId）' : '（连哈希值都没有）'}。${owl.length ? `旧式列表里还留着 ${owl.length} 项（${owl.slice(0, 3).join('、')}）。` : ''}`,
        `This ${ext} row is a common cause of "double-click does nothing / it keeps asking": Windows believes a default was chosen, while the decision is empty${d.hashPresent === true ? ' (the hash is still there, but there is no ProgId)' : ' (not even a hash)'}.${owl.length ? ` The legacy list still holds ${owl.length} item(s) (${owl.slice(0, 3).join(', ')}).` : ''}`,
      );
    } else {
      out.what = S(
        `${ext} 的关联记录（状态「${state || '未报告'}」）${progId ? `，指向 ${appLabel}` : ''}。`,
        `The association record for ${ext} (state "${state || 'not reported'}")${progId ? `, pointing at ${appLabel}` : ''}.`,
      );
      // state "none" is the probe saying "this key exists but describes nothing":
      // no ProgId, no command, no candidates, no hash. Saying that out loud is
      // the honest thing - it is not a broken association, it is an empty one.
      out.purpose = progId
        ? S(
          `这一条登记了 ProgId「${progId}」，但没有给出可用的打开命令${cmd ? '' : '（命令行是空的）'}。它说明这种文件类型被某个程序"认领"过，能不能真的打开要看那个程序还在不在。`,
          `This row names the ProgId "${progId}" but supplies no usable open command${cmd ? '' : ' (the command line is empty)'}. It means some program once claimed this file type; whether it can actually open the file depends on that program still being installed.`,
        )
        : S(
          `这条记录是空的：没有 ProgId、没有打开命令、没有候选程序、也没有哈希。它不代表 ${ext} 用了哪个程序打开，只说明注册表里留着这么一个键${owl.length ? `，旧式列表里还有 ${owl.length} 项（${owl.slice(0, 3).join('、')}）` : ''}。判断 ${ext} 用什么打开，得看有没有 userchoice 状态的那一条。`,
          `This record is empty: no ProgId, no open command, no candidates and no hash. It does not say which program opens ${ext} - it only means this key exists${owl.length ? ` with ${owl.length} legacy item(s) (${owl.slice(0, 3).join(', ')})` : ''}. To see what actually opens ${ext}, look for the row whose state is userchoice.`,
        );
    }

    out.where = S(
      `「设置 → 应用 → 默认应用」里 ${ext} 的默认程序；也可以在某个 ${ext} 文件上右键 →「打开方式」。`,
      `The default for ${ext} under Settings > Apps > Default apps, or right-click a ${ext} file > Open with.`,
    );

    out.ifOff = S(
      '这一版只读。这类关联不能在这里直接改：Windows 会给 UserChoice 算一个和当前用户绑死的哈希，绕过它写入的值会被系统自动改回去。要换默认程序，请走系统自带的「默认应用」界面。',
      'Read-only in this version. These associations cannot be edited here: Windows computes a hash over UserChoice bound to this user, and anything written past it is silently reverted. Change the default through Settings > Default apps.',
    );

    if (progId) fact('ProgId', 'ProgId', progId);
    if (cmd) fact('打开命令', 'Open command', cmd);
    if (owp.length) fact('「打开方式」候选', '"Open with" candidates', owp.join(', '));
    if (owl.length) fact('旧式「打开方式」列表', 'Legacy open-with list', owl.join(', '));
    if (progId) {
      fact('哈希', 'Hash', d.hashPresent === true
        ? S('存在（与当前用户绑定）', 'present (bound to this user)')
        : S('缺失（关联可被工具直接改写）', 'absent (tools can rewrite the association)'));
    }
    return finalize(out);
  }

  // ---- credential providers -------------------------------------------------
  if (entry.source === 'credprov') {
    const clsid = txt(d.clsid);
    const dll = txt(d.dll);
    const label = usable(d.purpose) || usable(d.displayName);
    const dllName = baseName(dll) || '未登记的 DLL';
    const inSys = d.inSystemDir === true;
    const missing = d.dllMissing === true;

    out.what = S(
      `登录/锁屏界面上的一个登录方式${label ? `：「${label}」` : ''}，由 ${dllName}.dll 实现${missing ? '（但这个文件已经不在了）' : ''}。`,
      `One of the sign-in options on the logon / lock screen${label ? `: "${label}"` : ''}, implemented by ${dllName}.dll${missing ? ' (that file is gone, though)' : ''}.`,
    );

    out.purpose = label
      ? S(
        `具体到这一个：它是「${label}」这个登录选项背后的组件。${inSys ? 'DLL 在 System32 里，属于 Windows 自带的那一批。' : 'DLL 不在 Windows 目录里，是第三方加的登录方式。'}`,
        `For this row specifically: it is the component behind the "${label}" sign-in option. ${inSys ? 'Its DLL sits in System32, so it ships with Windows.' : 'Its DLL is outside the Windows directory, so this is a third-party sign-in method.'}`,
      )
      : S(
        `它是锁屏界面上的一个登录方式，DLL 是 ${dllName}.dll${inSys ? '（在 System32 里）' : '（不在 Windows 目录里）'}；系统没有给出它的中文用途说明。`,
        `A sign-in option on the lock screen, backed by ${dllName}.dll${inSys ? ' in System32' : ' outside the Windows directory'}; Windows offers no friendly label for it.`,
      );

    out.where = S(
      `登录/锁屏界面上${label ? `「${label}」` : '列出的'}那个登录选项。`,
      `The ${label ? `"${label}" ` : ''}option on the logon / lock screen.`,
    );

    if (missing) {
      out.ifOff = S(
        '它注册的 DLL 已经不在了，所以这个登录方式在界面上会被跳过——这正是「PIN/指纹选项突然消失」的常见原因，删掉这条注册即可。',
        'The DLL it registers is gone, so this sign-in option is skipped on the logon screen - a common cause of "my PIN/fingerprint option vanished". Deleting this registration is the fix.',
      );
    } else if (!inSys) {
      out.ifOff = S(
        '这个 DLL 不在 Windows 目录里，属于第三方登录组件。它能看到锁屏时输入的口令，所以来源不明的提供程序值得核实一下。',
        'This DLL is not in the Windows directory, so it is a third-party sign-in component. It can see what is typed at the lock screen, so an unknown one is worth checking.',
      );
    } else {
      out.ifOff = S(
        '这一版只读。删掉一个提供程序会直接改变你能用什么方式登录，有把自己锁在系统外面的风险，所以不提供开关。',
        'Read-only in this version. Removing a provider changes how you can sign in, with a real risk of locking yourself out, so no toggle is offered.',
      );
    }

    if (!inSys && !isSystemPath(dll)) {
      out.origin = 'thirdparty';
      out.originName = dllName;
    } else {
      out.origin = 'microsoft';
      out.originName = 'Microsoft';
    }

    fact('实现文件', 'Implemented by', dll);
    fact('在 System32 里', 'In System32', inSys ? S('是', 'yes') : S('否', 'no'));
    if (missing) fact('DLL 是否存在', 'DLL present', S('否——注册残留', 'no - leftover registration'));
    fact('CLSID', 'CLSID', clsid);
    return finalize(out);
  }

  // ---- system repair findings ----------------------------------------------
  // One row per check. `detail` carries the probe's own measured sentence (with
  // the "期望 / 实测" pair) and the suggested fix; the explanation adds what the
  // check is FOR and what a deviation would mean, without inventing anything the
  // probe did not measure.
  if (entry.source === 'repair') {
    const checkId = txt(d.id);
    const status = txt(d.status || entry.state);
    const measured = txt(d.detail);
    const fixText = txt(d.fix);
    const label = usable(d.label) || usable(entry.name) || checkId;
    const checkWhat = CHECK_WHAT[checkId];

    out.what = checkWhat
      ? S(
        `${pick(checkWhat, 'zh')}；这一项测的是「${label}」，目前结论是「${status || '未报告'}」。`,
        `${pick(checkWhat, 'en')}; this row covers "${label}" and the current verdict is "${status || 'not reported'}".`,
      )
      : S(
        `一项系统配置检查「${label}」，目前结论是「${status || '未报告'}」。`,
        `A configuration check named "${label}"; the current verdict is "${status || 'not reported'}".`,
      );

    // Where the user meets this setting, per check.
    const WHERE = {
      hosts: {
        zh: 'C:\\Windows\\System32\\drivers\\etc\\hosts。浏览器访问任何域名前，Windows 都会先查这个文件；命中就按文件里的地址走，不再去问 DNS。',
        en: 'C:\\Windows\\System32\\drivers\\etc\\hosts. Before any domain is reached Windows consults this file; a hit there overrides DNS entirely.',
      },
      ie: {
        zh: 'HKCU\\Software\\Microsoft\\Internet Explorer\\Main。「IE 选项」里的主页与搜索页就存在这里，其他程序（包括部分国产浏览器）也会读它。',
        en: 'HKCU\\Software\\Microsoft\\Internet Explorer\\Main. The home page and search page from Internet Options live here, and other programs (including some Chinese browsers) read them too.',
      },
      dns: {
        zh: '每块网卡的「Internet 协议版本 4 (TCP/IPv4) 属性」里那个「使用下面的 DNS 服务器地址」。',
        en: 'The "Use the following DNS server addresses" field in each adapter\'s IPv4 properties.',
      },
      netconn: {
        zh: 'HKLM\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters。TCP 连接数相关的隐藏调优值放在这里，默认一个都不存在。',
        en: 'HKLM\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters. The hidden TCP tuning values live here, and by default none of them exist.',
      },
      uac: {
        zh: '控制面板 →「用户账户」→「更改用户账户控制设置」那个滑块，背后就是这几个值。',
        en: 'The slider under Control Panel → User Accounts → Change User Account Control settings is backed by these values.',
      },
      redundant: {
        zh: '任务管理器的「启动」选项卡，以及「设置 → 应用 → 已安装的应用」列表。',
        en: 'The Startup tab of Task Manager, and the installed-apps list under Settings → Apps.',
      },
      fontcache: {
        zh: 'C:\\Windows\\ServiceProfiles\\LocalService\\AppData\\Local\\FontCache，由 FontCache 服务维护；字体渲染变慢或界面字体错乱时才会想起来看它。',
        en: 'C:\\Windows\\ServiceProfiles\\LocalService\\AppData\\Local\\FontCache, maintained by the FontCache service. You only think about it when font rendering slows down or glyphs go wrong.',
      },
      iconcache: {
        zh: '%LOCALAPPDATA%\\Microsoft\\Windows\\Explorer 下的 iconcache_*.db，由资源管理器维护；图标变白纸或串图时才会想起来看它。',
        en: 'The iconcache_*.db files under %LOCALAPPDATA%\\Microsoft\\Windows\\Explorer, maintained by Explorer. You only think about them when icons go blank or swap around.',
      },
    };
    const where = WHERE[checkId];
    if (where) out.where = pick(where, lang);

    out.purpose = measured || null;

    if (status === 'ok') {
      out.ifOff = S(
        '实测值与期望一致，不需要处理。',
        'The measured value matches what is expected; nothing to do.',
      );
    } else if (status === 'skip') {
      out.ifOff = S(
        '这一项在本机测不到（原因见下方「实测」），所以没有给出结论——按「测不到就说测不到」处理，不猜测。',
        'This check could not be measured on this machine (the reason is in the measurement below), so no verdict is given - it reports "could not measure" rather than guessing.',
      );
    } else if (fixText) {
      out.ifOff = S(
        `不处理的话，这项偏差会一直存在。可行的修复：${fixText}`,
        `Left alone, this deviation stays. The available fix: ${fixText}`,
      );
    }

    fact('检查项', 'Check', label);
    fact('实测值', 'Measured', d.value);
    fact('结论', 'Verdict', status);
    fact('分组', 'Group', d.group);
    if (d.needsAdmin === true) fact('需要管理员', 'Needs admin', S('是', 'yes'));
    return finalize(out);
  }

  return finalize(out);
}

/** Drop empty fields so the UI never renders a blank labelled line. */
function finalize(o) {
  o.facts = (o.facts ?? []).filter((f) => Array.isArray(f) && f[1]);
  if (!o.what && !o.purpose && !o.where) return null;
  return o;
}

/**
 * Attach `explain` to every entry. Called from inventory after normalize so the
 * panel, the tools and the render test all see the same text.
 */
export function attachExplanations(entries, lang = LANG) {
  for (const e of entries) {
    try {
      e.explain = explainEntry(e, lang);
    } catch {
      e.explain = null;
    }
  }
  return entries;
}

export const EXPLAIN_TABLES = { SOURCE_KIND, SHELLX_PLACEMENT, HANDLER_KIND_GLOSS };
