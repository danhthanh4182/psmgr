#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Unit Tests - Extracted GUI XAML (ui\PSManager.MainWindow.xaml + theme).
.DESCRIPTION
    Guards the XAML/loader cutover:
      a. Both XAML resources exist.
      b. The loader returns a real Window with the theme dictionary merged.
      c. Every element gui.ps1 binds by name still resolves via FindName.
      d. The window XAML only uses StaticResource for icon geometries (everything
         else must be DynamicResource so the theme stays the single source of truth).
      e. Every theme token/style the window depends on resolves from the dictionary.
      f. Each page has exactly one primary action.
      g. The window keeps a title and a themed root background.
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$XamlDir = Join-Path $RootDir "ui"
$WindowXaml = Join-Path $XamlDir "PSManager.MainWindow.xaml"
$ThemeXaml = Join-Path $XamlDir "PSManager.Theme.xaml"
$Loader = Join-Path $XamlDir "GuiLoader.ps1"

Import-Module (Join-Path $RootDir "PSManager.psd1") -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Check {
    param([string]$Name, [scriptblock]$TestBlock)
    try {
        & $TestBlock
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $Name - $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add("$Name :: $($_.Exception.Message)")
    }
}

function Get-LogicalDescendant {
    # Depth-first walk over content-bearing WPF elements (no layout pass needed).
    param([object]$Root)
    $results = [System.Collections.Generic.List[object]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }
        $results.Add($node)
        if ($node -is [System.Windows.Controls.Panel]) {
            foreach ($child in $node.Children) { $stack.Push($child) }
        } elseif ($node -is [System.Windows.Controls.Decorator]) {
            $stack.Push($node.Child)
        } elseif ($node -is [System.Windows.Controls.ContentControl]) {
            $stack.Push($node.Content)
        } elseif ($node -is [System.Windows.Controls.ItemsControl]) {
            foreach ($item in $node.Items) { $stack.Push($item) }
        }
    }
    return $results
}

$script:Window = $null

try {
    Assert-Check -Name "Both XAML resources exist" -TestBlock {
        foreach ($path in @($WindowXaml, $ThemeXaml, $Loader)) {
            if (-not (Test-Path -LiteralPath $path)) { throw "Missing: $path" }
        }
    }

    Assert-Check -Name "Loader builds a Window with the theme merged" -TestBlock {
        . $Loader
        $script:Window = New-PSManagerGuiWindow -XamlPath $WindowXaml -ThemePath $ThemeXaml
        if ($script:Window -isnot [System.Windows.Window]) {
            throw "New-PSManagerGuiWindow returned $($script:Window.GetType().FullName)"
        }
        if ($script:Window.Resources.MergedDictionaries.Count -lt 1) {
            throw "Theme dictionary was not merged into the window resources"
        }
    }

    if ($null -eq $script:Window) {
        throw "Window did not load; later assertions cannot run"
    }

    # Materialise the log helpers from gui.ps1 once, at script scope: Assert-Check bodies
    # run in child scopes, so functions defined inside a check are not visible to the next.
    $guiSource = Get-Content -LiteralPath (Join-Path $RootDir 'gui.ps1') -Raw -Encoding UTF8
    $logStart = $guiSource.IndexOf('function Get-LogLevel')
    $logEnd = $guiSource.IndexOf('function Add-Log {', $logStart)
    if ($logStart -lt 0 -or $logEnd -lt 0) { throw "Log helpers not found in gui.ps1" }
    $script:window = $script:Window
    Invoke-Expression $guiSource.Substring($logStart, $logEnd - $logStart)

    # Language helpers drive the header mode label and the three-way toggle.
    $langStart = $guiSource.IndexOf('function Get-GuiLanguage')
    $langEnd = $guiSource.IndexOf('# The window markup', $langStart)
    if ($langStart -lt 0 -or $langEnd -lt 0) { throw "Language helpers not found in gui.ps1" }
    $script:Lang = $null
    Invoke-Expression $guiSource.Substring($langStart, $langEnd - $langStart)

    Assert-Check -Name "Language toggle cycles en -> vi-ascii -> vi and labels the active mode" -TestBlock {
        $orig = Get-PSManagerConfig
        try {
            $transitions = @(
                @{ From = 'en'; To = 'vi-ascii' },
                @{ From = 'vi-ascii'; To = 'vi' },
                @{ From = 'vi'; To = 'en' }
            )
            foreach ($step in $transitions) {
                Set-PSManagerConfig -Language $step.From | Out-Null
                $resolved = Get-GuiLanguage
                if ($resolved -ne $step.From) {
                    throw ("Configured '{0}' rendered as '{1}'" -f $step.From, $resolved)
                }
                $next = Get-NextGuiLanguage $resolved
                if ($next -ne $step.To) {
                    throw ("'{0}' cycled to '{1}', expected '{2}'" -f $step.From, $next, $step.To)
                }
                Set-PSManagerConfig -Language $next | Out-Null
                if ((Get-PSManagerConfig).language -ne $step.To) {
                    throw ("'{0}' was not persisted" -f $step.To)
                }
            }

            foreach ($mode in @('en', 'vi-ascii', 'vi')) {
                Set-PSManagerConfig -Language $mode | Out-Null
                $resolved = Get-GuiLanguage
                if ($resolved -ne $mode) {
                    throw ("Configured '{0}' rendered as '{1}'" -f $mode, $resolved)
                }
                $label = Get-GuiLanguageLabel $resolved
                if ([string]::IsNullOrWhiteSpace($label) -or $label -like 'gui_lang_*') {
                    throw ("No label for '{0}'" -f $mode)
                }
            }

            $asciiLabel = Get-GuiLanguageLabel 'vi-ascii'
            if ($asciiLabel -notmatch 'ASCII') { throw "vi-ascii label does not name the ASCII mode: $asciiLabel" }
            $nonAscii = @($asciiLabel.ToCharArray() | Where-Object { [int]$_ -gt 126 })
            if ($nonAscii.Count -gt 0) { throw "vi-ascii label contains non-ASCII characters: $asciiLabel" }
        } finally {
            Set-PSManagerConfig -Source $orig.updateSource -Channel $orig.channel -Language $orig.language | Out-Null
        }
    }

    Assert-Check -Name "Every GUI element name still resolves via FindName" -TestBlock {
        $names = @(
            'BtnRefresh', 'BtnLangToggle', 'TxtLangToggle', 'TxtVersion', 'TxtSubtitle',
            'BtnLaunchTUI', 'TxtBtnLaunchTUI', 'LblSecDefault', 'LblSecMaint', 'LblSecSource',
            'LblSecPkg', 'LblSecTools', 'LblQuickLaunch', 'LblLog', 'LblSource', 'LblChannel',
            'LblCardDefault', 'LblCardHost', 'LblCardShim', 'LblCardSource',
            'CardWTDefault', 'CardWTSub', 'CardHost', 'CardHostSub', 'CardShim', 'CardShimSub',
            'CardSource', 'CardSourceSub',
            'BtnSetDefaultPS7', 'TxtBtnSetDefaultPS7', 'BtnRestorePS5', 'TxtBtnRestorePS5',
            'BtnUpdate', 'TxtBtnUpdate', 'BtnInstall', 'TxtBtnInstall',
            'BtnDiagnostics', 'TxtBtnDiagnostics', 'BtnEditProfile', 'TxtBtnEditProfile',
            'BtnAuditProfiles', 'TxtBtnAuditProfiles', 'BtnAdoptProfiles', 'TxtBtnAdoptProfiles',
            'BtnSyncNow', 'TxtBtnSyncNow', 'BtnDoctorAudit', 'TxtBtnDoctorAudit',
            'BtnDoctorFix', 'TxtBtnDoctorFix', 'BtnSyncSources', 'TxtBtnSyncSources',
            'BtnViewLogs', 'TxtBtnViewLogs', 'BtnBackupProfiles', 'TxtBtnBackupProfiles',
            'BtnRestoreBackup', 'TxtBtnRestoreBackup', 'BtnBackupCloud', 'TxtBtnBackupCloud',
            'BtnDeleteBackups', 'TxtBtnDeleteBackups',
            'BtnSrcWinget', 'BtnSrcMsstore', 'BtnSrcGithub', 'BtnChStable', 'BtnChPreview', 'BtnChLts',
            'BtnLaunchPS7', 'TxtBtnLaunchPS7', 'BtnLaunchPS7Admin', 'TxtBtnLaunchPS7Admin',
            'BtnLaunchSplit', 'TxtBtnLaunchSplit', 'BtnLaunchPS5', 'TxtBtnLaunchPS5',
            'BtnLogCopy', 'BtnLogClear', 'TxtLogFilter', 'TxtLogFilterHint', 'TxtStatusHint',
            'PrgBusy', 'BtnCancelAction', 'RtbConsoleLog',
            'NavOverview', 'NavUpdate', 'NavBackup', 'NavHealth', 'NavProfile',
            'TxtNavOverview', 'TxtNavUpdate', 'TxtNavBackup', 'TxtNavHealth', 'TxtNavProfile',
            'PageOverview', 'PageUpdate', 'PageBackup', 'PageHealth', 'PageProfile',
            'TxtCapDefaultPS7', 'TxtCapRestorePS5', 'TxtCapUpdate', 'TxtCapInstall',
            'TxtCapSyncNow', 'TxtCapSyncSources', 'TxtCapBackupProfiles', 'TxtCapRestoreBackup',
            'TxtCapBackupCloud', 'TxtCapDeleteBackups', 'TxtCapDiagnostics', 'TxtCapDoctorAudit',
            'TxtCapDoctorFix', 'TxtCapEditProfile', 'TxtCapAuditProfiles', 'TxtCapAdoptProfiles',
            'NavHelp', 'TxtNavHelp', 'PageHelp',
            'BtnHelp', 'BtnNotifications', 'NotifBadge', 'TxtNotifBadge',
            'NotifPanel', 'NotifList', 'TxtNotifEmpty', 'BtnNotifClear', 'BtnNotifClose', 'TxtNotifTitle',
            'ToastPanel', 'TxtToastTitle', 'TxtToastMessage', 'BtnToastClose',
            'BtnCheckUpdate', 'BtnInstallUpdate', 'BtnOpenRelease',
            'BtnOpenDocs', 'BtnOpenRepo', 'BtnOpenIssues', 'BtnOpenLicense',
            'TxtBtnCheckUpdate', 'TxtBtnInstallUpdate', 'TxtBtnOpenRelease',
            'TxtBtnOpenDocs', 'TxtBtnOpenRepo', 'TxtBtnOpenIssues', 'TxtBtnOpenLicense',
            'HelpCommandList', 'LblHelpCommands',
            'TxtHelpTitle', 'TxtHelpSubtitle', 'TxtHelpVersion', 'TxtHelpIntro', 'TxtCapCheckUpdate',
            'LblHelpQuickStart', 'TxtHelpQuickDefault', 'TxtHelpQuickDefaultDesc',
            'TxtHelpQuickSync', 'TxtHelpQuickSyncDesc',
            'TxtHelpQuickUpdate', 'TxtHelpQuickUpdateDesc',
            'LblHelpUpdate', 'TxtHelpUpdateStatus', 'TxtHelpUpdateDetail', 'TxtHelpUpdateChecked',
            'LblHelpShortcuts', 'TxtHelpShortcuts', 'LblHelpLinks', 'LblHelpAbout', 'TxtHelpAbout'
        )
        $missing = @()
        foreach ($name in $names) {
            if ($null -eq $script:Window.FindName($name)) { $missing += $name }
        }
        if ($missing.Count -gt 0) {
            throw ("FindName did not resolve: " + ($missing -join ', '))
        }
    }

    Assert-Check -Name "Navigation rail items pair a vector icon with each label" -TestBlock {
        $navNames = @('NavOverview', 'NavUpdate', 'NavBackup', 'NavHealth', 'NavProfile', 'NavHelp')
        foreach ($navName in $navNames) {
            $navItem = $script:Window.FindName($navName)
            if ($navItem.Content -isnot [System.Windows.Controls.StackPanel]) {
                throw "$navName content must be a StackPanel containing an icon and label"
            }
            $icon = @($navItem.Content.Children | Where-Object { $_ -is [System.Windows.Shapes.Path] })
            if ($icon.Count -ne 1 -or $null -eq $icon[0].Data) {
                throw "$navName must render exactly one vector icon"
            }
        }
    }

    Assert-Check -Name "Window XAML only uses StaticResource for icon geometries" -TestBlock {
        $text = Get-Content -LiteralPath $WindowXaml -Raw -Encoding UTF8
        $keys = [regex]::Matches($text, '\{StaticResource\s+([^}\s]+)\s*\}') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $invalid = @($keys | Where-Object { $_ -notlike 'Icon*' })
        if ($invalid.Count -gt 0) {
            throw ("StaticResource used for non-icon keys: " + ($invalid -join ', '))
        }
    }

    Assert-Check -Name "Theme tokens and styles resolve from the merged dictionary" -TestBlock {
        $keys = @(
            'Btn', 'BtnPrimary', 'BtnDanger', 'BtnRow', 'Switch', 'Segment', 'SectionTitle',
            'Caption', 'Chip', 'Panel', 'NavItem', 'FieldLabel', 'FocusRing',
            'UiFont', 'MonoFont', 'IconFont',
            'BgBrush', 'SurfaceBrush', 'RaisedBrush', 'BorderBrush', 'TextBrush', 'TextDimBrush',
            'AccentBrush', 'AccentSoftBrush', 'OnAccentBrush', 'OkBrush', 'WarnBrush',
            'DangerBrush', 'DangerLineBrush'
        )
        $missing = @()
        foreach ($key in $keys) {
            try {
                $null = $script:Window.FindResource($key)
            } catch {
                $missing += $key
            }
        }
        if ($missing.Count -gt 0) {
            throw ("Theme keys missing: " + ($missing -join ', '))
        }
    }

    Assert-Check -Name "Each page declares exactly one primary action" -TestBlock {
        $primary = $script:Window.FindResource('BtnPrimary')
        foreach ($pageName in @('PageOverview', 'PageUpdate', 'PageBackup', 'PageHealth', 'PageProfile', 'PageHelp')) {
            $page = $script:Window.FindName($pageName)
            if ($null -eq $page) { throw "$pageName not found" }
            $buttons = @(Get-LogicalDescendant -Root $page | Where-Object { $_ -is [System.Windows.Controls.Button] })
            $primaries = @($buttons | Where-Object { [object]::ReferenceEquals($_.Style, $primary) })
            if ($primaries.Count -ne 1) {
                throw ("{0} has {1} primary buttons (labels: {2})" -f $pageName, $primaries.Count, (($buttons | ForEach-Object { $_.Name }) -join ','))
            }
        }
    }

    Assert-Check -Name "Window title and themed root background are set" -TestBlock {
        if ([string]::IsNullOrWhiteSpace($script:Window.Title)) { throw "Window.Title is empty" }
        $root = $script:Window.Content
        if ($null -eq $root) { throw "Window has no content" }
        if ($null -eq $root.Background) { throw "Root grid has no background brush" }
    }

    Assert-Check -Name "Log entries render level colours and clickable hyperlinks" -TestBlock {

        if ((Get-LogLevel -Text 'ERROR: boom') -ne 'Error') { throw "ERROR prefix not classified as Error" }
        if ((Get-LogLevel -Text '[!] careful') -ne 'Warn') { throw "[!] prefix not classified as Warn" }
        if ((Get-LogLevel -Text '[OK] done') -ne 'Success') { throw "[OK] prefix not classified as Success" }
        if ((Get-LogLevel -Text '[>] start') -ne 'Accent') { throw "[>] prefix not classified as Accent" }
        if ((Get-LogLevel -Text 'plain line') -ne 'Info') { throw "Plain line not classified as Info" }

        $blocks = $script:Window.FindName('RtbConsoleLog').Document.Blocks
        $blocks.Clear()
        $entry = [pscustomobject]@{
            Time  = '10:00:00'
            Level = 'Error'
            Text  = 'ERROR: see https://example.com/diag for details'
        }
        Add-LogEntryBlock -Entry $entry -Blocks $blocks
        if ($blocks.Count -ne 1) { throw "Expected 1 log paragraph, got $($blocks.Count)" }

        $paragraph = $blocks[0]
        $links = @($paragraph.Inlines | Where-Object { $_ -is [System.Windows.Documents.Hyperlink] })
        if ($links.Count -ne 1) { throw "Expected 1 hyperlink, got $($links.Count)" }
        $navigateUri = $links[0].NavigateUri
        if ($null -eq $navigateUri -or $navigateUri.AbsoluteUri -ne 'https://example.com/diag') {
            throw "Hyperlink target wrong: $navigateUri"
        }

        $runs = @($paragraph.Inlines | Where-Object { $_ -is [System.Windows.Documents.Run] })
        $danger = $script:Window.FindResource('DangerBrush')
        $dim = $script:Window.FindResource('TextDimBrush')
        $stampRun = @($runs | Where-Object { $_.Text -like '`[10:00:00`]*' })[0]
        if ($null -eq $stampRun -or -not [object]::ReferenceEquals($stampRun.Foreground, $dim)) {
            throw "Timestamp run is not using the dim token"
        }
        $bodyRun = @($runs | Where-Object { $_.Text -like 'ERROR:*' })[0]
        if ($null -eq $bodyRun -or -not [object]::ReferenceEquals($bodyRun.Foreground, $danger)) {
            throw "Error text is not using the danger token"
        }
    }

    Assert-Check -Name "Log filter narrows entries and clearing restores them" -TestBlock {
        $script:LogEntries = [System.Collections.Generic.List[object]]::new()
        $script:LogEntries.Add([pscustomobject]@{ Time = '10:00:00'; Level = 'Info'; Text = 'alpha' })
        $script:LogEntries.Add([pscustomobject]@{ Time = '10:00:01'; Level = 'Error'; Text = 'ERROR beta' })
        $script:LogEntries.Add([pscustomobject]@{ Time = '10:00:02'; Level = 'Info'; Text = 'gamma' })
        $rtbConsoleLog = $script:Window.FindName('RtbConsoleLog')

        Update-LogView -Filter 'ERROR'
        if ($rtbConsoleLog.Document.Blocks.Count -ne 1) {
            throw ("Filtered view should hold 1 entry, got {0}" -f $rtbConsoleLog.Document.Blocks.Count)
        }
        Update-LogView -Filter ''
        if ($rtbConsoleLog.Document.Blocks.Count -ne 3) {
            throw ("Unfiltered view should hold 3 entries, got {0}" -f $rtbConsoleLog.Document.Blocks.Count)
        }
    }

    Assert-Check -Name "Action handlers still call their original targets" -TestBlock {
        # Guards against a rewrite that re-points a button at a different function.
        $source = Get-Content -LiteralPath (Join-Path $RootDir 'gui.ps1') -Raw -Encoding UTF8
        $pairs = @(
            @{ Var = '$btnSetDefaultPS7'; Target = 'Set-PowerShell7Default' }
            @{ Var = '$btnRestorePS5';    Target = 'Set-PowerShell5Default' }
            @{ Var = '$btnUpdate';        Target = 'ps-manager.ps1`" update' }
            @{ Var = '$btnInstall';       Target = 'ps-manager.ps1`" install' }
            @{ Var = '$btnDiagnostics';   Target = 'ps-manager.ps1`" diagnostics' }
            @{ Var = '$btnLaunchTUI';     Target = 'ps-manager.ps1`" tui' }
            @{ Var = '$btnSyncNow';       Target = "-CliAction 'sync'" }
            @{ Var = '$btnDoctorAudit';   Target = "-CliAction 'doctor'" }
            @{ Var = '$btnDoctorFix';     Target = "@('-Fix')" }
            @{ Var = '$btnAuditProfiles'; Target = "-CliAction 'audit-profile'" }
            @{ Var = '$btnAdoptProfiles'; Target = 'Adopt-PSManagerProfiles' }
            @{ Var = '$btnSyncSources';   Target = "-CliAction 'sync-sources'" }
            @{ Var = '$btnViewLogs';      Target = 'Get-PSManagerLogs' }
            @{ Var = '$btnBackupProfiles';Target = 'Backup-PSManagerProfiles' }
            @{ Var = '$btnRestoreBackup'; Target = 'Restore-PSManagerBackup' }
            @{ Var = '$btnBackupCloud';   Target = 'Publish-PSManagerCloudBackup' }
            @{ Var = '$btnDeleteBackups'; Target = 'Remove-PSManagerBackup' }
            @{ Var = '$btnLaunchPS7';     Target = "Start-QuickShell -Target 'PS7'" }
            @{ Var = '$btnLaunchPS7Admin';Target = "Start-QuickShell -Target 'PS7-Admin'" }
            @{ Var = '$btnLaunchSplit';   Target = "Start-QuickShell -Target 'Split'" }
            @{ Var = '$btnLaunchPS5';     Target = "Start-QuickShell -Target 'PS5'" }
            @{ Var = '$btnEditProfile';   Target = 'Start-Process $editor' }
            @{ Var = '$btnLangToggle';    Target = 'Set-PSManagerConfig -Language' }
            @{ Var = '$btnLangToggle';    Target = 'Get-NextGuiLanguage $current' }
        )

        foreach ($pair in $pairs) {
            $marker = $pair.Var + '.Add_Click({'
            $start = $source.IndexOf($marker)
            if ($start -lt 0) { throw ("{0}: no Add_Click handler found" -f $pair.Var) }
            $end = $source.IndexOf("`n})", $start)
            if ($end -lt 0) { throw ("{0}: unterminated handler" -f $pair.Var) }
            $body = $source.Substring($start, $end - $start)
            if ($body.IndexOf($pair.Target) -lt 0) {
                throw ("{0} no longer calls '{1}'" -f $pair.Var, $pair.Target)
            }
        }
    }

    Assert-Check -Name "Header toggle renders the active language mode label" -TestBlock {
        $source = Get-Content -LiteralPath (Join-Path $RootDir 'gui.ps1') -Raw -Encoding UTF8
        if ($source.IndexOf('$txtLangToggle.Text = Get-GuiLanguageLabel $guiLang') -lt 0) {
            throw "Update-DashboardUI no longer renders Get-GuiLanguageLabel"
        }
    }

    Assert-Check -Name "Action map GUI names match the window XAML" -TestBlock {
        $mapPath = Join-Path $RootDir 'docs/ui-ux/action-map.md'
        if (-not (Test-Path -LiteralPath $mapPath)) { throw "action-map.md missing at $mapPath" }
        $map = Get-Content -LiteralPath $mapPath -Raw -Encoding UTF8
        $names = [regex]::Matches($map, '`(Btn[A-Za-z0-9]+)`') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        if ($names.Count -eq 0) { throw "action-map.md lists no GUI element names" }
        $missing = @($names | Where-Object { $null -eq $script:Window.FindName($_) })
        if ($missing.Count -gt 0) {
            throw ("action-map names that do not exist in the window: " + ($missing -join ', '))
        }
    }
} finally {
    if ($script:Window) { $script:Window.Close() }
}

if ($failures.Count -gt 0) {
    Write-Host ("`nGUI XAML tests FAILED: " + $failures.Count + " failure(s)") -ForegroundColor Red
    exit 1
}

Write-Host "test_gui_xaml.ps1 passed all checks" -ForegroundColor Green
exit 0
