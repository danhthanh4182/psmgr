#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Multi-Package Provisioning Engine
.DESCRIPTION
    Orchestrates installation and updates across Winget, Scoop, and PSGallery.
#>

function Initialize-ScoopEnvironment {
    [CmdletBinding()]
    param(
        [switch]$AutoInstall
    )

    $scoopShim = Join-Path $env:USERPROFILE "scoop\shims\scoop.cmd"
    $scoopDir  = Join-Path $env:USERPROFILE "scoop\shims"

    if (Test-Path -LiteralPath $scoopShim) {
        if ($env:PATH -notmatch [regex]::Escape($scoopDir)) {
            $env:PATH = "$scoopDir;$env:PATH"
        }
        return $true
    }

    if ($AutoInstall) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $installer = Join-Path ([System.IO.Path]::GetTempPath()) "install-scoop.ps1"
            Invoke-RestMethod -Uri "https://get.scoop.io" -OutFile $installer
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -RunAsAdmin:$false
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $scoopShim) {
                if ($env:PATH -notmatch [regex]::Escape($scoopDir)) {
                    $env:PATH = "$scoopDir;$env:PATH"
                }
                return $true
            }
        } catch {
            Write-Warning "Failed to bootstrap Scoop: $($_.Exception.Message)"
            return $false
        }
    }

    return (Test-Path -LiteralPath $scoopShim)
}

function Install-WingetBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Packages,

        [switch]$DryRun
    )

    $installed = [System.Collections.Generic.List[string]]::new()
    $skipped   = [System.Collections.Generic.List[string]]::new()
    $failed    = [System.Collections.Generic.List[string]]::new()

    $normalized = @($Packages | ForEach-Object {
        $id = if ($_ -is [string]) { "$_" } elseif ($_.id) { "$($_.id)" } else { "$_" }
        $src = if ($_ -is [psobject] -and $_.PSObject.Properties['source'] -and $_.source) { "$($_.source)" } else { "winget" }
        [pscustomobject]@{ Id = $id; Source = $src }
    })

    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd -and -not $DryRun) {
        return [pscustomobject]@{
            Success   = $false
            Total     = $normalized.Count
            Installed = @()
            Skipped   = @()
            Failed    = @($normalized | ForEach-Object { $_.Id })
            Message   = "winget command not found on this system"
        }
    }

    foreach ($pkg in $normalized) {
        $id = $pkg.Id

        if ($DryRun) {
            $skipped.Add($id)
            continue
        }

        try {
            $check = & winget list --exact --id $id 2>&1 | Out-String
            if ($check -match [regex]::Escape($id)) {
                $skipped.Add($id)
            } else {
                & winget install --exact --id $id --accept-source-agreements --accept-package-agreements --silent
                if ($LASTEXITCODE -eq 0) {
                    $installed.Add($id)
                } else {
                    $failed.Add($id)
                }
            }
        } catch {
            $failed.Add($id)
        }
    }

    return [pscustomobject]@{
        Success   = ($failed.Count -eq 0)
        Total     = $normalized.Count
        Installed = $installed.ToArray()
        Skipped   = $skipped.ToArray()
        Failed    = $failed.ToArray()
        Message   = "Processed $($normalized.Count) Winget packages"
    }
}

function Install-ScoopBatch {
    [CmdletBinding()]
    param(
        [string[]]$Buckets = @(),
        [string[]]$Apps = @(),
        [switch]$DryRun
    )

    $installedApps = [System.Collections.Generic.List[string]]::new()
    $skippedApps   = [System.Collections.Generic.List[string]]::new()
    $failedApps    = [System.Collections.Generic.List[string]]::new()

    $isScoopAvailable = Initialize-ScoopEnvironment -AutoInstall:(-not $DryRun)
    if (-not $isScoopAvailable -and -not $DryRun) {
        return [pscustomobject]@{
            Success       = $false
            BucketsTotal  = $Buckets.Count
            AppsTotal     = $Apps.Count
            InstalledApps = @()
            SkippedApps   = @()
            FailedApps    = $Apps
            Message       = "Scoop is not installed and could not be bootstrapped"
        }
    }

    if (-not $DryRun -and $Buckets -and $Buckets.Count -gt 0) {
        $activeBuckets = & scoop bucket list 2>&1 | Out-String
        foreach ($b in $Buckets) {
            if ($activeBuckets -notmatch "(?m)^$([regex]::Escape($b))\s") {
                & scoop bucket add $b 2>&1 | Out-Null
            }
        }
    }

    foreach ($app in $Apps) {
        if ($DryRun) {
            $skippedApps.Add($app)
            continue
        }

        try {
            $check = & scoop list $app 2>&1 | Out-String
            if ($check -match "(?m)^$([regex]::Escape($app))\s") {
                $skippedApps.Add($app)
            } else {
                & scoop install $app 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $installedApps.Add($app)
                } else {
                    $failedApps.Add($app)
                }
            }
        } catch {
            $failedApps.Add($app)
        }
    }

    return [pscustomobject]@{
        Success       = ($failedApps.Count -eq 0)
        BucketsTotal  = $Buckets.Count
        AppsTotal     = $Apps.Count
        InstalledApps = $installedApps.ToArray()
        SkippedApps   = $skippedApps.ToArray()
        FailedApps    = $failedApps.ToArray()
        Message       = "Processed $($Apps.Count) Scoop apps"
    }
}

function Install-PSGalleryBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Modules,

        [switch]$DryRun
    )

    # Enforce TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $installed = [System.Collections.Generic.List[string]]::new()
    $skipped   = [System.Collections.Generic.List[string]]::new()
    $failed    = [System.Collections.Generic.List[string]]::new()

    $normalized = @($Modules | ForEach-Object {
        $name = if ($_ -is [string]) { "$_" } elseif ($_.name) { "$($_.name)" } else { "$_" }
        $scope = if ($_ -is [psobject] -and $_.PSObject.Properties['scope'] -and $_.scope) { "$($_.scope)" } else { "CurrentUser" }
        [pscustomobject]@{ Name = $name; Scope = $scope }
    })

    foreach ($mod in $normalized) {
        $name = $mod.Name
        $scope = $mod.Scope

        if ($DryRun) {
            $skipped.Add($name)
            continue
        }

        try {
            $existing = Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue
            if ($existing) {
                $skipped.Add($name)
            } else {
                Install-Module -Name $name -Scope $scope -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
                $installed.Add($name)
            }
        } catch {
            $failed.Add($name)
        }
    }

    return [pscustomobject]@{
        Success   = ($failed.Count -eq 0)
        Total     = $normalized.Count
        Installed = $installed.ToArray()
        Skipped   = $skipped.ToArray()
        Failed    = $failed.ToArray()
        Message   = "Processed $($normalized.Count) PSGallery modules"
    }
}
