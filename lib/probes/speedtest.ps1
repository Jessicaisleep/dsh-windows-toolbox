param([string]$ParamFile)
# speedtest.ps1 - 只读网络测速探针：仅向公共测速端点发 HTTP 请求，不写任何本地状态。
# 下载 / 上传 / 延迟 三项各带 tried 列表（端点 + 耗时 + 结果）；总预算硬上限 45s，测不到即 skip。
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items  = New-ProbeList

$BudgetMs = 45000
$clock    = [System.Diagnostics.Stopwatch]::StartNew()

function Get-Budget {
    $left = $BudgetMs - $clock.ElapsedMilliseconds
    if ($left -lt 0) { return 0 }
    return [int]$left
}

function Format-Mbps {
    param([double]$Mbps)
    return ([string]::Format('{0:F2} Mbps', $Mbps))
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1073741824) { return ([string]::Format('{0:F2} GB', $Bytes / 1073741824)) }
    if ($Bytes -ge 1048576) { return ([string]::Format('{0:F1} MB', $Bytes / 1048576)) }
    if ($Bytes -ge 1024) { return ([string]::Format('{0:F1} KB', $Bytes / 1024)) }
    return "$Bytes B"
}

# 单次下载取样：计时覆盖整次请求，速率 = 实际收到字节数 * 8 / 秒。
function Measure-Download {
    param([int]$Bytes, [int]$TimeoutSec, [string]$Label)
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    $url = "https://speed.cloudflare.com/__down?bytes=$Bytes"
    $res = [pscustomobject]@{
        label = $Label; url = $url; ok = $false; gotBytes = [int64]0
        ms = 0; mbps = 0.0; error = ''
    }
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $sw.Stop()
        $res.ms = [int]$sw.ElapsedMilliseconds
        $n = [int64]0
        if ($null -ne $r.RawContentLength -and $r.RawContentLength -gt 0) { $n = [int64]$r.RawContentLength }
        elseif ($null -ne $r.Content -and $r.Content.Length -gt 0) { $n = [int64]$r.Content.Length }
        $res.gotBytes = $n
        if ($res.ms -gt 0 -and $n -gt 0) {
            $res.mbps = [math]::Round(($n * 8.0) / ($res.ms / 1000.0) / 1000000.0, 2)
            $res.ok   = $true
        }
        else {
            $res.error = '未取到字节数或计时为 0'
        }
    }
    catch {
        $sw.Stop()
        $res.ms    = [int]$sw.ElapsedMilliseconds
        $res.error = $_.Exception.Message
    }
    # 释放响应对象，避免连接被占住
    $r = $null
    return $res
}

# 单次上传取样：POST 随机字节到 __up，速率按请求体字节数计。
function Measure-Upload {
    param([int]$Bytes, [int]$TimeoutSec, [string]$Label)
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $url  = 'https://speed.cloudflare.com/__up'
    $res  = [pscustomobject]@{
        label = $Label; url = $url; ok = $false; sentBytes = [int64]$Bytes
        ms = 0; mbps = 0.0; error = ''
    }
    try {
        $body = [byte[]]::new($Bytes)
        $rnd  = [System.Random]::new(20261117)
        $rnd.NextBytes($body)
        $r = Invoke-WebRequest -Uri $url -Method Post -Body $body -ContentType 'application/octet-stream' `
            -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $sw.Stop()
        $res.ms = [int]$sw.ElapsedMilliseconds
        if ($res.ms -gt 0) {
            $res.mbps = [math]::Round(($Bytes * 8.0) / ($res.ms / 1000.0) / 1000000.0, 2)
            $res.ok   = $true
        }
        else { $res.error = '计时为 0' }
    }
    catch {
        $sw.Stop()
        $res.ms    = [int]$sw.ElapsedMilliseconds
        $res.error = $_.Exception.Message
    }
    $body = $null
    $r    = $null
    return $res
}

# 延迟：复用同一条 TLS 连接，量的是真实 RTT（Invoke-WebRequest 每次重连会虚高到 ~700ms）。
function Measure-LatencyHttp {
    param([int]$Samples, [int]$PerTimeoutMs, [string]$Url, [string]$Mode)
    $out = [pscustomobject]@{
        ok = $false; samples = @(); medianMs = 0; jitterMs = 0; stdMs = 0
        error = ''; mode = $Mode
    }
    $client = $null
    try {
        $handler          = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $client           = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout   = [TimeSpan]::FromMilliseconds($PerTimeoutMs)
        $null = $client.GetAsync($Url).GetAwaiter().GetResult()   # 建连 + 预热，不计入样本
        $list = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $Samples; $i++) {
            if ((Get-Budget) -lt ($PerTimeoutMs + 500)) { break }
            $t    = [System.Diagnostics.Stopwatch]::StartNew()
            $resp = $client.GetAsync($Url).GetAwaiter().GetResult()
            $null = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $t.Stop()
            [void]$list.Add([int]$t.ElapsedMilliseconds)
        }
        if ($list.Count -gt 0) {
            $ordered = $list | Sort-Object
            $n       = $ordered.Count
            if ($n % 2 -eq 1) { $median = [double]$ordered[[int](($n - 1) / 2)] }
            else { $median = ([double]$ordered[$n / 2 - 1] + [double]$ordered[$n / 2]) / 2.0 }
            $max = [double]$ordered[$n - 1]
            $min = [double]$ordered[0]
            $sum = 0.0
            foreach ($v in $ordered) { $sum += [double]$v }
            $mean = $sum / $n
            $sq = 0.0
            foreach ($v in $ordered) { $sq += ([double]$v - $mean) * ([double]$v - $mean) }
            $out.samples  = @($ordered)
            $out.medianMs = [int][math]::Round($median)
            $out.jitterMs = [int][math]::Round($max - $min)
            $out.stdMs    = [int][math]::Round([math]::Sqrt($sq / $n))
            $out.ok       = $true
        }
        else {
            $out.error = '预算耗尽，未取到样本'
        }
    }
    catch {
        $out.error = $_.Exception.Message
    }
    if ($null -ne $client) { $client.Dispose() }
    return $out
}

# 回退端点：只测延迟，不测速率（baidu 首页不适合做吞吐取样）。
function Measure-LatencySimple {
    param([int]$Samples, [int]$TimeoutSec, [string]$Url)
    $out = [pscustomobject]@{ ok = $false; samples = @(); medianMs = 0; jitterMs = 0; error = ''; mode = 'Invoke-WebRequest（新建连接）' }
    $list = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Samples; $i++) {
        if ((Get-Budget) -lt 2500) { break }
        $t = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
            $t.Stop()
            [void]$list.Add([int]$t.ElapsedMilliseconds)
        }
        catch { $t.Stop() }
    }
    if ($list.Count -gt 0) {
        $ordered = $list | Sort-Object
        $n = $ordered.Count
        if ($n % 2 -eq 1) { $median = [double]$ordered[[int](($n - 1) / 2)] }
        else { $median = ([double]$ordered[$n / 2 - 1] + [double]$ordered[$n / 2]) / 2.0 }
        $out.samples  = @($ordered)
        $out.medianMs = [int][math]::Round($median)
        $out.jitterMs = [int]([double]$ordered[$n - 1] - [double]$ordered[0])
        $out.ok       = $true
    }
    else {
        $out.error = '回退端点亦不可达'
    }
    return $out
}

# ---------- 1) 延迟 ----------
$latUrl      = 'https://speed.cloudflare.com/__down?bytes=0'
$lat          = Measure-LatencyHttp -Samples 5 -PerTimeoutMs 6000 -Url $latUrl -Mode 'HttpClient 复用连接'
$fallbackUsed = $false
$baidu        = $null

if (-not $lat.ok) {
    $baidu        = Measure-LatencySimple -Samples 3 -TimeoutSec 8 -Url 'https://www.baidu.com/'
    $fallbackUsed = $true
}

$triedLat = @(
    "Cloudflare __down?bytes=0 [HttpClient 复用] $($lat.samples.Count) 次: " +
        $(if ($lat.samples.Count -gt 0) { ($lat.samples -join ',') + " ms" } else { '无样本' }) +
        " => $(if ($lat.ok) { "中位 $($lat.medianMs) ms" } else { "失败: $($lat.error)" })"
)
if ($fallbackUsed) {
    $triedLat += "www.baidu.com [Invoke-WebRequest] $($baidu.samples.Count) 次: " +
        $(if ($baidu.samples.Count -gt 0) { ($baidu.samples -join ',') + " ms" } else { '无样本' }) +
        " => $(if ($baidu.ok) { "中位 $($baidu.medianMs) ms（回退，仅延迟）" } else { "失败: $($baidu.error)" })"
}

if ($lat.ok) {
    $latStatus = $(if ($lat.medianMs -gt 300) { 'warn' } elseif ($lat.medianMs -gt 150) { 'ok' } else { 'ok' })
    Add-Item -List $items -Id 'speedtest:latency' -Group '网络' -Label '延迟（Cloudflare 中位 RTT）' `
        -Status $latStatus -Value "$($lat.medianMs) ms" `
        -Detail ("样本 $($lat.samples.Count) 次: " + ($lat.samples -join ',') + " ms；中位 $($lat.medianMs) ms；抖动(max-min) $($lat.jitterMs) ms；标准差 $($lat.stdMs) ms；测法 $($lat.mode)`n" + ($triedLat -join "`n")) `
        -Fix '延迟偏高先查本地网关与 DNS 解析，再测是否只有国际链路慢（对照 www.baidu.com 延迟）' -NeedsAdmin $false
}
elseif ($null -ne $baidu -and $baidu.ok) {
    Add-Item -List $items -Id 'speedtest:latency' -Group '网络' -Label '延迟（回退 www.baidu.com 中位 RTT）' `
        -Status 'warn' -Value "$($baidu.medianMs) ms" `
        -Detail ("Cloudflare 延迟不可测（$($lat.error)），改用国内回退端点 www.baidu.com（仅延迟，不代表国际链路，且每次新建连接会偏高）`n" + ($triedLat -join "`n")) `
        -Fix 'Cloudflare 端点不可达时，本地网络可能只有国内连通性；国际出口需另行用代理/路由排查' -NeedsAdmin $false
}
else {
    Add-Item -List $items -Id 'speedtest:latency' -Group '网络' -Label '延迟' -Status 'skip' -Value '未测量' `
        -Detail ("Cloudflare 与 www.baidu.com 均不可达，跳过延迟测量（不编造数值）`n" + ($triedLat -join "`n")) `
        -Fix '确认本机能否正常上网；若使用代理，代理可能拦截了测速端点' -NeedsAdmin $false
}

# ---------- 2) 下载速率 ----------
$dlResults = New-Object System.Collections.ArrayList
$dlPlan    = @(
    @{ bytes = 1000000; label = '1MB 热身' },
    @{ bytes = 5000000; label = '5MB 正式' }
)

foreach ($p in $dlPlan) {
    $left = Get-Budget
    if ($left -lt 5000) { break }
    $to = [int][math]::Floor($left / 1000)
    if ($to -gt 25) { $to = 25 }
    $r = Measure-Download -Bytes $p.bytes -TimeoutSec $to -Label $p.label
    [void]$dlResults.Add($r)
}

$dlOk      = @($dlResults | Where-Object { $_.ok })
$dlBest    = $null
$dlTried   = New-Object System.Collections.ArrayList
foreach ($r in $dlResults) {
    if ($r.ok) {
        [void]$dlTried.Add("$($r.label) $($r.url): $(Format-Bytes $r.gotBytes) / $($r.ms) ms => $(Format-Mbps $r.mbps)")
    }
    else {
        [void]$dlTried.Add("$($r.label) $($r.url): 失败 $($r.ms) ms => $($r.error)")
    }
    if ($null -eq $dlBest -or ($r.ok -and $r.mbps -gt $dlBest.mbps)) {
        if ($r.ok) { $dlBest = $r }
    }
}

if ($null -ne $dlBest) {
    $dlStatus = $(if ($dlBest.mbps -lt 5) { 'warn' } elseif ($dlBest.mbps -lt 20) { 'ok' } else { 'ok' })
    $spread = ''
    if ($dlOk.Count -gt 1) {
        $mbpsList = @($dlOk | ForEach-Object { [double]$_.mbps })
        $spread   = "；多次取样 " + ($mbpsList -join ' / ') + " Mbps（取较快的一次）"
    }
    Add-Item -List $items -Id 'speedtest:download' -Group '网络' -Label '下载速率（取较快样本）' `
        -Status $dlStatus -Value (Format-Mbps $dlBest.mbps) `
        -Detail ("最佳样本 $($dlBest.label)：$(Format-Bytes $dlBest.gotBytes) / $($dlBest.ms) ms$spread`n" + ($dlTried -join "`n")) `
        -Fix '速率低于预期时优先用有线千兆网口复测，排除 Wi-Fi 与同网段占用' -NeedsAdmin $false
}
else {
    Add-Item -List $items -Id 'speedtest:download' -Group '网络' -Label '下载速率' -Status 'skip' -Value '未测量' `
        -Detail ("Cloudflare __down 取样全部失败，跳过下载速率（不编造数值）`n" + ($dlTried -join "`n")) `
        -Fix '确认能否访问 speed.cloudflare.com；企业代理/防火墙可能拦截该域名' -NeedsAdmin $false
}

# ---------- 3) 上传速率 ----------
$upBytes = $(if ((Get-Budget) -gt 15000) { 2097152 } else { 1048576 })
$up      = $null
if ($null -ne $dlBest -and (Get-Budget) -gt 6000) {
    $left = Get-Budget
    $to   = [int][math]::Floor(($left - 1000) / 1000)
    if ($to -gt 30) { $to = 30 }
    if ($to -lt 5) { $to = 5 }
    $up = Measure-Upload -Bytes $upBytes -TimeoutSec $to -Label (Format-Bytes $upBytes)
}

if ($null -ne $up -and $up.ok) {
    $upStatus = $(if ($up.mbps -lt 2) { 'warn' } else { 'ok' })
    Add-Item -List $items -Id 'speedtest:upload' -Group '网络' -Label '上传速率' `
        -Status $upStatus -Value (Format-Mbps $up.mbps) `
        -Detail ("POST $($up.url) 请求体 $(Format-Bytes $up.sentBytes) / $($up.ms) ms => $(Format-Mbps $up.mbps)") `
        -Fix '上传低通常受宽带上行套餐限制；对比运营商签约上行速率是否一致' -NeedsAdmin $false
}
else {
    $reason = '下载未通过，按顺序跳过上传测量以节省预算'
    if ($null -ne $up -and $up.error) { $reason = "上传取样失败: $($up.error)" }
    Add-Item -List $items -Id 'speedtest:upload' -Group '网络' -Label '上传速率' -Status 'skip' -Value '未测量' `
        -Detail "$reason（不编造数值）" `
        -Fix '若需上传数据，确认 speed.cloudflare.com/__up 可达且代理允许 POST' -NeedsAdmin $false
}

# ---------- 4) 端点可达性汇总 ----------
# 注意：不能用 -match '可用$' 统计可用项 —— '不可用' 也以「可用」结尾，会把失败项算成可用。
# 用显式布尔数组，避免任何字符串后缀匹配。
$okFlags       = New-Object System.Collections.ArrayList
$endpointParts = New-Object System.Collections.ArrayList

$latOk  = [bool]$lat.ok
$dlFlag = ($null -ne $dlBest)
$ulFlag = ($null -ne $up -and $up.ok)
[void]$okFlags.Add($latOk);  [void]$endpointParts.Add($(if ($latOk)  { 'Cloudflare 延迟=可用' } else { 'Cloudflare 延迟=不可用' }))
[void]$okFlags.Add($dlFlag); [void]$endpointParts.Add($(if ($dlFlag) { 'Cloudflare 下载=可用' } else { 'Cloudflare 下载=不可用' }))
[void]$okFlags.Add($ulFlag); [void]$endpointParts.Add($(if ($ulFlag) { 'Cloudflare 上传=可用' } else { 'Cloudflare 上传=不可用' }))
if ($fallbackUsed) {
    $bdFlag = ($null -ne $baidu -and $baidu.ok)
    [void]$okFlags.Add($bdFlag)
    [void]$endpointParts.Add($(if ($bdFlag) { 'www.baidu.com 延迟=可用' } else { 'www.baidu.com 延迟=不可用' }))
}

$okCount = 0
foreach ($f in $okFlags) { if ($f) { $okCount++ } }
$epTotal = $okFlags.Count

$epStatus = $(if ($dlFlag -and $latOk -and $ulFlag) { 'ok' } elseif ($dlFlag -or $latOk -or $ulFlag) { 'warn' } else { 'bad' })
Add-Item -List $items -Id 'speedtest:endpoints' -Group '网络' -Label '测速端点可达性' `
    -Status $epStatus -Value ("$okCount 项可用 / $epTotal 项") `
    -Detail (@(
        '主端点 speed.cloudflare.com（__down 下载 / __up 上传 / bytes=0 延迟）'
        '回退端点 www.baidu.com（仅延迟，不测吞吐）'
        '已剔除已知不可用端点: cachefly.cachefly.net、speedtest.tokyo.linode.com（避免无效重试）'
        ($endpointParts -join '；')
    ) -join "`n") `
    -Fix '端点整体不可达时先确认代理设置与 DNS；国内网络访问 Cloudflare 测速端点可能不稳定' -NeedsAdmin $false

# ---------- 5) 预算 ----------
$elapsedMs = [int]$clock.ElapsedMilliseconds
$budgetStatus = $(if ($elapsedMs -ge $BudgetMs) { 'warn' } else { 'info' })
Add-Item -List $items -Id 'speedtest:budget' -Group '网络' -Label '探针耗时 / 预算' `
    -Status $budgetStatus -Value ("$([math]::Round($elapsedMs / 1000.0, 1)) s / $([math]::Round($BudgetMs / 1000.0, 1)) s") `
    -Detail ("总预算硬上限 $BudgetMs ms；实际耗时 $elapsedMs ms；剩余 $([math]::Max(0, $BudgetMs - $elapsedMs)) ms。" +
        "每个取样点在开跑前检查剩余预算，不足即停并回传已取到的样本。") `
    -Fix '' -NeedsAdmin $false

$extra = @{
    budgetMs      = $BudgetMs
    elapsedMs     = $elapsedMs
    downloadMbps  = $([double]$(if ($null -ne $dlBest) { $dlBest.mbps } else { 0 }))
    downloadBytes = $([int64]$(if ($null -ne $dlBest) { $dlBest.gotBytes } else { 0 }))
    uploadMbps    = $([double]$(if ($null -ne $up -and $up.ok) { $up.mbps } else { 0 }))
    latencyMs     = $([int]$(if ($lat.ok) { $lat.medianMs } elseif ($null -ne $baidu -and $baidu.ok) { $baidu.medianMs } else { 0 }))
    jitterMs      = $([int]$(if ($lat.ok) { $lat.jitterMs } elseif ($null -ne $baidu -and $baidu.ok) { $baidu.jitterMs } else { 0 }))
    latencySource = $(if ($lat.ok) { 'speed.cloudflare.com' } elseif ($null -ne $baidu -and $baidu.ok) { 'www.baidu.com' } else { 'none' })
    fallbackUsed  = $fallbackUsed
    endpoints     = @(@{
        name      = 'speed.cloudflare.com'
        latency   = $(if ($lat.ok) { 'ok' } else { 'fail' })
        download  = $(if ($null -ne $dlBest) { 'ok' } else { 'fail' })
        upload    = $(if ($null -ne $up -and $up.ok) { 'ok' } else { 'fail' })
        tried     = @($dlTried)
    } | ForEach-Object { $_ })
}

Write-ProbeResult -Items $items -Extra $extra -Note (
    '只读探针：仅向公共测速端点发起 HTTP GET/POST，不写本地文件、不改配置。' +
    '速率取样单位 Mbps = 字节*8/秒/1e6；延迟为复用连接的 TLS 往返（中位）。' +
    '本机实测网络波动较大，单次结果仅供参考，建议连跑 2-3 次看区间。'
)
