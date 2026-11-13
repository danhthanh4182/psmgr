#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Automated Test & Validation Harness
.DESCRIPTION
    Runs syntax AST linting, manifest verification, module export contract checks,
    config CRUD tests, source resolution checks, and i18n adaptation tests.
#>

[CmdletBinding()]
param(
    [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'
$Script:ROOT_DIR = Split-Path -Parent $PSScriptRoot
if (-not $Script:ROOT_DIR) { $Script:ROOT_DIR = (Split-Path -Parent $PSScriptRoot) }

$Script:PassCount = 0
$Script:FailCount = 0
$Script:TestResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Assert-Test {
    param(
        [string]$Name,
        [scriptblock]$TestBlock
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $TestBlock
        $sw.Stop()
        $Script:PassCount++
        $Script:TestResults.Add([pscustomobject]@{
            Status   = "PASS"
            Name     = $Name
            Duration = "$($sw.ElapsedMilliseconds)ms"
            Message  = "OK"
        })
        Write-Host "  [PASS] $Name ($($sw.ElapsedMilliseconds)ms)" -ForegroundColor Green
    } catch {
        $sw.Stop()
        $Script:FailCount++
        $Script:TestResults.Add([pscustomobject]@{
            Status   = "FAIL"
            Name     = $Name
            Duration = "$($sw.ElapsedMilliseconds)ms"
            Message  = $_.Exception.Message
        })
        Write-Host "  [FAIL] $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "                     PSMANAGER AUTOMATED VALIDATION HARNESS                     " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "Root Directory: $Script:ROOT_DIR"
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion.ToString()) ($($PSVersionTable.PSEdition))`n"

# ---------------------------------------------------------------------------
# Test Suite 1: AST Syntax Linting
# ---------------------------------------------------------------------------
Write-Host "--> Running Test Suite 1: AST Syntax & Code Linting..." -ForegroundColor Yellow

$filesToLint = Get-ChildItem -Path $Script:ROOT_DIR -Recurse -Include *.ps1, *.psm1, *.psd1
foreach ($f in $filesToLint) {
    Assert-Test -Name "Lint syntax: $($f.Name)" -TestBlock {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs) | Out-Null
        if ($errs -and $errs.Count -gt 0) {
            $msg = ($errs | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "; "
            throw "Syntax errors detected: $msg"
        }
    }
}

# ---------------------------------------------------------------------------
# Test Suite 1b: PSScriptAnalyzer Static Analysis (if available)
# ---------------------------------------------------------------------------
if ($env:PSMGR_SKIP_LINTER -ne '1' -and (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Write-Host "`n--> Running Test Suite 1b: PSScriptAnalyzer Rule Audit..." -ForegroundColor Yellow
    Assert-Test -Name "PSScriptAnalyzer Zero-Warning Audit" -TestBlock {
        $settingsPath = Join-Path -Path $Script:ROOT_DIR -ChildPath "PSScriptAnalyzerSettings.psd1"
        # Windows PowerShell 5.1 occasionally throws an internal "Collection was modified" error
        # while walking the tree; retry once, but never swallow a real finding.
        $results = $null
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                $results = Invoke-ScriptAnalyzer -Path $Script:ROOT_DIR -Settings $settingsPath -Recurse
                break
            } catch {
                if ($attempt -ge 2) { throw }
                Start-Sleep -Milliseconds 750
            }
        }
        $errorsAndWarns = @($results | Where-Object { $_.Severity -in 'Error', 'Warning' })
        if ($errorsAndWarns.Count -gt 0) {
            $issues = ($errorsAndWarns | ForEach-Object { "$($_.ScriptName):$($_.Line) [$($_.RuleName)] $($_.Message)" }) -join "; "
            throw "PSScriptAnalyzer violations ($($errorsAndWarns.Count)): $issues"
        }
    }
} elseif ($env:PSMGR_SKIP_LINTER -eq '1') {
    Write-Host "`n[INFO] PSScriptAnalyzer skipped (PSMGR_SKIP_LINTER=1)." -ForegroundColor Gray
} else {
    Write-Host "`n[INFO] PSScriptAnalyzer module not installed in current session. Skipping Suite 1b." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Test Suite 2: Module Manifest & Export Verification
# ---------------------------------------------------------------------------
Write-Host "`n--> Running Test Suite 2: Module Manifest & Contracts..." -ForegroundColor Yellow

Assert-Test -Name "Validate PSManager.psd1 manifest" -TestBlock {
    $manifestPath = Join-Path -Path $Script:ROOT_DIR -ChildPath "PSManager.psd1"
    $m = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    if (-not $m) { throw "Manifest returned null." }
    # Any semantic version is valid, but the changelog must document the released one.
    $ver = $m.Version.ToString()
    if ($ver -notmatch '^\d+\.\d+\.\d+$') { throw "Manifest version is not semantic: $ver" }
    $changelogPath = Join-Path -Path $Script:ROOT_DIR -ChildPath "CHANGELOG.md"
    $changelog = Get-Content -LiteralPath $changelogPath -Raw -Encoding UTF8
    if ($changelog -notmatch ('(?m)^## \[' + [regex]::Escape($ver) + '\]')) {
        throw "CHANGELOG.md has no '## [$ver]' section for the manifest version"
    }
}

Assert-Test -Name "Config path resolves inside the package root" -TestBlock {
    $manifestPath = Join-Path -Path $Script:ROOT_DIR -ChildPath "PSManager.psd1"
    Import-Module $manifestPath -Force -ErrorAction Stop
    $mod = Get-Module PSManager
    if (-not $mod) { throw "Module PSManager is not loaded." }
    $expected = Join-Path $mod.ModuleBase 'config.json'
    $actual = & $mod { $Script:CONFIG_PATH }
    if (-not $actual) { throw "CONFIG_PATH is empty." }
    if ((Resolve-Path -LiteralPath $actual).Path -ne (Resolve-Path -LiteralPath $expected).Path) {
        throw "Config path '$actual' does not resolve to '$expected'."
    }
}

Assert-Test -Name "Config writes BOM-free UTF-8 on both runtimes" -TestBlock {
    $manifestPath = Join-Path -Path $Script:ROOT_DIR -ChildPath "PSManager.psd1"
    Import-Module $manifestPath -Force -ErrorAction Stop
    $mod = Get-Module PSManager
    $tempConfig = Join-Path $env:TEMP ("psmgr_cfg_bom_{0}.json" -f (Get-Random))
    $originalConfigPath = & $mod { $Script:CONFIG_PATH }
    try {
        # Redirect only the module-scoped path, so the tracked config.json is never rewritten.
        $null = & $mod {
            param($Path)
            $Script:CONFIG_PATH = $Path
            Set-PSManagerConfig -Language 'vi' | Out-Null
        } $tempConfig
        $bytes = [System.IO.File]::ReadAllBytes($tempConfig)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw "config.json was written with a UTF-8 BOM (PS 5.1 Set-Content behaviour)."
        }
        $parsed = [System.IO.File]::ReadAllText($tempConfig) | ConvertFrom-Json
        if ($parsed.language -ne 'vi') { throw "Written config lost the language value." }
    } finally {
        # Later in-process tests must keep reading the real config path.
        $null = & $mod { param($Path) $Script:CONFIG_PATH = $Path } $originalConfigPath
        if (Test-Path -LiteralPath $tempConfig) { Remove-Item -LiteralPath $tempConfig -Force }
    }
}

Assert-Test -Name "Shipped sources contain no developer-specific paths" -TestBlock {
    $extensions = @('.ps1', '.psm1', '.psd1', '.json', '.xaml')
    $files = Get-ChildItem -LiteralPath $Script:ROOT_DIR -Recurse -File |
        Where-Object {
            ($extensions -contains $_.Extension) -and
            ($_.FullName -notmatch '\\(tests|docs|logs|backups)\\')
        }
    foreach ($file in $files) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ($text -match 'C:\\Users\\[A-Za-z0-9._-]+') {
            throw "Hard-coded developer path in $($file.FullName)"
        }
    }
}

Assert-Test -Name "Import PSManager module cleanly" -TestBlock {
    $manifestPath = Join-Path -Path $Script:ROOT_DIR -ChildPath "PSManager.psd1"
    Remove-Module PSManager -ErrorAction SilentlyContinue
    Import-Module $manifestPath -Force -ErrorAction Stop
}

Assert-Test -Name "Verify exported public API functions" -TestBlock {
    $expectedFunctions = @(
        'Initialize-ConsoleEncoding',
        'Get-PSManagerConfig',
        'Set-PSManagerConfig',
        'Get-EffectiveLanguage',
        'Get-I18nText',
        'Get-PSManagerActions',
        'Invoke-PSManagerAction',
        'Stop-PSManagerAction',
        'Get-WTSettingsPath',
        'Get-PSInstallations',
        'Get-PSManagerStatus',
        'Set-PowerShell7Default',
        'Set-PowerShell5Default',
        'Install-PSManagerProfileAliases',
        'Get-SourcePackageTarget',
        'Show-SourceMenu',
        'Invoke-PowerShellUpdate',
        'Invoke-PowerShellInstall',
        'Start-QuickShell',
        'Start-DesktopGUI',
        'Show-DiagnosticsScreen',
        'Show-TUI',
        'Show-PSManagerHelp',
        'Format-ColorText',
        'Format-ColorBadge',
        'Get-PSManagerTheme',
        'Set-PSManagerTheme',
        'Disable-PSManagerColor',
        'Write-PSManagerLog',
        'Get-PSManagerLogs',
        'Clear-PSManagerLogs',
        'Resolve-NormalizedPath',
        'New-SafeLink',
        'Test-FileIdentical',
        'Read-SyncManifest',
        'Test-SyncManifest',
        'Get-DefaultManifestTemplate',
        'Install-WingetBatch',
        'Install-ScoopBatch',
        'Install-PSGalleryBatch',
        'Initialize-ScoopEnvironment',
        'Backup-PSManagerProfiles',
        'Publish-PSManagerCloudBackup',
        'Set-PSManagerCloudRepo',
        'Get-PSManagerBackups',
        'Remove-PSManagerBackup',
        'Restore-PSManagerBackup',
        'Invoke-PSManagerSync',
        'Invoke-PSManagerDoctor',
        'Test-PSManagerProfile',
        'Repair-PSManagerProfile',
        'Get-PSManagerVersion',
        'Get-PSManagerHelpSections',
        'Get-PSManagerHelpEntry',
        'Get-PSManagerHelpLinks',
        'Add-PSManagerNotification',
        'Get-PSManagerNotifications',
        'Get-PSManagerNotificationView',
        'Set-PSManagerNotificationRead',
        'Clear-PSManagerNotifications',
        'Show-PSManagerToast',
        'ConvertTo-PSManagerReleaseStatus',
        'Get-PSManagerUpdateStatus',
        'Get-PSManagerUpdateStatusText',
        'Add-PSManagerUpdateNotification',
        'Save-PSManagerUpdatePackage',
        'Install-PSManagerUpdate'
    )
    $mod = Get-Module PSManager
    if (-not $mod) { throw "Module PSManager is not loaded." }
    foreach ($fn in $expectedFunctions) {
        if (-not ($mod.ExportedFunctions.ContainsKey($fn))) {
            throw "Missing exported function: $fn"
        }
    }
}

Assert-Test -Name "Verify Tri-Interface Parity Contract (CLI, TUI, GUI)" -TestBlock {
    $parityTestScript = Join-Path $Script:ROOT_DIR "tests\test_interface_parity.ps1"
    if (-not (Test-Path $parityTestScript)) { throw "test_interface_parity.ps1 missing" }
    & $parityTestScript
}

Assert-Test -Name "GUI async CLI bridge unit tests" -TestBlock {
    $guiAsyncTest = Join-Path $Script:ROOT_DIR "tests\test_gui_async.ps1"
    if (-not (Test-Path $guiAsyncTest)) { throw "test_gui_async.ps1 missing" }
    & $guiAsyncTest
    if ($LASTEXITCODE -ne 0) { throw "test_gui_async.ps1 failed" }
}

Assert-Test -Name "GUI XAML extraction, theme and page contract tests" -TestBlock {
    $guiXamlTest = Join-Path $Script:ROOT_DIR "tests\test_gui_xaml.ps1"
    if (-not (Test-Path $guiXamlTest)) { throw "test_gui_xaml.ps1 missing" }
    & $guiXamlTest
    if ($LASTEXITCODE -ne 0) { throw "test_gui_xaml.ps1 failed" }
}

Assert-Test -Name "GUI keyboard navigation and accessibility tests" -TestBlock {
    $guiKbTest = Join-Path $Script:ROOT_DIR "tests\test_gui_keyboard.ps1"
    if (-not (Test-Path $guiKbTest)) { throw "test_gui_keyboard.ps1 missing" }
    & $guiKbTest
    if ($LASTEXITCODE -ne 0) { throw "test_gui_keyboard.ps1 failed" }
}

Assert-Test -Name "TUI render, capabilities and action catalog tests" -TestBlock {
    $tuiRenderTest = Join-Path $Script:ROOT_DIR "tests\test_tui_render.ps1"
    if (-not (Test-Path $tuiRenderTest)) { throw "test_tui_render.ps1 missing" }
    & $tuiRenderTest
    if ($LASTEXITCODE -ne 0) { throw "test_tui_render.ps1 failed" }
}

Assert-Test -Name "TUI state reducer and keyboard mapping tests" -TestBlock {
    $tuiStateTest = Join-Path $Script:ROOT_DIR "tests\test_tui_state.ps1"
    if (-not (Test-Path $tuiStateTest)) { throw "test_tui_state.ps1 missing" }
    & $tuiStateTest
    if ($LASTEXITCODE -ne 0) { throw "test_tui_state.ps1 failed" }
}

Assert-Test -Name "TUI engine screen lifecycle and guard tests" -TestBlock {
    $tuiEngineTest = Join-Path $Script:ROOT_DIR "tests\test_tui_engine.ps1"
    if (-not (Test-Path $tuiEngineTest)) { throw "test_tui_engine.ps1 missing" }
    & $tuiEngineTest
    if ($LASTEXITCODE -ne 0) { throw "test_tui_engine.ps1 failed" }
}

Assert-Test -Name "Builder contract tests (launchers, packages, installer, MCP)" -TestBlock {
    if ($env:PSMGR_SKIP_BUILDER_TESTS -eq '1') {
        Write-Host '  [SKIP] Builder tests disabled by PSMGR_SKIP_BUILDER_TESTS'
        return
    }
    $builderTest = Join-Path $Script:ROOT_DIR "tests\test_builder.ps1"
    if (-not (Test-Path $builderTest)) { throw "test_builder.ps1 missing" }
    & $builderTest
    if ($LASTEXITCODE -ne 0) { throw "test_builder.ps1 failed" }
}

Assert-Test -Name "End-to-end sync flow tests" -TestBlock {
    $e2eTest = Join-Path $Script:ROOT_DIR "tests\test_e2e_sync.ps1"
    if (-not (Test-Path $e2eTest)) { throw "test_e2e_sync.ps1 missing" }
    & $e2eTest
    if ($LASTEXITCODE -ne 0) { throw "test_e2e_sync.ps1 failed" }
}

Assert-Test -Name "ActionEngine unit and contract tests" -TestBlock {
    $engineTest = Join-Path $Script:ROOT_DIR "tests\test_action_engine.ps1"
    if (-not (Test-Path $engineTest)) { throw "test_action_engine.ps1 missing" }
    & $engineTest
    if ($LASTEXITCODE -ne 0) { throw "test_action_engine.ps1 failed" }
}

Assert-Test -Name "ProfileAuditor unit and contract tests" -TestBlock {
    $auditorTest = Join-Path $Script:ROOT_DIR "tests\test_profile_auditor.ps1"
    if (-not (Test-Path $auditorTest)) { throw "test_profile_auditor.ps1 missing" }
    & $auditorTest
    if ($LASTEXITCODE -ne 0) { throw "test_profile_auditor.ps1 failed" }
}

Assert-Test -Name "Backup cleanup safety tests" -TestBlock {
    $cleanupTest = Join-Path $Script:ROOT_DIR "tests\test_backup_cleanup.ps1"
    if (-not (Test-Path $cleanupTest)) { throw "test_backup_cleanup.ps1 missing" }
    & $cleanupTest
    if ($LASTEXITCODE -ne 0) { throw "test_backup_cleanup.ps1 failed" }
}

# Module suites that live outside the harness's inline assertions. They are
# listed explicitly so the gate fails loudly if a file is renamed or deleted.
$moduleSuites = @(
    @{ Name = "Backup encryption, DPAPI and tamper tests"; File = "test_backup.ps1" }
    @{ Name = "Bootstrapper installation tests";           File = "test_bootstrapper.ps1" }
    @{ Name = "Safe link (hardlink/symlink/copy) tests";   File = "test_linker.ps1" }
    @{ Name = "Logger concurrency and retention tests";    File = "test_logger.ps1" }
    @{ Name = "Manifest parse and normalization tests";    File = "test_manifest.ps1" }
    @{ Name = "Provisioner dry-run and source tests";      File = "test_provisioner.ps1" }
    @{ Name = "Sync engine cross-runtime tests";           File = "test_sync_engine.ps1" }
    @{ Name = "Update notification, help catalog and self-update tests"; File = "test_update_notifier.ps1" }
)
foreach ($suite in $moduleSuites) {
    $suitePath = Join-Path $Script:ROOT_DIR ("tests\" + $suite.File)
    $suiteName = $suite.Name
    $suiteFile = $suite.File
    Assert-Test -Name $suiteName -TestBlock {
        if (-not (Test-Path -LiteralPath $suitePath)) { throw "$suiteFile missing" }
        & $suitePath
        if ($LASTEXITCODE -ne 0) { throw "$suiteFile failed" }
    }
}

Assert-Test -Name "Automation invariants: LF-only hooks, all test files registered" -TestBlock {
    $hookDir = Join-Path $Script:ROOT_DIR ".agents\hooks"
    foreach ($hook in Get-ChildItem -LiteralPath $hookDir -File) {
        $hookText = [System.IO.File]::ReadAllText($hook.FullName)
        if ($hookText.Contains("`r")) {
            throw "$($hook.Name) contains CR characters; sh parses the hook incorrectly (convert to LF)"
        }
    }

    $harnessText = [System.IO.File]::ReadAllText((Join-Path $Script:ROOT_DIR "tests\harness.ps1"))
    foreach ($testFile in Get-ChildItem -LiteralPath (Join-Path $Script:ROOT_DIR "tests") -Filter "test_*.ps1" -File) {
        if (-not $harnessText.Contains($testFile.Name)) {
            throw "$($testFile.Name) is not registered in tests/harness.ps1, so no gate runs it"
        }
    }
}

Assert-Test -Name "Run-Tests.ps1 dual-engine cross-verification contract" -TestBlock {
    $runnerText = [System.IO.File]::ReadAllText((Join-Path $Script:ROOT_DIR "tests\Run-Tests.ps1"))
    if ($runnerText -notmatch '\$isCore') {
        throw "Run-Tests.ps1 must determine whether current engine is Core to avoid redundant runs"
    }
    if ($runnerText -notmatch 'powershell\.exe' -or $runnerText -notmatch 'pwsh') {
        throw "Run-Tests.ps1 must support both powershell.exe and pwsh cross-verification"
    }
}

# ---------------------------------------------------------------------------
# Test Suite 3: Configuration Persistence & Schema
# ---------------------------------------------------------------------------
Write-Host "`n--> Running Test Suite 3: Configuration Persistence..." -ForegroundColor Yellow

Assert-Test -Name "Read and validate config schema" -TestBlock {
    $cfg = Get-PSManagerConfig
    if ($null -eq $cfg) { throw "Get-PSManagerConfig returned null" }
    if (-not $cfg.updateSource) { throw "Config missing updateSource" }
    if (-not $cfg.channel) { throw "Config missing channel" }
    if (-not $cfg.language) { throw "Config missing language" }
}

Assert-Test -Name "Update config values and verify persistence" -TestBlock {
    $orig = Get-PSManagerConfig
    $updated = Set-PSManagerConfig -Source "msstore" -Channel "preview" -Language "en"
    if ($updated.updateSource -ne "msstore") { throw "Failed to set source to msstore" }
    if ($updated.channel -ne "preview") { throw "Failed to set channel to preview" }
    if ($updated.language -ne "en") { throw "Failed to set language to en" }
    
    # Restore original configuration
    Set-PSManagerConfig -Source $orig.updateSource -Channel $orig.channel -Language $orig.language | Out-Null
}

# ---------------------------------------------------------------------------
# Test Suite 4: Package Source Resolution
# ---------------------------------------------------------------------------
Write-Host "`n--> Running Test Suite 4: Package Source Resolution..." -ForegroundColor Yellow

Assert-Test -Name "Resolve Winget Stable target" -TestBlock {
    $t = Get-SourcePackageTarget -Source "winget" -Channel "stable"
    if ($t.PackageId -ne "Microsoft.PowerShell") { throw "Expected Microsoft.PowerShell, got $($t.PackageId)" }
    if ($t.Source -ne "winget") { throw "Expected source winget, got $($t.Source)" }
}

Assert-Test -Name "Resolve Microsoft Store Stable target" -TestBlock {
    $t = Get-SourcePackageTarget -Source "msstore" -Channel "stable"
    if ($t.PackageId -ne "9MZ1SNWT0N5D") { throw "Expected 9MZ1SNWT0N5D, got $($t.PackageId)" }
    if ($t.Source -ne "msstore") { throw "Expected source msstore, got $($t.Source)" }
}

Assert-Test -Name "Resolve Microsoft Store Preview target" -TestBlock {
    $t = Get-SourcePackageTarget -Source "msstore" -Channel "preview"
    if ($t.PackageId -ne "9P95ZZKTNRN4") { throw "Expected 9P95ZZKTNRN4, got $($t.PackageId)" }
}

Assert-Test -Name "Resolve GitHub Releases target" -TestBlock {
    $t = Get-SourcePackageTarget -Source "github" -Channel "stable"
    if ($t.PackageId -ne "PowerShell/PowerShell") { throw "Expected PowerShell/PowerShell, got $($t.PackageId)" }
    if ($t.CommandType -ne "github") { throw "Expected commandType github, got $($t.CommandType)" }
}

# ---------------------------------------------------------------------------
# Test Suite 5: i18n & Font Adaptation Logic
# ---------------------------------------------------------------------------
Write-Host "`n--> Running Test Suite 5: i18n & Font Adaptation..." -ForegroundColor Yellow

Assert-Test -Name "Verify i18n dictionary file loading" -TestBlock {
    $i18nPath = Join-Path -Path $Script:ROOT_DIR -ChildPath "i18n.json"
    if (-not (Test-Path $i18nPath)) { throw "i18n.json missing" }
    $data = Get-Content $i18nPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $data.en -or -not $data.vi -or -not $data."vi-ascii") {
        throw "i18n.json missing one of required root languages: en, vi, vi-ascii"
    }
}

Assert-Test -Name "Explicit language mode is preserved on both engines" -TestBlock {
    $orig = Get-PSManagerConfig
    try {
        foreach ($mode in @('en', 'vi-ascii', 'vi')) {
            Set-PSManagerConfig -Language $mode | Out-Null
            $eff = Get-EffectiveLanguage
            if ($eff -ne $mode) {
                throw ("Configured '{0}' resolved to '{1}' on PS {2}" -f $mode, $eff, $PSVersionTable.PSVersion)
            }
        }
    } finally {
        Set-PSManagerConfig -Source $orig.updateSource -Channel $orig.channel -Language $orig.language | Out-Null
    }
}

Assert-Test -Name "Verify key translation with fallback" -TestBlock {
    $title = Get-I18nText "app_title"
    if ([string]::IsNullOrWhiteSpace($title)) { throw "Translation for app_title returned empty string" }
    $fallback = Get-I18nText "non_existent_key_xyz"
    if ($fallback -ne "non_existent_key_xyz") { throw "Fallback did not return key name" }
}

Assert-Test -Name "CLI help -NoColor suppresses all ANSI escape sequences" -TestBlock {
    $cliScript = Join-Path -Path $Script:ROOT_DIR -ChildPath "ps-manager.ps1"
    $engine = (Get-Process -Id $PID).Path
    if (-not $engine) {
        $engine = if ($PSVersionTable.PSVersion.Major -ge 7) { "pwsh.exe" } else { "powershell.exe" }
    }
    $out = & $engine -NoProfile -ExecutionPolicy Bypass -File $cliScript help -NoColor 6>&1 | Out-String
    $escChars = @($out.ToCharArray() | Where-Object { [int]$_ -eq 27 })
    if ($escChars.Count -gt 0) {
        throw "help -NoColor emitted $($escChars.Count) ESC character(s)"
    }
}
# ---------------------------------------------------------------------------
# Test Suite 6: Environment Detection & Status
# ---------------------------------------------------------------------------
Write-Host "`n--> Running Test Suite 6: System Detection..." -ForegroundColor Yellow

Assert-Test -Name "Query Get-PSManagerStatus without errors" -TestBlock {
    $s = Get-PSManagerStatus
    if ($null -eq $s) { throw "Get-PSManagerStatus returned null" }
    if ($null -eq $s.Installations) { throw "Installations property is null" }
    if ([string]::IsNullOrWhiteSpace($s.CurrentHostVersion)) { throw "CurrentHostVersion is empty" }
}

# ---------------------------------------------------------------------------
# Test Suite 7: Profile Sync & Provisioning Subsystem
# ---------------------------------------------------------------------------
Write-Host "`n--> Running Test Suite 7: Profile Sync & Provisioning..." -ForegroundColor Yellow

Assert-Test -Name "Resolve-NormalizedPath path expansion" -TestBlock {
    $p = Resolve-NormalizedPath "~/.config"
    if (-not $p.StartsWith($env:USERPROFILE)) { throw "Expected path to start with user profile, got: $p" }
}

Assert-Test -Name "Manifest template loading & validation" -TestBlock {
    $tmplPath = Join-Path $Script:ROOT_DIR "templates\manifest.default.json"
    if (-not (Test-Path $tmplPath)) { throw "manifest.default.json not found" }
    $m = Read-SyncManifest -ManifestPath $tmplPath
    $v = Test-SyncManifest -Manifest $m
    if (-not $v.IsValid) { throw "Default manifest failed validation: $($v.Errors -join '; ')" }
}

Assert-Test -Name "Invoke-PSManagerSync DryRun test" -TestBlock {
    $tmplPath = Join-Path $Script:ROOT_DIR "templates\manifest.default.json"
    $res = Invoke-PSManagerSync -ManifestPath $tmplPath -DryRun
    if (-not $res.Success) { throw "Sync dry-run reported failure: $($res.Message)" }
    if ($res.LinksProcessed -le 0) { throw "Expected links processed in dry-run, got 0" }
}

Assert-Test -Name "Invoke-PSManagerDoctor audit test" -TestBlock {
    $tmplPath = Join-Path $Script:ROOT_DIR "templates\manifest.default.json"
    $report = Invoke-PSManagerDoctor -ManifestPath $tmplPath
    if (-not $report -or $report.Count -eq 0) { throw "Doctor returned empty report" }
}

Assert-Test -Name "Write-PSManagerLog & Get-PSManagerLogs persistence" -TestBlock {
    $tDir = Join-Path $env:TEMP "harness_log_test_$(Get-Random)"
    New-Item -ItemType Directory -Path $tDir -Force | Out-Null
    try {
        Write-PSManagerLog -Message "Harness test log" -Level "INFO" -LogDirectory $tDir
        $logs = @(Get-PSManagerLogs -LogDirectory $tDir)
        if ($logs.Count -eq 0) { throw "Failed to read written log" }
        if ("$($logs -join ' ')" -notmatch "Harness test log") { throw "Log content mismatch" }
    } finally {
        Remove-Item -LiteralPath $tDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-Test -Name "Backup and restore preserves starship.toml config" -TestBlock {
    $mDir = Join-Path $env:TEMP "harness_backup_cfg_$(Get-Random)"
    New-Item -ItemType Directory -Path $mDir -Force | Out-Null
    try {
        $cDir = Join-Path $mDir ".config"
        New-Item -ItemType Directory -Path $cDir -Force | Out-Null
        "test_theme_data" | Out-File (Join-Path $cDir "starship.toml") -Encoding utf8
        $bDir = Join-Path $mDir "backups"
        $zip = Backup-PSManagerProfiles -DestinationDir $bDir -MockBaseDir $mDir
        if (-not (Test-Path $zip)) { throw "Backup failed to create zip" }
        "corrupted" | Out-File (Join-Path $cDir "starship.toml") -Encoding utf8
        $ok = Restore-PSManagerBackup -BackupZipPath $zip -MockBaseDir $mDir
        if (-not $ok) { throw "Restore reported false" }
        $restored = Get-Content (Join-Path $cDir "starship.toml") -Raw
        if ($restored -notmatch "test_theme_data") { throw "Failed to restore starship.toml content" }
    } finally {
        Remove-Item -LiteralPath $mDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Summary Report
# ---------------------------------------------------------------------------
Write-Host "`n================================================================================" -ForegroundColor Cyan
Write-Host "                              VALIDATION SUMMARY                                " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "Total Tests: $($Script:PassCount + $Script:FailCount) | Passed: $Script:PassCount | Failed: $Script:FailCount"

if ($Script:FailCount -gt 0) {
    Write-Host "`n[RESULT] Test suite FAILED with $Script:FailCount failure(s)." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n[RESULT] All tests PASSED successfully!" -ForegroundColor Green
    exit 0
}
