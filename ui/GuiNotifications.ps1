#Requires -Version 5.1
<#
.SYNOPSIS
    GUI notification center, unread badge, in-app toast and the PSManager update pipeline.
.DESCRIPTION
    The in-app surfaces are authoritative; native Windows toasts are emitted once by
    Add-PSManagerNotification so a GUI refresh never duplicates one. The update check runs in
    a background job and is polled by a DispatcherTimer, so the window never freezes on the
    network and startup only reads the cache.
#>

function Initialize-GuiNotifications {
    <#
    .SYNOPSIS
        Resolves the notification/toast elements and wires their handlers.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Windows.Window]$Window)

    $Script:NotifWindow       = $Window
    $Script:BtnNotifications  = $Window.FindName('BtnNotifications')
    $Script:NotifBadge        = $Window.FindName('NotifBadge')
    $Script:TxtNotifBadge     = $Window.FindName('TxtNotifBadge')
    $Script:NotifPanel        = $Window.FindName('NotifPanel')
    $Script:NotifList         = $Window.FindName('NotifList')
    $Script:TxtNotifEmpty     = $Window.FindName('TxtNotifEmpty')
    $Script:BtnNotifClear     = $Window.FindName('BtnNotifClear')
    $Script:BtnNotifClose     = $Window.FindName('BtnNotifClose')
    $Script:TxtNotifTitle     = $Window.FindName('TxtNotifTitle')
    $Script:ToastPanel        = $Window.FindName('ToastPanel')
    $Script:TxtToastTitle     = $Window.FindName('TxtToastTitle')
    $Script:TxtToastMessage   = $Window.FindName('TxtToastMessage')
    $Script:BtnToastClose     = $Window.FindName('BtnToastClose')

    $Script:ToastTimer  = $null
    $Script:UpdateJob   = $null
    $Script:UpdateTimer = $null
    if (-not (Test-Path Variable:Script:UpdateStatus)) { $Script:UpdateStatus = $null }

    if ($Script:BtnNotifications) {
        $Script:BtnNotifications.Add_Click({
            if ($Script:NotifPanel -and $Script:NotifPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
                Hide-GuiNotificationCenter
            } else {
                Show-GuiNotificationCenter
            }
        })
    }

    if ($Script:BtnNotifClear) {
        $Script:BtnNotifClear.Add_Click({
            $null = Clear-PSManagerNotifications
            Update-GuiNotificationBadge
            Show-GuiNotificationCenter
            if ($Script:TxtNotifEmpty) { $Script:TxtNotifEmpty.Visibility = 'Visible' }
        })
    }

    if ($Script:BtnNotifClose) {
        $Script:BtnNotifClose.Add_Click({ Hide-GuiNotificationCenter })
    }

    if ($Script:BtnToastClose) {
        $Script:BtnToastClose.Add_Click({
            if ($Script:ToastTimer) { $Script:ToastTimer.Stop(); $Script:ToastTimer = $null }
            if ($Script:ToastPanel) { $Script:ToastPanel.Visibility = 'Collapsed' }
        })
    }

    # Esc closes the overlays first, matching the "Esc close dialogs" shortcut in the help text.
    $Window.Add_PreviewKeyDown({
        $keyArgs = $_
        if ($keyArgs.Key -ne [System.Windows.Input.Key]::Escape) { return }
        if ($Script:NotifPanel -and $Script:NotifPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
            Hide-GuiNotificationCenter
            $keyArgs.Handled = $true
            return
        }
        if ($Script:ToastPanel -and $Script:ToastPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
            if ($Script:ToastTimer) { $Script:ToastTimer.Stop(); $Script:ToastTimer = $null }
            $Script:ToastPanel.Visibility = 'Collapsed'
            $keyArgs.Handled = $true
        }
    })
}

function Update-GuiNotificationBadge {
    <#
    .SYNOPSIS
        Refreshes the unread badge and localizes the notification chrome.
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $Script:NotifWindow) { return }

    try {
        $unread = @(Get-PSManagerNotifications -UnreadOnly).Count
    } catch {
        $unread = 0
    }

    if ($Script:TxtNotifBadge) { $Script:TxtNotifBadge.Text = [string]$unread }
    if ($Script:NotifBadge) {
        $Script:NotifBadge.Visibility = if ($unread -gt 0) { 'Visible' } else { 'Collapsed' }
    }

    $tip = Get-Text 'gui_btn_notifications_tip'
    $unreadSuffix = if ($unread -gt 0) { " (" + ((Get-Text 'notif_center_unread') -f $unread) + ")" } else { "" }
    if ($Script:BtnNotifications) {
        $Script:BtnNotifications.ToolTip = $tip
        [System.Windows.Automation.AutomationProperties]::SetName($Script:BtnNotifications, ($tip + $unreadSuffix))
    }
    if ($Script:TxtNotifTitle) { $Script:TxtNotifTitle.Text = Get-Text 'notif_center_title' }
    if ($Script:TxtNotifEmpty) { $Script:TxtNotifEmpty.Text = Get-Text 'notif_center_empty' }
    if ($Script:BtnNotifClear) { $Script:BtnNotifClear.Content = Get-Text 'notif_center_clear' }
    foreach ($button in @($Script:BtnNotifClose, $Script:BtnToastClose)) {
        if ($button) {
            [System.Windows.Automation.AutomationProperties]::SetName($button, (Get-Text 'notif_center_close'))
        }
    }
}

function New-GuiNotificationRow {
    <#
    .SYNOPSIS
        Builds one notification row: title, message and local time.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Item)

    $panel = [System.Windows.Controls.StackPanel]::new()

    $title = [System.Windows.Controls.TextBlock]::new()
    $title.Text = [string]$Item.Title
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    $title.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $title.Foreground = $Script:NotifWindow.FindResource('TextBrush')
    $null = $panel.Children.Add($title)

    $message = [System.Windows.Controls.TextBlock]::new()
    $message.Text = [string]$Item.Message
    $message.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $message.FontSize = 12
    $message.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    $message.Foreground = $Script:NotifWindow.FindResource('TextDimBrush')
    $null = $panel.Children.Add($message)

    $time = [System.Windows.Controls.TextBlock]::new()
    $time.Text = [string]$Item.Time
    $time.FontSize = 11
    $time.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
    $time.Foreground = $Script:NotifWindow.FindResource('TextDimBrush')
    $null = $panel.Children.Add($time)

    return $panel
}

function Show-GuiNotificationCenter {
    <#
    .SYNOPSIS
        Rebuilds and shows the notification center, marking everything read.
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $Script:NotifPanel) { return }

    if ($Script:NotifList) {
        $Script:NotifList.Children.Clear()
        $views = @()
        try { $views = @(Get-PSManagerNotificationView -Language (Get-GuiLanguage) -Limit 30) } catch { $views = @() }

        foreach ($item in $views) {
            $row = New-GuiNotificationRow -Item $item
            if ($item.Url) {
                $button = [System.Windows.Controls.Button]::new()
                $button.Style = $Script:NotifWindow.FindResource('BtnRow')
                $button.HorizontalContentAlignment = [System.Windows.HorizontalAlignment]::Left
                $button.Content = $row
                $button.Tag = [string]$item.Url
                $button.ToolTip = [string]$item.Url
                [System.Windows.Automation.AutomationProperties]::SetName($button, ([string]$item.Title + ' - ' + (Get-Text 'notif_center_open')))
                $button.Add_Click({
                    $target = [string]$this.Tag
                    if ($target) {
                        try { Start-Process $target } catch { Add-Log ("ERROR: could not open " + $target) }
                    }
                })
                $null = $Script:NotifList.Children.Add($button)
            } else {
                $border = [System.Windows.Controls.Border]::new()
                $border.Padding = [System.Windows.Thickness]::new(12, 10, 12, 10)
                $border.Child = $row
                $null = $Script:NotifList.Children.Add($border)
            }
        }

        if ($Script:TxtNotifEmpty) {
            $Script:TxtNotifEmpty.Visibility = if ($views.Count -eq 0) { 'Visible' } else { 'Collapsed' }
        }
    }

    $null = Set-PSManagerNotificationRead -All
    Update-GuiNotificationBadge
    $Script:NotifPanel.Visibility = 'Visible'
    if ($Script:NotifList -and $Script:NotifList.Children.Count -gt 0) {
        $first = $Script:NotifList.Children[0]
        if ($first -is [System.Windows.Controls.Button]) {
            $first.Focus() | Out-Null
        } elseif ($Script:BtnNotifClose) {
            $Script:BtnNotifClose.Focus() | Out-Null
        }
    } elseif ($Script:BtnNotifClose) {
        $Script:BtnNotifClose.Focus() | Out-Null
    }
}

function Hide-GuiNotificationCenter {
    <#
    .SYNOPSIS
        Collapses the notification center and restores focus to the trigger button.
    #>
    [CmdletBinding()]
    param()

    if ($Script:NotifPanel) {
        $wasVisible = ($Script:NotifPanel.Visibility -eq [System.Windows.Visibility]::Visible)
        $Script:NotifPanel.Visibility = 'Collapsed'
        if ($wasVisible -and $Script:BtnNotifications) {
            $Script:BtnNotifications.Focus() | Out-Null
        }
    }
}

function Show-GuiToast {
    <#
    .SYNOPSIS
        Shows the transient in-app toast (native toasts are emitted by the store).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = 'Info'
    )

    if ($null -eq $Script:ToastPanel) { return }

    $brushKey = switch ($Level) {
        'Success' { 'OkBrush' }
        'Warning' { 'WarnBrush' }
        'Error'   { 'DangerBrush' }
        default   { 'TextBrush' }
    }

    if ($Script:TxtToastTitle) {
        $Script:TxtToastTitle.Text = $Title
        $Script:TxtToastTitle.Foreground = $Script:NotifWindow.FindResource($brushKey)
    }
    if ($Script:TxtToastMessage) { $Script:TxtToastMessage.Text = $Message }

    $Script:ToastPanel.Visibility = 'Visible'

    if ($Script:ToastTimer) { $Script:ToastTimer.Stop(); $Script:ToastTimer = $null }
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromSeconds(6)
    $timer.Add_Tick({
        if ($Script:ToastTimer) { $Script:ToastTimer.Stop() }
        $Script:ToastTimer = $null
        if ($Script:ToastPanel) { $Script:ToastPanel.Visibility = 'Collapsed' }
    })
    $Script:ToastTimer = $timer
    $timer.Start()
}

function Update-GuiUpdateUi {
    <#
    .SYNOPSIS
        Renders one PSManager release status on the Help page.
    #>
    [CmdletBinding()]
    param([object]$Status)

    $currentVersion = ''
    try { $currentVersion = [string](Get-Module PSManager).Version } catch { $currentVersion = '' }

    if ($null -eq $Status -or -not $Status.PSObject.Properties['Status']) {
        $Status = [pscustomobject]@{
            CurrentVersion  = $currentVersion
            LatestVersion   = $null
            UpdateAvailable = $false
            Status          = 'Unknown'
            ReleaseName     = ''
            ReleaseUrl      = ''
            PublishedAt     = ''
            CheckedAt       = (Get-Date)
            FromCache       = $false
            Stale           = $false
            Error           = $null
            Assets          = @()
        }
    }

    $Script:UpdateStatus = $Status

    $statusText = Get-Text 'update_status_unknown'
    $detailText = Get-Text 'help_update_not_checked'
    $hasError = [bool]$Status.Error

    if ($hasError) {
        $statusText = Get-Text 'update_status_error'
        $detailText = (Get-Text 'help_update_error') -f $Status.Error
    } else {
        switch ([string]$Status.Status) {
            'Available' {
                $statusText = Get-Text 'update_status_available'
                $detailText = (Get-Text 'help_update_available') -f $Status.LatestVersion
            }
            'Current' {
                $statusText = Get-Text 'update_status_current'
                $detailText = Get-Text 'help_update_up_to_date'
            }
            'Unknown' {
                $statusText = Get-Text 'update_status_unknown'
                $detailText = Get-Text 'help_update_not_checked'
            }
            'Disabled' {
                $statusText = Get-Text 'update_status_disabled'
                $detailText = Get-Text 'help_update_not_checked'
            }
        }
    }

    if ($Script:TxtHelpUpdateStatus) { $Script:TxtHelpUpdateStatus.Text = $statusText }
    if ($Script:TxtHelpUpdateDetail) { $Script:TxtHelpUpdateDetail.Text = $detailText }

    $checkedText = Get-Text 'help_update_not_checked'
    $hasRealCheck = ($Status.CheckedAt -and [string]$Status.Status -in @('Available', 'Current', 'Error'))
    if ($hasRealCheck) {
        try { $checkedText = (Get-Text 'update_checked') + ': ' + ([datetime]$Status.CheckedAt).ToString('yyyy-MM-dd HH:mm') } catch { $checkedText = [string]$Status.CheckedAt }
    }
    if ($Script:TxtHelpUpdateChecked) { $Script:TxtHelpUpdateChecked.Text = $checkedText }

    if ($Script:BtnInstallUpdate) {
        $Script:BtnInstallUpdate.IsEnabled = ([string]$Status.Status -eq 'Available' -and -not $hasError)
    }
    if ($Script:BtnOpenRelease) {
        $Script:BtnOpenRelease.IsEnabled = [bool]$Status.ReleaseUrl
    }
}

function Start-GuiUpdateCheck {
    <#
    .SYNOPSIS
        Starts a background release check (or renders the cache when checks are disabled).
    .DESCRIPTION
        Never blocks the UI thread: the network call runs in a PowerShell job and a 750 ms
        DispatcherTimer polls it. Installation is never triggered from here.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    if ($env:PSMGR_DISABLE_UPDATE_CHECK -eq '1' -and -not $Force) {
        $cached = $null
        try { $cached = Get-PSManagerUpdateStatus -CacheOnly } catch { $cached = $null }
        Update-GuiUpdateUi -Status $cached
        return
    }

    if ($Script:UpdateJob) { return }

    if ($Script:BtnCheckUpdate) { $Script:BtnCheckUpdate.IsEnabled = $false }
    if ($Script:TxtHelpUpdateStatus) { $Script:TxtHelpUpdateStatus.Text = Get-Text 'update_check_title' }

    # Render cached status immediately so UI is responsive
    if (-not $Force) {
        $cached = $null
        try { $cached = Get-PSManagerUpdateStatus -CacheOnly } catch { $cached = $null }
        if ($null -ne $cached -and $cached.Status -ne 'Unknown') {
            Update-GuiUpdateUi -Status $cached
        }
    }

    try {
        $forceCheck = [bool]$Force
        $Script:UpdateJob = Start-Job -ScriptBlock {
            Import-Module (Join-Path $using:scriptRoot 'PSManager.psd1') -Force
            if ($using:forceCheck) {
                Get-PSManagerUpdateStatus -Force
            } else {
                Get-PSManagerUpdateStatus
            }
        }
    } catch {
        $Script:UpdateJob = $null
        if ($Script:BtnCheckUpdate) { $Script:BtnCheckUpdate.IsEnabled = $true }
        Add-Log ("[!] update check failed: " + $_.Exception.Message)
        return
    }

    if ($Script:UpdateTimer) { $Script:UpdateTimer.Stop() }
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(750)
    $timer.Add_Tick({
        $job = $Script:UpdateJob
        if ($null -eq $job) {
            if ($Script:UpdateTimer) { $Script:UpdateTimer.Stop() }
            $Script:UpdateTimer = $null
            return
        }
        if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { return }

        if ($Script:UpdateTimer) { $Script:UpdateTimer.Stop() }
        $Script:UpdateTimer = $null

        $status = $null
        $failure = ''
        try {
            $status = Receive-Job -Job $job -ErrorAction Stop | Select-Object -Last 1
        } catch {
            $failure = $_.Exception.Message
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $Script:UpdateJob = $null
        if ($Script:BtnCheckUpdate) { $Script:BtnCheckUpdate.IsEnabled = $true }

        Update-GuiUpdateUi -Status $status
        if ($null -ne $status -and $status.UpdateAvailable -and -not $status.Error) {
            $added = Add-PSManagerUpdateNotification -Status $status
            if ($added -and $added.Added) {
                Show-GuiToast -Title (Get-Text 'notif_update_title') `
                    -Message ((Get-Text 'notif_update_body') -f $status.LatestVersion, $status.CurrentVersion) -Level 'Info'
            }
        }
        Update-GuiNotificationBadge
        if ($null -eq $status) {
            $reason = if ($failure) { $failure } else { 'no result' }
            Add-Log ("[!] update check failed: " + $reason)
        }
    })
    $Script:UpdateTimer = $timer
    $timer.Start()
}

function Add-GuiActionNotification {
    <#
    .SYNOPSIS
        Records the outcome of one CLI action as a notification.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Header,
        [bool]$Success = $true,
        [int]$ExitCode = 0
    )

    try {
        if ($Success) {
            $null = Add-PSManagerNotification -Kind 'Action' -Level 'Success' `
                -TitleKey 'notif_action_title' -MessageKey 'notif_action_body' `
                -Params @($Header, $ExitCode) -Silent
            $toastTitle = (Get-Text 'notif_action_title') -f $Header
            $toastMessage = (Get-Text 'notif_action_body') -f $Header, $ExitCode
            $level = 'Success'
        } else {
            $null = Add-PSManagerNotification -Kind 'Action' -Level 'Error' `
                -TitleKey 'notif_action_failed_title' -MessageKey 'notif_action_failed_body' `
                -Params @($Header, $ExitCode) -Silent
            $toastTitle = (Get-Text 'notif_action_failed_title') -f $Header
            $toastMessage = (Get-Text 'notif_action_failed_body') -f $Header, $ExitCode
            $level = 'Error'
        }
        if ($Script:BtnNotifications) {
            Show-GuiToast -Title $toastTitle -Message $toastMessage -Level $level
        }
        Update-GuiNotificationBadge
        if ($Script:NotifPanel -and $Script:NotifPanel.Visibility -eq [System.Windows.Visibility]::Visible) {
            Show-GuiNotificationCenter
        }
    } catch {
        Add-Log ("[!] notification failed: " + $_.Exception.Message)
    }
}
