param([string]$ParamFile)

# ---------------------------------------------------------------------------
# dupfiles.ps1 — find duplicate files under a chosen root.
#
# Read-only: nothing is deleted here. Grouping of the results is done by the JS
# layer; this script only reports groups of files that are byte-identical.
#
# Three-stage funnel, because hashing everything is far too slow:
#   1. group by exact size           — cheap, discards the vast majority
#   2. hash the first 64 KiB         — separates most same-size-but-different files
#   3. hash the whole file           — only for survivors of stage 2
# A file is only reported as a duplicate when stage 3 says the bytes match.
#
# Root is named by id, never by a caller-supplied path (same reason as
# bigfiles.ps1: an arbitrary path reaches network shares and other users' data).
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'

$params = @{}
if ($ParamFile -and (Test-Path -LiteralPath $ParamFile)) {
    $raw = Get-Content -LiteralPath $ParamFile -Raw -Encoding UTF8
    if ($raw) { $params = $raw | ConvertFrom-Json }
}

$rootId = if ($params.root) { [string]$params.root } else { 'user' }
$minKb = 1
if ($null -ne $params.minKb) { $minKb = [int]$params.minKb }
if ($minKb -lt 1) { $minKb = 1 }
$limit = 100
if ($null -ne $params.limit) { $limit = [int]$params.limit }
if ($limit -lt 1) { $limit = 1 }
if ($limit -gt 500) { $limit = 500 }
$maxSeconds = 60
if ($null -ne $params.maxSeconds) { $maxSeconds = [int]$params.maxSeconds }
$maxCandidateFiles = 4000
if ($null -ne $params.maxCandidateFiles) { $maxCandidateFiles = [int]$params.maxCandidateFiles }

# See rootlib.ps1: never join $env:USERPROFILE for known folders, they are
# commonly redirected (this machine: Documents=E:\Documents, Downloads=E:\Downloads,
# Desktop=D:\Desktop, Pictures=D:\Pictures).
. (Join-Path $PSScriptRoot 'rootlib.ps1')
$roots = Get-ScanRoots

if (-not $roots.Contains($rootId)) {
    $o = [ordered]@{ ok = $false; error = "unknown root: $rootId"; roots = @($roots.Keys); groups = @() }
    [Console]::Out.Write((ConvertTo-Json -InputObject $o -Depth 4 -Compress)); exit 0
}
$rootPath = [string]$roots[$rootId]
if (-not (Test-Path -LiteralPath $rootPath)) {
    $o = [ordered]@{ ok = $false; error = "root does not exist: $rootPath"; roots = @($roots.Keys); groups = @() }
    [Console]::Out.Write((ConvertTo-Json -InputObject $o -Depth 4 -Compress)); exit 0
}

$started = Get-Date
$minBytes = [int64]$minKb * 1KB
$truncated = $false
$scanned = 0

# ---- stage 1: bucket by size -------------------------------------------------
$bySize = @{}
foreach ($f in (Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue)) {
    $scanned++
    $len = $f.Length
    if ($null -eq $len) { continue }
    $len = [int64]$len
    if ($len -lt $minBytes) { continue }
    if (-not $bySize.ContainsKey($len)) { $bySize[$len] = [System.Collections.Generic.List[object]]::new() }
    $bySize[$len].Add($f)
    if (((Get-Date) - $started).TotalSeconds -gt $maxSeconds) { $truncated = $true; break }
}

# ---- stage 2: partial hash within each size bucket ---------------------------
$candidates = [System.Collections.Generic.List[object]]::new()
$partialCount = 0
foreach ($size in $bySize.Keys) {
    $bucket = $bySize[$size]
    if ($bucket.Count -lt 2) { continue }
    if ($partialCount -ge $maxCandidateFiles) { $truncated = $true; break }
    if ($size -le 64KB) {
        # Small file: the full hash below is cheaper than a partial one.
        foreach ($f in $bucket) { $candidates.Add([pscustomobject]@{ File = $f; Partial = '' }) }
        continue
    }
    foreach ($f in $bucket) {
        $partialCount++
        $partial = ''
        try {
            $fs = [System.IO.File]::OpenRead($f.FullName)
            try {
                $buf = New-Object byte[] 65536
                $read = $fs.Read($buf, 0, $buf.Length)
                $partial = [BitConverter]::ToString($buf, 0, [Math]::Max($read, 0))
            } finally { $fs.Dispose() }
        } catch { $partial = '' }
        $candidates.Add([pscustomobject]@{ File = $f; Partial = $partial })
    }
    if (((Get-Date) - $started).TotalSeconds -gt $maxSeconds) { $truncated = $true; break }
}

# ---- stage 3: full hash, grouped by (size, partial) --------------------------
$buckets = @{}
foreach ($c in $candidates) {
    $f = $c.File
    $key = '{0}|{1}' -f $f.Length, $c.Partial
    if (-not $buckets.ContainsKey($key)) { $buckets[$key] = [System.Collections.Generic.List[object]]::new() }
    $buckets[$key].Add($f)
}

$groups = [System.Collections.Generic.List[object]]::new()
$hashed = 0
foreach ($key in $buckets.Keys) {
    $bucket = $buckets[$key]
    if ($bucket.Count -lt 2) { continue }
    if (((Get-Date) - $started).TotalSeconds -gt $maxSeconds) { $truncated = $true; break }
    $byHash = @{}
    foreach ($f in $bucket) {
        $hashed++
        $hash = ''
        try { $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $hash = '' }
        if (-not $hash) { continue }
        if (-not $byHash.ContainsKey($hash)) { $byHash[$hash] = [System.Collections.Generic.List[object]]::new() }
        $byHash[$hash].Add($f)
    }
    foreach ($h in $byHash.Keys) {
        $same = $byHash[$h]
        if ($same.Count -lt 2) { continue }
        $files = [System.Collections.Generic.List[object]]::new()
        foreach ($f in $same) {
            $files.Add([ordered]@{
                path = $f.FullName
                name = $f.Name
                folder = $f.DirectoryName
                bytes = [int64]$f.Length
                modified = $f.LastWriteTimeUtc.ToString('o')
            })
        }
        $wasted = [int64]$same[0].Length * ($same.Count - 1)
        $groups.Add([ordered]@{
            hash = $h
            bytes = [int64]$same[0].Length
            count = $same.Count
            wasted = $wasted
            files = @($files)
        })
    }
}

# Scriptblock sort — see bigfiles.ps1: -Property <key> does not order
# OrderedDictionary rows, so the "biggest waste first" list came back unsorted.
$sorted = @($groups | Sort-Object -Property { [int64]$_.wasted } -Descending | Select-Object -First $limit)
$wastedTotal = [int64]0
foreach ($g in $sorted) { $wastedTotal += [int64]$g.wasted }

$o = [ordered]@{
    ok = $true
    root = $rootId
    rootPath = $rootPath
    minKb = $minKb
    scanned = $scanned
    hashed = $hashed
    groupsTotal = $groups.Count
    shown = $sorted.Count
    wastedTotal = $wastedTotal
    truncated = $truncated
    elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    groups = @($sorted)
}
[Console]::Out.Write((ConvertTo-Json -InputObject $o -Depth 6 -Compress))
