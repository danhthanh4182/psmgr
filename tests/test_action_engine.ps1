#Requires -Version 5.1
<#
.SYNOPSIS
    Unit and Contract Tests for PSManager Action Execution Engine (Deep Module)
#>
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

Import-Module (Join-Path $RootDir "PSManager.psd1") -Force

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Check {
    param([string]$Name, [scriptblock]$TestBlock)
    try {
        & $TestBlock
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $Name - $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add("$Name :: $($_.Exception.Message)")
    }
}

Write-Host "--> Running ActionEngine Unit & Contract Tests..." -ForegroundColor Cyan

# 1. Synchronous execution test
Assert-Check -Name "Invoke-PSManagerAction runs synchronously and returns result object" -TestBlock {
    $res = Invoke-PSManagerAction -Action "help"
    if (-not $res) { throw "Result object is null" }
    if (-not $res.Success) { throw "Action failed with exit code $($res.ExitCode): $($res.Error)" }
    if ($res.ExitCode -ne 0) { throw "Expected exit code 0, got $($res.ExitCode)" }
    if ($res.Output.Count -lt 5) { throw "Expected at least 5 lines of output, got $($res.Output.Count)" }
}

# 2. Line streaming callback and ANSI sanitization test
Assert-Check -Name "OnOutput callback streams clean lines without ANSI escapes" -TestBlock {
    $lines = [System.Collections.Generic.List[string]]::new()
    $res = Invoke-PSManagerAction -Action "help" -OnOutput {
        param($line)
        $lines.Add($line)
    }
    if ($lines.Count -eq 0) { throw "No lines captured by OnOutput callback" }
    $joined = $lines -join "`n"
    $escChars = @($joined.ToCharArray() | Where-Object { [int]$_ -eq 27 })
    if ($escChars.Count -gt 0) { throw "Captured output contains $($escChars.Count) unstripped ESC characters" }
}

# 3. Error signaling on invalid action / parameter failure
Assert-Check -Name "Invoke-PSManagerAction captures failure and sets non-zero exit code" -TestBlock {
    $res = Invoke-PSManagerAction -Action "help" -Arguments @('-InvalidSwitchThatDoesNotExist')
    if ($res.Success) { throw "Expected failure for invalid parameter, but Success was true" }
    if ($res.ExitCode -eq 0) { throw "Expected non-zero exit code for failure, got 0" }
}

# 4. Asynchronous handle and Stop() cancellation
Assert-Check -Name "Invoke-PSManagerAction -Async returns handle and supports Stop()" -TestBlock {
    $handle = Invoke-PSManagerAction -Action "help" -Async
    if (-not $handle) { throw "Async handle was null" }
    if (-not $handle.ExecutionId) { throw "Handle missing ExecutionId" }
    if (-not $handle.Process) { throw "Handle missing Process object" }
    Stop-PSManagerAction -Handle $handle
}

if ($failures.Count -gt 0) {
    Write-Host "`n[FAIL] test_action_engine.ps1 had $($failures.Count) failure(s)" -ForegroundColor Red
    exit 1
}

Write-Host "`n[PASS] test_action_engine.ps1 passed all checks" -ForegroundColor Green
exit 0
