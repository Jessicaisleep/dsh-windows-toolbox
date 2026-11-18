param([string]$ParamFile)

# ---------------------------------------------------------------------------
# junk.ps1 — scan (and optionally clean) known-safe junk locations.
#
# Flow only. The whitelist and the deletion primitives live in junklib.ps1 so
# the test suite can exercise them against a sandbox directory without touching
# real caches.
#
# Two hard rules, both learned on this machine (2026-11-17):
#
#  1. UTF-8 ON STDOUT. All Chinese labels came back as `�ܾ�...` through the Node
#     pipe until this line was added — PowerShell defaults to the OEM code page
#     while Node decodes UTF-8.
#
#  2. NEVER delete a cache directory itself, only its contents (see junklib).
#
# The JS layer sends target *ids*, never paths. A caller cannot name a directory.
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'junklib.ps1')

$params = @{}
if ($ParamFile -and (Test-Path -LiteralPath $ParamFile)) {
    $raw = Get-Content -LiteralPath $ParamFile -Raw -Encoding UTF8
    if ($raw) { $params = $raw | ConvertFrom-Json }
}
$action = if ($params.action) { [string]$params.action } else { 'scan' }
$dryRun = $true
if ($null -ne $params.dryRun) { $dryRun = [bool]$params.dryRun }
$wanted = @()
if ($params.targets) { $wanted = @($params.targets | ForEach-Object { [string]$_ }) }

$isElevated = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isElevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

$all = Get-JunkTargets
$selected = @($all | Where-Object { $wanted.Count -eq 0 -or $wanted -contains $_.id })

$results = [System.Collections.Generic.List[object]]::new()
foreach ($t in $selected) {
    $scan = Measure-JunkTarget -Target $t
    $blocked = ([bool]$t.needsAdmin -and -not $isElevated)
    $results.Add([ordered]@{
        id = $t.id; group = $t.group; label = $t.label; labelEn = $t.labelEn; path = $t.path
        needsAdmin = [bool]$t.needsAdmin; blocked = $blocked; kind = $t.kind; note = $t.note
        exists = $scan.exists; files = $scan.files; bytes = $scan.bytes
    })
}

# Sum by hand: Measure-Object -Property over an OrderedDictionary list returns
# nothing (the dictionary keys are not PS properties to the cmdlet), which
# silently produced an empty totalFiles.
$totalBytes = 0
$totalFiles = 0
foreach ($r in $results) { $totalBytes += [int64]$r.bytes; $totalFiles += [int64]$r.files }

$freed = 0; $deleted = 0; $skipped = 0
$messages = [System.Collections.Generic.List[string]]::new()

if ($action -eq 'clean' -and -not $dryRun) {
    foreach ($r in $results) {
        if ($r.blocked) { $messages.Add("跳过 $($r.label)：需要管理员权限"); continue }
        if (-not $r.exists) { continue }
        # Rebuild the target record from the fixed list — never from the result
        # row, so a mutated payload can never widen what gets deleted.
        $t = $all | Where-Object { $_.id -eq $r.id } | Select-Object -First 1
        if ($null -eq $t) { continue }
        $one = Remove-JunkTarget -Target $t
        $freed += [int64]$one.freed
        $deleted += [int]$one.deleted
        $skipped += [int]$one.skipped
        foreach ($m in @($one.messages)) { $messages.Add($m) }
    }
}

$out = [ordered]@{
    action = $action
    dryRun = $dryRun
    elevated = $isElevated
    targets = @($results)
    totalBytes = $totalBytes
    totalFiles = $totalFiles
    freed = $freed
    deleted = $deleted
    skipped = $skipped
    messages = @($messages)
}
[Console]::Out.Write((ConvertTo-Json -InputObject $out -Depth 6 -Compress))
