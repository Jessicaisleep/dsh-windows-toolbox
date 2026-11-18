param([string]$ParamFile, [string]$Action = '', [object]$DryRun = $null)

# ---------------------------------------------------------------------------
# netdiag.ps1 — network diagnostics ("断网急救箱") + optional repair actions.
#
# Answers, in order of how far the machine actually got: is there a link, did
# DHCP hand out a lease, is the gateway reachable, does DNS resolve, does the
# internet answer, and is a proxy silently eating the traffic. The first "no"
# in that chain is the actual fault — which is why each step is reported
# separately instead of being collapsed into one "network is down".
#
# action='scan' (default) is strictly read-only: no adapter is reset, no DNS
# cache flushed, no lease renewed. It is byte-for-byte the behaviour the panel
# and tests relied on before repair existed, and it must stay that way.
#
# action='repair' is the 断网急救箱: seven independently selectable fixes.
#   * dryRun DEFAULTS TO TRUE — without an explicit dryRun:false nothing is
#     executed, only the plan (command / current state / risk) is returned.
#   * Admin-required fixes on a non-elevated host never throw and never hang:
#     they come back as needsAdmin:true with the full command string.
#   * Every external command has a hard timeout; a timeout is reported as
#     "未完成", never as success.
#   * Any registry write is preceded by `reg export` into
#     %LOCALAPPDATA%\dsh-windows-toolbox\regbackup\ and aborts if the backup fails.
#   * Every executed fix is re-measured and the before/after readings are both
#     returned. Nothing is claimed "fixed" on the strength of an exit code.
#
# UTF-8 on stdout (PowerShell otherwise emits the OEM code page and the Node
# side reads mojibake).
#
# NOTE: `param` must stay the first statement — if anything executable precedes
# it, PowerShell treats `param` as a command name, prints a term-not-recognized
# error to stderr, and keeps going with no parameters bound at all.
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'

$params = @{}
if ($ParamFile -and (Test-Path -LiteralPath $ParamFile)) {
    $raw = Get-Content -LiteralPath $ParamFile -Raw -Encoding UTF8
    if ($raw) { $params = $raw | ConvertFrom-Json }
}

# Read one key from the parameter bag without assuming its shape: an empty
# -ParamFile leaves a hashtable, ConvertFrom-Json leaves a PSCustomObject.
function Get-ParamRaw {
    param($Bag, [string]$Name)
    if ($null -eq $Bag) { return $null }
    if ($Bag -is [System.Collections.IDictionary]) {
        if ($Bag.Contains($Name)) { return $Bag[$Name] }
        return $null
    }
    $p = $Bag.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# ---- shared helpers (used by the repair branch only) -----------------------

function Test-AdminLocal {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Quote one argv element for ProcessStartInfo.Arguments. PS 5.1 has no
# .ArgumentList, so the string has to be built by hand — and always from a real
# argument array, never by splicing a command line together.
function Quote-Arg {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '"', '\"') + '"'
}

# Run one external command with a hard timeout. Returns a row, never throws:
# a timeout is a real result ("timed out after Nms"), not an exception.
function Invoke-External {
    param(
        [string]$Exe,
        [string[]]$ArgList,
        [int]$TimeoutMs = 20000
    )
    $res = [ordered]@{
        command  = ((Split-Path -Leaf $Exe) + ' ' + (($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' ')).Trim()
        exe      = $Exe
        args     = @($ArgList)
        exitCode = -1
        timedOut = $false
        output   = ''
        error    = ''
        ms       = 0
    }
    if (-not (Test-Path -LiteralPath $Exe)) {
        $res.error = "找不到可执行文件: $Exe"
        return $res
    }
    if ($TimeoutMs -lt 1000) { $TimeoutMs = 1000 }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $env:TEMP
    # ipconfig / netsh / reg are console tools and write their output in the
    # OEM code page (936 here). Without this the pipe decodes them as UTF-8 and
    # every Chinese line comes back as mojibake — the exact same trap the
    # process-level [Console]::OutputEncoding assignment solves for our own
    # stdout, but it does not propagate into a redirected child.
    try {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        $psi.StandardErrorEncoding = $psi.StandardOutputEncoding
    } catch { }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $res.error = $_.Exception.Message
        $res.ms = [int]$sw.ElapsedMilliseconds
        return $res
    }
    # Read both pipes asynchronously; a synchronous ReadToEnd before
    # WaitForExit can deadlock when the child fills its buffer.
    $oTask = $proc.StandardOutput.ReadToEndAsync()
    $eTask = $proc.StandardError.ReadToEndAsync()
    $finished = $proc.WaitForExit($TimeoutMs)
    if (-not $finished) {
        $res.timedOut = $true
        # Kill($true) only exists on .NET Core; PS 5.1 has the parameterless one.
        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
        try { [void]$proc.WaitForExit(3000) } catch { }
    } else {
        $proc.WaitForExit()
    }
    try { if ($oTask.Wait(3000)) { $res.output = [string]$oTask.Result } } catch { }
    try { if ($eTask.Wait(3000)) { $res.error = [string]$eTask.Result } } catch { }
    try { if (-not $res.timedOut) { $res.exitCode = $proc.ExitCode } } catch { }
    try { $proc.Dispose() } catch { }
    $res.ms = [int]$sw.ElapsedMilliseconds
    # Keep the row small enough for one JSON document; stderr carries the
    # interesting part of a netsh refusal.
    if ($res.output.Length -gt 2000) { $res.output = $res.output.Substring(0, 2000) }
    if ($res.error.Length -gt 2000) { $res.error = $res.error.Substring(0, 2000) }
    return $res
}

# Run a PowerShell cmdlet in a child runspace with a hard timeout. Used for
# Restart-NetAdapter: it is a cmdlet, not an exe, and it can block for as long
# as the driver takes. Building a `pwsh -Command "<string>"` line instead would
# mean splicing the adapter name into a command string, which this plugin does
# not do.
function Invoke-CmdletTimeout {
    param(
        [string]$CommandName,
        [hashtable]$Parameters = @{},
        [int]$TimeoutMs = 45000
    )
    $res = [ordered]@{ command = $CommandName; timedOut = $false; ok = $false; error = ''; output = ''; ms = 0 }
    if ($TimeoutMs -lt 1000) { $TimeoutMs = 1000 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ps = $null
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddCommand($CommandName)
        foreach ($k in @($Parameters.Keys)) { [void]$ps.AddParameter($k, $Parameters[$k]) }
        $handle = $ps.BeginInvoke()
        if ($handle.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $objs = $ps.EndInvoke($handle)
            $res.ok = ($ps.Streams.Error.Count -eq 0)
            if ($ps.Streams.Error.Count -gt 0) { $res.error = [string]$ps.Streams.Error[0] }
            $res.output = (@($objs | ForEach-Object { [string]$_ }) -join ' ').Trim()
        } else {
            $res.timedOut = $true
            try { $ps.Stop() } catch { }
        }
    } catch {
        $res.error = $_.Exception.Message
    } finally {
        if ($ps) { try { $ps.Dispose() } catch { } }
    }
    $res.ms = [int]$sw.ElapsedMilliseconds
    return $res
}

function Get-DnsCacheCount {
    return @(Get-DnsClientCache -ErrorAction SilentlyContinue).Count
}

# The adapter a fix should target: first Up non-virtual one, else first Up.
# Virtual adapters (VPN/WSL/Hyper-V) are skipped for the same reason the scan
# marks them: resetting one fixes nothing and drops a working tunnel.
function Get-PrimaryAdapter {
    $all = @(Get-NetAdapter -ErrorAction SilentlyContinue)
    $virtualPattern = 'Virtual|Hyper-V|VMware|VirtualBox|TAP|WireGuard|Tailscale|Loopback'
    foreach ($a in $all) {
        if ([string]$a.Status -ne 'Up') { continue }
        if ($a.InterfaceDescription -match $virtualPattern) { continue }
        return $a
    }
    foreach ($a in $all) { if ([string]$a.Status -eq 'Up') { return $a } }
    return $null
}

function Get-IpSnapshot {
    param([string]$Alias = '')
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
        if ($Alias -and [string]$c.InterfaceAlias -ne $Alias) { continue }
        $rows.Add([ordered]@{
            alias     = [string]$c.InterfaceAlias
            addresses = @($c.IPv4Address | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
            gateways  = @($c.IPv4DefaultGateway | Where-Object { $_.NextHop } | ForEach-Object { $_.NextHop })
            dhcp      = [string]$c.NetIPv4Interface.Dhcp
        })
    }
    return , $rows
}

function Get-IeProxyState {
    $iePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $row = [ordered]@{ enabled = $false; proxyEnable = 'unset'; server = ''; override = ''; autoConfig = '' }
    try {
        $p = Get-ItemProperty -LiteralPath $iePath -ErrorAction Stop
        $row.proxyEnable = if ($null -eq $p.ProxyEnable) { 'unset' } else { [string]([int]$p.ProxyEnable) }
        $row.enabled = ([string]$row.proxyEnable -eq '1')
        $row.server = [string]$p.ProxyServer
        $row.override = [string]$p.ProxyOverride
        $row.autoConfig = [string]$p.AutoConfigURL
    } catch { }
    return $row
}

function Get-WinhttpState {
    $exe = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $r = Invoke-External -Exe $exe -ArgList @('winhttp', 'show', 'proxy') -TimeoutMs 15000
    $text = (($r.output + "`n" + $r.error) -replace '\s+', ' ').Trim()
    $row = [ordered]@{ text = $text; direct = ($text -match '直接访问|Direct access|没有代理服务器') }
    return $row
}

# ---------------------------------------------------------------------------
# WiFi / DNS helpers — shared by scan (wifi:信号, dns:优选) and dnspick.
# ---------------------------------------------------------------------------

# Public resolvers worth ranking. Every one is queried with the SAME name,
# because the comparison decides whether the user is told to switch DNS: mixing
# names would fold domain-dependent jitter into a number that drives advice.
$DnsCandidates = @(
    @{ ip = '223.5.5.5'; label = '阿里 DNS' }
    @{ ip = '119.29.29.29'; label = '腾讯 DNS' }
    @{ ip = '1.1.1.1'; label = 'Cloudflare' }
    @{ ip = '8.8.8.8'; label = 'Google DNS' }
    @{ ip = '114.114.114.114'; label = '114 DNS' }
)
$DnsProbeName = 'www.baidu.com'

# Runspaces whose query was cut off by the timeout. They are never Stop()'d or
# disposed — see the comment inside Invoke-DnsProbe — so a reference is kept
# here to stop the GC from finalizing them mid-flight. The process is short
# lived, so this list dies with it.
$script:AbandonedDnsRunspaces = [System.Collections.Generic.List[object]]::new()

function Get-ParamKeys {
    param($Bag)
    if ($null -eq $Bag) { return @() }
    if ($Bag -is [System.Collections.IDictionary]) { return @($Bag.Keys) }
    return @($Bag.PSObject.Properties | ForEach-Object { $_.Name })
}

# Resolve one name against ONE server, with a hard timeout.
#
# Resolve-DnsName's own -QuickTimeout is not a hard cap: against an unreachable
# server (10.255.255.1) it sat for 7.0-7.4 s before throwing. Six measurements
# have to fit in a 10 s budget, so the query runs in a child runspace and this
# thread simply stops waiting.
#
# The runspace is then ABANDONED, not stopped. Measured on this machine: once a
# query has been cut off, both $ps.Stop() and $ps.Dispose() block for another
# ~10.9 s waiting for the pipeline to finish — which would blow the budget far
# worse than the timeout itself and made a 1500 ms cap report 12140 ms. Only a
# runspace that completed normally is disposed. The abandoned ones are kept
# referenced (see $script:AbandonedDnsRunspaces) so the GC does not finalize
# them while still running; they end when the process exits.
#   -Server '' means "whatever this machine is configured to use".
function Invoke-DnsProbe {
    param(
        [string]$Server = '',
        [string]$Name = 'www.baidu.com',
        [int]$TimeoutMs = 1500
    )
    $res = [ordered]@{ server = $Server; name = $Name; ok = $false; timedOut = $false; ms = 0; error = ''; ips = @() }
    if ($TimeoutMs -lt 500) { $TimeoutMs = 500 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ps = $null
    $abandon = $false
    try {
        $ps = [powershell]::Create()
        [void]$ps.AddCommand('Resolve-DnsName')
        [void]$ps.AddParameter('Name', $Name)
        [void]$ps.AddParameter('Type', 'A')
        [void]$ps.AddParameter('DnsOnly', $true)
        if ($Server) { [void]$ps.AddParameter('Server', $Server) }
        # Timed from BeginInvoke so runspace construction is not billed to the
        # server being measured.
        $handle = $ps.BeginInvoke()
        if ($handle.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $objs = $ps.EndInvoke($handle)
            # The first record of a Resolve-DnsName result set is often a PTR
            # row without IPAddress, so "any record" is not the success test.
            $res.ips = @($objs | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
            $res.ok = ($res.ips.Count -gt 0)
            if (-not $res.ok) {
                if ($ps.Streams.Error.Count -gt 0) { $res.error = [string]$ps.Streams.Error[0] }
                else { $res.error = '查询没有返回 A 记录' }
            }
        } else {
            $res.timedOut = $true
            $res.error = "超过 $TimeoutMs ms 未返回"
            $abandon = $true
        }
    } catch {
        $res.error = $_.Exception.Message
    } finally {
        if ($ps) {
            if ($abandon) {
                try { $script:AbandonedDnsRunspaces.Add($ps) } catch { }
            } else {
                try { $ps.Dispose() } catch { }
            }
        }
    }
    # The stopwatch is read after the runspace is parked, and parking is
    # instant, so ms reflects the query, not the cleanup.
    $res.ms = [int]$sw.ElapsedMilliseconds
    return $res
}

# netsh wlan field labels: English on this build, localized on others.
function ConvertFrom-WlanFieldName {
    param([string]$Key)
    $k = (($Key.Trim().ToLowerInvariant()) -replace '\s+', ' ')
    if ($k -eq 'name' -or $k -eq '名称') { return 'name' }
    if ($k -eq 'description' -or $k -eq '描述') { return 'description' }
    if ($k -eq 'state' -or $k -eq '状态') { return 'state' }
    if ($k -eq 'ssid') { return 'ssid' }
    if ($k -eq 'bssid') { return 'bssid' }
    if ($k -match '^radio type' -or $k -match '^无线电类型') { return 'radioType' }
    if ($k -eq 'channel' -or $k -eq '信道') { return 'channel' }
    if ($k -match '^receive rate' -or $k -match '^接收速率') { return 'receiveRate' }
    if ($k -match '^transmit rate' -or $k -match '^传输速率' -or $k -match '^发送速率') { return 'transmitRate' }
    if ($k -eq 'signal' -or $k -match '^信号') { return 'signal' }
    if ($k -eq 'profile' -or $k -eq '配置文件') { return 'profile' }
    if ($k -match '^authentication' -or $k -match '^身份验证') { return 'auth' }
    return ''
}

# Parse `netsh wlan show interfaces` into one row per radio.
# Read-only query, but a console tool with no timeout of its own: a wedged WLAN
# AutoConfig service makes it hang, hence the 5 s cap through Invoke-External.
function Get-WlanInterfaces {
    $out = [ordered]@{ interfaces = @(); available = $false; timedOut = $false; error = ''; ms = 0 }
    $netshExe = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $r = Invoke-External -Exe $netshExe -ArgList @('wlan', 'show', 'interfaces') -TimeoutMs 5000
    $out.ms = $r.ms
    if ($r.timedOut) {
        $out.timedOut = $true
        $out.error = "netsh wlan show interfaces 在 $($r.ms) ms 内没有返回（超时）"
        return $out
    }
    $text = ([string]$r.output + "`n" + [string]$r.error)
    $list = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($line in @($text -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        # "Key: value". Values routinely carry trailing spaces ("Signal: 88% "),
        # and some builds emit a full-width colon.
        if ($line -notmatch '^\s*([^:：]{1,60}?)\s*[:：]\s*(.*)$') { continue }
        $value = $matches[2].Trim()
        $field = ConvertFrom-WlanFieldName $matches[1]
        if (-not $field) { continue }
        if ($field -eq 'name') {
            if ($cur) { $list.Add($cur) }
            $cur = [ordered]@{
                name = $value; description = ''; state = ''; ssid = ''; bssid = ''
                radioType = ''; channel = ''; receiveRate = ''; transmitRate = ''
                signal = ''; signalPercent = $null; profile = ''; auth = ''
                connected = $false
            }
            continue
        }
        if (-not $cur) { continue }
        if ($field -eq 'state') {
            $cur.state = $value
            $cur.connected = ($value -match '^(connected|已连接)$')
        } elseif ($field -eq 'signal') {
            $cur.signal = $value
            # No "N%" -> leave the percentage unknown rather than reporting 0%.
            if ($value -match '(\d+)\s*%') { $cur.signalPercent = [int]$matches[1] }
        } else {
            $cur.$field = $value
        }
    }
    if ($cur) { $list.Add($cur) }
    $out.interfaces = @($list)
    $out.available = ($list.Count -gt 0)
    if ($list.Count -eq 0) {
        $trimmed = (($text -replace '\s+', ' ').Trim())
        if ($trimmed.Length -gt 0) { $out.error = $trimmed }
    }
    return $out
}

function Format-WifiRate {
    param([string]$Raw)
    if (-not $Raw) { return '' }
    $d = 0.0
    if ([double]::TryParse($Raw, [ref]$d)) {
        return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.#}', $d)
    }
    return $Raw
}

# One connected radio in the shape the task asks for:
# "SSID=Chen 信号=75% 频段/信道=802.11ax/48 收=138Mbps 发=1729Mbps"
function Format-WlanRow {
    param($W)
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($W.ssid) { $parts.Add("SSID=$($W.ssid)") }
    if ($W.signal) { $parts.Add("信号=$($W.signal)") }
    $radio = if ($W.radioType) { [string]$W.radioType } else { '?' }
    $chan = if ($W.channel) { [string]$W.channel } else { '?' }
    $parts.Add("频段/信道=$radio/$chan")
    $rx = Format-WifiRate $W.receiveRate
    $tx = Format-WifiRate $W.transmitRate
    if ($rx) { $parts.Add("收=${rx}Mbps") }
    if ($tx) { $parts.Add("发=${tx}Mbps") }
    return ($parts -join ' ')
}

# Receive 138 / transmit 1729 is not cosmetic: it means the driver or the AP
# negotiated one direction badly. Say it out loud instead of printing two
# numbers and letting the user assume they are fine.
function Get-WlanAsymmetryNote {
    param($W)
    $rx = 0.0
    $tx = 0.0
    if (-not [double]::TryParse([string]$W.receiveRate, [ref]$rx)) { return '' }
    if (-not [double]::TryParse([string]$W.transmitRate, [ref]$tx)) { return '' }
    if ($rx -le 0 -or $tx -le 0) { return '' }
    $ratio = [math]::Max($tx / $rx, $rx / $tx)
    if ($ratio -lt 3) { return '' }
    $who = if ($tx -gt $rx) { '发送远高于接收' } else { '接收远高于发送' }
    $num = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.#}', $ratio)
    return "收 ${rx}Mbps / 发 ${tx}Mbps 相差约 $num 倍（$who），可能是驱动或协商异常（省电模式、干扰、或驱动把速率协商错了）"
}

# ---------------------------------------------------------------------------
# repair branch
# ---------------------------------------------------------------------------
$act = $Action
if (-not $act) { $act = [string](Get-ParamRaw $params 'action') }
$act = $act.Trim().ToLowerInvariant()
if (-not $act) { $act = 'scan' }

if ($act -eq 'repair') {
    $t0 = Get-Date
    # Stay well inside runner.js's 90 s netdiag budget so a slow fix returns
    # partial, honest results instead of being killed and reported as a crash.
    $budgetMs = 80000
    $deadline = $t0.AddMilliseconds($budgetMs)

    # dryRun default TRUE. Only an explicit boolean false (or a literal
    # "false"/"0"/"no" from a hand-written params file) turns execution on.
    $dryRaw = $null
    if ($DryRun -is [bool]) { $dryRaw = $DryRun } else { $dryRaw = Get-ParamRaw $params 'dryRun' }
    $dryRun = $true
    if ($null -ne $dryRaw) {
        if ($dryRaw -is [bool]) { $dryRun = -not ($dryRaw -eq $false) }
        elseif ("$dryRaw" -match '^(false|0|no)$') { $dryRun = $false }
    }

    $elevated = Test-AdminLocal
    $ipconfigExe = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
    $netshExe = Join-Path $env:SystemRoot 'System32\netsh.exe'
    $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
    $ieKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $backupDir = Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox\regbackup'

    # ---- the seven fixes --------------------------------------------------
    # Static metadata only; per-target readings and actions live in the
    # Get-TargetState / Invoke-TargetAction switches below.
    $targets = @(
        @{ id = 'flushdns'; label = '清空 DNS 缓存'; category = 'dns'; needsAdmin = $false; needsReboot = $false
           impact = '无中断'; risk = '只清本机解析缓存，不改任何配置；之后头几个域名要重新解析（毫秒级）'
           commandText = "$ipconfigExe /flushdns" }
        @{ id = 'renew-dhcp'; label = '重新获取 IP'; category = 'lease'; needsAdmin = $false; needsReboot = $false
           impact = '断网 2–5 秒'; risk = '会先释放当前 DHCP 租约再重新申请，期间网络短暂中断；若路由器没有响应，机器会停在无地址状态（再执行 ipconfig /renew 可恢复）'
           commandText = "$ipconfigExe /release <网卡>  →  $ipconfigExe /renew <网卡>" }
        @{ id = 'reset-winsock'; label = '重置 Winsock'; category = 'stack'; needsAdmin = $true; needsReboot = $true
           impact = '需重启'; risk = '清空 Winsock 目录并重建，卸载残留的 LSP 一并清掉；必须重启才完全生效，重启前部分程序可能无法联网'
           commandText = "$netshExe winsock reset" }
        @{ id = 'reset-tcpip'; label = '重置 TCP/IP'; category = 'stack'; needsAdmin = $true; needsReboot = $true
           impact = '需重启'; risk = '把 IPv4/IPv6 栈恢复到默认值（含自定义路由/接口设置）；必须重启'
           commandText = "$netshExe int ip reset <日志文件>" }
        @{ id = 'reset-proxy'; label = '重置 WinHTTP 代理'; category = 'proxy'; needsAdmin = $true; needsReboot = $false
           impact = '无中断'; risk = '只重置系统级（WinHTTP）代理，不动浏览器代理；若有服务依赖代理需要重新配置'
           commandText = "$netshExe winhttp reset proxy" }
        @{ id = 'reset-ie-proxy'; label = '关闭系统代理'; category = 'proxy'; needsAdmin = $false; needsReboot = $false
           impact = '无中断'; risk = '把 IE/WinINet 代理开关置 0 并删除 ProxyServer 值；写前先 reg export 备份，失败即中止'
           commandText = "reg export HKCU\...\Internet Settings <备份>  →  ProxyEnable=0  →  删除 ProxyServer" }
        @{ id = 'restart-adapter'; label = '重启网卡'; category = 'adapter'; needsAdmin = $true; needsReboot = $false
           impact = '断网数秒'; risk = '禁用再启用主网卡，连接会断开数秒；正在传输的任务会中断'
           commandText = "Restart-NetAdapter -Name <主网卡>" }
    )

    # Optional subset selection: ids / targets array.
    $selected = @()
    foreach ($key in @('ids', 'targets')) {
        $v = Get-ParamRaw $params $key
        if ($null -ne $v) { foreach ($x in @($v)) { $selected += [string]$x } }
    }
    $known = @($targets | ForEach-Object { $_.id })
    $selected = @($selected | Where-Object { $_ -and ($known -contains $_) } | Select-Object -Unique)
    $unknownRequested = @()
    foreach ($key in @('ids', 'targets')) {
        $v = Get-ParamRaw $params $key
        if ($null -ne $v) { foreach ($x in @($v)) { if ($x -and ($known -notcontains [string]$x)) { $unknownRequested += [string]$x } } }
    }
    $todo = if ($selected.Count -gt 0) { @($targets | Where-Object { $selected -contains $_.id }) } else { @($targets) }

    function Get-TargetState {
        param([string]$Id)
        switch ($Id) {
            'flushdns' {
                return [ordered]@{ dnsCacheEntries = (Get-DnsCacheCount) }
            }
            'renew-dhcp' {
                $a = Get-PrimaryAdapter
                $alias = if ($a) { [string]$a.Name } else { '' }
                $snap = Get-IpSnapshot -Alias $alias
                $row = if ($snap.Count -gt 0) { $snap[0] } else { [ordered]@{ alias = $alias; addresses = @(); gateways = @(); dhcp = '' } }
                return [ordered]@{ adapter = $alias; addresses = @($row.addresses); gateways = @($row.gateways); dhcp = $row.dhcp }
            }
            'reset-winsock' {
                return [ordered]@{ elevated = (Test-AdminLocal); note = 'Winsock 目录是否损坏无法直读，只能重置' }
            }
            'reset-tcpip' {
                return [ordered]@{ elevated = (Test-AdminLocal); ipv4Interfaces = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue).Count }
            }
            'reset-proxy' {
                return (Get-WinhttpState)
            }
            'reset-ie-proxy' {
                return (Get-IeProxyState)
            }
            'restart-adapter' {
                $a = Get-PrimaryAdapter
                if (-not $a) { return [ordered]@{ adapter = ''; status = 'none' } }
                return [ordered]@{ adapter = [string]$a.Name; status = [string]$a.Status; desc = [string]$a.InterfaceDescription; linkSpeed = [string]$a.LinkSpeed }
            }
        }
        return [ordered]@{}
    }

    function Format-TargetState {
        param([string]$Id, $State)
        switch ($Id) {
            'flushdns' { return "DNS 缓存 $($State.dnsCacheEntries) 条" }
            'renew-dhcp' {
                if ($State.addresses.Count -eq 0) { return "$($State.adapter): 没有 IPv4 地址（DHCP 未拿到租约）" }
                return "$($State.adapter): $($State.addresses -join ', ')，网关 $(if ($State.gateways.Count) { $State.gateways -join ', ' } else { '无' })"
            }
            'reset-winsock' { return $(if ($State.elevated) { '已提权，可执行' } else { '未提权，只能给出命令' }) }
            'reset-tcpip' { return "$(@($State.ipv4Interfaces) -join '') 个 IPv4 接口配置；$(if ($State.elevated) { '已提权' } else { '未提权' })" }
            'reset-proxy' { return $(if ($State.direct) { 'WinHTTP 已是直连' } else { "WinHTTP: $($State.text)" }) }
            'reset-ie-proxy' {
                if ($State.enabled) { return "ProxyEnable=1 → $($State.server)" }
                return "ProxyEnable=$($State.proxyEnable)，ProxyServer=" + $(if ($State.server) { $State.server } else { '未设置' })
            }
            'restart-adapter' {
                if (-not $State.adapter) { return '没有已连接的网卡' }
                return "$($State.adapter): $($State.status)（$($State.desc)）"
            }
        }
        return ''
    }

    # One target's actual work. Returns @{ changed; detail; runs; retest }.
    # Nothing here invokes a string: every command is an argv array or a cmdlet
    # called through AddCommand/AddParameter.
    function Invoke-TargetAction {
        param([string]$Id, [int]$RemainingMs)
        $out = [ordered]@{ changed = $false; detail = ''; runs = @(); retest = [ordered]@{}; aborted = '' }
        $runs = [System.Collections.Generic.List[object]]::new()

        switch ($Id) {
            'flushdns' {
                $r = Invoke-External -Exe $ipconfigExe -ArgList @('/flushdns') -TimeoutMs ([Math]::Min(20000, $RemainingMs))
                $runs.Add($r)
                $out.changed = (-not $r.timedOut -and $r.exitCode -eq 0)
                $out.detail = if ($r.timedOut) { "ipconfig /flushdns 在 $($r.ms) ms 内未完成（超时），未确认生效" }
                              elseif ($r.exitCode -eq 0) { "已清空解析缓存（$($r.ms) ms）" }
                              else { "ipconfig /flushdns 返回 $($r.exitCode): $($r.error)" }
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $resolved = $false
                try {
                    $rr = Resolve-DnsName -Name 'www.msftconnecttest.com' -Type A -DnsOnly -ErrorAction Stop -QuickTimeout
                    $resolved = @($rr | Where-Object { $_.IPAddress }).Count -gt 0
                } catch { }
                $out.retest = [ordered]@{ resolveOk = $resolved; resolveMs = [int]$sw.ElapsedMilliseconds; dnsCacheEntriesAfterResolve = (Get-DnsCacheCount) }
            }
            'renew-dhcp' {
                $a = Get-PrimaryAdapter
                $alias = if ($a) { [string]$a.Name } else { '' }
                $relArgs = @('/release')
                if ($alias) { $relArgs += $alias }
                $rel = Invoke-External -Exe $ipconfigExe -ArgList $relArgs -TimeoutMs ([Math]::Min(60000, $RemainingMs))
                $runs.Add($rel)
                if ($rel.timedOut) {
                    $out.detail = "ipconfig /release 在 $($rel.ms) ms 内未完成（超时），未继续 /renew"
                } else {
                    $renArgs = @('/renew')
                    if ($alias) { $renArgs += $alias }
                    $left = $RemainingMs - $rel.ms
                    $ren = Invoke-External -Exe $ipconfigExe -ArgList $renArgs -TimeoutMs ([Math]::Min(120000, [Math]::Max(5000, $left)))
                    $runs.Add($ren)
                    if ($ren.timedOut) {
                        $out.detail = "租约已释放，但 ipconfig /renew 在 $($ren.ms) ms 内未完成（超时）——当前可能没有 IP，可再执行一次 ipconfig /renew"
                    } elseif ($ren.exitCode -eq 0) {
                        $out.changed = $true
                        $out.detail = "已释放并重新申请租约（release $($rel.ms) ms + renew $($ren.ms) ms）"
                    } else {
                        $out.detail = "租约已释放，/renew 返回 $($ren.exitCode): $($ren.error)"
                    }
                }
                $snap = Get-IpSnapshot -Alias $alias
                $row = if ($snap.Count -gt 0) { $snap[0] } else { $null }
                $gw = if ($row -and $row.gateways.Count -gt 0) { $row.gateways[0] } else { '' }
                $gwOk = $false
                if ($gw) { $gwOk = Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue }
                $out.retest = [ordered]@{
                    addresses = if ($row) { @($row.addresses) } else { @() }
                    gateways  = if ($row) { @($row.gateways) } else { @() }
                    gatewayReachable = $gwOk
                }
            }
            'reset-winsock' {
                if (-not (Test-AdminLocal)) {
                    $out.aborted = 'needsAdmin'
                    $out.detail = "需要管理员权限，当前进程未提权，未执行。请以管理员身份运行: $netshExe winsock reset"
                    break
                }
                $r = Invoke-External -Exe $netshExe -ArgList @('winsock', 'reset') -TimeoutMs ([Math]::Min(30000, $RemainingMs))
                $runs.Add($r)
                $out.changed = (-not $r.timedOut -and $r.exitCode -eq 0)
                $out.detail = if ($r.timedOut) { "netsh winsock reset 在 $($r.ms) ms 内未完成（超时）" }
                              elseif ($r.exitCode -eq 0) { "Winsock 目录已重置（$($r.ms) ms）——必须重启后才完全生效" }
                              else { "netsh winsock reset 返回 $($r.exitCode): $($r.error)" }
                $out.retest = [ordered]@{ needsReboot = $true; note = '重置结果在重启后才能验证' }
            }
            'reset-tcpip' {
                if (-not (Test-AdminLocal)) {
                    $out.aborted = 'needsAdmin'
                    $out.detail = "需要管理员权限，当前进程未提权，未执行。请以管理员身份运行: $netshExe int ip reset"
                    break
                }
                $logFile = Join-Path $env:TEMP ("dsh-360-tcpip-reset-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $r = Invoke-External -Exe $netshExe -ArgList @('int', 'ip', 'reset', $logFile) -TimeoutMs ([Math]::Min(60000, $RemainingMs))
                $runs.Add($r)
                $out.changed = (-not $r.timedOut -and $r.exitCode -eq 0)
                $out.detail = if ($r.timedOut) { "netsh int ip reset 在 $($r.ms) ms 内未完成（超时）" }
                              elseif ($r.exitCode -eq 0) { "TCP/IP 栈已重置（$($r.ms) ms），日志 $logFile——必须重启后才完全生效" }
                              else { "netsh int ip reset 返回 $($r.exitCode): $($r.error)" }
                $out.retest = [ordered]@{ needsReboot = $true; logFile = $logFile; ipv4Interfaces = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue).Count }
            }
            'reset-proxy' {
                if (-not (Test-AdminLocal)) {
                    $out.aborted = 'needsAdmin'
                    $out.detail = "需要管理员权限，当前进程未提权，未执行。请以管理员身份运行: $netshExe winhttp reset proxy"
                    break
                }
                $r = Invoke-External -Exe $netshExe -ArgList @('winhttp', 'reset', 'proxy') -TimeoutMs ([Math]::Min(20000, $RemainingMs))
                $runs.Add($r)
                $out.changed = (-not $r.timedOut -and $r.exitCode -eq 0)
                $out.detail = if ($r.timedOut) { "netsh winhttp reset proxy 在 $($r.ms) ms 内未完成（超时）" }
                              elseif ($r.exitCode -eq 0) { "WinHTTP 代理已重置为直连（$($r.ms) ms）" }
                              else { "netsh winhttp reset proxy 返回 $($r.exitCode): $($r.error)" }
                $out.retest = Get-WinhttpState
            }
            'reset-ie-proxy' {
                # 1) backup — abort on any failure, before a single value is written
                try { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null } catch { }
                $backupFile = Join-Path $backupDir ("{0}-netdiag-ieproxy.reg" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                $bk = Invoke-External -Exe $regExe -ArgList @('export', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings', $backupFile, '/y') -TimeoutMs 30000
                $runs.Add($bk)
                $backupOk = (-not $bk.timedOut -and $bk.exitCode -eq 0 -and (Test-Path -LiteralPath $backupFile))
                if ($backupOk) {
                    try { $backupOk = ((Get-Item -LiteralPath $backupFile -ErrorAction Stop).Length -gt 0) } catch { $backupOk = $false }
                }
                if (-not $backupOk) {
                    $out.aborted = 'backupError'
                    $out.detail = "注册表备份失败，已中止，未写入任何值: $($bk.command) -> exit $($bk.exitCode) $($bk.error)"
                    break
                }
                $out.retest = [ordered]@{ backupFile = $backupFile }
                # 2) write
                $before = Get-IeProxyState
                $wrote = $true
                try {
                    Set-ItemProperty -LiteralPath $ieKey -Name 'ProxyEnable' -Value 0 -Type DWord -ErrorAction Stop
                } catch {
                    $wrote = $false
                    $out.detail = "写 ProxyEnable 失败: $($_.Exception.Message)"
                }
                $removed = $false
                if ($wrote -and $before.server) {
                    try {
                        Remove-ItemProperty -LiteralPath $ieKey -Name 'ProxyServer' -ErrorAction Stop
                        $removed = $true
                    } catch {
                        $out.detail = "已置 ProxyEnable=0，但删除 ProxyServer 失败: $($_.Exception.Message)"
                    }
                }
                if ($wrote) {
                    $out.changed = $true
                    if (-not $out.detail) {
                        $out.detail = "已置 ProxyEnable=0" + $(if ($removed) { "，并删除 ProxyServer（原值 $($before.server)）" } else { '' }) + "；备份 $backupFile"
                    }
                }
                $out.retest = [ordered]@{ backupFile = $backupFile; removedProxyServer = $removed; state = (Get-IeProxyState) }
            }
            'restart-adapter' {
                if (-not (Test-AdminLocal)) {
                    $out.aborted = 'needsAdmin'
                    $out.detail = "需要管理员权限，当前进程未提权，未执行。请以管理员身份运行 PowerShell 后: Restart-NetAdapter -Name '<主网卡>'"
                    break
                }
                $a = Get-PrimaryAdapter
                if (-not $a) {
                    $out.detail = '没有已连接的网卡可重启'
                    break
                }
                $alias = [string]$a.Name
                $r = Invoke-CmdletTimeout -CommandName 'Restart-NetAdapter' -Parameters @{ Name = $alias } -TimeoutMs ([Math]::Min(45000, $RemainingMs))
                $runs.Add($r)
                $out.changed = ($r.ok -and -not $r.timedOut)
                $out.detail = if ($r.timedOut) { "Restart-NetAdapter '$alias' 在 $($r.ms) ms 内未完成（超时）" }
                              elseif ($r.ok) { "已重启网卡 $alias（$($r.ms) ms）" }
                              else { "Restart-NetAdapter 失败: $($r.error)" }
                # Wait (bounded) for the adapter to come back Up before reading.
                $sw = [Diagnostics.Stopwatch]::StartNew()
                while ($sw.ElapsedMilliseconds -lt 30000) {
                    $cur = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
                    if ($cur -and [string]$cur.Status -eq 'Up') { break }
                    Start-Sleep -Milliseconds 1000
                }
                $cur = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
                $out.retest = [ordered]@{
                    adapter = $alias
                    status  = if ($cur) { [string]$cur.Status } else { 'missing' }
                    waitedMs = [int]$sw.ElapsedMilliseconds
                }
            }
        }
        $out.runs = @($runs.ToArray())
        return $out
    }

    # ---- plan -------------------------------------------------------------
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $todo) {
        $st = Get-TargetState -Id $t.id
        $canRun = ((-not $t.needsAdmin) -or $elevated)
        $status = 'info'
        $note = ''
        if ($t.needsAdmin -and -not $elevated) {
            $status = 'skip'
            $note = '需要管理员：未提权时只给命令，不执行'
        }
        if ($t.needsReboot) { $note = (($note + '；') ).TrimStart('；') + '执行后需重启才完全生效' }
        $plan.Add([ordered]@{
            id          = $t.id
            label       = $t.label
            category    = $t.category
            status      = $status
            needsAdmin  = [bool]$t.needsAdmin
            needsReboot = [bool]$t.needsReboot
            canRun      = [bool]$canRun
            impact      = $t.impact
            risk        = $t.risk
            command     = $t.commandText
            currentState = (Format-TargetState -Id $t.id -State $st)
            state       = $st
            note        = $note
        })
    }

    # ---- execution (only with an explicit dryRun:false) -------------------
    $results = [System.Collections.Generic.List[object]]::new()
    $anyChanged = $false
    if (-not $dryRun) {
        foreach ($p in $plan) {
            $remaining = [int]($deadline - (Get-Date)).TotalMilliseconds
            $row = [ordered]@{
                id = $p.id; label = $p.label; status = 'info'; ran = $false; changed = $false
                needsAdmin = $p.needsAdmin; needsReboot = $p.needsReboot
                reason = ''; detail = ''; before = $p.state; after = $null; runs = @(); retest = $null
            }
            if ($p.needsAdmin -and -not $elevated) {
                # Never throw, never wait: hand back the exact command.
                $row.status = 'skip'
                $row.reason = 'needsAdmin'
                $row.detail = "需要管理员权限，当前未提权，未执行。命令: $($p.command)"
            } elseif ($remaining -lt 5000) {
                $row.status = 'skip'
                $row.reason = 'budget'
                $row.detail = "时间预算（$budgetMs ms）用完，未执行；可单独选中此项重跑"
            } else {
                $r = Invoke-TargetAction -Id $p.id -RemainingMs $remaining
                $row.ran = $true
                $row.changed = [bool]$r.changed
                $row.detail = $r.detail
                $row.runs = @($r.runs)
                $row.retest = $r.retest
                $row.after = Get-TargetState -Id $p.id
                if ($r.aborted) {
                    $row.status = 'skip'
                    $row.reason = $r.aborted
                } elseif ($r.changed) {
                    $row.status = 'ok'
                } else {
                    $row.status = 'bad'
                }
                if ($r.changed) { $anyChanged = $true }
            }
            $results.Add($row)
        }
    }

    $notes = [System.Collections.Generic.List[string]]::new()
    if ($dryRun) {
        $notes.Add('dryRun 默认为 true：本次只返回计划，没有执行任何命令，changed=false。确认后传 dryRun:false 才真正执行。')
    }
    if (-not $elevated) {
        $notes.Add('当前进程未提权：reset-winsock / reset-tcpip / reset-proxy / restart-adapter 只返回命令，未执行。')
    }
    if ($unknownRequested.Count -gt 0) {
        $notes.Add("忽略了未知的修复项 id: " + ($unknownRequested -join ', '))
    }
    $notes.Add('修复后仍不通：先看 action=scan 的 firstFail 指向哪一环，再决定是否重置协议栈。')

    $executedCount = @($results | Where-Object { $_.ran }).Count
    $changedCount = @($results | Where-Object { $_.changed }).Count
    $out = [ordered]@{
        ok = $true
        action = 'repair'
        dryRun = [bool]$dryRun
        changed = [bool]$anyChanged
        elevated = [bool]$elevated
        budgetMs = $budgetMs
        elapsedMs = [int]((Get-Date) - $t0).TotalMilliseconds
        targetCount = $plan.Count
        selectedIds = @($selected)
        targets = @($plan.ToArray())
        results = @($results.ToArray())
        summary = [ordered]@{
            total           = $plan.Count
            executed        = @($results | Where-Object { $_.ran }).Count
            changed         = @($results | Where-Object { $_.changed }).Count
            skippedNeedsAdmin = @($results | Where-Object { $_.reason -eq 'needsAdmin' }).Count
            skippedOther    = @($results | Where-Object { $_.reason -and $_.reason -ne 'needsAdmin' }).Count
        }
        verdict = if ($dryRun) { "计划 $($plan.Count) 项修复，dryRun=true，未执行任何命令" }
                  elseif (-not $elevated) { "已执行 $executedCount 项；需要管理员的项未执行（只给命令）" }
                  else { "已执行 $executedCount 项，其中 $changedCount 项实际生效" }
        notes = @($notes.ToArray())
    }
    [Console]::Out.Write((ConvertTo-Json -InputObject $out -Depth 8 -Compress))
    exit 0
}

# ---------------------------------------------------------------------------
# dnspick branch — switch this machine's interface DNS to a public resolver.
#
# Scope is deliberately narrow: only the DNS server list of local interfaces,
# nothing else. DHCP, gateways, proxy and hosts are untouched, so the change is
# a single reversible property write per interface.
# ---------------------------------------------------------------------------
if ($act -eq 'dnspick') {
    $t0 = Get-Date
    # dryRun default TRUE, same contract as repair: what comes back is a plan
    # unless the caller explicitly passes dryRun:false.
    $dryRaw = $null
    if ($DryRun -is [bool]) { $dryRaw = $DryRun } else { $dryRaw = Get-ParamRaw $params 'dryRun' }
    $dryRun = $true
    if ($null -ne $dryRaw) {
        if ($dryRaw -is [bool]) { $dryRun = -not ($dryRaw -eq $false) }
        elseif ("$dryRaw" -match '^(false|0|no)$') { $dryRun = $false }
    }
    $elevated = Test-AdminLocal
    $items = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $backupDir = Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox\backups'

    function Add-DpRow {
        param([string]$Id, [string]$Label, [string]$Status, [string]$Detail)
        $items.Add([ordered]@{ id = $Id; label = $Label; status = $Status; detail = $Detail })
    }

    # ---- what was asked for ---------------------------------------------------
    # Only `server` is honoured. Anything else in the params bag is ignored on
    # purpose: a probe that silently accepts unknown keys is a probe that will
    # one day be driven by a stale key name and change something nobody asked for.
    $candIps = @($DnsCandidates | ForEach-Object { $_.ip })
    $candText = ($DnsCandidates | ForEach-Object { "$($_.ip)（$($_.label)）" }) -join ' / '
    $reqServer = [string](Get-ParamRaw $params 'server')
    $reqServer = $reqServer.Trim().ToLowerInvariant()
    $picked = ''
    $ignored = [System.Collections.Generic.List[string]]::new()
    foreach ($k in @(Get-ParamKeys $params)) {
        if ($k -eq 'server' -or $k -eq 'action' -or $k -eq 'dryRun') { continue }
        $ignored.Add([string]$k)
    }
    if ($reqServer -eq 'auto') {
        $picked = 'auto'
    } elseif ($candIps -contains $reqServer) {
        $picked = $reqServer
    } elseif ($reqServer) {
        # An arbitrary IP is rejected rather than applied: "pick the fastest
        # public DNS" and "set DNS to whatever string arrived" are different
        # operations, and this probe only promises the first one. One dedicated
        # note explains it, so it is not repeated in the generic ignored list.
        $notes.Add("忽略了 server=$reqServer：只接受这五个候选之一或 auto（$candText）。本次没有任何改动。")
    }

    # ---- which interfaces -----------------------------------------------------
    # Up, non-virtual, and actually holding an IPv4 address. A disconnected or
    # VPN adapter's DNS list is not what resolves this machine's traffic, and
    # rewriting it would look like a fix while changing nothing observable.
    $targets = [System.Collections.Generic.List[object]]::new()
    $skippedAdapters = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
        $desc = [string]$a.InterfaceDescription
        if ([string]$a.Status -ne 'Up') { continue }
        if ($desc -match 'Virtual|Hyper-V|VMware|VirtualBox|TAP|WireGuard|Tailscale|Loopback') { continue }
        $v4 = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' })
        if ($v4.Count -eq 0) { $skippedAdapters.Add("$($a.Name)(无可用 IPv4)"); continue }
        $targets.Add($a)
    }
    if ($skippedAdapters.Count -gt 0) {
        $notes.Add("跳过这些已连接但无可用 IPv4 的网卡: " + ($skippedAdapters -join ', '))
    }

    # ---- current state + rollback data ---------------------------------------
    # Both families are captured even though only IPv4 addresses are offered:
    # Set-DnsClientServerAddress replaces the interface's server list, so the
    # IPv6 entries are collateral and must be restorable too.
    $dnsNow = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @(Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) {
        $fam = if ($row.AddressFamily -eq 2) { 'ipv4' } elseif ($row.AddressFamily -eq 23) { 'ipv6' } else { 'other' }
        $dnsNow.Add([ordered]@{
            interfaceIndex = $row.InterfaceIndex
            interfaceAlias = [string]$row.InterfaceAlias
            family         = $fam
            servers        = @($row.ServerAddresses | Where-Object { $_ })
        })
    }
    $rollback = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $targets) {
        $v4s = @($dnsNow | Where-Object { $_.interfaceIndex -eq $a.ifIndex -and $_.family -eq 'ipv4' } | ForEach-Object { $_.servers })
        $v4s = @($v4s | Where-Object { $_ })
        if ($v4s.Count -gt 0) {
            $rollback.Add("Set-DnsClientServerAddress -InterfaceIndex $($a.ifIndex) -ServerAddresses $(($v4s | ForEach-Object { "'$_'" }) -join ',')")
        } else {
            $rollback.Add("Set-DnsClientServerAddress -InterfaceIndex $($a.ifIndex) -ResetServerAddresses")
        }
    }

    # ---- plan -----------------------------------------------------------------
    $planCmds = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $targets) {
        if ($picked -eq 'auto') {
            $planCmds.Add("Set-DnsClientServerAddress -InterfaceIndex $($a.ifIndex) -ResetServerAddresses")
        } elseif ($picked -in $candIps) {
            $planCmds.Add("Set-DnsClientServerAddress -InterfaceIndex $($a.ifIndex) -ServerAddresses $picked")
        }
    }

    # ---- before measurement ---------------------------------------------------
    # An uncached name, because the system-resolver reading is the only way to
    # show the user a "before" that includes the resolver they are actually
    # using; a cache hit would report ~4 ms and hide the problem.
    $cachedNames = @()
    try { $cachedNames = @(Get-DnsClientCache -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Entry }) } catch { }
    $beforeName = $DnsProbeName
    foreach ($candName in @('www.baidu.com', 'www.qq.com', 'www.taobao.com', 'www.jd.com', 'www.163.com')) {
        if ($cachedNames -notcontains $candName) { $beforeName = $candName; break }
    }
    $beforeProbe = Invoke-DnsProbe -Server '' -Name $beforeName -TimeoutMs 1500
    $currentV4 = @($dnsNow | Where-Object { $_.family -eq 'ipv4' -and $_.interfaceIndex -in @($targets | ForEach-Object { $_.ifIndex }) } | ForEach-Object { $_.servers })
    $currentV4 = @($currentV4 | Where-Object { $_ })

    $changed = $false
    $didApply = $false
    $applied = [System.Collections.Generic.List[object]]::new()
    $aborted = ''
    $backupFile = ''
    $afterProbe = $null
    $afterDirect = [System.Collections.Generic.List[object]]::new()

    if (-not $picked) {
        # No valid target server was named, so the interfaces are reported for
        # context but nothing is planned. Saying "no suitable adapter" here would
        # be a lie: the adapters are fine, the request was not.
        $adaptText = if ($targets.Count -gt 0) { (@($targets | ForEach-Object { "$($_.Name)(#$($_.ifIndex))" }) -join ', ') } else { '没有已连接且持有 IPv4 地址的非虚拟网卡' }
        Add-DpRow 'target' '目标网卡' 'skip' "未指定有效的 server，没有可执行的操作。可修改的网卡: $adaptText；当前 DNS: $(if ($currentV4.Count) { $currentV4 -join ', ' } else { '未配置' })"
    } elseif ($targets.Count -eq 0) {
        Add-DpRow 'target' '目标网卡' 'skip' '没有已连接且持有 IPv4 地址的非虚拟网卡，没有可修改的对象（未做任何改动）'
    } else {
        $ifDesc = (@($targets | ForEach-Object { "$($_.Name)(#$($_.ifIndex))" }) -join ', ')
        Add-DpRow 'target' '目标网卡' 'ok' "将修改: $ifDesc；当前 DNS: $(if ($currentV4.Count) { $currentV4 -join ', ' } else { '未配置（自动获取）' })"

        $changedFlag = ($picked -eq 'auto') -or (@($currentV4 | Where-Object { $_ -ne $picked }).Count -gt 0)
        if (-not $changedFlag) {
            Add-DpRow 'plan' '切换计划' 'skip' "当前 DNS 已经是 $picked，无需修改（未做任何改动）"
        } elseif ($dryRun) {
            Add-DpRow 'plan' '切换计划' 'info' ("dryRun=true，未执行。将执行: " + ($planCmds -join ' ; ') + "；回滚: " + ($rollback -join ' ; '))
        } elseif (-not $elevated) {
            # needsAdmin, not an error: the caller decides whether to elevate.
            Add-DpRow 'plan' '切换计划' 'warn' ("未提权，无法修改 DNS（Set-DnsClientServerAddress 需要管理员）。请用管理员 PowerShell 执行: " + ($planCmds -join ' ; ') + "；回滚: " + ($rollback -join ' ; '))
        } else {
            # Backup FIRST. If the original state cannot be written down, there
            # is no rollback, so the change does not happen at all.
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupFile = Join-Path $backupDir "dns-$stamp.json"
            $backupOk = $false
            try {
                if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
                $payload = [ordered]@{
                    createdAt = (Get-Date).ToString('o')
                    tool      = 'dsh-windows-toolbox/netdiag dnspick'
                    requested = $picked
                    interfaces = @($dnsNow | ForEach-Object { [ordered]@{ interfaceIndex = $_.interfaceIndex; interfaceAlias = $_.interfaceAlias; family = $_.family; servers = @($_.servers) } })
                    rollbackCommands = @($rollback)
                }
                $json = ConvertTo-Json -InputObject $payload -Depth 6
                [System.IO.File]::WriteAllText($backupFile, $json, (New-Object System.Text.UTF8Encoding $false))
                $fi = Get-Item -LiteralPath $backupFile -ErrorAction Stop
                $backupOk = ($fi.Length -gt 0)
            } catch {
                $backupOk = $false
                $notes.Add("备份失败: $($_.Exception.Message)")
            }
            if (-not $backupOk) {
                $aborted = 'backupError'
                Add-DpRow 'plan' '切换计划' 'bad' "备份原 DNS 配置失败（$backupFile），按契约中止，没有做任何修改"
            } else {
                Add-DpRow 'backup' '备份' 'ok' "原 DNS 配置已导出: $backupFile；回滚: $($rollback -join ' ; ')"
                # Set only once the backup is on disk: this flag is what makes
                # the after-measurement claim "a write happened".
                $didApply = $true
                foreach ($a in $targets) {
                    $applyErr = ''
                    if ($picked -eq 'auto') {
                        try { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop }
                        catch { $applyErr = $_.Exception.Message }
                    } else {
                        try { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $picked -ErrorAction Stop }
                        catch { $applyErr = $_.Exception.Message }
                    }
                    $applied.Add([ordered]@{ interfaceIndex = $a.ifIndex; interfaceAlias = [string]$a.Name; ok = (-not $applyErr); error = $applyErr })
                }
                $failCount = @($applied | Where-Object { -not $_.ok }).Count
                if ($failCount -gt 0) {
                    Add-DpRow 'apply' '应用' 'warn' (($applied | ForEach-Object { if ($_.ok) { "$($_.interfaceAlias)=已设置" } else { "$($_.interfaceAlias)=失败: $($_.error)" } }) -join ' ; ')
                } else {
                    Add-DpRow 'apply' '应用' 'ok' (($applied | ForEach-Object { "$($_.interfaceAlias)=已设置" }) -join ' ; ')
                }
            }
        }
    }

    # ---- after measurement ----------------------------------------------------
    # Only an actual write deserves a re-measure, and only a re-read of the OS
    # config proves the write landed — echoing back the value we just set would
    # prove nothing.
    $afterV4 = @()
    if ($didApply) {
        $afterNow = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        foreach ($a in $targets) {
            $row = $afterNow | Where-Object { $_.InterfaceIndex -eq $a.ifIndex } | Select-Object -First 1
            foreach ($srv in @($row.ServerAddresses)) { if ($srv -and $afterV4 -notcontains $srv) { $afterV4 += $srv } }
        }
        $changed = ($picked -eq 'auto') -or (@($afterV4 | Where-Object { $_ -eq $picked }).Count -gt 0)
        $afterName = 'www.qq.com'
        foreach ($candName in @('www.qq.com', 'www.taobao.com', 'www.jd.com', 'www.163.com', 'www.so.com')) {
            if ($cachedNames -notcontains $candName -and $candName -ne $beforeName) { $afterName = $candName; break }
        }
        $afterProbe = Invoke-DnsProbe -Server '' -Name $afterName -TimeoutMs 1500
        foreach ($srv in @($afterV4 | Select-Object -First 2)) {
            $afterDirect.Add((Invoke-DnsProbe -Server $srv -Name $afterName -TimeoutMs 1500))
        }
        $directOk = @($afterDirect | Where-Object { $_.ok })
        $directStr = if ($directOk.Count -gt 0) { (@($directOk | ForEach-Object { "$($_.server)=$($_.ms)ms" }) -join ' ') } else { (@($afterDirect | ForEach-Object { "$($_.server)=失败" }) -join ' ') }
        $verifyDetail = "修改后 DNS=$(if ($afterV4.Count) { $afterV4 -join ', ' } else { '未配置（自动获取）' })；解析 $afterName 直连耗时: $directStr；系统解析路径: $(if ($afterProbe.ok) { "$($afterProbe.ms)ms" } else { '失败/超时' })；修改前 DNS=$(@($currentV4) -join ', ') 解析 $beforeName = $(if ($beforeProbe.ok) { "$($beforeProbe.ms)ms" } else { '失败/超时' })"
        if ($changed) {
            Add-DpRow 'verify' '改后复测' 'ok' $verifyDetail
        } else {
            Add-DpRow 'verify' '改后复测' 'warn' "写入后重新读取配置，没有看到 $picked：$verifyDetail"
        }
    } elseif ($aborted -eq 'backupError') {
        Add-DpRow 'verify' '改后复测' 'skip' '备份失败已中止，没有修改 DNS，无需复测'
    } elseif ($picked -and $targets.Count -gt 0) {
        # Nothing was written (dry run, no admin, or already correct), so a
        # "did it take effect" read would measure a change that never happened.
        $why = if ($dryRun) { 'dryRun 未执行' } elseif (-not $elevated) { '未提权未执行' } else { '当前配置已是目标值，未执行' }
        Add-DpRow 'verify' '改后复测' 'skip' ("$why，没有改动可复测。当前 DNS=$(if ($currentV4.Count) { $currentV4 -join ', ' } else { '未配置（自动获取）' })；解析 $beforeName = $(if ($beforeProbe.ok) { "$($beforeProbe.ms)ms" } else { '失败/超时' })")
    }

    if ($dryRun) { $notes.Add('dryRun 默认为 true：本次只返回计划，没有执行任何命令，changed=false。确认后传 dryRun:false 才真正执行。') }
    if (-not $elevated -and -not $dryRun) { $notes.Add('当前进程未提权：Set-DnsClientServerAddress 需要管理员，只有 plan 行给出完整命令文本，未执行。') }
    if ($ignored.Count -gt 0) { $notes.Add('忽略了这些参数: ' + ($ignored -join ', ') + '（只接受 server 一个参数）') }
    if ($aborted -eq 'backupError') { $notes.Add('备份失败即中止：没有修改 DNS。修好备份目录权限后重试。') }
    if ($backupFile) { $notes.Add("回滚: " + ($rollback -join ' ; ')) }

    $sum = [ordered]@{ total = $items.Count; ok = 0; warn = 0; bad = 0; info = 0; skip = 0 }
    foreach ($it in $items) {
        $k = [string]$it.status
        if ($sum.Contains($k)) { $sum[$k] = $sum[$k] + 1 }
    }
    $out = [ordered]@{
        ok = $true
        action = 'dnspick'
        dryRun = [bool]$dryRun
        changed = [bool]$changed
        aborted = $aborted
        elevated = [bool]$elevated
        needsAdmin = (-not $elevated -and -not $dryRun -and $picked -and $targets.Count -gt 0 -and -not $aborted)
        requested = $reqServer
        server = $picked
        candidates = @($DnsCandidates | ForEach-Object { [ordered]@{ ip = $_.ip; label = $_.label } })
        targetCount = $targets.Count
        targets = @($targets | ForEach-Object { [ordered]@{ interfaceIndex = $_.ifIndex; interfaceAlias = [string]$_.Name } })
        currentDns = @($currentV4)
        afterDns = @($afterV4)
        backupFile = $backupFile
        rollbackCommands = @($rollback)
        planCommands = @($planCmds)
        before = [ordered]@{ name = $beforeName; ok = [bool]$beforeProbe.ok; ms = [int]$beforeProbe.ms; timeout = [bool]$beforeProbe.timedOut }
        after = [ordered]@{ name = $(if ($afterProbe) { $afterProbe.name } else { '' }); ok = [bool]($afterProbe -and $afterProbe.ok); ms = $(if ($afterProbe) { [int]$afterProbe.ms } else { -1 }); direct = @($afterDirect | ForEach-Object { [ordered]@{ server = $_.server; ok = [bool]$_.ok; ms = [int]$_.ms } }) }
        applied = @($applied)
        elapsedMs = [int]((Get-Date) - $t0).TotalMilliseconds
        items = @($items)
        summary = $sum
        verdict =
            if ($aborted -eq 'backupError') { '备份失败，已中止，未修改 DNS' }
            elseif (-not $picked) { '没有指定有效的 server，未做任何改动' }
            elseif ($dryRun) { "计划把 DNS 切换为 $(if ($picked -eq 'auto') { '自动获取' } else { $picked })，dryRun=true，未执行任何命令" }
            elseif (-not $elevated) { '未提权：只给出命令文本，未修改 DNS' }
            elseif ($changed) { "已把 DNS 切换为 $(if ($picked -eq 'auto') { '自动获取' } else { $picked })" }
            else { 'DNS 未发生变化（写入后复读未见新值）' }
        notes = @($notes)
    }
    [Console]::Out.Write((ConvertTo-Json -InputObject $out -Depth 8 -Compress))
    exit 0
}

# ---------------------------------------------------------------------------
# scan branch — unchanged behaviour (8 steps, same ids, same verdict logic)
# ---------------------------------------------------------------------------
$started = Get-Date
$steps = [System.Collections.Generic.List[object]]::new()

function Add-Step {
    param([string]$Id, [string]$Label, [string]$Status, [string]$Detail, [int]$Ms = 0, [string]$Group = '', [string]$Value = '')
    $row = [ordered]@{ id = $Id; label = $Label; status = $Status; detail = $Detail; ms = $Ms }
    # The original eight steps keep exactly these five keys: runner.js maps
    # s => {id,label,status,detail,ms} and the panel renders that shape, so a
    # group/value added to them would be invisible noise. Only the two new rows
    # carry them.
    if ($Group) { $row['group'] = $Group }
    if ($Value) { $row['value'] = $Value }
    $steps.Add($row)
}

# ---- 1. adapters -------------------------------------------------------------
$adapters = [System.Collections.Generic.List[object]]::new()
foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
    $adapters.Add([ordered]@{
        name        = $a.Name
        description = $a.InterfaceDescription
        status      = [string]$a.Status
        linkSpeed   = [string]$a.LinkSpeed
        mac         = [string]$a.MacAddress
        # Virtual adapters (VPN, Hyper-V, WSL) routinely sit "Disconnected"
        # while the machine is perfectly online; mark them so the UI can stop
        # a user from chasing a red herring.
        virtual     = ($a.InterfaceDescription -match 'Virtual|Hyper-V|VMware|VirtualBox|TAP|WireGuard|Tailscale|Loopback')
    })
}
$up = @($adapters | Where-Object { $_.status -eq 'Up' })
if ($up.Count -gt 0) {
    Add-Step 'link' '网卡连接' 'ok' ("已连接: " + (($up | ForEach-Object { $_.name }) -join ', '))
} elseif ($adapters.Count -eq 0) {
    Add-Step 'link' '网卡连接' 'fail' '没有检测到任何网络适配器'
} else {
    Add-Step 'link' '网卡连接' 'fail' ("所有网卡均未连接: " + (($adapters | ForEach-Object { "$($_.name)=$($_.status)" }) -join ', '))
}

# ---- 2. IP configuration -----------------------------------------------------
$ipConfig = [System.Collections.Generic.List[object]]::new()
$hasUsableIp = $false
$hasGateway = $false
$dnsServers = [System.Collections.Generic.List[string]]::new()
# Only adapters that are actually Up count. A disconnected adapter routinely
# carries a stale 169.254 APIPA address, and judging DHCP failure on it made the
# whole diagnosis report "cannot get an IP" on a perfectly working machine.
$upNames = @($adapters | Where-Object { $_.status -eq 'Up' } | ForEach-Object { $_.name })
foreach ($ip in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
    $alias = [string]$ip.InterfaceAlias
    $isUp = ($upNames -contains $alias)
    $v4 = @($ip.IPv4Address | Where-Object { $_.IPAddress })
    $gw = @($ip.IPv4DefaultGateway | Where-Object { $_.NextHop })
    $dns = @($ip.DNSServer | Where-Object { $_.AddressFamily -eq 2 })
    $addrs = @($v4 | ForEach-Object { $_.IPAddress })
    # 169.254.x.x means DHCP failed — the classic "cable looks fine, nothing
    # works" case. Treating it as a usable address would hide the real fault.
    $real = @($addrs | Where-Object { $_ -notlike '169.254.*' -and $_ -ne '127.0.0.1' })
    if ($isUp -and $real.Count -gt 0) { $hasUsableIp = $true }
    if ($isUp -and $gw.Count -gt 0) { $hasGateway = $true }
    foreach ($d in $dns) { if ($d.ServerAddresses) { foreach ($s in $d.ServerAddresses) { if ($dnsServers -notcontains $s) { $dnsServers.Add($s) } } } }
    $ipConfig.Add([ordered]@{
        interface = $alias
        up        = $isUp
        addresses = $addrs
        gateways  = @($gw | ForEach-Object { $_.NextHop })
        dhcp      = [string]$ip.NetIPv4Interface.Dhcp
        # APIPA only matters on an interface that is Up; on a disconnected one
        # it is just the adapter's last-known remnant.
        apipa     = ($isUp -and $addrs.Count -gt 0 -and $real.Count -eq 0)
    })
}
foreach ($s in @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
    foreach ($srv in @($s.ServerAddresses)) {
        if ($srv -and $dnsServers -notcontains $srv) { $dnsServers.Add($srv) }
    }
}
$apipa = @($ipConfig | Where-Object { $_.apipa })
if ($apipa.Count -gt 0) {
    Add-Step 'ip' 'IP 地址' 'fail' ("DHCP 未获取到地址，只有 169.254 自分配地址: " + (($apipa | ForEach-Object { $_.interface }) -join ', '))
} elseif ($hasUsableIp) {
    Add-Step 'ip' 'IP 地址' 'ok' (($ipConfig | Where-Object { $_.up -and $_.addresses.Count -gt 0 } | ForEach-Object { "$($_.interface)=$($_.addresses -join '/')" }) -join '; ')
} else {
    Add-Step 'ip' 'IP 地址' 'fail' '没有任何已连接的网卡拿到有效 IPv4 地址'
}
if (-not $hasGateway) { Add-Step 'gateway-config' '默认网关' 'fail' '没有配置默认网关，只能访问本机所在网段' }
else { Add-Step 'gateway-config' '默认网关' 'ok' (($ipConfig | ForEach-Object { $_.gateways } | Where-Object { $_ }) -join ', ') }

# ---- 3. gateway reachability -------------------------------------------------
$gwFirst = ($ipConfig | ForEach-Object { $_.gateways } | Where-Object { $_ } | Select-Object -First 1)
if ($gwFirst) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ok = Test-Connection -ComputerName $gwFirst -Count 2 -Quiet -ErrorAction SilentlyContinue
    Add-Step 'gateway-ping' '网关连通' $(if ($ok) { 'ok' } else { 'fail' }) $(if ($ok) { "网关 $gwFirst 可达" } else { "网关 $gwFirst 无响应（可能是路由/防火墙/网线问题）" }) ([int]$sw.ElapsedMilliseconds)
} else {
    Add-Step 'gateway-ping' '网关连通' 'skip' '没有网关可测'
}

# ---- 4. DNS ------------------------------------------------------------------
$dnsOk = $false
$dnsDetail = ''
if ($dnsServers.Count -eq 0) {
    $dnsDetail = '没有配置 DNS 服务器（能上 IP 但打不开网页）'
} else {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Resolve-DnsName -Name 'www.msftconnecttest.com' -Type A -DnsOnly -ErrorAction Stop -QuickTimeout
        $dnsOk = @($r | Where-Object { $_.IPAddress }).Count -gt 0
        $dnsDetail = if ($dnsOk) { "DNS 服务器: $($dnsServers -join ', ')" } else { 'DNS 查询没有返回地址' }
    } catch {
        $dnsDetail = "DNS 查询失败: $($_.Exception.Message)"
    }
    Add-Step 'dns' '域名解析' $(if ($dnsOk) { 'ok' } else { 'fail' }) $dnsDetail ([int]$sw.ElapsedMilliseconds)
}

# ---- 5. internet -------------------------------------------------------------
# HTTP rather than ICMP: plenty of networks drop ping while serving HTTP fine,
# so a failed ping says nothing about whether browsing works.
#
# Several endpoints, first success wins. A single probe is not trustworthy here:
# msftconnecttest.com answered in 527 ms on one run and timed out at 6 s on the
# next on the same machine, which would have been reported as "no internet" on
# a connection that was demonstrably working. Endpoints are in different
# networks/regions so one being unreachable from here does not decide the result.
$internetOk = $false
$sw = [Diagnostics.Stopwatch]::StartNew()
$probes = @(
    @{ url = 'http://www.msftconnecttest.com/connecttest.txt'; expect = 'Microsoft Connect Test' },
    @{ url = 'http://connect.rom.miui.com/generate_204'; expect = '' },
    @{ url = 'http://www.baidu.com/'; expect = '' }
)
$tried = [System.Collections.Generic.List[string]]::new()
$lastErr = ''
foreach ($probe in $probes) {
    if (((Get-Date) - $sw.StartTime).TotalSeconds -gt 15) { break }
    try {
        $resp = Invoke-WebRequest -Uri $probe.url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
            $internetOk = $true
            $tried.Add("$($probe.url) -> HTTP $($resp.StatusCode)")
            break
        }
        $tried.Add("$($probe.url) -> HTTP $($resp.StatusCode)")
    } catch {
        $lastErr = $_.Exception.Message
        $tried.Add("$($probe.url) -> 失败")
    }
}
if ($internetOk) {
    Add-Step 'internet' '外网访问' 'ok' ("连通: " + ($tried -join ' | ')) ([int]$sw.ElapsedMilliseconds)
} else {
    Add-Step 'internet' '外网访问' 'fail' ("所有探测点均失败: " + ($tried -join ' | ') + " ; 最后错误: $lastErr") ([int]$sw.ElapsedMilliseconds)
}

# ---- 6. proxy ------------------------------------------------------------------
# A stale proxy is the most common cause of "the network is fine but nothing
# loads", and it is invisible in every other check above.
$proxy = [ordered]@{ enabled = $false; server = ''; bypass = ''; autoConfig = '' }
$ie = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
try {
    $p = Get-ItemProperty -LiteralPath $ie -ErrorAction Stop
    $proxy.enabled = ([int]$p.ProxyEnable -eq 1)
    $proxy.server = [string]$p.ProxyServer
    $proxy.bypass = [string]$p.ProxyOverride
    $proxy.autoConfig = [string]$p.AutoConfigURL
} catch {}
$winhttp = ''
try { $winhttp = [string](& netsh winhttp show proxy 2>$null | Out-String) } catch {}
$proxyActive = $proxy.enabled -and $proxy.server
if ($proxyActive) {
    Add-Step 'proxy' '代理设置' 'warn' "系统代理已开启: $($proxy.server)"
} else {
    Add-Step 'proxy' '代理设置' 'ok' '未启用系统代理（进程级环境变量不在检查范围）'
}

# ---- 7. hosts file -------------------------------------------------------------
# A hosts entry silently redirecting a domain is another classic "network fine,
# site broken" cause, and it survives every adapter-level fix.
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsEntries = [System.Collections.Generic.List[object]]::new()
$hostsBlocked = 0
if (Test-Path -LiteralPath $hostsPath) {
    foreach ($line in @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '\s+'
        if ($parts.Count -ge 2) {
            $hostsEntries.Add([ordered]@{ ip = $parts[0]; host = $parts[1] })
            # 0.0.0.0 / 127.0.0.1 with a real domain is the standard ad-block or
            # deliberate-block shape.
            if (($parts[0] -eq '0.0.0.0' -or $parts[0] -eq '127.0.0.1') -and $parts[1] -notin @('localhost', 'localhost.localdomain')) { $hostsBlocked++ }
        }
    }
}
Add-Step 'hosts' 'hosts 文件' $(if ($hostsBlocked -gt 0) { 'warn' } else { 'ok' }) $(if ($hostsBlocked -gt 0) { "有 $hostsBlocked 条被指向本机/黑洞的域名" } else { "共 $($hostsEntries.Count) 条自定义映射" })

# ---- 8. WiFi 体检 --------------------------------------------------------------
# Read from netsh rather than Get-NetAdapter: the adapter object knows link
# speed, but not signal strength, channel or the negotiated radio type, and
# those are exactly what "my Wi-Fi is slow" turns out to be.
$wlan = Get-WlanInterfaces
$wifiStatus = 'skip'
$wifiDetail = ''
$wifiValue = ''
$wifiRows = @($wlan.interfaces)
$wifiConnected = @($wifiRows | Where-Object { $_.connected })
$wirelessAdapters = @($adapters | Where-Object { $_.description -match 'Wi-?Fi|Wireless|WLAN|802\.11' -or $_.name -match 'Wi-?Fi|WLAN' })
$wiredUp = @($adapters | Where-Object { $_.status -eq 'Up' -and $_.description -notmatch 'Wi-?Fi|Wireless|WLAN|802\.11' -and -not $_.virtual })
if ($wlan.timedOut) {
    $wifiStatus = 'warn'
    $wifiDetail = "$($wlan.error)；无法判断信号强度（既不能算正常也不能算故障）"
} elseif ($wifiConnected.Count -gt 0) {
    $values = [System.Collections.Generic.List[string]]::new()
    $details = [System.Collections.Generic.List[string]]::new()
    $warnCount = 0
    foreach ($w in $wifiConnected) {
        $values.Add((Format-WlanRow $w))
        $line = if ($w.name) { "$($w.name): " } else { '' }
        $line += (Format-WlanRow $w)
        if ($null -ne $w.signalPercent -and $w.signalPercent -lt 50) {
            $warnCount++
            $line += " —— 信号 $($w.signal) 偏弱（<50%），离路由器远/有遮挡时优先怀疑信号"
        }
        $asym = Get-WlanAsymmetryNote $w
        # Reported, but NOT escalated to warn: on 802.11ax a large tx/rx split is
        # normal (the two directions are negotiated separately, and power save
        # biases the receive rate down). Turning it into warn would flag a
        # working connection on every machine and bury the signal case, which is
        # the one that actually predicts trouble.
        if ($asym) { $line += " —— $asym" }
        if ($w.radioType -match '802\.11a$|802\.11n$|802\.11g$') { $line += " —— 只协商到 $($w.radioType)" }
        $details.Add($line)
    }
    if ($wifiConnected.Count -lt $wifiRows.Count) {
        $down = @($wifiRows | Where-Object { -not $_.connected } | ForEach-Object { $_.name })
        if ($down.Count -gt 0) { $details.Add("未连接: $($down -join ', ')") }
    }
    $wifiValue = ($values -join ' | ')
    $wifiDetail = ($details -join ' | ')
    $wifiStatus = if ($warnCount -gt 0) { 'warn' } else { 'ok' }
} elseif ($wifiRows.Count -gt 0) {
    # A radio exists but is not associated. If a cable is carrying the traffic,
    # Wi-Fi signal is not a fault to chase.
    $names = @($wifiRows | ForEach-Object { $_.name }) -join ', '
    if ($wiredUp.Count -gt 0) {
        $wifiStatus = 'skip'
        $wifiDetail = "无线网卡（$names）未连接，当前走有线（$(@($wiredUp | ForEach-Object { $_.name }) -join ', ')），无需体检 Wi-Fi"
    } else {
        $wifiStatus = 'warn'
        $wifiDetail = "无线网卡（$names）存在但未连接到任何 AP，且没有有线连接在用"
    }
} else {
    $why = '本机没有无线网卡'
    if ($wirelessAdapters.Count -gt 0) { $why = "无线网卡（$(@($wirelessAdapters | ForEach-Object { $_.name }) -join ', ')）没有向 WLAN 服务注册接口" }
    if ($wiredUp.Count -gt 0) {
        $wifiStatus = 'skip'
        $wifiDetail = "$why；当前走有线（$(@($wiredUp | ForEach-Object { $_.name }) -join ', ')）"
    } else {
        $wifiStatus = 'skip'
        $wifiDetail = $why
    }
    if ($wlan.error -and $wlan.error -notmatch '没有|no wireless') { $wifiDetail = "$wifiDetail；netsh 输出: $($wlan.error)" }
}
Add-Step -Id 'wifi:信号' -Label 'Wi-Fi 信号' -Status $wifiStatus -Detail $wifiDetail -Ms ([int]$wlan.ms) -Group 'WiFi 体检' -Value $wifiValue

# ---- 9. DNS 优选 ----------------------------------------------------------------
# Why measure instead of judging by name recognition: the point of switching DNS
# is latency, and latency depends on where this machine sits. All servers are
# asked the SAME name so the comparison is about the resolver, not the domain.
#
# Every query passes -Server (including the ones this machine is configured to
# use), which bypasses the OS resolver cache. That is what makes the numbers
# comparable: a cached answer is served in ~4 ms regardless of how slow the
# resolver is, so mixing cached and uncached reads would rank the current
# server first by construction and hide exactly the case worth reporting.
$dnsBudgetMs = 10000
$dnsDeadline = (Get-Date).AddMilliseconds($dnsBudgetMs)
$dnsStepSw = [Diagnostics.Stopwatch]::StartNew()
# An uncached name keeps the comparison honest even if a third party has warmed
# the cache for the common names.
$cachedNames = @()
try { $cachedNames = @(Get-DnsClientCache -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Entry }) } catch { }
$dnsProbeName = $DnsProbeName
foreach ($candName in @('www.baidu.com', 'www.qq.com', 'www.taobao.com', 'www.jd.com')) {
    if ($cachedNames -notcontains $candName) { $dnsProbeName = $candName; break }
}
$dnsCandidateIps = @($DnsCandidates | ForEach-Object { $_.ip })
$dnsCurrentIps = @($dnsServers)
$dnsRows = [System.Collections.Generic.List[object]]::new()

# Measure the configured servers FIRST. The budget is 10 s and five candidates
# already cost up to 7.5 s worst case, so measuring candidates first let a slow
# resolver push the "current" reading off the end of the budget — the one number
# the whole step exists to produce. Ranking is unaffected by measurement order.
$dnsMeasureOrder = [System.Collections.Generic.List[object]]::new()
foreach ($ip in @($dnsCurrentIps | Where-Object { $_ })) {
    $dnsMeasureOrder.Add([ordered]@{ ip = $ip; label = '当前设置'; current = $true })
}
foreach ($c in $DnsCandidates) {
    $isCur = ($dnsCurrentIps -contains $c.ip)
    $dnsMeasureOrder.Add([ordered]@{ ip = $c.ip; label = $c.label; current = $isCur })
}
foreach ($m in $dnsMeasureOrder) {
    $remaining = [int]($dnsDeadline - (Get-Date)).TotalMilliseconds
    if ($remaining -lt 400) {
        $dnsRows.Add([ordered]@{ ip = $m.ip; label = $m.label; ok = $false; ms = -1; timedOut = $false; current = [bool]$m.current; measured = $false; error = '总预算用尽，未测' })
        continue
    }
    $to = [int][math]::Min(1500, $remaining)
    $r = Invoke-DnsProbe -Server $m.ip -Name $dnsProbeName -TimeoutMs $to
    $dnsRows.Add([ordered]@{ ip = $m.ip; label = $m.label; ok = [bool]$r.ok; ms = [int]$r.ms; timedOut = [bool]$r.timedOut; current = [bool]$m.current; measured = $true; error = [string]$r.error })
}
# Rank the servers that actually answered. OrderedDictionary rows: sorting by
# -Property <key> silently does nothing here, so the scriptblock is required.
$dnsAnswered = @($dnsRows | Where-Object { $_.ok } | Sort-Object -Property { [int64]$_.ms })
$rank = 0
foreach ($row in $dnsAnswered) {
    $rank++
    $row['rank'] = $rank
}
$dnsFastest = if ($dnsAnswered.Count -gt 0) { $dnsAnswered[0] } else { $null }
$dnsCurrentAnswered = @($dnsAnswered | Where-Object { $_.current })
$dnsCurrentBest = if ($dnsCurrentAnswered.Count -gt 0) { $dnsCurrentAnswered[0] } else { $null }
$dnsTableParts = [System.Collections.Generic.List[string]]::new()
# Printed in rank order, so the table and the stated rank cannot disagree.
# Unmeasured / failed rows go last: they have no rank but still have to be shown,
# because "this server did not answer" is a result, not a missing value.
foreach ($row in $dnsAnswered) {
    # The configured servers are labelled "当前设置" already; tagging them again
    # produced "（当前设置，当前设置）".
    $tag = if ($row.current -and $row.label -ne '当前设置') { '，当前设置' } else { '' }
    $dnsTableParts.Add("$($row.ip)（$($row.label)$tag）=$($row.ms)ms")
}
foreach ($row in @($dnsRows | Where-Object { -not $_.ok })) {
    $tag = if ($row.current -and $row.label -ne '当前设置') { '，当前设置' } else { '' }
    if (-not $row.measured) { $dnsTableParts.Add("$($row.ip)（$($row.label)$tag）=未测（$($row.error)）") }
    elseif ($row.timedOut) { $dnsTableParts.Add("$($row.ip)（$($row.label)$tag）=超时 $($row.ms)ms") }
    else { $dnsTableParts.Add("$($row.ip)（$($row.label)$tag）=失败$(if ($row.error) { "（$($row.error)）" } else { '' })") }
}
$dnsTableStr = ($dnsTableParts -join '  ')
$dnsElapsed = [int]$dnsStepSw.ElapsedMilliseconds
if ($dnsAnswered.Count -eq 0) {
    $dnsStatus = 'skip'
    $dnsValue = '所有候选 DNS 均未测出结果'
    $dnsDetail = "五个候选 DNS 在 ${dnsProbeName} 上全部失败或超时，无法比较（不填 0，也不猜）: $dnsTableStr"
} else {
    $fastestMs = [int]$dnsFastest.ms
    $curMs = if ($dnsCurrentBest) { [int]$dnsCurrentBest.ms } else { $null }
    $curRank = if ($dnsCurrentBest) { [int]$dnsCurrentBest['rank'] } else { 0 }
    $totalRanked = $dnsAnswered.Count
    $dnsValue = "最快=$fastestMs ms（$($dnsFastest.ip)） 当前=$(if ($null -ne $curMs) { "$curMs ms" } else { '未测出' })"
    if ($dnsCurrentIps.Count -eq 0) {
        $dnsStatus = 'warn'
        $dnsDetail = "没有配置任何 DNS 服务器；候选最快 $($dnsFastest.ip)（$($dnsFastest.label)）${fastestMs}ms。$dnsTableStr"
    } elseif ($null -eq $curMs) {
        $dnsStatus = 'warn'
        $dnsDetail = "当前设置的 DNS（$($dnsCurrentIps -join ', ')）解析 ${dnsProbeName} 失败或超时，而候选 $($dnsFastest.ip) 可用（${fastestMs}ms）: $dnsTableStr"
    } elseif ($curMs -gt ($fastestMs * 3) -and $curMs -gt ($fastestMs + 60)) {
        $dnsStatus = 'warn'
        $dnsDetail = "当前设置的 DNS 排第 $curRank 名（共 $totalRanked 个测出结果），比最快的 $($dnsFastest.ip)（$($dnsFastest.label)）慢 $([math]::Round($curMs / [math]::Max($fastestMs, 1), 1)) 倍；可用于 action=dnspick 切换。$dnsTableStr"
    } else {
        $dnsStatus = 'ok'
        $dnsDetail = "当前设置的 DNS 排第 $curRank 名（共 $totalRanked 个测出结果），${curMs}ms vs 最快 ${fastestMs}ms，差距不足以建议切换。$dnsTableStr"
    }
    $dnsDetail += "；测试域名 $dnsProbeName（各服务器各一次，-Server 查询不走系统缓存）"
}
Add-Step -Id 'dns:优选' -Label 'DNS 优选' -Status $dnsStatus -Detail $dnsDetail -Ms $dnsElapsed -Group 'DNS 优选' -Value $dnsValue

# ---- verdict -------------------------------------------------------------------
# Report the FIRST step that is neither ok nor skip: that is where the chain
# actually broke (a fail) or where the only remaining complaint is (a warn), and
# everything after a fail fails as a consequence, not as a separate problem.
$firstFail = $null
foreach ($s in $steps) {
    if ($s.status -ne 'ok' -and $s.status -ne 'skip') { $firstFail = $s; break }
}
$verdict =
    if ($firstFail -and $firstFail.id -eq 'link') { '网卡没有连接：检查网线、Wi-Fi 开关、飞行模式' }
    elseif ($firstFail -and $firstFail.id -eq 'ip') { '连上了但拿不到 IP：路由器/DHCP 问题，或需要重新获取地址' }
    elseif ($firstFail -and $firstFail.id -eq 'gateway-config') { '没有默认网关：网络配置缺失' }
    elseif ($firstFail -and $firstFail.id -eq 'gateway-ping') { '网关不通：本机到路由器的链路有问题' }
    elseif ($firstFail -and $firstFail.id -eq 'dns') { 'DNS 解析失败：能连网但打不开网页，通常是 DNS 设置问题' }
    elseif ($firstFail -and $firstFail.id -eq 'internet') { '内网通但外网不通：可能是路由器未联网、代理或防火墙拦截' }
    elseif ($firstFail -and $firstFail.id -eq 'wifi:信号') { '链路都通，但 Wi-Fi 这一环有异常：先看信号强度与协商速率，再怀疑上游' }
    elseif ($firstFail -and $firstFail.id -eq 'dns:优选') { '链路都通，但当前 DNS 明显慢于可选服务器：可用 action=dnspick 换成更快的 DNS' }
    elseif ($proxyActive) { '各环节都通，但系统代理处于启用状态——若网页仍打不开，先关掉代理试试' }
    else { '网络链路各环节正常' }

$out = [ordered]@{
    ok = $true
    elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    verdict = $verdict
    firstFail = if ($firstFail) { $firstFail.id } else { '' }
    online = $internetOk
    steps = @($steps)
    adapters = @($adapters)
    ipConfig = @($ipConfig)
    dnsServers = @($dnsServers)
    proxy = $proxy
    winhttp = $winhttp.Trim()
    hostsPath = $hostsPath
    hostsBlocked = $hostsBlocked
    hostsEntries = @($hostsEntries)
}
[Console]::Out.Write((ConvertTo-Json -InputObject $out -Depth 6 -Compress))
