# ---------------------------------------------------------------------------
# featurelib.ps1 — shared helpers for the "feature" probes (privacy, security,
# homepage, apps, speedtest, tweaks, slim, rescue).
#
# Every feature probe emits the SAME item shape so the panel can render all of
# them with one table component:
#
#   { id, group, label, status, value, detail, fix, needsAdmin }
#
#   status ∈ ok | warn | bad | info | skip
#     ok   — nothing to do, measured value is on the good side of the threshold
#     warn — worth a look, not broken
#     bad  — actually broken or exposed
#     info — a fact with no good/bad direction (a version, a path, a count)
#     skip — could not be measured; `detail` says why (missing tool, needs admin)
#
# Rules this file encodes, learned the hard way elsewhere in this plugin:
#   * UTF-8 on stdout, or Node reads mojibake.
#   * Return List[object] with a leading comma, or PowerShell enumerates it.
#   * Never Test-Path a registry key that might not exist (≈387 ms/call). Read
#     with -LiteralPath and treat a throw as "absent". Filesystem Test-Path is
#     cheap (≈1.6 ms), so it is fine there.
#   * Never `Sort-Object -Property <key>` on OrderedDictionary rows — it is a
#     silent no-op. Use a scriptblock property.
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

function Read-ProbeParams {
    param([string]$ParamFile)
    $params = @{}
    if ($ParamFile -and (Test-Path -LiteralPath $ParamFile)) {
        $raw = Get-Content -LiteralPath $ParamFile -Raw -Encoding UTF8
        if ($raw) {
            try { $params = $raw | ConvertFrom-Json } catch { $params = @{} }
        }
    }
    return $params
}

function New-ProbeList {
    # Leading comma, or PowerShell enumerates the list into the pipeline: an
    # EMPTY list becomes $null and every Add() after that throws "cannot call a
    # method on a null-valued expression". Same trap as appx.ps1's rows.
    return , [System.Collections.Generic.List[object]]::new()
}

function Add-Item {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Id,
        [string]$Group,
        [string]$Label,
        [string]$Status,
        [string]$Value = '',
        [string]$Detail = '',
        [string]$Fix = '',
        [bool]$NeedsAdmin = $false,
        # Optional per-row extras (e.g. the Chinese explanation fields that
        # tweaks.ps1 adds). Merged into the row so the panel can prefer a
        # curated label over the raw upstream one. Keep it a hashtable so
        # callers that pass nothing are unaffected.
        [hashtable]$Extra = @{}
    )
    $row = [ordered]@{
        id         = $Id
        group      = $Group
        label      = $Label
        status     = $Status
        value      = $Value
        detail     = $Detail
        fix        = $Fix
        needsAdmin = $NeedsAdmin
    }
    if ($null -ne $Extra) {
        foreach ($k in $Extra.Keys) {
            if ([string]::IsNullOrWhiteSpace([string]$k)) { continue }
            if ($row.Contains([string]$k)) { continue }
            $row[[string]$k] = $Extra[$k]
        }
    }
    $List.Add($row)
}

function Test-Elevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Read a registry value without ever Test-Path-ing the key. Returns $null when
# the key or value is absent — callers render that as "unset", which is a real
# and different state from "0".
function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $k = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $k.$Name
    } catch { return $null }
}

# Present an absent value distinctly from a falsy one.
function Format-RegValue {
    param($Value)
    if ($null -eq $Value) { return 'unset' }
    if ($Value -is [array]) { return ($Value -join ',') }
    return [string]$Value
}

# Emit the standard envelope. `scope`/`note` are free-form and go into meta.
function Write-ProbeResult {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [hashtable]$Extra = @{},
        [string]$Note = ''
    )
    $counts = @{ ok = 0; warn = 0; bad = 0; info = 0; skip = 0 }
    foreach ($i in $Items) {
        $k = [string]$i.status
        if ($counts.ContainsKey($k)) { $counts[$k]++ }
    }
    $payload = [ordered]@{
        ok    = $true
        count = $Items.Count
        items = @($Items.ToArray())
        summary = [ordered]@{
            total = $Items.Count
            ok    = $counts.ok
            warn  = $counts.warn
            bad   = $counts.bad
            info  = $counts.info
            skip  = $counts.skip
        }
        elevated = (Test-Elevated)
    }
    foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] }
    if ($Note) { $payload.note = $Note }
    [Console]::Out.Write(($payload | ConvertTo-Json -Depth 6 -Compress))
}

function Get-OptionalString {
    # Safely read a possibly-missing string property off a PSCustomObject.
    # Read-ProbeParams / ConvertFrom-Json hand back objects where a missing
    # field is simply absent; indexing it yields $null and a cast to [string]
    # would silently produce ''. Keeping this in one place stops callers from
    # inventing empty values in different ways.
    param($Object, [string]$Name, [string]$Fallback = '')
    if ($null -eq $Object) { return $Fallback }
    $props = $Object.PSObject.Properties[$Name]
    if ($null -eq $props) { return $Fallback }
    $v = $props.Value
    if ($null -eq $v) { return $Fallback }
    return [string]$v
}
