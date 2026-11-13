#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Package - Installation & Update Operations
#>

function Invoke-PowerShellUpdate {
    [CmdletBinding()]
    param()

    $target = Get-SourcePackageTarget
    Write-Host ""
    Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "==> Checking and updating PowerShell...")
    Write-Host ("    Target:  " + (Color-Text $Script:THEME.Green $target.DisplayName))
    Write-Host ("    Source:  " + (Color-Text $Script:THEME.Yellow $target.SourceName))
    Write-Host ("    Package: " + (Color-Text $Script:THEME.White $target.PackageId))
    Write-Host ""

    if ($target.CommandType -eq "github") {
        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -Headers @{ 'User-Agent' = 'PSManager' } -TimeoutSec 10
            Write-Host ("    Latest GitHub Release: " + (Color-Text $Script:THEME.Green $rel.tag_name) + " (" + $rel.name + ")")
            Write-Host ("    Published:             " + $rel.published_at)
            Write-Host ("    Release URL:           " + $rel.html_url)
            
            $msiAsset = $rel.assets | Where-Object { $_.name -match 'win-x64\.msi$' } | Select-Object -First 1
            if ($msiAsset) {
                Write-Host ("    Installer Asset:       " + $msiAsset.name + " (" + [math]::Round($msiAsset.size / 1MB, 2) + " MB)")
                $choice = Read-Host "`nDownload and install now? (y/N)"
                if ($choice -match '^[Yy]$') {
                    $tmpMsi = "$env:TEMP\$($msiAsset.name)"
                    Write-Host "Downloading $($msiAsset.browser_download_url)..."
                    Invoke-WebRequest -Uri $msiAsset.browser_download_url -OutFile $tmpMsi
                    Write-Host "Running MSI installer..."
                    Start-Process msiexec.exe -ArgumentList "/i `"$tmpMsi`" /passive" -Wait
                    Write-Host (Color-Text $Script:THEME.Green "Installation completed!")
                }
            }
        } catch {
            Write-Host (Color-Text $Script:THEME.Red "GitHub check failed: $($_.Exception.Message)")
        }
    } else {
        winget upgrade --id $target.PackageId --source $target.Source --accept-source-agreements --accept-package-agreements
    }
}

function Invoke-PowerShellInstall {
    [CmdletBinding()]
    param()

    $target = Get-SourcePackageTarget
    Write-Host ""
    Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "==> Installing PowerShell via $($target.SourceName)...")
    Write-Host ("    Target:  " + (Color-Text $Script:THEME.Green $target.DisplayName))
    Write-Host ("    Package: " + (Color-Text $Script:THEME.White $target.PackageId))
    Write-Host ""

    if ($target.CommandType -eq "github") {
        Invoke-PowerShellUpdate
    } else {
        winget install --id $target.PackageId --source $target.Source --accept-source-agreements --accept-package-agreements
    }
}
