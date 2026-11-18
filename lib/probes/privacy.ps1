param([string]$ParamFile)

# ---------------------------------------------------------------------------
# privacy.ps1 — 隐私保镖 / 权限管理.
#
# Two halves, both real reads of the machine's own policy stores:
#   1. ConsentStore — the per-capability, per-app camera/mic/location grants that
#      Settings > Privacy writes. 29 capabilities exist on a stock Win10; any app
#      that has an explicit entry can be flipped here.
#   2. Privacy switches that actually leak — telemetry level, advertising id,
#      DiagTrack, activity history.
#
# All writes here land in HKCU, so they work without elevation. That is
# deliberate: a privacy toggle that needs admin is a toggle most users cannot use.
# ---------------------------------------------------------------------------
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'featurelib.ps1')

$params = Read-ProbeParams -ParamFile $ParamFile
$items = New-ProbeList

# ---- 1. per-capability consent --------------------------------------------
$consentRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$caps = Get-ChildItem -LiteralPath $consentRoot -ErrorAction SilentlyContinue
$consented = 0
$denied = 0
$appEntries = 0
if ($caps) {
    foreach ($cap in $caps) {
        $name = $cap.PSChildName
        $global = Get-RegValue -Path $cap.PSPath -Name 'Value'
        $globalText = Format-RegValue $global
        # Apps live one level down, keyed by a package identity or a path-ish id.
        $apps = Get-ChildItem -LiteralPath $cap.PSPath -ErrorAction SilentlyContinue
        foreach ($app in $apps) {
            $v = Get-RegValue -Path $app.PSPath -Name 'Value'
            $appEntries++
            if ((Format-RegValue $v) -eq 'Allow') { $consented++ } else { $denied++ }
        }
        $status = 'info'
        if ($globalText -eq 'Allow') { $status = 'warn' }
        elseif ($globalText -eq 'Deny') { $status = 'ok' }
        Add-Item -List $items -Id "consent:$name" -Group 'consent' -Label $name -Status $status `
            -Value "全局 $globalText · 应用 $($apps.Count)" `
            -Detail "写入 HKCU\...\CapabilityAccessManager\ConsentStore\$name" `
            -Fix $(if ($globalText -eq 'Allow') { "把 $name 权限改为 Deny" } else { '' })
    }
}
Add-Item -List $items -Id 'consent:summary' -Group 'consent' -Label '权限条目' -Status 'info' `
    -Value "$($caps.Count) 项权限 · $appEntries 个应用级条目" `
    -Detail "已允许 $consented · 已拒绝 $denied" `
    -Fix ''

# ---- 2. advertising id -----------------------------------------------------
$adKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
$adRaw = Get-RegValue -Path $adKey -Name 'Enabled'
$ad = Format-RegValue $adRaw
$adStatus = 'ok'
if ($ad -eq '1') { $adStatus = 'bad' }
Add-Item -List $items -Id 'privacy:adid' -Group 'privacy' -Label '广告 ID' -Status $adStatus `
    -Value $ad -Detail '应用可用它跨应用追踪你' `
    -Fix $(if ($ad -eq '1') { '关闭广告 ID' } else { '' })

# ---- 3. telemetry ----------------------------------------------------------
$telKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
$tel = Format-RegValue (Get-RegValue -Path $telKey -Name 'AllowTelemetry')
$diag = Get-Service -Name DiagTrack -ErrorAction SilentlyContinue
$diagText = if ($diag) { "$($diag.Status)/$($diag.StartType)" } else { 'absent' }
$telStatus = 'ok'
if ($diag -and $diag.Status -eq 'Running') { $telStatus = 'warn' } elseif ($tel -eq 'unset') { $telStatus = 'warn' }
Add-Item -List $items -Id 'privacy:telemetry' -Group 'privacy' -Label '遥测' -Status $telStatus `
    -Value "AllowTelemetry=$tel · DiagTrack=$diagText" `
    -Detail 'AllowTelemetry 未设置表示使用系统默认级别' `
    -Fix $(if ($telStatus -ne 'ok') { '把 AllowTelemetry 设为 0 并停用 DiagTrack（需管理员）' } else { '' }) `
    -NeedsAdmin ($diagText -ne 'absent')

# ---- 4. activity history ---------------------------------------------------
$actKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'
$publish = Format-RegValue (Get-RegValue -Path $actKey -Name 'PublishUserActivities')
$upload = Format-RegValue (Get-RegValue -Path $actKey -Name 'UploadUserActivities')
$actStatus = 'ok'
if ($publish -ne '0' -or $upload -ne '0') { $actStatus = 'warn' }
Add-Item -List $items -Id 'privacy:activity' -Group 'privacy' -Label '活动历史' -Status $actStatus `
    -Value "Publish=$publish · Upload=$upload" `
    -Detail '未设为 0 时系统会记录并上传你打开过的内容' `
    -Fix $(if ($actStatus -ne 'ok') { '停止记录并上传活动历史' } else { '' })

# ---- 5. location ----------------------------------------------------------
$locKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
$loc = Format-RegValue (Get-RegValue -Path $locKey -Name 'Value')
Add-Item -List $items -Id 'privacy:location' -Group 'privacy' -Label '定位总开关' -Status $(if ($loc -eq 'Allow') { 'warn' } else { 'ok' }) `
    -Value $loc -Detail '系统级定位权限' `
    -Fix $(if ($loc -eq 'Allow') { '关闭定位（需管理员）' } else { '' }) -NeedsAdmin $true

Write-ProbeResult -Items $items -Extra @{
    capabilities = $caps.Count
    appEntries   = $appEntries
} -Note '隐私开关写 HKCU 即可生效，无需管理员；遥测与定位总开关写 HKLM，需要管理员。'
