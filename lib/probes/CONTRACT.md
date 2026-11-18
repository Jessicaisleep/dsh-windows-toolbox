# 探针编写契约（dsh-360-toolbox）

这份文档是**唯一权威**的探针接口说明。任何新增的 `lib/probes/*.ps1` 必须严格遵守。
违反任何一条都会导致面板静默失效（不报错、但数据不上屏），历史上已经踩过其中每一条的坑。

---

## 1. 文件骨架（照抄，不要改动顺序）

```powershell
param([string]$ParamFile)

# ---------------------------------------------------------------------------
# <name>.ps1 — <一句话说明这个探针做什么>
#
# <为什么这样实现、限制了哪些行为、哪些读数需要管理员>
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList

# ... 探测逻辑，用 Add-Item 往 $items 里加行 ...

Write-ProbeResult -Items $items -Extra @{ /* 可选，自由字段 */ } -Note '可选，给用户看的一句说明'
```

### 1.1 `param(...)` 必须是脚本的第一条语句

`param` 前面**不能有任何可执行语句**，连 `[Console]::OutputEncoding = ...` 都不行。
否则 PowerShell 会把 `param` 当成一个命令名去调用，报：

```
术语 'param' 不会被识别为 cmdlet、函数、脚本文件或可执行程序的名称。
```

这条错误打到 stderr 后**脚本仍会继续执行**，而且 Node 侧的 `parseJson()` 会跳过前导噪声——
于是探针"看起来正常"，实际 `-ParamFile` 从来没绑上，参数全部丢失。本插件踩过一次，藏了很久。

### 1.2 UTF-8 那行必须有

缺了它，`[Console]::Out.Write()` 按系统代码页（zh-CN 是 936/GBK）编码，Node 按 UTF-8 解码，
所有中文变成 `�ܾ������ܱ�������`。这是最难发现的一类 bug，因为 JSON 结构完全正确。

---

## 2. 行形状（唯一）

用 `Add-Item` 添加，不要自己拼 `[ordered]@{...}`：

```powershell
Add-Item -List $items -Id 'sec:smartscreen' -Group 'security' -Label 'SmartScreen' `
    -Status 'warn' -Value '未启用' -Detail '未知来源的程序下载后不会被拦截' `
    -Fix '在 Windows 安全中心启用 SmartScreen' -NeedsAdmin $false
```

| 字段 | 类型 | 含义 |
|---|---|---|
| `id` | string | **全局唯一**，建议 `组名:具体项`。UI 的行 key 与折叠状态靠它 |
| `group` | string | 分组 id，一个探针通常只用 1-3 个分组 |
| `label` | string | 用户看到的名字，**中文**，简短（≤12 字） |
| `status` | enum | 只能是 `ok` / `warn` / `bad` / `info` / `skip` |
| `value` | string | 实测读数，**必须是真实测到的数/状态**，不能是"正常""良好" |
| `detail` | string | 这个值意味着什么，一到两句 |
| `fix` | string | 怎么改。无需处理时传空串 |
| `needsAdmin` | bool | 改这个项是否需要管理员 |

### 2.1 status 的语义（必须严格遵守）

- `ok`   —— 测到了，且在安全/正常的一侧
- `warn` —— 值得看一眼，但没坏
- `bad`  —— 确实是坏的/暴露的
- `info` —— 纯事实，没有好坏方向（版本号、路径、数量）
- `skip` —— **没测到**。`detail` 必须说明为什么（缺工具 / 需要管理员 / 找不到）

### 2.2 绝不编造

- 测不到就 `skip` + 写明原因，**不要给个猜测值**，不要写"未知"就当 `info`。
- `value` 里不要出现"可能""大概""建议"。要写就写实测数。
- 不要为了凑数生成行。一个探针返回 3 条真实的行，好过 20 条编的。

---

## 3. 工具箱函数（featurelib.ps1 已提供，直接用）

```powershell
$params = Read-ProbeParams -ParamFile $ParamFile   # 读 -ParamFile 的 JSON，返回 hashtable/PSObject
$items  = New-ProbeList                            # 新的 List[object]（已处理 return 展开问题）
Add-Item -List $items -Id ... -Group ... -Label ... -Status ... -Value ... -Detail ... -Fix ... -NeedsAdmin ...
Test-Elevated                                      # bool，当前进程是否管理员
Get-RegValue -Path 'HKCU:\...' -Name 'Foo'         # 读值，不存在返回 $null（不抛错、不 Test-Path）
Format-RegValue $v                                 # $null → 'unset'；数组 → 逗号连接；其余 → string
Write-ProbeResult -Items $items -Extra @{...} -Note '...'
```

---

## 4. 硬性安全规则（违反会破坏用户机器）

### 4.1 绝不用 `New-Item -Force` 创建注册表键

`New-Item -Path <已存在的键> -Force` 会**重建该键并丢掉它的全部值和子键**，且不报错。
本项目已经因此清空过用户真实的 `HKCU\...\Explorer\Advanced`（值从多个变成 0 个）。

正确写法：

```powershell
if ($null -eq (Get-Item -LiteralPath $r.path -ErrorAction SilentlyContinue)) {
    New-Item -Path $r.path -ErrorAction Stop | Out-Null
}
```

（`New-Item -ItemType Directory -Force` 对文件系统目录是安全的，只有注册表 provider 有破坏性。）

### 4.2 所有写操作默认 dryRun

带写能力的探针必须接受 `params.dryRun`，**缺省视为 true**，只有显式 `dryRun: false` 才真写。
dryRun 时照常返回"将要做什么"的计划，`changed = false`。

```powershell
$dryRun = -not ($params.PSObject.Properties.Name -contains 'dryRun' -and $params.dryRun -eq $false)
```

### 4.3 写之前先备份

要改注册表就先把该键 `reg export` 到
`%LOCALAPPDATA%\dsh-360-toolbox\regbackup\<时间戳>-<安全键名>.reg`。
备份失败 → **中止，不写任何东西**，返回 `backupError`。

### 4.4 绝不调用这些

- `Set-ExecutionPolicy`、`Invoke-Expression`、`iex`、下载并执行远程脚本
- `Format-Volume`、`Initialize-Disk`、`Remove-Partition`、`Clear-Disk`
- `reg delete`、`Remove-Item` 作用于非白名单路径
- `bcdedit`、`bootrec`、`diskpart clean`
- 任何 `Restart-Computer` / `Stop-Computer`

分区、磁盘、引导相关的探针**只读**。把"该怎么做"告诉用户，但不要代做。

### 4.5 只读探针不许有写路径

如果一个探针声明的行为是只读，就不要在里面出现任何写 cmdlet。
`capabilities.js` 里 `risk: 'readonly'` 的项只允许 `actions: ['scan']`。

---

## 5. 性能规则（每条都有实测依据）

- **绝不对可能不存在的注册表键用 `Test-Path`**：实测 387 ms/次。用 `Get-RegValue`（内部 `Get-ItemProperty -ErrorAction Stop` + catch，约 10 ms）。
  *文件系统* 的 `Test-Path` 很便宜（1.6 ms），可以用。
- **绝不对 OrderedDictionary 行用 `Sort-Object -Property <键>`**：静默不排序。必须用 scriptblock：
  `Sort-Object -Property { [int64]$_.bytes } -Descending`
  同理 `Measure-Object -Property <键> -Sum` 返回空，改成 `foreach` 手工累加。
- **批量读注册表按 path 去重**：119 个值逐个读 569 ms，按 67 个唯一 path 读 413 ms。
- **单点网络探测不可信**：必须多个探测点、首个成功即通过，并回传 `tried` 列表。
- **外部命令优先给硬超时**：`Get-WinEvent`、`netsh`、`winget`、`sfc` 都可能挂很久。

---

## 6. 返回值

`Write-ProbeResult` 输出：

```json
{ "ok": true, "count": 12,
  "items": [ { "id": "...", "group": "...", "label": "...", "status": "...",
               "value": "...", "detail": "...", "fix": "...", "needsAdmin": false } ],
  "summary": { "total": 12, "ok": 5, "warn": 4, "bad": 1, "info": 2, "skip": 0 },
  "elevated": false,
  "...Extra 里的字段平铺在这里": true,
  "note": "可选说明" }
```

需要额外数据（比如"总共有多少个分区"）就塞进 `-Extra`，会平铺在顶层。
**不要**自己再包一层 `{ ok: true, data: {...} }`。

---

## 7. 自测方法（提交前必须跑过）

```powershell
# 基本跑通（把 <name> 换成你的探针名）
pwsh -NoProfile -File 'E:\DSHWORK\DSH插件\dsh-360-toolbox\lib\probes\<name>.ps1' -ParamFile '<临时 json 路径>'

# 不带 ParamFile 也要能跑（面板首屏就是不带参数调）
pwsh -NoProfile -File 'E:\DSHWORK\DSH插件\dsh-360-toolbox\lib\probes\<name>.ps1'
```

自测清单：

1. 退出码 0，stdout 是**能被 `ConvertFrom-Json` 解析的单个 JSON**（stderr 有杂音不要紧）。
2. `items` 非空，每条的 `id` 互不重复。
3. 中文正常显示（不是 `��`）。
4. 不带 `-ParamFile` 也能跑通。
5. `summary` 的五个计数加起来等于 `total`。
6. 语法检查：
   ```powershell
   $e = $null
   [System.Management.Automation.Language.Parser]::ParseFile('<路径>', [ref]$null, [ref]$e) | Out-Null
   if ($e) { $e } else { 'OK' }
   ```
   （注意类型名必须写全 `System.Management.Automation.Language.Parser`，写 `[Parser]` 会得到 `$null` 然后假报 OK。）
7. 有写路径的探针：dryRun 跑一遍，确认机器上**什么都没变**。

---

## 8. 交付什么

- 只写你被指派的那个 `.ps1` 文件，**不要改** `capabilities.js` / `runner.js` / `index.js` / `client.js` / `featurelib.ps1` / 其它探针。
- 在最终答复里给出：文件路径、实测的 item 条数与耗时、每个 group 的行数、明确列出**哪些项做不到以及为什么**、以及你跑过的自测命令与读数。
