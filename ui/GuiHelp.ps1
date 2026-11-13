#Requires -Version 5.1
<#
.SYNOPSIS
    GUI Help & About page: command reference, shortcuts, update status and project links.
.DESCRIPTION
    Everything rendered here comes from the shared help catalog (modules/Core/Help.ps1), so the
    desktop page and `psmgr help` can never disagree. The command list is rebuilt only when the
    interface language changes, because Update-DashboardUI runs on every window activation.
#>

function Initialize-GuiHelp {
    <#
    .SYNOPSIS
        Resolves the Help page elements and wires the header and page actions.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Windows.Window]$Window)

    $Script:HelpWindow          = $Window
    $Script:BtnHelp             = $Window.FindName('BtnHelp')
    $Script:TxtHelpTitle        = $Window.FindName('TxtHelpTitle')
    $Script:TxtHelpSubtitle     = $Window.FindName('TxtHelpSubtitle')
    $Script:TxtHelpVersion      = $Window.FindName('TxtHelpVersion')
    $Script:TxtHelpIntro        = $Window.FindName('TxtHelpIntro')
    $Script:TxtCapCheckUpdate   = $Window.FindName('TxtCapCheckUpdate')
    $Script:LblHelpQuickStart   = $Window.FindName('LblHelpQuickStart')
    $Script:TxtHelpQuickDefault = $Window.FindName('TxtHelpQuickDefault')
    $Script:TxtHelpQuickDefaultDesc = $Window.FindName('TxtHelpQuickDefaultDesc')
    $Script:TxtHelpQuickSync    = $Window.FindName('TxtHelpQuickSync')
    $Script:TxtHelpQuickSyncDesc = $Window.FindName('TxtHelpQuickSyncDesc')
    $Script:TxtHelpQuickUpdate  = $Window.FindName('TxtHelpQuickUpdate')
    $Script:TxtHelpQuickUpdateDesc = $Window.FindName('TxtHelpQuickUpdateDesc')
    $Script:LblHelpCommands     = $Window.FindName('LblHelpCommands')
    $Script:HelpCommandList     = $Window.FindName('HelpCommandList')
    $Script:LblHelpUpdate       = $Window.FindName('LblHelpUpdate')
    $Script:TxtHelpUpdateStatus = $Window.FindName('TxtHelpUpdateStatus')
    $Script:TxtHelpUpdateDetail = $Window.FindName('TxtHelpUpdateDetail')
    $Script:TxtHelpUpdateChecked = $Window.FindName('TxtHelpUpdateChecked')
    $Script:LblHelpShortcuts    = $Window.FindName('LblHelpShortcuts')
    $Script:TxtHelpShortcuts    = $Window.FindName('TxtHelpShortcuts')
    $Script:LblHelpLinks        = $Window.FindName('LblHelpLinks')
    $Script:LblHelpAbout        = $Window.FindName('LblHelpAbout')
    $Script:TxtHelpAbout        = $Window.FindName('TxtHelpAbout')
    $Script:BtnOpenDocs         = $Window.FindName('BtnOpenDocs')
    $Script:BtnOpenRepo         = $Window.FindName('BtnOpenRepo')
    $Script:BtnOpenIssues       = $Window.FindName('BtnOpenIssues')
    $Script:BtnOpenLicense      = $Window.FindName('BtnOpenLicense')
    $Script:BtnCheckUpdate      = $Window.FindName('BtnCheckUpdate')
    $Script:BtnInstallUpdate    = $Window.FindName('BtnInstallUpdate')
    $Script:BtnOpenRelease      = $Window.FindName('BtnOpenRelease')
    $Script:TxtBtnCheckUpdate   = $Window.FindName('TxtBtnCheckUpdate')
    $Script:TxtBtnInstallUpdate = $Window.FindName('TxtBtnInstallUpdate')
    $Script:TxtBtnOpenRelease   = $Window.FindName('TxtBtnOpenRelease')
    $Script:TxtBtnOpenDocs      = $Window.FindName('TxtBtnOpenDocs')
    $Script:TxtBtnOpenRepo      = $Window.FindName('TxtBtnOpenRepo')
    $Script:TxtBtnOpenIssues    = $Window.FindName('TxtBtnOpenIssues')
    $Script:TxtBtnOpenLicense   = $Window.FindName('TxtBtnOpenLicense')

    $Script:HelpCommandLanguage = $null

    if ($Script:BtnHelp) {
        $Script:BtnHelp.Add_Click({
            $navHelp = $Script:GuiNav['help']
            if ($navHelp) {
                $navHelp.IsChecked = $true
                $navHelp.Focus() | Out-Null
            } else {
                Show-GuiPage -Name 'help'
            }
        })
    }

    if ($Script:BtnCheckUpdate) {
        $Script:BtnCheckUpdate.Add_Click({ Start-GuiUpdateCheck -Force })
    }

    if ($Script:BtnInstallUpdate) {
        $Script:BtnInstallUpdate.Add_Click({
            $status = $Script:UpdateStatus
            if ($null -eq $status -or [string]$status.Status -ne 'Available' -or $status.Error) { return }

            $confirm = [System.Windows.MessageBox]::Show(
                ((Get-Text 'update_confirm_install') -f $status.LatestVersion),
                'PSManager', 'YesNo', 'Question')
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

            $Script:BtnInstallUpdate.IsEnabled = $false
            $package = $null
            Set-BusyState $true
            try {
                $package = Save-PSManagerUpdatePackage -Status $status
            } catch {
                $errMessage = $_.Exception.Message
                Add-Log ("ERROR: " + $errMessage)
                if ($Script:TxtHelpUpdateDetail) {
                    $Script:TxtHelpUpdateDetail.Text = ((Get-Text 'notif_update_failed') -f $errMessage)
                }
                Show-GuiToast -Title (Get-Text 'update_status_error') -Message ((Get-Text 'notif_update_failed') -f $errMessage) -Level 'Error'
                if ($Script:HelpWindow -and $Script:HelpWindow.IsVisible) {
                    $Script:BtnInstallUpdate.IsEnabled = $true
                }
                return
            } finally {
                Set-BusyState $false
            }

            if ($package) {
                try {
                    # The installer replaces the running files, so the window closes first.
                    $Script:HelpWindow.Close()
                    Start-Process -FilePath $package.InstallerPath -ArgumentList $package.Arguments
                } catch {
                    Add-Log ("ERROR: could not launch installer: " + $_.Exception.Message)
                }
            }
        })
    }

    if ($Script:BtnOpenRelease) {
        $Script:BtnOpenRelease.Add_Click({
            $url = ''
            if ($Script:UpdateStatus) { $url = [string]$Script:UpdateStatus.ReleaseUrl }
            if (-not $url) { return }
            try { Start-Process $url } catch { Add-Log ("ERROR: could not open " + $url) }
        })
    }

    $linkButtons = @(
        @{ Button = $Script:BtnOpenDocs;    Key = 'Docs' }
        @{ Button = $Script:BtnOpenRepo;    Key = 'Repository' }
        @{ Button = $Script:BtnOpenIssues;  Key = 'Issues' }
        @{ Button = $Script:BtnOpenLicense; Key = 'License' }
    )
    foreach ($entry in $linkButtons) {
        $button = $entry.Button
        if (-not $button) { continue }
        $button.Tag = $entry.Key
        $button.Add_Click({
            $key = [string]$this.Tag
            $links = Get-PSManagerHelpLinks
            if (-not $key -or -not $links.ContainsKey($key)) { return }
            $url = [string]$links[$key]
            try { Start-Process $url } catch { Add-Log ("ERROR: could not open " + $url) }
        })
    }
}

function Update-GuiHelpCommandList {
    <#
    .SYNOPSIS
        Rebuilds the command reference rows for the active language.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Language)

    if ($null -eq $Script:HelpCommandList) { return }
    $Script:HelpCommandList.Children.Clear()

    $sections = @()
    try { $sections = @(Get-PSManagerHelpSections -Language $Language) } catch { $sections = @() }

    $textBrush = $Script:HelpWindow.FindResource('TextBrush')
    $dimBrush = $Script:HelpWindow.FindResource('TextDimBrush')
    $accentBrush = $Script:HelpWindow.FindResource('AccentBrush')
    $monoFont = $Script:HelpWindow.FindResource('MonoFont')

    foreach ($section in $sections) {
        $caption = [System.Windows.Controls.TextBlock]::new()
        $caption.Text = [string]$section.Title
        $caption.FontSize = 11
        $caption.FontWeight = [System.Windows.FontWeights]::SemiBold
        $caption.Foreground = $dimBrush
        $caption.Margin = [System.Windows.Thickness]::new(0, 10, 0, 4)
        $null = $Script:HelpCommandList.Children.Add($caption)

        foreach ($item in $section.Items) {
            $row = [System.Windows.Controls.StackPanel]::new()
            $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)

            $usage = [System.Windows.Controls.TextBlock]::new()
            $usage.Text = [string]$item.Usage
            $usage.FontFamily = $monoFont
            $usage.FontSize = 12
            $usage.Foreground = $accentBrush
            $usage.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $null = $row.Children.Add($usage)

            $desc = [System.Windows.Controls.TextBlock]::new()
            $desc.Text = [string]$item.Desc
            $desc.FontSize = 12
            $desc.Foreground = $textBrush
            $desc.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $desc.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
            $null = $row.Children.Add($desc)

            $null = $Script:HelpCommandList.Children.Add($row)
        }
    }
}

function Update-GuiHelpPage {
    <#
    .SYNOPSIS
        Localizes the Help page and refreshes its update status.
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $Script:HelpWindow) { return }

    $lang = Get-GuiLanguage

    if ($Script:TxtHelpTitle) { $Script:TxtHelpTitle.Text = Get-Text 'help_title' }
    if ($Script:TxtHelpSubtitle) { $Script:TxtHelpSubtitle.Text = Get-Text 'help_subtitle' }
    if ($Script:TxtHelpIntro) { $Script:TxtHelpIntro.Text = Get-Text 'help_intro' }
    if ($Script:LblHelpQuickStart) { $Script:LblHelpQuickStart.Text = Get-Text 'help_quick_title' }
    if ($Script:TxtHelpQuickDefault) { $Script:TxtHelpQuickDefault.Text = Get-Text 'help_quick_default' }
    if ($Script:TxtHelpQuickDefaultDesc) { $Script:TxtHelpQuickDefaultDesc.Text = Get-Text 'help_quick_default_desc' }
    if ($Script:TxtHelpQuickSync) { $Script:TxtHelpQuickSync.Text = Get-Text 'help_quick_sync' }
    if ($Script:TxtHelpQuickSyncDesc) { $Script:TxtHelpQuickSyncDesc.Text = Get-Text 'help_quick_sync_desc' }
    if ($Script:TxtHelpQuickUpdate) { $Script:TxtHelpQuickUpdate.Text = Get-Text 'help_quick_update' }
    if ($Script:TxtHelpQuickUpdateDesc) { $Script:TxtHelpQuickUpdateDesc.Text = Get-Text 'help_quick_update_desc' }
    if ($Script:LblHelpCommands) { $Script:LblHelpCommands.Text = Get-Text 'help_commands_title' }
    if ($Script:LblHelpUpdate) { $Script:LblHelpUpdate.Text = Get-Text 'help_update_title' }
    if ($Script:LblHelpShortcuts) { $Script:LblHelpShortcuts.Text = Get-Text 'help_shortcuts_title' }
    if ($Script:TxtHelpShortcuts) { $Script:TxtHelpShortcuts.Text = Get-Text 'help_shortcuts' }
    if ($Script:LblHelpLinks) { $Script:LblHelpLinks.Text = Get-Text 'help_links_title' }
    if ($Script:LblHelpAbout) { $Script:LblHelpAbout.Text = Get-Text 'help_about_title' }
    if ($Script:TxtCapCheckUpdate) { $Script:TxtCapCheckUpdate.Text = Get-Text 'menu_update_check_desc' }

    $version = ''
    try { $version = [string](Get-Module PSManager).Version } catch { $version = '' }
    if ($Script:TxtHelpVersion) { $Script:TxtHelpVersion.Text = 'v' + $version }
    if ($Script:TxtHelpAbout) {
        $Script:TxtHelpAbout.Text = ((Get-Text 'help_about_version') -f $version) + [Environment]::NewLine + (Get-Text 'help_about_build')
    }

    # Set the inner label, not Button.Content: replacing the content drops the vector icon.
    if ($Script:TxtBtnCheckUpdate) { $Script:TxtBtnCheckUpdate.Text = Get-Text 'help_btn_check' }
    if ($Script:TxtBtnInstallUpdate) { $Script:TxtBtnInstallUpdate.Text = Get-Text 'help_btn_install' }
    if ($Script:TxtBtnOpenRelease) { $Script:TxtBtnOpenRelease.Text = Get-Text 'help_btn_release' }
    if ($Script:TxtBtnOpenDocs) { $Script:TxtBtnOpenDocs.Text = Get-Text 'help_link_docs' }
    if ($Script:TxtBtnOpenRepo) { $Script:TxtBtnOpenRepo.Text = Get-Text 'help_link_repo' }
    if ($Script:TxtBtnOpenIssues) { $Script:TxtBtnOpenIssues.Text = Get-Text 'help_link_issues' }
    if ($Script:TxtBtnOpenLicense) { $Script:TxtBtnOpenLicense.Text = Get-Text 'help_link_license' }

    $helpTip = Get-Text 'gui_btn_help_tip'
    if ($Script:BtnHelp) {
        $Script:BtnHelp.ToolTip = $helpTip
        [System.Windows.Automation.AutomationProperties]::SetName($Script:BtnHelp, [string]$helpTip)
    }

    # Rebuilding the whole list on every dashboard refresh would fight the user's scroll
    # position; the catalog only changes when the language does.
    if ($Script:HelpCommandLanguage -ne $lang) {
        Update-GuiHelpCommandList -Language $lang
        $Script:HelpCommandLanguage = $lang
    }

    if (-not $Script:UpdateJob) {
        $cached = $null
        try { $cached = Get-PSManagerUpdateStatus -CacheOnly } catch { $cached = $null }
        Update-GuiUpdateUi -Status $cached
    }
}
