#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$SyncEngineModule = Join-Path $RootDir "modules\Sync\SyncEngine.ps1"

if (-not (Test-Path $SyncEngineModule)) {
    Write-Error "SyncEngine module not found at: $SyncEngineModule"
    exit 1
}

# Load dependencies
. (Join-Path $RootDir "modules\Sync\Linker.ps1")
. (Join-Path $RootDir "modules\Sync\Manifest.ps1")
. (Join-Path $RootDir "modules\Sync\Provisioner.ps1")
. (Join-Path $RootDir "modules\Sync\Backup.ps1")
. $SyncEngineModule

$TempDir = Join-Path $env:TEMP "psmgr_test_synceng_$(Get-Random)"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    # Create test manifest & files
    $manifestFile = Join-Path $TempDir "manifest.json"
    $profilesDir = Join-Path $TempDir "profiles"
    New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null
    $srcProfile = Join-Path $profilesDir "master_profile.ps1"
    "Write-Host 'Test Universal Profile'" | Out-File $srcProfile -Encoding utf8

    $targetPS5 = Join-Path $TempDir "dest_ps5_profile.ps1"
    $targetPS7 = Join-Path $TempDir "dest_ps7_profile.ps1"

    $manifestData = @{
        version  = "1.0.0"
        packages = @{
            winget    = @()
            scoop     = @{ buckets = @(); apps = @() }
            psgallery = @()
        }
        links    = @(
            @{
                source  = "profiles/master_profile.ps1"
                targets = @($targetPS5, $targetPS7)
                type    = "hardlink"
            }
        )
        env      = @{
            PSMGR_TEST_ENV = "ACTIVE"
        }
    }
    $json = $manifestData | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($manifestFile, $json, [System.Text.Encoding]::UTF8)

    # Test 1: Invoke-PSManagerSync in DryRun mode
    $dryRunRes = Invoke-PSManagerSync -ManifestPath $manifestFile -BasePayloadDir $TempDir -DryRun
    if (-not $dryRunRes.Success) {
        throw "DryRun sync failed: $($dryRunRes.Message)"
    }
    if ($dryRunRes.LinksProcessed -ne 2) {
        throw "Expected LinksProcessed=2 in DryRun, got $($dryRunRes.LinksProcessed)"
    }

    # Test 2: Invoke-PSManagerSync real execution
    $realRes = Invoke-PSManagerSync -ManifestPath $manifestFile -BasePayloadDir $TempDir -SkipPackages
    if (-not $realRes.Success) {
        throw "Real sync failed: $($realRes.Message)"
    }
    if (-not (Test-Path $targetPS5) -or -not (Test-Path $targetPS7)) {
        throw "Target profiles were not created during real sync"
    }

    # Test 3: Invoke-PSManagerDoctor with recommendations
    $doctorChecks = Invoke-PSManagerDoctor -ManifestPath $manifestFile -BasePayloadDir $TempDir
    if (-not $doctorChecks -or $doctorChecks.Count -eq 0) {
        throw "Invoke-PSManagerDoctor returned 0 audit items"
    }
    $firstItem = $doctorChecks[0]
    if (-not ($firstItem.PSObject.Properties['Recommendation'])) {
        throw "Doctor report items missing Recommendation field"
    }
    $failedChecks = $doctorChecks | Where-Object { $_.Status -eq "FAIL" }
    if ($failedChecks.Count -gt 0) {
        throw "Doctor reported unexpected failures: $($failedChecks | ForEach-Object { $_.Item } | Out-String)"
    }

    # Test 4: Invoke-PSManagerDoctor -Fix repairs broken or differing links
    # Break hardlink and corrupt target file
    Remove-Item $targetPS5 -Force
    "Corrupted content" | Out-File $targetPS5 -Encoding utf8
    $fixReport = Invoke-PSManagerDoctor -ManifestPath $manifestFile -BasePayloadDir $TempDir -Fix
    $fixedItem = $fixReport | Where-Object { $_.Item -eq (Split-Path -Leaf $targetPS5) }
    if (-not $fixedItem -or $fixedItem.Status -ne "FIXED") {
        throw "Invoke-PSManagerDoctor -Fix failed to repair differing link"
    }
    if (-not (Test-FileIdentical -PathA $srcProfile -PathB $targetPS5)) {
        throw "Target file was not restored to match source after Doctor -Fix"
    }

    # Test 5: Verify non-path environment variables are preserved exactly without turning into paths
    $envCheck = [System.Environment]::GetEnvironmentVariable("PSMGR_TEST_ENV", [System.EnvironmentVariableTarget]::Process)
    if ($envCheck -ne "ACTIVE") {
        throw "Non-path environment variable was corrupted: expected 'ACTIVE', got '$envCheck'"
    }

    Write-Host "[PASS] test_sync_engine.ps1 passed all checks" -ForegroundColor Green
    exit 0
}
finally {
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
