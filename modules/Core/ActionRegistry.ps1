#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Core - Central Action & Capability Registry
.DESCRIPTION
    Single source of truth defining all user-facing capabilities across
    CLI, TUI, and Desktop GUI interfaces to ensure strict 3-way parity.
#>

$Script:PSMANAGER_ACTION_REGISTRY = @(
    @{
        Id          = 'def7'
        Category    = 'DefaultShell'
        CliAction   = 'set-default-ps7'
        TuiKey      = '1'
        GuiButton   = 'BtnSetDefaultPS7'
        TitleKey    = 'menu_def7'
        DescKey     = 'menu_def7_desc'
    },
    @{
        Id          = 'def5'
        Category    = 'DefaultShell'
        CliAction   = 'set-default-ps5'
        TuiKey      = '2'
        GuiButton   = 'BtnRestorePS5'
        TitleKey    = 'menu_def5'
        DescKey     = 'menu_def5_desc'
    },
    @{
        Id          = 'source'
        Category    = 'Package'
        CliAction   = 'source'
        TuiKey      = '3'
        GuiButton   = 'BtnSrcWinget'
        TitleKey    = 'menu_source'
        DescKey     = 'menu_source_desc'
    },
    @{
        Id          = 'update'
        Category    = 'Maintenance'
        CliAction   = 'update'
        TuiKey      = '4'
        GuiButton   = 'BtnUpdate'
        TitleKey    = 'menu_update'
        DescKey     = 'menu_update_desc'
    },
    @{
        Id          = 'install'
        Category    = 'Maintenance'
        CliAction   = 'install'
        TuiKey      = '5'
        GuiButton   = 'BtnInstall'
        TitleKey    = 'menu_install'
        DescKey     = 'menu_install_desc'
    },
    @{
        Id          = 'sync'
        Category    = 'Sync'
        CliAction   = 'sync'
        TuiKey      = 'Y'
        GuiButton   = 'BtnSyncNow'
        TitleKey    = 'menu_sync'
        DescKey     = 'menu_sync_desc'
    },
    @{
        Id          = 'doctor'
        Category    = 'Sync'
        CliAction   = 'doctor'
        TuiKey      = 'O'
        GuiButton   = 'BtnDoctorAudit'
        TitleKey    = 'menu_doctor'
        DescKey     = 'menu_doctor_desc'
    },
    @{
        Id          = 'adopt'
        Category    = 'Sync'
        CliAction   = 'adopt'
        TuiKey      = 'A'
        GuiButton   = 'BtnAdoptProfiles'
        TitleKey    = 'gui_btn_adopt'
        DescKey     = 'gui_btn_adopt_tip'
    },
    @{
        Id          = 'backup'
        Category    = 'Sync'
        CliAction   = 'backup'
        TuiKey      = 'B'
        GuiButton   = 'BtnBackupProfiles'
        TitleKey    = 'gui_btn_backup'
        DescKey     = 'gui_btn_backup_tip'
    },
    @{
        Id          = 'backup-cloud'
        Category    = 'Sync'
        CliAction   = 'backup-cloud'
        TuiKey      = 'C'
        GuiButton   = 'BtnBackupCloud'
        TitleKey    = 'gui_btn_cloud_backup'
        DescKey     = 'gui_btn_cloud_backup_tip'
    },
    @{
        Id          = 'set-cloud-repo'
        Category    = 'Sync'
        CliAction   = 'set-cloud-repo'
        TuiKey      = 'j'
        GuiButton   = 'BtnSetCloudRepo'
        TitleKey    = 'gui_btn_set_cloud_repo'
        DescKey     = 'gui_btn_set_cloud_repo_tip'
    },
    @{
        Id          = 'restore'
        Category    = 'Sync'
        CliAction   = 'restore'
        TuiKey      = 'K'
        GuiButton   = 'BtnRestoreBackup'
        TitleKey    = 'gui_btn_restore'
        DescKey     = 'gui_btn_restore_tip'
    },
    @{
        Id          = 'logs'
        Category    = 'Maintenance'
        CliAction   = 'logs'
        TuiKey      = 'V'
        GuiButton   = 'BtnViewLogs'
        TitleKey    = 'gui_btn_viewlogs'
        DescKey     = 'gui_btn_viewlogs_tip'
    },
    @{
        Id          = 'sync-sources'
        Category    = 'Maintenance'
        CliAction   = 'sync-sources'
        TuiKey      = 'W'
        GuiButton   = 'BtnSyncSources'
        TitleKey    = 'gui_btn_syncsources'
        DescKey     = 'gui_btn_syncsources_tip'
    },
    @{
        Id          = 'q_ps7'
        Category    = 'Launch'
        CliAction   = 'switch-ps7'
        TuiKey      = '6'
        GuiButton   = 'BtnLaunchPS7'
        TitleKey    = 'menu_ps7'
        DescKey     = 'menu_ps7_desc'
    },
    @{
        Id          = 'q_ps7a'
        Category    = 'Launch'
        CliAction   = 'switch'
        TuiKey      = '7'
        GuiButton   = 'BtnLaunchPS7Admin'
        TitleKey    = 'menu_ps7a'
        DescKey     = 'menu_ps7a_desc'
    },
    @{
        Id          = 'q_split'
        Category    = 'Launch'
        CliAction   = 'switch'
        TuiKey      = '8'
        GuiButton   = 'BtnLaunchSplit'
        TitleKey    = 'menu_split'
        DescKey     = 'menu_split_desc'
    },
    @{
        Id          = 'q_ps5'
        Category    = 'Launch'
        CliAction   = 'switch-ps5'
        TuiKey      = '9'
        GuiButton   = 'BtnLaunchPS5'
        TitleKey    = 'menu_ps5'
        DescKey     = 'menu_ps5_desc'
    },
    @{
        Id          = 'diag'
        Category    = 'Maintenance'
        CliAction   = 'diagnostics'
        TuiKey      = '0'
        GuiButton   = 'BtnDiagnostics'
        TitleKey    = 'menu_diag'
        DescKey     = 'menu_diag_desc'
    },
    @{
        Id          = 'gui'
        Category    = 'Interface'
        CliAction   = 'gui'
        TuiKey      = 'G'
        GuiButton   = 'BtnLaunchTUI'
        TitleKey    = 'menu_gui'
        DescKey     = 'menu_gui_desc'
    },
    @{
        Id          = 'lang'
        Category    = 'Config'
        CliAction   = 'set-lang'
        TuiKey      = 'L'
        GuiButton   = 'BtnLangToggle'
        TitleKey    = 'menu_lang'
        DescKey     = 'menu_lang_desc'
    },
    @{
        Id          = 'prof'
        Category    = 'Config'
        CliAction   = 'edit-profile'
        TuiKey      = 'P'
        GuiButton   = 'BtnEditProfile'
        TitleKey    = 'menu_prof'
        DescKey     = 'menu_prof_desc'
    },
    @{
        Id          = 'audit-prof'
        Category    = 'Maintenance'
        CliAction   = 'audit-profile'
        TuiKey      = 'T'
        GuiButton   = 'BtnAuditProfiles'
        TitleKey    = 'menu_audit_prof'
        DescKey     = 'menu_audit_prof_desc'
    },
    @{
        Id          = 'clean-backups'
        Category    = 'Maintenance'
        CliAction   = 'clean-backups'
        TuiKey      = 'X'
        GuiButton   = 'BtnDeleteBackups'
        TitleKey    = 'menu_clean_backups'
        DescKey     = 'menu_clean_backups_desc'
    },
    @{
        Id          = 'help'
        Category    = 'Interface'
        CliAction   = 'help'
        TuiKey      = 'h'
        GuiButton   = 'BtnHelp'
        TitleKey    = 'menu_help'
        DescKey     = 'menu_help_desc'
    },
    @{
        Id          = 'update-check'
        Category    = 'Maintenance'
        CliAction   = 'update-check'
        TuiKey      = 'v'
        GuiButton   = 'BtnCheckUpdate'
        TitleKey    = 'menu_update_check'
        DescKey     = 'menu_update_check_desc'
    },
    @{
        Id          = 'update-app'
        Category    = 'Maintenance'
        CliAction   = 'update-app'
        TuiKey      = 'p'
        GuiButton   = 'BtnInstallUpdate'
        TitleKey    = 'menu_update_app'
        DescKey     = 'menu_update_app_desc'
    },
    @{
        Id          = 'notifications'
        Category    = 'Interface'
        CliAction   = 'notifications'
        TuiKey      = '!'
        GuiButton   = 'BtnNotifications'
        TitleKey    = 'menu_notifications'
        DescKey     = 'menu_notifications_desc'
    }
)

function Get-PSManagerActions {
    [CmdletBinding()]
    [OutputType([array])]
    param()

    return $Script:PSMANAGER_ACTION_REGISTRY
}
