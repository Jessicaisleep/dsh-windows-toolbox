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
      // Real React folds positional children into props.children; this harness
      // used to drop them, so every component that took its label as a child
      // (Btn, Badge, ...) rendered empty and the text assertions could not see
      // its own button labels.
      const withChildren = node.children === undefined
        ? (props ?? {})
        : { ...(props ?? {}), children: node.children };
      return expand(type(withChildren), depth + 1);
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
    payloads: {
      '/status': {
        ok: true, name: 'dsh-360-toolbox', version: '0.1.0', host: HOST,
        catalogue: [
          { id: 'junk', risk: 'destructive', actions: ['scan', 'clean'], label: '垃圾清理', labelEn: 'Junk cleanup', tagline: '扫描固定白名单内的缓存，可直接清理', detail: '' },
          { id: 'bigfiles', risk: 'readonly', actions: ['scan'], label: '大文件查找', labelEn: 'Large files', tagline: '找出占空间最多的文件', detail: '' },
          { id: 'dupfiles', risk: 'readonly', actions: ['scan'], label: '重复文件', labelEn: 'Duplicate files', tagline: '按内容哈希找真正的重复', detail: '' },
          { id: 'netdiag', risk: 'readonly', actions: ['scan'], label: '断网诊断', labelEn: 'Network diagnosis', tagline: '按链路顺序定位断点', detail: '' },
          { id: 'health', risk: 'readonly', actions: ['scan'], label: '系统体检', labelEn: 'Health check', tagline: '磁盘、内存、服务、事件等 11 项实测', detail: '' },
        ],
        capabilities: [
          { id: 'junk', cached: true, itemCount: 16, at: Date.now() - 1000 },
          { id: 'bigfiles', cached: false, itemCount: 0, at: 0 },
          { id: 'dupfiles', cached: false, itemCount: 0, at: 0 },
          { id: 'netdiag', cached: false, itemCount: 0, at: 0 },
          { id: 'health', cached: true, itemCount: 11, at: Date.now() - 2000 },
        ],
        junkGroups: [
          { id: 'temp', label: '临时文件', labelEn: 'Temporary', targets: ['user-temp', 'windows-temp'] },
          { id: 'browser', label: '浏览器缓存', labelEn: 'Browser', targets: ['edge-cache'] },
        ],
        scanRoots: [{ id: 'user', label: '用户目录' }, { id: 'downloads', label: '下载' }],
      },
      '/result?id=junk': {
        ok: true, cached: false,
        items: [
          { id: 'user-temp', label: '用户临时文件', path: 'C:\\Users\\26035\\AppData\\Local\\Temp', kind: 'dirContent', exists: true, blocked: false, needsAdmin: false, files: 4752, bytes: 578901341, note: '' },
          { id: 'windows-temp', label: '系统临时文件', path: 'C:\\Windows\\Temp', kind: 'dirContent', exists: true, blocked: true, needsAdmin: true, files: 289, bytes: 141557760, note: '' },
          { id: 'edge-cache', label: 'Edge 缓存', path: 'C:\\Users\\26035\\AppData\\Local\\Microsoft\\Edge\\User Data\\Default\\Cache', kind: 'dirContent', exists: true, blocked: false, needsAdmin: false, files: 607, bytes: 391758288, note: '' },
          { id: 'recycle-bin', label: '回收站', path: '', kind: 'recycle', exists: true, blocked: false, needsAdmin: false, files: 0, bytes: 0, note: '' },
        ],
        meta: { action: 'scan', dryRun: true, elevated: false, totalBytes: 1112217389, totalFiles: 5648, freed: 0, deleted: 0, skipped: 0, messages: [] },
      },
    },
    mustShow: LANG === 'zh'
      ? ['360 工具箱', '垃圾清理', '用户临时文件', '系统体检', '需要管理员权限']
      : ['360 Toolbox', 'Junk cleanup', 'Needs admin'],
  },

  'dsh-windows-plugin-manager': {
    ns: '/dsh-windows-plugin-manager/',
    payloads: {
      '/status': {
        ok: true, name: 'dsh-windows-plugin-manager', version: '0.1.0', host: HOST,
        // Captured from the live host 2026-11-18: 12 sources / 2462 entries. autorun grew
        // from 3 to 136 once it began reporting services, logon tasks and Active Setup.
        total: 2462, elapsedMs: 5200,
        sources: [
          { id: 'svc', label: '服务', labelEn: 'Services', risk: 'reversible', actions: ['enable', 'disable'], description: 'Windows 服务：开机就在后台运行的程序，不显示窗口。', total: 272, enabled: 108, disabled: 164, unknown: 0, ms: 963, stale: false, error: '' },
          { id: 'task', label: '计划任务', labelEn: 'Tasks', risk: 'reversible', actions: ['enable', 'disable'], description: '计划任务：按时间或事件自动运行的程序。', total: 165, enabled: 131, disabled: 34, unknown: 0, ms: 1317, stale: false, error: '' },
          { id: 'autorun', label: '开机自启', labelEn: 'Autostart', risk: 'reversible', actions: ['enable', 'disable'], description: '开机会自动运行的东西：Run/RunOnce 十处注册表项、启动文件夹、UWP StartupTask、登录/开机触发的计划任务、自动启动的服务、Active Setup', total: 136, enabled: 91, disabled: 45, unknown: 0, ms: 2284, stale: false, error: '' },
          { id: 'com', label: '右键扩展', labelEn: 'Shell extensions', risk: 'reversible', actions: ['enable', 'disable'], description: '外壳扩展：给资源管理器加菜单项或属性页。', total: 75, enabled: 75, disabled: 0, unknown: 0, ms: 2342, stale: false, error: '' },
          { id: 'program', label: '已安装程序', labelEn: 'Programs', risk: 'destructive', actions: ['uninstall'], description: '已安装程序：可卸载（先预演再执行）。', total: 114, enabled: 114, disabled: 0, unknown: 0, ms: 599, stale: false, error: '' },
          { id: 'appx', label: 'AppX 应用', labelEn: 'AppX', risk: 'destructive', actions: ['uninstall'], description: 'AppX/MSIX 商店应用，可卸载（非系统包）。', total: 100, enabled: 100, disabled: 0, unknown: 0, ms: 3983, stale: false, error: '' },
          { id: 'drv', label: '驱动', labelEn: 'Drivers', risk: 'destructive', actions: ['uninstall'], description: '驱动程序包，仅第三方且未被占用的可删。', total: 418, enabled: 45, disabled: 205, unknown: 168, ms: 1699, stale: false, error: '' },
          { id: 'firewall', label: '防火墙规则', labelEn: 'Firewall rules', risk: 'reversible', actions: ['enable', 'disable'], description: '防火墙规则：每条入站/出站放行或阻断。', total: 546, enabled: 347, disabled: 199, unknown: 0, ms: 1107, stale: false, error: '' },
          { id: 'ifeo', label: 'IFEO 劫持', labelEn: 'IFEO hijack', risk: 'readonly', actions: [], description: '映像劫持：启动某个 exe 时实际运行另一个程序。', total: 86, enabled: 86, disabled: 0, unknown: 0, ms: 562, stale: false, error: '' },
          { id: 'fileexts', label: '文件关联', labelEn: 'File associations', risk: 'readonly', actions: [], description: '文件关联：哪种扩展名交给哪个程序打开。', total: 520, enabled: 163, disabled: 357, unknown: 0, ms: 605, stale: false, error: '' },
          { id: 'credprov', label: '凭据提供程序', labelEn: 'Credential providers', risk: 'readonly', actions: [], description: '凭据提供程序：登录界面上多出来的登录方式。', total: 22, enabled: 22, disabled: 0, unknown: 0, ms: 485, stale: false, error: '' },
          { id: 'repair', label: '系统修复', labelEn: 'System repair', risk: 'readonly', actions: [], description: '八项配置漂移检查（hosts / IE 主页 / DNS / 连接数 / UAC / 冗余注册表项 / 字体缓存 / 图标缓存）', total: 8, enabled: 0, disabled: 0, unknown: 8, ms: 882, stale: false, error: '', meta: { ok: true, count: 8, summary: { total: 8, ok: 6, warn: 0, bad: 0, info: 1, skip: 1 } } },
        ],
      },
      '/entries': {
        ok: true, total: 2462, shown: 6,
        rows: [
          {
            id: 'svc:machine:Spooler', source: 'svc', kind: 'service', name: 'Spooler', state: 'Running', enabled: true,
            path: 'C:\\WINDOWS\\System32\\spoolsv.exe', version: '', publisher: 'Microsoft Corporation',
            scope: 'machine', view: '64', risk: 'reversible', detail: { name: 'Spooler' },
            explain: {
              kindLabel: 'Windows 服务',
              what: '一个后台服务。它不显示窗口，开机就在后台运行。',
              where: '任务管理器的「服务」选项卡，或服务管理器里',
              purpose: '由 Microsoft Corporation 提供，是打印后台处理服务，负责把要打印的文件排队送进打印机。',
              ifOff: '关掉之后打印队列会停止工作，所有打印任务都会失败。',
              origin: 'microsoft', originName: 'Microsoft Corporation',
              facts: [['由哪个文件提供', 'C:\\WINDOWS\\System32\\spoolsv.exe'], ['启动类型', 'Automatic']],
            },
          },
          {
            id: 'task:machine:\\Microsoft\\Windows\\Application Experience\\Microsoft Compatibility Appraiser',
            source: 'task', kind: 'task',
            name: '\\Microsoft\\Windows\\Application Experience\\Microsoft Compatibility Appraiser',
            state: 'Ready', enabled: false, path: '', version: '', publisher: 'Microsoft Corporation',
            scope: 'machine', view: '64', risk: 'reversible',
            detail: { taskPath: '\\Microsoft\\Windows\\Application Experience\\', taskName: 'Microsoft Compatibility Appraiser' },
            explain: {
              kindLabel: '计划任务',
              what: '一条计划任务。它按触发条件（时间、开机、登录）自动运行一次。',
              where: '任务计划程序库的 Application Experience 文件夹里',
              purpose: '由 Microsoft Corporation 提供，注册名是「Microsoft Compatibility Appraiser」。',
              ifOff: '关掉之后 Windows 不会自动上报兼容性数据。',
              origin: 'microsoft', originName: 'Microsoft Corporation',
              facts: [['任务路径', '\\Microsoft\\Windows\\Application Experience\\']],
            },
          },
          {
            id: 'svc:machine:ZhuDongFangYu', source: 'svc', kind: 'service', name: 'ZhuDongFangYu', state: 'Running', enabled: true,
            path: 'D:\\Program Files (x86)\\360\\360Safe\\deepscan\\ZhuDongFangYu.exe', version: '14.0.2.1004',
            publisher: '360', scope: 'machine', view: '64', risk: 'blocked', detail: { name: 'ZhuDongFangYu' },
            explain: {
              kindLabel: 'Windows 服务',
              what: '一个后台服务。它不显示窗口，开机就在后台运行。',
              where: '任务管理器的「服务」选项卡，或服务管理器里',
              purpose: '由「360安全卫士」提供，注册名是「ZhuDongFangYu」。',
              ifOff: '关掉之后 360 的主动防御会失效，病毒拦截与自我保护会停止工作。',
              origin: 'thirdparty', originName: '360.cn',
              facts: [['由哪个文件提供', 'D:\\Program Files (x86)\\360\\360Safe\\deepscan\\ZhuDongFangYu.exe']],
            },
          },
          {
            id: 'com:machine:{8F2C0D11-0000-4B2E-9A31-360ZIP000001}',
            source: 'com', kind: 'shellex', name: '360压缩 Shell Extension', state: '', enabled: null,
            path: 'D:\\Program Files (x86)\\360\\360Zip\\360ZipExt64.dll', version: '', publisher: '360.cn',
            scope: 'machine', view: '64', risk: 'reversible',
            detail: { server: 'D:\\Program Files (x86)\\360\\360Zip\\360ZipExt64.dll', clsid: '{8F2C0D11-0000-4B2E-9A31-360ZIP000001}' },
            explain: {
              kindLabel: '右键菜单扩展',
              what: '一个外壳扩展。它不会自己运行，但会在资源管理器的菜单或属性对话框里增加一项。',
              where: '在任意文件上右键时出现的菜单项',
              purpose: '由「360压缩 Shell Extension」提供，注册名是「360压缩文件类型」。',
              ifOff: '关掉之后这一项菜单/选项卡会消失，压缩包的右键菜单恢复成系统默认。',
              origin: 'thirdparty', originName: '360.cn',
              facts: [
                ['由哪个文件提供', 'D:\\Program Files (x86)\\360\\360Zip\\360ZipExt64.dll'],
                ['CLSID', '{8F2C0D11-0000-4B2E-9A31-360ZIP000001}'],
              ],
            },
          },
          {
              "id": "program:machine:HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Git_is1",
              "source": "program",
              "kind": "program",
              "name": "Git",
              "state": "installed",
              "enabled": true,
              "path": "C:\\Program Files\\Git\\mingw64\\share\\git\\git-for-windows.ico",
              "version": "2.55.0.5",
              "publisher": "The Git Development Community",
              "scope": "machine",
              "view": "64",
              "risk": "destructive",
              "detail": {
                "source": "uninst",
                "kind": "program",
                "name": "Git",
                "state": "installed",
                "path": "C:\\Program Files\\Git\\mingw64\\share\\git\\git-for-windows.ico",
                "version": "2.55.0.5",
                "publisher": "The Git Development Community",
                "installLocation": "C:\\Program Files\\Git\\",
                "uninstall": "\"C:\\Program Files\\Git\\unins000.exe\"",
                "quietUninstall": "\"C:\\Program Files\\Git\\unins000.exe\" /SILENT",
                "modify": "",
                "productCode": "Git_is1",
                "scope": "machine",
                "view": "64",
                "keyPath": "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Git_is1",
                "installDate": "20260922",
                "sizeKb": 344561,
                "systemComponent": ""
              },
              "explain": {
                "kindLabel": "已安装软件",
                "what": "版本 2.55.0.5，发布者「The Git Development Community」，登记体积 336.5 MB，有自己的安装目录 C:\\Program Files\\Git\\。",
                "where": "「设置 → 应用 → 已安装的应用」或「控制面板 → 程序和功能」里的「Git」。",
                "purpose": "它在「程序和功能」里有一条正式登记：卸载入口是 unins000，安装日期 2026-09-22，登记体积 336.5 MB，装在 C:\\Program Files\\Git\\，产品代码 Git_is1。绿色软件不会留下这条登记，所以这一条是真被安装程序写进系统的。它另有一条静默卸载命令 unins000，可无人值守地卸载。",
                "ifOff": "这一版只读：它告诉你去哪儿卸载，但不代你执行。要卸载请走系统自带的卸载入口（就是上面这条命令），或者先扫描掌握情况。",
                "origin": "thirdparty",
                "originName": "The Git Development Community",
                "facts": [
                  [
                    "版本",
                    "2.55.0.5"
                  ],
                  [
                    "发布者",
                    "The Git Development Community"
                  ],
                  [
                    "安装位置",
                    "C:\\Program Files\\Git\\"
                  ],
                  [
                    "安装时间",
                    "2026-09-22"
                  ],
                  [
                    "占用大小",
                    "336.5 MB"
                  ],
                  [
                    "卸载命令",
                    "\"C:\\Program Files\\Git\\unins000.exe\""
                  ],
                  [
                    "静默卸载",
                    "\"C:\\Program Files\\Git\\unins000.exe\" /SILENT"
                  ],
                  [
                    "产品代码",
                    "Git_is1"
                  ]
                ]
              }
            },
          {
            id: 'drv:machine:0000:oem19.inf', source: 'drv', kind: 'driver', name: 'oem19.inf', state: 'OK', enabled: true,
            path: 'C:\\Windows\\System32\\DriverStore\\FileRepository\\oem19.inf', version: '', publisher: '',
            scope: 'machine', view: '64', risk: 'readonly', detail: { inf: 'oem19.inf' },
            explain: null,
          },
        ],
      },
    },
    // Strings that must reach the paint. The explain.what of the COM entry is the
    // page's whole reason to exist ("这玩意是干嘛的"), so it is asserted by name.
    mustShow: LANG === 'zh'
      ? ['Windows 插件化管理器', '服务', 'Spooler', 'ZhuDongFangYu', '2462', '系统修复', 'Git']
      : ['Windows Plugin Manager', 'Spooler'],
    // explain.js emits Chinese regardless of UI language, so these hold in both
    // languages: the card faces must carry the explanation, not just the name.
    explainOnFace: [
      '一个外壳扩展。它不会自己运行，但会在资源管理器的菜单或属性对话框里增加一项。',
      '在任意文件上右键时出现的菜单项',
      '一个后台服务。它不显示窗口，开机就在后台运行。',
    ],
    // Only reachable by clicking a card open.
    explainOnExpand: [
      '由「360压缩 Shell Extension」提供，注册名是「360压缩文件类型」。',
      '关掉之后这一项菜单/选项卡会消失，压缩包的右键菜单恢复成系统默认。',
      'D:\\Program Files (x86)\\360\\360Zip\\360ZipExt64.dll',
      '{8F2C0D11-0000-4B2E-9A31-360ZIP000001}',
    ],
    // The card the click test opens, and the fallback path for explain === null.
    openName: '360压缩 Shell Extension',
    noExplainName: 'oem19.inf',
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

/* ------------------------------------------------------- card structure --- */

/** All rendered text below one node, flattened. */
function textOf(node) {
  const out = [];
  (function walk(n) {
    if (n == null || n === false) return;
    if (typeof n === 'string') { out.push(n); return; }
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (typeof n !== 'object' || !('type' in n)) return;
    walk(n.props?.children);
  }(node));
  return out.join(' ');
}

/** First clickable card whose own text mentions `needle`. */
function findCard(root, needle) {
  let hit = null;
  (function walk(n) {
    if (hit || n == null || n === false || typeof n !== 'object') return;
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (!('type' in n)) return;
    if (n.props?.role === 'button' && typeof n.props?.onClick === 'function'
      && textOf(n).includes(needle)) { hit = n; return; }
    walk(n.props?.children);
  }(root));
  return hit;
}

const cards = [];
(function walk(n) {
  if (n == null || n === false || typeof n !== 'object') return;
  if (Array.isArray(n)) { n.forEach(walk); return; }
  if (!('type' in n)) return;
  if (n.props?.role === 'button' && 'aria-expanded' in (n.props ?? {})) cards.push(n);
  walk(n.props?.children);
}(tree));

const rowCount = FIXTURES[mod.id].payloads['/entries'].rows.length;
if (cards.length < rowCount) {
  throw new Error(`expected >= ${rowCount} entry cards, found ${cards.length}`);
}
if (cards.some((c) => c.props['aria-expanded'] !== 'false')) {
  throw new Error('every card must start collapsed (aria-expanded=false)');
}

// The one-sentence explanation has to be on the CARD FACE — the whole point of
// the redesign is that nobody has to click to learn what a thing is.
const faceAbsent = cfg.explainOnFace.filter((s) => !joined.includes(s));
if (faceAbsent.length) {
  throw new Error(`card faces did not render explain.what/where: ${faceAbsent.join(' | ')}`);
}

// explain === null must degrade to the raw state plus an honest note, not crash.
const noExplainNote = resolved.noExplain;
if (!noExplainNote) throw new Error('dictionary has no noExplain string');
if (!joined.includes(noExplainNote)) {
  throw new Error('an entry with explain === null did not render the noExplain fallback');
}

// Nothing detail-only may leak into the collapsed view.
const leaked = cfg.explainOnExpand.filter((s) => joined.includes(s));
if (leaked.length) {
  throw new Error(`collapsed cards rendered detail-only text: ${leaked.join(' | ')}`);
}

/* ------------------------------------------- a collapsed card can be ACTED ON */
//
// The user's complaint was "大量卡片只能看不能操作": every verb lived inside the
// expanded detail, so the panel read as a wall of inert text. The fix put one
// primary verb on each card face, as a SIBLING of the expanding role="button"
// node (nesting a button inside a button is invalid ARIA and swallows clicks).
//
// This assertion exists so that regression cannot come back quietly: for every
// card on screen, look at its face container's children and demand either a
// real <button> or an explicit badge saying why there is none.

/** Face text + the verb buttons that sit beside, not inside, the expanding node. */
function faceOf(cardNode) {
  // Walk up is not available in a plain tree, so instead find the wrapper whose
  // children are [expandingNode, actionRow, maybeDetail] by searching from root.
  let found = null;
  (function walk(n) {
    if (found || n == null || n === false || typeof n !== 'object') return;
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (!('type' in n)) return;
    const kids = n.props?.children;
    const list = Array.isArray(kids) ? kids : (kids ? [kids] : []);
    if (list.includes(cardNode)) { found = list; return; }
    walk(kids);
  }(tree));
  return found ?? [];
}

function buttonTexts(nodes) {
  const out = [];
  (function walk(n) {
    if (n == null || n === false) return;
    if (Array.isArray(n)) { n.forEach(walk); return; }
    if (typeof n !== 'object' || !('type' in n)) return;
    // Two shapes count as a button: a host `<button>` tag (what Btn renders) and
    // anything carrying role="button" with a click handler (the card face).
    const isButton = n.type === 'button'
      || (n.props?.role === 'button' && typeof n.props?.onClick === 'function');
    if (isButton) {
      const label = textOf(n).trim();
      if (label) out.push(label);
      return;
    }
    walk(n.props?.children);
  }(nodes));
  return out;
}

const faceReport = cards.map((c) => {
  const siblings = faceOf(c).filter((s) => s !== c);
  const btns = buttonTexts(siblings);
  const otherText = siblings.map((s) => (typeof s === 'string' ? s : textOf(s))).join(' ').trim();
  return {
    name: (textOf(c).split(' ')[0] ?? '').slice(0, 24),
    buttons: btns,
    // A card with no verb must still say why: 受保护 / 仅查看.
    explains: btns.length > 0
      || otherText.includes(resolved.riskBlockedNote)
      || otherText.includes(resolved.readonlyBadge),
    text: otherText.slice(0, 120),
  };
});

const inert = faceReport.filter((f) => !f.explains);
if (inert.length) {
  throw new Error(
    `${inert.length} collapsed card(s) are neither actionable nor explained: `
    + inert.map((f) => `${f.name} [${f.text}]`).join(' | '),
  );
}
const actionable = faceReport.filter((f) => f.buttons.length > 0).length;
const explainedOnly = faceReport.filter((f) => f.buttons.length === 0).length;
if (actionable === 0) {
  throw new Error('no card face exposes an action button — the panel is read-only again');
}
if (!resolved.actionDisable || !resolved.actionUninstall) {
  throw new Error('dictionary lost the face verb labels');
}
if (!joined.includes(resolved.actionDisable)) {
  throw new Error(`no card face shows "${resolved.actionDisable}" — enabled rows lost their verb`);
}
if (!joined.includes(resolved.actionUninstall)) {
  throw new Error(`no card face shows "${resolved.actionUninstall}" — programs lost their uninstall`);
}

/* --------------------------------------------------------- click to expand */

const card = findCard(tree, cfg.openName);
if (!card) throw new Error(`no clickable card for "${cfg.openName}"`);

card.props.onClick();

let expandedTree = null;
for (let pass = 0; pass < MAX_PASSES; pass += 1) {
  visitOrder = 0;
  dirty = false;
  effects = [];
  expandedTree = expand(registered.main.render({ t }), 0);
  for (const fn of effects) fn();
  for (let i = 0; i < 8; i += 1) await new Promise((r) => setTimeout(r, 0));
  if (!dirty) break;
  if (pass === MAX_PASSES - 1) throw new Error(`panel never settled after expanding a card`);
}

const expandedTexts = [];
(function walk(n) {
  if (n == null || n === false) return;
  if (typeof n === 'string') { expandedTexts.push(n); return; }
  if (Array.isArray(n)) { n.forEach(walk); return; }
  if (typeof n !== 'object' || !('type' in n)) return;
  walk(n.props?.children);
}(expandedTree));
const expandedJoined = expandedTexts.join(' ');

const expandAbsent = cfg.explainOnExpand.filter((s) => !expandedJoined.includes(s));
if (expandAbsent.length) {
  throw new Error(`expanded card missing purpose/ifOff/facts: ${expandAbsent.join(' | ')}`);
}

// The raw record is a folded <details>, and the switches live in the open card.
if (!expandedJoined.includes(resolved.exp_raw)) throw new Error('expanded card has no raw-data summary');
if (!expandedJoined.includes(resolved.actionDryRun)) throw new Error('expanded card has no dry-run button');

const openAfter = [];
(function walk(n) {
  if (n == null || n === false || typeof n !== 'object') return;
  if (Array.isArray(n)) { n.forEach(walk); return; }
  if (!('type' in n)) return;
  if (n.props?.role === 'button' && n.props?.['aria-expanded'] === 'true') openAfter.push(n);
  walk(n.props?.children);
}(expandedTree));
if (openAfter.length !== 1) throw new Error(`expected exactly 1 expanded card, got ${openAfter.length}`);

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
  cards: cards.length,
  faceActions: actionable,
  faceExplainedOnly: explainedOnly,
  explainOnFace: cfg.explainOnFace.length,
  explainOnExpand: cfg.explainOnExpand.length,
  expandedCard: cfg.openName,
  expandedChars: expandedJoined.length,
  textNodesExpanded: expandedTexts.length,
  sample: joined.slice(0, 300),
}, null, 2));
