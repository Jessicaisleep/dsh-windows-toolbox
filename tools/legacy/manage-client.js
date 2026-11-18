/**
 * dsh-windows-plugin-manager — Client half: the 工作栏 panel.
 *
 * Pure ESM loaded through window.__ModuleLoader__. React comes from the host
 * module table (require('react')); NO host Client UI package is imported
 * (practices.md), and styling uses only --dsw-alias-* theme tokens so light and
 * dark themes are inherited.
 *
 * The whole point of this panel is to answer two questions for someone who is
 * not a Windows internals developer:
 *
 *   "这条东西是干嘛的？"  -> entry.explain.what / .where on the card face
 *   "我能关掉它吗？"     -> expand the card for purpose / ifOff / facts / switch
 *
 * So the layout is one card grid per registration source (sources come from
 * /status, never hardcoded — the backend can add a source without a client
 * change), each card answering "what is this" in one sentence, and a click
 * expands that card in place instead of opening a second pane.
 *
 * The cards are driven by lib/explain.js output attached in lib/inventory.js,
 * which may be null for anything it cannot honestly describe — the card then
 * degrades to just the raw state and says so.
 */
window.__ModuleLoader__.load({
  id: 'dsh-windows-plugin-manager',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    const { useState, useEffect, useCallback, useMemo } = React;

    const NS = 'dsh-windows-plugin-manager';
    const PANEL_ID = 'dsh-windows-plugin-manager';
    const API = '/dsh-windows-plugin-manager/api';

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

    // ---- module registration ----
    return {
      inject: ['slots', 'locale', 'theme'],
      apply(ctx) {
        let t = (k) => k;
        let layout;
        if (ctx.locale && typeof ctx.locale.register === 'function' && typeof ctx.locale.bind === 'function') {
          ctx.effect(() => ctx.locale.register(NS, DICT), 'dsh-windows-plugin-manager: dictionaries');
          t = ctx.locale.bind(NS);
        }
        // The server generates the explanations, so it needs to be told which
        // language to generate them in. Captured here (not read from a global in
        // the component) and defensive: a host without getSnapshot, or one that
        // throws, falls back to the plugin's default instead of breaking load().
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
              name: 'main', key: PANEL_ID, locale: NS, inject: () => ({ t, getLang }),
            }, () => h(Panel, { t, getLang }))));
          } catch (e) { console.warn('[dsh-windows-plugin-manager] main panel registration failed:', e?.message); }
          try {
            offs.push(ctx.slots.inject('sidebar.panellist', () => ctx.slots.register({
              name: 'sidebar.panellist', id: PANEL_ID, order: 7, label: () => t('nav'), locale: NS,
            }, (owner = {}) => h(ManagerIcon, { size: owner.size ?? 16 }))));
          } catch (e) { console.warn('[dsh-windows-plugin-manager] sidebar row unavailable:', e?.message); }

          return () => {
            for (const off of offs) { if (typeof off === 'function') { try { off(); } catch { /* noop */ } } }
            try { if (layout?.panelInfo?.getSnapshot?.().activePanelId === PANEL_ID) layout.selectPanel?.(null); } catch { /* noop */ }
          };
        }, 'dsh-windows-plugin-manager: workbench panel');
      },
    };
  },
});
