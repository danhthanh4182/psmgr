#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Launcher - Shell Launching & GUI Dispatcher
#>

function Start-QuickShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateSet('PS7', 'PS7-Admin', 'PS5', 'PS5-Admin', 'Split')]
        [string]$Target
    )

    switch ($Target) {
        'PS7' {
            if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
                Start-Process wt.exe -ArgumentList '-p "PowerShell 7"'
            } else {
                Start-Process pwsh.exe
            }
        }
        'PS7-Admin' {
            if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
                Start-Process wt.exe -ArgumentList '-p "PowerShell 7"' -Verb RunAs
            } else {
                Start-Process pwsh.exe -Verb RunAs
            }
        }
        'PS5' {
            if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
                Start-Process wt.exe -ArgumentList '-p "Windows PowerShell"'
            } else {
                Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            }
        }
        'PS5-Admin' {
            if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
                Start-Process wt.exe -ArgumentList '-p "Windows PowerShell"' -Verb RunAs
            } else {
                Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs
            }
        }
        'Split' {
            if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
                # Single string: PowerShell passes it as one argv element to wt.exe,
                # which parses ';' itself as the command separator.
                Start-Process wt.exe -ArgumentList 'new-tab -p "PowerShell 7" ; split-pane -p "Windows PowerShell"'
            } else {
                Start-Process pwsh.exe
                Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            }
        }
    }
}

function Start-DesktopGUI {
    [CmdletBinding()]
    param()

    $repoRoot = if ($Script:ROOT_PATH) { $Script:ROOT_PATH } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $guiScript = Join-Path $repoRoot "gui.ps1"
    # Prefer PS 7 when present (faster startup, native UTF-8); PS 5.1 still works
    $engine = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    Start-Process $engine -ArgumentList "-WindowStyle Hidden -NoProfile -STA -ExecutionPolicy Bypass -File `"$guiScript`""
}
