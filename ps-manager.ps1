#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager - Executable Harness (CLI & TUI)
.DESCRIPTION
    Thin entry point harness that imports PSManager module and executes subcommands or interactive TUI.
#>

[CmdletBinding()]
param(
    [ValidateSet('tui', 'gui', 'status', 'set-default', 'set-default-ps7', 'set-default-ps5', 'switch', 'switch-ps7', 'switch-ps5', 'update', 'install', 'diagnostics', 'source', 'set-source', 'set-channel', 'set-lang', 'sync-sources', 'sync', 'doctor', 'adopt', 'backup', 'backup-cloud', 'set-cloud-repo', 'clean-backups', 'restore', 'logs', 'edit-profile', 'edit', 'audit-profile', 'update-check', 'update-app', 'notifications', 'help', '--help', '-h')]
    [string]$Action = 'tui',
    [string]$Value = $null,
    [string]$Url = $null,
    [string]$Manifest = $null,
    [switch]$DryRun,
    [switch]$SkipPackages,
    [switch]$Fix,
    [Alias('Resolve')]
    [switch]$AutoResolve,
    [switch]$NoColor,
    [switch]$Force,
    [int]$Tail = 0,
    [switch]$Errors
)

$manifestPath = Join-Path -Path $PSScriptRoot -ChildPath 'PSManager.psd1'
if (Test-Path $manifestPath) {
    Import-Module $manifestPath -Force
} else {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'PSManager.psm1') -Force
}

if ($NoColor) {
    Disable-PSManagerColor
}
$Script:THEME = Get-PSManagerTheme

function Test-PassphraseMatch {
    # Thin wrapper over the module helper so the CLI harness and the TUI share one
    # implementation (the module version zero-frees both BSTRs).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][Security.SecureString]$First,
        [Parameter(Mandatory = $true)][Security.SecureString]$Second
    )

    return (Test-PSManagerPassphrase -First $First -Second $Second)
}

function Read-ConfirmedPassphrase {
    # Prompts twice for a passphrase; returns a SecureString, or $null on
    # mismatch (caller decides how to surface the failure).
    [CmdletBinding()]
    [OutputType([Security.SecureString])]
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$ConfirmPrompt
    )

    $p1 = Read-Host -Prompt $Prompt -AsSecureString
    $p2 = Read-Host -Prompt $ConfirmPrompt -AsSecureString
    if (-not (Test-PassphraseMatch -First $p1 -Second $p2)) {
        Write-Host (Color-Text $Script:THEME.Red "[FAIL] Passphrases do not match.")
        return $null
    }
    return $p1
}

switch ($Action) {
    'status'           {
        $s = Get-PSManagerStatus
        Write-CliHeading 'PSManager status'
        $shellValue = 'Custom'
        $shellColor = $Script:THEME.Gray
        if ($s.OverallPS7Default) { $shellValue = 'PowerShell 7'; $shellColor = $Script:THEME.Green }
        elseif ($s.WTDefaultIsPS5) { $shellValue = 'Windows PowerShell 5.1'; $shellColor = $Script:THEME.Yellow }
        $installed = @()
        if ($s.Installations) { $installed = @($s.Installations.Keys) }
        $rows = @(
            @{ Section = 'Shell & host' }
            @{ Label = 'Default shell'; Value = $shellValue; Color = $shellColor }
            @{ Label = 'Terminal host'; Value = $(if ($s.IsWTDefaultHost) { 'Windows Terminal' } else { 'Legacy console' }); Color = $(if ($s.IsWTDefaultHost) { $Script:THEME.Green } else { $Script:THEME.Yellow }) }
            @{ Label = 'Command shim'; Value = $(if ($s.ShimActive) { 'active (pwsh)' } else { 'inactive' }); Color = $(if ($s.ShimActive) { $Script:THEME.Green } else { $Script:THEME.Yellow }) }
            @{ Label = 'VS Code default'; Value = $(if ($s.VSCodeDefaultPS7) { 'PowerShell 7' } else { 'not set' }); Color = $(if ($s.VSCodeDefaultPS7) { $Script:THEME.Green } else { $Script:THEME.Gray }) }
            @{ Label = 'Context menu'; Value = $(if ($s.ContextMenuInstalled) { 'installed' } else { 'missing' }); Color = $(if ($s.ContextMenuInstalled) { $Script:THEME.Green } else { $Script:THEME.Yellow }) }
            @{ Section = 'Runtime' }
            @{ Label = 'This host'; Value = ("{0} ({1})" -f $s.CurrentHostVersion, $s.CurrentHostEdition); Color = $Script:THEME.White }
            @{ Label = 'Installed'; Value = ($installed -join ', '); Color = $Script:THEME.White }
            @{ Section = 'Updates' }
            @{ Label = 'Source'; Value = ("{0} {1} {2}" -f $s.UpdateSource, (Get-CliGlyph -Kind Bullet), $s.Channel); Color = $Script:THEME.Cyan }
            @{ Label = 'Target'; Value = ("{0} ({1})" -f $s.TargetPackage.PackageId, $s.TargetPackage.SourceName); Color = $Script:THEME.White }
        )
        Write-CliKeyValueTable -Rows $rows -LabelWidth 18
        Write-CliInfo "Run 'psmgr diagnostics' for the side-by-side version table."
        break
    }
    'gui'              { Start-DesktopGUI; break }
    'set-default'      {
        if ($Value -match 'ps5|5') { Set-PowerShell5Default } else { Set-PowerShell7Default }
        break
    }
    'set-default-ps7'  { Set-PowerShell7Default; break }
    'set-default-ps5'  { Set-PowerShell5Default; break }
    'switch'           {
        if ($Value -match 'ps5-admin') { Start-QuickShell -Target 'PS5-Admin' }
        elseif ($Value -match 'ps5|5') { Start-QuickShell -Target 'PS5' }
        elseif ($Value -match 'admin') { Start-QuickShell -Target 'PS7-Admin' }
        elseif ($Value -match 'split') { Start-QuickShell -Target 'Split' }
        else { Start-QuickShell -Target 'PS7' }
        break
    }
    'switch-ps7'       { Start-QuickShell -Target 'PS7'; break }
    'switch-ps5'       { Start-QuickShell -Target 'PS5'; break }
    'update'           { Invoke-PowerShellUpdate; break }
    'install'          { Invoke-PowerShellInstall; break }
    'diagnostics'      { Show-DiagnosticsScreen; break }
    'source'           {
        $target = Get-SourcePackageTarget
        Write-CliHeading 'Update source'
        Write-CliKeyValueTable -Rows @(
            @{ Label = 'Source'; Value = [string]$target.Source; Color = $Script:THEME.Cyan }
            @{ Label = 'Channel'; Value = [string]$target.Channel; Color = $Script:THEME.Cyan }
            @{ Label = 'Catalog'; Value = [string]$target.SourceName; Color = $Script:THEME.White }
            @{ Label = 'Package id'; Value = [string]$target.PackageId; Color = $Script:THEME.White }
            @{ Label = 'Display name'; Value = [string]$target.DisplayName; Color = $Script:THEME.White }
        ) -LabelWidth 14
        Write-CliInfo "Change it with 'psmgr set-source <winget|msstore|github>' and 'psmgr set-channel <stable|preview|lts>'."
        break
    }
    'set-source'       {
        if (-not $Value) { Write-CliError 'Missing source value.' 'Pass one of: winget | msstore | github'; break }
        $res = Set-PSManagerConfig -Source $Value
        Write-CliSuccess ("Update source set to: " + $res.updateSource)
        break
    }
    'set-channel'      {
        if (-not $Value) { Write-CliError 'Missing channel value.' 'Pass one of: stable | preview | lts'; break }
        $res = Set-PSManagerConfig -Channel $Value
        Write-CliSuccess ("Release channel set to: " + $res.channel)
        break
    }
    'set-lang'         {
        if (-not $Value) { Write-CliError 'Missing language value.' 'Pass one of: en | vi | vi-ascii'; break }
        $res = Set-PSManagerConfig -Language $Value
        Write-CliSuccess ("Language set to: " + $res.language)
        break
    }
    'set-cloud-repo'   {
        try {
            $res = Set-PSManagerCloudRepo -Repo ([string]$Value)
        } catch {
            Write-CliError $_.Exception.Message 'Pass psmgr set-cloud-repo owner/repo (empty value clears it).'
            exit 1
        }
        if ($res.cloudRepo) {
            Write-CliSuccess ("Cloud backup repository set to: " + $res.cloudRepo)
        } else {
            Write-CliSuccess 'Cloud backup repository cleared (auto-resolves from PSMGR_CLOUD_REPO, config.json, git remote or gh).'
        }
        break
    }
    'sync-sources'     {
        Write-CliHeading 'Refresh winget sources'
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-CliError 'winget was not found on this system.' "Install App Installer from the Microsoft Store, then rerun 'psmgr sync-sources'."
            exit 1
        }
        winget source update
        if ($LASTEXITCODE -ne 0) {
            Write-CliError "winget source update failed (exit $LASTEXITCODE)." 'Check the winget output above, then retry.'
            exit $LASTEXITCODE
        }
        Write-CliSuccess 'Winget sources refreshed.'
        break
    }
    'sync'             {
        Write-CliHeading $(if ($DryRun) { 'Profile sync (dry run)' } else { 'Profile sync' })
        $res = Invoke-PSManagerSync -ManifestPath $Manifest -SkipPackages:$SkipPackages -DryRun:$DryRun
        if ($res.Success) {
            Write-CliSuccess ([string]$res.Message)
        } else {
            Write-CliWarning ([string]$res.Message)
            exit 1
        }
        break
    }
    'doctor'           {
        $doFix = ($Fix.IsPresent -or $AutoResolve.IsPresent -or ($Value -match 'fix|resolve|--fix|--resolve'))
        Write-CliHeading $(if ($doFix) { 'Environment doctor (repair mode)' } else { 'Environment doctor' })
        $report = @(Invoke-PSManagerDoctor -ManifestPath $Manifest -Fix:$doFix)
        Write-CliStatusTable -Rows $report -ShowRecommendation

        $issues = @($report | Where-Object { $_.Status -in 'WARN', 'FAIL' })
        Write-Host ''
        if ($issues.Count -gt 0) {
            if ($doFix) {
                Write-CliWarning ("$($issues.Count) item(s) still need attention.")
            } else {
                Write-CliWarning ("$($issues.Count) item(s) need attention.")
                Write-CliInfo "Repair them with 'psmgr doctor -Fix'."
            }
        } else {
            Write-CliSuccess 'Environment is healthy.'
        }
        break
    }
    'audit-profile'    {
        $doFix = ($Fix.IsPresent -or $AutoResolve.IsPresent -or ($Value -match 'fix|resolve|--fix|--resolve'))
        Write-CliHeading $(if ($doFix) { 'Profile audit and repair' } else { 'Profile audit' })
        if ($doFix) {
            $repairs = @(Repair-PSManagerProfile)
            Write-CliStatusTable -Rows $repairs
        }
        $report = @(Test-PSManagerProfile)
        Write-CliStatusTable -Rows $report -ShowRecommendation

        $issues = @($report | Where-Object { $_.Status -in 'WARN', 'FAIL' })
        Write-Host ''
        if ($issues.Count -gt 0) {
            Write-CliWarning ("$($issues.Count) finding(s) remain.")
            if (-not $doFix) { Write-CliInfo "Repair them with 'psmgr audit-profile -Fix'." }
        } else {
            Write-CliSuccess 'Profiles are compatible with PowerShell 5.1 and 7.'
        }
        if ($issues.Count -gt 0 -and -not $doFix) { exit 1 }
        break
    }
    'clean-backups'    {
        $backups = @(Get-PSManagerBackups)
        if ($backups.Count -eq 0) {
            Write-Host (Color-Text $Script:THEME.Gray "No local profile backups found to delete.")
            break
        }

        $selector = "$Value".Trim()
        $selected = @()
        if (-not $selector -or $selector -match '^(?i)all$') {
            $selected = @($backups)
        } else {
            $wanted = @($selector -split '[,;\s]+' | Where-Object { $_ })
            $ambiguous = $false
            $missing = $false
            foreach ($w in $wanted) {
                $exact = @($backups | Where-Object { $_.Name -eq $w })
                if ($exact.Count -eq 1) {
                    $selected += $exact[0]
                    continue
                }

                # No exact match: accept a partial token only when it identifies
                # exactly one archive, otherwise refuse so -Force cannot silently
                # delete a different backup than the caller intended.
                $partial = @($backups | Where-Object { $_.Name -like "*$w*" })
                if ($partial.Count -eq 1) {
                    $selected += $partial[0]
                } elseif ($partial.Count -eq 0) {
                    Write-Host (Color-Text $Script:THEME.Red ("  not found: " + $w))
                    $missing = $true
                } else {
                    Write-Host (Color-Text $Script:THEME.Red ("  ambiguous '" + $w + "' matches " + $partial.Count + " backups:"))
                    foreach ($p in $partial) { Write-Host (Color-Text $Script:THEME.Gray ("     - " + $p.Name)) }
                    $ambiguous = $true
                }
            }
            if ($ambiguous) {
                Write-Host (Color-Text $Script:THEME.Red "Aborting: pass exact backup file names.")
                exit 1
            }
            if ($missing) {
                Write-Host (Color-Text $Script:THEME.Red "Aborting: one or more names did not match any backup.")
                exit 1
            }
            if ($selected.Count -eq 0) {
                Write-Host (Color-Text $Script:THEME.Red "No backups selected. Pass 'all' or one/more explicit backup names.")
                exit 1
            }
        }
        Write-Host ""
        Write-Host (Color-Text ($Script:THEME.Red + $Script:THEME.Bold) "!! WARNING: DESTRUCTIVE OPERATION - DELETION IS PERMANENT !!")
        Write-Host (Color-Text $Script:THEME.Yellow "The following $($selected.Count) backup archive(s) will be permanently deleted:")
        foreach ($b in $selected) {
            Write-Host (Color-Text $Script:THEME.Gray ("   - " + $b.Name + "  (" + $b.SizeKB + " KB, " + $b.CreationTime.ToString("yyyy-MM-dd HH:mm") + ")"))
        }
        Write-Host ""

        $proceed = $Force
        if (-not $proceed) {
            if ([Console]::IsInputRedirected) {
                Write-Host (Color-Text $Script:THEME.Red "Refusing to delete in a non-interactive session without -Force.")
                exit 1
            }
            $answer = Read-Host "Type DELETE to confirm permanent removal, or press Enter to abort"
            $proceed = ($answer -eq 'DELETE')
        }

        if (-not $proceed) {
            Write-Host (Color-Text $Script:THEME.Gray "Aborted. No backups were deleted.")
            break
        }

        $res = Remove-PSManagerBackup -Name @($selected | ForEach-Object { $_.Name }) -Force -Confirm:$false
        Write-CliSuccess ("Deleted " + $res.Deleted + " backup(s), freed " + $res.FreedKB + " KB.")
        foreach ($e in $res.Errors) { Write-CliWarning ([string]$e) }
        if ($res.Skipped -gt 0) { Write-CliInfo ("skipped: " + $res.Skipped) }
        break
    }
    'backup'           {
        Write-CliHeading 'Create profile backup'
        $secPass = $null
        $useDP = $false
        if ($Value -match 'dpapi') {
            $useDP = $true
        } elseif ($Value -match 'encrypt|enc') {
            try {
                if (-not [Console]::IsInputRedirected) {
                    $secPass = Read-ConfirmedPassphrase -Prompt "Enter backup encryption passphrase" -ConfirmPrompt "Confirm passphrase"
                    if (-not $secPass) { break }
                }
            } catch {}
        }
        $zip = Backup-PSManagerProfiles -Passphrase $secPass -UseDPAPI:$useDP
        Write-CliSuccess ("Profiles backed up to: " + $zip)
        break
    }
    'backup-cloud'     {
        Write-CliHeading 'Publish backup to GitHub'
        $secPass = $null
        try {
            if (-not [Console]::IsInputRedirected -and -not ($Value -match 'plain|no-enc')) {
                $choice = Read-Host "Encrypt cloud backup with passphrase? (recommended) [Y/n]"
                if ($choice -notmatch '^[Nn]') {
                    $secPass = Read-ConfirmedPassphrase -Prompt "Enter passphrase" -ConfirmPrompt "Confirm passphrase"
                    if (-not $secPass) { break }
                }
            }
        } catch {}
        # Credential precedence lives in the engine: -Token, then PSMGR_CLOUD_TOKEN, then the
        # gh CLI credential (GH_TOKEN / GITHUB_TOKEN / 'gh auth login').
        try {
            $res = Publish-PSManagerCloudBackup -Passphrase $secPass
        } catch {
            Write-CliError $_.Exception.Message "Fix the credential or target repo, then rerun 'psmgr backup-cloud'."
            exit 1
        }
        Write-CliSuccess ("Uploaded to GitHub Release: " + $res.Tag)
        Write-CliInfo ([string]$res.Url)
        break
    }
    'restore'          {
        if (-not $Value) {
            $recent = Get-PSManagerBackups | Select-Object -First 1
            if (-not $recent) {
                Write-CliError 'No profile backups found to restore.' "Create one first with 'psmgr backup'."
                break
            }
            $targetZip = $recent.FullName
        } else {
            $targetZip = $Value
        }
        Write-CliHeading 'Restore profiles'
        Write-CliInfo ("Source: " + $targetZip)
        $ok = Restore-PSManagerBackup -BackupZipPath $targetZip
        if ($ok) {
            Write-CliSuccess 'Backup restored successfully.'
        } else {
            Write-CliError 'Restore failed.' 'Check the archive path and, for encrypted backups, the passphrase.'
        }
        break
    }
    'logs'             {
        $clear = ($Value -match 'clear|clean')
        if ($clear) {
            $deleted = Clear-PSManagerLogs -RetentionDays 0
            Write-CliSuccess ("Cleared " + $deleted + " diagnostic log file(s).")
        } else {
            $tailCount = if ($Tail -gt 0) { $Tail } elseif ($Value -and [int]::TryParse($Value, [ref]$null)) { [int]$Value } else { 50 }
            $errOnly = ($Errors.IsPresent -or $Fix.IsPresent -or ($Value -match 'err|warn'))
            Write-CliHeading ("Diagnostic logs (last " + $tailCount + ")")
            $entries = Get-PSManagerLogs -Tail $tailCount -ErrorsOnly:$errOnly
            if (-not $entries -or $entries.Count -eq 0) {
                Write-CliInfo 'No log entries found.'
            } else {
                foreach ($entry in $entries) {
                    if ($entry -match '\[ERROR\]') {
                        Write-Host (Color-Text $Script:THEME.Red $entry)
                    } elseif ($entry -match '\[WARN\]') {
                        Write-Host (Color-Text $Script:THEME.Yellow $entry)
                    } else {
                        Write-Host $entry
                    }
                }
            }
        }
        break
    }
    'adopt'            {
        Write-CliHeading 'Adopt live profiles'
        $res = Adopt-PSManagerProfiles
        foreach ($d in $res.Details) {
            Write-CliInfo ([string]$d)
        }
        if ($res.Success) {
            Write-CliSuccess ([string]$res.Message)
        } else {
            Write-CliError ([string]$res.Message)
        }
        break
    }
    'edit-profile'     {
        $target = if ($Value -match '5') {
            "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
        } else {
            "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
        }
        $editor = if (Get-Command code -ErrorAction SilentlyContinue) { "code" } else { "notepad.exe" }
        Write-CliHeading ("Open profile in " + $editor)
        Write-CliInfo ([string]$target)
        Start-Process $editor -ArgumentList "`"$target`""
        break
    }
    'edit'             {
        $target = "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
        $editor = if (Get-Command code -ErrorAction SilentlyContinue) { "code" } else { "notepad.exe" }
        Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "==> Opening profile in $($editor): $target")
        Start-Process $editor -ArgumentList "`"$target`""
        break
    }
    'update-check'     {
        $lang = Get-EffectiveLanguage
        Write-CliHeading (Get-I18nText 'update_check_title' $lang)
        $st = Get-PSManagerUpdateStatus -Force
        $statusText = Get-PSManagerUpdateStatusText -Status $st -Language $lang
        $statusColor = if ($st.UpdateAvailable) { $Script:THEME.Green } elseif ($st.Status -eq 'Error') { $Script:THEME.Red } else { $Script:THEME.Gray }
        $latestText = if ($st.LatestVersion) { [string]$st.LatestVersion } else { '-' }
        $releaseText = if ($st.ReleaseUrl) { [string]$st.ReleaseUrl } else { '-' }
        Write-CliKeyValueTable -Rows @(
            @{ Label = (Get-I18nText 'update_current' $lang); Value = [string]$st.CurrentVersion; Color = $Script:THEME.White }
            @{ Label = (Get-I18nText 'update_latest' $lang); Value = $latestText; Color = $Script:THEME.White }
            @{ Label = (Get-I18nText 'update_status' $lang); Value = $statusText; Color = $statusColor }
            @{ Label = (Get-I18nText 'update_release' $lang); Value = $releaseText; Color = $Script:THEME.Cyan }
            @{ Label = (Get-I18nText 'update_checked' $lang); Value = $(if ($st.CheckedAt) { ([datetime]$st.CheckedAt).ToString('yyyy-MM-dd HH:mm') } else { '-' }); Color = $Script:THEME.Gray }
        )

        if ($st.UpdateAvailable -and -not $st.Error) {
            $null = Add-PSManagerUpdateNotification -Status $st -Force
            $notice = (Get-I18nText 'update_available_hint' $lang) -f $st.LatestVersion
            Write-CliInfo $notice
        } elseif ($st.Status -eq 'Error' -or $st.Error) {
            Write-CliInfo ((Get-I18nText 'update_error_hint' $lang) -f $st.Error)
        } elseif ($st.Status -eq 'Current') {
            Write-CliSuccess (Get-I18nText 'update_none_hint' $lang)
        } elseif ($st.Status -eq 'Disabled') {
            Write-CliInfo (Get-I18nText 'update_status_disabled' $lang)
        } else {
            Write-CliInfo (Get-I18nText 'help_update_not_checked' $lang)
        }

        if ($st.Status -eq 'Error' -or $st.Error) { exit 1 }
        break
    }
    'update-app'       {
        $lang = Get-EffectiveLanguage
        Write-CliHeading (Get-I18nText 'menu_update_app' $lang)
        $st = Get-PSManagerUpdateStatus -Force
        if ($st.Status -eq 'Error' -or $st.Error) {
            Write-CliError ((Get-I18nText 'update_error_hint' $lang) -f $st.Error)
            exit 1
        }
        if ($st.Status -eq 'Disabled') {
            Write-CliInfo (Get-I18nText 'update_status_disabled' $lang)
            break
        }
        if (-not $st.UpdateAvailable) {
            Write-CliSuccess (Get-I18nText 'update_none_hint' $lang)
            break
        }
        if (-not $Force) {
            $answer = Read-Host ((Get-I18nText 'update_confirm_install' $lang) -f $st.LatestVersion)
            if ($answer -notmatch '^[Yy]') {
                Write-CliInfo (Get-I18nText 'tui_msg_cancelled' $lang)
                break
            }
        }
        try {
            $res = Install-PSManagerUpdate -Status $st
            if ($res.Success) {
                if ($res.RestartRequired) { Write-CliWarning (Get-I18nText 'notif_update_restart' $lang) }
                else { Write-CliSuccess (Get-I18nText 'notif_update_installed' $lang) }
            } else {
                Write-CliError ((Get-I18nText 'notif_update_failed' $lang) -f $res.Error)
                exit 1
            }
        } catch {
            Write-CliError ((Get-I18nText 'notif_update_failed' $lang) -f $_.Exception.Message)
            exit 1
        }
        break
    }
    'notifications'    {
        $lang = Get-EffectiveLanguage
        Write-CliHeading (Get-I18nText 'notif_center_title' $lang)
        if ($Value -match '^(?i)clear$') {
            $cleared = Clear-PSManagerNotifications
            if ($cleared -lt 0) {
                Write-CliError (Get-I18nText 'gui_err_failed' $lang)
                exit 1
            }
            Write-CliSuccess (Get-I18nText 'notif_center_clear' $lang)
            break
        }
        if ($Value -match '^(?i)read$') {
            $readCount = Set-PSManagerNotificationRead -All
            if ($readCount -lt 0) {
                Write-CliError (Get-I18nText 'gui_err_failed' $lang)
                exit 1
            }
            Write-CliSuccess (Get-I18nText 'notif_center_read' $lang)
            break
        }
        $limit = 10
        if ($Value -match '^(?i)all$') { $limit = 50 }
        $view = @(Get-PSManagerNotificationView -Language $lang -Limit $limit)
        if ($view.Count -eq 0) {
            Write-CliInfo (Get-I18nText 'notif_center_empty' $lang)
            break
        }
        $rows = @()
        foreach ($item in $view) {
            $marker = if ($item.Read) { ' ' } else { '!' }
            $rows += @{
                Label = ($marker + ' ' + $item.Time)
                Value = ($item.Title + ' - ' + $item.Message)
                Color = if ($item.Read) { $Script:THEME.Gray } else { $Script:THEME.White }
            }
        }
        Write-CliKeyValueTable -Rows $rows -LabelWidth 19
        $unread = @($view | Where-Object { -not $_.Read }).Count
        if ($unread -gt 0) { Write-CliInfo ((Get-I18nText 'notif_center_unread' $lang) -f $unread) }
        break
    }
    'help'             {
        if (-not (Show-PSManagerHelp -Command $Value)) { exit 1 }
        break
    }
    '--help'           {
        if (-not (Show-PSManagerHelp -Command $Value)) { exit 1 }
        break
    }
    '-h'               {
        if (-not (Show-PSManagerHelp -Command $Value)) { exit 1 }
        break
    }
    default            { Show-TUI; break }
}
