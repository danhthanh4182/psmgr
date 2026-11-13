#Requires -Version 5.1
<#
.SYNOPSIS
    Test Runner for PSManager across both PS5 and PS7
#>
[CmdletBinding()]
param(
    [switch]$Fast
)

$scriptRoot = Split-Path -Parent $PSCommandPath
$harness = Join-Path -Path $scriptRoot -ChildPath "harness.ps1"

if ($Fast) {
    Write-Host ">>> Executing Fast Hook Validation Suite ($($PSVersionTable.PSVersion.ToString()))..." -ForegroundColor Cyan
    $rootDir = Split-Path -Parent $scriptRoot

    # 1. AST Syntax linting across all .ps1, .psm1, .psd1 files
    Write-Host "--> 1. AST Syntax Linting across all PowerShell sources..." -ForegroundColor Yellow
    $filesToLint = Get-ChildItem -Path (Join-Path $rootDir '*') -Recurse -Include *.ps1, *.psm1, *.psd1 |
        Where-Object { $_.FullName -notmatch '\\\.git\\' }
    $astFailures = 0
    foreach ($f in $filesToLint) {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs) | Out-Null
        if ($errs -and $errs.Count -gt 0) {
            Write-Host "  [FAIL] $($f.Name): $($errs[0].Message)" -ForegroundColor Red
            $astFailures++
        }
    }
    if ($astFailures -gt 0) {
        Write-Host "  [FAIL] Fast hook failed: $astFailures syntax errors detected." -ForegroundColor Red
        exit 1
    }
    Write-Host "  [PASS] All $($filesToLint.Count) files passed AST syntax parse cleanly." -ForegroundColor Green

    # 2. Module manifest verification
    Write-Host "`n--> 2. Module Manifest Verification..." -ForegroundColor Yellow
    $manifestPath = Join-Path $rootDir "PSManager.psd1"
    try {
        $m = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
        Write-Host "  [PASS] PSManager.psd1 valid (v$($m.Version))." -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] PSManager.psd1 manifest error: $_" -ForegroundColor Red
        exit 1
    }

    # 3. PSScriptAnalyzer Rule Audit on Changed Files
    Write-Host "`n--> 3. PSScriptAnalyzer Rule Audit on Changed Files..." -ForegroundColor Yellow
    $settingsPath = Join-Path $rootDir "PSScriptAnalyzerSettings.psd1"
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
        $changed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        try {
            $rawPaths = @(
                (& git -C $rootDir diff --cached --name-only 2>$null),
                (& git -C $rootDir diff --name-only 2>$null),
                (& git -C $rootDir ls-files --others --exclude-standard 2>$null),
                (& git -C $rootDir diff --name-only "@{upstream}...HEAD" 2>$null),
                (& git -C $rootDir diff --name-only HEAD~1 2>$null)
            )
            foreach ($p in $rawPaths) {
                if ($p -and ($p -match '\.(ps1|psm1|psd1)$')) {
                    $full = Join-Path $rootDir $p
                    if (Test-Path -LiteralPath $full) { $null = $changed.Add($full) }
                }
            }
        } catch { }

        if ($changed.Count -eq 0) {
            foreach ($entry in @('PSManager.psd1', 'PSManager.psm1', 'ps-manager.ps1')) {
                $full = Join-Path $rootDir $entry
                if (Test-Path -LiteralPath $full) { $null = $changed.Add($full) }
            }
        }

        $issues = @()
        $analyzerFailures = @()
        foreach ($file in $changed) {
            $results = $null
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                try {
                    $results = Invoke-ScriptAnalyzer -Path $file -Settings $settingsPath -ErrorAction Stop
                    break
                } catch {
                    if ($attempt -ge 2) {
                        # A transient analyzer crash must fail the gate, not pass it silently.
                        $analyzerFailures += ("{0}: {1}" -f $file, $_.Exception.Message)
                    }
                    Start-Sleep -Milliseconds 250
                }
            }
            if ($results) {
                $issues += @($results | Where-Object { $_.Severity -in 'Error', 'Warning' })
            }
        }

        if ($analyzerFailures.Count -gt 0) {
            foreach ($failure in $analyzerFailures) {
                Write-Host "  [FAIL] PSScriptAnalyzer crashed: $failure" -ForegroundColor Red
            }
            Write-Host "  [FAIL] PSScriptAnalyzer could not analyze $($analyzerFailures.Count) file(s)." -ForegroundColor Red
            exit 1
        }

        if ($issues.Count -gt 0) {
            foreach ($issue in $issues) {
                Write-Host "  [FAIL] $($issue.ScriptName):$($issue.Line) [$($issue.RuleName)] $($issue.Message)" -ForegroundColor Red
            }
            Write-Host "  [FAIL] PSScriptAnalyzer found $($issues.Count) issue(s)." -ForegroundColor Red
            exit 1
        }
        Write-Host "  [PASS] PSScriptAnalyzer verified $($changed.Count) changed file(s) with 0 warnings." -ForegroundColor Green
    } else {
        Write-Host "  [INFO] PSScriptAnalyzer module not installed in current session. Skipping." -ForegroundColor Gray
    }

    # 4. Tri-Interface Parity Contract verification
    Write-Host "`n--> 4. Tri-Interface Parity Contract..." -ForegroundColor Yellow
    $parityScript = Join-Path $scriptRoot "test_interface_parity.ps1"
    & $parityScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [FAIL] Tri-Interface Parity failed." -ForegroundColor Red
        exit 1
    }

    # 5. Automation invariants (LF-only hooks)
    Write-Host "`n--> 5. Automation Invariants (LF hooks)..." -ForegroundColor Yellow
    $hookDir = Join-Path $rootDir ".agents\hooks"
    if (Test-Path -LiteralPath $hookDir) {
        foreach ($hook in Get-ChildItem -LiteralPath $hookDir -File) {
            $hookText = [System.IO.File]::ReadAllText($hook.FullName)
            if ($hookText.Contains("`r")) {
                Write-Host "  [FAIL] $($hook.Name) contains CR characters." -ForegroundColor Red
                exit 1
            }
        }
        Write-Host "  [PASS] All hooks LF-only." -ForegroundColor Green
    }

    Write-Host "`n>>> Fast hook validation passed!" -ForegroundColor Green
    exit 0
}

$isCore = ($PSVersionTable.PSEdition -eq 'Core') -or ($PSVersionTable.PSVersion.Major -ge 6)
$currentVersion = $PSVersionTable.PSVersion.ToString()

Write-Host ">>> Executing Test Harness in Current PowerShell Engine ($currentVersion)..." -ForegroundColor Cyan
& $harness
$currentExit = $LASTEXITCODE

$crossExit = 0
if ($isCore) {
    # Current engine is PowerShell 7+ (Core). Cross-verify against Windows PowerShell 5.1 if present.
    $ps5 = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($ps5) {
        Write-Host "`n>>> Cross-verifying Test Harness in Windows PowerShell 5.1 (powershell.exe)..." -ForegroundColor Cyan
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harness
        $crossExit = $LASTEXITCODE
    } else {
        Write-Host "`n>>> Windows PowerShell 5.1 (powershell.exe) not available; skipping cross-verification." -ForegroundColor Yellow
    }
} else {
    # Current engine is Windows PowerShell 5.1 (Desktop). Cross-verify against PowerShell 7+ (Core).
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    }
    if ($pwsh) {
        Write-Host "`n>>> Cross-verifying Test Harness in PowerShell 7 (pwsh)..." -ForegroundColor Cyan
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File $harness
        $crossExit = $LASTEXITCODE
    } else {
        Write-Host "`n>>> PowerShell 7 (pwsh) not available; skipping cross-verification." -ForegroundColor Yellow
    }
}

if ($currentExit -ne 0 -or $crossExit -ne 0) {
    exit 1
}
exit 0
