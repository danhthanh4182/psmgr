#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Core - Console & Stream Encoding Configuration
#>

function Initialize-ConsoleEncoding {
    [CmdletBinding()]
    param()

    try {
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $null = & chcp.com 65001 2>&1
        }
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
        $global:OutputEncoding    = [System.Text.Encoding]::UTF8
    } catch {
        # Fallback if console handle is redirected
    }
}
