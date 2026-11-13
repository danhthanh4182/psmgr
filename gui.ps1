#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager - Modern WPF Desktop Application
.DESCRIPTION
    Desktop GUI for managing PowerShell versions, defaults, updates, sources, and quick launch.
    Engineered with resolution-independent SVG vector icons (StreamGeometry).
#>

param(
    [string]$Lang = $null
)
$Script:GuiBusy = $false

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# A WPF window hosted by pwsh.exe inherits the PowerShell taskbar identity: the
# process-level AppUserModelID is ignored for this host, so the window also gets its
# own AUMID through SHGetPropertyStoreForWindow/PKEY_AppUserModel_ID. That makes the
# taskbar button use the PSManager shortcut (name and icon) instead of pwsh.exe.
$Script:PSMGR_GUI_AUMID = 'PSManager.Desktop'
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace PSManager.Native
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct AumidPropertyKey
    {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct AumidPropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAumidPropertyStore
    {
        int GetCount(out uint propertyCount);
        int GetAt(uint propertyIndex, out AumidPropertyKey key);
        int GetValue(ref AumidPropertyKey key, out AumidPropVariant value);
        int SetValue(ref AumidPropertyKey key, ref AumidPropVariant value);
        int Commit();
    }

    public static class WindowAumid
    {
        [DllImport("shell32.dll")]
        private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, out IAumidPropertyStore propertyStore);

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref AumidPropVariant propVariant);

        public static int Set(IntPtr hwnd, string appId)
        {
            Guid iid = typeof(IAumidPropertyStore).GUID;
            IAumidPropertyStore store;
            int hr = SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
            if (hr != 0 || store == null) { return hr; }

            AumidPropertyKey key = new AumidPropertyKey();
            key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
            key.pid = 5; // PKEY_AppUserModel_ID

            AumidPropVariant value = new AumidPropVariant();
            value.vt = 31; // VT_LPWSTR
            value.pointerValue = Marshal.StringToCoTaskMemUni(appId);

            try
            {
                hr = store.SetValue(ref key, ref value);
                if (hr != 0) { return hr; }
                // A relaunch command lets the taskbar pin and launch this window's app.
                return store.Commit();
            }
            finally
            {
                PropVariantClear(ref value);
                Marshal.ReleaseComObject(store);
            }
        }
    }
}
'@ -ErrorAction Stop
} catch {
    Write-PSManagerLog -Message ("Window AUMID helper unavailable: {0}" -f $_.Exception.Message) -Level WARN
}



$scriptRoot = Split-Path -Parent $PSCommandPath
if (-not $scriptRoot) {
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}

# Import PSManager Module
Import-Module "$scriptRoot\PSManager.psd1" -Force

function Get-GuiLanguage {
    # Mirror the explicit stored mode (en / vi-ascii / vi) on every engine.
    # WPF can render Unicode, but it must not rewrite the user's choice.
    $candidates = @()
    if ($Lang) { $candidates += [string]$Lang }
    $candidates += [string]((Get-PSManagerConfig).language)

    foreach ($candidate in $candidates) {
        switch ($candidate.Trim().ToLowerInvariant()) {
            'en' { return 'en' }
            'vi-ascii' { return 'vi-ascii' }
            'vi' { return 'vi' }
        }
    }

    return (Get-EffectiveLanguage)
}

function Get-GuiLanguageLabel {
    param([string]$Language)
    $mode = ([string]$Language).Trim().ToLowerInvariant()
    return (Get-I18nText -Key ('gui_lang_' + $mode.Replace('-', '_')) -Language $mode)
}

function Get-NextGuiLanguage {
    param([string]$Current)
    switch (([string]$Current).Trim().ToLowerInvariant()) {
        'en' { return 'vi-ascii' }
        'vi-ascii' { return 'vi' }
        'vi' { return 'en' }
    }
    return 'en'
}

function Get-Text {
    param([string]$Key)
    return (Get-I18nText $Key (Get-GuiLanguage))
}

# The window markup lives in ui\PSManager.MainWindow.xaml with tokens from
# ui\PSManager.Theme.xaml; GuiLoader merges the theme into the window resources.
try {
    . (Join-Path $scriptRoot 'ui\GuiLoader.ps1')
    . (Join-Path $scriptRoot 'ui\GuiKeyboard.ps1')
    . (Join-Path $scriptRoot 'ui\GuiNavigation.ps1')
    . (Join-Path $scriptRoot 'ui\GuiNotifications.ps1')
    . (Join-Path $scriptRoot 'ui\GuiHelp.ps1')
    $window = New-PSManagerGuiWindow -XamlPath (Join-Path $scriptRoot 'ui\PSManager.MainWindow.xaml') -ThemePath (Join-Path $scriptRoot 'ui\PSManager.Theme.xaml')
# Set window title bar and taskbar icon. The .ico carries 16..256 px frames; the shell
# draws the taskbar button from a 32 px image, so pick the smallest frame >= 32 px
# instead of BitmapFrame::Create (which always returns the 16 px frame).
$iconPath = Join-Path $scriptRoot 'assets\psmgr.ico'
if (Test-Path -LiteralPath $iconPath) {
    try {
        $iconUri = [System.Uri]::new($iconPath, [System.UriKind]::Absolute)
        $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
            $iconUri,
            [System.Windows.Media.Imaging.BitmapCreateOptions]::None,
            [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $frames = @($decoder.Frames)
        $chosen = $frames | Where-Object { $_.PixelWidth -ge 32 } |
            Sort-Object PixelWidth | Select-Object -First 1
        if (-not $chosen) { $chosen = $frames | Sort-Object PixelWidth -Descending | Select-Object -First 1 }
        if ($chosen) { $window.Icon = $chosen }
    } catch {}
} else {
    $exeCandidate = Join-Path $scriptRoot 'psmgr-gui.exe'
    if (-not (Test-Path -LiteralPath $exeCandidate)) {
        $exeCandidate = Join-Path $scriptRoot 'psmgr.exe'
    }
    if (Test-Path -LiteralPath $exeCandidate) {
        try {
            Add-Type -AssemblyName System.Drawing
            $assocIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($exeCandidate)
            if ($assocIcon) {
                $window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                    $assocIcon.Handle,
                    [System.Windows.Int32Rect]::Empty,
                    [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            }
        } catch {}
    }
}

} catch {
    [System.Windows.MessageBox]::Show($_.Exception.Message, 'PSManager', 'OK', 'Error') | Out-Null
    exit 1
}

# The taskbar identity must be set on the HWND: the process-level AUMID is ignored while
# the window is hosted by pwsh.exe, so the button would otherwise show the PowerShell icon.
if ($Script:PSMGR_GUI_AUMID) {
    $window.Add_SourceInitialized({
        try {
            $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
            if ($hwnd -ne [IntPtr]::Zero) {
                $null = [PSManager.Native.WindowAumid]::Set($hwnd, $Script:PSMGR_GUI_AUMID)
            }
        } catch {}
    })
}

# Element References
$btnRefresh            = $window.FindName("BtnRefresh")
$btnLangToggle         = $window.FindName("BtnLangToggle")
$txtLangToggle         = $window.FindName("TxtLangToggle")
$txtVersion            = $window.FindName("TxtVersion")
$txtSubtitle           = $window.FindName("TxtSubtitle")
$lblSecDefault         = $window.FindName("LblSecDefault")
$lblSecMaint           = $window.FindName("LblSecMaint")
$lblSecSource          = $window.FindName("LblSecSource")
$lblSource             = $window.FindName("LblSource")
$lblChannel            = $window.FindName("LblChannel")
$lblCardDefault        = $window.FindName("LblCardDefault")
$lblCardHost           = $window.FindName("LblCardHost")
$lblCardShim           = $window.FindName("LblCardShim")
$lblCardSource         = $window.FindName("LblCardSource")
$lblQuickLaunch        = $window.FindName("LblQuickLaunch")
$lblLog                = $window.FindName("LblLog")
$cardWTDefault         = $window.FindName("CardWTDefault")
$cardWTSub             = $window.FindName("CardWTSub")
$cardHost              = $window.FindName("CardHost")
$cardHostSub           = $window.FindName("CardHostSub")
$cardShim              = $window.FindName("CardShim")
$cardShimSub           = $window.FindName("CardShimSub")
$cardSource            = $window.FindName("CardSource")
$cardSourceSub         = $window.FindName("CardSourceSub")

$btnSetDefaultPS7      = $window.FindName("BtnSetDefaultPS7")
$txtBtnSetDefaultPS7   = $window.FindName("TxtBtnSetDefaultPS7")
$btnRestorePS5         = $window.FindName("BtnRestorePS5")
$txtBtnRestorePS5      = $window.FindName("TxtBtnRestorePS5")
$btnUpdate             = $window.FindName("BtnUpdate")
$txtBtnUpdate          = $window.FindName("TxtBtnUpdate")
$btnInstall            = $window.FindName("BtnInstall")
$txtBtnInstall         = $window.FindName("TxtBtnInstall")
$btnEditProfile        = $window.FindName("BtnEditProfile")
$txtBtnEditProfile     = $window.FindName("TxtBtnEditProfile")
$btnAuditProfiles      = $window.FindName("BtnAuditProfiles")
$txtBtnAuditProfiles   = $window.FindName("TxtBtnAuditProfiles")
$btnDiagnostics        = $window.FindName("BtnDiagnostics")
$txtBtnDiagnostics     = $window.FindName("TxtBtnDiagnostics")
$btnLaunchTUI          = $window.FindName("BtnLaunchTUI")
$txtBtnLaunchTUI       = $window.FindName("TxtBtnLaunchTUI")

$btnSrcWinget          = $window.FindName("BtnSrcWinget")
$btnSrcMsstore         = $window.FindName("BtnSrcMsstore")
$btnSrcGithub          = $window.FindName("BtnSrcGithub")
$btnChStable           = $window.FindName("BtnChStable")
$btnChPreview          = $window.FindName("BtnChPreview")
$btnChLts              = $window.FindName("BtnChLts")

$btnLaunchPS7          = $window.FindName("BtnLaunchPS7")
$txtBtnLaunchPS7       = $window.FindName("TxtBtnLaunchPS7")
$btnLaunchPS7Admin     = $window.FindName("BtnLaunchPS7Admin")
$txtBtnLaunchPS7Admin  = $window.FindName("TxtBtnLaunchPS7Admin")
$btnLaunchSplit        = $window.FindName("BtnLaunchSplit")
$txtBtnLaunchSplit     = $window.FindName("TxtBtnLaunchSplit")
$btnLaunchPS5          = $window.FindName("BtnLaunchPS5")
$txtBtnLaunchPS5       = $window.FindName("TxtBtnLaunchPS5")
$btnEditProfile        = $window.FindName("BtnEditProfile")
$txtBtnEditProfile     = $window.FindName("TxtBtnEditProfile")

$lblSecTools           = $window.FindName("LblSecTools")
$btnSyncNow            = $window.FindName("BtnSyncNow")
$txtBtnSyncNow         = $window.FindName("TxtBtnSyncNow")
$btnDoctorAudit        = $window.FindName("BtnDoctorAudit")
$txtBtnDoctorAudit     = $window.FindName("TxtBtnDoctorAudit")
$btnDoctorFix          = $window.FindName("BtnDoctorFix")
$txtBtnDoctorFix       = $window.FindName("TxtBtnDoctorFix")
$btnAdoptProfiles      = $window.FindName("BtnAdoptProfiles")
$txtBtnAdoptProfiles   = $window.FindName("TxtBtnAdoptProfiles")

$lblSecPkg             = $window.FindName("LblSecPkg")
$btnSyncSources        = $window.FindName("BtnSyncSources")
$txtBtnSyncSources     = $window.FindName("TxtBtnSyncSources")
$btnViewLogs           = $window.FindName("BtnViewLogs")
$txtBtnViewLogs        = $window.FindName("TxtBtnViewLogs")
$btnBackupProfiles     = $window.FindName("BtnBackupProfiles")
$txtBtnBackupProfiles  = $window.FindName("TxtBtnBackupProfiles")
$btnRestoreBackup      = $window.FindName("BtnRestoreBackup")
$txtBtnRestoreBackup   = $window.FindName("TxtBtnRestoreBackup")
$btnBackupCloud        = $window.FindName("BtnBackupCloud")
$txtBtnBackupCloud     = $window.FindName("TxtBtnBackupCloud")
$btnSetCloudRepo       = $window.FindName("BtnSetCloudRepo")
$txtBtnSetCloudRepo    = $window.FindName("TxtBtnSetCloudRepo")
$txtCapSetCloudRepo    = $window.FindName("TxtCapSetCloudRepo")
$btnDeleteBackups      = $window.FindName("BtnDeleteBackups")
$txtBtnDeleteBackups   = $window.FindName("TxtBtnDeleteBackups")

$btnLogCopy            = $window.FindName("BtnLogCopy")
$btnLogClear           = $window.FindName("BtnLogClear")
$rtbConsoleLog         = $window.FindName("RtbConsoleLog")
$txtStatusHint         = $window.FindName("TxtStatusHint")
$prgBusy               = $window.FindName("PrgBusy")
$btnCancelAction       = $window.FindName("BtnCancelAction")
$txtLogFilter          = $window.FindName("TxtLogFilter")
$txtLogFilterHint      = $window.FindName("TxtLogFilterHint")

# Navigation shell
$navOverview           = $window.FindName("NavOverview")
$navUpdate             = $window.FindName("NavUpdate")
$navBackup             = $window.FindName("NavBackup")
$navHealth             = $window.FindName("NavHealth")
$navProfile            = $window.FindName("NavProfile")
$navHelp               = $window.FindName("NavHelp")
$txtNavOverview        = $window.FindName("TxtNavOverview")
$txtNavUpdate          = $window.FindName("TxtNavUpdate")
$txtNavBackup          = $window.FindName("TxtNavBackup")
$txtNavHealth          = $window.FindName("TxtNavHealth")
$txtNavProfile         = $window.FindName("TxtNavProfile")
$txtNavHelp            = $window.FindName("TxtNavHelp")
$pageOverview          = $window.FindName("PageOverview")
$pageUpdate            = $window.FindName("PageUpdate")
$pageBackup            = $window.FindName("PageBackup")
$pageHealth            = $window.FindName("PageHealth")
$pageProfile           = $window.FindName("PageProfile")
$pageHelp              = $window.FindName("PageHelp")

# Header and Help page actions
$btnHelp               = $window.FindName("BtnHelp")
$btnNotifications      = $window.FindName("BtnNotifications")
$txtNotifBadge         = $window.FindName("TxtNotifBadge")
$notifBadge            = $window.FindName("NotifBadge")
$btnCheckUpdate        = $window.FindName("BtnCheckUpdate")
$btnInstallUpdate      = $window.FindName("BtnInstallUpdate")
$btnOpenRelease        = $window.FindName("BtnOpenRelease")
$btnOpenDocs           = $window.FindName("BtnOpenDocs")
$btnOpenRepo           = $window.FindName("BtnOpenRepo")
$btnOpenIssues         = $window.FindName("BtnOpenIssues")
$btnOpenLicense        = $window.FindName("BtnOpenLicense")

# Caption under each page action (same wording as its tooltip)
$txtCapDefaultPS7      = $window.FindName("TxtCapDefaultPS7")
$txtCapRestorePS5      = $window.FindName("TxtCapRestorePS5")
$txtCapUpdate          = $window.FindName("TxtCapUpdate")
$txtCapInstall         = $window.FindName("TxtCapInstall")
$txtCapSyncNow         = $window.FindName("TxtCapSyncNow")
$txtCapSyncSources     = $window.FindName("TxtCapSyncSources")
$txtCapBackupProfiles  = $window.FindName("TxtCapBackupProfiles")
$txtCapRestoreBackup   = $window.FindName("TxtCapRestoreBackup")
$txtCapBackupCloud     = $window.FindName("TxtCapBackupCloud")
$txtCapDeleteBackups   = $window.FindName("TxtCapDeleteBackups")
$txtCapDiagnostics     = $window.FindName("TxtCapDiagnostics")
$txtCapDoctorAudit     = $window.FindName("TxtCapDoctorAudit")
$txtCapDoctorFix       = $window.FindName("TxtCapDoctorFix")
$txtCapEditProfile     = $window.FindName("TxtCapEditProfile")
$txtCapAuditProfiles   = $window.FindName("TxtCapAuditProfiles")
$txtCapAdoptProfiles   = $window.FindName("TxtCapAdoptProfiles")

# Shared brushes come from the merged theme dictionary (single source of truth)
$Script:BrushGreen = $window.FindResource('OkBrush')
$Script:BrushAmber = $window.FindResource('WarnBrush')
$Script:BrushGray  = $window.FindResource('TextDimBrush')

$guiPages = @{
    overview = $pageOverview
    update   = $pageUpdate
    backup   = $pageBackup
    health   = $pageHealth
    profile  = $pageProfile
    help     = $pageHelp
}

$guiNav = @{
    overview = $navOverview
    update   = $navUpdate
    backup   = $navBackup
    health   = $navHealth
    profile  = $navProfile
    help     = $navHelp
}

$sourceButtons = @($btnSrcWinget, $btnSrcMsstore, $btnSrcGithub)
$channelButtons = @($btnChStable, $btnChPreview, $btnChLts)
$busyButtons = @(
    $btnRefresh, $btnLangToggle, $btnHelp, $btnNotifications, $btnCheckUpdate, $btnSetDefaultPS7, $btnRestorePS5,
    $btnUpdate, $btnInstall, $btnDiagnostics, $btnLaunchTUI,
    $btnSrcWinget, $btnSrcMsstore, $btnSrcGithub,
    $btnChStable, $btnChPreview, $btnChLts,
    $btnLaunchPS7, $btnLaunchPS7Admin, $btnLaunchSplit, $btnLaunchPS5,
    $btnEditProfile, $btnAuditProfiles, $btnSyncNow, $btnDoctorAudit, $btnDoctorFix, $btnAdoptProfiles,
    $btnSyncSources, $btnViewLogs, $btnBackupProfiles, $btnRestoreBackup, $btnBackupCloud, $btnDeleteBackups,
    $btnLogCopy, $btnLogClear, $btnOpenRelease, $btnOpenDocs, $btnOpenRepo, $btnOpenIssues, $btnOpenLicense
)

$Script:LogEntries = [System.Collections.Generic.List[object]]::new()
$Script:MAX_LOG_ENTRIES = 500
$Script:BusyFocus = $null

function Get-LogLevel {
    # Console-style prefixes carry the severity, so handlers keep logging plain text.
    param([string]$Text)
    if ($Text -match '^(ERROR:|\[FAIL\])') { return 'Error' }
    if ($Text -match '^(\[!\]|WARN)') { return 'Warn' }
    if ($Text -match '^(\[OK\]|\[\+\])') { return 'Success' }
    if ($Text -match '^\[>\]') { return 'Accent' }
    return 'Info'
}

function Get-LogLevelBrush {
    param([string]$Level)
    $key = switch ($Level) {
        'Error' { 'DangerBrush' }
        'Warn' { 'WarnBrush' }
        'Success' { 'OkBrush' }
        'Accent' { 'AccentBrush' }
        default { 'TextBrush' }
    }
    return $window.FindResource($key)
}

function Add-LogEntryBlock {
    # One paragraph per entry: dim timestamp, level-coloured text, clickable URLs.
    param([object]$Entry, $Blocks)
    $paragraph = [System.Windows.Documents.Paragraph]::new()
    $paragraph.Margin = [System.Windows.Thickness]::new(0)

    $stamp = [System.Windows.Documents.Run]::new(("[" + $Entry.Time + "] "))
    $stamp.Foreground = $window.FindResource('TextDimBrush')
    $null = $paragraph.Inlines.Add($stamp)

    $brush = Get-LogLevelBrush -Level $Entry.Level
    $parts = [regex]::Split([string]$Entry.Text, '(https?://\S+|file:///\S+)')
    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part)) { continue }
        if ($part -match '^(https?://|file:///)') {
            $link = [System.Windows.Documents.Hyperlink]::new([System.Windows.Documents.Run]::new($part))
            # RequestNavigate only fires for a hyperlink that has a target.
            $link.NavigateUri = [System.Uri]::new($part)
            $link.Foreground = $window.FindResource('AccentBrush')
            $link.TextDecorations = [System.Windows.TextDecorations]::Underline
            $link.Add_RequestNavigate({
                param($navSource, $navEvent)
                try { Start-Process $navEvent.Uri.AbsoluteUri } catch {}
                $navEvent.Handled = $true
            })
            $null = $paragraph.Inlines.Add($link)
        } else {
            $run = [System.Windows.Documents.Run]::new($part)
            $run.Foreground = $brush
            $null = $paragraph.Inlines.Add($run)
        }
    }
    $null = $Blocks.Add($paragraph)
}

function Update-LogView {
    param([string]$Filter = "")
    if (-not $rtbConsoleLog) { return }
    $rtbConsoleLog.Document.Blocks.Clear()
    $needle = if ($Filter) { [regex]::Escape($Filter.Trim()) } else { "" }
    foreach ($entry in $Script:LogEntries) {
        if ($needle -and $entry.Text -notmatch $needle) { continue }
        Add-LogEntryBlock -Entry $entry -Blocks $rtbConsoleLog.Document.Blocks
    }
    $rtbConsoleLog.ScrollToEnd()
}

function Add-Log {
    param([string]$Text, [string]$Level)
    if (-not $Level) { $Level = Get-LogLevel -Text $Text }
    $Script:LogEntries.Add([pscustomobject]@{
        Time  = (Get-Date).ToString("HH:mm:ss")
        Level = $Level
        Text  = $Text
    })
    while ($Script:LogEntries.Count -gt $Script:MAX_LOG_ENTRIES) {
        $Script:LogEntries.RemoveAt(0)
    }
    $filter = if ($txtLogFilter) { $txtLogFilter.Text } else { "" }
    Update-LogView -Filter $filter
}

function Set-BusyState {
    param([bool]$Busy)
    if ($Busy) {
        $focused = [System.Windows.Input.Keyboard]::FocusedElement
        if ($focused -is [System.Windows.Controls.Control] -and $focused -isnot [System.Windows.Window]) {
            $Script:BusyFocus = $focused
        } else {
            $Script:BusyFocus = $null
        }
    }

    foreach ($b in $busyButtons) { $b.IsEnabled = -not $Busy }
    if ($Busy) {
        $txtStatusHint.Text = " — " + (Get-Text "gui_status_busy")
        $txtStatusHint.Foreground = $Script:BrushAmber
        if ($prgBusy) { $prgBusy.Visibility = 'Visible' }
        if ($btnCancelAction) { $btnCancelAction.Visibility = 'Visible' }
        [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
    } else {
        $txtStatusHint.Text = " — " + (Get-Text "gui_status_ready")
        $txtStatusHint.Foreground = $Script:BrushGreen
        if ($prgBusy) { $prgBusy.Visibility = 'Collapsed' }
        if ($btnCancelAction) { $btnCancelAction.Visibility = 'Collapsed' }
        [System.Windows.Input.Mouse]::OverrideCursor = $null

        if ($Script:BusyFocus) {
            $curr = [System.Windows.Input.Keyboard]::FocusedElement
            if (($null -eq $curr -or $curr -is [System.Windows.Window]) -and $Script:BusyFocus.IsVisible -and $Script:BusyFocus.IsEnabled) {
                $Script:BusyFocus.Focus() | Out-Null
            }
            $Script:BusyFocus = $null
        }
    }
}

function Set-SegmentedSelection {
    param([object[]]$Buttons, [string]$Selected)
    foreach ($b in $Buttons) { $b.IsChecked = ($b.Tag -eq $Selected) }
}

function Invoke-GuiAction {
    # Runs a handler with busy visuals, error capture, and dashboard refresh.
    param([scriptblock]$Action)
    Set-BusyState $true
    $window.Dispatcher.Invoke([action]{}, 'Background')
    $failed = $false
    $errMsg = ""
    try {
        & $Action
    } catch {
        $failed = $true
        $errMsg = $_.Exception.Message
        Add-Log ("ERROR: " + $errMsg)
    } finally {
        Set-BusyState $false
    }
    try { Update-DashboardUI } catch {}
    if ($failed) {
        [System.Windows.MessageBox]::Show(
            (Get-Text "gui_err_failed") + "`n`n" + $errMsg,
            "PSManager", "OK", "Warning") | Out-Null
    }
}

function Invoke-GuiCliAction {
    <#
    .SYNOPSIS
        Delegates long-running CLI operations to the deep ActionEngine module in async mode.
    #>
    param(
        [string]$CliAction,
        [string[]]$CliArgs = @(),
        [string]$LogHeader
    )
    if ($Script:GuiBusy) { return }
    Set-BusyState $true
    $Script:GuiBusy = $true
    if ($LogHeader) { Add-Log ("[>] " + $LogHeader) }

    $cliPath = Join-Path $scriptRoot 'ps-manager.ps1'
    # The completion callback runs from a DispatcherTimer after this function has
    # returned, so it must not read this function's parameters. Capture the action
    # metadata in the script-scoped state object and read it from there.
    $cliState = [pscustomobject]@{
        Proc      = $null
        Done      = $false
        Header    = if ($LogHeader) { $LogHeader } else { $CliAction }
        ExitCode  = $null
        Action    = $CliAction
        Arguments = $CliArgs
    }
    $Script:CliState = $cliState
    $onCompleted = {
        param($res)
        $actionState = $Script:CliState
        $hdr = if ($actionState -and $actionState.Header) { $actionState.Header } else { $res.Action }
        $Script:CliState = $null
        $Script:GuiBusy = $false
        Set-BusyState $false
        try { Update-DashboardUI } catch {}
        $isAuditFindings = ($actionState -and $actionState.Action -eq 'audit-profile' -and $res.ExitCode -eq 1)
        try { Add-GuiActionNotification -Header $hdr -Success ([bool]$res.Success -or $isAuditFindings) -ExitCode ([int]$res.ExitCode) } catch {}
        if (-not $res.Success) {
            if ($actionState -and $actionState.Action -eq 'audit-profile' -and $res.ExitCode -eq 1) {
                Add-Log ("[!] " + $hdr + ": " + (Get-Text "gui_audit_issues_found"))
                if ($actionState.Arguments -notcontains '-Fix') {
                    $askFix = [System.Windows.MessageBox]::Show(
                        (Get-Text "gui_audit_issues_prompt"),
                        "PSManager", "YesNo", "Question")
                    if ($askFix -eq [System.Windows.MessageBoxResult]::Yes -or $askFix -eq 'Yes') {
                        Invoke-GuiCliAction -CliAction 'audit-profile' -CliArgs @('-Fix') -LogHeader ((Get-Text "gui_btn_audit_prof") + " (Fix)")
                    }
                }
            } else {
                Add-Log ("ERROR: " + $hdr + " exited with code " + $res.ExitCode)
                [System.Windows.MessageBox]::Show(
                    (Get-Text "gui_err_failed") + "`n`n" + $hdr + " -> exit " + $res.ExitCode,
                    "PSManager", "OK", "Warning") | Out-Null
            }
        } else {
            if ($actionState -and $actionState.Action -eq 'audit-profile') {
                Add-Log ("[OK] " + $hdr + ": " + (Get-Text "gui_audit_clean"))
            }
        }
    }

    $handle = Invoke-PSManagerAction -Action $CliAction -Arguments $CliArgs -Async -CliScriptPath $cliPath `
        -OnOutput {
            param($line)
            Add-Log (" | " + $line)
        } `
        -OnCompleted $onCompleted

    $Script:ActiveActionHandle = $handle
    if ([object]::ReferenceEquals($Script:CliState, $cliState)) {
        $cliState.Proc = if ($handle) { $handle.Process } else { $null }
    }
}

function Update-DashboardUI {
    $status = Get-PSManagerStatus
    $cfg = Get-PSManagerConfig

    # Language Texts - Clean vector typography (no emoji string prefixes)
    $txtSubtitle.Text          = (Get-Text "app_subtitle")
    $lblSecDefault.Text        = (Get-Text "gui_sec_default")
    $lblSecMaint.Text          = (Get-Text "gui_sec_maint")
    $lblSecSource.Text         = (Get-Text "gui_sec_source")
    $lblSource.Text            = (Get-Text "gui_lbl_source")
    $lblChannel.Text           = (Get-Text "gui_lbl_channel")
    $lblQuickLaunch.Text       = (Get-Text "gui_launch_title")
    $lblLog.Text               = (Get-Text "gui_log_title")
    $lblSecTools.Text          = (Get-Text "gui_sec_tools")
    $lblSecPkg.Text            = (Get-Text "gui_sec_pkg")
    $lblCardDefault.Text       = (Get-Text "gui_card_default")
    $lblCardHost.Text          = (Get-Text "gui_card_host")
    $lblCardShim.Text          = (Get-Text "gui_card_shim")
    $lblCardSource.Text        = (Get-Text "gui_card_source")
    $txtNavOverview.Text       = (Get-Text "gui_nav_overview")
    $txtNavUpdate.Text         = (Get-Text "gui_nav_update")
    $txtNavBackup.Text         = (Get-Text "gui_nav_backup")
    $txtNavHealth.Text         = (Get-Text "gui_nav_health")
    $txtNavProfile.Text        = (Get-Text "gui_nav_profile")
    $txtNavHelp.Text           = (Get-Text "gui_nav_help")
    $txtLogFilterHint.Text     = (Get-Text "gui_log_filter_placeholder")

    $txtBtnSetDefaultPS7.Text  = (Get-Text "gui_btn_def7")
    $txtBtnRestorePS5.Text     = (Get-Text "gui_btn_def5")
    $txtBtnUpdate.Text         = (Get-Text "gui_btn_update")
    $txtBtnInstall.Text        = (Get-Text "gui_btn_install")
    $txtBtnDiagnostics.Text    = (Get-Text "gui_btn_diag")
    $txtBtnLaunchTUI.Text      = (Get-Text "gui_btn_tui")
    $txtBtnSyncSources.Text    = (Get-Text "gui_btn_syncsources")
    $txtBtnViewLogs.Text       = (Get-Text "gui_btn_viewlogs")
    $txtBtnBackupProfiles.Text = (Get-Text "gui_btn_backup")
    $txtBtnRestoreBackup.Text  = (Get-Text "gui_btn_restore")
    $txtBtnBackupCloud.Text    = (Get-Text "gui_btn_cloud_backup")
    $txtBtnDeleteBackups.Text  = (Get-Text "gui_btn_clean_backups")
    $btnDeleteBackups.ToolTip  = (Get-Text "gui_btn_clean_backups_tip")

    $txtBtnLaunchPS7.Text      = (Get-Text "gui_btn_ps7")
    $txtBtnLaunchPS7Admin.Text = (Get-Text "gui_btn_ps7a")
    $txtBtnLaunchSplit.Text    = (Get-Text "gui_btn_split")
    $txtBtnLaunchPS5.Text      = (Get-Text "gui_btn_ps5")
    $txtBtnEditProfile.Text    = (Get-Text "menu_prof")
    $txtBtnAuditProfiles.Text  = (Get-Text "gui_btn_audit_prof")
    $txtBtnSyncNow.Text        = (Get-Text "gui_btn_sync")
    $txtBtnDoctorAudit.Text    = (Get-Text "gui_btn_doctor")
    $txtBtnDoctorFix.Text      = (Get-Text "gui_btn_doctor_fix")
    $txtBtnAdoptProfiles.Text  = (Get-Text "gui_btn_adopt")

    # Tooltips: one short sentence per action, reused as the inline page caption
    $btnRefresh.ToolTip        = Get-Text "gui_btn_refresh_tip"
    $btnSetDefaultPS7.ToolTip  = Get-Text "gui_btn_def7_tip"
    $btnRestorePS5.ToolTip     = Get-Text "gui_btn_def5_tip"
    $btnUpdate.ToolTip         = Get-Text "gui_btn_update_tip"
    $btnInstall.ToolTip        = Get-Text "gui_btn_install_tip"
    $btnDiagnostics.ToolTip    = Get-Text "gui_btn_diag_tip"
    $btnLaunchTUI.ToolTip      = Get-Text "gui_btn_tui_tip"
    $btnLaunchPS7.ToolTip      = Get-Text "gui_btn_ps7_tip"
    $btnLaunchPS7Admin.ToolTip = Get-Text "gui_btn_ps7a_tip"
    $btnLaunchSplit.ToolTip    = Get-Text "gui_btn_split_tip"
    $btnLaunchPS5.ToolTip      = Get-Text "gui_btn_ps5_tip"
    $btnEditProfile.ToolTip    = Get-Text "gui_btn_prof_tip"
    $btnAuditProfiles.ToolTip  = Get-Text "gui_btn_audit_prof_tip"
    $btnLogCopy.ToolTip        = Get-Text "gui_btn_copy"
    $btnLogClear.ToolTip       = Get-Text "gui_btn_clear"
    $btnSyncNow.ToolTip        = Get-Text "gui_btn_sync_tip"
    $btnDoctorAudit.ToolTip    = Get-Text "gui_btn_doctor_tip"
    $btnDoctorFix.ToolTip      = Get-Text "gui_btn_doctor_fix_tip"
    $btnAdoptProfiles.ToolTip  = Get-Text "gui_btn_adopt_tip"
    $btnSyncSources.ToolTip    = Get-Text "gui_btn_syncsources_tip"
    $btnViewLogs.ToolTip       = Get-Text "gui_btn_viewlogs_tip"
    $btnBackupProfiles.ToolTip = Get-Text "gui_btn_backup_tip"
    $btnRestoreBackup.ToolTip  = Get-Text "gui_btn_restore_tip"
    $btnBackupCloud.ToolTip    = Get-Text "gui_btn_cloud_backup_tip"
    $txtBtnSetCloudRepo.Text   = Get-Text "gui_btn_set_cloud_repo"
    $btnSetCloudRepo.ToolTip   = Get-Text "gui_btn_set_cloud_repo_tip"
    $btnSrcWinget.ToolTip      = Get-Text "gui_tip_source_winget"
    $btnSrcMsstore.ToolTip     = Get-Text "gui_tip_source_msstore"
    $btnSrcGithub.ToolTip      = Get-Text "gui_tip_source_github"
    $btnChStable.ToolTip       = Get-Text "gui_tip_channel_stable"
    $btnChPreview.ToolTip      = Get-Text "gui_tip_channel_preview"
    $btnChLts.ToolTip          = Get-Text "gui_tip_channel_lts"

    $guiLang = Get-GuiLanguage
    $txtLangToggle.Text = Get-GuiLanguageLabel $guiLang
    $btnLangToggle.ToolTip = Get-Text "gui_btn_lang_tip"

    # Page captions mirror the tooltip so the explanation is visible, not hover-only
    $txtCapDefaultPS7.Text     = [string]$btnSetDefaultPS7.ToolTip
    $txtCapRestorePS5.Text     = [string]$btnRestorePS5.ToolTip
    $txtCapUpdate.Text         = [string]$btnUpdate.ToolTip
    $txtCapInstall.Text        = [string]$btnInstall.ToolTip
    $txtCapSyncNow.Text        = [string]$btnSyncNow.ToolTip
    $txtCapSyncSources.Text    = [string]$btnSyncSources.ToolTip
    $txtCapBackupProfiles.Text = [string]$btnBackupProfiles.ToolTip
    $txtCapRestoreBackup.Text  = [string]$btnRestoreBackup.ToolTip
    $txtCapBackupCloud.Text    = [string]$btnBackupCloud.ToolTip
    $txtCapSetCloudRepo.Text   = ((Get-Text "gui_cap_cloud_repo") -f $(if ($cfg.PSObject.Properties['cloudRepo'] -and $cfg.cloudRepo) { [string]$cfg.cloudRepo } else { Get-Text "gui_cap_cloud_repo_auto" }))
    $txtCapDeleteBackups.Text  = [string]$btnDeleteBackups.ToolTip
    $txtCapDiagnostics.Text    = [string]$btnDiagnostics.ToolTip
    $txtCapDoctorAudit.Text    = [string]$btnDoctorAudit.ToolTip
    $txtCapDoctorFix.Text      = [string]$btnDoctorFix.ToolTip
    $txtCapEditProfile.Text    = [string]$btnEditProfile.ToolTip
    $txtCapAuditProfiles.Text  = [string]$btnAuditProfiles.ToolTip
    $txtCapAdoptProfiles.Text  = [string]$btnAdoptProfiles.ToolTip

    # Automation names: announce the visible label (icon-only buttons fall back to the tip)
    $automationNames = @(
        [pscustomobject]@{ Button = $btnSetDefaultPS7;  Name = $txtBtnSetDefaultPS7.Text }
        [pscustomobject]@{ Button = $btnRestorePS5;     Name = $txtBtnRestorePS5.Text }
        [pscustomobject]@{ Button = $btnUpdate;         Name = $txtBtnUpdate.Text }
        [pscustomobject]@{ Button = $btnInstall;        Name = $txtBtnInstall.Text }
        [pscustomobject]@{ Button = $btnDiagnostics;    Name = $txtBtnDiagnostics.Text }
        [pscustomobject]@{ Button = $btnLaunchTUI;      Name = $txtBtnLaunchTUI.Text }
        [pscustomobject]@{ Button = $btnSyncNow;        Name = $txtBtnSyncNow.Text }
        [pscustomobject]@{ Button = $btnDoctorAudit;    Name = $txtBtnDoctorAudit.Text }
        [pscustomobject]@{ Button = $btnDoctorFix;      Name = $txtBtnDoctorFix.Text }
        [pscustomobject]@{ Button = $btnAdoptProfiles;  Name = $txtBtnAdoptProfiles.Text }
        [pscustomobject]@{ Button = $btnSyncSources;    Name = $txtBtnSyncSources.Text }
        [pscustomobject]@{ Button = $btnViewLogs;       Name = $txtBtnViewLogs.Text }
        [pscustomobject]@{ Button = $btnBackupProfiles; Name = $txtBtnBackupProfiles.Text }
        [pscustomobject]@{ Button = $btnRestoreBackup;  Name = $txtBtnRestoreBackup.Text }
        [pscustomobject]@{ Button = $btnBackupCloud;    Name = $txtBtnBackupCloud.Text }
        [pscustomobject]@{ Button = $btnDeleteBackups;  Name = $txtBtnDeleteBackups.Text }
        [pscustomobject]@{ Button = $btnLaunchPS7;      Name = $txtBtnLaunchPS7.Text }
        [pscustomobject]@{ Button = $btnLaunchPS7Admin; Name = $txtBtnLaunchPS7Admin.Text }
        [pscustomobject]@{ Button = $btnLaunchSplit;    Name = $txtBtnLaunchSplit.Text }
        [pscustomobject]@{ Button = $btnLaunchPS5;      Name = $txtBtnLaunchPS5.Text }
        [pscustomobject]@{ Button = $btnEditProfile;    Name = $txtBtnEditProfile.Text }
        [pscustomobject]@{ Button = $btnAuditProfiles;  Name = $txtBtnAuditProfiles.Text }
        [pscustomobject]@{ Button = $btnLangToggle;     Name = $txtLangToggle.Text }
        [pscustomobject]@{ Button = $btnRefresh;        Name = [string]$btnRefresh.ToolTip }
        [pscustomobject]@{ Button = $btnLogCopy;        Name = [string]$btnLogCopy.ToolTip }
        [pscustomobject]@{ Button = $btnLogClear;       Name = [string]$btnLogClear.ToolTip }
        # Read labels from i18n, not from .Content/.ToolTip: those are only populated by
        # Update-GuiHelpPage/Update-GuiNotificationBadge later in this function, so the first
        # render would otherwise announce an empty string or "System.Windows.Controls.StackPanel".
        [pscustomobject]@{ Button = $btnHelp;           Name = (Get-Text "gui_btn_help_tip") }
        [pscustomobject]@{ Button = $btnNotifications;  Name = (Get-Text "gui_btn_notifications_tip") }
        [pscustomobject]@{ Button = $btnCheckUpdate;    Name = (Get-Text "help_btn_check") }
        [pscustomobject]@{ Button = $btnInstallUpdate;  Name = (Get-Text "help_btn_install") }
        [pscustomobject]@{ Button = $btnOpenRelease;    Name = (Get-Text "help_btn_release") }
        [pscustomobject]@{ Button = $btnOpenDocs;       Name = (Get-Text "help_link_docs") }
        [pscustomobject]@{ Button = $btnOpenRepo;       Name = (Get-Text "help_link_repo") }
        [pscustomobject]@{ Button = $btnOpenIssues;     Name = (Get-Text "help_link_issues") }
        [pscustomobject]@{ Button = $btnOpenLicense;    Name = (Get-Text "help_link_license") }
    )
    foreach ($item in $automationNames) {
        if ($item.Button) {
            [System.Windows.Automation.AutomationProperties]::SetName($item.Button, [string]$item.Name)
        }
    }

    # Version badge (from imported module manifest)
    $mod = Get-Module -Name PSManager -ErrorAction SilentlyContinue
    if ($mod) { $txtVersion.Text = "v" + $mod.Version.ToString() }

    # Cards
    if ($status.WTDefaultIsPS7) {
        $cardWTDefault.Text = "PowerShell 7"
        $cardWTDefault.Foreground = $Script:BrushGreen
        $cardWTSub.Text = (Get-Text "gui_card_wtps7")
    } elseif ($status.WTDefaultIsPS5) {
        $cardWTDefault.Text = "PowerShell 5.1"
        $cardWTDefault.Foreground = $Script:BrushAmber
        $cardWTSub.Text = (Get-Text "gui_card_wtps5")
    } else {
        $cardWTDefault.Text = "Custom"
        $cardWTDefault.Foreground = $Script:BrushGray
        $cardWTSub.Text = $status.WTDefaultProfile
    }

    if ($status.IsWTDefaultHost) {
        $cardHost.Text = "Windows Terminal"
        $cardHost.Foreground = $window.FindResource('AccentBrush')
        $cardHostSub.Text = (Get-Text "gui_card_host_wt")
    } else {
        $cardHost.Text = "ConHost (Legacy)"
        $cardHost.Foreground = $Script:BrushAmber
        $cardHostSub.Text = (Get-Text "gui_card_host_con")
    }

    if ($status.ShimActive) {
        $cardShim.Text = "Active (pwsh)"
        $cardShim.Foreground = $Script:BrushGreen
        $cardShimSub.Text = "powershell -> pwsh"
    } else {
        $cardShim.Text = "Inactive (5.1)"
        $cardShim.Foreground = $Script:BrushGray
        $cardShimSub.Text = "powershell -> 5.1"
    }

    $cardSource.Text = "$($cfg.updateSource):$($cfg.channel)"
    if ($status.TargetPackage -and $status.TargetPackage.PackageId) {
        $cardSourceSub.Text = $status.TargetPackage.PackageId
    } else {
        $cardSourceSub.Text = ""
    }

    # Segmented selections
    Set-SegmentedSelection -Buttons $sourceButtons -Selected $cfg.updateSource
    Set-SegmentedSelection -Buttons $channelButtons -Selected $cfg.channel

    # Help page + notification badge render last, after the language is settled.
    Update-GuiHelpPage
    Update-GuiNotificationBadge
}

# Attach Events
$btnRefresh.Add_Click({
    Invoke-GuiAction -Action { Add-Log (Get-Text "gui_log_refreshed") }
})

$window.Add_Activated({
    # Keep status cards current when the user returns from spawned terminals.
    try { Update-DashboardUI } catch {}
})

$btnLangToggle.Add_Click({
    Invoke-GuiAction -Action {
        $current = Get-GuiLanguage
        $script:Lang = $null
        $new = Get-NextGuiLanguage $current
        Set-PSManagerConfig -Language $new | Out-Null
        Add-Log ("Language -> " + $new)
    }
})

$btnSetDefaultPS7.Add_Click({
    Invoke-GuiAction -Action {
        Add-Log ("[>] " + (Get-Text "gui_btn_def7"))
        $res = Set-PowerShell7Default -Silent
        foreach ($k in $res.Keys) { Add-Log (" * " + $k + ": " + $res[$k]) }
    }
})

$btnRestorePS5.Add_Click({
    Invoke-GuiAction -Action {
        Add-Log ("[>] " + (Get-Text "gui_btn_def5"))
        $res = Set-PowerShell5Default -Silent
        foreach ($k in $res.Keys) { Add-Log (" * " + $k + ": " + $res[$k]) }
    }
})

$btnUpdate.Add_Click({
    Invoke-GuiAction -Action {
        Add-Log ("[>] " + (Get-Text "gui_btn_update"))
        Start-Process wt.exe -ArgumentList "-p `"PowerShell 7`" pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptRoot\ps-manager.ps1`" update"
        Add-Log (Get-Text "gui_log_terminal")
    }
})

$btnInstall.Add_Click({
    Invoke-GuiAction -Action {
        Add-Log ("[>] " + (Get-Text "gui_btn_install"))
        Start-Process wt.exe -ArgumentList "-p `"PowerShell 7`" pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptRoot\ps-manager.ps1`" install"
        Add-Log (Get-Text "gui_log_terminal")
    }
})

$btnDiagnostics.Add_Click({
    Invoke-GuiAction -Action {
        Start-Process wt.exe -ArgumentList "-p `"PowerShell 7`" pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptRoot\ps-manager.ps1`" diagnostics"
        Add-Log (Get-Text "gui_log_terminal")
    }
})

$btnLaunchTUI.Add_Click({
    Invoke-GuiAction -Action {
        Start-Process wt.exe -ArgumentList "-p `"PowerShell 7`" pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptRoot\ps-manager.ps1`" tui"
        Add-Log (Get-Text "gui_log_terminal")
    }
})

foreach ($sb in $sourceButtons) {
    $sb.Add_Checked({
        $tag = [string]$this.Tag
        if ($tag -eq (Get-PSManagerConfig).updateSource) { return }
        Invoke-GuiAction -Action {
            Set-PSManagerConfig -Source $tag | Out-Null
            Add-Log ("Source -> " + $tag)
        }
    })
}

foreach ($cb in $channelButtons) {
    $cb.Add_Checked({
        $tag = [string]$this.Tag
        if ($tag -eq (Get-PSManagerConfig).channel) { return }
        Invoke-GuiAction -Action {
            Set-PSManagerConfig -Channel $tag | Out-Null
            Add-Log ("Channel -> " + $tag)
        }
    })
}

$btnLaunchPS7.Add_Click({ Invoke-GuiAction -Action { Start-QuickShell -Target 'PS7'; Add-Log "Launched PowerShell 7." } })
$btnLaunchPS7Admin.Add_Click({ Invoke-GuiAction -Action { Start-QuickShell -Target 'PS7-Admin'; Add-Log "Launched PowerShell 7 (Admin)." } })
$btnLaunchSplit.Add_Click({ Invoke-GuiAction -Action { Start-QuickShell -Target 'Split'; Add-Log "Launched Side-by-Side split view." } })
$btnLaunchPS5.Add_Click({ Invoke-GuiAction -Action { Start-QuickShell -Target 'PS5'; Add-Log "Launched Windows PowerShell 5.1." } })

$btnEditProfile.Add_Click({
    Invoke-GuiAction -Action {
        $profiles = @(
            "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1",
            "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
        )
        $editor = if (Get-Command code -ErrorAction SilentlyContinue) { "code" } else { "notepad.exe" }
        foreach ($prof in $profiles) {
            Start-Process $editor -ArgumentList "`"$prof`""
            Add-Log ("Opened: " + $prof)
        }
    }
})

$btnLogCopy.Add_Click({
    $range = [System.Windows.Documents.TextRange]::new(
        $rtbConsoleLog.Document.ContentStart, $rtbConsoleLog.Document.ContentEnd)
    [System.Windows.Clipboard]::SetText($range.Text)
    Add-Log (Get-Text "gui_log_copied")
})

$btnLogClear.Add_Click({
    $Script:LogEntries.Clear()
    $rtbConsoleLog.Document.Blocks.Clear()
    Add-Log (Get-Text "gui_log_cleared")
})

$btnSyncNow.Add_Click({
    Invoke-GuiCliAction -CliAction 'sync' -LogHeader (Get-Text "gui_btn_sync")
})

$btnDoctorAudit.Add_Click({
    Invoke-GuiCliAction -CliAction 'doctor' -LogHeader (Get-Text "gui_btn_doctor")
})

$btnDoctorFix.Add_Click({
    Invoke-GuiCliAction -CliAction 'doctor' -CliArgs @('-Fix') -LogHeader (Get-Text "gui_btn_doctor_fix")
})

$btnAuditProfiles.Add_Click({
    Invoke-GuiCliAction -CliAction 'audit-profile' -LogHeader (Get-Text "gui_btn_audit_prof")
})
$btnAdoptProfiles.Add_Click({
    # Convert direction: LIVE profiles become the payload source of truth.
    $confirm = [System.Windows.MessageBox]::Show(
        (Get-Text "gui_adopt_confirm"), "PSManager", "YesNo", "Warning")
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Invoke-GuiAction -Action {
        Add-Log ("[>] " + (Get-Text "gui_btn_adopt"))
        $res = Adopt-PSManagerProfiles
        foreach ($d in $res.Details) { Add-Log (" * " + $d) }
        Add-Log ($res.Message)
    }
})

$btnSyncSources.Add_Click({
    Invoke-GuiCliAction -CliAction 'sync-sources' -LogHeader (Get-Text "gui_btn_syncsources")
})

$btnViewLogs.Add_Click({
    Invoke-GuiAction -Action {
        Add-Log ("[>] " + (Get-Text "gui_btn_viewlogs"))
        $lines = Get-PSManagerLogs -Tail 40
        if (-not $lines -or $lines.Count -eq 0) {
            Add-Log (" * " + (Get-Text "gui_log_logs_empty"))
        } else {
            foreach ($l in $lines) { Add-Log (" | " + $l) }
        }
    }
})

function Show-TextInputDialog {
    # Single-line text prompt (used by "Set Backup Repo"). Shares the passphrase dialog's
    # theme, validation row and cancel/OK contract; returns @{ Cancelled; Value }.
    param(
        [string]$Title = "Input",
        [string]$Message = "",
        [string]$Value = ""
    )

    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title"
        Height="200" Width="460"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#0F172A" Foreground="#F8FAFC"
        FontFamily="Segoe UI" ShowInTaskbar="False">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{DynamicResource FocusRing}"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FocusVisualStyle" Value="{DynamicResource FocusRing}"/>
        </Style>
    </Window.Resources>
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="$Message" FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,8"/>
        <TextBox x:Name="TxtValue" Grid.Row="1" Margin="0,0,0,10"/>
        <TextBlock x:Name="TxtError" Grid.Row="2" Text="" FontSize="11" Foreground="#F87171" Margin="0,0,0,8"/>

        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnCancel" Content="$(Get-Text 'gui_dialog_cancel')" Margin="0,0,8,0" Width="80" IsCancel="True"/>
            <Button x:Name="BtnOK" Content="$(Get-Text 'gui_dialog_ok')" Background="#0284C7" Width="80" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $rdr = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dlgXaml))
    $win = [System.Windows.Markup.XamlReader]::Load($rdr)
    Add-PSManagerGuiTheme -Window $win -ThemePath (Join-Path $scriptRoot 'ui\PSManager.Theme.xaml')
    $win.Owner = $window
    $txtValue = $win.FindName("TxtValue")
    $okBtn = $win.FindName("BtnOK")
    $cancelBtn = $win.FindName("BtnCancel")
    $txtValue.Text = [string]$Value

    $win.Add_Loaded({
        $txtValue.Focus()
        $txtValue.SelectAll()
    })

    $script:dlgOutcome = @{ Cancelled = $true; Value = $null }

    $cancelBtn.Add_Click({ $win.Close() })
    $okBtn.Add_Click({
        $script:dlgOutcome = @{ Cancelled = $false; Value = [string]$txtValue.Text }
        $win.Close()
    })

    $win.ShowDialog() | Out-Null
    return $script:dlgOutcome
}
function Show-PassphraseDialog {
    param(
        [string]$Title = "Passphrase",
        [string]$Message = "Enter passphrase:",
        [switch]$RequireConfirmation,
        [switch]$ShowToken
    )

    $height = if ($ShowToken) {
        if ($RequireConfirmation) { 330 } else { 260 }
    } else {
        if ($RequireConfirmation) { 260 } else { 190 }
    }
    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title"
        Height="$height" Width="430"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#0F172A" Foreground="#F8FAFC"
        FontFamily="Segoe UI" ShowInTaskbar="False">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{DynamicResource FocusRing}"/>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FocusVisualStyle" Value="{DynamicResource FocusRing}"/>
        </Style>
    </Window.Resources>
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="$(if ($RequireConfirmation) { 'Auto' } else { '0' })"/>
            <RowDefinition Height="$(if ($RequireConfirmation) { 'Auto' } else { '0' })"/>
            <RowDefinition Height="$(if ($ShowToken) { 'Auto' } else { '0' })"/>
            <RowDefinition Height="$(if ($ShowToken) { 'Auto' } else { '0' })"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock Grid.Row="0" Text="$Message" FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,8"/>
        <PasswordBox x:Name="TxtPass" Grid.Row="1" Margin="0,0,0,10"/>

        <TextBlock Grid.Row="2" Text="$(Get-Text 'gui_dialog_confirm_label')" FontSize="12" Foreground="#94A3B8" Margin="0,0,0,6"
                   Visibility="$(if ($RequireConfirmation) { 'Visible' } else { 'Collapsed' })"/>
        <PasswordBox x:Name="TxtPassConfirm" Grid.Row="3" Margin="0,0,0,10"
                     Visibility="$(if ($RequireConfirmation) { 'Visible' } else { 'Collapsed' })"/>

        <TextBlock Grid.Row="4" Text="$(Get-Text 'gui_dialog_token_label')" FontSize="12" Foreground="#94A3B8" TextWrapping="Wrap" Margin="0,0,0,6"
                   Visibility="$(if ($ShowToken) { 'Visible' } else { 'Collapsed' })"/>
        <PasswordBox x:Name="TxtToken" Grid.Row="5" Margin="0,0,0,10"
                     Visibility="$(if ($ShowToken) { 'Visible' } else { 'Collapsed' })"/>

        <TextBlock x:Name="TxtError" Grid.Row="6" Text="" FontSize="11" Foreground="#F87171" Margin="0,0,0,8"/>

        <StackPanel Grid.Row="7" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnCancel" Content="$(Get-Text 'gui_dialog_cancel')" Margin="0,0,8,0" Width="80" IsCancel="True"/>
            <Button x:Name="BtnOK" Content="$(Get-Text 'gui_dialog_ok')" Background="#0284C7" Width="80" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $rdr = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dlgXaml))
    $win = [System.Windows.Markup.XamlReader]::Load($rdr)
    Add-PSManagerGuiTheme -Window $win -ThemePath (Join-Path $scriptRoot 'ui\PSManager.Theme.xaml')
    $win.Owner = $window
    $pBox1 = $win.FindName("TxtPass")
    $pBox2 = $win.FindName("TxtPassConfirm")
    $tBox = $win.FindName("TxtToken")
    $errTxt = $win.FindName("TxtError")
    $okBtn = $win.FindName("BtnOK")
    $cancelBtn = $win.FindName("BtnCancel")

    # Initial keyboard focus on the password field
    $win.Add_Loaded({ $pBox1.Focus() })

    $script:dlgOutcome = @{ Cancelled = $true; Password = $null; Token = $null; IsEmpty = $true }

    $cancelBtn.Add_Click({ $win.Close() })
    $okBtn.Add_Click({
        if ($RequireConfirmation -and $pBox1.SecurePassword.Length -gt 0) {
            $p1Ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pBox1.SecurePassword)
            $p2Ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pBox2.SecurePassword)
            try {
                $p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p1Ptr)
                $p2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p2Ptr)
                if ($p1 -ne $p2) {
                    $errTxt.Text = Get-Text "gui_dialog_mismatch"
                    return
                }
            } finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p1Ptr)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p2Ptr)
            }
        }
        $script:dlgOutcome = @{
            Cancelled = $false
            Password  = if ($pBox1.SecurePassword.Length -gt 0) { $pBox1.SecurePassword } else { $null }
            Token     = if ($ShowToken -and $tBox -and $tBox.SecurePassword.Length -gt 0) { $tBox.SecurePassword } else { $null }
            IsEmpty   = ($pBox1.SecurePassword.Length -eq 0)
        }
        $win.Close()
    })

    $win.ShowDialog() | Out-Null
    return $script:dlgOutcome
}

$btnBackupProfiles.Add_Click({
    $dlg = Show-PassphraseDialog -Title (Get-Text "gui_btn_backup") -Message (Get-Text "gui_dialog_backup_msg") -RequireConfirmation
    if ($dlg.Cancelled) { return }

    Invoke-GuiAction -Action {
        Add-Log ("[>] " + (Get-Text "gui_btn_backup"))
        $zip = Backup-PSManagerProfiles -Passphrase $dlg.Password
        if ($zip) {
            $encTag = if ($dlg.Password) { " [Encrypted: AES-256 + HMAC]" } else { "" }
            Add-Log ((Get-Text "gui_log_backup_done") + " " + $zip + $encTag)
        } else {
            throw (Get-Text "gui_log_backup_fail")
        }
    }
})

$btnRestoreBackup.Add_Click({
    Invoke-GuiAction -Action {
        $backups = @(Get-PSManagerBackups)
        if ($backups.Count -eq 0) {
            Add-Log ("[>] " + (Get-Text "gui_btn_restore") + ": " + (Get-Text "gui_log_no_backups"))
            return
        }
        Add-Log ("[>] " + (Get-Text "gui_btn_restore"))
        # Pick backup via context menu at the button (most recent first)
        $menu = [System.Windows.Controls.ContextMenu]::new()
        foreach ($b in ($backups | Select-Object -First 10)) {
            $entry = [System.Windows.Controls.MenuItem]::new()
            $entry.Header = if ($b.IsEncrypted) { "[Encrypted] " + $b.Name } else { "[Zip] " + $b.Name }
            $entry.Tag = $b
            $entry.Add_Click({
                $item = $this.Tag
                $zipPath = $item.FullName
                $secPass = $null

                if ($item.IsEncrypted) {
                    $blob = [System.IO.File]::ReadAllBytes($zipPath)
                    $magic = if ($blob.Length -ge 6) { [System.Text.Encoding]::ASCII.GetString($blob, 0, 6) } else { "" }
                    if ($magic -in @("PSMGR1", "PSMGR2")) {
                        $dlg = Show-PassphraseDialog -Title (Get-Text "gui_btn_restore") -Message (Get-Text "gui_dialog_restore_msg")
                        if ($dlg.Cancelled -or -not $dlg.Password) {
                            Add-Log (" * " + (Get-Text "gui_log_restore_cancelled"))
                            return
                        }
                        $secPass = $dlg.Password
                    }
                }

                Invoke-GuiAction -Action {
                    Add-Log (" * restore: " + $zipPath)
                    $ok = Restore-PSManagerBackup -BackupZipPath $zipPath -Passphrase $secPass
                    if ($ok) {
                        Add-Log (Get-Text "gui_log_restore_done")
                    } else {
                        throw (Get-Text "gui_log_restore_fail")
                    }
                }
            })
            $menu.Items.Add($entry) | Out-Null
        }
        $menu.PlacementTarget = $btnRestoreBackup
        $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
        $menu.IsOpen = $true
        $btnRestoreBackup.IsEnabled = $true
    }
})

$btnBackupCloud.Add_Click({
    $dlg = Show-PassphraseDialog -Title (Get-Text "gui_btn_cloud_backup") -Message (Get-Text "gui_dialog_cloud_msg") -RequireConfirmation -ShowToken
    if ($dlg.Cancelled) { return }

    Invoke-GuiAction -Action {
        Add-Log ("[>] " + (Get-Text "gui_btn_cloud_backup"))
        $res = Publish-PSManagerCloudBackup -Passphrase $dlg.Password -Token $dlg.Token
        $encTag = if ($res.Encrypted) { " [Encrypted: AES-256 + HMAC]" } else { "" }
        Add-Log ((Get-Text "gui_log_cloud_backup_done") + " " + $res.Tag + $encTag)
        Add-Log (" * " + $res.Url)
    }
})

$btnSetCloudRepo.Add_Click({
    $cfgNow = Get-PSManagerConfig
    $currentRepo = if ($cfgNow.PSObject.Properties['cloudRepo'] -and $cfgNow.cloudRepo) { [string]$cfgNow.cloudRepo } else { "" }
    $dlg = Show-TextInputDialog -Title (Get-Text "gui_btn_set_cloud_repo") -Message (Get-Text "gui_dialog_cloud_repo_msg") -Value $currentRepo
    if ($dlg.Cancelled) { return }

    Invoke-GuiAction -Action {
        $repo = ([string]$dlg.Value).Trim()
        Add-Log ("[>] " + (Get-Text "gui_btn_set_cloud_repo"))
        $null = Set-PSManagerCloudRepo -Repo $repo
        $saved = (Get-PSManagerConfig).cloudRepo
        Add-Log ((Get-Text "gui_log_cloud_repo_saved") -f $(if ($saved) { [string]$saved } else { Get-Text "gui_cap_cloud_repo_auto" }))
        Update-DashboardUI
    }
})
function Show-BackupDeleteDialog {
    param([object[]]$Backups)

    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Delete Backups"
        Height="480" Width="600"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize"
        Background="#0F172A" Foreground="#F8FAFC"
        FontFamily="Segoe UI" ShowInTaskbar="False">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12,6"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{DynamicResource FocusRing}"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#1E293B"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="BorderBrush" Value="#334155"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FocusVisualStyle" Value="{DynamicResource FocusRing}"/>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="FocusVisualStyle" Value="{DynamicResource FocusRing}"/>
        </Style>
        <Style TargetType="ListBoxItem">
            <Setter Property="FocusVisualStyle" Value="{DynamicResource FocusRing}"/>
        </Style>
    </Window.Resources>
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Background="#7F1D1D" BorderBrush="#DC2626" BorderThickness="1"
                CornerRadius="6" Padding="12,10" Margin="0,0,0,10">
            <TextBlock x:Name="TxtDanger" Text="" FontSize="12" Foreground="#FEE2E2" TextWrapping="Wrap"/>
        </Border>

        <TextBlock x:Name="TxtSelectLabel" Grid.Row="1" Text="" FontSize="12" Foreground="#94A3B8" Margin="0,0,0,6"/>

        <ListBox x:Name="LstBackups" Grid.Row="2" SelectionMode="Extended"
                 Background="#0B1220" Foreground="#E2E8F0" BorderBrush="#334155" BorderThickness="1"
                 FontFamily="Cascadia Code, Consolas" FontSize="12" Padding="4"/>

        <TextBox x:Name="TxtConfirm" Grid.Row="3" Margin="0,10,0,10"/>

        <TextBlock x:Name="TxtError" Grid.Row="4" Text="" FontSize="11" Foreground="#F87171" Margin="0,0,0,8"/>

        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnCancelDlg" Content="$(Get-Text 'gui_dialog_cancel')" Margin="0,0,8,0" Width="90" IsCancel="True"/>
            <Button x:Name="BtnConfirmDelete" Content="$(Get-Text 'gui_btn_clean_backups')" Background="#B91C1C" BorderBrush="#DC2626" Width="140" IsEnabled="False"/>
        </StackPanel>
    </Grid>
</Window>
"@

    $rdr = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dlgXaml))
    $win = [System.Windows.Markup.XamlReader]::Load($rdr)
    Add-PSManagerGuiTheme -Window $win -ThemePath (Join-Path $scriptRoot 'ui\PSManager.Theme.xaml')
    $win.Owner = $window

    $lst = $win.FindName("LstBackups")
    $txtConfirm = $win.FindName("TxtConfirm")
    $txtDanger = $win.FindName("TxtDanger")
    $txtSelect = $win.FindName("TxtSelectLabel")
    $txtErr = $win.FindName("TxtError")
    $btnDel = $win.FindName("BtnConfirmDelete")
    $btnCancelDlg = $win.FindName("BtnCancelDlg")
    $win.Add_Loaded({ $lst.Focus() | Out-Null })

    $txtDanger.Text = (Get-Text "gui_clean_backups_confirm")
    $txtSelect.Text = (Get-Text "gui_clean_backups_select")

    foreach ($b in $Backups) {
        $enc = if ($b.IsEncrypted) { " [ENC]" } else { "" }
        $item = [System.Windows.Controls.ListBoxItem]::new()
        $item.Content = ("{0}{1}   ({2} KB, {3})" -f $b.Name, $enc, $b.SizeKB, $b.CreationTime.ToString("yyyy-MM-dd HH:mm"))
        $item.Tag = $b
        $lst.Items.Add($item) | Out-Null
    }

    $script:delOutcome = @{ Cancelled = $true; Names = @() }

    $txtConfirm.Add_TextChanged({
        $btnDel.IsEnabled = ($txtConfirm.Text -eq 'DELETE') -and ($lst.SelectedItems.Count -gt 0)
    })
    $lst.Add_SelectionChanged({
        $btnDel.IsEnabled = ($txtConfirm.Text -eq 'DELETE') -and ($lst.SelectedItems.Count -gt 0)
    })

    $btnCancelDlg.Add_Click({ $win.Close() })
    $btnDel.Add_Click({
        if ($lst.SelectedItems.Count -eq 0) {
            $txtErr.Text = "Select at least one backup."
            return
        }
        if ($txtConfirm.Text -ne 'DELETE') {
            $txtErr.Text = "Type DELETE to enable the delete button."
            return
        }
        $names = @()
        foreach ($it in $lst.SelectedItems) { $names += $it.Tag.Name }
        $script:delOutcome = @{ Cancelled = $false; Names = $names }
        $win.Close()
    })

    $win.ShowDialog() | Out-Null
    return $script:delOutcome
}

$btnDeleteBackups.Add_Click({
    $backups = @(Get-PSManagerBackups)
    if ($backups.Count -eq 0) {
        Add-Log ("[>] " + (Get-Text "gui_btn_clean_backups"))
        Add-Log ("   " + (Get-Text "gui_clean_backups_none"))
        return
    }

    $outcome = Show-BackupDeleteDialog -Backups $backups
    if ($outcome.Cancelled -or $outcome.Names.Count -eq 0) {
        Add-Log ("[!] " + (Get-Text "gui_clean_backups_aborted"))
        return
    }

    Invoke-GuiAction -Action {
        Add-Log ("[>] " + (Get-Text "gui_btn_clean_backups"))
        Add-Log ("   " + (Get-Text "gui_clean_backups_confirm").Split("`n")[0])
        $res = Remove-PSManagerBackup -Name @($outcome.Names) -Force -Confirm:$false
        Add-Log (" * " + (Get-Text "gui_clean_backups_done") + " " + $res.Deleted + " (freed " + $res.FreedKB + " KB)")
        foreach ($e in $res.Errors) { Add-Log ("   ! " + $e) }
    }
})
if ($btnCancelAction) {
    $btnCancelAction.Add_Click({
        if ($Script:ActiveActionHandle) {
            Stop-PSManagerAction -Handle $Script:ActiveActionHandle
            $Script:ActiveActionHandle = $null
            $Script:CliState = $null
            Add-Log ("[!] Action cancelled by user.")
            $Script:GuiBusy = $false
            Set-BusyState $false
            try { Update-DashboardUI } catch {}
        }
    })
}

if ($txtLogFilter) {
    $txtLogFilter.Add_TextChanged({
        if ($txtLogFilterHint) {
            $txtLogFilterHint.Visibility = if ($this.Text) { 'Collapsed' } else { 'Visible' }
        }
        Update-LogView -Filter $this.Text
    })
}

# Page navigation: one page visible at a time, the rail item carries the page key in Tag
$guiPageOrder = @('overview', 'update', 'backup', 'health', 'profile', 'help')
$guiRadioPanels = @($navOverview.Parent, $btnSrcWinget.Parent, $btnChStable.Parent)
Initialize-GuiNotifications -Window $window
Initialize-GuiHelp -Window $window
Initialize-GuiNavigation -Window $window -Pages $guiPages -Nav $guiNav `
    -PageOrder $guiPageOrder -RadioPanels $guiRadioPanels
Show-GuiPage -Name 'overview'
$window.Add_Loaded({ Start-GuiUpdateCheck })
# Window geometry persistence
$guiStateFile = Join-Path $scriptRoot "gui_state.json"
if (Test-Path -LiteralPath $guiStateFile) {
    try {
        $st = Get-Content -LiteralPath $guiStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.Width -gt 500)  { $window.Width  = $st.Width }
        if ($st.Height -gt 400) { $window.Height = $st.Height }
        if ($st.Top -ge 0)      { $window.Top    = $st.Top }
        if ($st.Left -ge 0)     { $window.Left   = $st.Left }
    } catch {}
}

$window.Add_Closing({
    try {
        $st = @{
            Width  = [int]$window.ActualWidth
            Height = [int]$window.ActualHeight
            Top    = [int]$window.Top
            Left   = [int]$window.Left
        } | ConvertTo-Json
        Set-Content -LiteralPath $guiStateFile -Value $st -Encoding UTF8 -Force
    } catch {}

    if ($Script:UpdateTimer) { $Script:UpdateTimer.Stop(); $Script:UpdateTimer = $null }
    if ($Script:ToastTimer) { $Script:ToastTimer.Stop(); $Script:ToastTimer = $null }
    if ($Script:UpdateJob) {
        try { Stop-Job -Job $Script:UpdateJob -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $Script:UpdateJob -Force -ErrorAction SilentlyContinue } catch {}
        $Script:UpdateJob = $null
    }

    if ($Script:ActiveActionHandle) {
        Stop-PSManagerAction -Handle $Script:ActiveActionHandle
    }
})

# Dark window title bar: attribute 20 on Windows 10 1809+, attribute 19 on older builds.
# Wrapped so hosts without dwmapi.dll (or with constrained language mode) keep a light frame
# instead of failing to start.
try {
    Add-Type -Namespace PSManager.Native -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);'
    $window.Add_SourceInitialized({
        try {
            $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
            $dark = 1
            $result = [PSManager.Native.Dwm]::DwmSetWindowAttribute($handle, 20, [ref]$dark, 4)
            if ($result -ne 0) {
                $null = [PSManager.Native.Dwm]::DwmSetWindowAttribute($handle, 19, [ref]$dark, 4)
            }
        } catch {}
    })
} catch {}

Set-BusyState $false
Update-DashboardUI
Add-Log (Get-Text "gui_log_ready")
$window.ShowDialog() | Out-Null
