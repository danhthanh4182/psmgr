#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Manifest Parser & Schema Validator
.DESCRIPTION
    Handles reading, schema verification, and default template generation
    for manifest.json in the user dotfiles payload layer.
#>

function Get-DefaultManifestTemplate {
    [CmdletBinding()]
    param()

    return @{
        version  = "1.0.0"
        packages = @{
            winget    = @(
                @{ id = "Microsoft.PowerShell"; source = "winget" }
                @{ id = "Microsoft.WindowsTerminal"; source = "winget" }
                @{ id = "Git.Git"; source = "winget" }
            )
            scoop     = @{
                buckets = @("extras", "nerd-fonts")
                apps    = @("starship", "fnm", "fzf", "ripgrep", "jq", "zoxide")
            }
            psgallery = @(
                @{ name = "PSReadLine"; minVersion = "2.3.4"; scope = "CurrentUser" }
                @{ name = "Terminal-Icons"; scope = "CurrentUser" }
                @{ name = "posh-git"; scope = "CurrentUser" }
            )
        }
        links    = @(
            @{
                source  = "profiles/master_profile.ps1"
                targets = @(
                    "~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1",
                    "~/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"
                )
                type    = "hardlink"
            },
            @{
                source  = "configs/starship.toml"
                targets = @("~/.config/starship.toml")
                type    = "hardlink"
            }
        )
        env      = @{
            STARSHIP_CONFIG = "~/.config/starship.toml"
        }
    }
}

function Read-SyncManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        Write-Error "Manifest file not found: $ManifestPath"
        return $null
    }

    try {
        $content = [System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)
        $manifest = $content | ConvertFrom-Json

        # Normalize structure
        if (-not $manifest.packages) {
            $manifest | Add-Member -MemberType NoteProperty -Name "packages" -Value ([pscustomobject]@{}) -Force
        }
        if (-not $manifest.packages.winget) {
            $manifest.packages | Add-Member -MemberType NoteProperty -Name "winget" -Value @() -Force
        }
        if (-not $manifest.packages.scoop) {
            $manifest.packages | Add-Member -MemberType NoteProperty -Name "scoop" -Value ([pscustomobject]@{ buckets = @(); apps = @() }) -Force
        }
        if (-not $manifest.packages.psgallery) {
            $manifest.packages | Add-Member -MemberType NoteProperty -Name "psgallery" -Value @() -Force
        }
        if (-not $manifest.links) {
            $manifest | Add-Member -MemberType NoteProperty -Name "links" -Value @() -Force
        }
        if (-not $manifest.env) {
            $manifest | Add-Member -MemberType NoteProperty -Name "env" -Value ([pscustomobject]@{}) -Force
        }

        return $manifest
    } catch {
        Write-Error "Failed to parse manifest JSON at '$ManifestPath': $($_.Exception.Message)"
        return $null
    }
}

function Test-SyncManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Manifest
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not $Manifest) {
        $errors.Add("Manifest object is null or empty")
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray() }
    }

    # Version check
    if (-not ($Manifest.PSObject.Properties['version']) -or [string]::IsNullOrWhiteSpace($Manifest.version)) {
        $errors.Add("Missing required field 'version'")
    }

    # Packages check
    if (-not ($Manifest.PSObject.Properties['packages']) -or -not $Manifest.packages) {
        $errors.Add("Missing required field 'packages'")
    }

    # Links validation if present
    if ($Manifest.PSObject.Properties['links'] -and $Manifest.links) {
        $index = 0
        foreach ($link in $Manifest.links) {
            if (-not $link.source) {
                $errors.Add("Link item [$index] is missing 'source'")
            }
            if (-not $link.targets -or ($link.targets.Count -eq 0)) {
                $errors.Add("Link item [$index] is missing 'targets'")
            }
            $index++
        }
    }

    return [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = $errors.ToArray()
    }
}
