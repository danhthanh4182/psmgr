#Requires -Version 5.1
<#
.SYNOPSIS
    Dev-only off-screen renderer for the PSManager WPF window.
.DESCRIPTION
    Loads the GUI window (either the extracted ui\ XAML files or the legacy inline
    here-string in gui.ps1), fills it with synthetic demo data, and renders it to a
    PNG with RenderTargetBitmap. No action handler is invoked and no system state is
    read or written, so it is safe to run on any machine.
.PARAMETER Source
    files  - load ui\PSManager.MainWindow.xaml + ui\PSManager.Theme.xaml via ui\GuiLoader.ps1
    inline - load the XAML here-string embedded in gui.ps1 (used for before-shots)
.PARAMETER OutFile
    Destination PNG path. Parent directory is created when missing.
.PARAMETER Width
    Render width in device-independent pixels.
.PARAMETER Height
    Render height in device-independent pixels.
.PARAMETER Lang
    Language used for the demo labels.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools/Capture-PSManagerGui.ps1 -Source inline -OutFile docs/ui-ux/shots/before/1280x800.png
#>
[CmdletBinding()]
param(
    [ValidateSet('inline', 'files')]
    [string]$Source = 'files',
    [string]$OutFile,
    [int]$Width = 1280,
    [int]$Height = 800,
    [ValidateSet('en', 'vi')]
    [string]$Lang = 'en'
)

$ErrorActionPreference = 'Stop'

# WPF rendering requires a single-threaded apartment. Relaunch under -STA when the
# current host is MTA so the caller never has to remember the flag.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $PSCommandPath + '"'))
    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        if ($entry.Value -is [switch]) {
            if ($entry.Value.IsPresent) { $relaunchArgs += ('-' + $entry.Key) }
            continue
        }
        $relaunchArgs += ('-' + $entry.Key)
        $relaunchArgs += ('"' + [string]$entry.Value + '"')
    }
    $child = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs -Wait -PassThru
    exit $child.ExitCode
}

if (-not $OutFile) {
    Write-Host "Capture-PSManagerGui: -OutFile is required." -ForegroundColor Red
    exit 1
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    try { New-Item -ItemType Directory -Path $outDir -Force | Out-Null } catch {
        Write-Host ("Capture-PSManagerGui: cannot create output directory '" + $outDir + "': " + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Import-Module (Join-Path $repoRoot 'PSManager.psd1') -Force

    $script:Window = $null

    if ($Source -eq 'files') {
        $loaderPath = Join-Path $repoRoot 'ui\GuiLoader.ps1'
        $xamlPath = Join-Path $repoRoot 'ui\PSManager.MainWindow.xaml'
        $themePath = Join-Path $repoRoot 'ui\PSManager.Theme.xaml'
        foreach ($required in @($loaderPath, $xamlPath, $themePath)) {
            if (-not (Test-Path -LiteralPath $required)) {
                Write-Host ("Capture-PSManagerGui: missing XAML resource: " + $required) -ForegroundColor Red
                exit 1
            }
        }
        . $loaderPath
        $script:Window = New-PSManagerGuiWindow -XamlPath $xamlPath -ThemePath $themePath
    } else {
        $guiPath = Join-Path $repoRoot 'gui.ps1'
        if (-not (Test-Path -LiteralPath $guiPath)) {
            Write-Host ("Capture-PSManagerGui: missing gui.ps1 at " + $guiPath) -ForegroundColor Red
            exit 1
        }
        $guiLines = @(Get-Content -LiteralPath $guiPath -Encoding UTF8)
        $start = -1
        $end = -1
        for ($i = 0; $i -lt $guiLines.Count; $i++) {
            $line = $guiLines[$i]
            if ($start -lt 0 -and $line.Trim() -eq '$xaml = @"') {
                $start = $i + 1
                continue
            }
            if ($start -ge 0 -and $line -eq '"@') {
                $end = $i - 1
                break
            }
        }
        if ($start -lt 0 -or $end -lt $start) {
            Write-Host "Capture-PSManagerGui: could not locate the XAML here-string in gui.ps1." -ForegroundColor Red
            exit 1
        }
        $xaml = ($guiLines[$start..$end] -join "`r`n")
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        $script:Window = [System.Windows.Markup.XamlReader]::Load($reader)
    }

    $window = $script:Window
    if ($null -eq $window) {
        Write-Host "Capture-PSManagerGui: the XAML produced no window." -ForegroundColor Red
        exit 1
    }

    function Set-DemoText {
        param([string]$Name, [string]$Value)
        if ([string]::IsNullOrEmpty($Name)) { return }
        $element = $script:Window.FindName($Name)
        if ($null -eq $element) { return }
        if ($null -eq $Value) { return }
        try { $element.Text = $Value } catch { }
    }

    function Get-DemoText {
        param([string]$Key)
        try { return (Get-I18nText -Key $Key -Language $Lang) } catch { return $null }
    }

    function Set-DemoLog {
        param([object[]]$Entries)
        $rtb = $script:Window.FindName('RtbConsoleLog')
        if ($null -ne $rtb) {
            $document = $rtb.Document
            $document.Blocks.Clear()
            foreach ($entry in $Entries) {
                $brushKey = switch ($entry.Level) {
                    'Success' { 'OkBrush' }
                    'Warn' { 'WarnBrush' }
                    'Error' { 'DangerBrush' }
                    'Accent' { 'AccentBrush' }
                    default { 'TextBrush' }
                }
                $brush = $null
                try { $brush = $script:Window.FindResource($brushKey) } catch { }
                $paragraph = [System.Windows.Documents.Paragraph]::new()
                $paragraph.Margin = [System.Windows.Thickness]::new(0)
                $stamp = [System.Windows.Documents.Run]::new("[$($entry.Time)] ")
                try { $stamp.Foreground = $script:Window.FindResource('TextDimBrush') } catch { }
                $body = [System.Windows.Documents.Run]::new([string]$entry.Text)
                if ($null -ne $brush) { $body.Foreground = $brush }
                [void]$paragraph.Inlines.Add($stamp)
                [void]$paragraph.Inlines.Add($body)
                [void]$document.Blocks.Add($paragraph)
            }
            return
        }
        $txt = $script:Window.FindName('TxtConsoleLog')
        if ($null -ne $txt) {
            $lines = @()
            foreach ($entry in $Entries) { $lines += ("[" + $entry.Time + "] " + $entry.Text) }
            $txt.Text = ($lines -join "`r`n")
        }
    }

    # ---- Synthetic demo data (no handler, no system query) ----
    Set-DemoText 'TxtVersion' 'v1.4.0'
    Set-DemoText 'TxtSubtitle' (Get-DemoText 'app_subtitle')
    Set-DemoText 'TxtLangToggle' $(if ($Lang -eq 'vi') { 'Tiếng Việt' } else { 'English' })
    Set-DemoText 'TxtStatusHint' ' — Ready'

    Set-DemoText 'CardWTDefault' 'PowerShell 7'
    Set-DemoText 'CardWTSub' (Get-DemoText 'gui_card_wtps7')
    Set-DemoText 'CardHost' 'Windows Terminal'
    Set-DemoText 'CardHostSub' (Get-DemoText 'gui_card_host_wt')
    Set-DemoText 'CardShim' 'Active'
    Set-DemoText 'CardShimSub' 'powershell -> pwsh'
    Set-DemoText 'CardSource' 'winget:stable'
    Set-DemoText 'CardSourceSub' 'Microsoft.PowerShell'

    $labelKeys = @{
        LblCardDefault = 'gui_card_default'
        LblCardHost    = 'gui_card_host'
        LblCardShim    = 'gui_card_shim'
        LblCardSource  = 'gui_card_source'
        LblSecDefault  = 'gui_sec_default'
        LblSecMaint    = 'gui_sec_maint'
        LblSecSource   = 'gui_sec_source'
        LblSecPkg      = 'gui_sec_pkg'
        LblSecTools    = 'gui_sec_tools'
        LblQuickLaunch = 'gui_launch_title'
        LblLog         = 'gui_log_title'
        LblSource      = 'gui_lbl_source'
        LblChannel     = 'gui_lbl_channel'
        TxtBtnSetDefaultPS7   = 'gui_btn_def7'
        TxtBtnRestorePS5      = 'gui_btn_def5'
        TxtBtnUpdate          = 'gui_btn_update'
        TxtBtnInstall         = 'gui_btn_install'
        TxtBtnDiagnostics     = 'gui_btn_diag'
        TxtBtnLaunchTUI       = 'gui_btn_tui'
        TxtBtnSyncNow         = 'gui_btn_sync'
        TxtBtnDoctorAudit     = 'gui_btn_doctor'
        TxtBtnDoctorFix       = 'gui_btn_doctor_fix'
        TxtBtnAdoptProfiles   = 'gui_btn_adopt'
        TxtBtnSyncSources     = 'gui_btn_syncsources'
        TxtBtnViewLogs        = 'gui_btn_viewlogs'
        TxtBtnBackupProfiles  = 'gui_btn_backup'
        TxtBtnRestoreBackup   = 'gui_btn_restore'
        TxtBtnBackupCloud     = 'gui_btn_cloud_backup'
        TxtBtnDeleteBackups   = 'gui_btn_clean_backups'
        TxtBtnLaunchPS7       = 'gui_btn_ps7'
        TxtBtnLaunchPS7Admin  = 'gui_btn_ps7a'
        TxtBtnLaunchSplit     = 'gui_btn_split'
        TxtBtnLaunchPS5       = 'gui_btn_ps5'
        TxtBtnEditProfile     = 'menu_prof'
        TxtBtnAuditProfiles   = 'gui_btn_audit_prof'
        TxtNavOverview        = 'gui_nav_overview'
        TxtNavUpdate          = 'gui_nav_update'
        TxtNavBackup          = 'gui_nav_backup'
        TxtNavHealth          = 'gui_nav_health'
        TxtNavProfile         = 'gui_nav_profile'
        TxtLogFilterHint      = 'gui_log_filter_placeholder'
    }
    foreach ($key in $labelKeys.Keys) {
        $value = Get-DemoText $labelKeys[$key]
        if ($null -ne $value) { Set-DemoText $key $value }
    }

    # Show the active segments the way the live dashboard does.
    foreach ($pair in @(@('BtnSrcWinget', $true), @('BtnSrcMsstore', $false), @('BtnSrcGithub', $false),
                        @('BtnChStable', $true), @('BtnChPreview', $false), @('BtnChLts', $false))) {
        $seg = $window.FindName($pair[0])
        if ($null -eq $seg) { continue }
        # The legacy inline XAML used Buttons here; only the new RadioButtons expose IsChecked.
        try { $seg.IsChecked = [bool]$pair[1] } catch { }
    }

    Set-DemoLog -Entries @(
        [pscustomobject]@{ Time = '09:41:07'; Level = 'Info';    Text = 'PSManager Desktop ready.' }
        [pscustomobject]@{ Time = '09:41:12'; Level = 'Accent';  Text = 'Dashboard refreshed.' }
        [pscustomobject]@{ Time = '09:41:19'; Level = 'Success'; Text = '[OK] Sync complete: 12 links verified.' }
        [pscustomobject]@{ Time = '09:41:26'; Level = 'Warn';    Text = '[!] Winget source catalog is 3 days old.' }
        [pscustomobject]@{ Time = '09:41:31'; Level = 'Error';   Text = 'ERROR: Diagnostics could not read one registry key.' }
    )

    # ---- Off-screen render ----
    $root = $window.Content
    $root.Measure([System.Windows.Size]::new([double]$Width, [double]$Height))
    $root.Arrange([System.Windows.Rect]::new(0, 0, [double]$Width, [double]$Height))
    $root.UpdateLayout()

    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)

    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Create($OutFile)
    try {
        $encoder.Save($stream)
    } finally {
        $stream.Dispose()
    }

    $info = Get-Item -LiteralPath $OutFile
    Write-Host ("Rendered {0} ({1} bytes) from {2}." -f $OutFile, $info.Length, $Source) -ForegroundColor Green
    exit 0
} catch {
    Write-Host ("Capture-PSManagerGui: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
