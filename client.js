/**
 * dsh-windows-toolbox — Client half: the single 工作栏 panel for both halves.
 *
 * GENERATED FILE — build it with `node tools/merge-client.mjs`, do not edit.
 * It concatenates the two module bodies from
 *    tools/legacy/manage-client.js   (manage half)
 *    tools/legacy/toolbox-client.js  (toolbox half)
 * verbatim, each inside its own function scope, and adds only:
 *
 *   - one sidebar entry ("WINDOWS工具箱", order 7) instead of two;
 *   - a two-tab shell so the panels switch in place;
 *   - three locale namespaces, so the two dictionaries keep their own keys
 *     (both define nav/title/refresh/loading, with different meanings).
 *
 * Everything else -- the card grid, the checks list, the apply forms, the
 * dry-run dialogs -- is the original component code, unchanged, so a fix in
 * either half still lands in the same component it was written for.
 */
window.__ModuleLoader__.load({
  id: 'dsh-windows-toolbox',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    const { useState } = React;

    const NS = 'dsh-windows-toolbox';
    const NS_MANAGE = 'dsh-windows-toolbox-manage';
    const NS_TOOLBOX = 'dsh-windows-toolbox-toolbox';
    const PANEL_ID = 'dsh-windows-toolbox';

    /** Only the shell's own strings live here; each half carries its own. */
    const SHELL_DICT = {
      zh: {
        nav: 'WINDOWS工具箱',
        title: 'WINDOWS工具箱',
        tabManage: '插件化管理',
        tabToolbox: '工具箱',
        tabManageHint: '本机装了哪些东西、在哪注册、关掉会怎样',
        tabToolboxHint: '清理、体检、修复、软件与驱动',
      },
      en: {
        nav: 'Windows Toolbox',
        title: 'Windows Toolbox',
        tabManage: 'Plugins',
        tabToolbox: 'Toolbox',
        tabManageHint: 'What is installed, where it hooks in, what turning it off does',
        tabToolboxHint: 'Cleanup, health, repair, software and drivers',
      },
    };

    // ---- manage half (tools/legacy/manage-client.js, verbatim body) ----
    function makeManageModule(require) {
    const React = require('react');
    const h = React.createElement;
    const { useState, useEffect, useCallback, useMemo } = React;

    const API = '/dsh-windows-toolbox/api/manage';

    const DICT = {
      zh: {
        nav: 'Windows 插件化管理器',
        title: 'Windows 插件化管理器',
        subtitle: '把 Windows 加载东西的十一个注册点合成一份可读索引：服务、计划任务、开机自启、外壳扩展、已安装程序、AppX/MSIX、驱动、防火墙规则、映像劫持、文件关联、凭据提供程序；另有一个独立的系统修复板块（八项配置漂移检查，不是注册点、不能开关）。每张卡片用一句话说清「这玩意是干嘛的」，点开能看在哪出现、关掉会怎样，以及能不能恢复。',
        scopeNote: '已安装程序 / AppX / 驱动可以卸载（卸载不可撤销，只能重装）；服务、计划任务、开机自启、外壳扩展、防火墙规则可以启停并回滚。服务、计划任务、防火墙与机器级卸载需要管理员权限，面板会给你一个「请求提权」的入口。',
        hostElevated: '已提权',
        hostNormal: '未提权',
        hostNormalHint: '服务与计划任务的启停需要管理员权限；外壳扩展与开机自启（当前用户）可以直接改。',
        hostElevatedHint: '当前进程带管理员令牌，服务、计划任务、防火墙与机器级卸载可以直接执行。',
        elevateBanner: '当前未提权 · 服务与计划任务的改动需要管理员',
        elevateAsk: '请求提权',
        elevateAsking: '等待 UAC 确认…',
        elevateOk: '已提权，可以继续操作',
        elevateOkDetail: '提权通道已就绪（{user}）',
        elevateCancelled: '你取消了 UAC 提权，什么都没改',
        elevateFailed: '提权失败：{message}',
        elevateTimeout: '提权在限定时间内没有返回结果（UAC 对话框可能还开着）',
        elevateRetryAdmin: '以管理员身份重试',
        elevateRetrying: '正在提权重试…',
        uninstallNote: '卸载不可撤销：安装记录会消失，要恢复只能重新安装。',
        totalEntries: '条目',
        refresh: '刷新索引',
        refreshing: '正在枚举…',
        loading: '正在首次枚举本机注册点…（十一类注册点加系统修复，合计约 13 秒）',
        loadFailed: '加载失败',
        search: '搜索名称 / 路径 / 发布者',
        allSources: '全部来源',
        anyState: '全部状态',
        onlyOn: '只看启用中',
        onlyOff: '只看已禁用',
        onlyActionable: '只看可操作',
        empty: '没有条目。点「刷新索引」重新枚举。',
        noMatch: '没有符合当前筛选条件的条目。',
        actionEnable: '启用',
        actionDisable: '禁用',
        actionDryRun: '预演',
        actionRollback: '回滚',
        actionUninstall: '卸载',
        actionModify: '修改安装',
        actionWorking: '处理中…',
        dryRunBadge: '预演结果（未写入）',
        workedBadge: '已写入',
        needsAdmin: '该操作需要管理员权限。',
        readonlyNote: '此项在本版本仅只读。',
        blockedNote: '受保护项：关掉它可能导致系统无法启动或无法使用，已拒绝操作。',
        riskReversible: '可逆',
        riskDestructive: '破坏性',
        riskBlocked: '受保护',
        riskReadonly: '只读',
        enabled: '启用',
        disabled: '禁用',
        unknownState: '—',
        ms: 'ms',
        staleHint: '（缓存，点刷新更新）',
        sourceError: '该类枚举失败',
        confirmCancel: '取消',
        confirmOk: '确认执行',
        undoKept: '回滚记录已保存',
        // ---- cards --------------------------------------------------------
        exp_what: '这是什么',
        exp_where: '在哪能看到',
        exp_purpose: '它是干什么的',
        exp_ifOff: '关掉会怎样',
        exp_facts: '相关事实',
        exp_raw: '原始数据',
        origin_ms: '微软',
        origin_third: '第三方',
        viewDetail: '展开详情',
        collapse: '收起',
        noExplain: '这一条还没有自动生成的通俗解释，下面显示它的原始状态。',
        copy: '复制',
        copied: '已复制',
        // ---- system repair (repair.ps1) -----------------------------------
        repairTitle: '系统修复',
        repairHint: '八项配置漂移检查（hosts / IE 主页 / DNS / 连接数 / UAC / 冗余注册表项 / 字体缓存 / 图标缓存）。',
        repairScan: '检测',
        repairDryRun: '预演修复（不写入）',
        repairApply: '执行修复',
        repairRunning: '检查中…',
        repairSummary: '共 {total} 项：正常 {ok} · 提示 {warn} · 异常 {bad} · 记录 {info} · 无法检查 {skip}',
        repairDryRunNote: '预演：以下动作都没有真正写入。',
        repairAppliedNote: '已按预演结果执行修复。',
        repairFailed: '系统修复检查失败',
        riskBlockedNote: '受保护项',
        // ---- installed-program facts + cross-plugin hint -------------------
        progLocation: '安装位置',
        progSize: '占用大小',
        progInstalled: '安装日期',
        progVersion: '版本',
        progPublisher: '发布者',
        progSystemComponent: '系统组件',
        progSystemComponentHint: '这条被标记为系统组件，探针会拒绝卸载它。',
        progSoftmgrHint: '升级与搬家见 360 工具箱的软件管家',
        readonlyBadge: '仅查看',
      },
      en: {
        nav: 'Windows Plugin Manager',
        title: 'Windows Plugin Manager',
        subtitle: 'One readable index over the eleven places Windows loads things from: services, scheduled tasks, autostart, shell extensions, installed programs, AppX/MSIX, drivers, firewall rules, image-file hijacks, file associations and credential providers — plus a separate system-repair board (eight configuration-drift checks; not registration points and not switchable). Every card says in one sentence what the thing is; click it to see where it shows up, what breaks if you turn it off, and whether it can be undone.',
        scopeNote: 'Installed programs, AppX and driver packages can be uninstalled (uninstalling cannot be undone — only reinstalling brings it back); services, scheduled tasks, autostart, shell extensions and firewall rules can be toggled and rolled back. Services, scheduled tasks, firewall rules and machine-wide uninstalls need administrator rights — the panel offers a "Request elevation" entry for those.',
        hostElevated: 'Elevated',
        hostNormal: 'Not elevated',
        hostNormalHint: 'Starting/stopping services and tasks needs administrator rights; shell extensions and per-user autostart can be changed directly.',
        hostElevatedHint: 'This process holds an administrator token, so services, scheduled tasks, firewall rules and machine-wide uninstalls run directly.',
        elevateBanner: 'Not elevated · service and task changes need administrator rights',
        elevateAsk: 'Request elevation',
        elevateAsking: 'Waiting for the UAC prompt…',
        elevateOk: 'Elevated — you can act now',
        elevateOkDetail: 'Elevation channel ready ({user})',
        elevateCancelled: 'You cancelled the UAC prompt; nothing was changed',
        elevateFailed: 'Elevation failed: {message}',
        elevateTimeout: 'Elevation did not return in time (the UAC dialog may still be open)',
        elevateRetryAdmin: 'Retry as administrator',
        elevateRetrying: 'Retrying elevated…',
        uninstallNote: 'Uninstalling cannot be undone: the install record is gone and only reinstalling brings it back.',
        totalEntries: 'entries',
        refresh: 'Refresh index',
        refreshing: 'Enumerating…',
        loading: 'Enumerating this machine\'s registration points… (~13 s for all eleven sources plus the repair board on a cold start)',
        loadFailed: 'Load failed',
        search: 'Search name / path / publisher',
        allSources: 'All sources',
        anyState: 'Any state',
        onlyOn: 'Enabled only',
        onlyOff: 'Disabled only',
        onlyActionable: 'Actionable only',
        empty: 'No entries. Press "Refresh index" to enumerate.',
        noMatch: 'No entries match the current filters.',
        actionEnable: 'Enable',
        actionDisable: 'Disable',
        actionDryRun: 'Dry run',
        actionRollback: 'Roll back',
        actionUninstall: 'Uninstall',
        actionModify: 'Modify',
        actionWorking: 'Working…',
        dryRunBadge: 'Dry run (nothing written)',
        workedBadge: 'Written',
        needsAdmin: 'This action needs administrator rights.',
        readonlyNote: 'Read-only in this version.',
        blockedNote: 'Protected: disabling it can make Windows unbootable or unusable, so the action is refused.',
        riskReversible: 'Reversible',
        riskDestructive: 'Destructive',
        riskBlocked: 'Protected',
        riskReadonly: 'Read-only',
        enabled: 'On',
        disabled: 'Off',
        unknownState: '—',
        ms: 'ms',
        staleHint: '(cached — refresh to update)',
        sourceError: 'this source failed to enumerate',
        confirmCancel: 'Cancel',
        confirmOk: 'Apply now',
        undoKept: 'Rollback record saved',
        // ---- cards --------------------------------------------------------
        exp_what: 'What it is',
        exp_where: 'Where you see it',
        exp_purpose: 'What it does',
        exp_ifOff: 'If you turn it off',
        exp_facts: 'Facts',
        exp_raw: 'Raw data',
        origin_ms: 'Microsoft',
        origin_third: 'Third-party',
        viewDetail: 'Show details',
        collapse: 'Collapse',
        noExplain: 'No plain-language explanation for this one yet — its raw state is shown instead.',
        copy: 'Copy',
        copied: 'Copied',
        // ---- system repair (repair.ps1) -----------------------------------
        repairTitle: 'System repair',
        repairHint: 'Eight configuration-drift checks (hosts / IE home page / DNS / connection limits / UAC / dead registry entries / font cache / icon cache).',
        repairScan: 'Check',
        repairDryRun: 'Dry-run the fixes',
        repairApply: 'Apply fixes',
        repairRunning: 'Checking…',
        repairSummary: '{total} checks: {ok} OK · {warn} notice · {bad} problem · {info} info · {skip} not checked',
        repairDryRunNote: 'Dry run: nothing below was actually written.',
        repairAppliedNote: 'Fixes applied as previewed.',
        repairFailed: 'System repair check failed',
        riskBlockedNote: 'Protected',
        // ---- installed-program facts + cross-plugin hint -------------------
        progLocation: 'Install location',
        progSize: 'Size on disk',
        progInstalled: 'Installed on',
        progVersion: 'Version',
        progPublisher: 'Publisher',
        progSystemComponent: 'System component',
        progSystemComponentHint: 'This entry is flagged as a system component; the probe refuses to uninstall it.',
        progSoftmgrHint: 'Upgrading and moving: see the 360 Toolbox software manager',
        readonlyBadge: 'View only',
      },
    };

    /** Prefix-aware path (never root-absolute), keeping the query string. */
    function api(path) {
      const relative = String(path).replace(/^\/+/, '');
      if (typeof document === 'undefined') return '/' + relative;
      try {
        const u = new URL(relative, document.baseURI);
        return u.pathname + u.search;
      } catch { return '/' + relative; }
    }

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

    /** Risk badge label key per risk class. */
    const RISK_KEY = {
      blocked: 'riskBlocked',
      destructive: 'riskDestructive',
      reversible: 'riskReversible',
      readonly: 'riskReadonly',
    };

    function riskColor(risk) {
      if (risk === 'blocked') return C.error;
      if (risk === 'destructive') return C.warn;
      if (risk === 'reversible') return C.brand;
      return C.label3;
    }

    /**
     * Is the panel painting English? The bound `t` is the only translation
     * entry point (ctx.locale.bind), so compare one known dictionary value
     * rather than guessing from the host.
     */
    function isEnglishUI(t) {
      try { return t('title') !== DICT.zh.title; } catch { return false; }
    }

    /**
     * Label for one source, taken from the /status summary — never a hardcoded
     * list, so a source the backend adds later shows up with its own name.
     */
    function sourceLabel(t, s) {
      if (!s) return '';
      if (isEnglishUI(t)) return String(s.labelEn || s.description || s.label || s.id || '');
      return String(s.label || s.labelEn || s.id || '');
    }

    // ------------------------------------------------------------- components

    function Badge({ text, color, title }) {
      return h('span', {
        title,
        style: {
          display: 'inline-block', fontSize: '10px', lineHeight: '16px',
          padding: '0 6px', borderRadius: '9px', color,
          background: 'transparent', border: `1px solid ${color}`,
          whiteSpace: 'nowrap', flex: 'none',
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

    /** The "is it on" dot: green on, grey off, half-transparent when unknown. */
    function StateDot({ enabled }) {
      const unknown = enabled !== true && enabled !== false;
      return h('span', {
        'aria-hidden': true,
        style: {
          width: '8px', height: '8px', borderRadius: '50%', flex: 'none',
          background: enabled === true ? C.success : C.label3,
          opacity: unknown ? 0.4 : 1,
        },
      });
    }

    /** One labelled block: small caption above, wrapping body below. */
    function field(label, value, tone) {
      if (!value) return null;
      return h('div', { style: { display: 'flex', flexDirection: 'column', gap: '2px' } },
        h('div', { style: { fontSize: '10px', color: C.label3, letterSpacing: '0.02em' } }, label),
        h('div', { style: { fontSize: '11.5px', lineHeight: '17px', color: tone ?? C.label2, wordBreak: 'break-word' } },
          String(value)),
      );
    }

    function Toolbar({ t, filters, setFilters, sources, onRefresh, busy }) {
      const inputStyle = {
        font: 'inherit', fontSize: '12px', padding: '5px 9px',
        borderRadius: C.radius, border: `1px solid ${C.border}`,
        background: C.bgBase, color: C.label, minWidth: 0,
      };
      return h('div', {
        style: { display: 'flex', flexWrap: 'wrap', gap: '8px', alignItems: 'center' },
      },
        h('input', {
          value: filters.q, placeholder: t('search'),
          onChange: (e) => setFilters({ ...filters, q: e.target.value }),
          ...focusable, style: { ...inputStyle, flex: '1 1 180px' },
        }),
        h('select', {
          value: filters.source,
          onChange: (e) => setFilters({ ...filters, source: e.target.value }),
          ...focusable, style: { ...inputStyle, flex: '0 0 150px' },
        },
          h('option', { value: '' }, t('allSources')),
          ...sources.map((s) => h('option', { key: s.id, value: s.id }, `${sourceLabel(t, s)} (${s.total})`)),
        ),
        h('select', {
          value: filters.enabled,
          onChange: (e) => setFilters({ ...filters, enabled: e.target.value }),
          ...focusable, style: { ...inputStyle, flex: '0 0 120px' },
        },
          h('option', { value: '' }, t('anyState')),
          h('option', { value: 'true' }, t('onlyOn')),
          h('option', { value: 'false' }, t('onlyOff')),
        ),
        h('label', {
          style: { display: 'flex', alignItems: 'center', gap: '5px', fontSize: '12px', color: C.label2, whiteSpace: 'nowrap' },
        },
          h('input', {
            type: 'checkbox', checked: filters.actionable,
            onChange: (e) => setFilters({ ...filters, actionable: e.target.checked }),
          }),
          t('onlyActionable'),
        ),
        h(Btn, { onClick: onRefresh, disabled: busy, tone: 'brand' }, busy ? t('refreshing') : t('refresh')),
      );
    }

    /**
     * Format a size in KB for display. Program entries record the
     * EstimatedSize registry value, which is KB; a missing or zero value means
     * "not recorded", not "0 bytes", so it renders as nothing at all.
     */
    function sizeText(kb) {
      const n = Number(kb);
      if (!Number.isFinite(n) || n <= 0) return '';
      if (n < 1024) return `${Math.round(n)} KB`;
      const mb = n / 1024;
      if (mb < 1024) return `${mb >= 100 ? Math.round(mb) : mb.toFixed(1)} MB`;
      const gb = mb / 1024;
      return `${gb >= 100 ? Math.round(gb) : gb.toFixed(2)} GB`;
    }

    /** `20180412` → `2018-04-12`; anything else is passed through untouched. */
    function dateText(raw) {
      const s = String(raw ?? '').trim();
      if (!/^\d{8}$/.test(s)) return s;
      return `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}`;
    }

    /**
     * The verbs a row actually offers, derived from the source's declared
     * `actions` — never from a hardcoded per-source list. A source that gains a
     * verb in lib/sources.js shows it here without touching this file.
     */
    function verbsFor(entry, actions) {
      const list = Array.isArray(actions) ? actions : [];
      const canToggle = list.includes('enable') || list.includes('disable');
      const canUninstall = list.includes('uninstall');
      // The one verb a dry run should plan by default: a row that can be removed
      // is planned as a removal; a toggleable row is planned as its own opposite.
      const primary = canUninstall ? 'uninstall' : (entry.enabled ? 'disable' : 'enable');
      return { canToggle, canUninstall, primary, empty: list.length === 0 };
    }

    /**
     * The expanded half of a card: the explanation in full, the two-column fact
     * table, the collapsible raw record and the switches with their dry-run
     * confirmation loop.
     *
     * `actions` is the source's declared verb list (meta.actions). Buttons are
     * derived from it, so the panel cannot drift from lib/sources.js.
     */
    function CardDetail({ t, entry, ex, actions, busy, elevating, result, plan, onDryRun, onApply, onCancelPlan, onElevate }) {
      const [copied, setCopied] = useState('');
      const clipboard = (typeof navigator !== 'undefined'
        && navigator.clipboard
        && typeof navigator.clipboard.writeText === 'function') ? navigator.clipboard : null;

      const copy = (key, value) => {
        if (!clipboard) return;
        const text = String(value ?? '');
        if (!text) return;
        try {
          Promise.resolve(clipboard.writeText(text))
            .then(() => setCopied(key))
            .catch(() => { /* clipboard refused — the text is still selectable */ });
        } catch { /* noop */ }
      };

      const facts = Array.isArray(ex?.facts) ? ex.facts.filter((f) => Array.isArray(f) && f[1]) : [];
      const raw = entry.detail === undefined || entry.detail === null
        ? '—'
        : JSON.stringify(entry.detail, null, 2);

      const verbs = verbsFor(entry, actions);
      const detail = entry.detail ?? {};

      const copyStyle = {
        appearance: 'none', font: 'inherit', cursor: 'pointer', marginLeft: '6px',
        fontSize: '10px', lineHeight: '14px', padding: '0 5px',
        borderRadius: '7px', border: `1px solid ${C.border}`,
        background: 'transparent', color: C.label3, whiteSpace: 'nowrap',
      };

      // ---- program-only read-only facts ----------------------------------
      // These come straight from the uninstall registry key (program.ps1). They
      // are read-only by design; the only button derived from them is "Modify",
      // and only when the key actually records a ModifyPath.
      const progRows = entry.source === 'program'
        ? [
            [t('progLocation'), String(detail.installLocation ?? '')],
            [t('progSize'), sizeText(detail.sizeKb)],
            [t('progInstalled'), dateText(detail.installDate)],
            [t('progVersion'), String(detail.version ?? entry.version ?? '')],
            [t('progPublisher'), String(detail.publisher ?? entry.publisher ?? '')],
          ].filter(([, v]) => v)
        : [];
      const systemComponent = entry.source === 'program'
        && (detail.systemComponent === true || detail.systemComponent === 1 || detail.systemComponent === '1');
      const modifyCmd = entry.source === 'program' ? String(detail.modify ?? '') : '';

      let actionsRow;
      if (verbs.empty) {
        actionsRow = h('div', { style: { fontSize: '11px', color: C.label3 } }, t('readonlyNote'));
      } else if (entry.risk === 'blocked') {
        actionsRow = h('div', { style: { fontSize: '11px', color: C.error } }, t('blockedNote'));
      } else {
        const buttons = [
          // Dry run first — it is the only button that cannot change anything.
          h(Btn, {
            key: 'dry',
            onClick: () => onDryRun(entry, verbs.primary),
            disabled: busy,
          }, busy ? t('actionWorking') : t('actionDryRun')),
        ];

        if (verbs.canUninstall) {
          buttons.push(h(Btn, {
            key: 'uninstall',
            onClick: () => onApply(entry, 'uninstall'),
            disabled: busy,
            tone: 'danger',
          }, t('actionUninstall')));
        }
        if (verbs.canToggle) {
          buttons.push(entry.enabled
            ? h(Btn, { key: 'toggle', onClick: () => onApply(entry, 'disable'), disabled: busy, tone: 'danger' }, t('actionDisable'))
            : h(Btn, { key: 'toggle', onClick: () => onApply(entry, 'enable'), disabled: busy, tone: 'brand' }, t('actionEnable')));
        }
        // A ModifyPath is an executable path recorded by the installer, not a
        // decision the panel makes: no ModifyPath, no button.
        if (modifyCmd) {
          buttons.push(h(Btn, {
            key: 'modify',
            onClick: () => onApply(entry, 'modify'),
            disabled: busy,
          }, t('actionModify')));
        }
        if (result?.undo) {
          buttons.push(h(Btn, {
            key: 'rollback',
            onClick: () => onApply(entry, 'rollback', result.undo),
            disabled: busy,
            tone: 'danger',
          }, t('actionRollback')));
        }
        // A dry run has already shown the plan: this is the confirm step.
        if (plan) {
          buttons.push(h(Btn, {
            key: 'confirm',
            onClick: () => onApply(entry, plan.action),
            disabled: busy,
            tone: plan.action === 'disable' || plan.action === 'uninstall' ? 'danger' : 'brand',
          }, t('confirmOk')));
          buttons.push(h(Btn, { key: 'cancel', onClick: onCancelPlan, disabled: busy }, t('confirmCancel')));
        }
        actionsRow = h('div', { style: { display: 'flex', gap: '6px', flexWrap: 'wrap', alignItems: 'center' } }, ...buttons);
      }

      return h('div', {
        style: {
          display: 'flex', flexDirection: 'column', gap: '8px',
          padding: '9px', borderTop: `1px solid ${C.border}`, background: C.bgLayer1,
        },
      },
        field(t('exp_purpose'), ex?.purpose),
        field(t('exp_ifOff'), ex?.ifOff, entry.risk === 'blocked' ? C.error : C.label2),

        progRows.length || systemComponent
          ? h('div', { style: { display: 'flex', flexDirection: 'column', gap: '4px' } },
              h('div', { style: { display: 'flex', gap: '6px', alignItems: 'center', fontSize: '10px', color: C.label3, letterSpacing: '0.02em' } },
                h('span', null, t('exp_facts')),
                systemComponent
                  ? h('span', { title: t('progSystemComponentHint') }, h(Badge, { text: t('progSystemComponent'), color: C.warn }))
                  : null,
              ),
              h('div', {
                style: {
                  display: 'grid', gridTemplateColumns: 'minmax(76px,34%) minmax(0,1fr)',
                  gap: '4px 8px', fontSize: '11px', alignItems: 'baseline',
                },
              },
                ...progRows.flatMap(([k, v], i) => [
                  h('div', { key: `pk:${i}`, style: { color: C.label3 } }, k),
                  h('div', { key: `pv:${i}`, title: v, style: { minWidth: 0, color: C.label2, wordBreak: 'break-word', userSelect: 'text' } }, v),
                ]),
              ),
            )
          : null,

        entry.source === 'program'
          ? h('div', { style: { fontSize: '10px', color: C.label3 } }, t('progSoftmgrHint'))
          : null,

        facts.length
          ? h('div', { style: { display: 'flex', flexDirection: 'column', gap: '4px' } },
              h('div', { style: { fontSize: '10px', color: C.label3, letterSpacing: '0.02em' } }, t('exp_facts')),
              h('div', {
                style: {
                  display: 'grid', gridTemplateColumns: 'minmax(76px,34%) minmax(0,1fr)',
                  gap: '4px 8px', fontSize: '11px', alignItems: 'baseline',
                },
              },
                ...facts.flatMap(([k, v], i) => [
                  h('div', { key: `fk:${i}`, style: { color: C.label3, wordBreak: 'break-word' } }, String(k)),
                  h('div', {
                    key: `fv:${i}`, title: String(v),
                    style: { minWidth: 0, color: C.label2, wordBreak: 'break-word', userSelect: 'text' },
                  },
                    String(v),
                    clipboard
                      ? h('button', {
                          type: 'button', onClick: () => copy(`f:${i}`, v),
                          ...focusable, style: copyStyle,
                        }, copied === `f:${i}` ? t('copied') : t('copy'))
                      : null,
                  ),
                ]),
              ),
            )
          : null,

        actionsRow,

        result
          ? h('div', {
              style: {
                fontSize: '11px', lineHeight: '17px', padding: '7px 9px', borderRadius: C.radius,
                border: `1px solid ${result.ok ? (result.dryRun ? C.border : C.success) : C.error}`,
                background: C.bgBase, color: result.ok ? C.label2 : C.error,
                whiteSpace: 'pre-wrap', wordBreak: 'break-word',
              },
            },
              h('div', { style: { fontWeight: 600, color: result.ok ? (result.dryRun ? C.label2 : C.success) : C.error } },
                result.ok ? (result.dryRun ? t('dryRunBadge') : t('workedBadge')) : (result.message || 'error')),
              result.message && result.ok ? h('div', { style: { marginTop: '2px' } }, result.message) : null,
              // The probe answered "this needs admin" — that is an invitation to
              // elevate, not an error. The retry replays the exact same request
              // through the UAC channel.
              result.needsAdmin
                ? h('div', { style: { marginTop: '4px', display: 'flex', gap: '6px', alignItems: 'center', flexWrap: 'wrap' } },
                    h('span', { style: { color: C.warn } }, t('needsAdmin')),
                    h(Btn, {
                      onClick: () => onElevate(entry, plan?.action ?? verbs.primary, result.undo),
                      disabled: busy || elevating,
                      tone: 'brand',
                      compact: true,
                    }, elevating ? t('elevateRetrying') : t('elevateRetryAdmin')),
                  )
                : null,
              result.undo ? h('div', { style: { marginTop: '2px', color: C.label3 } }, t('undoKept')) : null,
            )
          : null,

        h('details', { style: { fontSize: '11px', color: C.label3 } },
          h('summary', { style: { cursor: 'pointer', color: C.label3 } }, t('exp_raw')),
          h('pre', {
            style: {
              margin: '6px 0 0', padding: '8px', borderRadius: C.radius,
              border: `1px solid ${C.border}`, background: C.bgBase, color: C.label2,
              fontSize: '10px', lineHeight: '15px', maxHeight: '240px', overflow: 'auto',
              whiteSpace: 'pre-wrap', wordBreak: 'break-word',
            },
          }, raw),
        ),
      );
    }

    /**
     * One entry as a card. The face answers "what is this" AND offers its main
     * action without a click — the whole point of a manager is that the switch
     * is on the front, not one level down.
     *
     * Structure note (was: whole card was role="button" with buttons nested
     * inside — invalid ARIA and unreachable by keyboard): now the expanding part
     * is its own role="button" node, and the action row is a SIBLING of it. That
     * keeps one focusable target for "expand" and real <button>s for the actions,
     * with no nesting and no click bubbling to fight.
     *
     * `actions` is the source's declared verb list; the face renders whatever it
     * allows, so adding a verb in lib/sources.js needs no change here.
     */
    function EntryCard({ t, entry, open, onToggle, actions, busy, elevating, result, plan, onDryRun, onApply, onCancelPlan, onElevate }) {
      const ex = entry.explain ?? null;
      const what = ex?.what ?? entry.state ?? '';
      const where = ex?.where ?? '';
      const riskKey = RISK_KEY[entry.risk] ?? null;
      const verbs = verbsFor(entry, actions);

      // The face action row: exactly one primary verb, so the front stays
      // readable. Everything else lives in the expanded detail.
      //
      // Every face click also opens the card: the dry run's plan, its result box
      // and the confirm button all live in CardDetail, and a button that changes
      // state while hiding its own output would be a worse lie than no button.
      const faceRun = (action) => (e) => {
        if (e && e.stopPropagation) e.stopPropagation();
        onDryRun(entry, action);
        if (!open) onToggle();
      };
      const faceKey = (e) => { if (e.key === 'Enter' || e.key === ' ') e.stopPropagation(); };

      const faceAction = (() => {
        if (entry.risk === 'blocked') {
          return h(Badge, { text: t('riskBlockedNote'), color: C.error, title: t('blockedNote') });
        }
        if (verbs.empty) {
          return h(Badge, { text: t('readonlyBadge'), color: C.label3, title: t('readonlyNote') });
        }
        if (verbs.canUninstall) {
          return h(Btn, {
            onClick: faceRun('uninstall'),
            onKeyDown: faceKey,
            disabled: busy,
            tone: 'danger',
            compact: true,
            title: t('uninstallNote'),
          }, busy ? t('actionWorking') : t('actionUninstall'));
        }
        if (verbs.canToggle) {
          return entry.enabled
            ? h(Btn, { onClick: faceRun('disable'), onKeyDown: faceKey, disabled: busy, tone: 'danger', compact: true },
                busy ? t('actionWorking') : t('actionDisable'))
            : h(Btn, { onClick: faceRun('enable'), onKeyDown: faceKey, disabled: busy, tone: 'brand', compact: true },
                busy ? t('actionWorking') : t('actionEnable'));
        }
        return null;
      })();

      return h('div', {
        style: {
          display: 'flex', flexDirection: 'column', minWidth: 0,
          border: `1px solid ${open ? C.brand : C.border}`,
          borderRadius: C.radiusMd,
          background: open ? C.bgLayer1 : C.bgBase,
          overflow: 'hidden',
        },
      },
        // ---- expanding face: the only role="button" in the card ----
        h('div', {
          role: 'button',
          tabIndex: 0,
          'aria-expanded': open ? 'true' : 'false',
          onClick: onToggle,
          onKeyDown: (e) => {
            if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onToggle(); }
          },
          ...focusable,
          title: entry.name,
          style: { display: 'flex', flexDirection: 'column', gap: '4px', padding: '8px 9px 4px', cursor: 'pointer', minWidth: 0 },
        },
          h('div', { style: { display: 'flex', alignItems: 'center', gap: '6px', minWidth: 0 } },
            h(StateDot, { enabled: entry.enabled }),
            h('div', {
              style: {
                flex: 1, minWidth: 0, fontSize: '12.5px', fontWeight: 600, color: C.label,
                overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
              },
            }, entry.name),
            ex?.origin === 'microsoft'
              ? h(Badge, { key: 'o', text: t('origin_ms'), color: C.label2, title: ex.originName || '' })
              : ex?.origin === 'thirdparty'
                ? h(Badge, { key: 'o', text: t('origin_third'), color: C.warn, title: ex.originName || '' })
                : null,
            riskKey ? h(Badge, { key: 'r', text: t(riskKey), color: riskColor(entry.risk) }) : null,
          ),

          // The one sentence the user actually asked for.
          what
            ? h('div', { style: { fontSize: '11.5px', lineHeight: '16px', color: C.label2, wordBreak: 'break-word' } }, what)
            : null,
          where
            ? h('div', { style: { fontSize: '11px', lineHeight: '15px', color: C.label3, wordBreak: 'break-word' } }, where)
            : null,
          !ex
            ? h('div', { style: { fontSize: '11px', lineHeight: '15px', color: C.label3 } },
                `${t('noExplain')}${entry.state ? ` (${entry.state})` : ''}`)
            : null,

          h('div', { style: { fontSize: '10px', color: open ? C.brand : C.label3, marginTop: '1px' } },
            open ? '\u25be ' + t('collapse') : '\u25b8 ' + t('viewDetail')),
        ),

        // ---- action row: a sibling of the role="button" node ----
        h('div', {
          style: {
            display: 'flex', alignItems: 'center', gap: '6px', flexWrap: 'wrap',
            padding: '0 9px 7px', minHeight: '20px',
          },
        },
          faceAction,
          // A destructive verb gets its consequence spelled out on the face, not
          // only after the dry run: the user is deciding here.
          entry.risk === 'destructive' && !verbs.empty
            ? h('span', { style: { fontSize: '9.5px', lineHeight: '13px', color: C.label3, flex: '1 1 100%' } },
                t('uninstallNote'))
            : null,
        ),

        open ? h(CardDetail, {
          t, entry, ex, actions, busy, elevating, result, plan, onDryRun, onApply, onCancelPlan, onElevate,
        }) : null,
      );
    }

    /**
     * One source's section: its label and counts, then a responsive card grid.
     * minmax(260px, 1fr) + auto-fill means a narrow panel drops to one column by
     * itself, with no fixed pixel widths to break.
     */
    function SourceGroup({ t, group, openId, onToggle, cardProps }) {
      const s = group.source;
      const failed = Boolean(s.error);
      return h('section', { style: { display: 'flex', flexDirection: 'column', gap: '7px' } },
        h('div', {
          style: {
            display: 'flex', alignItems: 'baseline', gap: '8px', flexWrap: 'wrap',
            borderBottom: `1px solid ${C.border}`, paddingBottom: '4px',
          },
        },
          h('div', { style: { fontSize: '12.5px', fontWeight: 600, color: C.label } }, sourceLabel(t, s)),
          h('div', { style: { fontSize: '11px', color: C.label3 } },
            `${s.total ?? group.rows.length} ${t('totalEntries')}`),
          typeof s.enabled === 'number'
            ? h('div', { style: { fontSize: '11px', color: C.success } }, String(s.enabled))
            : null,
          typeof s.disabled === 'number' && s.disabled > 0
            ? h('div', { style: { fontSize: '11px', color: C.label3 } }, String(s.disabled))
            : null,
          s.ms !== null && s.ms !== undefined
            ? h('div', { style: { fontSize: '10px', color: C.label3 } }, `${s.ms} ${t('ms')}`)
            : null,
          s.stale ? h('div', { style: { fontSize: '10px', color: C.label3 } }, t('staleHint')) : null,
          failed
            ? h('div', { style: { fontSize: '10px', color: C.error }, title: String(s.error) }, t('sourceError'))
            : null,
          s.description
            ? h('div', { style: { flexBasis: '100%', fontSize: '10.5px', color: C.label3, lineHeight: '15px' } },
                String(s.description))
            : null,
        ),
        h('div', {
          style: {
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 1fr))',
            gap: '10px',
          },
        },
          ...group.rows.map((entry) => h(EntryCard, {
            key: entry.id,
            t,
            entry,
            open: openId === entry.id,
            onToggle: () => onToggle(entry.id),
            ...cardProps(entry),
          })),
        ),
      );
    }

    /** Fill `{name}` placeholders in a dictionary string. */
    function fill(text, vars) {
      return String(text).replace(/\{(\w+)\}/g, (m, k) => (vars[k] === undefined ? m : String(vars[k])));
    }

    function statusColor(status) {
      if (status === 'ok') return C.success;
      if (status === 'warn') return C.warn;
      if (status === 'bad') return C.error;
      return C.label3;
    }

    /**
     * The system-repair strip: eight configuration-drift checks that are not
     * registration points, so they never appear as switchable cards.
     *
     * It deliberately does NOT fetch on mount. The panel's own load() already
     * costs a full probe sweep, and a second automatic run on every mount would
     * double that; the checks run when the user asks for them.
     */
    function RepairStrip({ t }) {
      const [busy, setBusy] = useState('');
      const [out, setOut] = useState(null);
      const [error, setError] = useState('');

      const run = useCallback(async (action, dryRun) => {
        setBusy(dryRun && action === 'fix' ? 'dry' : action); setError('');
        try {
          const res = await postJSON(`${API}/repair`, { action, dryRun });
          setOut(res);
        } catch (e) {
          setError(String(e?.message ?? e));
        } finally {
          setBusy('');
        }
      }, []);

      const rows = Array.isArray(out?.items) ? out.items : [];
      const sum = out?.summary ?? null;

      return h('section', {
        style: {
          display: 'flex', flexDirection: 'column', gap: '6px',
          padding: '9px', borderRadius: C.radius, background: C.bgLayer1,
          border: `1px solid ${C.border}`,
        },
      },
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' } },
          h('div', { style: { fontSize: '12.5px', fontWeight: 600 } }, t('repairTitle')),
          h('div', { style: { flex: '1 1 240px', fontSize: '10.5px', color: C.label3, lineHeight: '15px' } },
            t('repairHint')),
          h(Btn, { onClick: () => run('scan', true), disabled: Boolean(busy), tone: 'brand' },
            busy === 'scan' ? t('repairRunning') : t('repairScan')),
          h(Btn, { onClick: () => run('fix', true), disabled: Boolean(busy) },
            busy === 'dry' ? t('repairRunning') : t('repairDryRun')),
          // Applying is offered only after a dry run has shown the plan: the same
          // two-step confirmation the row actions use.
          out && out.dryRun !== false && out.action === 'fix'
            ? h(Btn, { onClick: () => run('fix', false), disabled: Boolean(busy), tone: 'danger' },
                busy === 'fix' ? t('repairRunning') : t('repairApply'))
            : null,
        ),

        error ? h('div', { style: { fontSize: '11px', color: C.error } }, `${t('repairFailed')}: ${error}`) : null,

        sum
          ? h('div', { style: { fontSize: '11px', color: C.label2 } },
              fill(t('repairSummary'), sum))
          : null,

        out ? h('div', {
          style: { fontSize: '10.5px', color: out.dryRun === false ? C.success : C.label3 },
        }, out.dryRun === false ? t('repairAppliedNote') : t('repairDryRunNote')) : null,

        rows.length
          ? h('div', { style: { display: 'flex', flexDirection: 'column', gap: '3px' } },
              ...rows.map((r) => h('div', {
                key: r.id,
                style: {
                  display: 'grid', gridTemplateColumns: 'minmax(96px,26%) minmax(0,1fr)',
                  gap: '6px', fontSize: '11px', lineHeight: '16px',
                },
              },
                h('div', { style: { color: C.label2 } }, `${r.label ?? r.id}`),
                h('div', { style: { color: statusColor(r.status) } },
                  `${r.status}${r.value ? ` · ${r.value}` : ''}`),
              )))
          : null,
      );
    }

    // getLang defaults so a host (or the offline render harness) that hands the
    // panel only `t` still loads, just in the default language.
    function Panel({ t, getLang = () => 'zh' }) {
      const [status, setStatus] = useState(null);
      const [rows, setRows] = useState([]);
      const [filters, setFilters] = useState({ q: '', source: '', enabled: '', actionable: false });
      const [busy, setBusy] = useState(false);
      const [error, setError] = useState('');
      const [openId, setOpenId] = useState('');
      const [result, setResult] = useState(null);
      const [plan, setPlan] = useState(null);
      const [busyId, setBusyId] = useState('');
      // Elevation is a separate channel from a plain action, with its own busy
      // flag and its own status line: a UAC prompt can sit on screen for a while
      // and must not look like the panel froze.
      const [elevating, setElevating] = useState(false);
      const [elevateMsg, setElevateMsg] = useState(null);

      const sources = status?.sources ?? [];

      /** id -> /status summary row, so actions come from the backend, not a list here. */
      const sourceMeta = useMemo(() => {
        const m = new Map();
        for (const s of sources) { if (s?.id) m.set(s.id, s); }
        return m;
      }, [sources]);

      const load = useCallback(async (opts = {}) => {
        setBusy(true); setError('');
        try {
          const st = opts.refresh
            ? await postJSON(`${API}/refresh`, {})
            : await getJSON(`${API}/status`);
          setStatus(st);
          const qs = new URLSearchParams();
          if (filters.source) qs.set('source', filters.source);
          if (filters.enabled) qs.set('enabled', filters.enabled);
          if (filters.q) qs.set('q', filters.q);
          if (filters.actionable) qs.set('risk', 'reversible');
          qs.set('limit', '2000');
          // The explanation is generated on the server, so the language has to
          // travel with the request; otherwise an English UI shows Chinese text.
          qs.set('lang', getLang());
          const list = await getJSON(`${API}/entries?${qs.toString()}`);
          setRows(list.rows ?? []);
        } catch (e) {
          setError(String(e?.message ?? e));
        } finally {
          setBusy(false);
        }
      }, [filters, getLang]);

      useEffect(() => { load({ refresh: false }); }, [load]);

      const runAction = useCallback(async (entry, action, extra = {}) => {
        setBusyId(entry.id); setResult(null);
        if (extra.dryRun !== true) setPlan(null);
        try {
          const out = await postJSON(`${API}/action`, {
            source: entry.source,
            action,
            target: entry.detail,
            dryRun: extra.dryRun === true,
            undo: extra.undo ?? null,
          });
          setResult({ id: entry.id, out });
          // A successful dry run becomes the thing the confirm button applies.
          if (extra.dryRun === true && out?.ok) setPlan({ id: entry.id, action });
          if (out?.ok && out?.changed && !out?.dryRun) {
            setPlan(null);
            await load({ refresh: false });
          }
        } catch (e) {
          setResult({ id: entry.id, out: { ok: false, message: String(e?.message ?? e) } });
        } finally {
          setBusyId('');
        }
      }, [load]);

      /**
       * Ask Windows for administrator rights, through the real UAC channel.
       *
       * `probe:true` runs no action at all: it only reports which token the
       * elevated process got. The result is deliberately NOT optimistic — the
       * banner flips only on `elevated === true`, and a cancelled prompt is
       * reported as "you cancelled, nothing changed", never as success.
       */
      const requestElevation = useCallback(async () => {
        setElevating(true); setElevateMsg(null);
        try {
          const out = await postJSON(`${API}/elevated`, { probe: true });
          if (out?.elevated === true) {
            setElevateMsg({ ok: true, text: fill(t('elevateOkDetail'), { user: String(out.user ?? '') }) });
            // Re-read /status so host.elevated reflects what actually happened
            // (the host process itself did not change; the channel did).
            await load({ refresh: false });
          } else if (out?.cancelled === true) {
            setElevateMsg({ ok: false, text: t('elevateCancelled') });
          } else if (out?.timeout === true) {
            setElevateMsg({ ok: false, text: t('elevateTimeout') });
          } else {
            setElevateMsg({ ok: false, text: fill(t('elevateFailed'), { message: String(out?.message ?? out?.error ?? '') }) });
          }
        } catch (e) {
          setElevateMsg({ ok: false, text: fill(t('elevateFailed'), { message: String(e?.message ?? e) }) });
        } finally {
          setElevating(false);
        }
      }, [load, t]);

      /**
       * Replay one action through the elevated channel — the "retry as
       * administrator" button. Same source/action/target/undo, different path.
       */
      const runElevated = useCallback(async (entry, action, undo) => {
        setBusyId(entry.id); setElevating(true); setResult(null); setPlan(null);
        try {
          const out = await postJSON(`${API}/elevated`, {
            source: entry.source,
            action,
            target: entry.detail,
            undo: undo ?? null,
            dryRun: false,
          });
          setResult({ id: entry.id, out });
          if (out?.ok && out?.changed) await load({ refresh: false });
        } catch (e) {
          setResult({ id: entry.id, out: { ok: false, cancelled: false, message: String(e?.message ?? e) } });
        } finally {
          setBusyId(''); setElevating(false);
        }
      }, [load]);

      const toggleOpen = useCallback((id) => {
        setOpenId((prev) => (prev === id ? '' : id));
      }, []);

      /**
       * Group rows by source, driven by the /status order. A source that shows
       * up in /entries but not in /status still gets a group (it follows the
       * backend instead of dropping rows), and groups with nothing to show are
       * omitted so a filtered view does not render seven empty grids.
       */
      const groups = useMemo(() => {
        const byId = new Map();
        for (const s of sources) {
          if (s?.id) byId.set(s.id, { source: s, rows: [] });
        }
        for (const r of rows) {
          const g = byId.get(r.source);
          if (g) { g.rows.push(r); continue; }
          byId.set(r.source, { source: { id: r.source, label: r.source, actions: [] }, rows: [r] });
        }
        return [...byId.values()].filter((g) => g.rows.length > 0);
      }, [sources, rows]);

      /**
       * Per-card props. `actions` is the source's declared verb list from the
       * backend summary — the card derives its buttons from it, so the panel can
       * never offer a verb the probe does not implement, nor hide one it does.
       */
      const cardProps = useCallback((entry) => {
        const meta = sourceMeta.get(entry.source);
        const actions = Array.isArray(meta?.actions) ? meta.actions : [];
        return {
          actions,
          busy: busyId === entry.id,
          elevating,
          result: result?.id === entry.id ? result.out : null,
          plan: plan?.id === entry.id ? plan : null,
          onDryRun: (e, action) => runAction(e, action ?? (actions.includes('uninstall') ? 'uninstall' : (e.enabled ? 'disable' : 'enable')), { dryRun: true }),
          onApply: (e, action, undo) => runAction(e, action, { dryRun: false, undo }),
          onCancelPlan: () => setPlan(null),
          onElevate: (e, action, undo) => runElevated(e, action, undo),
        };
      }, [sourceMeta, busyId, elevating, result, plan, runAction, runElevated]);

      const hostChip = useMemo(() => {
        const elevated = status?.host?.elevated;
        if (elevated === true) return h('span', { title: t('hostElevatedHint'), style: { display: 'inline-flex' } },
          h(Badge, { text: t('hostElevated'), color: C.success }));
        if (elevated === false) {
          return h('span', { title: t('hostNormalHint'), style: { display: 'inline-flex', gap: '4px', alignItems: 'center' } },
            h(Badge, { text: t('hostNormal'), color: C.warn }));
        }
        return null;
      }, [status, t]);

      /**
       * The elevation bar.
       *
       * Shown whenever /status says the host is NOT elevated — because that is
       * the state in which service/task/firewall changes and machine-wide
       * uninstalls will answer needsAdmin. It carries the real button: the only
       * code path in this plugin that raises a UAC prompt.
       *
       * When the host IS elevated the bar disappears entirely rather than
       * showing a disabled button, so "can I act?" is answered by its absence.
       */
      const elevateBar = status?.host?.elevated === false
        ? h('div', {
            style: {
              display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap',
              padding: '7px 9px', borderRadius: C.radius,
              border: `1px solid ${C.warn}`, background: C.bgLayer1,
            },
          },
            h('span', { style: { fontSize: '11.5px', lineHeight: '16px', color: C.label2, minWidth: 0, flex: '1 1 220px' } },
              t('elevateBanner')),
            h(Btn, {
              onClick: requestElevation,
              disabled: elevating,
              tone: 'brand',
              compact: true,
              title: t('hostNormalHint'),
            }, elevating ? t('elevateAsking') : t('elevateAsk')),
            elevateMsg
              ? h('span', {
                  style: {
                    flexBasis: '100%', fontSize: '10.5px', lineHeight: '15px',
                    color: elevateMsg.ok ? C.success : C.warn,
                  },
                }, elevateMsg.text)
              : null,
          )
        : null;

      return h('div', {
        style: {
          display: 'flex', flexDirection: 'column', gap: '10px',
          height: '100%', minHeight: 0, padding: '12px', background: C.bgBase, color: C.label,
        },
      },
        // header
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '4px' } },
          h('div', { style: { display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' } },
            h('div', { style: { fontSize: '15px', fontWeight: 600 } }, t('title')),
            hostChip,
            status ? h('span', { style: { fontSize: '11px', color: C.label3 } },
              `${status.total ?? 0} ${t('totalEntries')}${status.elapsedMs ? ` · ${status.elapsedMs} ${t('ms')}` : ''}`) : null,
          ),
          h('div', { style: { fontSize: '11px', color: C.label2, lineHeight: '17px' } }, t('subtitle')),
          h('div', { style: { fontSize: '11px', color: C.label3, lineHeight: '17px' } }, t('scopeNote')),
        ),

        elevateBar,

        h(Toolbar, { t, filters, setFilters, sources, onRefresh: () => load({ refresh: true }), busy }),

        h(RepairStrip, { t }),

        error ? h('div', { style: { fontSize: '12px', color: C.error } }, `${t('loadFailed')}: ${error}`) : null,
        !status && busy ? h('div', { style: { fontSize: '12px', color: C.label3 } }, t('loading')) : null,

        // body: every source's card grid in one scrollable column
        h('div', {
          style: {
            flex: 1, minHeight: 0, overflowY: 'auto',
            display: 'flex', flexDirection: 'column', gap: '14px', paddingRight: '2px',
          },
        },
          rows.length === 0
            ? h('div', { style: { padding: '16px', fontSize: '12px', color: C.label3 } },
                busy ? t('loading') : (status ? t('noMatch') : t('empty')))
            : groups.map((g) => h(SourceGroup, {
                key: g.source.id,
                t,
                group: g,
                openId,
                onToggle: toggleOpen,
                cardProps,
              })),
        ),
      );
    }

    /** Sidebar glyph: a window with one dashed empty slot (matches icon.svg). */
    function ManagerIcon({ size = 16 }) {
      return h('svg', {
        width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
        stroke: 'currentColor', strokeWidth: 1.7, strokeLinecap: 'round', strokeLinejoin: 'round',
        'aria-hidden': true,
      },
        h('rect', { x: 2.5, y: 4, width: 19, height: 16, rx: 2.2 }),
        h('path', { d: 'M2.5 8.2h19' }),
        h('path', { d: 'M7 12.4h3.2M7 16h5.4' }),
        h('path', { d: 'M15.4 12.6v4.6M13.1 14.9h4.6', strokeDasharray: '2.2 1.9' }),
      );
    }

      return { Panel, Icon: ManagerIcon, DICT };
    }
    const MANAGE = makeManageModule(require);


    // ---- toolbox half (tools/legacy/toolbox-client.js, verbatim body) ----
    function makeToolboxModule(require) {
    const React = require('react');
    const h = React.createElement;
    const { useState, useEffect, useCallback, useMemo, useRef } = React;

    const API = '/dsh-windows-toolbox/api/toolbox';

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

      return { Panel, Icon: ToolboxIcon, DICT };
    }
    const TOOLBOX = makeToolboxModule(require);

    // ---- merged shell ----
    /** Sidebar glyph: a window grid (manage) overlapping a toolbox (toolbox). */
    function ToolboxMergedIcon({ size = 16 }) {
      return h('svg', {
        width: size, height: size, viewBox: '0 0 24 24', fill: 'none',
        stroke: 'currentColor', strokeWidth: 1.7, strokeLinecap: 'round', strokeLinejoin: 'round',
        'aria-hidden': true,
      },
        h('rect', { x: 2.2, y: 3.4, width: 12.2, height: 10.4, rx: 1.8 }),
        h('path', { d: 'M2.2 6.6h12.2' }),
        h('path', { d: 'M5 9.4h3.4M5 11.6h5' }),
        h('path', { d: 'M8.6 14.6h4.2', opacity: 0.55 }),
        h('rect', { x: 8.4, y: 15.2, width: 13.4, height: 6, rx: 1.6 }),
        h('path', { d: 'M13.2 15.2v-1.1a1 1 0 0 1 1-1h1.8a1 1 0 0 1 1 1v1.1' }),
        h('rect', { x: 13.9, y: 17.3, width: 2.4, height: 1.7, rx: 0.5 }),
      );
    }

    /** Tab button: same visual vocabulary as each half's Btn, no shared import. */
    function TabButton({ active, label, hint, onClick }) {
      return h('button', {
        type: 'button',
        title: hint,
        'aria-selected': active ? 'true' : 'false',
        role: 'tab',
        onClick,
        style: {
          cursor: 'pointer',
          fontSize: 13,
          padding: '6px 14px',
          borderRadius: 7,
          border: '1px solid ' + (active ? 'var(--dsw-alias-border-accent, #3B82F6)' : 'var(--dsw-alias-border-subtle, #d8dce3)'),
          background: active ? 'var(--dsw-alias-bg-accent-weak, rgba(59,130,246,0.12))' : 'transparent',
          color: active ? 'var(--dsw-alias-text-primary, inherit)' : 'var(--dsw-alias-text-secondary, inherit)',
          fontWeight: active ? 600 : 400,
        },
      }, label);
    }

    /**
     * The merged panel. Both children are mounted fresh on every switch rather
     * than kept alive: each Panel re-fetches its own /status on mount, and the
     * halves have ~15 s of PowerShell behind them, so keeping a hidden one alive
     * would only mean a stale view with no way to see it.
     */
    function Shell({ t, tManage, tToolbox, getLang, Manage, Toolbox }) {
      const [tab, setTab] = useState('manage');
      const tabs = [
        { id: 'manage', label: t('tabManage'), hint: t('tabManageHint') },
        { id: 'toolbox', label: t('tabToolbox'), hint: t('tabToolboxHint') },
      ];
      return h('div', {
        style: { display: 'flex', flexDirection: 'column', gap: 10, height: '100%', minHeight: 0 },
      },
        h('div', {
          role: 'tablist',
          'aria-label': t('title'),
          style: {
            display: 'flex', gap: 8, alignItems: 'center',
            paddingBottom: 8,
            borderBottom: '1px solid var(--dsw-alias-border-subtle, #e5e7eb)',
          },
        },
          ...tabs.map((item) => h(TabButton, {
            key: item.id,
            active: tab === item.id,
            label: item.label,
            hint: item.hint,
            onClick: () => setTab(item.id),
          })),
        ),
        h('div', { style: { flex: '1 1 auto', minHeight: 0, overflow: 'hidden' } },
          tab === 'manage'
            ? h(Manage.Panel, { t: tManage, getLang })
            : h(Toolbox.Panel, { t: tToolbox }),
        ),
      );
    }

    // ---- module registration ----
    return {
      inject: ['slots', 'locale', 'theme'],
      apply(ctx) {
        let t = (k) => k;
        let tManage = (k) => k;
        let tToolbox = (k) => k;
        let layout;
        const canLocate = ctx.locale
          && typeof ctx.locale.register === 'function'
          && typeof ctx.locale.bind === 'function';
        if (canLocate) {
          // Three namespaces, registered together and disposed together. The
          // halves must NOT share one: both dictionaries define nav/title/
          // refresh/loading, so the second registration would shadow the first
          // and one panel would start showing the other's wording.
          ctx.effect(() => {
            const offs = [
              ctx.locale.register(NS, SHELL_DICT),
              ctx.locale.register(NS_MANAGE, MANAGE.DICT),
              ctx.locale.register(NS_TOOLBOX, TOOLBOX.DICT),
            ];
            return () => {
              for (const off of offs) { if (typeof off === 'function') { try { off(); } catch { /* noop */ } } }
            };
          }, 'dsh-windows-toolbox: dictionaries');
          t = ctx.locale.bind(NS);
          tManage = ctx.locale.bind(NS_MANAGE);
          tToolbox = ctx.locale.bind(NS_TOOLBOX);
        }
        // The manage half's explanations are generated server-side, so it needs
        // to be told the active language. Defensive: a host without
        // getSnapshot, or one that throws, falls back to the plugin default
        // instead of breaking load().
        const getLang = () => {
          try {
            const active = ctx.locale?.getSnapshot?.()?.active;
            if (typeof active === 'string' && active.toLowerCase().startsWith('en')) return 'en';
          } catch { /* no snapshot on this host */ }
          return 'zh';
        };
        try { ctx.inject(['layout'], (scoped) => { layout = scoped.layout; }); } catch { /* optional */ }
        ctx.effect(() => {
          const offs = [];
          // MUST go through ctx.slots.inject(name, () => ctx.slots.register(...)):
          // rc.3 declares these slots lazily, so a bare register() at apply time
          // runs before the declaration exists and is silently dropped.
          try {
            offs.push(ctx.slots.inject('main', () => ctx.slots.register({
              name: 'main', key: PANEL_ID, locale: NS, inject: () => ({ t, tManage, tToolbox, getLang }),
            }, () => h(Shell, { t, tManage, tToolbox, getLang, Manage: MANAGE, Toolbox: TOOLBOX }))));
          } catch (e) { console.warn('[dsh-windows-toolbox] main panel registration failed:', e?.message); }
          try {
            offs.push(ctx.slots.inject('sidebar.panellist', () => ctx.slots.register({
              name: 'sidebar.panellist', id: PANEL_ID, order: 7, label: () => t('nav'), locale: NS,
            }, (owner = {}) => h(ToolboxMergedIcon, { size: owner.size ?? 16 }))));
          } catch (e) { console.warn('[dsh-windows-toolbox] sidebar row unavailable:', e?.message); }

          return () => {
            for (const off of offs) { if (typeof off === 'function') { try { off(); } catch { /* noop */ } } }
            try { if (layout?.panelInfo?.getSnapshot?.().activePanelId === PANEL_ID) layout.selectPanel?.(null); } catch { /* noop */ }
          };
        }, 'dsh-windows-toolbox: workbench panel');
      },
    };
  },
});
