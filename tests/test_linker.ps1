#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$LinkerPath = Join-Path $RootDir "modules\Sync\Linker.ps1"

if (-not (Test-Path $LinkerPath)) {
    Write-Error "Linker module not found at: $LinkerPath"
    exit 1
}

. $LinkerPath

$TempDir = Join-Path $env:TEMP "psmgr_test_linker_$(Get-Random)"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    # Test 1: Resolve-NormalizedPath
    $homePath = Resolve-NormalizedPath "~/test/path"
    $expectedHome = Join-Path $env:USERPROFILE "test\path"
    if ($homePath -ne $expectedHome) {
        throw "Resolve-NormalizedPath failed: expected '$expectedHome', got '$homePath'"
    }

    # Test 2: New-SafeLink creates link/copy
    $srcFile = Join-Path $TempDir "source.txt"
    "Hello PSManager Sync" | Out-File -FilePath $srcFile -Encoding utf8 -NoNewline
    $targetFile = Join-Path $TempDir "target.txt"

    $res = New-SafeLink -SourcePath $srcFile -TargetPath $targetFile -LinkType "hardlink"
    if (-not $res.Success) {
        throw "New-SafeLink failed: $($res.Message)"
    }
    if (-not (Test-Path $targetFile)) {
        throw "Target file was not created"
    }

    # Test 3: Test-FileIdentical
    $identical = Test-FileIdentical -PathA $srcFile -PathB $targetFile
    if (-not $identical) {
        throw "Test-FileIdentical returned false for newly linked file"
    }

    # Test 4: Idempotent - running again should report success and no backup
    $res2 = New-SafeLink -SourcePath $srcFile -TargetPath $targetFile -LinkType "hardlink"
    if (-not $res2.Success) {
        throw "Idempotent New-SafeLink failed"
    }
    if ($res2.Method -ne "SkippedIdentical") {
        throw "Expected method SkippedIdentical, got '$($res2.Method)'"
    }

    # Test 5: Conflict backup
    $newSource = Join-Path $TempDir "source_new.txt"
    "Different Content" | Out-File -FilePath $newSource -Encoding utf8 -NoNewline

    $res3 = New-SafeLink -SourcePath $newSource -TargetPath $targetFile -LinkType "copy"
    if (-not $res3.Success -or -not $res3.BackupPath) {
        throw "Backup failed when overwriting differing content: $($res3.Message)"
    }
    if (-not (Test-Path $res3.BackupPath)) {
        throw "Backup file does not exist on disk"
    }

    Write-Host "[PASS] test_linker.ps1 passed all checks" -ForegroundColor Green
    exit 0
}
finally {
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
