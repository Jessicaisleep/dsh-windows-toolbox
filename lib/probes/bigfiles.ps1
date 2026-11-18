param([string]$ParamFile)

# ---------------------------------------------------------------------------
# bigfiles.ps1 — find the largest files under a chosen root.
#
# The root is named by ID ('user' / 'downloads' / 'desktop' / 'documents' /
# 'c:' / 'd:' / 'e:'), never by a path from the caller: an arbitrary path would
# let a request walk anywhere on the machine, including network shares.
#
# Reads are strictly read-only. Nothing here deletes anything.
#
# UTF-8 on stdout, or every Chinese label comes back as mojibake through the
# Node pipe (PowerShell defaults to the OEM code page).
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'

$params = @{}
if ($ParamFile -and (Test-Path -LiteralPath $ParamFile)) {
    $raw = Get-Content -LiteralPath $ParamFile -Raw -Encoding UTF8
    if ($raw) { $params = $raw | ConvertFrom-Json }
}

$rootId = if ($params.root) { [string]$params.root } else { 'user' }
$minMb = 100
if ($null -ne $params.minMb) { $minMb = [int]$params.minMb }
if ($minMb -lt 1) { $minMb = 1 }
$limit = 200
if ($null -ne $params.limit) { $limit = [int]$params.limit }
if ($limit -lt 1) { $limit = 1 }
if ($limit -gt 2000) { $limit = 2000 }
$maxSeconds = 60
if ($null -ne $params.maxSeconds) { $maxSeconds = [int]$params.maxSeconds }

# Known folders must be resolved through the shell folder API, never by joining
# $env:USERPROFILE — on this machine Documents/Downloads/Desktop/Pictures are all
# redirected to other drives, so a hardcoded join scans nothing and looks empty.
. (Join-Path $PSScriptRoot 'rootlib.ps1')
$roots = Get-ScanRoots

if (-not $roots.Contains($rootId)) {
    $out = [ordered]@{ ok = $false; error = "unknown root: $rootId"; roots = @($roots.Keys); rows = @() }
    [Console]::Out.Write((ConvertTo-Json -InputObject $out -Depth 4 -Compress))
    exit 0
}

$rootPath = [string]$roots[$rootId]
if (-not (Test-Path -LiteralPath $rootPath)) {
    $out = [ordered]@{ ok = $false; error = "root does not exist: $rootPath"; roots = @($roots.Keys); rows = @() }
    [Console]::Out.Write((ConvertTo-Json -InputObject $out -Depth 4 -Compress))
    exit 0
}

$minBytes = [int64]$minMb * 1MB
$started = Get-Date
$rows = [System.Collections.Generic.List[object]]::new()
$scanned = 0
$totalBytes = [int64]0
$truncated = $false

# One pass, keep only files at or above the threshold. The list is trimmed to
# the top N once at the end rather than sorted during the walk — sorting on
# every insert costs more than the walk itself on a large tree.
foreach ($f in (Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force -ErrorAction SilentlyContinue)) {
    $scanned++
    $len = $f.Length
    if ($null -eq $len) { continue }
    $totalBytes += [int64]$len
    if ([int64]$len -lt $minBytes) { continue }
    $rows.Add([ordered]@{
        path = $f.FullName
        name = $f.Name
        nameLower = $f.Name.ToLowerInvariant()
        bytes = [int64]$len
        modified = $f.LastWriteTimeUtc.ToString('o')
        ext = $f.Extension.ToLowerInvariant()
        folder = $f.DirectoryName
    })
    # Time budget: a full C:\ walk can take minutes on a cold cache. Returning
    # partial results with truncated=true is better than a 60 s timeout error.
    if (((Get-Date) - $started).TotalSeconds -gt $maxSeconds) { $truncated = $true; break }
}

# Sort on a SCRIPTBLOCK, not -Property bytes.
# Sort-Object -Property <key> silently leaves an OrderedDictionary list in its
# original order (the dictionary key is not a PS property, exactly like
# Measure-Object over the same rows) — the list came back shuffled instead of
# largest-first, and the panel showed a 288 MB file above a 575 MB one.
$sorted = @($rows | Sort-Object -Property { [int64]$_.bytes } -Descending | Select-Object -First $limit)

$out = [ordered]@{
    ok = $true
    root = $rootId
    rootPath = $rootPath
    minMb = $minMb
    scanned = $scanned
    scannedBytes = $totalBytes
    matched = $rows.Count
    shown = $sorted.Count
    truncated = $truncated
    elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    rows = @($sorted)
}
[Console]::Out.Write((ConvertTo-Json -InputObject $out -Depth 5 -Compress))
