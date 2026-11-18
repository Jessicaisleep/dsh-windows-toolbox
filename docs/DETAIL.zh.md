# WINDOWS工具箱 · 技术说明

一个 DSH 插件，两半功能，共用一套探针基础设施、一套风险分级、一套「先预演再执行」的安全模型。

| 半 | 面板页签 | 规模 | 深度文档 |
|---|---|---|---|
| 插件化管理 | 插件化管理 | 11 类注册点 / 2454 条 + 系统修复 8 项 | [细节](manage/DETAIL.zh.md) · [范围判定](manage/SCOPE.zh.md) · [系统修复](manage/REPAIR.zh.md) |
| 工具箱 | 工具箱 | 25 个能力 / 9 组清理 / 31 个清理目标 | [细节](toolbox/DETAIL.zh.md) |

本文只讲**两半共同的部分**：为什么这样切、共用的基础设施、共用的安全模型、以及跨两半都会踩的坑。每一半自己的细节在各自的文档里。

---

## 1. 为什么是一个插件而不是两个

原本是两个独立插件（`dsh-windows-plugin-manager` + `dsh-360-toolbox`），2026-11-18 合并。合并的判据不是"看起来相关"，而是**它们已经在共用同一批东西**：

| 共用物 | 合并前 | 合并后 |
|---|---|---|
| PowerShell 启动器 `ps.js` | 两份（差一个 `rm()` 清理） | 一份（取有 `rm()` 的那版） |
| `featurelib.ps1` | 两份（127 行 vs 155 行，后者多 `Add-Item -Extra` 与 `Get-OptionalString`） | 一份（155 行超集） |
| `host.ps1` | 两份，**逐字节相同** | 一份 |
| `reg export` 备份机制 | 两套各自实现 | 同一目录 `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\` |
| 提权通道 | 两套 | 一套（`elevated.ps1` + 两条路由指向同一实现） |
| dryRun 默认值语义 | 两处各自约定 | 一处约定，测试跨两半统一断言 |

合并的直接收益是**测试不能再靠复制粘贴作弊**。合并前两个 `render.mjs` 是同一份代码的两个拷贝，A 插件的断言因为 B 插件那边复制过来而"一起变绿"是可能的；现在 `tests/run-all.mjs` 一次跑完两半。

代价：`index.js` 里两半是**独立的 try/catch**。一半挂不上，另一半照常工作，只 `console.warn`。这是故意的——插件失败应该是降级，不是全灭。

```js
function mountHalf(name, fn, ctx, config) {
  try {
    fn(ctx, config);
  } catch (err) {
    console.warn(`[${ID}:${name}] failed to mount: ${err?.message ?? err}`);
  }
}
```

### 工具名为什么不合并

12 个工具保留两套前缀：`wpm_*`（7 个，注册点管理）与 `tb360_*`（5 个，维护工具箱）。如果统一成 `*_status`，模型读工具列表时分不清是哪一个 `status`。前缀是给读工具列表的人（模型）看的，不是给代码看的。

---

## 2. 共用的基础设施

### 2.1 `lib/ps.js` — PowerShell 启动器

| 导出 | 作用 |
|---|---|
| `probePath(name)` | 探针绝对路径（`fileURLToPath`，**不能用 `.pathname`**，见坑 3.1） |
| `interpreter()` | 缓存解释器选择：优先 `pwsh`（PS7），回落 `System32\WindowsPowerShell\v1.0\powershell.exe`（5.1） |
| `runProbe(script, params, {timeout})` | 把 `params` 写成临时 JSON，用 `-ParamFile` 传给探针 |
| `parseJson(stdout)` | 容忍 stderr 噪声：取首个 `[`/`{` 到最后一个 `]`/`}` |
| `resetInterpreterCache()` | 测试用 |

**参数永远走 `-ParamFile`，不拼进脚本字符串**。用户可控的值（路径、CLSID、服务名）如果拼进命令，一个引号就能变成任意代码执行。

### 2.2 `featurelib.ps1` — 行格式契约

所有"检查类"探针输出同一种行，这是两半能共用渲染器的原因：

```powershell
[ordered]@{ id; group; label; status; value; detail; fix; needsAdmin }
```

`status` 只有五个值，语义固定：

| status | 含义 | UI 表现 |
|---|---|---|
| `ok` | 实测过，正常 | 绿 |
| `warn` | 实测过，值得看 | 琥珀 |
| `bad` | 实测过，确实坏 | 红 |
| `info` | 纯事实（版本、路径、数量） | 灰 |
| `skip` | **没测到**，`detail` 必须说明原因 | 弱化 + 显示原因 |

`skip` 是这套契约里最要紧的一个。缺工具、缺管理员权限、硬件不支持——全部归 `skip` 并写清原因。**不许把没测到当成测到了正常**。

`Add-Item` 还接受 `-Extra`（合并时从工具箱那半引入的超集版本），用于附带 `labelZh`/`effectZh` 这类额外字段；`lib/runner.js` 的归一化器会把这些字段透传到前端。这是「tweaks 的中文标签到不了屏幕」那个 bug 的修复点——原归一化器只保留 8 个固定字段，多出来的全被丢掉。

### 2.3 风险分级（两半一致）

```
blocked      碰不得（受保护服务、映像劫持的目标、系统组件）
reversible   可逆：改注册表值、停服务、禁计划任务、禁外壳扩展、禁防火墙规则
destructive  不可逆：卸载程序、删 AppX、删驱动包、粉碎文件
readonly     只读检查，没有任何写路径
```

`blocked` 的判断在 `lib/sources.js` 的 `riskOf()`：命中 35 个 `PROTECTED_SERVICES`、或路径匹配 `\\drivers\\|\.sys\b` 且 `acceptStop === false`、或 IFEO 的 `detail.hijacked === true`。

### 2.4 缓存策略

- 注册点索引（`inventory.js`）：TTL 5 分钟，串行跑（12 个 PowerShell 同时起会把低端机拖成假死），`refresh` 时并行。冷启动约 7.4 秒 / 2461–2462 条（服务启停会让条数漂移）。
- 工具箱（`runner.js`）：TTL 5 分钟，各能力独立超时（junk 120s / dupfiles 240s / speedtest 180s / netdiag 240s）。
- **缓存只存一种语言（`zh`）**，英文按请求在 `host-manage.js` 的 `withLang()` 里重算。`explainEntry` 是纯函数，重算很便宜；存两份语言会让缓存翻倍而语言一整个会话可能都不变。

---

## 3. 跨两半的坑（每条都是实测踩出来的）

### 3.1 `new URL(...).pathname` 会百分号编码非 ASCII 路径

插件在 `E:\DSHWORK\DSH插件\...`，`.pathname` 给出 `DSH%E6%8F%92%E4%BB%B6` → PowerShell 报「无法找到路径」，**所有探针全灭**。必须 `fileURLToPath(new URL(file, PROBE_ROOT))`。

### 3.2 PowerShell 默认按系统代码页输出，Node 按 UTF-8 解码

所有中文变 `�ܾ������ܱ�������`。每个 `.ps1` 在 `param(...)` **之后**必须加：

```powershell
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
```

只测 JSON 结构不会暴露这个——结构对、内容是乱码。

### 3.3 `param` 块必须是脚本第一条语句

否则 PowerShell 报「术语 'param' 不会被识别为 cmdlet…」打到 stderr，然后**继续执行脚本体**。Node 的 `parseJson()` 会跳过噪声，所以"看起来正常"，实际参数从未绑定——降级路径成了死代码。

### 3.4 PowerShell 函数 `return` 会展开 `List`

```powershell
return $rows        # 调用方拿到的是被枚举后的数组，单元素时甚至不是数组
return , $rows      # 正确：前导逗号阻止展开
```

随后 `$rows.ToArray()` 会抛「[OrderedDictionary] 不包含名为 'ToArray' 的方法」。

### 3.5 `OrderedDictionary` 让 `Sort-Object -Property <键>` 和 `Measure-Object -Sum` 静默失效

```powershell
$rows | Sort-Object -Property bytes -Descending        # 完全不排序，不报错
$rows | Sort-Object -Property { [int64]$_.bytes } -Descending   # 正确
$rows | Measure-Object -Property files -Sum            # 返回空
```

字典的键不是 cmdlet 眼里的 PS 属性。所有排序与求和必须走 scriptblock 或手工 foreach。这个坑造成过"288 MB 排在 575 MB 前面"和"totalFiles 静默变空"。

### 3.6 `New-Item -Force` 在注册表上会**清空已存在的键**

```powershell
New-Item -Path $key -Force    # 键已存在 → 重建，丢弃全部值与子键，不报错
```

这条造成过真实数据损失（`HKCU\...\Explorer\Advanced` 被清空成 0 个值）。正确写法：

```powershell
if ($null -eq (Get-Item -LiteralPath $path -ErrorAction SilentlyContinue)) {
    New-Item -Path $path -ErrorAction Stop | Out-Null
}
```

顺带：探测不存在的注册表键用 `Get-Item` 约 **10 ms**；387 ms 是 `Test-Path` 的数字（注册表 provider 特有的慢）。文件系统上 `Test-Path` 只要 1.6 ms，可以放心用。

### 3.7 注册表路径里的字面量 `*` 必须用 `-LiteralPath`

`HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers` 用普通 `-Path` 会被当通配符，provider 遍历整个 `Classes` 树，实测 >2 分钟不结束（看起来像卡死）。

### 3.8 PS7 加载不了 Appx 模块，而且不报错

`Get-AppxPackage` 在 PS7 下抛 `Operation is not supported on this platform. (0x80131539)`，命令**不抛错、直接返回空** → 看起来像"本机没有 AppX"。真实是 100 个包。修法：`Import-Module Appx -UseWindowsPowerShell`，且**必须验证 `count > 0` 才算成功**，否则退回 `powershell.exe` 5.1 子进程。

同一类陷阱：`Get-NetFirewallRule` 在 PS7 下**静默返回 0 条**（本机实际 542 条）。改用 COM `HNetCfg.FwPolicy2`，44 ms 枚举完，还免提权。

**通用教训：一个枚举返回 0 条时，先证明这个 0 是真的。**

### 3.9 解释层不能"复述自己"

第一版 `explain.js` 按 `source` 返回固定模板，于是 78 张外壳扩展卡全都写着同一句「一个外壳扩展。它不会自己运行，但会在资源管理器中增加一项。」——用户的原话是「你这简介和没有一样」。

修法：每一行用**它自己的数据**生成文案。外壳扩展要指名到"具体是哪一页 /菜单里的哪一项"：`PageTitle` → `SHLoadIndirectString` 解析真实页签名（「以前的版本」「位置」「安全」），`ImplementsVerbs` → 白话动词（"固定到开始屏幕 / 从开始屏幕取消固定"）。

同时要防"**拿代码类名当用户可见标签**"：`ShellContextMenu Class`、`DfsShell Class` 是 COM 类名，菜单里根本不显示。把它们当标题比不说更糟。判据见 `looksLikeCode` 正则。

还有两条边界是实测才发现的：

- **动词表里要存"菜单项文本"，不能存句子**。`startpin` 第一版写成「把这一项固定到「开始」屏幕」，拼进 `what` 就成了「它加的是把这一项固定到「开始」屏幕」——半句话。现在表里只存 `固定到开始屏幕`，引号由拼装处加。回归断言用 `!/把这一项/.test(zh.what)` 守着。
- **不能拿占位符当名字**。无名设备的 `name` 是 `(未命名)`，直接塞进句子会写出「它现在绑定的驱动 INF 是 (未命名)」；必须回落到设备 ID（`HTREE\ROOT\0`）。

全量实测（2461 行）：`where` 为空 **168 → 0**（修前全是 drv 设备行，整张卡只有一句类别描述）；英文输出混入 CJK 引号 **67 → 0**；`what` 去重 **2207/2462**。这些数字由 `tests/run-all-manage.mjs` 里新增的 7 条单元断言守着，每条都用故意打断对应代码行验证过会变红。

---

## 4. 安全模型（两半共用）

1. **写操作默认 `dryRun: true`**。所有会改系统的路由，body 不给 `dryRun: false` 就只预演。预演返回**和真执行同构的结果**（计划、目标、将释放的字节数、将执行的命令），不是"我只是预演一下"的占位。
2. **写前备份，备份失败即中止**。注册表写之前 `reg export` 到 `%LOCALAPPDATA%\dsh-windows-toolbox\regbackup\<时间戳>-<键名>.reg`；建不出目录就不写。防火墙规则另有 `Backup-FirewallRules`（77 ms / 314 KB，免提权）。
3. **每个改动都先捕获 undo 再写**。undo 记录里 `existed: false` 表示"这键原来不存在"，回滚时删除而不是写回空值。
4. **受保护项不提供按钮**。`risk === 'blocked'` 的卡片正面显示灰色「受保护项」，不是禁用状态的按钮——避免用户以为"点了没反应"是 bug。
5. **禁用外壳扩展不删值，写空串**。`Approved` 里值为空串 = 已阻止；**值不存在 ≠ 已阻止**（只用于特定旧代码路径）。这两个语义相反，混淆会让"禁用"看起来成功而实际没生效。
6. **绝不做的事**：`Set-ExecutionPolicy`、`Invoke-Expression`/`iex`、`Format-Volume`、`Initialize-Disk`、`Remove-Partition`、`Clear-Disk`、`diskpart clean`、`reg delete` 批量、`bcdedit`、`Restart-Computer`。`tools/audit-probes.mjs` 会扫这 12 类构造，命中即 fail。

---

## 5. 权限边界（本机实测，未提权）

宿主事实：`Microsoft Windows 10 专业版 (build 19045)`，`UAC ConsentPromptBehaviorAdmin = 5`，用户 `CHEN-KETING\26035`，`elevated = false`。

| 操作 | 未提权结果 |
|---|---|
| HKCU 注册表写值 | ✅ 成功 |
| HKCU 自启项改名 | ✅ 成功 |
| `reg export` 备份 | ✅ 成功 |
| 启动文件夹改名 | ✅ 成功 |
| DNS 缓存 flush / 改 DNS（`netsh`） | ✅ 成功 |
| `Set-Service` | ❌ `拒绝访问。` |
| `Disable-ScheduledTask` | ❌ `拒绝访问。` |
| HKLM `Approved` 写值 | ❌ 拒绝 |
| 防火墙规则 `Enabled=` | ❌ `E_ACCESSDENIED 0x80070005`（规则保持原状） |
| `pnputil /delete-driver` | ❌ 需管理员 |
| DISM 任何操作 | ❌ `Error: 740` |
| `fltmc filters` | ❌ 被拒 |

因此两半的所有写路由在需要管理员时**不直接失败**，而是返回：

```json
{ "ok": false, "changed": false, "needsAdmin": true, "canElevate": true,
  "message": "该操作需要管理员权限。可在插件里点「以管理员身份重试」。" }
```

前端据此渲染「以管理员身份重试」按钮，走 `POST /api/{manage,toolbox}/elevated`：`Start-Process -Verb RunAs` 拉子进程跑 `actions.ps1`，结果写 `%TEMP%\dsh-wpm-elevated-<guid>.json` 轮询 180 s。**UAC 取消返回 `{ok:false,cancelled:true}` 且 HTTP 200，不是 500**——用户点"否"不是错误。

---

## 6. 测试

```bash
node tools/smoke-merged.mjs          # 两半都挂上了吗：13 路由 + 12 工具 + 0 个旧前缀
node tools/audit-probes.mjs          # 44 个探针：语法/param 位置/UTF-8 头/禁用 API/输出契约
node tests/run-all.mjs               # 两半全量（含真跑探针，几分钟）
node tests/run-all.mjs --unit-only   # 只跑单元
node tests/render.mjs                                  # 无头渲染 manage 半
WINDOWS_TOOLBOX_PANEL=toolbox node tests/render.mjs    # 无头渲染 toolbox 半
```

`tools/smoke-merged.mjs` 是这次合并专门的验收器。它做四件事：抓 `webServer.register()` 与 `tools.register()` 的调用、断言 13 条路由与 12 个工具都在正确的 API 前缀下、断言**旧的 `/dsh-360-toolbox/api` 与 `/dsh-windows-plugin-manager/api` 一个都没残留**（残留会静默 404）。合并时最容易犯的错就是把一个文件搬到新目录却忘了改它内部的路径常量，语法检查抓不到。

`tests/render.mjs` 用假 React 跑真实 `client.js`，能点、能展开、能切页签、能断言行内按钮出现在**折叠状态的卡片正面**。它存在的理由是：合并前所有测试都是绿的，而用户看到的是一堆"只能看不能操作"的卡片。断言必须覆盖"用户能不能点到"，不是"代码里有没有这个分支"。

---

## 7. 已知限制

- **实时防护做不到**：弹窗拦截、驱动级拦截、BadUSB 防御都需要常驻内核组件，插件生命周期是会话级的，语义上冲突（插件失败是降级，安全软件失败是失守）。相关能力只做只读态势检查，并在 UI 上明写"做不到"。
- **TRIM 之后无法恢复**：本机两块 SSD 全部 `DisableDeleteNotify = 0`，删除的文件在设备层已被清零，恢复软件扫到的是空白。`recovery` 能力只做评估并给出正确顺序（立刻停止写盘 → 另一块盘启动 → 恢复软件 → 恢复到第三块盘）。
- **SMART 读数拿不全**：本机 `Get-StorageReliabilityCounter` 抛 `AccessDenied`（提权可拿到），`MSStorageDriver_FailurePredictStatus` 实例数 0（该 WMI 只枚举 ATA/SATA，NVMe 硬件通道不支持，提权也没用）。两条 `skip` 分开写明，`smartFields` 全是 `null` 而不是 0。
- **C 盘扩容本机被卡死**：C 结束于 `324,420,992,512`，恢复分区起于 `324,421,025,792`，中间只有 **32.5 KB**。先搬恢复分区才有得谈，`expandc` 判定 `blocked-system-partition` 并说明删恢复分区会让 WinRE 失效。
- **英文界面的宿主自带名字仍是中文**：`我的文档文件夹 UI`、`安全外壳扩展` 来自本机 Windows 的中文资源，翻译的只是我们自己的框架句。这不是 bug。

---

## 8. 安装

```jsonc
// D:\Program Files (x86)\DSH_Data\profiles\desktop\package.json
"dsh-windows-toolbox": "link:E:/DSHWORK/DSH插件/dsh-windows-toolbox"
```

**分层生效**：`lib/probes/*.ps1` 与 `client.js` 改完立刻生效；`lib/*.js` 与 `index.js` **必须重启 DSH 桌面进程**。原因是 profile 是 hoisted 布局：插件更新是原地改写文件、模块 URL 不变，Node 的 ESM 缓存把后续 import 全解析到旧模块。`POST /dsh-market/toggle` 的响应里 `hot:true` 只是围着**旧模块**重建 fiber（双标记实验验证过：标记读不到）；`POST /dsh-market/restart` 在 supervisor 存在时返回 403 `self-restart is disabled for this host`。
