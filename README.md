# WINDOWS工具箱（dsh-windows-toolbox）

一个 DSH 插件，两半功能，共用一套探针基础设施、一套风险分级、一套「先预演再执行」的安全模型。

```
┌─ WINDOWS工具箱 (侧栏一个入口, order 7) ────────────────────┐
│  [ 插件化管理 ]  [ 工具箱 ]        ← 顶部两个页签           │
├────────────────────────────────────────────────────────────┤
│  插件化管理: 十一类注册点索引 2454 条 + 系统修复 8 项        │
│  工具箱:     25 个维护能力（清理/诊断/修复/目录）            │
└────────────────────────────────────────────────────────────┘
```

- 上半 **插件化管理** — <span>docs/manage/DETAIL.zh.md</span>
- 下半 **工具箱** — <span>docs/toolbox/DETAIL.zh.md</span>

## 为什么要合并

两半原来是两个独立插件（原 `dsh-windows-plugin-manager` + 原 `dsh-360-toolbox`）。它们共用同一批东西：PowerShell 探针启动器（`lib/ps.js`）、`featurelib.ps1` 的行格式、`reg export` 备份机制、dryRun 默认值、提权通道。合并后：

- 侧栏从两个入口变成一个，不占两行。
- 提权通道只有一份：`lib/elevation.js` 起一个**常驻** broker（`lib/probes/broker.ps1`），两个页签共用，**整个会话只弹一次 UAC**。之后所有提权动作都投给同一个仍持有管理员令牌的进程，不再每点一次问一次。
- 探针目录只有一份，`host.ps1` 与 `featurelib.ps1` 不再各存一份副本。
- 测试能一次跑完两半，不会再出现"改了 A 插件但 B 插件的断言因为复制粘贴而一起变绿"。

## 目录

```
dsh-windows-toolbox/
├─ index.js                 # 挂两半: mountManage() + mountToolbox()，各自 try/catch
├─ client.js                # 生成文件: node tools/merge-client.mjs
├─ icon.svg
├─ cordis.patch.yml
├─ locale/{zh,en}.json      # meta.title / description / detail
├─ lib/
│  ├─ host-manage.js        # 7 路由 /dsh-windows-toolbox/api/manage/* + 7 工具 wpm_*
│  ├─ host-toolbox.js       # 6 路由 /dsh-windows-toolbox/api/toolbox/* + 5 工具 tb360_*
│  ├─ sources.js            # 12 类注册点定义 + PROTECTED_SERVICES + riskOf()
│  ├─ normalize.js          # 原始行 → 统一条目
│  ├─ explain.js            # 统一条目 → 「是什么/在哪见/有什么作用/关了会怎样」
│  ├─ inventory.js          # 注册点索引缓存（单语言 zh，按请求重算）
│  ├─ capabilities.js       # 25 个能力定义 + 9 组 junk + 覆盖度
│  ├─ runner.js             # 工具箱执行器 + 参数白名单 + 超时表
│  ├─ ps.js                 # PowerShell 解释器探测 + runProbe
│  ├─ probes/*.ps1          # 44 个探针 + featurelib/junklib/rootlib/CONTRACT.md
│  └─ presets/*.json        # drivers / softwares(-A/B/C) / tweaks
├─ tools/
│  ├─ merge-client.mjs      # 从两个旧 client.js 生成合并后的 client.js
│  ├─ smoke-merged.mjs      # 校验两半都挂上：13 路由 + 12 工具 + 无旧前缀
│  ├─ audit-probes.mjs      # 探针客观验收（语法/禁用 API/UTF-8 头/param 位置）
│  ├─ verify-catalog.mjs    # 软件目录"只给官网"强制执行器
│  ├─ verify-drivers.mjs    # 驱动官网映射校验
│  ├─ merge-catalog.mjs     # 三个目录分片 → softwares.json
│  └─ probe-shapes.mjs      # 打印探针真实信封形状
├─ tests/
│  ├─ render.mjs            # 无头渲染 + 交互断言（WINDOWS_TOOLBOX_PANEL=manage|toolbox）
│  ├─ run-all.mjs           # 聚合器，透传 --unit-only
│  ├─ run-all-manage.mjs
│  └─ run-all-toolbox.mjs
└─ docs/{manage,toolbox}/
```

## 命令

```bash
node tools/smoke-merged.mjs          # 两半都挂上了吗（秒级，不需要 DSH）
node tools/audit-probes.mjs          # 44 个探针：语法 + 禁用 API + 输出契约
node tools/verify-catalog.mjs --offline
node tools/verify-drivers.mjs --offline

node tests/run-all.mjs               # 两半全量（含真跑探针，约几分钟）
node tests/run-all.mjs --unit-only   # 只跑单元
node tests/render.mjs                # 默认渲染 manage 半
WINDOWS_TOOLBOX_PANEL=toolbox node tests/render.mjs
```

## 安装

从 npm（推荐，预构建、装完即用）：

```bash
dsh plugin add dsh-windows-toolbox
```

也可以直接从 GitHub 仓库装。开发时用 `link:`，改代码即时生效于**探针与客户端**：

```json
"dsh-windows-toolbox": "link:E:/DSHWORK/DSH插件/dsh-windows-toolbox"
```

### 开发时的分层生效（实测，务必分清）

| 改动 | 需要重启 DSH 吗 |
|---|---|
| `lib/probes/*.ps1` | 不需要（每次调用新起进程） |
| `client.js` | 不需要（刷新页面） |
| `lib/*.js`、`index.js` | **需要重启桌面进程** |

原因：profile 是 hoisted 布局，插件更新是原地改写文件、模块 URL 不变，Node ESM 缓存会把后续 import 全解析到旧模块。`POST /dsh-market/toggle` 的响应里 `hot:true` 只是围着**旧模块**重建 fiber——实测双标记实验，标记读不到。`/dsh-market/restart` 在 `supervisor` 存在时返回 403。

## 三条设计红线（两半共用）

1. **绝不编造**。测不到就 `skip` 并写明原因；推不出的字段返回 `null` 由 UI 省略，不填 0、不写"可能/大概"。
2. **写操作默认 dryRun**。非 dryRun 前把将触碰的注册表键 `reg export` 到 `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\`，备份失败即中止。
3. **不做内核层的事**。实时拦截（弹窗过滤、火绒式驱动拦截）、BadUSB 固件防御、TRIM 后的数据恢复——这些做不到就是做不到，在 UI 上明写"做不到"，不用"只读检查"假装实现了。

## 权限

未提权时（本机实测，`UAC ConsentPromptBehaviorAdmin=5`）：

| 能改 | 改不了（返回 `needsAdmin` + 完整命令 + 「以管理员身份重试」按钮） |
|---|---|
| HKCU 注册表、启动文件夹改名、DNS 缓存 | 服务启停/启动类型、计划任务、HKLM、防火墙规则、驱动删除、分区操作 |

提权走常驻 broker：`lib/elevation.js` 用 `Start-Process -Verb RunAs` 只拉起一次 `lib/probes/broker.ps1`，它拿到管理员令牌后常驻，通过临时目录里的 job/result JSON 文件接收任务。UAC 取消返回 `{ok:false,cancelled:true}` 而不是 500，且不会留下半截状态。
