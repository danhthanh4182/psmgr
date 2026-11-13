#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$ProvModule = Join-Path $RootDir "modules\Sync\Provisioner.ps1"

if (-not (Test-Path $ProvModule)) {
    Write-Error "Provisioner module not found at: $ProvModule"
    exit 1
}

. $ProvModule

try {
    # Test 1: Install-WingetBatch DryRun
    $wingetPkgs = @(
        @{ id = "Microsoft.PowerShell"; source = "winget" }
    )
    $resWinget = Install-WingetBatch -Packages $wingetPkgs -DryRun
    if (-not $resWinget.Success) {
        throw "Install-WingetBatch DryRun failed: $($resWinget.Message)"
    }
    if ($resWinget.Total -ne 1) {
        throw "Expected Total=1 in DryRun, got $($resWinget.Total)"
    }

    # Test 2: Install-ScoopBatch DryRun
    $resScoop = Install-ScoopBatch -Buckets @("extras") -Apps @("starship", "fnm") -DryRun
    if (-not $resScoop.Success) {
        throw "Install-ScoopBatch DryRun failed: $($resScoop.Message)"
    }
    if ($resScoop.AppsTotal -ne 2) {
        throw "Expected AppsTotal=2, got $($resScoop.AppsTotal)"
    }

    # Test 3: Install-PSGalleryBatch DryRun
    $psgModules = @(
        @{ name = "Terminal-Icons"; scope = "CurrentUser" }
    )
    $resPsg = Install-PSGalleryBatch -Modules $psgModules -DryRun
    if (-not $resPsg.Success) {
        throw "Install-PSGalleryBatch DryRun failed: $($resPsg.Message)"
    }
    if ($resPsg.Total -ne 1) {
        throw "Expected Total=1 in DryRun, got $($resPsg.Total)"
    }

    # Test 4: Initialize-ScoopEnvironment returns bool
    $scoopEnv = Initialize-ScoopEnvironment
    if ($scoopEnv -ne $true -and $scoopEnv -ne $false) {
        throw "Initialize-ScoopEnvironment must return boolean"
    }

    # Test 5: Verify polymorphic package & module normalization and accurate Total counts
    $mixedWinget = @("Git.Git", @{ id = "Microsoft.PowerShell" })
    $resMixedWinget = Install-WingetBatch -Packages $mixedWinget -DryRun
    if ($resMixedWinget.Total -ne 2) {
        throw "Expected Total=2 for mixed Winget packages, got $($resMixedWinget.Total)"
    }

    $mixedPsg = @("posh-git", @{ name = "Terminal-Icons"; scope = "CurrentUser" })
    $resMixedPsg = Install-PSGalleryBatch -Modules $mixedPsg -DryRun
    if ($resMixedPsg.Total -ne 2) {
        throw "Expected Total=2 for mixed PSGallery modules, got $($resMixedPsg.Total)"
    }

    Write-Host "[PASS] test_provisioner.ps1 passed all checks" -ForegroundColor Green
    exit 0
}
catch {
    Write-Error "Test failed: $($_.Exception.Message)"
    exit 1
}
