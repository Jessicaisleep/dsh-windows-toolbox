/**
 * dsh-360-toolbox — Client half: the 工作栏 panel.
 *
 * Pure ESM loaded through window.__ModuleLoader__. React comes from the host
 * module table (require('react')); NO host Client UI package is imported
 * (practices.md), and styling uses only --dsw-alias-* theme tokens so light and
 * dark themes are inherited.
 *
 * Shape of the panel: one card per capability, grouped into cleanup / system / network /
 * apps. A group tab row narrows the capability strip, and one result area below
 * renders the selected capability. Nothing here hardcodes a capability id list —
 * groups, cards and badges are all derived from the /status catalogue, so adding
 * a capability on the host side needs no client change. The only literals are the
 * `view` dispatch (junk / files / groups / steps get a dedicated table, everything
 * else falls through to the generic ChecksList) and `id === 'junk'`, the one
 * capability that can delete files.
 *
 * Row shapes: junk → whitelist targets; files → big files; groups → duplicate
 * groups; steps → network diagnosis steps; checks → the unified
 * { id, group, label, status, value, detail, fix, needsAdmin } row used by the
 * other 19 capabilities. Every capability normalizes to { items, meta }.
 *
 * Honesty rules enforced here: a capability's `coverage` badge is always shown
 * when it is not `full` (partial = amber, readonly = grey, blocked = red with the
 * probe's reason in the tooltip), `status: 'skip'` check rows are dimmed and
 * always carry a reason, and the "apply" path always runs a dry run first — the
 * confirm dialog is the only place that sends dryRun:false.
 *
 * The first paint deliberately runs NO scan: /status only reports what is cached.
 * bigfiles takes 14 s and dupfiles 39 s on this machine, so auto-scanning on open
 * would make the panel feel broken.
 */
window.__ModuleLoader__.load({
  id: 'dsh-360-toolbox',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    const { useState, useEffect, useCallback, useMemo, useRef } = React;

    const NS = 'dsh-360-toolbox';
    const PANEL_ID = 'dsh-360-toolbox';
    const API = '/dsh-360-toolbox/api';

    const DICT = {
      zh: {
        nav: '360 工具箱',
        title: '360 工具箱',
        subtitle: '{n} 项系统维护能力，按「清理与空间 / 系统与安全 / 网络 / 应用与外壳」分组。每项都给出实测值与判定依据，并且明确标出哪些做不到、为什么做不到。',
        scopeNote: '只有「垃圾清理」会删除文件，且只清固定白名单内的缓存内容（目录本身保留）；「文件粉碎机」需你自己指定文件并二次确认。其余能力只读报告，或先预演再执行。',
        hostElevated: '已提权',
        hostNormal: '未提权',
        hostNormalHint: '需要管理员权限的目标（系统临时文件、更新缓存、预读取）会被明确跳过，不会假装清理。',
        loadFailed: '加载失败',
        scan: '开始扫描',
        rescan: '重新扫描',
        scanning: '扫描中…',
        notScanned: '尚未扫描。点「开始扫描」获取结果。',
        cachedHint: '缓存结果，重新扫描可更新',
        clean: '清理',
        cleaning: '清理中…',
        cleaningAll: '全部清理',
        dryRunNotice: '预演：下面是将要删除的内容，尚未删除',
        freedNotice: '已清理',
        confirmTitle: '确认清理',
        confirmBody: '将删除以下位置的缓存内容（目录本身保留）。此操作不可撤销。',
        confirmCancel: '取消',
        confirmOk: '确认删除',
        planTotal: '将释放',
        planFiles: '文件数',
        planBlocked: '需管理员权限、会被跳过',
        planMeasuring: '正在测算选中目标…',
        planFailed: '无法测算，已取消',
        needAdmin: '需要管理员权限',
        nothingHere: '该位置不存在或为空',
        elevationHint: '未提权：勾选需要管理员权限的目标会被跳过',
        selectAll: '全选',
        selectNone: '全不选',
        selectedSummary: '已选',
        colTarget: '位置',
        colSize: '大小',
        colFiles: '文件数',
        colState: '状态',
        colPath: '路径',
        colActions: '操作',
        colName: '名称',
        colFolder: '所在目录',
        colWasted: '可回收',
        colCount: '重复数',
        colStatus: '结果',
        colValue: '实测值',
        colNote: '说明',
        rootLabel: '扫描范围',
        minMbLabel: '最小大小 (MB)',
        minKbLabel: '最小大小 (KB)',
        statusOk: '正常',
        statusWarn: '注意',
        statusBad: '异常',
        statusFail: '失败',
        statusSkip: '跳过',
        statusInfo: '信息',
        totalJunk: '可清理',
        totalFiles: '个文件',
        scannedFiles: '扫描文件数',
        matchedFiles: '命中',
        truncated: '（已达到时间上限，结果为部分）',
        groupsCount: '组重复',
        wastedTotal: '可回收空间',
        netOnline: '外网连通',
        netOffline: '外网不通',
        netVerdict: '结论',
        adapters: '网卡',
        dnsServers: 'DNS 服务器',
        proxyOn: '系统代理：已开启',
        proxyOff: '系统代理：未开启',
        hostsBlocked: 'hosts 屏蔽',
        error: '错误',
        none: '无',
        ms: 'ms',
        expand: '展开',
        collapse: '收起',
        riskReadonly: '只读',
        riskDestructive: '破坏性',
        fileCount: '个文件',
        itemsUnit: '项结果',
        rowsUnit: '行',
        noRows: '这次没有返回任何检查项',
        groupOther: '其他',
        groupCleanup: '清理与空间',
        groupSystem: '系统与安全',
        groupNetwork: '网络',
        groupApps: '应用与外壳',
        covPartial: '部分覆盖',
        covReadonly: '只读',
        covBlocked: '做不到',
        needAdminBadge: '需管理员',
        skippedWhy: '未测到：探针在这一项上跳过了，原因见上',
        apply: '执行修复',
        applying: '修复中…',
        applyTitle: '确认执行修复',
        applyBody: '这一步才是真的改动。宿主已先跑过一遍预演（dryRun），下面是它返回的条目；确认后才会以 dryRun=false 执行，能自动备份的会先备份。',
        applyPlan: '预演条目',
        applyDone: '修复已执行',
        ssdWarn: '注意：本机磁盘全部是 SSD 且 TRIM 已开启，覆盖写无法保证物理擦除——真正的解法是全盘加密。',
    dnsPickServer: '切换到这个 DNS',
    dnsPickAuto: '改回自动获取（DHCP）',
    dnsPickCurrent: '当前 DNS：',
    dnsPickNeed: '请先选择一个 DNS 服务器',
        elevNot: '当前未提权 · 部分项目的修复与清理需要管理员',
        elevRequest: '请求提权',
        elevRequesting: '等待 UAC 确认…',
        elevCancelled: '你取消了 UAC 提权',
        elevDone: '提权进程已返回结果',
        elevFailed: '提权失败',
    elevGranted: '已获得管理员权限 · 两个页签现在都能直接执行，不会再弹 UAC',
        formTitle: '执行参数',
        formPreview: '先预演',
        formNeed: '先把参数填好，才能执行',
        homepageTarget: '写入目标',
        homepageUrl: '主页地址',
        homepageUrlBad: '必须以 http(s):// 或 about: 开头',
        backupKeys: '要导出的注册表键（至少 1 个）',
        backupKeysBad: '每行一个键，形如 HKCU:\\Software\\... 或 HKLM:\\SOFTWARE\\...',
        cmClsid: '完整 CLSID',
        cmNoClsid: '这条记录没有完整 CLSID，无法安全操作',
        cmClsidBad: 'CLSID 必须是完整 GUID（8-4-4-4-12）',
        cmScope: '写入位置',
        scopeMachine: 'HKLM（所有用户，需管理员）',
        scopeUser: 'HKCU（当前用户）',
        shredPaths: '要覆盖删除的文件（每行一个绝对路径，最多 50 个）',
        shredBad: '每行必须是盘符开头的绝对路径，不能含通配符，最多 50 个',
        tweakIds: '要改的项',
        tweakOn: '应用',
        tweakOff: '还原',
        wsSetting: '设置项',
        wsValue: '新值',
        wsValueNeed: '先填新值',
        wsValueInt: '这一项是整数类型，新值必须是整数',
        softAction: '动作',
        softAppName: '应用名（清扫残留必填）',
        softAppNeed: '清扫残留需要应用名',
        actUpgrade: '升级清单',
        actLeftover: '清扫残留',
        actMigrate: '搬家可行性',
        actPerm: '软件权限',
        rowNeedsForm: '先在上面表单填好参数，这一行才能执行',
        nextStep: '下一步',
        goTo: '切到',
        reread: '重新读取',
        nextBigfilesHit: '这些只是列出来，不会删除；若其中有重复副本，去「重复文件」看能否回收',
        nextBigfilesNone: '没有超过阈值的大文件；想腾空间先看「系统盘瘦身」的可回收量',
        nextDupHit: '这些组只做报告不会删；先确认不是备份或安装包，再决定怎么处理',
        nextDupNone: '没找到重复文件：同一份内容没有被发现多个副本',
        nextNetFail: '断在这一段：',
        nextNetOk: '全链路连通；若某些站点仍打不开，多半在 DNS 或 hosts，上面已列出实测值',
        nextHealthBad: '有异常项，先处理磁盘与服务，再复扫确认',
        nextHealthOk: '这台机器当前没有需要立刻处理的异常',
        nextSecurityBad: '这些是策略层面的风险：改注册表或策略需要管理员，未提权时只能看',
        nextSecurityOk: '策略项都在期望值上，无需改动',
        nextPrivacyMeta: '隐私项只能在「设置」里逐项关，这里给出的是实测状态',
        nextPermBroad: '这些应用拿到了较宽的设备或文件系统权限，去「设置 → 隐私」逐个收窄',
        nextPermOk: '没有应用拿到超宽的摄像头或麦克风权限',
        nextPopupHit: '这些是弹窗来源；先停计划任务，再按需卸载软件',
        nextPopupNone: '没有发现明显的弹窗来源进程或计划任务',
        nextSpeedtestSlow: '延迟偏高，先排除本机占用与无线信号，再对比运营商带宽',
        nextSpeedtestOk: '实测带宽与延迟见上；与套餐对比时按有线下限判断',
        nextSlimSafe: '可安全回收的量见上，不需要你逐个判断，可直接切到垃圾清理按白名单清',
        nextSlimNone: '没有可安全回收的大头；pagefile 与休眠文件的调整要重启才生效',
        nextRescuePending: '有挂起的重启操作，先重启再做后续修复',
        nextRescueOk: '没有挂起的重启，也没有最近的严重事件',
        nextSoftwareHit: '官网目录命中的已装软件见上；升级走「软件管家进阶」的升级清单',
        nextSoftwareNone: '没有命中官网目录的软件',
        nextDriversBad: '有缺驱动或报问题的设备：优先用厂商入口装官方驱动，别用第三方驱动包',
        nextDriversOk: '没有缺驱动或未签名的设备',
        nextDrivers2Missing: '这些设备缺驱动；先确认硬件型号，再下官方驱动',
        nextDrivers2Ok: '没有发现缺驱动的硬件',
        nextPhoneOff: '没有已配对的手机；接上 USB 后回到这里复扫',
        nextPhoneOk: '手机已连接；若资源管理器看不到设备，先看 WPD/MTP 驱动那一行',
        nextJunkNone: '没有可清理的缓存内容',
        nextProcBusy: 'CPU/内存占用最高的进程已在上面；先确认是不是你在用的程序，再决定是否结束它',
        nextProcIdle: '当前没有明显吃 CPU 或内存的进程，不用处理',
        nextDiskBad: '有硬盘已经报出预警，先把这块盘上的数据备份出去，再考虑换盘',
        nextDiskOk: '没有盘报预警；SMART 详细读数未提权时读不到，需要时点「请求提权」再扫一次',
        nextDiskSkip: 'SMART 详细读数需要管理员权限，当前只有 Win32 兜底数据，判断力有限',
        cap_junk: '垃圾清理',
        cap_bigfiles: '大文件查找',
        cap_dupfiles: '重复文件',
        cap_netdiag: '断网诊断',
        cap_health: '系统体检',
        cap_proc: '任务管理器',
        cap_diskhealth: '硬盘健康',
        cap_security: '系统安全防护',
        cap_privacy: '隐私保镖',
        cap_perm: '权限管理',
        cap_popup: '弹窗过滤',
        cap_speedtest: '宽带测速',
        cap_homepage: '主页防护',
        cap_slim: '系统盘瘦身',
        cap_rescue: '系统急救箱',
        cap_backup: '备份还原',
        cap_software: '软件管家',
        cap_softmgr: '软件管家进阶',
        cap_drivers: '驱动清单',
        cap_drivers2: '驱动更新检查',
        cap_contextmenu: '右键管理',
        cap_winsettings: 'WINDOWS 设置',
        cap_phone: '手机助手',
        cap_tweaks: '优化预设',
        cap_shredder: '文件粉碎机',
        tag_junk: '扫描固定白名单内的缓存，可直接清理',
        tag_bigfiles: '按大小列出占空间的文件，只报告',
        tag_dupfiles: '三阶段哈希找出真正重复的文件，只报告',
        tag_netdiag: '从网卡到外网逐段判定，指出断在哪',
        tag_health: '磁盘、内存、服务、设备、防护一次过一遍',
        tag_proc: '谁在偷吃 CPU、内存和磁盘',
        tag_diskhealth: '提前发现硬盘要坏的前兆',
        tag_security: 'UAC、Defender、SMB、RDP、Autorun、LSA 只读检查',
        tag_privacy: '遥测、广告 ID、定位、活动历史、应用权限总览',
        tag_perm: '逐个应用看谁拿到了摄像头、麦克风、文件系统权限',
        tag_popup: '找出弹窗源头：进程、计划任务、已装软件、通知',
        tag_speedtest: '下载、上传、延迟、抖动，多端点回退',
        tag_homepage: '检查浏览器主页与快捷方式是否被塞网址',
        tag_slim: 'pagefile、休眠、Windows.old、更新缓存大头',
        tag_rescue: '待重启、sfc/DISM、还原点、事件日志、Defender',
        tag_backup: '导出注册表键，改动前自动备份',
        tag_software: '已装程序、官网目录命中、winget 可升级清单',
        tag_softmgr: '卸载残留、软件搬家可行性、软件权限',
        tag_drivers: '第三方驱动包、问题设备、未签名驱动',
        tag_drivers2: '缺驱动的硬件、偏旧的驱动、厂商入口',
        tag_contextmenu: '右键菜单项的启用与屏蔽',
        tag_winsettings: '深色模式、扩展名、任务栏、24 小时制',
        tag_phone: 'Phone Link、已配对设备、WPD/MTP 驱动',
        tag_tweaks: '51 项常用优化，逐项预演后再动手',
        tag_shredder: '覆盖写后删除指定文件（SSD 上无效，会说明原因）',
      },
      en: {
        nav: '360 Toolbox',
        title: '360 Toolbox',
        subtitle: '{n} maintenance capabilities grouped into Cleanup & space / System & security / Network / Apps & shell. Every item reports a measured value and the rule behind it, and says plainly what cannot be done and why.',
        scopeNote: 'Only "Junk cleanup" deletes files, and only the contents of fixed whitelisted cache directories (the directories themselves are kept); the file shredder needs files you name yourself plus a second confirmation. Everything else reports read-only, or previews before it acts.',
        hostElevated: 'Elevated',
        hostNormal: 'Not elevated',
        hostNormalHint: 'Targets requiring admin rights (Windows temp, update caches, prefetch) are skipped explicitly — never silently reported as cleaned.',
        loadFailed: 'Load failed',
        scan: 'Scan',
        rescan: 'Rescan',
        scanning: 'Scanning…',
        notScanned: 'Not scanned yet. Press "Scan" to get results.',
        cachedHint: 'Cached result — rescan to refresh',
        clean: 'Clean',
        cleaning: 'Cleaning…',
        cleaningAll: 'Clean all',
        dryRunNotice: 'Dry run: this is what would be deleted; nothing has been deleted',
        freedNotice: 'Freed',
        confirmTitle: 'Confirm cleanup',
        confirmBody: 'The cache contents at these locations will be deleted (the directories themselves are kept). This cannot be undone.',
        confirmCancel: 'Cancel',
        confirmOk: 'Delete',
        planTotal: 'To be freed',
        planFiles: 'Files',
        planBlocked: 'need admin, will be skipped',
        planMeasuring: 'Measuring the selected targets…',
        planFailed: 'Could not measure — cancelled',
        needAdmin: 'Needs admin',
        nothingHere: 'Missing or empty',
        elevationHint: 'Not elevated: targets requiring admin will be skipped',
        selectAll: 'All',
        selectNone: 'None',
        selectedSummary: 'Selected',
        colTarget: 'Location',
        colSize: 'Size',
        colFiles: 'Files',
        colState: 'State',
        colPath: 'Path',
        colActions: 'Actions',
        colName: 'Name',
        colFolder: 'Folder',
        colWasted: 'Reclaimable',
        colCount: 'Copies',
        colStatus: 'Result',
        colValue: 'Measured',
        colNote: 'Note',
        rootLabel: 'Scan root',
        minMbLabel: 'Min size (MB)',
        minKbLabel: 'Min size (KB)',
        statusOk: 'OK',
        statusWarn: 'Warning',
        statusBad: 'Problem',
        statusFail: 'Failed',
        statusSkip: 'Skipped',
        statusInfo: 'Info',
        totalJunk: 'Cleanable',
        totalFiles: 'files',
        scannedFiles: 'Files scanned',
        matchedFiles: 'Matched',
        truncated: '(time limit reached — partial result)',
        groupsCount: 'duplicate groups',
        wastedTotal: 'Reclaimable',
        netOnline: 'Internet reachable',
        netOffline: 'No internet',
        netVerdict: 'Verdict',
        adapters: 'Adapters',
        dnsServers: 'DNS servers',
        proxyOn: 'System proxy: on',
        proxyOff: 'System proxy: off',
        hostsBlocked: 'hosts blocked',
        error: 'Error',
        none: 'none',
        ms: 'ms',
        expand: 'Expand',
        collapse: 'Collapse',
        riskReadonly: 'read-only',
        riskDestructive: 'destructive',
        fileCount: 'files',
        itemsUnit: 'items',
        rowsUnit: 'rows',
        noRows: 'No check rows were returned this time',
        groupOther: 'Other',
        groupCleanup: 'Cleanup & space',
        groupSystem: 'System & security',
        groupNetwork: 'Network',
        groupApps: 'Apps & shell',
        covPartial: 'Partial',
        covReadonly: 'Read-only',
        covBlocked: 'Cannot do',
        needAdminBadge: 'Needs admin',
        skippedWhy: 'Not measured: the probe skipped this one — reason above',
        apply: 'Apply fix',
        applying: 'Applying…',
        applyTitle: 'Confirm the fix',
        applyBody: 'This step is the real change. The host already ran a dry run; the entries it returned are listed below. Only on confirm does it run with dryRun=false, and anything it can back up is backed up first.',
        applyPlan: 'Dry-run entries',
        applyDone: 'Fix applied',
        ssdWarn: 'Note: every disk here is an SSD with TRIM enabled — overwriting cannot guarantee physical erasure. Full-disk encryption is the real fix.',
    dnsPickServer: 'Switch to this DNS',
    dnsPickAuto: 'Go back to automatic (DHCP)',
    dnsPickCurrent: 'Current DNS: ',
    dnsPickNeed: 'Pick a DNS server first',
        elevNot: 'Not elevated · some fixes and cleanups need administrator rights',
        elevRequest: 'Request elevation',
        elevRequesting: 'Waiting for the UAC prompt…',
        elevCancelled: 'You cancelled the UAC prompt',
        elevDone: 'The elevated process returned a result',
        elevFailed: 'Elevation failed',
    elevGranted: 'Administrator rights granted — both tabs can now act without another UAC prompt',
        formTitle: 'Parameters',
        formPreview: 'Dry run first',
        formNeed: 'Fill in the parameters first',
        homepageTarget: 'Write target',
        homepageUrl: 'Home page URL',
        homepageUrlBad: 'Must start with http(s):// or about:',
        backupKeys: 'Registry keys to export (at least 1)',
        backupKeysBad: 'One key per line, e.g. HKCU:\\Software\\... or HKLM:\\SOFTWARE\\...',
        cmClsid: 'Full CLSID',
        cmNoClsid: 'This row carries no full CLSID, so it cannot be changed safely',
        cmClsidBad: 'The CLSID must be a full GUID (8-4-4-4-12)',
        cmScope: 'Write location',
        scopeMachine: 'HKLM (all users, needs admin)',
        scopeUser: 'HKCU (current user)',
        shredPaths: 'Files to overwrite (one absolute path per line, up to 50)',
        shredBad: 'Each line must be a drive-letter absolute path with no wildcards, at most 50',
        tweakIds: 'Entries to change',
        tweakOn: 'Apply',
        tweakOff: 'Revert',
        wsSetting: 'Setting',
        wsValue: 'New value',
        wsValueNeed: 'Enter the new value first',
        wsValueInt: 'This setting is an integer; the new value must be an integer',
        softAction: 'Action',
        softAppName: 'App name (required for leftover sweep)',
        softAppNeed: 'The leftover sweep needs an app name',
        actUpgrade: 'Upgrade list',
        actLeftover: 'Leftover sweep',
        actMigrate: 'Migration check',
        actPerm: 'App permissions',
        rowNeedsForm: 'Fill in the form above before this row can run',
        nextStep: 'Next step',
        goTo: 'Go to',
        reread: 'Read again',
        nextBigfilesHit: 'These are only listed, never deleted; if a copy is duplicated, check Duplicates for space that can be reclaimed',
        nextBigfilesNone: 'Nothing above the threshold; for space, look at the reclaimable total in Slim first',
        nextDupHit: 'These groups are a report only; confirm none is a backup or installer before acting',
        nextDupNone: 'No duplicate files found: no content has multiple copies',
        nextNetFail: 'The chain breaks here: ',
        nextNetOk: 'Every hop is reachable; if some sites still fail, the cause is DNS or hosts — the measured values are listed above',
        nextHealthBad: 'Some checks failed; fix disks and services first, then rescan',
        nextHealthOk: 'Nothing on this machine needs immediate attention',
        nextSecurityBad: 'These are policy-level risks: changing registry or policy entries needs admin, so without elevation you can only read them',
        nextSecurityOk: 'Every policy entry is at its expected value; nothing to change',
        nextPrivacyMeta: 'Privacy items can only be turned off one by one in Settings; this is the measured state',
        nextPermBroad: 'These apps hold wide device or filesystem access; narrow them in Settings → Privacy',
        nextPermOk: 'No app holds overly broad camera or microphone access',
        nextPopupHit: 'These are the popup sources; disable the scheduled task first, then uninstall software as needed',
        nextPopupNone: 'No obvious popup sources — no processes or scheduled tasks found',
        nextSpeedtestSlow: 'Latency is high; rule out local load and wireless signal before blaming the ISP bandwidth',
        nextSpeedtestOk: 'The measured bandwidth and latency are shown above; compare against your plan using the wired lower bound',
        nextSlimSafe: 'The safe reclaimable total is shown above — no need to judge each item, switch to Junk cleanup and let the whitelist handle it',
        nextSlimNone: 'No large safe reclaimable chunk; pagefile and hibernation changes only take effect after a restart',
        nextRescuePending: 'A restart is pending; restart first, then continue with repairs',
        nextRescueOk: 'No pending restart and no recent critical events',
        nextSoftwareHit: 'Installed software matched against official catalogues is listed above; upgrades live in the Software manager action list',
        nextSoftwareNone: 'No installed software matched an official catalogue',
        nextDriversBad: 'Devices are missing drivers or reporting problems: get official drivers from the vendor, not third-party driver packs',
        nextDriversOk: 'No device is missing a driver or unsigned',
        nextDrivers2Missing: 'These devices lack drivers; confirm the hardware model, then download the official driver',
        nextDrivers2Ok: 'No hardware is missing a driver',
        nextPhoneOff: 'No phone is paired; connect it over USB and rescan here',
        nextPhoneOk: 'A phone is connected; if Explorer cannot see it, check the WPD/MTP driver row',
        nextJunkNone: 'No cache content is available to clean',
        nextProcBusy: 'The top CPU/memory processes are listed above; confirm whether you are using them before ending one',
        nextProcIdle: 'No process is eating noticeable CPU or memory right now — nothing to do',
        nextDiskBad: 'A disk is already reporting failure warnings: back up its data first, then consider replacing it',
        nextDiskOk: 'No disk is reporting warnings; detailed SMART readings need admin — press "Request elevation" and rescan',
        nextDiskSkip: 'Detailed SMART readings need admin rights; only the Win32 fallback data is available, so this verdict is weak',
        cap_junk: 'Junk cleanup',
        cap_bigfiles: 'Large files',
        cap_dupfiles: 'Duplicates',
        cap_netdiag: 'Network',
        cap_health: 'Health check',
        cap_proc: 'Task manager',
        cap_diskhealth: 'Disk health',
        cap_security: 'System security',
        cap_privacy: 'Privacy guard',
        cap_perm: 'App permissions',
        cap_popup: 'Popup sources',
        cap_speedtest: 'Speed test',
        cap_homepage: 'Homepage guard',
        cap_slim: 'Slim system drive',
        cap_rescue: 'System rescue',
        cap_backup: 'Backup / restore',
        cap_software: 'Software manager',
        cap_softmgr: 'Software deep clean',
        cap_drivers: 'Driver inventory',
        cap_drivers2: 'Driver update check',
        cap_contextmenu: 'Context menu',
        cap_winsettings: 'Windows settings',
        cap_phone: 'Phone link',
        cap_tweaks: 'Tweak presets',
        cap_shredder: 'File shredder',
        tag_junk: 'Scans whitelisted caches; cleanable',
        tag_bigfiles: 'Largest files by size; report only',
        tag_dupfiles: 'Three-stage hash for real duplicates; report only',
        tag_netdiag: 'Adapter → gateway → DNS → internet, shows the break',
        tag_health: 'Disk, memory, services, devices, protection in one pass',
        tag_proc: 'Who is eating CPU, memory and disk',
        tag_diskhealth: 'Catch the warning signs before a disk dies',
        tag_security: 'UAC, Defender, SMB, RDP, Autorun, LSA — read-only',
        tag_privacy: 'Telemetry, ad ID, location, activity history, app permissions',
        tag_perm: 'Which app holds camera, microphone, filesystem access',
        tag_popup: 'Who pops up: processes, tasks, installed software, notifications',
        tag_speedtest: 'Download, upload, latency, jitter, multi-endpoint fallback',
        tag_homepage: 'Checks browser homepages and shortcut URL injection',
        tag_slim: 'pagefile, hibernation, Windows.old, update caches, AppData',
        tag_rescue: 'Pending reboot, sfc/DISM, restore points, event log, Defender',
        tag_backup: 'Exports registry keys and backs up before any change',
        tag_software: 'Installed programs, official-site hits, winget upgrades',
        tag_softmgr: 'Uninstall leftovers, move feasibility, software permissions',
        tag_drivers: 'Third-party driver packs, problem devices, unsigned drivers',
        tag_drivers2: 'Hardware missing drivers, outdated drivers, vendor links',
        tag_contextmenu: 'Enable or block Explorer context-menu entries',
        tag_winsettings: 'Dark mode, extensions, taskbar, 24-hour clock',
        tag_phone: 'Phone Link, paired devices, WPD/MTP driver state',
        tag_tweaks: '51 common tweaks, previewed item by item',
        tag_shredder: 'Overwrite then delete chosen files (useless on SSD, says why)',
      },
    };

    function api(path) {
      try {
        const u = new URL(relative(path), document.baseURI);
        return u.pathname + u.search;
      } catch { return '/' + path; }
    }
    function relative(p) { return p.startsWith('/') ? p.slice(1) : p; }

    const getJSON = async (path) => {
      const res = await fetch(api(path), { credentials: 'same-origin' });
      if (!res.ok) throw new Error(`${res.status} ${path}`);
      return res.json();
    };
    const postJSON = async (path, body) => {
      const res = await fetch(api(path), {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body ?? {}),
      });
      if (!res.ok) throw new Error(`${res.status} ${path}`);
      return res.json();
    };

    // ---- theme tokens only ----
    const C = {
      bgBase: 'var(--dsw-alias-bg-base,#ffffff)',
      bgLayer1: 'var(--dsw-alias-bg-layer-1,#f7f8fa)',
      bgLayer2: 'var(--dsw-alias-bg-layer-2,#eef0f4)',
      border: 'var(--dsw-alias-border-l2,#d9dee6)',
      label: 'var(--dsw-alias-label-primary,#1f2328)',
      label2: 'var(--dsw-alias-label-secondary,#5c6570)',
      label3: 'var(--dsw-alias-label-tertiary,#8b93a1)',
      hover: 'var(--dsw-alias-interactive-bg-hover,#2631480f)',
      brand: 'var(--dsw-alias-brand-primary,#4f6ef7)',
      warn: 'var(--dsw-alias-state-warn-primary,#d98f0b)',
      success: 'var(--dsw-alias-state-success-primary,#1a9c5b)',
      error: 'var(--dsw-alias-state-error-primary,#d64545)',
      radius: 'var(--dsw-radius-sm,8px)',
      radiusMd: 'var(--dsw-radius-md,12px)',
    };

    const focusRing = { outline: '2px solid transparent', outlineOffset: '1px' };
    const onFocus = (e) => { try { e.target.style.outlineColor = C.brand; } catch { /* noop */ } };
    const onBlur = (e) => { try { e.target.style.outlineColor = 'transparent'; } catch { /* noop */ } };
    const focusable = { onFocus, onBlur };

    /**
     * The active language layer. `t` cannot be introspected, so the one string
     * that is guaranteed to differ (nav) tells us which half of DICT is live.
     */
    function langOf(t) {
      try { return t('nav') === DICT.en.nav ? 'en' : 'zh'; } catch { return 'zh'; }
    }
    function dictHas(t, key) {
      const layer = DICT[langOf(t)];
      return !!layer && Object.prototype.hasOwnProperty.call(layer, key);
    }
    /** t(key) only when both language layers really define it; else a fallback. */
    function tr(t, key, fallback) {
      return dictHas(t, key) ? t(key) : fallback;
    }
    /** Catalogue labels arrive per language; cap_/tag_ dictionaries win. */
    function capName(t, cap) {
      if (!cap) return '';
      const en = langOf(t) === 'en';
      const own = en ? (cap.labelEn || cap.label) : (cap.label || cap.labelEn);
      return tr(t, 'cap_' + cap.id, own ?? String(cap.id ?? ''));
    }
    function capTag(t, cap) {
      if (!cap) return '';
      const en = langOf(t) === 'en';
      const own = en ? (cap.taglineEn || cap.tagline) : (cap.tagline || cap.taglineEn);
      return tr(t, 'tag_' + cap.id, '') || own || '';
    }
    function groupLabel(t, g) {
      if (!g) return '';
      const en = langOf(t) === 'en';
      const own = en ? (g.labelEn || g.label) : (g.label || g.labelEn);
      if (own) return own;
      const id = String(g.id ?? '');
      return tr(t, 'group' + id.replace(/^./, (c) => c.toUpperCase()), id);
    }

    /**
     * View dispatch. The host sends `view` per capability; a stale /status (or an
     * older host) may omit it, so four ids map to their obvious table. Everything
     * else is the generic checks list — no capability id list is maintained here.
     */
    const VIEW_FOR_KNOWN_ID = { junk: 'junk', bigfiles: 'files', dupfiles: 'groups', netdiag: 'steps' };
    function viewOf(cap) {
      if (!cap) return 'checks';
      if (typeof cap.view === 'string' && cap.view) return cap.view;
      return VIEW_FOR_KNOWN_ID[cap.id] ?? 'checks';
    }

    const STATUS_KEY = {
      ok: 'statusOk', warn: 'statusWarn', bad: 'statusBad',
      fail: 'statusFail', skip: 'statusSkip', info: 'statusInfo',
    };
    function statusText(t, status) {
      const key = STATUS_KEY[status];
      return (key && dictHas(t, key)) ? t(key) : String(status ?? '');
    }

    /** coverage → badge, or null for the common `full` case. */
    function covBadge(t, cap) {
      const cov = cap?.coverage ?? 'full';
      if (cov === 'partial') return { text: t('covPartial'), color: C.warn, title: cap.detail };
      if (cov === 'readonly') return { text: t('covReadonly'), color: C.label3, title: cap.detail };
      if (cov === 'blocked') return { text: t('covBlocked'), color: C.error, title: cap.detail };
      return null;
    }

    function human(bytes) {
      const n = Number(bytes);
      if (!Number.isFinite(n) || n <= 0) return '0 B';
      const units = ['B', 'KB', 'MB', 'GB', 'TB'];
      let v = n;
      let i = 0;
      while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
      return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
    }
    function truncateMid(s, n = 64) {
      const v = String(s ?? '');
      if (v.length <= n) return v;
      const head = Math.ceil((n - 1) * 0.55);
      const tail = Math.max(0, n - 1 - head);
      return v.slice(0, head) + '…' + (tail ? v.slice(-tail) : '');
    }
    function statusColor(status) {
      if (status === 'ok') return C.success;
      if (status === 'warn') return C.warn;
      if (status === 'bad' || status === 'fail') return C.error;
      return C.label3;
    }

    const ellipsis = { minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' };

    // ------------------------------------------------------------- components

    function Badge({ text, color, title }) {
      return h('span', {
        title,
        style: {
          display: 'inline-block', fontSize: '10px', lineHeight: '16px',
          padding: '0 6px', borderRadius: '9px', color,
          background: 'transparent', border: `1px solid ${color}`,
          whiteSpace: 'nowrap',
        },
      }, text);
    }

    function Btn({ children, onClick, disabled, tone, title, compact }) {
      const color = tone === 'danger' ? C.error : tone === 'brand' ? C.brand : C.label2;
      return h('button', {
        type: 'button', onClick, disabled, title,
        ...focusable,
        style: {
          appearance: 'none', font: 'inherit', cursor: disabled ? 'default' : 'pointer',
          fontSize: compact ? '11px' : '12px',
          padding: compact ? '2px 8px' : '5px 12px',
          borderRadius: C.radius,
          border: `1px solid ${disabled ? C.border : color}`,
          background: 'transparent',
          color: disabled ? C.label3 : color,
          opacity: disabled ? 0.55 : 1,
          whiteSpace: 'nowrap',
        },
      }, children);
    }

    function Stat({ label, value, tone }) {
      return h('div', { style: { display: 'flex', flexDirection: 'column', gap: '1px', minWidth: 0 } },
        h('div', { style: { fontSize: '10px', color: C.label3, whiteSpace: 'nowrap' } }, label),
        h('div', {
          style: { fontSize: '13px', color: tone ?? C.label, fontWeight: 600, whiteSpace: 'nowrap' },
        }, value),
      );
    }

    /** Group tabs. Labels come from /status groups[]; i18n is only a fallback. */
    function GroupTabs({ t, groups, selected, onSelect }) {
      return h('div', {
        style: { display: 'flex', gap: '5px', flexWrap: 'wrap', alignItems: 'center' },
      }, groups.map((g) => {
        const isSel = g.id === selected;
        return h('button', {
          key: g.id, type: 'button', onClick: () => onSelect(g.id), ...focusable,
          style: {
            appearance: 'none', font: 'inherit', cursor: 'pointer',
            fontSize: '11px', padding: '3px 10px', borderRadius: C.radius,
            border: `1px solid ${isSel ? C.brand : C.border}`,
            background: isSel ? C.bgLayer1 : 'transparent',
            color: isSel ? C.brand : C.label2,
            whiteSpace: 'nowrap',
          },
        }, groupLabel(t, g));
      }));
    }

    /**
     * The capability cards of the selected group. Selecting one does not scan;
     * it shows whatever the host has cached.
     */
    function CapStrip({ t, catalogue, statusOf, active, onSelect, onScan, busy }) {
      return h('div', {
        style: { display: 'flex', gap: '6px', flexWrap: 'wrap' },
      }, catalogue.map((cap) => {
        const st = statusOf.get(cap.id);
        const isActive = cap.id === active;
        const cov = covBadge(t, cap);
        const itemCount = Number(st?.itemCount ?? 0);
        const scanning = busy === cap.id || st?.running === true;
        // The card is a container, not one big button: it holds the select
        // target AND its own Scan control, so a freshly selected capability is
        // usable without expanding anything below.
        return h('div', {
          key: cap.id,
          style: {
            flex: '0 1 auto', minWidth: '132px',
            padding: '7px 9px', borderRadius: C.radiusMd,
            border: `1px solid ${isActive ? C.brand : (cap.coverage === 'blocked' ? C.error : C.border)}`,
            background: isActive ? C.bgLayer1 : 'transparent',
            color: C.label,
            display: 'flex', flexDirection: 'column', gap: '4px',
          },
        },
          h('button', {
            type: 'button', onClick: () => onSelect(cap.id),
            title: cap.detail || capTag(t, cap), ...focusable,
            style: {
              appearance: 'none', font: 'inherit', cursor: 'pointer', textAlign: 'left',
              padding: 0, margin: 0, border: 'none', background: 'transparent', color: C.label,
              display: 'flex', flexDirection: 'column', gap: '3px', minWidth: 0,
            },
          },
            h('span', { style: { display: 'flex', alignItems: 'center', gap: '6px', minWidth: 0 } },
              h('span', { style: { fontSize: '12px', fontWeight: 600, whiteSpace: 'nowrap' } }, capName(t, cap)),
              cap.risk === 'destructive' ? h(Badge, { text: t('riskDestructive'), color: C.warn }) : null,
              cov ? h(Badge, cov) : null,
            ),
            h('span', { style: { fontSize: '10px', color: C.label3, lineHeight: '1.35' } },
              st?.cached && itemCount > 0 ? `${itemCount} ${t('itemsUnit')}` : capTag(t, cap)),
          ),
          h(Btn, {
            compact: true,
            disabled: scanning,
            onClick: () => onScan(cap.id),
            title: cap.detail || capTag(t, cap),
          }, scanning ? t('scanning') : (st?.cached ? t('rescan') : t('scan'))),
        );
      }));
    }

    // ---- junk table ----------------------------------------------------------

    function JunkTable({ t, items, selected, onToggle, allTargets }) {
      const GRID = '22px minmax(0,1.3fr) 84px 62px 92px minmax(0,1.1fr)';
      return h('div', {
        style: {
          display: 'flex', flexDirection: 'column', minHeight: 0,
          border: `1px solid ${C.border}`, borderRadius: C.radiusMd, overflow: 'hidden', background: C.bgBase,
        },
      },
        h('div', {
          style: {
            display: 'grid', gridTemplateColumns: GRID, gap: '8px', padding: '6px 8px',
            fontSize: '10px', color: C.label3, background: C.bgLayer2,
            borderBottom: `1px solid ${C.border}`, textTransform: 'uppercase', letterSpacing: '0.04em',
          },
        },
          h('div'),
          h('div', null, t('colTarget')),
          h('div', null, t('colSize')),
          h('div', null, t('colFiles')),
          h('div', null, t('colState')),
          h('div', null, t('colPath')),
        ),
        h('div', { style: { flex: 1, overflowY: 'auto', minHeight: 0, padding: '2px' } },
          items.length === 0
            ? h('div', { style: { padding: '16px', fontSize: '12px', color: C.label3 } }, t('notScanned'))
            : items.map((it) => {
              const isSel = selected.has(it.id);
              const selectable = it.exists && !it.blocked;
              return h('label', {
                key: it.id,
                style: {
                  display: 'grid', gridTemplateColumns: GRID, gap: '8px', alignItems: 'center',
                  padding: '5px 8px', borderRadius: C.radius, fontSize: '12px',
                  cursor: selectable ? 'pointer' : 'default',
                  background: isSel ? C.hover : 'transparent', color: C.label,
                },
              },
                h('input', {
                  type: 'checkbox', checked: isSel, disabled: !selectable,
                  onChange: () => onToggle(it.id),
                  style: { margin: 0, cursor: selectable ? 'pointer' : 'default' },
                }),
                h('div', { style: { minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } },
                  it.label,
                  it.note ? h('span', { style: { color: C.label3, fontSize: '10px' } }, ` · ${it.note}`) : null,
                ),
                h('div', { style: { color: it.bytes > 0 ? C.label : C.label3, whiteSpace: 'nowrap' } }, human(it.bytes)),
                h('div', { style: { color: C.label3, whiteSpace: 'nowrap' } }, String(it.files)),
                h('div', null,
                  it.blocked
                    ? h(Badge, { text: t('needAdmin'), color: C.warn })
                    : !it.exists
                      ? h(Badge, { text: t('nothingHere'), color: C.label3 })
                      : h(Badge, { text: t('statusOk'), color: C.success }),
                ),
                h('div', {
                  title: it.path,
                  style: { color: C.label3, fontSize: '11px', minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' },
                }, truncateMid(it.path, 56)),
              );
            }),
        ),
      );
    }

    // ---- big files -----------------------------------------------------------

    function BigFilesTable({ t, items }) {
      const GRID = 'minmax(0,1.5fr) 92px minmax(0,1.4fr)';
      return h('div', {
        style: { display: 'flex', flexDirection: 'column', minHeight: 0, border: `1px solid ${C.border}`, borderRadius: C.radiusMd, overflow: 'hidden', background: C.bgBase },
      },
        h('div', {
          style: {
            display: 'grid', gridTemplateColumns: GRID, gap: '8px', padding: '6px 8px',
            fontSize: '10px', color: C.label3, background: C.bgLayer2,
            borderBottom: `1px solid ${C.border}`, textTransform: 'uppercase', letterSpacing: '0.04em',
          },
        },
          h('div', null, t('colName')),
          h('div', null, t('colSize')),
          h('div', null, t('colFolder')),
        ),
        h('div', { style: { flex: 1, overflowY: 'auto', minHeight: 0, padding: '2px' } },
          items.map((it) => h('div', {
            key: it.path, title: it.path,
            style: {
              display: 'grid', gridTemplateColumns: GRID, gap: '8px', alignItems: 'center',
              padding: '4px 8px', borderRadius: C.radius, fontSize: '12px', color: C.label,
            },
          },
            h('div', { style: ellipsis }, it.name),
            h('div', { style: { color: it.bytes > 200 * 1024 * 1024 ? C.warn : C.label, whiteSpace: 'nowrap' } }, human(it.bytes)),
            h('div', { style: { color: C.label3, fontSize: '11px', ...ellipsis } }, truncateMid(it.folder, 64)),
          )),
        ),
      );
    }

    // ---- duplicate groups ----------------------------------------------------

    function DupTable({ t, items }) {
      const [open, setOpen] = useState(() => new Set());
      const toggle = (hash) => {
        const next = new Set(open);
        if (next.has(hash)) next.delete(hash); else next.add(hash);
        setOpen(next);
      };
      return h('div', {
        style: { display: 'flex', flexDirection: 'column', minHeight: 0, border: `1px solid ${C.border}`, borderRadius: C.radiusMd, overflow: 'hidden', background: C.bgBase },
      },
        h('div', { style: { flex: 1, overflowY: 'auto', minHeight: 0, padding: '2px' } },
          items.map((g) => h('div', { key: g.hash, style: { borderBottom: `1px solid ${C.border}` } },
            h('button', {
              type: 'button', onClick: () => toggle(g.hash), ...focusable,
              style: {
                appearance: 'none', font: 'inherit', cursor: 'pointer', width: '100%', textAlign: 'left',
                display: 'grid', gridTemplateColumns: '20px minmax(0,1fr) 96px 74px', gap: '8px',
                alignItems: 'center', padding: '5px 8px', background: 'transparent',
                border: 'none', color: C.label, fontSize: '12px',
              },
            },
              h('span', { style: { color: C.label3 } }, open.has(g.hash) ? '▾' : '▸'),
              h('span', { style: ellipsis }, g.files?.[0]?.name ?? g.hash.slice(0, 12)),
              h('span', { style: { whiteSpace: 'nowrap' } }, `${g.count} × ${human(g.bytes)}`),
              h('span', { style: { color: C.warn, whiteSpace: 'nowrap', textAlign: 'right' } }, human(g.wasted)),
            ),
            open.has(g.hash)
              ? h('div', { style: { padding: '2px 8px 8px 28px', display: 'flex', flexDirection: 'column', gap: '2px' } },
                  (g.files ?? []).map((f) => h('div', {
                    key: f.path, title: f.path,
                    style: { fontSize: '11px', color: C.label2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' },
                  }, `${human(f.bytes)}  ${truncateMid(f.path, 96)}`)))
              : null,
          )),
        ),
      );
    }

    // ---- netdiag steps -------------------------------------------------------

    function NetSteps({ t, items, meta }) {
      return h('div', { style: { display: 'flex', flexDirection: 'column', gap: '10px', minHeight: 0 } },
        h('div', {
          style: {
            padding: '9px 11px', borderRadius: C.radiusMd, fontSize: '12px',
            border: `1px solid ${meta.online ? C.success : C.warn}`,
            background: C.bgLayer1, color: C.label,
          },
        }, h('strong', { style: { color: meta.online ? C.success : C.warn } }, `${t('netVerdict')}: `), meta.verdict || t('none')),
        h('div', {
          style: { display: 'flex', flexDirection: 'column', border: `1px solid ${C.border}`, borderRadius: C.radiusMd, overflow: 'hidden', background: C.bgBase },
        },
          items.map((s) => h('div', {
            key: s.id,
            style: {
              display: 'grid', gridTemplateColumns: '92px 72px minmax(0,1fr) 58px', gap: '8px',
              alignItems: 'center', padding: '5px 9px', fontSize: '12px',
              borderTop: `1px solid ${C.border}`, color: C.label,
            },
          },
            h('div', { style: { whiteSpace: 'nowrap' } }, s.label),
            h('div', null, h(Badge, { text: s.status, color: statusColor(s.status) })),
            h('div', { style: { color: C.label2, ...ellipsis }, title: s.detail }, s.detail),
            h('div', { style: { color: C.label3, textAlign: 'right', whiteSpace: 'nowrap' } }, s.ms ? `${s.ms} ${t('ms')}` : ''),
          )),
        ),
        h('div', { style: { display: 'flex', gap: '14px', flexWrap: 'wrap', fontSize: '11px', color: C.label3 } },
          h('span', null, `${t('dnsServers')}: ${(meta.dnsServers ?? []).join(', ') || t('none')}`),
          h('span', null, meta.proxy?.enabled ? t('proxyOn') : t('proxyOff')),
          meta.hostsBlocked > 0 ? h('span', { style: { color: C.warn } }, `${t('hostsBlocked')}: ${meta.hostsBlocked}`) : null,
        ),
      );
    }

    // ---- generic check list (19 checks-view capabilities) --------------------

    /**
     * A row may only offer "apply" when the host puts concrete write parameters
     * on the row itself. The probes deliberately do not expose them: contextmenu
     * keeps a 9-char CLSID slug, homepage needs a URL the scan never sees, backup
     * needs the key list and shredder needs explicit paths. Rendering no button
     * is the correct behaviour when the parameters cannot be derived reliably —
     * a guessed parameter would silently corrupt something.
     */
    function deriveApplyParams(cap, item) {
      if (!cap || !Array.isArray(cap.actions) || !cap.actions.includes('apply')) return null;
      if (!item || item.status === 'skip') return null;
      // contextmenu can still be driven per row when (and only when) the probe
      // left a complete GUID somewhere in the row text.
      if (cap.id === 'contextmenu') {
        const clsid = fullClsidOf(item);
        if (!clsid) return null;
        const blocked = item.status === 'warn' || /已阻止|blocked/i.test(String(item.value ?? ''));
        return { action: blocked ? 'enable' : 'disable', clsid, scope: 'machine' };
      }
      const p = item.params;
      if (!p || typeof p !== 'object' || Array.isArray(p) || Object.keys(p).length === 0) return null;
      return p;
    }

    /**
     * contextmenu rows carry only a 9-character CLSID slug in their id
     * (`menu:allfiles-context-{9179176E`). A row-level write needs the whole GUID,
     * so the only safe thing is to look for a complete GUID anywhere the probe
     * put text, and refuse the row when there is none. Padding the slug with
     * zeros would address a different key and is never acceptable.
     */
    const FULL_GUID_RE = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/;

    function fullClsidOf(item) {
      if (!item) return null;
      const hay = [item.id, item.label, item.value, item.detail, item.fix, item.group]
        .filter((x) => typeof x === 'string' && x)
        .join(' ');
      const m = hay.match(FULL_GUID_RE);
      return m ? `{${m[0].toUpperCase()}}` : null;
    }

    /** Per-row reason a row-level apply is refused, or null when it is allowed. */
    function rowGateFor(t, cap, item) {
      if (cap && cap.id === 'contextmenu' && !fullClsidOf(item)) return t('cmNoClsid');
      return null;
    }

    /**
     * Bucket rows by the probe's own group name (Chinese, e.g. 磁盘 / 内存),
     * keeping first-appearance order, with the untitled bucket last. Groups are
     * <details> so 33-row capabilities (perm) do not have to render fully open.
     *
     * The open state is tracked here instead of being forced from props: an
     * `open={i === 0}` prop would be re-applied on every re-render and snap the
     * panel shut each time a scan finishes. `openKeys === null` means "nobody has
     * toggled yet", which renders as "first group open".
     */
    function ChecksList({ t, items, cap, onApplyRow, rowGateText }) {
      const [openKeys, setOpenKeys] = useState(null);
      const rows = Array.isArray(items) ? items : [];
      const buckets = [];
      const at = new Map();
      for (const it of rows) {
        const key = String(it.group ?? '');
        if (!at.has(key)) { at.set(key, buckets.length); buckets.push({ key, rows: [] }); }
        buckets[at.get(key)].rows.push(it);
      }
      buckets.sort((a, b) => (a.key === '' ? 1 : 0) - (b.key === '' ? 1 : 0));

      const isOpen = (key, i) => (openKeys === null ? i === 0 : openKeys.has(key));
      const onToggle = (key, e) => {
        const nowOpen = e?.currentTarget?.open;
        if (typeof nowOpen !== 'boolean') return;
        const next = openKeys === null
          ? new Set(buckets.length ? [buckets[0].key] : [])
          : new Set(openKeys);
        if (nowOpen) next.add(key); else next.delete(key);
        setOpenKeys(next);
      };

      if (rows.length === 0) {
        return h('div', { style: { padding: '16px', fontSize: '12px', color: C.label3 } }, t('noRows'));
      }
      const canApply = Array.isArray(cap?.actions) && cap.actions.includes('apply');

      const rowBody = (it) => {
        const fix = it.fix ?? it.fixHint ?? '';
        const detail = String(it.detail ?? '');
        const line = [detail, fix ? `→ ${fix}` : ''].filter(Boolean).join('  ');
        const isSkip = it.status === 'skip';
        // "not measured" must never be mistaken for "measured and fine".
        const shown = line || (isSkip ? t('skippedWhy') : '');
        const params = canApply ? deriveApplyParams(cap, it) : null;
        return h('div', {
          key: it.id ?? `${it.group ?? ''}:${it.label ?? ''}`,
          style: {
            display: 'flex', flexDirection: 'column', gap: '1px',
            padding: '4px 8px', fontSize: '12px', color: C.label,
            borderTop: `1px solid ${C.border}`,
            opacity: isSkip ? 0.7 : 1,
          },
        },
          h('div', { style: { display: 'grid', gridTemplateColumns: '150px 84px minmax(0,1fr) auto', gap: '8px', alignItems: 'center' } },
            h('div', { style: { width: '150px', ...ellipsis }, title: it.label }, it.label ?? ''),
            h('div', { style: { display: 'flex', gap: '4px', alignItems: 'center' } },
              h(Badge, { text: statusText(t, it.status), color: statusColor(it.status), title: it.status }),
              it.needsAdmin === true
                ? h(Badge, { text: t('needAdminBadge'), color: C.warn })
                : null,
            ),
            h('div', { style: { color: C.label2, ...ellipsis }, title: it.value }, it.value || '—'),
            params
              ? h(Btn, {
                  compact: true, disabled: !onApplyRow,
                  onClick: onApplyRow ? () => onApplyRow(it, params) : undefined,
                }, t('apply'))
              : (canApply
                ? h(Btn, {
                    compact: true,
                    disabled: true,
                    // The row's own reason wins over the panel-wide one: "no full
                    // CLSID" is a fact about this row, not about the form.
                    title: rowGateFor(t, cap, it) || rowGateText || undefined,
                  }, t('apply'))
                : null),
          ),
          shown
            ? h('div', {
                title: shown,
                style: { fontSize: '10px', color: isSkip ? C.warn : C.label3, lineHeight: '1.45', ...ellipsis },
              }, shown)
            : null,
        );
      };

      return h('div', {
        style: { display: 'flex', flexDirection: 'column', minHeight: 0, border: `1px solid ${C.border}`, borderRadius: C.radiusMd, overflow: 'hidden', background: C.bgBase },
      },
        h('div', { style: { fontSize: '10px', color: C.label3, padding: '5px 8px', background: C.bgLayer2, borderBottom: `1px solid ${C.border}` } },
          `${rows.length} ${t('rowsUnit')} · ${buckets.length}`),
        h('div', { style: { flex: 1, overflowY: 'auto', minHeight: 0 } },
          buckets.map((b, i) => h('details', {
            key: b.key || 'group-other',
            open: isOpen(b.key, i),
            onToggle: (e) => onToggle(b.key, e),
            style: { borderTop: i === 0 ? 'none' : `1px solid ${C.border}` },
          },
            h('summary', {
              style: {
                cursor: 'pointer', fontSize: '11px', color: C.label2, padding: '4px 8px',
                background: C.bgLayer1, whiteSpace: 'nowrap',
              },
            }, `${b.key || t('groupOther')} · ${b.rows.length} ${t('rowsUnit')}`),
            h('div', { style: { display: 'flex', flexDirection: 'column' } }, b.rows.map(rowBody)),
          )),
        ),
      );
    }

    /**
     * Shredder's honest caveat: only shown when the host actually returned disk
     * media entries and TRIM is enabled, i.e. when overwriting is provably
     * pointless here. No data → no line (never invented).
     */
    function ssdTrimNote(meta) {
      const m = meta ?? {};
      const media = Array.isArray(m.media) ? m.media : [];
      if (media.length === 0) return null;
      const ntfs = Number(m.trim?.ntfs);
      if (!Number.isFinite(ntfs) || ntfs !== 0) return null;
      const allSsd = media.every((x) => String(x?.mediaType ?? '').toUpperCase() === 'SSD');
      return allSsd ? { count: media.length, ntfs } : null;
    }

    // ---- apply forms ---------------------------------------------------------

    /**
     * Every scan+apply capability needs parameters the scan never returns:
     * homepage needs a URL, backup needs key paths, shredder needs explicit
     * files, winsettings needs the new value, softmgr needs a verb. The probes
     * are deliberately strict about all of them (homepage only accepts
     * ie-start / ie-search, winsettings matches the setting id exactly), so the
     * panel collects them explicitly instead of guessing: an invalid form
     * disables the button and says why, it never sends a half-parameterised
     * write.
     */
    const FORM_KINDS = {
      homepage: 'homepage',
      backup: 'backup',
      contextmenu: 'contextmenu',
      shredder: 'shredder',
      tweaks: 'tweaks',
      winsettings: 'winsettings',
      softmgr: 'softmgr',
      // Netdiag carries two writable verbs behind one capability. The form only
      // appears for the DNS switch — the 7-step repair keeps its own table UI,
      // because its targets are already rows with their own buttons.
      netdiag: 'netdns',
    };

    const formKindOf = (cap) => (cap && FORM_KINDS[cap.id]) || null;

    const defaultFormOf = (capId) => {
      if (capId === 'homepage') return { target: 'ie-start', value: '' };
      if (capId === 'backup') return { keys: '' };
      if (capId === 'contextmenu') return { clsid: '', scope: 'machine', action: 'disable' };
      if (capId === 'shredder') return { paths: '' };
      if (capId === 'tweaks') return { ids: [], action: 'apply' };
      if (capId === 'winsettings') return { setting: '', value: '' };
      if (capId === 'softmgr') return { action: 'upgrade', appName: '' };
      if (capId === 'netdiag') return { server: '' };
      return {};
    };

    const GUID_RE = /^\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?$/;
    const REG_KEY_RE = /^HK(LM|CU|CR|U):\\/i;
    const URL_RE = /^(https?:\/\/|about:)/i;
    const DRIVE_PATH_RE = /^[A-Za-z]:\\/;

    const splitLines = (raw) => String(raw ?? '')
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean);

    /**
     * Turn one form's raw values into probe parameters.
     * Returns {ok, params, reason}: reason is a translated string shown as the
     * disabled button's tooltip, so the user knows what to fix.
     */
    function validateForm(t, cap, form, items) {
      const kind = formKindOf(cap);
      const f = form ?? {};
      const bad = (reason) => ({ ok: false, params: null, reason });

      if (kind === 'homepage') {
        const target = f.target === 'ie-search' ? 'ie-search' : 'ie-start';
        const value = String(f.value ?? '').trim();
        if (!value) return bad(t('formNeed'));
        if (!URL_RE.test(value)) return bad(t('homepageUrlBad'));
        if (value.length > 2048) return bad(t('homepageUrlBad'));
        return { ok: true, params: { action: 'fix', target, value }, reason: '' };
      }

      if (kind === 'backup') {
        const keys = splitLines(f.keys);
        if (keys.length === 0) return bad(t('backupKeysBad'));
        if (keys.some((k) => !REG_KEY_RE.test(k))) return bad(t('backupKeysBad'));
        return { ok: true, params: { action: 'export', keys }, reason: '' };
      }

      if (kind === 'contextmenu') {
        const clsid = String(f.clsid ?? '').trim();
        if (!clsid) return bad(t('cmClsidBad'));
        if (!GUID_RE.test(clsid)) return bad(t('cmClsidBad'));
        const scope = f.scope === 'user' ? 'user' : 'machine';
        const action = f.action === 'enable' ? 'enable' : 'disable';
        return { ok: true, params: { action, clsid, scope }, reason: '' };
      }

      if (kind === 'shredder') {
        const paths = splitLines(f.paths);
        if (paths.length === 0) return bad(t('shredBad'));
        if (paths.length > 50) return bad(t('shredBad'));
        if (paths.some((p) => !DRIVE_PATH_RE.test(p) || /[*?]/.test(p))) return bad(t('shredBad'));
        return { ok: true, params: { paths }, reason: '' };
      }

      if (kind === 'tweaks') {
        const ids = Array.isArray(f.ids) ? f.ids.filter(Boolean) : [];
        if (ids.length === 0) return bad(t('formNeed'));
        const action = f.action === 'revert' ? 'revert' : 'apply';
        return { ok: true, params: { action, ids }, reason: '' };
      }

      if (kind === 'winsettings') {
        const setting = String(f.setting ?? '').trim();
        const value = String(f.value ?? '').trim();
        if (!setting || !value) return bad(t('wsValueNeed'));
        const row = (items ?? []).find((it) => it.id === setting);
        const isInt = /DWord|QWord|整数/i.test(String(row?.detail ?? ''));
        if (isInt && !/^-?\d+$/.test(value)) return bad(t('wsValueInt'));
        return { ok: true, params: { action: 'set', setting, value }, reason: '' };
      }

      if (kind === 'softmgr') {
        const action = ['upgrade', 'leftover', 'migrate', 'perm'].includes(f.action) ? f.action : 'upgrade';
        const appName = String(f.appName ?? '').trim();
        if (action === 'leftover' && !appName) return bad(t('softAppNeed'));
        const params = { action };
        if (appName) params.appName = appName;
        return { ok: true, params, reason: '' };
      }

      if (kind === 'netdns') {
        // Only the five published resolvers, or 'auto' to hand control back to
        // DHCP. Free-text is deliberately not an option: a typo here takes the
        // machine off the network, and the probe only accepts the same six
        // values, so anything else would be sent and silently ignored.
        const server = String(f.server ?? '').trim();
        const allowed = ['223.5.5.5', '119.29.29.29', '1.1.1.1', '8.8.8.8', '114.114.114.114', 'auto'];
        if (!allowed.includes(server)) return bad(t('dnsPickNeed'));
        return { ok: true, params: { action: 'dnspick', server }, reason: '' };
      }

      return { ok: false, params: null, reason: '' };
    }

    const FORM_ROW = { display: 'flex', gap: '6px', alignItems: 'center', flexWrap: 'wrap', fontSize: '11px' };
    const FORM_INPUT = {
      font: 'inherit', fontSize: '11px', padding: '3px 6px', borderRadius: C.radius,
      border: `1px solid ${C.border}`, background: C.bgBase, color: C.label,
    };

    /** The inline parameter form for the seven scan+apply capabilities. */
    function ApplyForm({ t, cap, form, onChange, onPreview, onToggleId, busy, items, meta }) {
      const kind = formKindOf(cap);
      if (!kind) return null;
      const out = validateForm(t, cap, form, items);
      const set = (patch) => onChange({ ...form, ...patch });

      const head = h('div', { style: { display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap' } },
        h('span', { style: { fontSize: '11px', fontWeight: 600 } }, t('formTitle')),
        h(Btn, {
          compact: true, tone: 'brand', disabled: busy || !out.ok,
          title: out.ok ? undefined : out.reason,
          onClick: out.ok ? () => onPreview(out.params) : undefined,
        }, busy ? t('applying') : t('formPreview')),
        !out.ok && out.reason ? h('span', { style: { color: C.warn } }, out.reason) : null,
      );

      let body = null;

      if (kind === 'homepage') {
        body = h('div', { style: FORM_ROW },
          h('span', { style: { color: C.label3 } }, t('homepageTarget')),
          h('select', {
            value: form.target ?? 'ie-start', ...focusable,
            onChange: (e) => set({ target: e.target.value }),
            style: FORM_INPUT,
          },
            h('option', { value: 'ie-start' }, 'ie-start'),
            h('option', { value: 'ie-search' }, 'ie-search'),
          ),
          h('span', { style: { color: C.label3 } }, t('homepageUrl')),
          h('input', {
            type: 'text', value: form.value ?? '', placeholder: 'https://', ...focusable,
            onChange: (e) => set({ value: e.target.value }),
            style: { ...FORM_INPUT, flex: '1 1 240px', minWidth: '160px' },
          }),
        );
      }

      if (kind === 'backup') {
        body = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '4px' } },
          h('span', { style: { fontSize: '10px', color: C.label3 } }, t('backupKeys')),
          h('textarea', {
            value: form.keys ?? '', rows: 3, ...focusable,
            onChange: (e) => set({ keys: e.target.value }),
            style: { ...FORM_INPUT, width: '100%', boxSizing: 'border-box', resize: 'vertical', fontFamily: 'inherit' },
          }),
        );
      }

      if (kind === 'contextmenu') {
        body = h('div', { style: FORM_ROW },
          h('span', { style: { color: C.label3 } }, t('cmClsid')),
          h('input', {
            type: 'text', value: form.clsid ?? '', placeholder: '{00000000-0000-0000-0000-000000000000}', ...focusable,
            onChange: (e) => set({ clsid: e.target.value }),
            style: { ...FORM_INPUT, flex: '1 1 260px', minWidth: '180px' },
          }),
          h('span', { style: { color: C.label3 } }, t('cmScope')),
          h('select', {
            value: form.scope ?? 'machine', ...focusable,
            onChange: (e) => set({ scope: e.target.value }),
            style: FORM_INPUT,
          },
            h('option', { value: 'machine' }, t('scopeMachine')),
            h('option', { value: 'user' }, t('scopeUser')),
          ),
          h('select', {
            value: form.action ?? 'disable', ...focusable,
            onChange: (e) => set({ action: e.target.value }),
            style: FORM_INPUT,
          },
            h('option', { value: 'disable' }, t('collapse')),
            h('option', { value: 'enable' }, t('expand')),
          ),
        );
      }

      if (kind === 'shredder') {
        const note = ssdTrimNote(meta);
        body = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '4px' } },
          h('span', { style: { fontSize: '10px', color: C.label3 } }, t('shredPaths')),
          h('textarea', {
            value: form.paths ?? '', rows: 3, ...focusable,
            onChange: (e) => set({ paths: e.target.value }),
            style: { ...FORM_INPUT, width: '100%', boxSizing: 'border-box', resize: 'vertical', fontFamily: 'inherit' },
          }),
          note
            ? h('div', { style: { fontSize: '10px', color: C.error, lineHeight: '1.45' } }, `⚠ ${t('ssdWarn')}`)
            : null,
        );
      }

      if (kind === 'tweaks') {
        const rows = (items ?? []).slice(0, 60);
        const chosen = new Set(Array.isArray(form.ids) ? form.ids : []);
        body = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '4px' } },
          h('div', { style: { ...FORM_ROW, color: C.label3 } },
            t('tweakIds'),
            h('select', {
              value: form.action ?? 'apply', ...focusable,
              onChange: (e) => set({ action: e.target.value }),
              style: FORM_INPUT,
            },
              h('option', { value: 'apply' }, t('tweakOn')),
              h('option', { value: 'revert' }, t('tweakOff')),
            ),
            h('span', null, `${chosen.size} / ${rows.length}`),
          ),
          h('div', { style: { display: 'flex', flexDirection: 'column', gap: '1px', maxHeight: '150px', overflowY: 'auto' } },
            rows.map((it) => h('label', {
              key: it.id,
              style: { display: 'flex', gap: '6px', alignItems: 'center', fontSize: '11px', color: C.label2, cursor: 'pointer' },
            },
              h('input', {
                type: 'checkbox', checked: chosen.has(it.id),
                onChange: () => onToggleId(it.id),
              }),
              h('span', { style: ellipsis }, it.label ?? it.id),
            )),
          ),
        );
      }

      if (kind === 'winsettings') {
        const rows = (items ?? []).filter((it) => it.id && it.id !== 'winsettings:action-set');
        body = h('div', { style: FORM_ROW },
          h('span', { style: { color: C.label3 } }, t('wsSetting')),
          h('select', {
            value: form.setting ?? '', ...focusable,
            onChange: (e) => set({ setting: e.target.value }),
            style: { ...FORM_INPUT, flex: '1 1 260px', minWidth: '180px' },
          },
            h('option', { value: '' }, '—'),
            rows.map((it) => h('option', { key: it.id, value: it.id }, it.label ?? it.id)),
          ),
          h('span', { style: { color: C.label3 } }, t('wsValue')),
          h('input', {
            type: 'text', value: form.value ?? '', ...focusable,
            onChange: (e) => set({ value: e.target.value }),
            style: { ...FORM_INPUT, width: '110px' },
          }),
        );
      }

      if (kind === 'softmgr') {
        body = h('div', { style: FORM_ROW },
          h('span', { style: { color: C.label3 } }, t('softAction')),
          h('select', {
            value: form.action ?? 'upgrade', ...focusable,
            onChange: (e) => set({ action: e.target.value }),
            style: FORM_INPUT,
          },
            h('option', { value: 'upgrade' }, t('actUpgrade')),
            h('option', { value: 'leftover' }, t('actLeftover')),
            h('option', { value: 'migrate' }, t('actMigrate')),
            h('option', { value: 'perm' }, t('actPerm')),
          ),
          h('span', { style: { color: C.label3 } }, t('softAppName')),
          h('input', {
            type: 'text', value: form.appName ?? '', ...focusable,
            onChange: (e) => set({ appName: e.target.value }),
            style: { ...FORM_INPUT, flex: '1 1 180px', minWidth: '120px' },
          }),
        );
      }

      if (kind === 'netdns') {
        // The probe only reports `candidates` on the dnspick verb, not on a plain
        // scan, so the menu would be empty on first open. Fall back to the same
        // five servers the probe and the host sanitizer accept (a test asserts
        // all three lists are identical); merge in whatever the probe did report
        // so a future probe-side addition shows up without touching this file.
        const KNOWN_DNS = [
          { ip: '223.5.5.5', label: '阿里 DNS' },
          { ip: '119.29.29.29', label: '腾讯 DNS' },
          { ip: '1.1.1.1', label: 'Cloudflare' },
          { ip: '8.8.8.8', label: 'Google DNS' },
          { ip: '114.114.114.114', label: '114 DNS' },
        ];
        const fromProbe = Array.isArray(meta?.candidates) ? meta.candidates.filter((c) => c && c.ip) : [];
        const byIp = new Map(KNOWN_DNS.map((c) => [c.ip, c]));
        for (const c of fromProbe) byIp.set(c.ip, { ip: c.ip, label: c.label ?? byIp.get(c.ip)?.label ?? c.ip });
        const candidates = [...byIp.values()];
        // A plain scan reports the configured resolvers as `dnsServers`; only the
        // dnspick verb calls them `currentDns`. Accept either so the "current:"
        // line is right before the user ever runs a switch.
        const current = Array.isArray(meta?.currentDns) && meta.currentDns.length
          ? meta.currentDns
          : (Array.isArray(meta?.dnsServers) ? meta.dnsServers : []);
        const rankRow = (items ?? []).find((it) => String(it.id ?? '') === 'dns:优选');
        const fastestHit = /最快\s*=\s*\d+\s*ms\s*[（(]\s*([\d.]+)\s*[)）]/.exec(String(rankRow?.value ?? ''));
        const fastestIp = fastestHit ? fastestHit[1] : '';
        body = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '4px' } },
          h('div', { style: FORM_ROW },
            h('span', { style: { color: C.label3 } }, t('dnsPickServer')),
            h('select', {
              value: form.server ?? '', ...focusable,
              onChange: (e) => set({ server: e.target.value }),
              style: { ...FORM_INPUT, flex: '1 1 220px', minWidth: '160px' },
            },
              h('option', { value: '' }, '—'),
              candidates.map((c) => h('option', {
                key: c.ip, value: c.ip,
              }, `${c.label ?? c.ip}（${c.ip}）${fastestIp && fastestIp === c.ip ? ' ★' : ''}`)),
              h('option', { value: 'auto' }, t('dnsPickAuto')),
            ),
          ),
          current.length
            ? h('div', { style: { fontSize: '10px', color: C.label3 } },
                `${t('dnsPickCurrent')} ${current.join(', ')}`)
            : null,
        );
      }

      return h('div', {
        style: {
          display: 'flex', flexDirection: 'column', gap: '6px', padding: '7px 9px',
          borderRadius: C.radiusMd, border: `1px solid ${C.border}`, background: C.bgLayer1,
        },
      }, head, body);
    }

    // ---- "what now" guidance ------------------------------------------------

    /**
     * A read-only capability that ends at "here are the numbers" is the exact
     * complaint this panel had: everything visible, nothing actionable. Each of
     * these returns ONE concrete next step derived from that capability's own
     * meta fields — never a shared sentence — plus an optional button that does
     * the step (switch capability, or run the probe elevated).
     */
    /**
     * The next step must be derived from this capability's own readings, so the
     * caller passes `nameOf` to turn capability ids into their display names; a
     * raw id in a sentence ("切到 softmgr") is not an instruction a user can act
     * on without looking something up.
     */
    function nextStepFor(t, cap, result, nameOf) {
      if (!cap || !result?.ok) return null;
      const meta = result.meta ?? {};
      const items = Array.isArray(result.items) ? result.items : [];
      const id = cap.id;
      const elev = { label: t('elevRequest'), elevate: true };
      const to = (capId) => ({ label: `${t('goTo')} ${nameOf ? nameOf(capId) : capId}`, capId });

      const anyBad = (s) => Number(s?.bad ?? 0) > 0;

      if (id === 'bigfiles') {
        return { text: items.length > 0 ? t('nextBigfilesHit') : t('nextBigfilesNone'), action: to('dupfiles') };
      }
      if (id === 'dupfiles') {
        return { text: (meta.groupsTotal ?? items.length) > 0 ? t('nextDupHit') : t('nextDupNone'), action: to('bigfiles') };
      }
      if (id === 'netdiag') {
        return meta.online === true
          ? { text: t('nextNetOk') }
          : { text: `${t('nextNetFail')} ${meta.firstFail ?? '—'}`, action: to('health') };
      }
      if (id === 'health') {
        const bad = anyBad(meta.summary) || Number(meta.summary?.warn ?? 0) > 0;
        return { text: bad ? t('nextHealthBad') : t('nextHealthOk'), action: bad ? to('junk') : undefined };
      }
      if (id === 'security') {
        const bad = anyBad(meta.summary) || Number(meta.summary?.warn ?? 0) > 0;
        return { text: bad ? t('nextSecurityBad') : t('nextSecurityOk'), action: bad ? elev : undefined };
      }
      if (id === 'privacy') return { text: t('nextPrivacyMeta') };
      if (id === 'perm') {
        const broad = (Array.isArray(meta.broadFsApps) ? meta.broadFsApps.length : 0)
          + (Array.isArray(meta.sensitiveAllow) ? meta.sensitiveAllow.length : 0);
        return { text: broad > 0 ? t('nextPermBroad') : t('nextPermOk') };
      }
      if (id === 'popup') {
        const hit = Number(meta.suspicious ?? 0) > 0 || Number(meta.adTasks ?? 0) > 0 || Number(meta.adSoftware ?? 0) > 0;
        return { text: hit ? t('nextPopupHit') : t('nextPopupNone'), action: hit ? to('softmgr') : undefined };
      }
      if (id === 'speedtest') {
        const slow = Number(meta.latencyMs ?? 0) >= 60 || Number(meta.jitterMs ?? 0) >= 30;
        return { text: slow ? t('nextSpeedtestSlow') : t('nextSpeedtestOk'), action: slow ? to('netdiag') : undefined };
      }
      if (id === 'slim') {
        const safe = Number(meta.safeGB ?? 0);
        return safe > 0
          ? { text: `${t('nextSlimSafe')} · ${safe.toFixed(2)} GB`, action: to('junk') }
          : { text: t('nextSlimNone') };
      }
      if (id === 'rescue') {
        const p = meta.pendingReboot ?? {};
        const pending = [p.cbs, p.windowsUpdate, p.pendingFileRename].some((v) => v === true);
        return { text: pending ? t('nextRescuePending') : t('nextRescueOk') };
      }
      if (id === 'software') {
        const hit = Number(meta.catalogMatched ?? 0) > 0;
        return { text: hit ? t('nextSoftwareHit') : t('nextSoftwareNone'), action: hit ? to('softmgr') : undefined };
      }
      if (id === 'drivers') {
        const bad = Number(meta.problemCount ?? 0) + Number(meta.unsignedCount ?? 0) > 0;
        return { text: bad ? t('nextDriversBad') : t('nextDriversOk'), action: bad ? elev : undefined };
      }
      if (id === 'drivers2') {
        const bad = Number(meta.missingTotal ?? 0) + Number(meta.needDriverTotal ?? 0) > 0;
        return { text: bad ? t('nextDrivers2Missing') : t('nextDrivers2Ok'), action: bad ? elev : undefined };
      }
      if (id === 'phone') {
        const on = Number(meta.connected ?? meta.wpdDevices ?? 0) > 0;
        return { text: on ? t('nextPhoneOk') : t('nextPhoneOff') };
      }
      if (id === 'proc') {
        // Busy is judged from the probe's own aggregate readings, not from a guess:
        // cpuTotalPct / memoryPct are machine-wide, so a single hot process shows up.
        const hot =
          Number(meta.cpuTotalPct ?? 0) >= 25 ||
          Number(meta.memoryPct ?? 0) >= 80 ||
          items.some((it) => it.status === 'bad' || it.status === 'warn');
        return { text: hot ? t('nextProcBusy') : t('nextProcIdle') };
      }
      if (id === 'diskhealth') {
        const smartShown = meta.smartReadable === true && meta.usedWin32Fallback !== true;
        if (Number(meta.predictFailureInstances ?? 0) > 0 || items.some((it) => it.status === 'bad')) {
          return { text: t('nextDiskBad'), action: elev };
        }
        if (!smartShown) return { text: t('nextDiskSkip'), action: elev };
        return { text: t('nextDiskOk'), action: elev };
      }
      if (id === 'junk') {
        const empty = items.every((it) => Number(it.bytes ?? 0) === 0);
        return empty ? { text: t('nextJunkNone'), action: to('slim') } : null;
      }
      return null;
    }

    function NextStep({ t, cap, result, onGo, onElevate, elevating, catalogue }) {
      // Capability ids in prose are useless; resolve them through the catalogue
      // the strip is already using.
      const nameOf = (capId) => {
        const found = Array.isArray(catalogue) ? catalogue.find((c) => c.id === capId) : null;
        return found ? capName(t, found) : String(capId);
      };
      const step = nextStepFor(t, cap, result, nameOf);
      if (!step) return null;
      const action = step.action;
      return h('div', {
        style: {
          display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap', fontSize: '11px',
          padding: '6px 9px', borderRadius: C.radius, border: `1px solid ${C.border}`,
          background: C.bgLayer1, color: C.label2, lineHeight: '1.5',
        },
      },
        h('span', { style: { color: C.label3, whiteSpace: 'nowrap' } }, `${t('nextStep')}:`),
        h('span', { style: { flex: '1 1 240px', minWidth: 0 } }, step.text),
        action && action.capId
          ? h(Btn, { compact: true, onClick: () => onGo(action.capId) }, action.label)
          : null,
        action && action.elevate
          ? h(Btn, { compact: true, tone: 'brand', disabled: elevating, onClick: onElevate },
              elevating ? t('elevRequesting') : action.label)
          : null,
      );
    }

    // ---- main panel ----------------------------------------------------------

    function Panel({ t }) {
      const [status, setStatus] = useState(null);
      const [error, setError] = useState('');
      const [busy, setBusy] = useState(false);
      /** Which capability is currently scanning, so only its card shows it. */
      const [scanningId, setScanningId] = useState(null);
      const [active, setActive] = useState('junk');
      const [group, setGroup] = useState('cleanup');
      const [results, setResults] = useState({});
      const [selected, setSelected] = useState(() => new Set());
      const [notice, setNotice] = useState(null);
      const [confirming, setConfirming] = useState(false);
      /**
       * Authoritative dry-run plan for whatever is being confirmed. `mode` keeps
       * the junk clean flow and the apply flow apart without duplicating the
       * dialog; null = nothing planned yet.
       */
      const [plan, setPlan] = useState(null);
      /**
       * Per-capability params, kept so a rescan reuses the user's choices. Keyed
       * by capability id and started empty: the defaults live where they are read,
       * so no capability id needs to be spelled out here.
       */
      const [params, setParams] = useState({});
      /**
       * Per-capability form values for the seven scan+apply capabilities.
       * Kept separate from `params` (which feeds the scan) so a scan and a
       * write never share a half-filled field.
       */
      const [forms, setForms] = useState({});
      const [elevating, setElevating] = useState(false);
      const [elevNote, setElevNote] = useState(null);
      const mounted = useRef(true);

      useEffect(() => () => { mounted.current = false; }, []);

      const loadStatus = useCallback(async () => {
        try {
          const data = await getJSON(`${API}/status`);
          if (mounted.current) { setStatus(data); setError(''); }
        } catch (e) {
          if (mounted.current) setError(String(e?.message ?? e));
        }
      }, []);

      useEffect(() => { loadStatus(); }, [loadStatus]);

      /** Pull whatever the host already has cached for a capability. */
      const loadCached = useCallback(async (id) => {
        try {
          const data = await getJSON(`${API}/result?id=${encodeURIComponent(id)}`);
          if (!mounted.current) return;
          if (data?.ok) {
            setResults((prev) => ({ ...prev, [id]: data }));
            if (id === 'junk') {
              // Preselect everything that can actually be cleaned, so the common
              // case (clean the obvious junk) needs one click, not sixteen.
              setSelected(new Set((data.items ?? []).filter((i) => i.exists && !i.blocked && i.bytes > 0).map((i) => i.id)));
            }
          }
        } catch { /* a missing cache is not an error */ }
      }, []);

      useEffect(() => { if (status) loadCached(active); }, [status, active, loadCached]);

      const runScan = useCallback(async (id) => {
        setBusy(true); setScanningId(id); setError(''); setNotice(null);
        try {
          const body = { id, force: true, params: params[id] ?? {} };
          const data = await postJSON(`${API}/run`, body);
          if (!mounted.current) return;
          if (data?.ok) {
            setResults((prev) => ({ ...prev, [id]: data }));
            if (id === 'junk') {
              setSelected(new Set((data.items ?? []).filter((i) => i.exists && !i.blocked && i.bytes > 0).map((i) => i.id)));
            }
            setNotice(null);
          } else {
            setError(data?.error ?? t('loadFailed'));
          }
          await loadStatus();
        } catch (e) {
          if (mounted.current) setError(String(e?.message ?? e));
        } finally {
          if (mounted.current) { setBusy(false); setScanningId(null); }
        }
      }, [params, loadStatus, t]);

      /**
       * Scanning a card that is not selected must also select it, otherwise the
       * result lands somewhere the user is not looking. Same for the elevation
       * path: one entry point, one selected capability.
       */
      const scanCap = useCallback(async (id) => {
        if (id !== active) { setConfirming(false); setPlan(null); setActive(id); }
        await runScan(id);
      }, [active, runScan]);

      /**
       * dryRun:true is the "plan" step — the probe re-measures the selected
       * targets and returns authoritative numbers, which the dialog then shows.
       * Only after the user confirms does dryRun:false run for real.
       */
      const doClean = useCallback(async (dryRun) => {
        setBusy(true); setError(''); setNotice(null);
        try {
          const targets = [...selected];
          const data = await postJSON(`${API}/clean`, { targets, dryRun });
          if (!mounted.current) return;
          if (data?.ok === false) { setError(data?.error ?? t('loadFailed')); return; }
          if (dryRun) {
            // The host normalizes the probe's junk rows into `items`, so the plan
            // IS the item list — there is no separate `targets` key.
            const items = data.items ?? [];
            const total = items.reduce((a, b) => a + Number(b.bytes ?? 0), 0);
            const files = items.reduce((a, b) => a + Number(b.files ?? 0), 0);
            const blocked = items.filter((i) => i.blocked === true).length;
            setPlan({ mode: 'clean', total, files, blocked, items, meta: data.meta ?? {} });
            setConfirming(true);
          } else {
            setNotice({ kind: 'done', text: `${t('freedNotice')} ${human(data.freed ?? 0)}` });
            setPlan(null);
            setConfirming(false);
            setSelected(new Set());
            await runScan('junk');
          }
        } catch (e) {
          if (mounted.current) setError(String(e?.message ?? e));
        } finally {
          if (mounted.current) setBusy(false);
        }
      }, [selected, runScan, t]);

      /**
       * Apply path for the capabilities whose catalogue says scan+apply
       * (homepage / backup / contextmenu / shredder). Same two-step discipline as
       * junk: the first call is always dryRun:true, and the dialog is the only
       * place that sends dryRun:false.
       */
      const doApply = useCallback(async (id, baseParams, dryRun) => {
        setBusy(true); setError(''); setNotice(null);
        try {
          const payload = { ...(baseParams ?? {}), dryRun };
          const data = await postJSON(`${API}/apply`, { id, params: payload });
          if (!mounted.current) return;
          if (data?.ok === false) { setError(data?.error ?? t('loadFailed')); return; }
          const items = data.items ?? [];
          if (dryRun) {
            setPlan({
              mode: 'apply',
              capId: id,
              params: baseParams ?? {},
              total: Number(data.meta?.plannedBytes ?? 0),
              files: items.length,
              blocked: items.filter((i) => i.status === 'skip').length,
              items,
              meta: data.meta ?? {},
            });
            setConfirming(true);
          } else {
            setNotice({ kind: 'done', text: `${t('applyDone')} · ${items.length} ${t('rowsUnit')}` });
            setPlan(null);
            setConfirming(false);
            await runScan(id);
          }
        } catch (e) {
          if (mounted.current) setError(String(e?.message ?? e));
        } finally {
          if (mounted.current) setBusy(false);
        }
      }, [runScan, t]);

      /**
       * Elevation is a real, separate run: the host process stays unelevated
       * (so /status keeps saying elevated:false — that is the truth) and a
       * child started through UAC does the work. A dismissed prompt comes back
       * as cancelled:true and is reported as such, never as a success and
       * never as a crash.
       */
      const runElevated = useCallback(async (id, baseParams, dryRun, mode) => {
        setElevating(true); setBusy(true); setError(''); setNotice(null); setElevNote(null);
        try {
          const payload = { ...(baseParams ?? {}), dryRun };
          const data = await postJSON(`${API}/elevated`, { id, params: payload });
          if (!mounted.current) return;
          if (data?.cancelled === true) {
            setElevNote({ kind: 'warn', text: data?.message || t('elevCancelled') });
            return;
          }
          if (data?.ok === false) {
            setElevNote({ kind: 'warn', text: `${t('elevFailed')}: ${data?.error ?? t('loadFailed')}` });
            return;
          }
          const items = data.items ?? [];
          if (mode === 'plan') {
            setPlan({
              mode: 'elevApply',
              capId: id,
              params: baseParams ?? {},
              total: Number(data.meta?.plannedBytes ?? 0),
              files: items.length,
              blocked: items.filter((i) => i.status === 'skip').length,
              items,
              meta: data.meta ?? {},
              elevated: data.elevated === true,
            });
            setConfirming(true);
          } else {
            setResults((prev) => ({ ...prev, [id]: data }));
            setElevNote({ kind: 'done', text: t('elevDone') });
            setNotice({ kind: 'done', text: `${t('elevDone')} · ${items.length} ${t('rowsUnit')}` });
            await loadStatus();
          }
        } catch (e) {
          if (mounted.current) setElevNote({ kind: 'warn', text: `${t('elevFailed')}: ${String(e?.message ?? e)}` });
        } finally {
          if (mounted.current) { setElevating(false); setBusy(false); }
        }
      }, [loadStatus, t]);

      /**
       * The ONE elevation request, shared with the other tab.
       *
       * `probe:true` starts (or adopts) the resident elevated broker and runs no
       * capability at all — the host then answers `elevated:true` on /status for
       * BOTH halves, so this bar disappears everywhere and no later action shows
       * a second UAC prompt. It used to run the currently selected capability
       * elevated, which meant one prompt per click *and* a scan the user did not
       * ask for.
       */
      const elevateActive = useCallback(async () => {
        setElevating(true); setElevNote(null);
        try {
          const data = await postJSON(`${API}/elevated`, { probe: true });
          if (!mounted.current) return;
          if (data?.cancelled === true) {
            setElevNote({ kind: 'warn', text: data?.message || t('elevCancelled') });
            return;
          }
          if (data?.elevated === true) {
            setElevNote({ kind: 'done', text: t('elevGranted') });
            await loadStatus();
            return;
          }
          setElevNote({ kind: 'warn', text: `${t('elevFailed')}: ${data?.error ?? t('loadFailed')}` });
        } catch (e) {
          if (mounted.current) setElevNote({ kind: 'warn', text: `${t('elevFailed')}: ${String(e?.message ?? e)}` });
        } finally {
          if (mounted.current) setElevating(false);
        }
      }, [loadStatus, t]);

      const setForm = useCallback((id, next) => {
        setForms((prev) => ({ ...prev, [id]: next }));
      }, []);

      const formOf = (id) => forms[id] ?? defaultFormOf(id);

      const catalogue = status?.catalogue ?? [];
      const statusOf = useMemo(() => {
        const m = new Map();
        for (const s of status?.capabilities ?? []) m.set(s.id, s);
        return m;
      }, [status]);
      const groupTabs = useMemo(() => {
        const gs = status?.groups;
        return Array.isArray(gs) ? gs.filter((g) => g && g.id) : [];
      }, [status]);
      // A stale or minimal /status may omit groups entirely: then no tabs and
      // every capability stays reachable.
      const activeGroup = groupTabs.length === 0
        ? null
        : (groupTabs.some((g) => g.id === group) ? group : groupTabs[0].id);
      const visible = activeGroup === null
        ? catalogue
        : catalogue.filter((c) => (c.group ?? groupTabs[0].id) === activeGroup);
      const result = results[active];
      const capMeta = catalogue.find((c) => c.id === active);
      const view = viewOf(capMeta);
      const hostLine = useMemo(() => {
        if (!status?.host) return '';
        const host = status.host;
        const elev = host.elevated === true ? t('hostElevated') : t('hostNormal');
        return [host.os, elev, host.user ? `user: ${host.user}` : ''].filter(Boolean).join(' · ');
      }, [status, t]);

      const toggleTarget = (id) => {
        const next = new Set(selected);
        if (next.has(id)) next.delete(id); else next.add(id);
        setSelected(next);
      };

      /**
       * A pending confirmation belongs to the capability it was planned for.
       * Navigating away drops it, so the dialog can never confirm an operation
       * the user is no longer looking at.
       */
      const dropPlan = () => {
        setConfirming(false);
        setPlan(null);
      };
      const selectCap = (id) => {
        if (id !== active) dropPlan();
        setActive(id);
      };
      const selectGroup = (gid) => {
        setGroup(gid);
        const first = catalogue.find((c) => (c.group ?? '') === gid);
        if (first && first.id !== active) { dropPlan(); setActive(first.id); }
      };

      const summary = (() => {
        const st = statusOf.get(active);
        if (!st) return '';
        if (st.error) return `${t('error')}: ${st.error}`;
        if (!st.cached) return t('notScanned');
        return `${st.itemCount} ${t('itemsUnit')}`;
      })();

      const canApply = Array.isArray(capMeta?.actions) && capMeta.actions.includes('apply');
      const cov = covBadge(t, capMeta);
      const checkSummary = result?.ok ? result.meta?.summary : null;
      const planNote = plan?.mode === 'apply' || plan?.mode === 'elevApply' ? ssdTrimNote(plan.meta) : null;
      // files=MB / groups=KB; the host clamps both, these are only the form defaults.
      const minKey = view === 'files' ? 'minMb' : 'minKb';
      const minDefault = view === 'files' ? 100 : 1024;

      /**
       * The seven scan+apply capabilities all take parameters the scan cannot
       * supply, so the panel owns a form per capability and the apply entry is
       * only live once that form is valid — with the reason shown when it is
       * not. Nothing here ever sends a guessed parameter.
       */
      const formKind = formKindOf(capMeta);
      const activeForm = formKind ? formOf(active) : null;
      const formCheck = formKind
        ? validateForm(t, capMeta, activeForm, result?.items ?? [])
        : { ok: false, params: null, reason: '' };
      const formItems = result?.items ?? [];
      const formMeta = result?.meta ?? {};
      const rowGateText = formKind
        ? (formCheck.ok ? t('rowNeedsForm') : formCheck.reason)
        : '';
      // A plan is either a plain apply or the same apply run elevated; they share
      // the dialog, the difference is only which endpoint confirms it.
      const isApplyPlan = plan?.mode === 'apply' || plan?.mode === 'elevApply';

      return h('div', {
        style: {
          display: 'flex', flexDirection: 'column', gap: '9px', height: '100%', minHeight: 0,
          padding: '12px', background: C.bgBase, color: C.label, boxSizing: 'border-box',
        },
      },
        // elevation status bar — only when the host actually says it is not
        // elevated. Never rendered speculatively: a missing /status field means
        // "unknown", not "unelevated".
        status?.host?.elevated === false
          ? h('div', {
              style: {
                display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap',
                fontSize: '11px', padding: '6px 9px', borderRadius: C.radius,
                border: `1px solid ${C.warn}`, background: C.bgLayer1, color: C.label2,
              },
            },
              h('span', { style: { color: C.warn } }, `⚠ ${t('elevNot')}`),
              h('span', { style: { flex: 1 } }),
              h(Btn, {
                compact: true, tone: 'brand', disabled: elevating || busy,
                title: t('elevationHint'),
                onClick: elevateActive,
              }, elevating ? t('elevRequesting') : t('elevRequest')),
              elevNote
                ? h('span', { style: { color: elevNote.kind === 'done' ? C.success : C.warn, flex: '1 1 100%' } }, elevNote.text)
                : null,
            )
          : null,

        // header
        h('div', { style: { display: 'flex', alignItems: 'flex-start', gap: '10px', flexWrap: 'wrap' } },
          h('div', { style: { flex: '1 1 320px', minWidth: 0 } },
            h('div', { style: { fontSize: '15px', fontWeight: 650 } }, t('title')),
            h('div', { style: { fontSize: '11px', color: C.label2, lineHeight: '1.5', marginTop: '2px' } },
              // The count comes from the host, never from a literal: it said
              // "27" for a whole release after proc and diskhealth were added.
              catalogue.length > 0 ? t('subtitle').replace('{n}', String(catalogue.length)) : t('subtitle')),
            hostLine ? h('div', { style: { fontSize: '10px', color: C.label3, marginTop: '3px' } }, hostLine) : null,
          ),
          h('div', { style: { display: 'flex', gap: '6px', alignItems: 'center', flexWrap: 'wrap' } },
            h(Btn, {
              onClick: () => runScan(active), disabled: busy, tone: 'brand',
            }, busy ? t('scanning') : (statusOf.get(active)?.cached ? t('rescan') : t('scan'))),
            canApply
              ? h(Btn, {
                  onClick: formKind
                    ? () => doApply(active, formCheck.params, true)
                    : () => doApply(active, params[active] ?? {}, true),
                  disabled: busy || (formKind ? !formCheck.ok : false),
                  tone: 'danger',
                  title: formKind && !formCheck.ok ? formCheck.reason : (capMeta?.detail || undefined),
                }, busy ? t('applying') : t('apply'))
              : null,
          ),
        ),
        h('div', {
          style: {
            fontSize: '10px', color: C.label3, lineHeight: '1.5',
            padding: '5px 8px', borderRadius: C.radius, background: C.bgLayer1,
            border: `1px solid ${C.border}`,
          },
        }, t('scopeNote'),
          status?.host?.elevated === false ? h('div', { style: { marginTop: '2px', color: C.warn } }, `⚠ ${t('elevationHint')}`) : null,
        ),

        groupTabs.length > 0
          ? h(GroupTabs, { t, groups: groupTabs, selected: activeGroup, onSelect: selectGroup })
          : null,

        h(CapStrip, {
          t, catalogue: visible, statusOf, active,
          onSelect: selectCap,
          onScan: scanCap,
          // scanningId, not `active`: the spinner belongs on the card whose scan
          // is actually in flight, which is not always the selected one.
          busy: scanningId,
        }),

        // current capability: name + coverage badge + why-it-cannot (if any)
        capMeta ? h('div', { style: { display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap', fontSize: '11px', color: C.label2 } },
          h('span', { style: { fontSize: '12px', fontWeight: 600, color: C.label } }, capName(t, capMeta)),
          cov ? h(Badge, cov) : null,
          capMeta.needsAdmin === true ? h(Badge, { text: t('needAdminBadge'), color: C.warn }) : null,
          capTag(t, capMeta) ? h('span', { style: { color: C.label3 } }, capTag(t, capMeta)) : null,
          (cov && capMeta.detail) ? h('span', { style: { color: C.label3, flex: '1 1 100%' } }, capMeta.detail) : null,
          (view === 'files' || view === 'groups')
            ? [
              h('span', { key: 'r' }, t('rootLabel')),
              h('select', {
                key: 'root', value: params[active]?.root ?? 'user',
                onChange: (e) => setParams({ ...params, [active]: { ...(params[active] ?? {}), root: e.target.value } }),
                ...focusable,
                style: { font: 'inherit', fontSize: '11px', padding: '2px 6px', borderRadius: C.radius, border: `1px solid ${C.border}`, background: C.bgBase, color: C.label },
              }, (status?.scanRoots ?? []).map((r) => h('option', { key: r.id, value: r.id }, r.label))),
              h('span', { key: 'm' }, view === 'files' ? t('minMbLabel') : t('minKbLabel')),
              h('input', {
                key: 'min', type: 'number', min: 1,
                value: params[active]?.[minKey] ?? minDefault,
                onChange: (e) => {
                  const v = Number(e.target.value) || 1;
                  setParams({ ...params, [active]: { ...(params[active] ?? {}), [minKey]: v } });
                },
                ...focusable,
                style: { font: 'inherit', fontSize: '11px', width: '76px', padding: '2px 6px', borderRadius: C.radius, border: `1px solid ${C.border}`, background: C.bgBase, color: C.label },
              }),
            ]
            : null,
        ) : null,

        // inline parameter form for the seven scan+apply capabilities
        formKind
          ? h(ApplyForm, {
              t, cap: capMeta, form: activeForm, items: formItems, meta: formMeta,
              busy,
              onChange: (next) => setForm(active, next),
              onPreview: (p) => doApply(active, p, true),
              onToggleId: (tid) => {
                const cur = Array.isArray(activeForm.ids) ? activeForm.ids : [];
                const next = cur.includes(tid) ? cur.filter((x) => x !== tid) : cur.concat([tid]);
                setForm(active, { ...activeForm, ids: next });
              },
            })
          : null,

        active === 'junk' && result?.ok
          ? h('div', { style: { display: 'flex', gap: '8px', alignItems: 'center', flexWrap: 'wrap', fontSize: '11px' } },
              h(Btn, {
                compact: true,
                onClick: () => setSelected(new Set((result.items ?? []).filter((i) => i.exists && !i.blocked && i.bytes > 0).map((i) => i.id))),
              }, t('selectAll')),
              h(Btn, { compact: true, onClick: () => setSelected(new Set()) }, t('selectNone')),
              h('span', { style: { color: C.label3 } },
                `${t('selectedSummary')} ${selected.size} / ${(result.items ?? []).length}`),
              h('span', { style: { flex: 1 } }),
              h(Btn, {
                compact: true, tone: 'danger', disabled: busy || selected.size === 0,
                onClick: () => doClean(true),
              }, busy ? t('cleaning') : `${t('clean')} (${human((result.items ?? []).filter((i) => selected.has(i.id)).reduce((a, b) => a + Number(b.bytes ?? 0), 0))})`),
            )
          : null,

        // summary line
        h('div', { style: { display: 'flex', gap: '16px', flexWrap: 'wrap', alignItems: 'baseline' } },
          h(Stat, { label: t('colStatus'), value: busy ? t('scanning') : summary }),
          result?.ok && view === 'junk'
            ? [
              h(Stat, { key: 'a', label: t('totalJunk'), value: human(result.meta?.totalBytes ?? 0), tone: C.warn }),
              h(Stat, { key: 'b', label: t('colFiles'), value: String(result.meta?.totalFiles ?? 0) }),
            ]
            : null,
          result?.ok && view === 'files'
            ? [
              h(Stat, { key: 'a', label: t('scannedFiles'), value: String(result.meta?.scanned ?? 0) }),
              h(Stat, { key: 'b', label: t('matchedFiles'), value: String(result.meta?.matched ?? 0) }),
              h(Stat, { key: 'c', label: t('colSize'), value: human((result.items ?? [])[0]?.bytes ?? 0) }),
            ]
            : null,
          result?.ok && view === 'groups'
            ? [
              h(Stat, { key: 'a', label: t('scannedFiles'), value: String(result.meta?.scanned ?? 0) }),
              h(Stat, { key: 'b', label: t('groupsCount'), value: String(result.meta?.groupsTotal ?? 0) }),
              h(Stat, { key: 'c', label: t('wastedTotal'), value: human(result.meta?.wastedTotal ?? 0), tone: C.warn }),
            ]
            : null,
          result?.ok && view === 'steps'
            ? h(Stat, {
                label: t('colStatus'),
                value: result.meta?.online ? t('netOnline') : t('netOffline'),
                tone: result.meta?.online ? C.success : C.warn,
              })
            : null,
          // Every checks-view capability reports the same five-state tally.
          result?.ok && view === 'checks' && checkSummary
            ? [
              h(Stat, { key: 'a', label: t('statusOk'), value: String(checkSummary.ok ?? 0), tone: C.success }),
              h(Stat, { key: 'b', label: t('statusWarn'), value: String(checkSummary.warn ?? 0), tone: C.warn }),
              h(Stat, { key: 'c', label: t('statusBad'), value: String(checkSummary.bad ?? 0), tone: C.error }),
              checkSummary.skip > 0
                ? h(Stat, { key: 'd', label: t('statusSkip'), value: String(checkSummary.skip), tone: C.label3 })
                : null,
            ]
            : null,
        ),

        error ? h('div', { style: { fontSize: '11px', color: C.error } }, `${t('error')}: ${error}`) : null,
        notice ? h('div', {
          style: {
            fontSize: '11px', padding: '5px 8px', borderRadius: C.radius,
            color: notice.kind === 'done' ? C.success : C.warn,
            border: `1px solid ${notice.kind === 'done' ? C.success : C.warn}`,
          },
        }, notice.text) : null,

        // result area
        h('div', { style: { flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' } },
          !result
            ? h('div', { style: { padding: '18px', fontSize: '12px', color: C.label3 } }, t('notScanned'))
            : !result.ok
              ? h('div', { style: { padding: '18px', fontSize: '12px', color: C.error } }, `${t('error')}: ${result.error}`)
              : view === 'junk'
                ? h(JunkTable, { t, items: result.items ?? [], selected, onToggle: toggleTarget })
                : view === 'files'
                  ? h(BigFilesTable, { t, items: result.items ?? [] })
                  : view === 'groups'
                    ? h(DupTable, { t, items: result.items ?? [] })
                    : view === 'steps'
                      ? h(NetSteps, { t, items: result.items ?? [], meta: result.meta ?? {} })
                      : h(ChecksList, {
                          t,
                          items: result.items ?? [],
                          cap: capMeta,
                          rowGateText,
                          onApplyRow: (item, p) => doApply(active, p, true),
                        }),
        ),

        // One concrete next step per read-only capability, derived from its own
        // meta readings — never the same sentence for all of them.
        h(NextStep, {
          t,
          cap: capMeta,
          result,
          catalogue,
          elevating,
          onGo: (capId) => selectCap(capId),
          onElevate: elevateActive,
        }),

        result?.ok && (result.meta?.truncated === true)
          ? h('div', { style: { fontSize: '10px', color: C.warn } }, t('truncated'))
          : null,
        result?.cached
          ? h('div', { style: { fontSize: '10px', color: C.label3 } }, t('cachedHint'))
          : null,

        // confirm dialog — shared by junk cleanup (mode 'clean') and apply ('apply')
        confirming
          ? h('div', {
              style: {
                position: 'absolute', inset: 0, background: 'rgba(0,0,0,0.35)',
                display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '18px',
              },
            },
            h('div', {
              style: {
                maxWidth: '460px', width: '100%', background: C.bgBase, color: C.label,
                border: `1px solid ${C.border}`, borderRadius: C.radiusMd, padding: '13px',
                display: 'flex', flexDirection: 'column', gap: '9px',
              },
            },
              h('div', { style: { fontSize: '13px', fontWeight: 600 } },
                isApplyPlan ? t('applyTitle') : t('confirmTitle')),
              h('div', { style: { fontSize: '12px', color: C.label2, lineHeight: '1.5' } },
                isApplyPlan ? t('applyBody') : t('confirmBody')),
              planNote
                ? h('div', {
                    style: {
                      fontSize: '11px', lineHeight: '1.5', color: C.error,
                      border: `1px solid ${C.error}`, borderRadius: C.radius, padding: '6px 8px',
                    },
                  }, `⚠ ${t('ssdWarn')}`)
                : null,
              !plan
                ? h('div', { style: { fontSize: '12px', color: C.label3 } }, t('planMeasuring'))
                : plan.mode === 'apply' || plan.mode === 'elevApply'
                  ? h('div', { style: { display: 'flex', flexDirection: 'column', gap: '7px', padding: '7px 9px', border: `1px solid ${C.border}`, borderRadius: C.radius } },
                      h('div', { style: { display: 'flex', gap: '16px', flexWrap: 'wrap' } },
                        h(Stat, { label: t('applyPlan'), value: `${plan.items.length} ${t('rowsUnit')}` }),
                        plan.total > 0 ? h(Stat, { label: t('planTotal'), value: human(plan.total), tone: C.warn }) : null,
                        plan.blocked > 0 ? h(Stat, { label: t('statusSkip'), value: String(plan.blocked), tone: C.warn }) : null,
                      ),
                      h('div', { style: { display: 'flex', flexDirection: 'column', gap: '2px', maxHeight: '190px', overflowY: 'auto' } },
                        plan.items.slice(0, 12).map((it, j) => h('div', {
                          key: it.id ?? `row-${j}`, title: it.detail ?? '',
                          style: { display: 'grid', gridTemplateColumns: 'minmax(0,1fr) auto', gap: '8px', fontSize: '10px', color: C.label2 },
                        },
                          h('div', { style: ellipsis }, `${it.label ?? ''}${it.value ? ` · ${it.value}` : ''}`),
                          h('span', { style: { color: statusColor(it.status), whiteSpace: 'nowrap' } }, statusText(t, it.status)),
                        )),
                        plan.items.length > 12
                          ? h('div', { style: { fontSize: '10px', color: C.label3 } }, `… ${plan.items.length - 12} ${t('rowsUnit')}`)
                          : null,
                      ),
                    )
                  : h('div', { style: { display: 'flex', gap: '16px', flexWrap: 'wrap', padding: '7px 9px', border: `1px solid ${C.border}`, borderRadius: C.radius } },
                      h(Stat, { label: t('planTotal'), value: human(plan.total), tone: C.warn }),
                      h(Stat, { label: t('planFiles'), value: String(plan.files) }),
                      plan.blocked > 0
                        ? h(Stat, { label: t('colState'), value: `${plan.blocked} ${t('planBlocked')}`, tone: C.warn })
                        : null,
                    ),
              h('div', { style: { display: 'flex', gap: '8px', justifyContent: 'flex-end' } },
                h(Btn, {
                  compact: true,
                  onClick: () => { setConfirming(false); setPlan(null); },
                }, t('confirmCancel')),
                h(Btn, {
                  compact: true, tone: 'danger',
                  disabled: busy || !plan || (isApplyPlan ? plan.items.length === 0 : plan.total <= 0),
                  onClick: () => (plan?.mode === 'apply'
                    ? doApply(plan.capId, plan.params, false)
                    : plan?.mode === 'elevApply'
                      ? runElevated(plan.capId, plan.params, false, 'exec')
                      : doClean(false)),
                }, isApplyPlan ? t('apply') : t('confirmOk')),
              ),
            ),
          )
          : null,
      );
    }

    /** Sidebar glyph: a toolbox with a handle (matches icon.svg). */
    function ToolboxIcon({ size = 16 }) {
      return h('svg', {
        width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
        stroke: 'currentColor', strokeWidth: 1.7, strokeLinecap: 'round', strokeLinejoin: 'round',
        'aria-hidden': true,
      },
        h('path', { d: 'M9 7V5.4A1.4 1.4 0 0 1 10.4 4h3.2A1.4 1.4 0 0 1 15 5.4V7' }),
        h('rect', { x: 2.5, y: 7, width: 19, height: 12.5, rx: 2 }),
        h('path', { d: 'M2.5 12.4h6.2M15.3 12.4h6.2' }),
        h('rect', { x: 9.4, y: 10.6, width: 5.2, height: 3.6, rx: 1 }),
      );
    }

    // ---- module registration ----
    return {
      inject: ['slots', 'locale', 'theme'],
      apply(ctx) {
        let t = (k) => k;
        let layout;
        if (ctx.locale && typeof ctx.locale.register === 'function' && typeof ctx.locale.bind === 'function') {
          ctx.effect(() => ctx.locale.register(NS, DICT), 'dsh-360-toolbox: dictionaries');
          t = ctx.locale.bind(NS);
        }
        try { ctx.inject(['layout'], (scoped) => { layout = scoped.layout; }); } catch { /* optional */ }
        ctx.effect(() => {
          const offs = [];
          // MUST go through ctx.slots.inject(name, () => ctx.slots.register(...)):
          // rc.3 declares these slots lazily, so a bare register() at apply time
          // runs before the declaration exists and is silently dropped.
          try {
            offs.push(ctx.slots.inject('main', () => ctx.slots.register({
              name: 'main', key: PANEL_ID, locale: NS, inject: () => ({ t }),
            }, () => h(Panel, { t }))));
          } catch (e) { console.warn('[dsh-360-toolbox] main panel registration failed:', e?.message); }
          try {
            offs.push(ctx.slots.inject('sidebar.panellist', () => ctx.slots.register({
              name: 'sidebar.panellist', id: PANEL_ID, order: 8, label: () => t('nav'), locale: NS,
            }, (owner = {}) => h(ToolboxIcon, { size: owner.size ?? 16 }))));
          } catch (e) { console.warn('[dsh-360-toolbox] sidebar row unavailable:', e?.message); }

          return () => {
            for (const off of offs) { if (typeof off === 'function') { try { off(); } catch { /* noop */ } } }
            try { if (layout?.panelInfo?.getSnapshot?.().activePanelId === PANEL_ID) layout.selectPanel?.(null); } catch { /* noop */ }
          };
        }, 'dsh-360-toolbox: workbench panel');
      },
    };
  },
});
