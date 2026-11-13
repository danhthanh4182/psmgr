#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Root Module
.DESCRIPTION
    PowerShell Version Manager Module: TUI, CLI, and WPF Desktop GUI.
#>

$Script:MODULE_ROOT = $PSScriptRoot

# Submodules loading in dependency order
$Script:SUBMODULES = @(
    "modules\Core\Encoding.ps1",
    "modules\Core\Config.ps1",
    "modules\Core\Logger.ps1",
    "modules\Core\Security.ps1",
    "modules\Core\I18n.ps1",
    "modules\Core\ActionRegistry.ps1",
    "modules\Core\Help.ps1",
    "modules\Core\Notification.ps1",
    "modules\Core\ActionEngine.ps1",
    "modules\UI\Theme.ps1",
    "modules\Environment\Detection.ps1",
    "modules\Environment\SystemConfig.ps1",
    "modules\Package\SourceManager.ps1",
    "modules\Package\UpdateNotifier.ps1",
    "modules\Package\Updater.ps1",
    "modules\Launcher\ShellSwitcher.ps1",
    "modules\Sync\Linker.ps1",
    "modules\Sync\AppResolver.ps1",
    "modules\Sync\Manifest.ps1",
    "modules\Sync\Provisioner.ps1",
    "modules\Sync\Backup.ps1",
    "modules\Sync\SyncEngine.ps1",
    "modules\Sync\ProfileAuditor.ps1",
    "modules\UI\Diagnostics.ps1",
    "modules\UI\TuiCapabilities.ps1",
    "modules\UI\TuiCatalog.ps1",
    "modules\UI\TuiRender.ps1",
    "modules\UI\TuiState.ps1",
    "modules\UI\TuiEngine.ps1"
)

foreach ($relPath in $Script:SUBMODULES) {
    $fullPath = Join-Path -Path $Script:MODULE_ROOT -ChildPath $relPath
    if (Test-Path $fullPath) {
        . $fullPath
    } else {
        Write-Warning "PSManager submodule missing: $fullPath"
    }
}

# Auto-initialize console encoding
Initialize-ConsoleEncoding

# Module version, read from the manifest so it stays a single source of truth
function Get-PSManagerVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param()

    $manifestPath = Join-Path $PSScriptRoot 'PSManager.psd1'
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
            if ($manifest -and $manifest.Version) { return [version]$manifest.Version }
        } catch {
            Write-PSManagerLog -Message ("Manifest version lookup failed: {0}" -f $_.Exception.Message) -Level WARN
        }
    }
    return [version]'0.0.0'
}

$Script:VERSION = Get-PSManagerVersion

function Get-PSManagerUpdateHint {
    <#
    .SYNOPSIS
        One localized line describing the cached PSManager release status.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Language)

    try {
        $status = Get-PSManagerUpdateStatus -CacheOnly
    } catch {
        return $null
    }
    if ($null -eq $status) { return $null }

    switch ($status.Status) {
        'Available' { return ((Get-I18nText 'update_available_hint' $Language) -f $status.LatestVersion) }
        'Current'   { return (Get-I18nText 'update_none_hint' $Language) }
        'Disabled'  { return (Get-I18nText 'update_status_disabled' $Language) }
        'Error'     { return ((Get-I18nText 'update_error_hint' $Language) -f $status.Error) }
        default     { return (Get-I18nText 'help_update_not_checked' $Language) }
    }
}

function Write-PSManagerHelpSections {
    <#
    .SYNOPSIS
        Renders the grouped command reference from the shared catalog.
    #>
    [CmdletBinding()]
    param([string]$Language)

    $sections = @(Get-PSManagerHelpSections -Language $Language)
    $nameWidth = 4
    foreach ($section in $sections) {
        foreach ($item in $section.Items) {
            if ($item.Usage.Length -gt $nameWidth) { $nameWidth = $item.Usage.Length }
        }
    }
    $nameWidth = [Math]::Min(46, $nameWidth + 2)

    foreach ($section in $sections) {
        Write-Host ''
        Write-Host (Format-ColorText $Script:THEME.Gray ('  ' + $section.Title))
        foreach ($item in $section.Items) {
            $usage = $item.Usage.PadRight($nameWidth)
            Write-Host ('    ' + (Format-ColorText $Script:THEME.Cyan $usage) + (Format-ColorText $Script:THEME.White $item.Desc))
        }
    }
}

function Show-PSManagerHelp {
    <#
    .SYNOPSIS
        Renders the command reference, one command's detail, or the aliases for it.
    .DESCRIPTION
        Text comes from i18n.json through the shared help catalog (modules/Core/Help.ps1) so
        the CLI, the TUI overlay and the desktop Help page never disagree. Returns $false when
        a -Command name is unknown, so callers can map it to exit code 1.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$Command,
        [string]$Language
    )

    $lang = if ($Language) { $Language } else { Get-EffectiveLanguage }
    try { Clear-Host } catch {}

    Write-Host ''
    Write-Host (Format-ColorText ($Script:THEME.Cyan + $Script:THEME.Bold) ('  PSManager v' + $Script:VERSION))
    Write-Host (Format-ColorText $Script:THEME.Gray ('  ' + (Get-I18nText 'help_intro' $lang)))
    Write-Host (Format-ColorText $Script:THEME.Gray ('  ' + (Get-I18nText 'nav_help' $lang)))
    Write-CliRule

    $updateHint = Get-PSManagerUpdateHint -Language $lang

    if ($Command) {
        $entry = Get-PSManagerHelpEntry -Name $Command -Language $lang
        if ($null -eq $entry) {
            Write-CliError ((Get-I18nText 'help_command_not_found' $lang) -f $Command)
            return $false
        }

        Write-Host ''
        Write-Host (Format-ColorText ($Script:THEME.Cyan + $Script:THEME.Bold) ('  ' + (Get-I18nText 'help_usage' $lang)))
        Write-Host ('    ' + (Format-ColorText $Script:THEME.White $entry.Usage))

        Write-Host ''
        Write-Host (Format-ColorText $Script:THEME.White ('  ' + $entry.Title))
        if ($entry.Desc) { Write-Host (Format-ColorText $Script:THEME.Gray ('    ' + $entry.Desc)) }

        Write-Host ''
        Write-Host (Format-ColorText $Script:THEME.Gray ('    ' + (Get-I18nText 'help_more' $lang)))

        if ($updateHint) {
            Write-Host ''
            Write-Host (Format-ColorText $Script:THEME.Gray ('  ' + $updateHint))
        }
        Write-Host ''
        return $true
    }

    Write-PSManagerHelpSections -Language $lang

    Write-Host ''
    Write-Host (Format-ColorText ($Script:THEME.Cyan + $Script:THEME.Bold) ('  ' + (Get-I18nText 'help_examples' $lang)))
    Write-Host ('    ' + (Format-ColorText $Script:THEME.Gray '# switch every Windows entry point to PowerShell 7'))
    Write-Host ('    ' + (Format-ColorText $Script:THEME.White 'psmgr set-default ps7'))
    Write-Host ('    ' + (Format-ColorText $Script:THEME.Gray '# preview profile sync without touching files'))
    Write-Host ('    ' + (Format-ColorText $Script:THEME.White 'psmgr sync -DryRun'))
    Write-Host ('    ' + (Format-ColorText $Script:THEME.Gray '# plain output for logs and scripts'))
    Write-Host ('    ' + (Format-ColorText $Script:THEME.White 'psmgr status -NoColor'))

    Write-Host ''
    Write-Host (Format-ColorText ($Script:THEME.Cyan + $Script:THEME.Bold) ('  ' + (Get-I18nText 'help_exit_codes' $lang)))
    Write-Host ('    ' + (Format-ColorText $Script:THEME.White '0') + (Format-ColorText $Script:THEME.Gray '  success                                  ') + `
                (Format-ColorText $Script:THEME.White '1') + (Format-ColorText $Script:THEME.Gray '  failure, findings or refusal (no -Force / no TTY)'))

    $links = Get-PSManagerHelpLinks
    Write-Host ''
    Write-Host (Format-ColorText ($Script:THEME.Cyan + $Script:THEME.Bold) ('  ' + (Get-I18nText 'help_links_title' $lang)))
    foreach ($pair in @(
        @{ LabelKey = 'help_link_repo';     Url = $links.Repository },
        @{ LabelKey = 'help_link_releases'; Url = $links.Releases },
        @{ LabelKey = 'help_link_issues';   Url = $links.Issues },
        @{ LabelKey = 'help_link_docs';     Url = $links.Docs },
        @{ LabelKey = 'help_link_license';  Url = $links.License }
    )) {
        $label = ((Get-I18nText $pair.LabelKey $lang) + ':').PadRight(20)
        Write-Host ('    ' + (Format-ColorText $Script:THEME.Gray $label) + (Format-ColorText $Script:THEME.Cyan $pair.Url))
    }

    if ($updateHint) {
        Write-Host ''
        Write-Host (Format-ColorText $Script:THEME.Gray ('  ' + $updateHint))
    }
    Write-Host ''
    return $true
}

# Exported public API
Export-ModuleMember -Function @(
    'Initialize-ConsoleEncoding',
    'Get-PSManagerConfig',
    'Set-PSManagerConfig',
    'Get-EffectiveLanguage',
    'Get-I18nText',
    'Test-PSManagerPassphrase',
    'Get-PSManagerActions',
    'Invoke-PSManagerAction',
    'Stop-PSManagerAction',
    'Get-WTSettingsPath',
    'Get-PSInstallations',
    'Get-PSManagerStatus',
    'Set-PowerShell7Default',
    'Set-PowerShell5Default',
    'Install-PSManagerProfileAliases',
    'Get-SourcePackageTarget',
    'Show-SourceMenu',
    'Invoke-PowerShellUpdate',
    'Invoke-PowerShellInstall',
    'Start-QuickShell',
    'Start-DesktopGUI',
    'Show-DiagnosticsScreen',
    'Show-TUI',
    'Show-PSManagerHelp',
    'Get-PSManagerTheme',
    'Set-PSManagerTheme',
    'Disable-PSManagerColor',
    'Format-ColorText',
    'Format-ColorBadge',
    'Test-CliUnicode',
    'Get-CliGlyph',
    'Get-CliTextWidth',
    'Write-CliRule',
    'Write-CliHeading',
    'Write-CliSuccess',
    'Write-CliWarning',
    'Write-CliError',
    'Write-CliInfo',
    'Write-CliKeyValueTable',
    'Write-CliStatusTable',
    'Write-PSManagerLog',
    'Get-PSManagerLogs',
    'Clear-PSManagerLogs',
    'Resolve-NormalizedPath',
    'New-SafeLink',
    'Test-FileIdentical',
    'Read-SyncManifest',
    'Test-SyncManifest',
    'Get-DefaultManifestTemplate',
    'Install-WingetBatch',
    'Install-ScoopBatch',
    'Install-PSGalleryBatch',
    'Initialize-ScoopEnvironment',
    'Backup-PSManagerProfiles',
    'Get-PSManagerBackups',
    'Remove-PSManagerBackup',
    'Restore-PSManagerBackup',
    'Protect-PSManagerBackup',
    'Unprotect-PSManagerBackup',
    'Publish-PSManagerCloudBackup',
    'Set-PSManagerCloudRepo',
    'Import-PSManagerProfiles',
    'Invoke-PSManagerSync',
    'Invoke-PSManagerDoctor',
    'Test-PSManagerProfile',
    'Repair-PSManagerProfile',
    'Get-PSManagerVersion',
    'Get-PSManagerHelpSections',
    'Get-PSManagerHelpEntry',
    'Get-PSManagerHelpLinks',
    'Add-PSManagerNotification',
    'Get-PSManagerNotifications',
    'Get-PSManagerNotificationView',
    'Set-PSManagerNotificationRead',
    'Clear-PSManagerNotifications',
    'Show-PSManagerToast',
    'ConvertTo-PSManagerReleaseStatus',
    'Get-PSManagerUpdateStatus',
    'Get-PSManagerUpdateStatusText',
    'Add-PSManagerUpdateNotification',
    'Save-PSManagerUpdatePackage',
    'Install-PSManagerUpdate'
) -Alias @(
    'Color-Text',
    'Color-Badge',
    'Adopt-PSManagerProfiles'
)
