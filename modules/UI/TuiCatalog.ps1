#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager TUI - Action Catalog, Groups & Keyboard Mapping
.DESCRIPTION
    Maps all PSManager capabilities into 5 ergonomic groups matching the Desktop GUI.
    Defines mnemonic single-character hotkeys that avoid confusing pairs (no 0 vs O, no 1 vs l),
    while preserving 100% backward compatibility for all legacy single-key shortcuts.
#>

function Get-TuiGroups {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string]$Language = "vi"
    )


    $ids = @('shell', 'launch', 'update', 'backup', 'health')
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ids) {
        $groups.Add([pscustomobject]@{
            Id    = $id
            Title = Get-I18nText ("tui_group_" + $id) $Language
        })
    }
    return $groups.ToArray()
}

function Get-TuiCatalog {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string]$Language = "vi"
    )

    # Master list of all actions in hierarchical display order
    $items = @(
        # --- Group 1: Shell ---
        [pscustomobject]@{
            Id          = 'def7'
            GroupId     = 'shell'
            Key         = 'd'
            LegacyKeys  = @('1', 'D')
            TitleKey    = 'menu_def7'
            DescKey     = 'menu_def7_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $true
            UndoHint    = Get-I18nText 'tui_undo_def7' $Language
            ActionTarget= 'def7'
        },
        [pscustomobject]@{
            Id          = 'def5'
            GroupId     = 'shell'
            Key         = 'r'
            LegacyKeys  = @('2', 'R')
            TitleKey    = 'menu_def5'
            DescKey     = 'menu_def5_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $true
            UndoHint    = Get-I18nText 'tui_undo_def5' $Language
            ActionTarget= 'def5'
        },

        # --- Group 2: Quick Launch ---
        [pscustomobject]@{
            Id          = 'q_ps7'
            GroupId     = 'launch'
            Key         = '6'
            LegacyKeys  = @('6')
            TitleKey    = 'menu_ps7'
            DescKey     = 'menu_ps7_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'q_ps7'
        },
        [pscustomobject]@{
            Id          = 'q_ps7a'
            GroupId     = 'launch'
            Key         = '7'
            LegacyKeys  = @('7')
            TitleKey    = 'menu_ps7a'
            DescKey     = 'menu_ps7a_desc'
            NeedAdmin   = $true
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'q_ps7a'
        },
        [pscustomobject]@{
            Id          = 'q_split'
            GroupId     = 'launch'
            Key         = '8'
            LegacyKeys  = @('8')
            TitleKey    = 'menu_split'
            DescKey     = 'menu_split_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'q_split'
        },
        [pscustomobject]@{
            Id          = 'q_ps5'
            GroupId     = 'launch'
            Key         = '9'
            LegacyKeys  = @('9')
            TitleKey    = 'menu_ps5'
            DescKey     = 'menu_ps5_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'q_ps5'
        },

        # --- Group 3: Update & Maintenance ---
        [pscustomobject]@{
            Id          = 'update'
            GroupId     = 'update'
            Key         = 'u'
            LegacyKeys  = @('4', 'U')
            TitleKey    = 'menu_update'
            DescKey     = 'menu_update_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'update'
        },
        [pscustomobject]@{
            Id          = 'install'
            GroupId     = 'update'
            Key         = 'i'
            LegacyKeys  = @('5', 'I')
            TitleKey    = 'menu_install'
            DescKey     = 'menu_install_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'install'
        },
        [pscustomobject]@{
            Id          = 'source'
            GroupId     = 'update'
            Key         = 'c'
            LegacyKeys  = @('3', 'S')
            TitleKey    = 'menu_source'
            DescKey     = 'menu_source_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $true
            UndoHint    = Get-I18nText 'tui_undo_source' $Language
            ActionTarget= 'source'
        },
        [pscustomobject]@{
            Id          = 'sync'
            GroupId     = 'update'
            Key         = 'y'
            LegacyKeys  = @('Y')
            TitleKey    = 'menu_sync'
            DescKey     = 'menu_sync_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $true
            UndoHint    = Get-I18nText 'tui_undo_sync' $Language
            ActionTarget= 'sync'
        },
        [pscustomobject]@{
            Id          = 'sync-sources'
            GroupId     = 'update'
            Key         = 'w'
            LegacyKeys  = @('W')
            TitleKey    = 'gui_btn_syncsources'
            DescKey     = 'gui_btn_syncsources_tip'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'sync-sources'
        },

        # --- Group 4: Backup & Restore ---
        [pscustomobject]@{
            Id          = 'backup'
            GroupId     = 'backup'
            Key         = 'b'
            LegacyKeys  = @('B')
            TitleKey    = 'gui_btn_backup'
            DescKey     = 'gui_btn_backup_tip'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'backup'
        },
        [pscustomobject]@{
            Id          = 'restore'
            GroupId     = 'backup'
            Key         = 'k'
            LegacyKeys  = @('K')
            TitleKey    = 'gui_btn_restore'
            DescKey     = 'gui_btn_restore_tip'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $true
            UndoHint    = Get-I18nText 'tui_undo_restore' $Language
            ActionTarget= 'restore'
        },
        [pscustomobject]@{
            Id          = 'backup-cloud'
            GroupId     = 'backup'
            Key         = 'n'
            LegacyKeys  = @('C')
            TitleKey    = 'gui_btn_cloud_backup'
            DescKey     = 'gui_btn_cloud_backup_tip'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'backup-cloud'
        },
        [pscustomobject]@{
            Id          = 'set-cloud-repo'
            GroupId     = 'backup'
            Key         = 'j'
            LegacyKeys  = @()
            TitleKey    = 'gui_btn_set_cloud_repo'
            DescKey     = 'gui_btn_set_cloud_repo_tip'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'set-cloud-repo'
        },
        [pscustomobject]@{
            Id          = 'clean-backups'
            GroupId     = 'backup'
            Key         = 'x'
            LegacyKeys  = @('X')
            TitleKey    = 'menu_clean_backups'
            DescKey     = 'menu_clean_backups_desc'
            NeedAdmin   = $false
            Destructive = $true
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'clean-backups'
        },

        # --- Group 5: Health & Profiles ---
        [pscustomobject]@{
            Id          = 'doctor'
            GroupId     = 'health'
            Key         = 'o'
            LegacyKeys  = @('O')
            TitleKey    = 'menu_doctor'
            DescKey     = 'menu_doctor_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'doctor'
        },
        [pscustomobject]@{
            Id          = 'diag'
            GroupId     = 'health'
            Key         = 'z'
            LegacyKeys  = @('0')
            TitleKey    = 'menu_diag'
            DescKey     = 'menu_diag_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'diag'
        },
        [pscustomobject]@{
            Id          = 'audit-prof'
            GroupId     = 'health'
            Key         = 't'
            LegacyKeys  = @('T')
            TitleKey    = 'menu_audit_prof'
            DescKey     = 'menu_audit_prof_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $true
            UndoHint    = Get-I18nText 'tui_undo_audit' $Language
            ActionTarget= 'audit-prof'
        },
        [pscustomobject]@{
            Id          = 'adopt'
            GroupId     = 'health'
            Key         = 'm'
            LegacyKeys  = @('A')
            TitleKey    = 'gui_btn_adopt'
            DescKey     = 'gui_btn_adopt_tip'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $true
            UndoHint    = Get-I18nText 'tui_undo_adopt' $Language
            ActionTarget= 'adopt'
        },
        [pscustomobject]@{
            Id          = 'prof'
            GroupId     = 'health'
            Key         = 'e'
            LegacyKeys  = @('P')
            TitleKey    = 'menu_prof'
            DescKey     = 'menu_prof_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'prof'
        },
        [pscustomobject]@{
            Id          = 'logs'
            GroupId     = 'health'
            Key         = 'f'
            LegacyKeys  = @('V')
            TitleKey    = 'gui_btn_viewlogs'
            DescKey     = 'gui_btn_viewlogs_tip'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'logs'
        },

        # --- Global shortcuts: registry parity only, never rendered in the action list ---
        [pscustomobject]@{
            Id          = 'gui'
            GroupId     = 'global'
            Key         = 'g'
            LegacyKeys  = @('G')
            TitleKey    = 'menu_gui'
            DescKey     = 'menu_gui_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'gui'
        },
        [pscustomobject]@{
            Id          = 'lang'
            GroupId     = 'global'
            Key         = 'l'
            LegacyKeys  = @('L')
            TitleKey    = 'menu_lang'
            DescKey     = 'menu_lang_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'lang'
        },
        [pscustomobject]@{
            Id          = 'help'
            GroupId     = 'global'
            Key         = 'h'
            LegacyKeys  = @('H')
            TitleKey    = 'menu_help'
            DescKey     = 'menu_help_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'help'
        },
        [pscustomobject]@{
            Id          = 'update-check'
            GroupId     = 'global'
            Key         = 'v'
            LegacyKeys  = @()
            TitleKey    = 'menu_update_check'
            DescKey     = 'menu_update_check_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'update-check'
        },
        [pscustomobject]@{
            Id          = 'update-app'
            GroupId     = 'global'
            Key         = 'p'
            LegacyKeys  = @()
            TitleKey    = 'menu_update_app'
            DescKey     = 'menu_update_app_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'update-app'
        },
        [pscustomobject]@{
            Id          = 'notifications'
            GroupId     = 'global'
            Key         = '!'
            LegacyKeys  = @()
            TitleKey    = 'menu_notifications'
            DescKey     = 'menu_notifications_desc'
            NeedAdmin   = $false
            Destructive = $false
            Undoable    = $false
            UndoHint    = ""
            ActionTarget= 'notifications'
        }
    )

    # Populate localized Title and Description
    foreach ($it in $items) {
        $it | Add-Member -NotePropertyName Title -NotePropertyValue (Get-I18nText $it.TitleKey $Language) -Force
        $it | Add-Member -NotePropertyName Desc  -NotePropertyValue (Get-I18nText $it.DescKey $Language) -Force
    }

    return $items
}

function Find-TuiActionByKey {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][string]$InputKey,
        [Parameter(Mandatory = $true)][object[]]$Catalog
    )

    $cleanKey = $InputKey.Trim()
    if (-not $cleanKey) { return $null }

    # 1. Exact-case mnemonic match wins (the lowercase key printed in the UI)
    foreach ($item in $Catalog) {
        if ($item.Key -ceq $cleanKey) {
            return @{ Item = $item; IsLegacy = $false }
        }
    }

    # 2. Exact-case legacy alias ('X', '1', 'D') -> report the new key as a hint
    foreach ($item in $Catalog) {
        foreach ($lKey in $item.LegacyKeys) {
            if ($lKey -ceq $cleanKey) {
                return @{ Item = $item; IsLegacy = $true; PrimaryKey = $item.Key }
            }
        }
    }

    # 3. Case-insensitive fallback (e.g. a stray uppercase of a mnemonic)
    foreach ($item in $Catalog) {
        if ($item.Key -ieq $cleanKey) {
            return @{ Item = $item; IsLegacy = $false }
        }
    }

    return $null
}
