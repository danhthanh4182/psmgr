#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager UI - Interactive Terminal User Interface (TUI) Engine
.DESCRIPTION
    Drives the alternate-screen TUI: renders frames produced by the pure renderer
    (modules/UI/TuiRender.ps1), reduces keys through the pure state machine
    (modules/UI/TuiState.ps1), and runs actions on the normal screen so their output
    stays in the scrollback. Always restores cursor, colours and the main screen.
    Also provides a plain (accessibility) mode and a non-TTY guard.
#>

$Script:TUI_ESC = [char]27

function Get-TuiTerminalWriter {
    # Single indirection so tests can capture the terminal sequence stream.
    param([scriptblock]$Writer)
    if ($Writer) { return $Writer }
    return { param([string]$Chunk) [Console]::Write($Chunk) }
}

function Read-TuiInput {
    <#
    .SYNOPSIS
        Single prompt indirection (tests substitute this, not the built-in cmdlet).
    #>
    [CmdletBinding()]
    param(
        [string]$Prompt = "",
        [switch]$AsSecureString
    )
    if ($AsSecureString) { return Read-Host -Prompt $Prompt -AsSecureString }
    return Read-Host -Prompt $Prompt
}

function Invoke-TuiScreen {
    <#
    .SYNOPSIS
        Runs a body inside the alternate screen and guarantees restoration on any exit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Body,
        [scriptblock]$Writer = $null
    )

    $w = Get-TuiTerminalWriter -Writer $Writer
    $esc = $Script:TUI_ESC
    try {
        & $w "$esc[?1049h"
        & $w "$esc[?25l"
        & $w "$esc[2J"
        & $Body
    } finally {
        & $w "$esc[0m"
        & $w "$esc[?25h"
        & $w "$esc[?1049l"
    }
}

function Convert-TuiKeyToString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][ConsoleKeyInfo]$KeyInfo)

    switch ($KeyInfo.Key) {
        'UpArrow'    { return 'Up' }
        'DownArrow'  { return 'Down' }
        'LeftArrow'  { return 'Left' }
        'RightArrow' { return 'Right' }
        'Home'       { return 'Home' }
        'End'        { return 'End' }
        'PageUp'     { return 'PgUp' }
        'PageDown'   { return 'PgDn' }
        'Enter'      { return 'Enter' }
        'Escape'     { return 'Esc' }
        'Backspace'  { return 'Backspace' }
        'Tab' {
            if ($KeyInfo.Modifiers -band [ConsoleModifiers]::Shift) { return 'ShiftTab' }
            return 'Tab'
        }
        default {
            if ($KeyInfo.KeyChar -eq [char]0) { return '' }
            return [string]$KeyInfo.KeyChar
        }
    }
}

function Get-TuiStatusSummary {
    <#
    .SYNOPSIS
        Localised status items used by the plain-mode header.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([object]$Status, [object]$Config, [string]$Language)

    $shell = Get-I18nText 'tui_status_custom' $Language
    if ($Status.WTDefaultIsPS7) { $shell = 'PowerShell 7' }
    elseif ($Status.WTDefaultIsPS5) { $shell = 'PowerShell 5.1' }

    $hostApp = if ($Status.IsWTDefaultHost) { 'Windows Terminal' } else { Get-I18nText 'tui_status_conhost' $Language }
    $shim = if ($Status.ShimActive) { Get-I18nText 'tui_status_shim_on' $Language } else { Get-I18nText 'tui_status_shim_off' $Language }
    $source = "$($Config.updateSource) - $($Config.channel)"

    return @(
        ("{0}: {1}" -f (Get-I18nText 'tui_status_shell' $Language), $shell),
        ("{0}: {1}" -f (Get-I18nText 'tui_status_host' $Language), $hostApp),
        ("{0}: {1}" -f (Get-I18nText 'tui_status_shim' $Language), $shim),
        ("{0}: {1}" -f (Get-I18nText 'tui_status_source' $Language), $source)
    )
}

function Update-TuiNotificationState {
    <#
    .SYNOPSIS
        Reloads the localized notification view and the unread counter into the state.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [int]$Limit = 20
    )

    try {
        $notes = @(Get-PSManagerNotifications -Limit $Limit)
        $State.Notifications = @(Get-PSManagerNotificationView -Language $State.Language -Limit $Limit)
        $State.UnreadCount = @($notes | Where-Object { -not $_.Read }).Count
    } catch {
        $State.Notifications = @()
        $State.UnreadCount = 0
    }
    $count = @($State.Notifications).Count
    if ($count -eq 0) {
        $State.NotificationIndex = 0
    } elseif ([int]$State.NotificationIndex -ge $count) {
        $State.NotificationIndex = $count - 1
    }
    return $State
}

function Get-TuiCatalogItem {
    <#
    .SYNOPSIS
        Finds one catalog entry by id (used for synthetic result screens).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][object[]]$Catalog,
        [Parameter(Mandatory = $true)][string]$Id
    )

    foreach ($entry in $Catalog) {
        if ($entry.Id -eq $Id) { return $entry }
    }
    return $null
}

function Invoke-TuiActionById {
    <#
    .SYNOPSIS
        Executes one catalog action on the normal screen and reports its outcome.
    .DESCRIPTION
        Returns @{ Ok = [bool]; Errors = [string[]] }. Prompts (passphrases, backup
        selection, typed DELETE) stay interactive; tests never call this function.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Language = 'en'
    )

    $result = @{ Ok = $true; Errors = @() }
    $t = { param([string]$k) Get-I18nText $k $Language }

    switch ($Id) {
        'def7' {
            try { $null = Set-PowerShell7Default } catch { $result.Ok = $false; $result.Errors = @($_.Exception.Message) }
        }
        'def5' {
            try { $null = Set-PowerShell5Default } catch { $result.Ok = $false; $result.Errors = @($_.Exception.Message) }
        }
        'source' {
            Show-SourceMenu
        }
        'update' {
            try { Invoke-PowerShellUpdate } catch { $result.Ok = $false; $result.Errors = @($_.Exception.Message) }
        }
        'install' {
            try { Invoke-PowerShellInstall } catch { $result.Ok = $false; $result.Errors = @($_.Exception.Message) }
        }
        'sync' {
            Write-Host (& $t 'tui_hdr_sync')
            $syncRes = Invoke-PSManagerSync
            $result.Ok = [bool]$syncRes.Success
            if ($syncRes.Message) { $result.Errors = @($syncRes.Message) }
        }
        'doctor' {
            Write-Host (& $t 'tui_hdr_doctor')
            $docRes = Invoke-PSManagerDoctor
            $docRes | Format-Table -Property Category, Item, Status, Details, Recommendation -AutoSize
            $warns = @($docRes | Where-Object { $_.Status -in 'WARN', 'FAIL' })
            if ($warns.Count -gt 0) {
                Write-Host ((& $t 'tui_msg_doctor_issues') -f $warns.Count)
                $choice = $null
                try { if (-not [Console]::IsInputRedirected) { $choice = [Console]::ReadKey($true) } } catch {}
                if ($choice -and $choice.Key -eq [ConsoleKey]::F) {
                    $fixedRes = Invoke-PSManagerDoctor -Fix
                    $fixedRes | Format-Table -Property Category, Item, Status, Details -AutoSize
                    $stillFailing = @($fixedRes | Where-Object { $_.Status -in 'WARN', 'FAIL' })
                    $result.Ok = ($stillFailing.Count -eq 0)
                    if (-not $result.Ok) { $result.Errors = @((& $t 'tui_msg_repair_remain') -f $stillFailing.Count) }
                } else {
                    $result.Ok = $false
                    $result.Errors = @((& $t 'tui_msg_repair_remain') -f $warns.Count)
                }
            }
        }
        'diag' {
            Show-DiagnosticsScreen
        }
        'audit-prof' {
            Write-Host (& $t 'tui_hdr_audit')
            $profChecks = Test-PSManagerProfile
            $profChecks | Format-Table -Property Category, Item, Status, Details, Recommendation -AutoSize
            $issues = @($profChecks | Where-Object { $_.Status -in 'WARN', 'FAIL' })
            if ($issues.Count -gt 0) {
                Write-Host ((& $t 'tui_msg_doctor_issues') -f $issues.Count)
                $choice = $null
                try { if (-not [Console]::IsInputRedirected) { $choice = [Console]::ReadKey($true) } } catch {}
                if ($choice -and $choice.Key -eq [ConsoleKey]::F) {
                    $repaired = Repair-PSManagerProfile
                    $repaired | Format-Table -Property Category, Item, Status, Details -AutoSize
                    Write-Host (& $t 'tui_msg_repair_ok')
                } else {
                    $result.Ok = $false
                    $result.Errors = @((& $t 'tui_msg_repair_remain') -f $issues.Count)
                }
            }
        }
        'adopt' {
            Write-Host (& $t 'tui_hdr_adopt')
            $answer = Read-TuiInput (& $t 'tui_msg_adopt_confirm')
            if ($answer -match '^[Yy]') {
                $adoptRes = Adopt-PSManagerProfiles
                foreach ($detail in $adoptRes.Details) { Write-Host (" * " + $detail) }
                $result.Ok = [bool]$adoptRes.Success
                if ($result.Ok) { Write-Host ((& $t 'tui_msg_adopted') -f $adoptRes.Message) }
                else { $result.Errors = @((& $t 'tui_msg_adopt_failed') -f $adoptRes.Message) }
            } else {
                Write-Host (& $t 'tui_msg_cancelled')
                $result.Ok = $false
            }
        }
        'backup' {
            Write-Host (& $t 'tui_hdr_backup')
            $secPass = $null
            $choice = Read-TuiInput (& $t 'tui_prompt_encrypt_backup')
            if ($choice -match '^[Yy]') {
                $p1 = Read-TuiInput -Prompt (& $t 'tui_prompt_passphrase') -AsSecureString
                $p2 = Read-TuiInput -Prompt (& $t 'tui_prompt_confirm_pass') -AsSecureString
                if (-not (Test-PSManagerPassphrase -First $p1 -Second $p2)) {
                    # Encryption was requested: never fall back to a plaintext archive.
                    Write-Host (& $t 'tui_msg_pass_mismatch')
                    $result.Ok = $false
                    $result.Errors = @(& $t 'tui_msg_pass_mismatch')
                    return $result
                }
                if ($p1.Length -eq 0) {
                    Write-Host (& $t 'tui_msg_pass_required')
                    $result.Ok = $false
                    $result.Errors = @(& $t 'tui_msg_pass_required')
                    return $result
                }
                $secPass = $p1
            }
            $zip = Backup-PSManagerProfiles -Passphrase $secPass
            if ($zip) {
                Write-Host ((& $t 'tui_msg_backup_done') -f $zip)
            } else {
                $result.Ok = $false
                $result.Errors = @(& $t 'tui_msg_backup_fail')
            }
        }
        'backup-cloud' {
            Write-Host (& $t 'tui_hdr_cloud')
            $secPass = $null
            $choice = Read-TuiInput (& $t 'tui_prompt_encrypt_cloud')
            if ($choice -notmatch '^[Nn]') {
                $p1 = Read-TuiInput -Prompt (& $t 'tui_prompt_passphrase') -AsSecureString
                $p2 = Read-TuiInput -Prompt (& $t 'tui_prompt_confirm_pass') -AsSecureString
                if (-not (Test-PSManagerPassphrase -First $p1 -Second $p2)) {
                    # Never upload a plaintext release because of a typo.
                    Write-Host (& $t 'tui_msg_pass_mismatch')
                    $result.Ok = $false
                    $result.Errors = @(& $t 'tui_msg_pass_mismatch')
                    return $result
                }
                if ($p1.Length -eq 0) {
                    Write-Host (& $t 'tui_msg_pass_required')
                    $result.Ok = $false
                    $result.Errors = @(& $t 'tui_msg_pass_required')
                    return $result
                }
                $secPass = $p1
            }
            # Optional per-run token: an empty answer keeps the gh CLI credential.
            $cloudToken = $null
            $tokenAnswer = Read-TuiInput -Prompt (& $t 'tui_prompt_cloud_token') -AsSecureString
            if ($tokenAnswer -and $tokenAnswer.Length -gt 0) { $cloudToken = $tokenAnswer }
            try {
                $cloudRes = Publish-PSManagerCloudBackup -Passphrase $secPass -Token $cloudToken
            } catch {
                Write-Host ((& $t 'tui_msg_action_failed') -f $_.Exception.Message)
                $result.Ok = $false
                $result.Errors = @($_.Exception.Message)
                break
            }
            if ($cloudRes) {
                Write-Host ((& $t 'tui_msg_cloud_done') -f $cloudRes.Tag)
                if ($cloudRes.Url) { Write-Host ((& $t 'tui_msg_cloud_url') -f $cloudRes.Url) }
            } else {
                $result.Ok = $false
            }
        }
        'set-cloud-repo' {
            Write-Host (& $t 'tui_hdr_cloud_repo')
            $cfgNow = Get-PSManagerConfig
            $currentRepo = if ($cfgNow.PSObject.Properties['cloudRepo'] -and $cfgNow.cloudRepo) { [string]$cfgNow.cloudRepo } else { '-' }
            $answer = Read-TuiInput ((& $t 'tui_prompt_cloud_repo') -f $currentRepo)
            if ($null -eq $answer) {
                Write-Host (& $t 'tui_msg_cancelled')
                $result.Ok = $false
                break
            }
            try {
                $null = Set-PSManagerCloudRepo -Repo ([string]$answer).Trim()
                $saved = (Get-PSManagerConfig).cloudRepo
                Write-Host ((& $t 'tui_msg_cloud_repo_saved') -f $(if ($saved) { [string]$saved } else { '-' }))
            } catch {
                $result.Ok = $false
                $result.Errors = @($_.Exception.Message)
            }
        }
        'restore' {
            Write-Host (& $t 'tui_hdr_restore')
            $backups = @(Get-PSManagerBackups)
            if ($backups.Count -eq 0) {
                Write-Host (& $t 'tui_msg_no_backups')
                $result.Ok = $false
            } else {
                for ($i = 0; $i -lt [Math]::Min(10, $backups.Count); $i++) {
                    $b = $backups[$i]
                    $tag = if ($b.IsEncrypted) { '[ENC]' } else { '[ZIP]' }
                    Write-Host ("  [{0}] {1} {2} ({3} KB)" -f ($i + 1), $tag, $b.Name, $b.SizeKB)
                }
                $pick = Read-TuiInput (& $t 'tui_prompt_pick_backup')
                $num = 0
                if ([int]::TryParse($pick, [ref]$num) -and $num -ge 1 -and $num -le [Math]::Min(10, $backups.Count)) {
                    $secPass = $null
                    if ($backups[$num - 1].IsEncrypted) {
                        $secPass = Read-TuiInput -Prompt (& $t 'tui_prompt_passphrase') -AsSecureString
                    }
                    $ok = Restore-PSManagerBackup -BackupZipPath $backups[$num - 1].FullName -Passphrase $secPass
                    if ($ok) { Write-Host (& $t 'tui_msg_restore_ok') }
                    else { $result.Ok = $false; $result.Errors = @(& $t 'tui_msg_restore_fail') }
                } else {
                    Write-Host (& $t 'tui_msg_cancelled')
                    $result.Ok = $false
                }
            }
        }
        'clean-backups' {
            Write-Host (& $t 'tui_hdr_clean')
            $backups = @(Get-PSManagerBackups)
            if ($backups.Count -eq 0) {
                Write-Host (& $t 'tui_msg_no_backups')
                $result.Ok = $false
            } else {
                for ($i = 0; $i -lt $backups.Count; $i++) {
                    Write-Host ("  [{0}] {1} ({2} KB)" -f ($i + 1), $backups[$i].Name, $backups[$i].SizeKB)
                }
                $answer = Read-TuiInput (& $t 'tui_prompt_pick_numbers')
                if ([string]::IsNullOrWhiteSpace($answer)) {
                    Write-Host (& $t 'tui_msg_cancelled')
                    $result.Ok = $false
                } else {
                    $picked = [System.Collections.Generic.List[object]]::new()
                    if ($answer.Trim() -match '^(?i)all$') {
                        foreach ($b in $backups) { $picked.Add($b) }
                    } else {
                        foreach ($tok in ($answer -split '[,;\s]+' | Where-Object { $_ })) {
                            if ($tok -match '^(\d+)\s*-\s*(\d+)$') {
                                $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
                                for ($n = $lo; $n -le $hi; $n++) {
                                    if ($n -ge 1 -and $n -le $backups.Count) { $picked.Add($backups[$n - 1]) }
                                }
                            } elseif ($tok -match '^\d+$') {
                                $n = [int]$tok
                                if ($n -ge 1 -and $n -le $backups.Count) { $picked.Add($backups[$n - 1]) }
                            }
                        }
                    }
                    $unique = @($picked | Sort-Object Name -Unique)
                    if ($unique.Count -eq 0) {
                        Write-Host (& $t 'tui_msg_invalid_selection')
                        $result.Ok = $false
                    } else {
                        $confirm = Read-TuiInput (& $t 'tui_prompt_delete_confirm')
                        if ($confirm -eq 'DELETE') {
                            $res = Remove-PSManagerBackup -Name @($unique | ForEach-Object { $_.Name }) -Force -Confirm:$false
                            Write-Host ((& $t 'tui_msg_deleted') -f $res.Deleted, $res.FreedKB)
                            foreach ($e in $res.Errors) { Write-Host ("  ! " + $e) }
                        } else {
                            Write-Host (& $t 'tui_msg_cancelled')
                            $result.Ok = $false
                        }
                    }
                }
            }
        }
        'logs' {
            Write-Host (& $t 'tui_hdr_logs')
            $entries = Get-PSManagerLogs -Tail 25
            if (-not $entries -or $entries.Count -eq 0) {
                Write-Host (& $t 'tui_msg_no_logs')
            } else {
                foreach ($entry in $entries) { Write-Host $entry }
            }
        }
        'sync-sources' {
            Write-Host (& $t 'tui_hdr_sources')
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                & winget source update
            } else {
                Write-Host (& $t 'tui_msg_winget_missing')
                $result.Ok = $false
            }
        }
        'prof' {
            Write-Host (& $t 'tui_hdr_edit')
            Write-Host '  1. PS7'
            Write-Host '  2. PS5.1'
            $pick = Read-TuiInput (& $t 'tui_prompt_pick_backup')
            $profilePath = $null
            if ($pick -eq '1') { $profilePath = "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1" }
            if ($pick -eq '2') { $profilePath = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1" }
            if ($profilePath) {
                $editor = if (Get-Command code -ErrorAction SilentlyContinue) { 'code' } else { 'notepad.exe' }
                Start-Process $editor -ArgumentList "`"$profilePath`""
            } else {
                $result.Ok = $false
            }
        }
        'help' {
            $null = Show-PSManagerHelp -Language $Language
        }
        'notifications' {
            $views = @(Get-PSManagerNotificationView -Language $Language -Limit 20)
            if ($views.Count -eq 0) {
                Write-Host (Get-I18nText 'notif_center_empty' $Language)
            } else {
                foreach ($note in $views) {
                    $mark = if ($note.Read) { ' ' } else { '!' }
                    Write-Host ("  [" + $mark + "] " + [string]$note.Time + "  " + [string]$note.Title)
                    Write-Host ("       " + [string]$note.Message)
                    if ($note.Url) { Write-Host ("       " + [string]$note.Url) }
                }
                $null = Set-PSManagerNotificationRead -All
            }
        }
        'update-check' {
            $st = Get-PSManagerUpdateStatus -Force
            Write-Host ((Get-I18nText 'update_current' $Language) + ': ' + [string]$st.CurrentVersion)
            Write-Host ((Get-I18nText 'update_latest' $Language) + ': ' + [string]$st.LatestVersion)
            Write-Host ((Get-I18nText 'update_status' $Language) + ': ' + (Get-PSManagerUpdateStatusText -Status $st -Language $Language))
            if ($st.ReleaseUrl) { Write-Host ((Get-I18nText 'update_release' $Language) + ': ' + [string]$st.ReleaseUrl) }
            if ($st.Error) {
                Write-Host ((Get-I18nText 'update_error_hint' $Language) -f $st.Error)
                $result.Ok = $false
                $result.Errors = @($st.Error)
            } else {
                $null = Add-PSManagerUpdateNotification -Status $st
            }
        }
        'update-app' {
            Write-Host ((Get-I18nText 'menu_update_check' $Language) + '...')
            $st = Get-PSManagerUpdateStatus -Force
            if ($st.Status -eq 'Error' -or $st.Error) {
                Write-Host ((Get-I18nText 'update_error_hint' $Language) -f $st.Error)
                $result.Ok = $false
                $result.Errors = @($st.Error)
                return $result
            }
            if ($st.Status -eq 'Disabled') {
                Write-Host (Get-I18nText 'update_status_disabled' $Language)
                return $result
            }
            if (-not $st.UpdateAvailable) {
                Write-Host (Get-I18nText 'update_none_hint' $Language)
                return $result
            }
            $answer = Read-TuiInput ((Get-I18nText 'update_confirm_install' $Language) -f $st.LatestVersion)
            if ($answer -notmatch '^[Yy]') {
                Write-Host (Get-I18nText 'tui_msg_cancelled' $Language)
                return $result
            }
            try {
                $installed = Install-PSManagerUpdate -Status $st
                if ($installed.Success) {
                    Write-Host (Get-I18nText 'notif_update_installed' $Language)
                    if ($installed.RestartRequired) { Write-Host (Get-I18nText 'notif_update_restart' $Language) }
                    $result.Stop = $true
                } else {
                    $result.Ok = $false
                    $result.Errors = @(((Get-I18nText 'notif_update_failed' $Language) -f $installed.Error))
                }
            } catch {
                $result.Ok = $false
                $result.Errors = @(((Get-I18nText 'notif_update_failed' $Language) -f $_.Exception.Message))
            }
        }
        'q_ps7'   { Start-QuickShell -Target 'PS7' }
        'q_ps7a'  { Start-QuickShell -Target 'PS7-Admin' }
        'q_split' { Start-QuickShell -Target 'Split' }
        'q_ps5'   { Start-QuickShell -Target 'PS5' }
        default {
            $result.Ok = $false
            $result.Errors = @("Unknown action: $Id")
        }
    }

    return $result
}

function Show-TuiPlain {
    <#
    .SYNOPSIS
        Linear, numbered, no-repaint mode for screen readers (PSMGR_PLAIN=1).
    #>
    [CmdletBinding()]
    param([hashtable]$Caps)

    $lang = Get-EffectiveLanguage
    $groups = Get-TuiGroups -Language $lang
    $catalog = Get-TuiCatalog -Language $lang
    $status = Get-PSManagerStatus
    $cfg = Get-PSManagerConfig

    Write-Host (Get-I18nText 'tui_plain_title' $lang)
    foreach ($line in (Get-TuiStatusSummary -Status $status -Config $cfg -Language $lang)) {
        Write-Host ("  " + $line)
    }
    Write-Host ''

    $index = 0
    $map = @{}
    foreach ($grp in $groups) {
        $grpItems = @($catalog | Where-Object { $_.GroupId -eq $grp.Id })
        if ($grpItems.Count -eq 0) { continue }
        Write-Host $grp.Title
        foreach ($it in $grpItems) {
            $index++
            $map[[string]$index] = $it.Id
            Write-Host ("  {0,2}. {1}" -f $index, $it.Title)
        }
    }

    # Global entries with a runnable action: gui/lang stay key-only shortcuts because
    # selecting them through the numbered list has no plain-mode equivalent.
    $plainGlobalIds = @('help', 'update-check', 'update-app', 'notifications')
    $globalItems = @($catalog | Where-Object { $_.GroupId -eq 'global' -and $plainGlobalIds -contains $_.Id })
    if ($globalItems.Count -gt 0) {
        Write-Host (Get-I18nText 'tui_group_system' $lang)
        foreach ($it in $globalItems) {
            $index++
            $map[[string]$index] = $it.Id
            Write-Host ("  {0,2}. {1}  [{2}]" -f $index, $it.Title, $it.Key)
        }
    }
    Write-Host ''

    $running = $true
    while ($running) {
        $answer = Read-TuiInput (Get-I18nText 'tui_plain_prompt' $lang)
        if ($null -eq $answer) { break }
        $answer = $answer.Trim()
        if ($answer -eq 'q' -or $answer -eq 'Q') { $running = $false; break }
        if ($answer -eq 'h' -or $answer -eq 'H') {
            $null = Show-PSManagerHelp -Language $lang
            continue
        }
        if (-not $map.ContainsKey($answer)) { continue }

        $id = $map[$answer]
        $item = $catalog | Where-Object { $_.Id -eq $id } | Select-Object -First 1

        if ($item.Destructive) {
            Write-Host ('  ' + (Get-I18nText 'tui_confirm_title' $lang))
            $confirm = Read-TuiInput ((Get-I18nText 'tui_confirm_body' $lang) -f $item.Title)
            if ($confirm -notmatch '^[Yy]$') {
                Write-Host (Get-I18nText 'tui_msg_cancelled' $lang)
                continue
            }
        } elseif ($item.Undoable) {
            # AC-T3: reversible actions always show a preview and default to cancel.
            Write-Host ('  ' + (Get-I18nText 'tui_preview_title' $lang) + ': ' + $item.Title)
            foreach ($descLine in (Get-TuiWrappedText -Text ([string]$item.Desc) -MaxWidth 76)) {
                Write-Host ('    ' + $descLine)
            }
            Write-Host ('    ' + (Get-I18nText 'tui_meta_undo' $lang) + ': ' + [string]$item.UndoHint)
            $go = Read-TuiInput (Get-I18nText 'tui_plain_apply' $lang)
            if ($go -notmatch '^[Yy]$') {
                Write-Host (Get-I18nText 'tui_msg_cancelled' $lang)
                continue
            }
        }

        try {
            $outcome = Invoke-TuiActionById -Id $id -Language $lang
        } catch {
            # A failing preflight (missing/invalid credential, refused target) must print a
            # readable message here instead of escaping as a raw PowerShell error.
            Write-Host ((Get-I18nText 'tui_msg_action_failed' $lang) -f $_.Exception.Message)
            $outcome = $null
        }
        if ($outcome -and -not $outcome.Ok -and $outcome.Errors) {
            foreach ($errText in $outcome.Errors) {
                Write-Host ((Get-I18nText 'tui_msg_action_failed' $lang) -f $errText)
            }
        }
        Write-Host ''
        if ($outcome -and $outcome.Stop) {
            $running = $false
            break
        }
    }

    Write-Host (Get-I18nText 'tui_plain_exit' $lang)
}

function Get-TuiNextLanguage {
    <#
    .SYNOPSIS
        Next explicit interface language in the TUI cycle: en -> vi-ascii -> vi -> en.
    .DESCRIPTION
        Cycles the persisted config value, not the effective render language, so an
        explicit 'vi' is reachable on every runtime and is never skipped.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Language)

    switch ($Language) {
        'en'       { return 'vi-ascii' }
        'vi-ascii' { return 'vi' }
        'vi'       { return 'en' }
        default    { return 'vi-ascii' }
    }
}

function Update-TuiLanguageCycle {
    <#
    .SYNOPSIS
        Persists the next language and refreshes the catalog and screen language.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $current = if ($State.Config) { ([string]$State.Config.language).Trim() } else { Get-EffectiveLanguage }
    Set-PSManagerConfig -Language (Get-TuiNextLanguage -Language $current) | Out-Null

    $State.Config = Get-PSManagerConfig
    $State.Language = Get-EffectiveLanguage
    $State.Groups = Get-TuiGroups -Language $State.Language
    $State.Catalog = Get-TuiCatalog -Language $State.Language
    return $State
}

function Show-TUI {
    [CmdletBinding()]
    param()

    $caps = Get-TuiCapabilities

    # No TTY: never enter an interactive loop (AC-T10).
    if (-not $caps.IsTty) {
        $null = Show-PSManagerHelp
        return
    }

    # Plain mode is the fallback for accessibility AND for consoles without VT
    # (legacy conhost would print the escape sequences literally).
    if ($caps.PlainMode -or -not $caps.HasVt) {
        Show-TuiPlain -Caps $caps
        return
    }

    $lang = Get-EffectiveLanguage
    $ctl = @{ Running = $true }
    $state = New-TuiState -Version ([string]$Script:VERSION) -Language $lang `
        -Status (Get-PSManagerStatus) -Config (Get-PSManagerConfig) `
        -Groups (Get-TuiGroups -Language $lang) -Catalog (Get-TuiCatalog -Language $lang)

    # Cached only: startup must never block on the network.
    try {
        $cache = Get-PSManagerUpdateStatus -CacheOnly
        if ($null -ne $cache) {
            $state.UpdateStatus = $cache
            if ($cache.UpdateAvailable) {
                $state.StatusMessage = (Get-I18nText 'tui_update_available' $lang) -f $cache.LatestVersion
            }
        }
    } catch {}
    $state = Update-TuiNotificationState -State $state -Limit 20

    $prevFrame = $null
    $lastW = 0
    $lastH = 0

    Invoke-TuiScreen -Body {
        while ($ctl.Running) {
            $caps = Get-TuiCapabilities
            # One column is left unused: writing the final border into the terminal's
            # last cell leaves it in the pending-wrap state, and several terminals drop
            # that glyph, which looks like a missing right border.
            $w = if ($caps.Width -gt 81) { $caps.Width - 1 } elseif ($caps.Width -gt 0) { $caps.Width } else { 80 }
            $h = if ($caps.Height -gt 0) { $caps.Height } else { 24 }

            # A resize invalidates line positions, so repaint from scratch once.
            if ($w -ne $lastW -or $h -ne $lastH) {
                [Console]::Write("$($Script:TUI_ESC)[2J")
                $prevFrame = $null
                $lastW = $w
                $lastH = $h
            }

            $frame = New-TuiFrame -State $state -Width $w -Height $h -Caps $caps
            Write-TuiFrame -Frame $frame -PreviousFrame $prevFrame
            $prevFrame = $frame

            $keyInfo = [Console]::ReadKey($true)
            if ($keyInfo.Key -eq [ConsoleKey]::C -and ($keyInfo.Modifiers -band [ConsoleModifiers]::Control)) {
                $ctl.Running = $false
                break
            }

            $keyStr = Convert-TuiKeyToString -KeyInfo $keyInfo
            if (-not $keyStr) { continue }

            $reduced = Update-TuiState -State $state -Key $keyStr
            $state = $reduced.State

            switch ($reduced.Command) {
                'quit' { $ctl.Running = $false }
                'lang' {
                    $state = Update-TuiLanguageCycle -State $state
                    $prevFrame = $null
                    [Console]::Write("$($Script:TUI_ESC)[2J")
                }
                'gui' {
                    $esc = $Script:TUI_ESC
                    [Console]::Write("$esc[0m$esc[?25h$esc[?1049l")
                    try { Start-DesktopGUI } catch {}
                    Write-Host (Get-I18nText 'tui_msg_gui_launched' $state.Language)
                    try { [Console]::ReadKey($true) | Out-Null } catch {}
                    [Console]::Write("$esc[?1049h$esc[?25l$esc[2J")
                    $prevFrame = $null
                }
                'run' { $state, $prevFrame = Invoke-TuiActionFlow -State $state -PrevFrame $prevFrame }
                'apply' { $state, $prevFrame = Invoke-TuiActionFlow -State $state -PrevFrame $prevFrame }
                'notifications' {
                    $state = Update-TuiNotificationState -State $state
                    $state.NotificationIndex = 0
                    $state.Mode = 'Notifications'
                    $null = Set-PSManagerNotificationRead -All
                    $state.UnreadCount = 0
                    $prevFrame = $null
                    [Console]::Write("$($Script:TUI_ESC)[2J")
                }
                'notifications-clear' {
                    $null = Clear-PSManagerNotifications
                    $state = Update-TuiNotificationState -State $state
                    $state.NotificationIndex = 0
                    $state.UnreadCount = 0
                    $state.Mode = 'Notifications'
                    $prevFrame = $null
                    [Console]::Write("$($Script:TUI_ESC)[2J")
                }
                'notifications-read' {
                    $null = Set-PSManagerNotificationRead -All
                    $state = Update-TuiNotificationState -State $state
                    $state.UnreadCount = 0
                    $prevFrame = $null
                    [Console]::Write("$($Script:TUI_ESC)[2J")
                }
                'notifications-open' {
                    $notes = @($state.Notifications)
                    $noteIdx = [int]$state.NotificationIndex
                    if ($noteIdx -ge 0 -and $noteIdx -lt $notes.Count -and $notes[$noteIdx].Url) {
                        try { Start-Process ([string]$notes[$noteIdx].Url) } catch {}
                        $null = Set-PSManagerNotificationRead -Id @([string]$notes[$noteIdx].Id)
                    }
                    $state = Update-TuiNotificationState -State $state
                    $state.Mode = 'Notifications'
                    $state.UnreadCount = @($state.Notifications | Where-Object { -not $_.Read }).Count
                    $prevFrame = $null
                    [Console]::Write("$($Script:TUI_ESC)[2J")
                }
                'update-check' {
                    $st = $null
                    try { $st = Get-PSManagerUpdateStatus -Force } catch { $st = $null }
                    $details = @()
                    $errors = @()
                    $ok = $false
                    if ($null -ne $st) {
                        $state.UpdateStatus = $st
                        $ok = ($st.Status -ne 'Error' -and -not $st.Error)
                        if ($st.Error) { $errors = @($st.Error) }
                        $null = Add-PSManagerUpdateNotification -Status $st
                        if ($st.UpdateAvailable) {
                            $state.StatusMessage = (Get-I18nText 'tui_update_available' $state.Language) -f $st.LatestVersion
                        }
                        $details = @(
                            ((Get-I18nText 'update_current' $state.Language) + ': ' + [string]$st.CurrentVersion),
                            ((Get-I18nText 'update_latest' $state.Language) + ': ' + [string]$st.LatestVersion),
                            ((Get-I18nText 'update_release' $state.Language) + ': ' + [string]$st.ReleaseUrl),
                            ((Get-I18nText 'update_checked' $state.Language) + ': ' + ([datetime]$st.CheckedAt).ToString('yyyy-MM-dd HH:mm'))
                        )
                    }
                    $state = Update-TuiNotificationState -State $state
                    $checkItem = Get-TuiCatalogItem -Catalog @($state.Catalog) -Id 'update-check'
                    if ($null -ne $checkItem) { $state.PreviewItem = $checkItem }
                    $state.Result = @{
                        Ok       = [bool]$ok
                        Duration = 0
                        Errors   = @($errors)
                        Details  = @($details)
                    }
                    $state.Mode = 'Result'
                    $prevFrame = $null
                    [Console]::Write("$($Script:TUI_ESC)[2J")
                }
                'update-app' {
                    $st = $state.UpdateStatus
                    if ($null -eq $st -or -not $st.UpdateAvailable -or $st.Error) {
                        try { $st = Get-PSManagerUpdateStatus -Force } catch { $st = $null }
                        if ($null -ne $st) { $state.UpdateStatus = $st }
                    }
                    if ($null -eq $st -or -not $st.UpdateAvailable -or $st.Error) {
                        $isErr = ($null -ne $st -and ($st.Status -eq 'Error' -or $st.Error))
                        $message = if ($isErr) {
                            (Get-I18nText 'update_error_hint' $state.Language) -f $st.Error
                        } elseif ($null -ne $st -and $st.Status -eq 'Disabled') {
                            Get-I18nText 'update_status_disabled' $state.Language
                        } else {
                            Get-I18nText 'update_none_hint' $state.Language
                        }
                        $appItem = Get-TuiCatalogItem -Catalog @($state.Catalog) -Id 'update-app'
                        if ($null -ne $appItem) { $state.PreviewItem = $appItem }
                        $state.Result = @{
                            Ok       = (-not $isErr)
                            Duration = 0
                            Errors   = if ($isErr) { @($message) } else { @() }
                            Details  = if (-not $isErr) { @($message) } else { @() }
                        }
                        $state.Mode = 'Result'
                        $prevFrame = $null
                        [Console]::Write("$($Script:TUI_ESC)[2J")
                    } else {
                        $esc = $Script:TUI_ESC
                        [Console]::Write("$esc[0m$esc[?25h$esc[?1049l")
                        try { Clear-Host } catch {}
                        $answer = Read-TuiInput -Prompt ((Get-I18nText 'update_confirm_install' $state.Language) -f $st.LatestVersion)
                        if ($answer -match '^[Yy]') {
                            try {
                                $installResult = Install-PSManagerUpdate -Status $st
                                if ($installResult.Success) {
                                    Write-Host (Get-I18nText 'notif_update_installed' $state.Language)
                                    if ($installResult.RestartRequired) { Write-Host (Get-I18nText 'notif_update_restart' $state.Language) }
                                } else {
                                    Write-Host ((Get-I18nText 'notif_update_failed' $state.Language) -f $installResult.Error)
                                }
                            } catch {
                                Write-Host ((Get-I18nText 'notif_update_failed' $state.Language) -f $_.Exception.Message)
                            }
                            try { [Console]::ReadKey($true) | Out-Null } catch {}
                            $ctl.Running = $false
                        } else {
                            Write-Host (Get-I18nText 'tui_msg_cancelled' $state.Language)
                            try { [Console]::ReadKey($true) | Out-Null } catch {}
                            [Console]::Write("$esc[?1049h$esc[?25l$esc[2J")
                            $prevFrame = $null
                        }
                    }
                }
            }
        }
    }

    # Restore a clean terminal even on abnormal exits.
    try { [Console]::CursorVisible = $true } catch {}
    try { Clear-Host } catch {}
    Write-Host (Get-I18nText 'exited')
}

function Invoke-TuiActionFlow {
    <#
    .SYNOPSIS
        Leaves the alternate screen, runs the selected action, then returns to a result screen.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$State,
        [string[]]$PrevFrame
    )

    $esc = $Script:TUI_ESC
    $item = $State.PreviewItem
    if ($null -eq $item) { return @($State, $PrevFrame) }

    [Console]::Write("$esc[0m$esc[?25h$esc[?1049l")
    try { Clear-Host } catch {}

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $outcome = @{ Ok = $true; Errors = @() }
    try {
        $outcome = Invoke-TuiActionById -Id $item.Id -Language $State.Language
    } catch {
        $outcome = @{ Ok = $false; Errors = @($_.Exception.Message) }
    }
    $stopwatch.Stop()

    $State.Result = @{
        Ok       = [bool]$outcome.Ok
        Duration = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        Errors   = @($outcome.Errors)
    }
    $State.Mode = 'Result'

    [Console]::Write("$esc[?1049h$esc[?25l$esc[2J")
    return @($State, $null)
}
