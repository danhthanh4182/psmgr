#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager End-to-End Tests - User-Visible Sync Flows
.DESCRIPTION
    Exercises the same code paths a user's click/keystroke triggers, without a
    visible window:
      E2E-1. GUI "Dồng bộ Ngay" button flow: the exact CLI invocation the async
             bridge spawns (ps-manager.ps1 sync) must complete successfully,
             leave a Finished entry in the engine log, and create/verify links.
      E2E-2. GUI "Doctor" button flow: ps-manager.ps1 doctor must audit and
             exit 0.
      E2E-3. TUI [Y] Sync flow: the Show-TUI 'sync' branch behavior (module
             Invoke-PSManagerSync with defaults) completes with Success.
      E2E-4. TUI press_key prompt regression: every
             'Write-Host "`n" + (Get-I18nText "press_key")' string-concat bug
             (renders a stray '+') must stay fixed with proper parentheses.
      E2E-5. Default manifest template link sources exist on disk (a missing
             payload file once made every real sync fail while dry-run passed).
      E2E-6. Real sync against the shipped default manifest: links land and
             match their sources (idempotent re-run over the live machine).
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

$cliScript = Join-Path $RootDir "ps-manager.ps1"
$psBin = (Get-Process -Id $PID).Path
if (-not $psBin) {
    $psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("psmgr_e2e_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$targetProfile1 = Join-Path $tempDir "PowerShell_profile.ps1"
$targetProfile2 = Join-Path $tempDir "WindowsPowerShell_profile.ps1"
$targetStarship = Join-Path $tempDir "starship.toml"

$templatesDir = Join-Path $RootDir "templates"
$p1Src = Join-Path $templatesDir "profiles\master_profile.ps1"
$sSrc = Join-Path $templatesDir "configs\starship.toml"

$fixtureManifestPath = Join-Path $tempDir "manifest.fixture.json"
$fixtureContent = @{
    version  = "1.0.0"
    packages = @{
        winget    = @()
        scoop     = @{ buckets = @(); apps = @() }
        psgallery = @()
    }
    links = @(
        @{
            source  = $p1Src
            targets = @($targetProfile1, $targetProfile2)
            type    = "copy"
        },
        @{
            source  = $sSrc
            targets = @($targetStarship)
            type    = "copy"
        }
    )
    env = @{
        PSMGR_E2E_TEST = "1"
    }
} | ConvertTo-Json -Depth 5
Set-Content -LiteralPath $fixtureManifestPath -Value $fixtureContent -Encoding UTF8

try {
    # ---------------------------------------------------------------------------
    # E2E-1: GUI "Sync Now" flow = hidden child running `ps-manager.ps1 sync`
    # ---------------------------------------------------------------------------
    Write-Host "--> E2E-1: GUI Sync Now flow (CLI child, isolated sandbox)" -ForegroundColor Yellow
    Assert-Check -Name "GUI Sync Now backend: psmgr sync reports success" -TestBlock {
        $out = & $psBin -NoProfile -ExecutionPolicy Bypass -File $cliScript 'sync' -Manifest $fixtureManifestPath -SkipPackages 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "sync exited $LASTEXITCODE`n$out" }
        # The CLI prints a success glyph (or ASCII fallback) followed by the summary.
        if ($out -notmatch 'Sync completed successfully') {
            throw "Expected the sync summary in output, got: $($out.Trim())"
        }
    }
    Assert-Check -Name "GUI Sync Now leaves Finished entry in engine log" -TestBlock {
        $logs = Get-PSManagerLogs -Tail 5
        $finished = @($logs | Where-Object { $_ -match 'Finished PSManager Sync: Sync completed successfully' })
        if ($finished.Count -eq 0) { throw "No Finished-success entry in recent logs: $($logs -join ' | ')" }
    }

    # ---------------------------------------------------------------------------
    # E2E-2: GUI "Doctor" flow
    # ---------------------------------------------------------------------------
    Write-Host "`n--> E2E-2: GUI Doctor flow" -ForegroundColor Yellow
    Assert-Check -Name "GUI Doctor backend: psmgr doctor audits and exits 0" -TestBlock {
        $out = & $psBin -NoProfile -ExecutionPolicy Bypass -File $cliScript 'doctor' -Manifest $fixtureManifestPath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "doctor exited $LASTEXITCODE`n$out" }
        if ($out -notmatch 'PASS') { throw "Doctor produced no PASS lines" }
    }

    # ---------------------------------------------------------------------------
    # E2E-3: TUI [Y] Sync flow = module-level Invoke-PSManagerSync
    # ---------------------------------------------------------------------------
    Write-Host "`n--> E2E-3: TUI [Y] Sync flow" -ForegroundColor Yellow
    Assert-Check -Name "TUI sync action: Invoke-PSManagerSync with fixture succeeds" -TestBlock {
        $res = Invoke-PSManagerSync -ManifestPath $fixtureManifestPath -SkipPackages
        if (-not $res.Success) { throw "Sync failed: $($res.Message)" }
        if ($res.LinksProcessed -lt 3) { throw "Expected >=3 links, got $($res.LinksProcessed)" }
    }

    # ---------------------------------------------------------------------------
    # E2E-4: TUI press_key prompt must be a parenthesized string concat
    # ---------------------------------------------------------------------------
    Write-Host "`n--> E2E-4: TUI press_key prompt regression" -ForegroundColor Yellow
    Assert-Check -Name "No unparenthesized Write-Host concat bugs remain in TUI modules" -TestBlock {
        $uiFiles = @(
            (Join-Path $RootDir "modules\UI\TuiEngine.ps1"),
            (Join-Path $RootDir "modules\Package\SourceManager.ps1")
        )
        foreach ($file in $uiFiles) {
            $src = Get-Content -LiteralPath $file -Raw -Encoding UTF8
            $bad = [regex]::Matches($src, 'Write-Host\s+"`n"\s*\+')
            if ($bad.Count -gt 0) {
                throw "Found $($bad.Count) unparenthesized 'Write-Host `"n`" + ...' in $(Split-Path $file -Leaf)"
            }
        }
    }

    # ---------------------------------------------------------------------------
    # E2E-5: default manifest link sources exist on disk
    # ---------------------------------------------------------------------------
    Write-Host "`n--> E2E-5: Default manifest payload integrity" -ForegroundColor Yellow
    Assert-Check -Name "Every default-manifest link source exists on disk" -TestBlock {
        $manifestPath = Join-Path $RootDir "templates\manifest.default.json"
        $m = Read-SyncManifest -ManifestPath $manifestPath
        $payloadDir = Split-Path -Parent $manifestPath
        foreach ($link in $m.links) {
            $src = if ([System.IO.Path]::IsPathRooted($link.source)) { $link.source } else { Join-Path $payloadDir $link.source }
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
                throw "Manifest link source missing: $src (sync would fail for every target)"
            }
        }
    }

    # ---------------------------------------------------------------------------
    # E2E-6: sandboxed links match sources after sync (idempotence)
    # ---------------------------------------------------------------------------
    Write-Host "`n--> E2E-6: Sandboxed link integrity after sync" -ForegroundColor Yellow
    Assert-Check -Name "Synced sandbox links are identical to their sources" -TestBlock {
        $m = Read-SyncManifest -ManifestPath $fixtureManifestPath
        foreach ($link in $m.links) {
            $src = $link.source
            foreach ($targetRaw in $link.targets) {
                $target = Resolve-NormalizedPath -Path $targetRaw
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                    throw "Link target missing: $target"
                }
                if (-not (Test-FileIdentical -PathA $src -PathB $target)) {
                    throw "Link target differs from source: $target"
                }
            }
        }
    }
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($failures.Count -gt 0) {
    Write-Host "`n[PASS/FAIL SUMMARY] $($failures.Count) failure(s):" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Yellow }
    exit 1
}
Write-Host "`n[PASS] test_e2e_sync.ps1 passed all checks" -ForegroundColor Green
exit 0
