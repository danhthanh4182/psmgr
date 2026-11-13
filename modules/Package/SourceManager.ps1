#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Package - Update Source & Channel Management
#>

function Get-SourcePackageTarget {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string]$Source = $null,

        [Parameter()]
        [string]$Channel = $null
    )

    $cfg = Get-PSManagerConfig
    $s = if ($Source) { $Source.ToLower() } else { $cfg.updateSource.ToLower() }
    $c = if ($Channel) { $Channel.ToLower() } else { $cfg.channel.ToLower() }
    
    $info = [ordered]@{
        Source      = $s
        Channel     = $c
        PackageId   = ""
        SourceName  = ""
        CommandType = "winget"
        DisplayName = ""
    }

    switch ($s) {
        'msstore' {
            $info.SourceName  = "msstore (Microsoft Store)"
            $info.CommandType = "winget"
            switch ($c) {
                'preview' {
                    $info.PackageId   = "9P95ZZKTNRN4"
                    $info.DisplayName = "PowerShell Preview (Microsoft Store)"
                }
                'lts' {
                    $info.PackageId   = "9MXBK0PFV7PJ"
                    $info.DisplayName = "PowerShell LTS (Microsoft Store)"
                }
                default {
                    $info.PackageId   = "9MZ1SNWT0N5D"
                    $info.DisplayName = "PowerShell (Microsoft Store)"
                }
            }
        }
        'github' {
            $info.SourceName  = "GitHub Direct Releases"
            $info.CommandType = "github"
            $info.PackageId   = "PowerShell/PowerShell"
            $info.DisplayName = "PowerShell Official GitHub Release"
        }
        default { # winget
            $info.Source      = "winget"
            $info.SourceName  = "winget (Community Catalog)"
            $info.CommandType = "winget"
            switch ($c) {
                'preview' {
                    $info.PackageId   = "Microsoft.PowerShell.Preview"
                    $info.DisplayName = "Microsoft.PowerShell.Preview"
                }
                default {
                    $info.PackageId   = "Microsoft.PowerShell"
                    $info.DisplayName = "Microsoft.PowerShell"
                }
            }
        }
    }

    return [pscustomobject]$info
}

function Show-SourceMenu {
    [CmdletBinding()]
    param()

    $inSubmenu = $true
    while ($inSubmenu) {
        $cfg = Get-PSManagerConfig
        $target = Get-SourcePackageTarget
        try { Clear-Host } catch {}

        Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "================================================================================")
        Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) ("                   " + (Get-I18nText "source_title") + "                  "))
        Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "================================================================================")
        Write-Host ""
        Write-Host ("  Active Source:     " + (Color-Badge $Script:THEME.Green $cfg.updateSource.ToUpper()) + " (" + $target.SourceName + ")")
        Write-Host ("  Release Channel:   " + (Color-Badge $Script:THEME.Cyan $cfg.channel.ToUpper()) + " (" + $target.PackageId + ")")
        Write-Host ""
        Write-Host (Color-Text $Script:THEME.Bold "  AVAILABLE ACTIONS:")
        Write-Host ("    " + (Color-Text $Script:THEME.Yellow "[1]") + " Set source to " + (Color-Text $Script:THEME.Bold "winget") + " (Community Catalog: Microsoft.PowerShell)")
        Write-Host ("    " + (Color-Text $Script:THEME.Yellow "[2]") + " Set source to " + (Color-Text $Script:THEME.Bold "msstore") + " (Microsoft Store: 9MZ1SNWT0N5D)")
        Write-Host ("    " + (Color-Text $Script:THEME.Yellow "[3]") + " Set source to " + (Color-Text $Script:THEME.Bold "github") + " (Direct GitHub Releases)")
        Write-Host ("    " + (Color-Text $Script:THEME.Yellow "[4]") + " Switch Channel (current: " + (Color-Text $Script:THEME.Cyan $cfg.channel) + " -> toggle stable / preview / lts)")
        Write-Host ("    " + (Color-Text $Script:THEME.Yellow "[5]") + " Sync & Update Winget Sources (" + (Color-Text $Script:THEME.Gray "winget source update") + ")")
        Write-Host ("    " + (Color-Text $Script:THEME.Yellow "[6]") + " Add Custom Winget Source (" + (Color-Text $Script:THEME.Gray "winget source add") + ")")
        Write-Host ("    " + (Color-Text $Script:THEME.Yellow "[7]") + " List All Registered Sources (" + (Color-Text $Script:THEME.Gray "winget source list") + ")")
        Write-Host ("    " + (Color-Text $Script:THEME.Yellow "[8]") + " Reset Winget Sources to Default (" + (Color-Text $Script:THEME.Gray "winget source reset") + ")")
        Write-Host ("    " + (Color-Text $Script:THEME.Gray "[0/B]") + " Back to Main Menu")
        Write-Host ""
        Write-Host (Color-Text $Script:THEME.Gray "--------------------------------------------------------------------------------")

        $opt = Read-Host "Choose an option [0-8]"
        switch ($opt) {
            '1' {
                Set-PSManagerConfig -Source "winget" | Out-Null
                Write-Host (Color-Text $Script:THEME.Green "`n[OK] Switched update source to 'winget' (Community Catalog)")
                Start-Sleep -Milliseconds 600
            }
            '2' {
                Set-PSManagerConfig -Source "msstore" | Out-Null
                Write-Host (Color-Text $Script:THEME.Green "`n[OK] Switched update source to 'msstore' (Microsoft Store)")
                Start-Sleep -Milliseconds 600
            }
            '3' {
                Set-PSManagerConfig -Source "github" | Out-Null
                Write-Host (Color-Text $Script:THEME.Green "`n[OK] Switched update source to 'github' (Direct GitHub API)")
                Start-Sleep -Milliseconds 600
            }
            '4' {
                try { Clear-Host } catch {}
                Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "=== Select Release Channel ===`n")
                Write-Host "1. Stable (Standard release - recommended)"
                Write-Host "2. Preview (Latest feature preview)"
                Write-Host "3. LTS (Long Term Support - msstore)"
                $ch = Read-Host "`nChoose channel [1-3]"
                if ($ch -eq '1') { Set-PSManagerConfig -Channel 'stable' | Out-Null }
                if ($ch -eq '2') { Set-PSManagerConfig -Channel 'preview' | Out-Null }
                if ($ch -eq '3') { Set-PSManagerConfig -Channel 'lts' | Out-Null }
                Write-Host (Color-Text $Script:THEME.Green "`n[OK] Channel updated.")
                Start-Sleep -Milliseconds 600
            }
            '5' {
                try { Clear-Host } catch {}
                Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "==> Updating Winget Sources...`n")
                winget source update
                Write-Host ("`n" + (Get-I18nText "press_key"))
                try { if (-not [Console]::IsInputRedirected) { $null = [Console]::ReadKey($true) } } catch {}
            }
            '6' {
                try { Clear-Host } catch {}
                Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "=== Add Custom Winget Source ===`n")
                $sName = Read-Host "Source Name (e.g. my-repo)"
                $sUrl  = Read-Host "Source URL (e.g. https://...)"
                if ($sName -and $sUrl) {
                    winget source add -n $sName -a $sUrl
                } else {
                    Write-Host (Color-Text $Script:THEME.Yellow "Name and URL required. Cancelled.")
                }
                Write-Host ("`n" + (Get-I18nText "press_key"))
                try { if (-not [Console]::IsInputRedirected) { $null = [Console]::ReadKey($true) } } catch {}
            }
            '7' {
                try { Clear-Host } catch {}
                Write-Host (Color-Text ($Script:THEME.Cyan + $Script:THEME.Bold) "=== Registered Winget Sources ===`n")
                winget source list
                Write-Host ("`n" + (Get-I18nText "press_key"))
                try { if (-not [Console]::IsInputRedirected) { $null = [Console]::ReadKey($true) } } catch {}
            }
            '8' {
                try { Clear-Host } catch {}
                $confirm = Read-Host "Reset all winget sources to defaults? (y/N)"
                if ($confirm -match '^[Yy]$') {
                    winget source reset --force
                    Write-Host (Color-Text $Script:THEME.Green "`n[OK] Sources reset.")
                }
                Write-Host ("`n" + (Get-I18nText "press_key"))
                try { if (-not [Console]::IsInputRedirected) { $null = [Console]::ReadKey($true) } } catch {}
            }
            '0' { $inSubmenu = $false }
            'b' { $inSubmenu = $false }
            'B' { $inSubmenu = $false }
            'q' { $inSubmenu = $false }
            default { }
        }
    }
}
