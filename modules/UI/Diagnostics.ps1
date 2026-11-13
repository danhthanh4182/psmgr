#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager UI - System Diagnostics & Reporting Screen
#>

function Show-DiagnosticsScreen {
    [CmdletBinding()]
    param()

    $status = Get-PSManagerStatus
    try { Clear-Host } catch {}

    Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "================================================================================")
    Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) ("                   " + (Get-I18nText "diag_title") + "                  "))
    Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "================================================================================")
    Write-Host ""

    Write-Host (Color-Text $Script:THEME.Bold ("  " + (Get-I18nText "diag_session")))
    Write-Host ("    Version:       " + (Color-Text $Script:THEME.Green $status.CurrentHostVersion))
    Write-Host ("    Edition:       " + (Color-Text $Script:THEME.White $status.CurrentHostEdition))
    Write-Host ("    Process:       " + (Color-Text $Script:THEME.White ((Get-Process -Id $PID).Path)))
    Write-Host ("    Bitness:       " + ([Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')))

    Write-Host ""
    Write-Host (Color-Text $Script:THEME.Bold ("  " + (Get-I18nText "diag_installed")))
    if ($status.Installations.PS7) {
        Write-Host ("    " + (Color-Badge $Script:THEME.Green "+") + " " + (Color-Text $Script:THEME.Bold "PowerShell 7 (pwsh): ") + "v" + $status.Installations.PS7.Version)
        Write-Host ("        Path: " + $status.Installations.PS7.Path)
    } else {
        Write-Host ("    " + (Color-Badge $Script:THEME.Red "-") + " PowerShell 7: Not Installed")
    }

    if ($status.Installations.PS5) {
        Write-Host ("    " + (Color-Badge $Script:THEME.Green "+") + " " + (Color-Text $Script:THEME.Bold "Windows PowerShell 5.1: ") + "v" + $status.Installations.PS5.Version)
        Write-Host ("        Path: " + $status.Installations.PS5.Path)
    }

    if ($status.Installations.PS7Preview) {
        Write-Host ("    " + (Color-Badge $Script:THEME.Purple "+") + " " + (Color-Text $Script:THEME.Bold "PowerShell Preview: ") + $status.Installations.PS7Preview.Version)
    }

    Write-Host ""
    Write-Host (Color-Text $Script:THEME.Bold ("  " + (Get-I18nText "diag_source")))
    Write-Host ("    Active Source: " + (Color-Badge $Script:THEME.Green $status.UpdateSource.ToUpper()) + " (" + $status.TargetPackage.SourceName + ")")
    Write-Host ("    Channel:       " + (Color-Badge $Script:THEME.Cyan $status.Channel.ToUpper()))
    Write-Host ("    Target ID:     " + (Color-Text $Script:THEME.White $status.TargetPackage.PackageId))

    Write-Host ""
    Write-Host (Color-Text $Script:THEME.Bold ("  " + (Get-I18nText "diag_config")))
    $wtTag = if ($status.WTDefaultIsPS7) { (Color-Badge $Script:THEME.Green "PowerShell 7") } elseif ($status.WTDefaultIsPS5) { (Color-Badge $Script:THEME.Yellow "PowerShell 5.1") } else { (Color-Badge $Script:THEME.White "Other") }
    Write-Host ("    Windows Terminal Default Profile: " + $wtTag + " (Guid: " + $status.WTDefaultProfile + ")")

    $hostTag = if ($status.IsWTDefaultHost) { (Color-Badge $Script:THEME.Green "Windows Terminal") } else { (Color-Badge $Script:THEME.Yellow "Windows Console Host (Legacy)") }
    Write-Host ("    Windows 11 Default Terminal App:  " + $hostTag)

    $shimTag = if ($status.ShimActive) { (Color-Badge $Script:THEME.Green "Active -> pwsh") } else { (Color-Badge $Script:THEME.Gray "Inactive (runs native 5.1)") }
    Write-Host ("    PATH 'powershell' Command Shim:   " + $shimTag)

    $vsTag = if ($status.VSCodeDefaultPS7) { (Color-Badge $Script:THEME.Green "PowerShell 7") } else { (Color-Badge $Script:THEME.Yellow "Default/PS5") }
    Write-Host ("    VS Code Default Terminal Profile: " + $vsTag)

    $menuTag = if ($status.ContextMenuInstalled) { (Color-Badge $Script:THEME.Green "Installed") } else { (Color-Badge $Script:THEME.Gray "Not installed") }
    Write-Host ("    Explorer 'Open in PS7' Menu:      " + $menuTag)

    Write-Host ""
    Write-Host (Color-Text $Script:THEME.Gray "--------------------------------------------------------------------------------")
    Write-Host (Get-I18nText "press_key")
    try {
        if (-not [Console]::IsInputRedirected) {
            $null = [Console]::ReadKey($true)
        }
    } catch {}
}
