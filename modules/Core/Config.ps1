#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Core - Configuration Persistence
#>

# Resolve from the module layout (<root>\modules\Core\Config.ps1 -> <root>\config.json)
# so a worktree, a copy, an installed package or a release zip all read their own file.
$Script:CONFIG_PATH = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'config.json'

function Get-PSManagerConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if (Test-Path $Script:CONFIG_PATH) {
        try {
            $raw = Get-Content $Script:CONFIG_PATH -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json
                return [pscustomobject]@{
                    updateSource = if ($obj.updateSource) { [string]$obj.updateSource } else { "winget" }
                    channel      = if ($obj.channel) { [string]$obj.channel } else { "stable" }
                    language     = if ($obj.language) { [string]$obj.language } else { "vi" }
                    cloudRepo    = if ($obj.cloudRepo) { [string]$obj.cloudRepo } else { $null }
                }
            }
        } catch {
            Write-Verbose "Failed to parse config file: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        updateSource = "winget"
        channel      = "stable"
        language     = "vi"
        cloudRepo    = $null
    }
}

function Set-PSManagerConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateSet('winget', 'msstore', 'github')]
        [string]$Source,

        [Parameter()]
        [ValidateSet('stable', 'preview', 'lts')]
        [string]$Channel,

        [Parameter()]
        [ValidateSet('vi', 'vi-ascii', 'en')]
        [string]$Language,

        [Parameter()]
        [AllowEmptyString()]
        [string]$CloudRepo
    )

    $current = Get-PSManagerConfig
    $h = [ordered]@{
        updateSource = if ($Source) { $Source.ToLower() } else { $current.updateSource }
        channel      = if ($Channel) { $Channel.ToLower() } else { $current.channel }
        language     = if ($Language) { $Language.ToLower() } else { $current.language }
        cloudRepo    = if ($PSBoundParameters.ContainsKey('CloudRepo')) {
            if ([string]::IsNullOrWhiteSpace($CloudRepo)) { $null } else { $CloudRepo.Trim() }
        } else { $current.cloudRepo }
    }

    $cfgDir = Split-Path $Script:CONFIG_PATH
    if (-not (Test-Path $cfgDir)) {
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    }

    # WriteAllText + UTF8Encoding($false): Set-Content -Encoding UTF8 stamps a BOM on
    # Windows PowerShell 5.1 and none on 7, which made the tracked config.json differ per engine.
    $json = $h | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($Script:CONFIG_PATH, $json, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]$h
}
