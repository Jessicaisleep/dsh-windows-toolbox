# ---------------------------------------------------------------------------
# rootlib.ps1 — resolve "scan root" ids to real folder paths.
#
# Dot-source this from a probe: . (Join-Path $PSScriptRoot 'rootlib.ps1')
#
# Why this exists: joining $env:USERPROFILE with 'Documents' / 'Downloads' /
# 'Desktop' / 'Pictures' is WRONG on any machine where the user moved a known
# folder (this one has Documents -> E:\Documents, Downloads -> E:\Downloads,
# Desktop -> D:\Desktop, Pictures -> D:\Pictures). Hardcoded joins silently
# resolve to a stale or non-existent directory and the scan then reports zero
# files as if the folder were simply empty — a false "nothing here", which is
# worse than an error.
#
# [Environment]::GetFolderPath reads the same shell folder registry that
# Explorer uses, so it follows redirection without needing to parse the
# User Shell Folders keys by hand (those contain unexpanded %VARS%).
# ---------------------------------------------------------------------------

function Get-ScanRoots {
    # Known folders first, each only accepted when it actually exists.
    $candidates = [ordered]@{}
    $map = @(
        @{ id = 'desktop';   special = 'Desktop' },
        @{ id = 'documents'; special = 'MyDocuments' },
        @{ id = 'downloads'; special = $null },   # no SpecialFolder enum; see below
        @{ id = 'pictures';  special = 'MyPictures' }
    )
    foreach ($m in $map) {
        if ($m.special) {
            $p = ''
            try { $p = [Environment]::GetFolderPath([Environment+SpecialFolder]::$($m.special)) } catch { $p = '' }
            if ($p) { $candidates[$m.id] = $p }
        }
    }

    # Downloads has no SpecialFolder member. Its canonical id lives in
    # User Shell Folders as {374DE290-123F-4565-9164-39C4925E467B}; the value is
    # usually stored as a REG_EXPAND_SZ with %USERPROFILE%, so expand it.
    $ush = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    if (-not $candidates.Contains('downloads')) {
        $raw = $null
        try { $raw = (Get-ItemProperty -LiteralPath $ush -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}' } catch { $raw = $null }
        if ($raw) {
            $expanded = [Environment]::ExpandEnvironmentVariables([string]$raw)
            if ($expanded) { $candidates['downloads'] = $expanded }
        }
    }
    # Fall back to the profile join only when nothing better is known.
    if (-not $candidates.Contains('downloads')) { $candidates['downloads'] = (Join-Path $env:USERPROFILE 'Downloads') }

    $candidates['user'] = $env:USERPROFILE

    # Every fixed drive is addressable as "<letter>:".
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Root -match '^([A-Za-z]):\\$') {
            $key = $Matches[1].ToLower() + ':'
            if (-not $candidates.Contains($key)) { $candidates[$key] = $d.Root }
        }
    }

    # Drop anything that does not exist so callers never report a phantom root
    # as an empty scan. Keep 'user' even if odd, it always exists in practice.
    $live = [ordered]@{}
    foreach ($k in $candidates.Keys) {
        $v = [string]$candidates[$k]
        if ($v -and (Test-Path -LiteralPath $v)) { $live[$k] = $v }
    }
    return $live
}
