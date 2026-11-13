#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$LoggerModule = Join-Path $RootDir "modules\Core\Logger.ps1"

if (-not (Test-Path $LoggerModule)) {
    Write-Error "Logger module not found at: $LoggerModule"
    exit 1
}

. $LoggerModule

$TempDir = Join-Path $env:TEMP "psmgr_test_logger_$(Get-Random)"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    # Test 1: Write-PSManagerLog writes to file
    Write-PSManagerLog -Message "Test info message" -Level "INFO" -LogDirectory $TempDir
    Write-PSManagerLog -Message "Test error occurred" -Level "ERROR" -LogDirectory $TempDir

    $logFiles = Get-ChildItem -LiteralPath $TempDir -Filter "psmgr_*.log"
    if ($logFiles.Count -eq 0) {
        throw "Log file was not created"
    }

    # Test 2: Get-PSManagerLogs reads content
    $allLogs = Get-PSManagerLogs -LogDirectory $TempDir
    if ($allLogs.Count -lt 2) {
        throw "Expected at least 2 log entries, got $($allLogs.Count)"
    }

    # Test 3: Get-PSManagerLogs with -ErrorsOnly filter
    $errLogs = @(Get-PSManagerLogs -LogDirectory $TempDir -ErrorsOnly)
    if ($errLogs.Count -ne 1) {
        throw "Expected 1 error log entry, got $($errLogs.Count)"
    }
    if ("$($errLogs -join ' ')" -notmatch "Test error occurred") {
        throw "Error log did not contain expected message: $($errLogs -join ' ')"
    }

    # Test 4: Clear-PSManagerLogs with 0 retention days removes file
    $cleared = Clear-PSManagerLogs -RetentionDays 0 -LogDirectory $TempDir
    if ($cleared -lt 1) {
        throw "Clear-PSManagerLogs did not clean up expired log"
    }
    $remaining = Get-ChildItem -LiteralPath $TempDir -Filter "psmgr_*.log"
    if ($remaining.Count -ne 0) {
        throw "Log file was not deleted after Clear-PSManagerLogs"
    }

    Write-Host "[PASS] test_logger.ps1 passed all checks" -ForegroundColor Green
    exit 0
}
finally {
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
