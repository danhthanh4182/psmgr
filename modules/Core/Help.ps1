#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Core - Shared Help Catalog
.DESCRIPTION
    One command reference feeds the CLI (`psmgr help [command]`), the TUI help overlay and
    the desktop Help page. Entries come from the action registry plus a small table of
    CLI-only commands, so a new capability never has to be documented three times.
#>

$Script:PSMANAGER_HELP_LINKS = @{
    Repository = 'https://github.com/danhthanh4182/psmgr'
    Releases   = 'https://github.com/danhthanh4182/psmgr/releases'
    Issues     = 'https://github.com/danhthanh4182/psmgr/issues'
    Docs       = 'https://github.com/danhthanh4182/psmgr/tree/main/docs'
    License    = 'https://github.com/danhthanh4182/psmgr/blob/main/LICENSE'
}

# Exact usage line per CLI action. The CLI dispatcher's ValidateSet is the source of truth
# for which of these actually exist; tests/test_interface_parity.ps1 keeps the two aligned.
$Script:PSMANAGER_HELP_USAGE = @{
    'tui'             = 'psmgr'
    'gui'             = 'psmgr gui'
    'status'          = 'psmgr status [-NoColor]'
    'set-default'     = 'psmgr set-default [ps7|ps5]'
    'set-default-ps7' = 'psmgr set-default-ps7'
    'set-default-ps5' = 'psmgr set-default-ps5'
    'switch'          = 'psmgr switch [ps7|ps5|admin|split|ps5-admin]'
    'switch-ps7'      = 'psmgr switch-ps7'
    'switch-ps5'      = 'psmgr switch-ps5'
    'update'          = 'psmgr update'
    'install'         = 'psmgr install'
    'update-check'    = 'psmgr update-check'
    'update-app'      = 'psmgr update-app [-Force]'
    'notifications'   = 'psmgr notifications [-Value all|clear|read]'
    'source'          = 'psmgr source'
    'set-source'      = 'psmgr set-source <winget|msstore|github>'
    'set-channel'     = 'psmgr set-channel <stable|preview|lts>'
    'set-lang'        = 'psmgr set-lang <en|vi|vi-ascii>'
    'sync-sources'    = 'psmgr sync-sources'
    'sync'            = 'psmgr sync [-DryRun] [-SkipPackages]'
    'doctor'          = 'psmgr doctor [-Fix]'
    'adopt'           = 'psmgr adopt'
    'audit-profile'   = 'psmgr audit-profile [-Fix]'
    'backup'          = 'psmgr backup'
    'backup-cloud'    = 'psmgr backup-cloud'
    'set-cloud-repo'  = 'psmgr set-cloud-repo [owner/repo]'
    'clean-backups'   = 'psmgr clean-backups [all|names] [-Force]'
    'restore'         = 'psmgr restore [file.zip]'
    'logs'            = 'psmgr logs [-Tail N] [-Errors]'
    'edit-profile'    = 'psmgr edit-profile'
    'diagnostics'     = 'psmgr diagnostics'
    'help'            = 'psmgr help [command]'
}

# Commands that exist only in the CLI, so the registry cannot describe them.
$Script:PSMANAGER_HELP_EXTRAS = @(
    @{ CliAction = 'tui';         DescKey = 'help_cmd_tui_desc' }
    @{ CliAction = 'status';      DescKey = 'help_cmd_status_desc' }
    @{ CliAction = 'set-default'; DescKey = 'help_cmd_set_default_desc' }
    @{ CliAction = 'set-source';  DescKey = 'help_cmd_set_source_desc' }
    @{ CliAction = 'set-channel'; DescKey = 'help_cmd_set_channel_desc' }
    @{ CliAction = 'switch';      DescKey = 'help_cmd_switch_desc' }
    @{ CliAction = 'switch-ps7';  DescKey = 'help_cmd_switch_desc' }
    @{ CliAction = 'switch-ps5';  DescKey = 'help_cmd_switch_desc' }
)

# Ordered groups. Commands are matched against the catalog Id first (q_ps7 vs switch-ps7
# both point at "psmgr switch-ps7") and then against the CLI action.
$Script:PSMANAGER_HELP_GROUPS = @(
    @{
        Id       = 'Interface'
        TitleKey = 'help_group_interface'
        Commands = @('tui', 'gui', 'status', 'diagnostics', 'help', 'logs')
    },
    @{
        Id       = 'Shell'
        TitleKey = 'help_group_shell'
        Commands = @('set-default', 'set-default-ps7', 'set-default-ps5', 'switch', 'switch-ps7', 'switch-ps5')
    },
    @{
        Id       = 'Update'
        TitleKey = 'help_group_update'
        Commands = @('source', 'set-source', 'set-channel', 'update', 'install', 'sync-sources', 'update-check', 'update-app', 'notifications')
    },
    @{
        Id       = 'Profiles'
        TitleKey = 'help_group_profiles'
        Commands = @('sync', 'doctor', 'adopt', 'audit-profile', 'backup', 'backup-cloud', 'set-cloud-repo', 'restore', 'clean-backups')
    },
    @{
        Id       = 'Launch'
        TitleKey = 'help_group_launch'
        Commands = @('q_ps7', 'q_ps7a', 'q_split', 'q_ps5')
    },
    @{
        Id       = 'Settings'
        TitleKey = 'help_group_settings'
        Commands = @('lang', 'prof')
    },
    @{
        Id       = 'System'
        TitleKey = 'help_group_system'
        Commands = @()
    }
)

function Get-PSManagerHelpLinks {
    <#
    .SYNOPSIS
        Project URLs shared by the CLI help, GUI Help page and the documentation.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $copy = @{}
    foreach ($key in $Script:PSMANAGER_HELP_LINKS.Keys) {
        $copy[$key] = $Script:PSMANAGER_HELP_LINKS[$key]
    }
    return $copy
}

function Get-PSManagerHelpGroupId {
    <#
    .SYNOPSIS
        Resolves the group for one catalog entry; unmatched commands land in System.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Id,
        [string]$CliAction
    )

    foreach ($group in $Script:PSMANAGER_HELP_GROUPS) {
        if ($Id -and ($group.Commands -contains $Id)) { return $group.Id }
    }
    foreach ($group in $Script:PSMANAGER_HELP_GROUPS) {
        if ($CliAction -and ($group.Commands -contains $CliAction)) { return $group.Id }
    }
    return 'System'
}

function Get-PSManagerHelpUsage {
    <#
    .SYNOPSIS
        Usage line for one CLI action, with a predictable fallback.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$CliAction)

    if ($Script:PSMANAGER_HELP_USAGE.ContainsKey($CliAction)) {
        return [string]$Script:PSMANAGER_HELP_USAGE[$CliAction]
    }
    return ('psmgr ' + $CliAction)
}

function Get-PSManagerHelpSections {
    <#
    .SYNOPSIS
        Ordered help groups, each carrying its localized title and command rows.
    .OUTPUTS
        Array of objects with Id, Title and Items (Name, Usage, Title, Desc, Group, CliAction, Id).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Language)

    $lang = if ($Language) { $Language } else { Get-EffectiveLanguage }

    $items = [System.Collections.Generic.List[object]]::new()
    $seenActions = @{}
    foreach ($action in @(Get-PSManagerActions)) {
        if ($null -eq $action) { continue }
        $id = [string]$action.Id
        # The q_* entries are GUI/TUI launchers with partial switch commands; the command
        # reference documents the full CLI switch suite through the Shell group instead.
        if ($id -like 'q_*') { continue }
        $cliAction = [string]$action.CliAction
        if (-not $cliAction) { continue }
        if ($seenActions.ContainsKey($cliAction)) { continue }
        $seenActions[$cliAction] = $true

        $title = if ($action.TitleKey) { Get-I18nText $action.TitleKey $lang } else { $cliAction }
        $desc = if ($action.DescKey) { Get-I18nText $action.DescKey $lang } else { '' }
        $items.Add([pscustomobject]@{
            Name      = $cliAction
            Usage     = (Get-PSManagerHelpUsage -CliAction $cliAction)
            Title     = $title
            Desc      = $desc
            Group     = (Get-PSManagerHelpGroupId -Id ([string]$action.Id) -CliAction $cliAction)
            CliAction = $cliAction
            Id        = [string]$action.Id
        })
    }

    foreach ($extra in $Script:PSMANAGER_HELP_EXTRAS) {
        $cliAction = [string]$extra.CliAction
        if ($seenActions.ContainsKey($cliAction)) { continue }
        $seenActions[$cliAction] = $true
        $items.Add([pscustomobject]@{
            Name      = $cliAction
            Usage     = (Get-PSManagerHelpUsage -CliAction $cliAction)
            Title     = $cliAction
            Desc      = (Get-I18nText $extra.DescKey $lang)
            Group     = (Get-PSManagerHelpGroupId -CliAction $cliAction)
            CliAction = $cliAction
            Id        = ''
        })
    }

    $sections = [System.Collections.Generic.List[object]]::new()
    foreach ($group in $Script:PSMANAGER_HELP_GROUPS) {
        $groupItems = @($items | Where-Object { $_.Group -eq $group.Id })
        if ($groupItems.Count -eq 0) { continue }
        $sections.Add([pscustomobject]@{
            Id    = $group.Id
            Title = (Get-I18nText $group.TitleKey $lang)
            Items = @($groupItems)
        })
    }
    return $sections.ToArray()
}

function Get-PSManagerHelpEntry {
    <#
    .SYNOPSIS
        Looks up one command row by name, CLI action or catalog id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$Language
    )

    $needle = ([string]$Name).Trim()
    if ($needle -match '^(?i)psmgr(\.exe)?\s+') {
        $needle = ($needle -replace '^(?i)psmgr(\.exe)?\s+', '').Trim()
    }
    if (-not $needle) { return $null }

    $rows = @()
    foreach ($section in @(Get-PSManagerHelpSections -Language $Language)) {
        $rows += @($section.Items)
    }

    foreach ($row in $rows) {
        if ($row.Name -eq $needle) { return $row }
    }
    foreach ($row in $rows) {
        if ($row.CliAction -eq $needle) { return $row }
    }
    foreach ($row in $rows) {
        if ($row.Id -and $row.Id -eq $needle) { return $row }
    }
    return $null
}
