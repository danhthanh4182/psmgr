#
# Module manifest for module 'PSManager'
# Generated on: 2025-05-01
#

@{
    RootModule = 'PSManager.psm1'
    ModuleVersion = '1.8.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID = 'a7b8e1f2-9c3d-4e5f-a6b7-8c9d0e1f2a3b'
    Author = 'Thanh'
    CompanyName = 'Personal'
    Copyright = '(c) 2025. All rights reserved.'
    Description = 'PowerShell Version Manager: TUI, CLI & WPF Desktop Control Center for Windows.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
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
    )

    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('Color-Text', 'Color-Badge', 'Adopt-PSManagerProfiles')

    PrivateData = @{
        PSData = @{
            Tags = @('PowerShell', 'pwsh', 'VersionManager', 'TUI', 'WPF', 'WindowsTerminal', 'Winget')
            ProjectUri = 'https://github.com/danhthanh4182/psmgr'
        }
    }
}
