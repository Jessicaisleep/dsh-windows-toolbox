# ---------------------------------------------------------------------------
# junklib.ps1 — the whitelist and the deletion primitives for junk.ps1.
#
# Split out so it can be dot-sourced and exercised directly by the test suite
# against a sandbox directory. junk.ps1 owns the parameter file and the flow;
# everything that decides *what may be touched* and *how it is removed* lives
# here, in one place, with no environment-dependent side effects at load time.
#
# Rules baked into this file:
#  • Only the CONTENTS of a cache directory are removed; the directory itself
#    always survives. Deleting e.g. ...\Edge\User Data\Default\Cache outright
#    makes Edge recreate it with wrong ACLs and lose the profile association.
#  • A target is a fixed record. There is no way to pass a path in from outside.
#  • Nine groups, mirroring the 360 toolbox's cleanup section:
#      temp / browser / system / update / recycle  — file and cache targets
#      privacy  — browser cookie stores
#      traces   — recent-item lists and shell history
#      registry — provably dead registry values (per-item, backed up, never bulk)
#      plugins  — browser extension discovery (read-only, never deletes)
#
# Kinds and what each one is allowed to do:
#   dirContent  empty a directory but keep it and its first-level subdirectories
#   files       delete only the files matching the target filter
#   recycle     Clear-RecycleBin
#   flushdns    ipconfig /flushdns (no bytes)
#   cookieFiles delete cookie files, but only after proving they are not locked
#   regValues   delete individual dead registry VALUES, after a reg export backup
#   regValuesByName
#               same, but the path lives in the VALUE NAME and the data is just a
#               display string (MuiCache). A separate kind on purpose: judging the
#               data there would flag nothing and delete nothing.
#   regDeadSubkeys
#               delete whole registry SUBKEYS that provably point at a missing
#               executable (App Paths). Every subkey is exported on its own
#               before anything is removed; one failed export aborts the target.
#   regDetect   read-only registry inspection; never writes anything
#   discoverExt read-only extension discovery; never deletes anything
#
# Deliberately NOT cleaned:
#   Flash cookies (%APPDATA%\Macromedia\Flash Player\#SharedObjects). Adobe
#   ended Flash support on 2020-12-31 and current browsers refuse Flash content,
#   so a Flash cookie store is either absent or dead weight. There is no target
#   for it on purpose: reporting "0 B cleaned" there would be theatre.
# ---------------------------------------------------------------------------

# --- small private helpers --------------------------------------------------

function _Test-RootedPath {
    <# True only for a string that claims to be an absolute filesystem path. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match '^[A-Za-z]:\\') { return $true }
    if ($Value -match '^\\\\[^\\]+\\') { return $true }
    return $false
}

function _Get-DeadRegValues {
    <#
      Returns the values of one key that can be PROVEN dead, as
      [ordered]@{ name; value } records. Everything else is left alone:

        * binary data is never decoded — RecentDocs stores raw shell PIDLs and
          guessing at them is how a cleaner eats a real entry;
        * non-path strings (a URL, a window title, "此电脑") are never judged;
        * an unexpanded %VAR% path is not judged, because we cannot resolve it
          without changing the data;
        * RunMRU stores its entries as "<command>\<sequence>", so when the raw
          string fails we retry once with the trailing "\<digits>" stripped —
          and a hit there KEEPS the value. Missing a dead entry is fine;
          deleting a live one is not.
    #>
    param($Key)
    $dead = [System.Collections.Generic.List[object]]::new()
    if (-not $Key) { return , $dead }

    foreach ($n in @($Key.GetValueNames())) {
        # The unnamed default value belongs to the app, not to a history list.
        if ([string]::IsNullOrEmpty($n)) { continue }

        $kindName = $null
        try { $kindName = [string]$Key.GetValueKind($n) } catch { continue }
        if ($kindName -ne 'String' -and $kindName -ne 'ExpandString') { continue }

        $raw = $null
        try { $raw = [string]$Key.GetValue($n) } catch { continue }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        if (-not (_Test-RootedPath $raw)) { continue }

        if (Test-Path -LiteralPath $raw) { continue }

        $revived = $false
        if ($raw -match '^(.*)\\[0-9]+$') {
            $stem = $Matches[1]
            if ((_Test-RootedPath $stem) -and (Test-Path -LiteralPath $stem)) { $revived = $true }
        }
        if ($revived) { continue }

        $dead.Add([ordered]@{ name = $n; value = $raw })
    }
    return , $dead
}

function _Get-DeadMuiCacheValues {
    <#
      MuiCache stores "<full exe path>.FriendlyAppName" = "<display name>".
      The path is in the value NAME, so that is what gets judged here; the data
      ("Internet Explorer") is a label and must never be read as a path — doing
      that would flag either all 343 values or none of them. Only the two
      suffixes Explorer actually writes are recognised; a value name in any
      other shape is left alone rather than guessed at.
    #>
    param($Key)
    $dead = [System.Collections.Generic.List[object]]::new()
    if (-not $Key) { return , $dead }

    foreach ($n in @($Key.GetValueNames())) {
        if ([string]::IsNullOrEmpty($n)) { continue }
        if ($n -notmatch '^(?<stem>.+)\.(?:FriendlyAppName|ApplicationCompany)$') { continue }
        $stem = [string]$Matches['stem']
        if (-not (_Test-RootedPath $stem)) { continue }
        if (Test-Path -LiteralPath $stem) { continue }

        $display = ''
        try { $display = [string]$Key.GetValue($n) } catch { $display = '' }
        $dead.Add([ordered]@{ name = $n; value = $stem; display = $display })
    }
    return , $dead
}

function _Get-AppPathsRoots {
    <#
      App Paths lives twice on a 64-bit machine: the native key and the
      32-bit mirror under WOW6432Node. Both are read so a leftover registered
      by a 32-bit installer is not missed. Read-only.
    #>
    param([string]$Path)
    $roots = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Path)) { return , $roots }
    $roots.Add($Path)
    if ($Path -match 'WOW6432Node') { return , $roots }
    if ($Path -notmatch '(?i)Microsoft\\Windows\\CurrentVersion\\App Paths$') { return , $roots }
    $roots.Add('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths')
    return , $roots
}

function _Get-DeadRegSubkeys {
    <#
      App Paths maps "app.exe" -> default value = the executable's full path.
      Returns the subkeys whose default value is an absolute path that no
      longer exists, as [ordered]@{ name; keyPath; value }.

      Two deliberate omissions, because deleting a whole subkey is heavier
      than deleting a value:
        * NO default value => skipped, not deleted. 11 subkeys here have an
          empty default but still carry meaningful data (UseURL, Path,
          BlockOnTSNonInstallMode), so "empty default" is not a shell.
        * a default that is not an absolute path (a URL, "System", an
          unexpanded %VAR%) is not judged at all.
    #>
    param([string[]]$Roots)
    $dead = [System.Collections.Generic.List[object]]::new()
    foreach ($root in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $rootKey = Get-Item -LiteralPath $root -ErrorAction SilentlyContinue
        if (-not $rootKey) { continue }

        foreach ($sub in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $raw = $null
            try { $raw = [string]$sub.GetValue('') } catch { continue }
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }

            # Stored paths are frequently quoted ("C:\...\app.exe"): Test-Path
            # fails on the quotes, so without the strip every quoted-but-live
            # registration would look dead.
            $probe = $raw.Trim().Trim('"').Trim()
            if (-not (_Test-RootedPath $probe)) { continue }
            if ($probe.Contains('%')) { continue }
            if (Test-Path -LiteralPath $probe) { continue }

            $keyPath = $null
            try { $keyPath = [string]$sub.PSPath } catch { }
            if ([string]::IsNullOrWhiteSpace($keyPath)) { try { $keyPath = [string]$sub.Name } catch { } }
            if ([string]::IsNullOrWhiteSpace($keyPath)) { continue }

            $leaf = $null
            try { $leaf = [string]$sub.PSChildName } catch { }
            if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = ($keyPath -split '\\')[-1] }

            $dead.Add([ordered]@{ name = $leaf; keyPath = $keyPath; value = $probe })
        }
    }
    return , $dead
}

function _Measure-FirewallRules {
    <#
      Counts firewall rules whose program does not exist on disk. Read-only by
      contract: this tool never creates, edits or deletes a firewall rule —
      the WPM side owns that. Reports 0 bytes for the same reason (a rule holds
      no file-system space, and a made-up number would inflate "可清理").

      The program path is inside the rule DATA as "App=<path>", not in the value
      name, so each data string is parsed rather than trusted. Every unique path
      is resolved once (542 rules here share far fewer programs).
    #>
    param([string]$Path)
    $out = [ordered]@{ exists = $false; total = 0; dead = 0; system = 0; noApp = 0; unjudged = 0 }

    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key) { return $out }
    $out.exists = $true

    $names = @($key.GetValueNames())
    $total = $names.Count
    $dead = 0; $sys = 0; $noApp = 0; $unjudged = 0
    $verdict = @{}

    foreach ($n in $names) {
        $raw = $null
        try { $raw = [string]$key.GetValue($n) } catch { $unjudged++; continue }
        if ([string]::IsNullOrWhiteSpace($raw)) { $noApp++; continue }

        $app = ''
        if ($raw -match '(?i)(?:^|\|)App=([^|]*)') { $app = [string]$Matches[1] }
        if ([string]::IsNullOrWhiteSpace($app)) { $noApp++; continue }
        if ($app.Trim() -eq 'System') { $sys++; continue }

        $probe = $app.Trim().Trim('"').Trim()
        # Not a path we can judge: a bare program name, a URL, an unexpanded
        # environment variable. Counted as unjudged, never as dead.
        if (-not (_Test-RootedPath $probe)) { $unjudged++; continue }
        if ($probe.Contains('%')) { $unjudged++; continue }

        $k = $probe.ToLowerInvariant()
        if (-not $verdict.ContainsKey($k)) { $verdict[$k] = [bool](Test-Path -LiteralPath $probe) }
        if (-not $verdict[$k]) { $dead++ }
    }

    $out.total = $total
    $out.dead = $dead
    $out.system = $sys
    $out.noApp = $noApp
    $out.unjudged = $unjudged
    return $out
}

function _Backup-RegKey {
    <#
      Exports one key with reg.exe into
      %LOCALAPPDATA%\dsh-windows-toolbox\regbackup and returns the file path, or
      $null when anything at all went wrong. A $null return means the caller
      MUST abort: no backup, no deletion, no "best effort".

      reg.exe wants HKEY_CURRENT_USER\..., not the provider form HKCU:\...;
      a $key.Name from Get-Item is already exactly the right shape.
    #>
    param($Key, [string]$Prefix)

    $dir = Join-Path $env:LOCALAPPDATA 'dsh-windows-toolbox\regbackup'
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
    } catch { return $null }

    $hivePath = $null
    try { $hivePath = [string]$Key.Name } catch { }
    if ([string]::IsNullOrWhiteSpace($hivePath)) {
        try { $hivePath = ($Key.PSPath -replace '^.*Registry::', '') } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($hivePath)) { return $null }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName = ($Prefix -replace '[^A-Za-z0-9._-]', '_')
    $dest = Join-Path $dir ("{0}-{1}.reg" -f $safeName, $stamp)

    try {
        & reg.exe export $hivePath $dest /y 2>&1 | Out-Null
    } catch { return $null }
    if ($LASTEXITCODE -ne 0) { return $null }

    try {
        if (-not (Test-Path -LiteralPath $dest)) { return $null }
        if ((Get-Item -LiteralPath $dest -ErrorAction Stop).Length -le 0) { return $null }
    } catch { return $null }

    return $dest
}

function _Get-BrowserExtensions {
    <#
      Read-only discovery of installed extensions in one browser profile.

      Layout is <profile>\Extensions\<id>\<version>_<n>\manifest.json — the
      manifest lives in the version directory, NOT at the extension id root.
      Reading the id root yields an empty name for every extension.

      A manifest name is frequently "__MSG_extName__": an i18n key, not a name.
      Those are resolved through _locales\<default_locale>\messages.json; when
      that fails the raw key is discarded and the extension id is shown instead.
      Printing "__MSG_extName__" to a user would be worse than printing nothing.

      Never writes anything. Returns a list of ordered records.
    #>
    param([string]$Root)

    $found = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Root)) { return , $found }
    if (-not (Test-Path -LiteralPath $Root)) { return , $found }

    foreach ($dir in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)) {
        # "Temp" is the installer's scratch directory, not an extension.
        if ($dir.Name -eq 'Temp') { continue }
        $versions = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue)
        if ($versions.Count -eq 0) { continue }

        $name = $null; $version = $null; $updUrl = $null; $defaultLocale = $null
        # The newest version directory is the one the browser actually loads.
        $active = $versions | Sort-Object -Property { $_.LastWriteTimeUtc } | Select-Object -Last 1
        $manifestPath = Join-Path $active.FullName 'manifest.json'
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                $name = [string]$m.name
                $version = [string]$m.version
                $updUrl = [string]$m.update_url
                $defaultLocale = [string]$m.default_locale
            } catch { }
        }

        if ($name -match '^__MSG_(.+)__$') {
            $key = $Matches[1]
            $resolved = $null
            foreach ($loc in @($defaultLocale, 'en', 'en_US', 'zh_CN')) {
                if ([string]::IsNullOrWhiteSpace($loc)) { continue }
                $msgPath = Join-Path $active.FullName (Join-Path '_locales' (Join-Path $loc 'messages.json'))
                if (-not (Test-Path -LiteralPath $msgPath)) { continue }
                try {
                    $msgs = Get-Content -LiteralPath $msgPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
                    $entry = $msgs.PSObject.Properties[$key]
                    if ($entry -and $entry.Value -and $entry.Value.message) { $resolved = [string]$entry.Value.message; break }
                } catch { }
            }
            # No translation -> show the id, never the raw i18n key.
            if ($resolved) { $name = $resolved } else { $name = $dir.Name }
        }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $dir.Name }

        $bytes = 0
        foreach ($f in @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $bytes += [int64]$f.Length
        }

        $found.Add([ordered]@{
            id          = $dir.Name
            name        = $name
            version     = $version
            versions    = $versions.Count
            bytes       = $bytes
            nonStore    = ([string]::IsNullOrWhiteSpace($updUrl) -or ($updUrl -notmatch 'microsoft\.com|google\.com'))
        })
    }
    return , $found
}

# --- the target catalogue ---------------------------------------------------

function Get-JunkTargets {
    <#
      Returns the complete, fixed list of cleanable locations for this machine.
      Paths are resolved here (not by the caller) so the caller can only ever
      name a target by id.
    #>
    $localApp = $env:LOCALAPPDATA
    # Recent items and PSReadLine history live under Roaming, not Local.
    $roamApp = $env:APPDATA
    $systemRoot = $env:SystemRoot
    $list = [System.Collections.Generic.List[object]]::new()

    function _add {
        param($Id, $Label, $LabelEn, $Path, $Group = 'temp', $NeedsAdmin = $false, $Filter = '*', $Kind = 'dirContent', $Note = '')
        $list.Add([ordered]@{
            id = $Id; label = $Label; labelEn = $LabelEn; path = $Path
            group = $Group
            needsAdmin = [bool]$NeedsAdmin; filter = $Filter; kind = $Kind; note = $Note
        })
    }

    # -- temp -----------------------------------------------------------------
    _add 'user-temp'         '用户临时文件'          'User temp'                $env:TEMP -Group 'temp'
    _add 'windows-temp'      '系统临时文件'          'Windows temp'             (Join-Path $systemRoot 'Temp') -Group 'temp' -NeedsAdmin $true
    _add 'crash-dumps'       '崩溃转储'              'Crash dumps'              (Join-Path $localApp 'CrashDumps') -Group 'temp'
    _add 'wer-report'        '错误报告缓存'          'Error reports'            (Join-Path $localApp 'Microsoft\Windows\WER') -Group 'temp'

    # -- browser --------------------------------------------------------------
    _add 'inet-cache'        'IE/系统网络缓存'       'INetCache'                (Join-Path $localApp 'Microsoft\Windows\INetCache') -Group 'browser'
    _add 'edge-cache'        'Edge 缓存'             'Edge cache'               (Join-Path $localApp 'Microsoft\Edge\User Data\Default\Cache') -Group 'browser'
    _add 'edge-code-cache'   'Edge 代码缓存'         'Edge code cache'          (Join-Path $localApp 'Microsoft\Edge\User Data\Default\Code Cache') -Group 'browser'
    _add 'chrome-cache'      'Chrome 缓存'           'Chrome cache'             (Join-Path $localApp 'Google\Chrome\User Data\Default\Cache') -Group 'browser'
    _add 'chrome-code-cache' 'Chrome 代码缓存'       'Chrome code cache'        (Join-Path $localApp 'Google\Chrome\User Data\Default\Code Cache') -Group 'browser'

    # -- system ---------------------------------------------------------------
    _add 'thumb-cache'       '缩略图缓存'            'Thumbnail cache'          (Join-Path $localApp 'Microsoft\Windows\Explorer') -Group 'system' -Filter 'thumbcache_*.db' -Kind 'files' -Note '正在被资源管理器占用时会被跳过，关掉资源管理器可清干净'
    _add 'icon-cache'        '图标缓存'              'Icon cache'               (Join-Path $localApp 'Microsoft\Windows\Explorer') -Group 'system' -Filter 'iconcache_*.db' -Kind 'files' -Note '正在被资源管理器占用时会被跳过'
    _add 'prefetch'          '预读取文件'            'Prefetch'                 (Join-Path $systemRoot 'Prefetch') -Group 'system' -Filter '*.pf' -Kind 'files' -NeedsAdmin $true -Note '会略微影响首次启动速度'
    _add 'dns-cache'         'DNS 解析缓存'          'DNS cache'                '' -Group 'system' -Kind 'flushdns' -Note '不占空间，只清理解析记录'

    # -- update ---------------------------------------------------------------
    _add 'wu-download'       'Windows 更新下载缓存'  'Windows Update cache'     (Join-Path $systemRoot 'SoftwareDistribution\Download') -Group 'update' -NeedsAdmin $true -Note '服务占用中的文件会被跳过'
    _add 'delivery-opt'      '传递优化缓存'          'Delivery Optimization'    (Join-Path $systemRoot 'SoftwareDistribution\DeliveryOptimization') -Group 'update' -NeedsAdmin $true

    # -- recycle --------------------------------------------------------------
    _add 'recycle-bin'       '回收站'                'Recycle bin'              '' -Group 'recycle' -Kind 'recycle'

    # -- privacy: cookie stores ----------------------------------------------
    # Browsers keep every cookie in one SQLite file and hold it open while they
    # run, so deletion fails outright rather than partially. Measured, not
    # assumed: the file is opened exclusively first, and a lock is reported as a
    # skip with an instruction, never as a silent success.
    _add 'edge-cookies'      'Edge Cookie'           'Edge cookies'             (Join-Path $localApp 'Microsoft\Edge\User Data\Default\Network') -Group 'privacy' -Filter 'Cookies*' -Kind 'cookieFiles' -Note '清理后网站需要重新登录；浏览器正在运行时会被跳过，请先关闭 Edge'
    _add 'chrome-cookies'    'Chrome Cookie'         'Chrome cookies'           (Join-Path $localApp 'Google\Chrome\User Data\Default\Network') -Group 'privacy' -Filter 'Cookies*' -Kind 'cookieFiles' -Note '清理后网站需要重新登录；浏览器正在运行时会被跳过，请先关闭 Chrome'
    _add 'inet-cookies'      'IE/系统 Cookie'        'INetCookies'              (Join-Path $localApp 'Microsoft\Windows\INetCookies') -Group 'privacy' -Note '老版 IE 与部分桌面程序共用，通常很小'

    # -- traces: recent lists and shell history -------------------------------
    _add 'recent-lnk'        '最近使用记录（快捷方式）' 'Recent shortcuts'       (Join-Path $roamApp 'Microsoft\Windows\Recent') -Group 'traces' -Filter '*.lnk' -Kind 'files' -Note '只删一级目录下的 .lnk，保留 desktop.ini 与跳转列表子目录'
    _add 'recent-auto'       '跳转列表（自动目标）'   'Jump list (automatic)'    (Join-Path $roamApp 'Microsoft\Windows\Recent\AutomaticDestinations') -Group 'traces' -Filter '*.automaticDestinations-ms' -Kind 'files' -Note '任务栏跳转列表缓存，删除后右键任务栏图标不再显示历史'
    _add 'recent-custom'     '跳转列表（自定义目标）' 'Jump list (custom)'       (Join-Path $roamApp 'Microsoft\Windows\Recent\CustomDestinations') -Group 'traces' -Filter '*.customDestinations-ms' -Kind 'files' -Note '程序自己写入的跳转列表，通常占用最大'
    _add 'ps-history'        'PowerShell 命令历史'    'PowerShell history'       (Join-Path $roamApp 'Microsoft\Windows\PowerShell\PSReadLine') -Group 'traces' -Filter 'ConsoleHost_history.txt' -Kind 'files' -Note '删除后按上下方向键不再补全旧命令'

    # -- registry: provably dead values, one at a time ------------------------
    # Each of these is inspected only. typed-paths and run-mru can drop single
    # values, but only after a reg export of the whole key succeeds; the other
    # two are detection only, on purpose.
    _add 'typed-paths'       '地址栏历史（失效路径）' 'Typed paths (dead)'       'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths' -Group 'registry' -Kind 'regValues' -Note '只删"值本身是绝对路径且该路径已不存在"的项；删前整键导出到 regbackup，可单条回滚'
    _add 'run-mru'           '运行对话框历史（失效路径）' 'Run dialog (dead)'    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU' -Group 'registry' -Kind 'regValues' -Note '同样的判据：只有指向已不存在路径的命令才算失效；非路径命令一律不动'
    _add 'uninstall-shells'  '空壳卸载登记项'        'Empty uninstall entries'  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -Group 'registry' -Kind 'regDetect' -Note '只检测不删除：同时扫描 HKLM、WOW6432Node、HKCU 三个根；删除卸载项可能破坏修复/卸载入口，交由用户手动处理'
    _add 'binary-mru'        '二进制 MRU（仅检测）'  'Binary MRU (detect only)' 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs' -Group 'registry' -Kind 'regDetect' -Note 'RecentDocs/LastVisitedPidlMRU 存的是二进制 PIDL，解码易误判，所以只报告存在性、不解析也不删除'
    _add 'mui-cache'         'MuiCache 失效程序名'   'MuiCache (dead apps)'     'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache' -Group 'registry' -Kind 'regValuesByName' -Note '值名就是程序路径（形如 C:\...\x.exe.FriendlyAppName），只看值名指向的文件是否还在；删前整键导出到 regbackup，可单条回滚'
    _add 'app-paths'         'App Paths 失效登记'    'App Paths (dead)'         'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths' -Group 'registry' -Kind 'regDeadSubkeys' -NeedsAdmin $true -Note '同时读 WOW6432Node 镜像；默认值指向的程序已不存在才删整个子键，每个子键先单独 reg export 备份，任一备份失败即中止本项；默认值为空的子键不当作失效（其中有 UseURL/Path 等有效数据）'
    _add 'firewall-rules'    '防火墙规则失效程序（仅检测）' 'Firewall rules (detect only)' 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules' -Group 'registry' -Kind 'regDetect' -Note '只读统计：程序路径写在规则数据里，数出指向已不存在程序的规则条数；本工具不新建、不修改、不删除任何防火墙规则'

    # -- plugins: discovery only ---------------------------------------------
    _add 'browser-extensions' '浏览器扩展（只读发现）' 'Browser extensions'      (Join-Path $localApp 'Microsoft\Edge\User Data\Default\Extensions') -Group 'plugins' -Kind 'discoverExt' -Note '只读：列出已装扩展数量；卸载扩展有风险，请在浏览器的扩展页自己操作，本工具不删'

    return , $list
}

# --- measuring --------------------------------------------------------------

function Measure-JunkTarget {
    <#  Current size of one target: { exists, files, bytes }. Never throws.  #>
    param($Target)
    $out = [ordered]@{ exists = $false; files = 0; bytes = 0 }

    if ($Target.kind -eq 'recycle') {
        $out.exists = $true
        try {
            $root = Join-Path $env:SystemDrive '$Recycle.Bin'
            if (Test-Path -LiteralPath $root) {
                $bytes = 0; $n = 0
                foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
                    foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                        # $I* are the tiny index blobs that shadow each $R* payload;
                        # counting both doubles the apparent size.
                        if ($f.Name -like '$I*') { continue }
                        $bytes += [int64]$f.Length; $n++
                    }
                }
                $out.bytes = $bytes; $out.files = $n
            }
        } catch { }
        return $out
    }
    if ($Target.kind -eq 'flushdns') { $out.exists = $true; return $out }

    # Registry kinds are handled before any Test-Path: on a registry path
    # Test-Path costs ~400 ms and is the wrong primitive anyway.
    if ($Target.kind -eq 'regValues') {
        $key = Get-Item -LiteralPath $Target.path -ErrorAction SilentlyContinue
        if (-not $key) { return $out }
        $out.exists = $true
        $dead = _Get-DeadRegValues -Key $key
        $out.files = [int]$dead.Count
        # A registry value holds no file-system bytes. Reporting a made-up
        # number here would land in the panel's "可清理" total, so it stays 0.
        $out.bytes = 0
        return $out
    }
    if ($Target.kind -eq 'regValuesByName') {
        $key = Get-Item -LiteralPath $Target.path -ErrorAction SilentlyContinue
        if (-not $key) { return $out }
        $out.exists = $true
        $dead = _Get-DeadMuiCacheValues -Key $key
        $out.files = [int]$dead.Count
        # Same reasoning as regValues: a value is not a file, so 0 bytes.
        $out.bytes = 0
        return $out
    }
    if ($Target.kind -eq 'regDeadSubkeys') {
        $roots = _Get-AppPathsRoots -Path $Target.path
        $anyRoot = $false
        foreach ($r in @($roots)) {
            if (Get-Item -LiteralPath $r -ErrorAction SilentlyContinue) { $anyRoot = $true }
        }
        if (-not $anyRoot) { return $out }
        $out.exists = $true
        $dead = _Get-DeadRegSubkeys -Roots $roots
        $out.files = [int]$dead.Count
        $out.bytes = 0
        return $out
    }
    if ($Target.kind -eq 'regDetect') {
        if ($Target.id -eq 'firewall-rules') {
            $fw = _Measure-FirewallRules -Path $Target.path
            $out.exists = [bool]$fw.exists
            $out.files = [int]$fw.dead
            $out.bytes = 0
            return $out
        }
        if ($Target.id -eq 'uninstall-shells') {
            $shells = 0
            $seen = $false
            $roots = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            )
            foreach ($root in $roots) {
                $rootKey = Get-Item -LiteralPath $root -ErrorAction SilentlyContinue
                if (-not $rootKey) { continue }
                $seen = $true
                foreach ($sub in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                    $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
                    if (-not $props) { continue }
                    if (-not $props.DisplayName) { continue }
                    # An entry that can still repair or uninstall itself is not
                    # a shell, whatever its install path looks like.
                    if ($props.UninstallString -or $props.QuietUninstallString -or $props.ModifyPath) { continue }
                    if (-not $props.InstallLocation) { continue }
                    $loc = ([string]$props.InstallLocation).Trim()
                    if ($loc -eq '') { continue }
                    if (Test-Path -LiteralPath $loc) { continue }
                    $shells++
                }
            }
            if ($seen) { $out.exists = $true }
            $out.files = $shells
            $out.bytes = 0
            return $out
        }
        # binary-mru and anything else regDetect: existence only.
        $probe = Get-Item -LiteralPath $Target.path -ErrorAction SilentlyContinue
        if ($probe) { $out.exists = $true }
        return $out
    }

    if (-not (Test-Path -LiteralPath $Target.path)) { return $out }
    $out.exists = $true

    if ($Target.kind -eq 'discoverExt') {
        $exts = _Get-BrowserExtensions -Root $Target.path
        $out.files = [int]$exts.Count
        # Deliberately 0: this tool cannot free a single byte of an extension, so
        # its size must not inflate the panel's "可清理" total. The real size is
        # reported in the clean-time message instead.
        $out.bytes = 0
        return $out
    }

    if ($Target.kind -eq 'cookieFiles' -or $Target.kind -eq 'files') {
        $hits = @(Get-ChildItem -LiteralPath $Target.path -Filter $Target.filter -File -Force -ErrorAction SilentlyContinue)
        $sum = 0
        foreach ($f in $hits) { $sum += [int64]$f.Length }
        $out.files = $hits.Count
        $out.bytes = $sum
        return $out
    }

    $sum = 0; $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $Target.path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $sum += [int64]$f.Length; $n++
    }
    $out.files = $n
    $out.bytes = $sum
    return $out
}

# --- removing ---------------------------------------------------------------

function Remove-JunkTarget {
    <#
      Empty ONE target. Returns { freed, deleted, skipped, messages }.

      dirContent:  walk one level; for a directory child, remove its children
                   and KEEP the child directory (an app's cache root must exist
                   when the app next starts). For a file child, remove it.
      files:       remove only the files matching the target's filter.
      cookieFiles: prove the file is not locked, then remove it.
      regValues:   export the key, then remove the dead values one by one.
      regDetect / discoverExt: never touch anything; explain why in messages.
      recycle:     Clear-RecycleBin.
      flushdns:    ipconfig /flushdns — no bytes involved.
    #>
    param($Target)

    $freed = 0; $deleted = 0; $skipped = 0
    $messages = [System.Collections.Generic.List[string]]::new()

    switch ($Target.kind) {
        'flushdns' {
            try { & ipconfig /flushdns | Out-Null; $messages.Add('DNS 缓存已刷新') }
            catch { $messages.Add("DNS 刷新失败：$($_.Exception.Message)") }
        }
        'recycle' {
            try {
                $before = Measure-JunkTarget -Target $Target
                Clear-RecycleBin -Force -ErrorAction Stop
                $freed += [int64]$before.bytes
                $deleted += [int]$before.files
            } catch { $messages.Add("回收站清空失败：$($_.Exception.Message)") }
        }
        'cookieFiles' {
            $hits = @(Get-ChildItem -LiteralPath $Target.path -Filter $Target.filter -File -Force -ErrorAction SilentlyContinue)
            if ($hits.Count -eq 0) { $messages.Add('没有找到 Cookie 文件') }
            foreach ($f in $hits) {
                # A running browser holds the cookie database open, and a delete
                # would fail anyway. Ask for exclusive access first so the skip
                # can name the real cause instead of a generic permission error.
                $lockError = $null
                try {
                    $stream = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                    $stream.Close()
                    $stream.Dispose()
                } catch { $lockError = $_.Exception.Message }

                if ($lockError) {
                    $skipped++
                    $messages.Add(("Cookie 文件正被占用，已跳过（请先关闭浏览器再清理）：{0}" -f $f.Name))
                    continue
                }
                try {
                    $len = [int64]$f.Length
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $freed += $len; $deleted++
                } catch {
                    $skipped++
                    $messages.Add(("删除失败（请先关闭浏览器再清理）：{0} — {1}" -f $f.Name, $_.Exception.Message))
                }
            }
        }
        'regValues' {
            $key = Get-Item -LiteralPath $Target.path -ErrorAction SilentlyContinue
            if (-not $key) { $messages.Add('注册表键不存在，无需清理'); break }

            $dead = _Get-DeadRegValues -Key $key
            if ($dead.Count -eq 0) {
                $messages.Add('没有可证明失效的项，未删除任何内容')
                break
            }

            $backup = _Backup-RegKey -Key $key -Prefix $Target.id
            if (-not $backup) {
                # Backup or nothing. No partial, hopeful clean of the registry.
                $messages.Add(("导出备份失败，已中止：{0} 项未删除" -f $dead.Count))
                break
            }
            $messages.Add(("已备份到 {0}" -f $backup))

            foreach ($d in $dead) {
                try {
                    Remove-ItemProperty -LiteralPath $Target.path -Name $d.name -ErrorAction Stop
                    $deleted++
                    $messages.Add(("已删除失效值 {0}（原值 {1}）" -f $d.name, $d.value))
                } catch {
                    $skipped++
                    $messages.Add(("删除值失败：{0} — {1}" -f $d.name, $_.Exception.Message))
                }
            }
        }
        'regValuesByName' {
            # Same contract as regValues: one backup of the whole key, then value
            # by value. The dead list is recomputed here rather than carried over
            # from the scan, so the delete count always equals what this run
            # proved dead — never what a previous scan might have seen.
            $key = Get-Item -LiteralPath $Target.path -ErrorAction SilentlyContinue
            if (-not $key) { $messages.Add('注册表键不存在，无需清理'); break }

            $dead = _Get-DeadMuiCacheValues -Key $key
            if ($dead.Count -eq 0) {
                $messages.Add('没有可证明失效的项，未删除任何内容')
                break
            }

            $backup = _Backup-RegKey -Key $key -Prefix $Target.id
            if (-not $backup) {
                $messages.Add(("导出备份失败，已中止：{0} 项未删除" -f $dead.Count))
                break
            }
            $messages.Add(("已备份到 {0}" -f $backup))

            foreach ($d in $dead) {
                try {
                    Remove-ItemProperty -LiteralPath $Target.path -Name $d.name -ErrorAction Stop
                    $deleted++
                    $messages.Add(("已删除失效值 {0}（指向 {1}）" -f $d.name, $d.value))
                } catch {
                    $skipped++
                    $messages.Add(("删除值失败：{0} — {1}" -f $d.name, $_.Exception.Message))
                }
            }
        }
        'regDeadSubkeys' {
            # Heaviest write in this file, so the strictest gate: EACH subkey is
            # exported on its own before it is removed, and the first failed
            # export stops the whole target for good. A half-cleaned App Paths
            # tree with no backup is exactly the state this must never produce.
            $roots = _Get-AppPathsRoots -Path $Target.path
            $dead = _Get-DeadRegSubkeys -Roots $roots
            if ($dead.Count -eq 0) {
                $messages.Add('没有可证明失效的登记项，未删除任何内容')
                break
            }

            $done = 0
            $aborted = $false
            foreach ($d in $dead) {
                $subKey = Get-Item -LiteralPath $d.keyPath -ErrorAction SilentlyContinue
                if (-not $subKey) {
                    $skipped++
                    $messages.Add(("子键已不存在，跳过：{0}" -f $d.name))
                    continue
                }

                $backup = _Backup-RegKey -Key $subKey -Prefix ("{0}-{1}" -f $Target.id, $d.name)
                if (-not $backup) {
                    $aborted = $true
                    $messages.Add(("导出备份失败，已中止本项：{0} 及其后 {1} 项未删除" -f $d.name, ($dead.Count - $done)))
                    break
                }

                try {
                    Remove-Item -LiteralPath $d.keyPath -Recurse -Force -ErrorAction Stop
                    $deleted++
                    $done++
                    $messages.Add(("已删除失效登记 {0}（原指向 {1}），备份 {2}" -f $d.name, $d.value, $backup))
                } catch {
                    $skipped++
                    $messages.Add(("删除子键失败：{0} — {1}（备份 {2}）" -f $d.name, $_.Exception.Message, $backup))
                }
            }
            if ($aborted) { break }
        }
        'regDetect' {
            if ($Target.id -eq 'firewall-rules') {
                $fw = _Measure-FirewallRules -Path $Target.path
                $messages.Add(("只读检测：共 {0} 条规则，其中 {1} 条指向已不存在的程序；本工具不新建、不修改、不删除防火墙规则，请到「高级安全 Windows Defender 防火墙」里手动处理" -f $fw.total, $fw.dead))
                break
            }
            $messages.Add('只读检测项：本工具不修改注册表中的这一类内容')
        }
        'discoverExt' {
            $exts = _Get-BrowserExtensions -Root $Target.path
            $bytes = 0
            $nonStore = 0
            foreach ($e in $exts) {
                $bytes += [int64]$e.bytes
                if ($e.nonStore) { $nonStore++ }
            }
            $messages.Add(("发现 {0} 个扩展，合计 {1:N1} MB；本工具不删除扩展" -f $exts.Count, ($bytes / 1MB)))
            foreach ($e in $exts) {
                $tag = ''
                if ($e.nonStore) { $tag = ' [非商店来源]' }
                if ([int]$e.versions -gt 1) { $tag += (" [含 {0} 个版本目录]" -f $e.versions) }
                $messages.Add(("  {0}  {1} v{2}  {3:N1} MB{4}" -f $e.name, $e.id, $e.version, ([int64]$e.bytes / 1MB), $tag))
            }
            $messages.Add('如需卸载，请打开浏览器的扩展管理页自己操作：删除扩展目录有风险')
        }
        'files' {
            foreach ($f in @(Get-ChildItem -LiteralPath $Target.path -Filter $Target.filter -File -Force -ErrorAction SilentlyContinue)) {
                try {
                    $len = [int64]$f.Length
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $freed += $len; $deleted++
                } catch { $skipped++ }
            }
        }
        default {
            foreach ($child in @(Get-ChildItem -LiteralPath $Target.path -Force -ErrorAction SilentlyContinue)) {
                if ($child.PSIsContainer) {
                    foreach ($grand in @(Get-ChildItem -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue)) {
                        try {
                            $len = 0
                            if (-not $grand.PSIsContainer) { $len = [int64]$grand.Length }
                            Remove-Item -LiteralPath $grand.FullName -Recurse -Force -ErrorAction Stop
                            $freed += $len; $deleted++
                        } catch { $skipped++ }
                    }
                } else {
                    try {
                        $len = [int64]$child.Length
                        Remove-Item -LiteralPath $child.FullName -Force -ErrorAction Stop
                        $freed += $len; $deleted++
                    } catch { $skipped++ }
                }
            }
        }
    }

    return [ordered]@{
        freed = $freed; deleted = $deleted; skipped = $skipped; messages = @($messages)
    }
}
