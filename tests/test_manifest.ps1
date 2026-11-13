#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$ManifestModule = Join-Path $RootDir "modules\Sync\Manifest.ps1"

if (-not (Test-Path $ManifestModule)) {
    Write-Error "Manifest module not found at: $ManifestModule"
    exit 1
}

. $ManifestModule

$TempDir = Join-Path $env:TEMP "psmgr_test_manifest_$(Get-Random)"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    # Test 1: Get-DefaultManifestTemplate
    $tmpl = Get-DefaultManifestTemplate
    if (-not $tmpl -or -not $tmpl.version -or -not $tmpl.packages) {
        throw "Get-DefaultManifestTemplate returned invalid template"
    }

    # Test 2: Write & Read valid manifest
    $manifestFile = Join-Path $TempDir "manifest.json"
    $tmplJson = $tmpl | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($manifestFile, $tmplJson, [System.Text.Encoding]::UTF8)

    $loaded = Read-SyncManifest -ManifestPath $manifestFile
    if (-not $loaded -or $loaded.version -ne "1.0.0") {
        throw "Read-SyncManifest failed to parse version"
    }

    # Test 3: Test-SyncManifest on valid
    $val = Test-SyncManifest -Manifest $loaded
    if (-not $val.IsValid -or $val.Errors.Count -gt 0) {
        throw "Test-SyncManifest reported false negative on valid manifest: $($val.Errors -join ', ')"
    }

    # Test 4: Test-SyncManifest rejects invalid schema
    $invalidManifest = [pscustomobject]@{ foo = "bar" }
    $val2 = Test-SyncManifest -Manifest $invalidManifest
    if ($val2.IsValid -or $val2.Errors.Count -eq 0) {
        throw "Test-SyncManifest failed to detect missing version/packages"
    }

    Write-Host "[PASS] test_manifest.ps1 passed all checks" -ForegroundColor Green
    exit 0
}
finally {
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
