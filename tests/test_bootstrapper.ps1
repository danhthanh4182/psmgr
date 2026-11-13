#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$BootScript = Join-Path $RootDir "boot.ps1"

if (-not (Test-Path $BootScript)) {
    Write-Error "boot.ps1 not found at: $BootScript"
    exit 1
}

# Test 1: Validate AST Syntax under PS 5.1 Parser
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($BootScript, [ref]$null, [ref]$errs)
if ($errs -and $errs.Count -gt 0) {
    throw "boot.ps1 AST syntax error: $($errs | Out-String)"
}

# Test 2: Check for forbidden PS7-only syntax in boot.ps1 (must be 100% PS5 compatible)
$content = Get-Content $BootScript -Raw
if ($content -match '\?\?' -or $content -match '\?\.=' -or $content -match '&&' -or $content -match '\|\|') {
    throw "boot.ps1 contains PS7-only operators (??, ?., &&, ||) which will break on PS 5.1"
}

# Test 3: Verify Compression assembly is preloaded for raw PS 5.1 zip extraction
if ($content -notmatch 'Add-Type\s+-AssemblyName\s+System\.IO\.Compression\.FileSystem') {
    throw "boot.ps1 missing Add-Type for System.IO.Compression.FileSystem"
}

# Test 4: Verify dynamic repository archive directory matching
if ($content -notmatch 'psmgr-main') {
    throw "boot.ps1 missing dynamic directory matching for psmgr-main"
}

# Test 5: Verify handover invokes script via -File argument
if ($content -notmatch '&\s+\$pwshExe\s+-NoProfile\s+-ExecutionPolicy\s+Bypass\s+-File\s+\$harnessScript\s+sync') {
    throw "boot.ps1 handover does not use safe -File invocation pattern"
}

# Test 6: install.ps1 must parse on PS 5.1 and refuse a release without SHA256SUMS.txt
$InstallScript = Join-Path $RootDir 'install.ps1'
if (-not (Test-Path $InstallScript)) { throw "install.ps1 not found at: $InstallScript" }
$installErrs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($InstallScript, [ref]$null, [ref]$installErrs)
if ($installErrs -and $installErrs.Count -gt 0) {
    throw "install.ps1 AST syntax error: $($installErrs | Out-String)"
}
$installContent = Get-Content $InstallScript -Raw
if ($installContent -match 'skipping digest verification') {
    throw 'install.ps1 still continues when SHA256SUMS.txt is missing (unsigned install path)'
}
if ($installContent -notmatch 'does not publish SHA256SUMS\.txt; refusing') {
    throw 'install.ps1 is missing the digest-refusal branch'
}

Write-Host "[PASS] test_bootstrapper.ps1 passed all checks" -ForegroundColor Green
exit 0
