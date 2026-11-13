#Requires -Version 5.1
<#
.SYNOPSIS
    Unit and Contract Tests for PSManager Profile Compatibility Auditor (ProfileAuditor.ps1)
#>
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

Import-Module (Join-Path $RootDir "PSManager.psd1") -Force

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Check {
    param([string]$Name, [scriptblock]$TestBlock, [scriptblock]$SkipWhen)
    if ($SkipWhen -and (& $SkipWhen)) {
        Write-Host "  [SKIP] $Name - hard links unsupported on this volume" -ForegroundColor Yellow
        return
    }
    try {
        & $TestBlock
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $Name - $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add("$Name :: $($_.Exception.Message)")
    }
}

function Test-HardLinkSupport {
    param([string]$Dir)
    try {
        $src = Join-Path $Dir ".hl-probe-src"
        $dst = Join-Path $Dir ".hl-probe-dst"
        [System.IO.File]::WriteAllText($src, "probe")
        $null = New-Item -ItemType HardLink -Path $dst -Target $src -Force -ErrorAction Stop
        Remove-Item -LiteralPath $src, $dst -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

Write-Host "--> Running ProfileAuditor Unit & Contract Tests..." -ForegroundColor Cyan

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("psmgr_audit_test_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # 1. Test clean profile passes all checks
    $cleanProfile = Join-Path $tempDir "clean_profile.ps1"
    $cleanContent = @'
if (Get-Module -ListAvailable posh-git) { Import-Module posh-git -ErrorAction SilentlyContinue }
if ($env:TERM -ne 'dumb' -and (Get-Command starship -ErrorAction SilentlyContinue)) { Invoke-Expression (& starship init powershell) }
if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Module -ListAvailable Terminal-Icons)) { Import-Module Terminal-Icons -ErrorAction SilentlyContinue }
try { if (-not [Console]::IsOutputRedirected) { Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue } } catch {}
'@
    Set-Content -LiteralPath $cleanProfile -Value $cleanContent -Encoding UTF8

    Assert-Check -Name "Test-PSManagerProfile passes on clean compliant profile" -TestBlock {
        $checks = Test-PSManagerProfile -TargetVersion '5.1' -ProfilePath $cleanProfile
        $fails = @($checks | Where-Object { $_.Status -eq 'FAIL' })
        if ($fails.Count -gt 0) {
            throw "Expected 0 FAIL checks on clean profile, got $($fails.Count): $($fails.Details -join '; ')"
        }
    }

    # 2. Test detection of module load order inversion (posh-git after starship)
    $invertedProfile = Join-Path $tempDir "inverted_profile.ps1"
    $invertedContent = @'
Invoke-Expression (& starship init powershell)
Import-Module posh-git
'@
    Set-Content -LiteralPath $invertedProfile -Value $invertedContent -Encoding UTF8

    Assert-Check -Name "Test-PSManagerProfile detects inverted module load ordering" -TestBlock {
        $checks = Test-PSManagerProfile -TargetVersion 'All' -ProfilePath $invertedProfile
        $orderCheck = $checks | Where-Object { $_.Item -eq 'Module Load Order' }
        if (-not $orderCheck) { throw "Module Load Order check was not executed" }
        if ($orderCheck.Status -ne 'FAIL') { throw "Expected FAIL for inverted module order, got $($orderCheck.Status)" }
    }

    # 3. Test detection of unguarded Terminal-Icons on PS 5.1 target
    $unguardedProfile = Join-Path $tempDir "unguarded_profile.ps1"
    $unguardedContent = @'
Import-Module Terminal-Icons
'@
    Set-Content -LiteralPath $unguardedProfile -Value $unguardedContent -Encoding UTF8

    Assert-Check -Name "Test-PSManagerProfile detects unguarded Terminal-Icons on PS 5.1 target" -TestBlock {
        $checks = Test-PSManagerProfile -TargetVersion '5.1' -ProfilePath $unguardedProfile
        $guardCheck = $checks | Where-Object { $_.Item -eq 'Terminal-Icons Guard' }
        if (-not $guardCheck) { throw "Terminal-Icons Guard check was not executed" }
        if ($guardCheck.Status -ne 'FAIL') { throw "Expected FAIL for unguarded Terminal-Icons, got $($guardCheck.Status)" }
    }

    # 4. Test Repair-PSManagerProfile fixes ordering and guards
    Assert-Check -Name "Repair-PSManagerProfile automatically fixes ordering and guards" -TestBlock {
        $badProfile = Join-Path $tempDir "bad_profile.ps1"
        $badContent = @'
# Starship
Invoke-Expression (& starship init powershell)
# posh-git
Import-Module posh-git
Import-Module Terminal-Icons
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
'@
        Set-Content -LiteralPath $badProfile -Value $badContent -Encoding UTF8

        $repairs = Repair-PSManagerProfile -TargetVersion '5.1' -ProfilePath $badProfile
        $repairedContent = Get-Content -LiteralPath $badProfile -Raw -Encoding UTF8

        # After repair: posh-git must be before starship
        $pIdx = $repairedContent.IndexOf("posh-git")
        $sIdx = $repairedContent.IndexOf("starship init")
        if ($pIdx -gt $sIdx) { throw "posh-git still appears after starship after repair" }

        # Terminal-Icons must be guarded with PS7
        if ($repairedContent -notmatch '\$PSVersionTable\.PSVersion\.Major\s+-ge\s+7') {
            throw "Terminal-Icons was not guarded with PSVersionTable check"
        }

        # Prediction must be wrapped in try/catch
        if ($repairedContent -notmatch 'try\s*\{[^}]*Set-PSReadLineOption\s+-PredictionSource') {
            throw "Set-PSReadLineOption was not wrapped in try/catch"
        }
    }

    # 5. Token-based PS7-operator detection: real operators flagged, '?' in
    #    strings and the Where-Object alias must not be flagged.
    Assert-Check -Name "PS 5.1 compatibility flags real PS7 operators and ignores '?' in strings" -TestBlock {
        $opsProfile = Join-Path $tempDir "ops_profile.ps1"
        $opsContent = @'
# ? not an operator here
$pattern = '^--?model(=|$)'
$where = Get-ChildItem | ? { $_.Name }
$a = $null ?? 'fallback'
$b = $true ? 1 : 2
$c = 1 && 2
'@
        Set-Content -LiteralPath $opsProfile -Value $opsContent -Encoding UTF8
        $checks = Test-PSManagerProfile -TargetVersion '5.1' -ProfilePath $opsProfile
        $syntaxRow = $checks | Where-Object { $_.Item -eq 'AST Syntax' }
        $compatRow = $checks | Where-Object { $_.Item -eq 'PS 5.1 Syntax Compatibility' }
        if (-not $syntaxRow) { throw "AST Syntax check did not run" }
        if (-not $compatRow) { throw "PS 5.1 Syntax Compatibility check did not run" }

        # On PS 7 the tokenizer recognises ??/?:/&& and the compatibility check
        # reports them. On PS 5.1 those constructs do not tokenize at all, so the
        # AST syntax check is what fails. Either way the audit must not report PASS.
        if ($syntaxRow.Status -ne 'FAIL' -and $compatRow.Status -ne 'FAIL') {
            throw "Profile with PS7-only operators was reported clean (AST=$($syntaxRow.Status), Compat=$($compatRow.Status))"
        }
        if ($compatRow.Status -eq 'FAIL' -and $compatRow.Details -notmatch 'null-coalescing|ternary|pipeline') {
            throw "Compatibility FAIL lacks operator detail: $($compatRow.Details)"
        }
    }

    Assert-Check -Name "PS 5.1 compatibility passes on a profile whose only '?' is inside a string" -TestBlock {
        $safeProfile = Join-Path $tempDir "safe_profile.ps1"
        $safeContent = @'
$pattern = '^--?model(=|$)'
$where = Get-ChildItem | ? { $_.Name }
'@
        Set-Content -LiteralPath $safeProfile -Value $safeContent -Encoding UTF8
        $checks = Test-PSManagerProfile -TargetVersion '5.1' -ProfilePath $safeProfile
        $row = $checks | Where-Object { $_.Item -eq 'PS 5.1 Syntax Compatibility' }
        if ($row.Status -ne 'PASS') { throw "False positive on '?' in string: $($row.Details)" }
    }

    # 5. Repair MUST NOT write through a hardlink into the payload template
    Assert-Check -SkipWhen { -not (Test-HardLinkSupport -Dir $tempDir) } -Name "Repair-PSManagerProfile detaches a hardlinked profile instead of mutating its payload" -TestBlock {
        $payload = Join-Path $tempDir "master_profile.ps1"
        $live = Join-Path $tempDir "Microsoft.PowerShell_profile.ps1"
        $payloadContent = @'
# canonical payload template
Invoke-Expression (& starship init powershell)
Import-Module posh-git
'@
        Set-Content -LiteralPath $payload -Value $payloadContent -Encoding UTF8
        $null = New-Item -ItemType HardLink -Path $live -Target $payload -Force

        $null = Repair-PSManagerProfile -TargetVersion 'All' -ProfilePath $live

        $payloadAfter = Get-Content -LiteralPath $payload -Raw -Encoding UTF8
        $liveAfter = Get-Content -LiteralPath $live -Raw -Encoding UTF8
        if ($payloadAfter.Trim() -ne $payloadContent.Trim()) {
            throw "Repair mutated the payload template through the hardlink. Payload now: $payloadAfter"
        }
        if ($liveAfter.Trim() -eq $payloadContent.Trim()) {
            throw "Repair did not update the live profile"
        }
    }

    # 7. Audit must WARN when the live profile really shares an inode with the
    #    repo payload (templates\profiles), and name the peer.
    Assert-Check -SkipWhen { -not (Test-HardLinkSupport -Dir $tempDir) } -Name "Payload Link Safety warns when the profile shares an inode with templates\profiles" -TestBlock {
        $payloadDir = Join-Path $tempDir "templates\profiles"
        New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
        $payload = Join-Path $payloadDir "master_profile.ps1"
        $live = Join-Path $tempDir "linked_live_profile.ps1"
        Set-Content -LiteralPath $payload -Value "# canonical payload" -Encoding UTF8
        $null = New-Item -ItemType HardLink -Path $live -Target $payload -Force

        $checks = Test-PSManagerProfile -TargetVersion '5.1' -ProfilePath $live
        $row = $checks | Where-Object { $_.Item -eq 'Payload Link Safety' }
        if (-not $row) { throw "Payload Link Safety check did not run" }
        if ($row.Status -ne 'WARN') { throw "Expected WARN for a payload-linked profile, got $($row.Status)" }
        if ($row.Details -notmatch 'master_profile\.ps1') { throw "Warning did not name the payload peer: $($row.Details)" }
        if ($row.Recommendation -notmatch 'audit-profile -Fix') { throw "Warning lacks a remediation hint: $($row.Recommendation)" }
    }

    # 8. A 5.1<->7 link pair is legitimate and must not be blamed on the payload.
    Assert-Check -SkipWhen { -not (Test-HardLinkSupport -Dir $tempDir) } -Name "Payload Link Safety does not blame the payload for a live-to-live link pair" -TestBlock {
        $profile51 = Join-Path $tempDir "pair\5.1\Microsoft.PowerShell_profile.ps1"
        $profile7 = Join-Path $tempDir "pair\7\Microsoft.PowerShell_profile.ps1"
        foreach ($p in @($profile51, $profile7)) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force
        }
        Set-Content -LiteralPath $profile51 -Value "# shared profile" -Encoding UTF8
        $null = New-Item -ItemType HardLink -Path $profile7 -Target $profile51 -Force

        $checks = Test-PSManagerProfile -TargetVersion '5.1' -ProfilePath $profile51
        $row = $checks | Where-Object { $_.Item -eq 'Payload Link Safety' }
        if (-not $row) { throw "Payload Link Safety check did not run" }
        if ($row.Status -ne 'PASS') { throw "Live-to-live link should not warn, got $($row.Status): $($row.Details)" }
        if ($row.Details -match 'templates\\profiles') { throw "Details still assert payload linkage: $($row.Details)" }
        if ($row.Details -notmatch 'PowerShell\\Microsoft\.PowerShell_profile\.ps1|PowerShell_profile\.ps1') {
            throw "Details did not name the actual peer: $($row.Details)"
        }
    }

    # 9. Repair-PSManagerProfile detaches a profile linked to templates\profiles even when content is already compliant.
    Assert-Check -SkipWhen { -not (Test-HardLinkSupport -Dir $tempDir) } -Name "Repair-PSManagerProfile detaches payload link on compliant profile" -TestBlock {
        $payloadDir2 = Join-Path $tempDir "templates\profiles"
        if (-not (Test-Path -LiteralPath $payloadDir2)) {
            New-Item -ItemType Directory -Path $payloadDir2 -Force | Out-Null
        }
        $payload2 = Join-Path $payloadDir2 "master_profile_clean.ps1"
        $live2 = Join-Path $tempDir "compliant_linked_profile.ps1"
        $cleanContent = "# fully compliant profile`r`nWrite-Host 'OK'`r`n"
        Set-Content -LiteralPath $payload2 -Value $cleanContent -Encoding UTF8
        $null = New-Item -ItemType HardLink -Path $live2 -Target $payload2 -Force

        $repairs = Repair-PSManagerProfile -TargetVersion '5.1' -ProfilePath $live2
        $linkRep = $repairs | Where-Object { $_.Item -eq 'Link Safety' }
        if (-not $linkRep) { throw "Repair did not report Link Safety for payload-linked file" }
        if ($linkRep.Status -ne 'FIXED') { throw "Expected FIXED, got $($linkRep.Status)" }

        # Verify profile is now independent and passes audit
        $checksAfter = Test-PSManagerProfile -TargetVersion '5.1' -ProfilePath $live2
        $linkCheck = $checksAfter | Where-Object { $_.Item -eq 'Payload Link Safety' }
        if ($linkCheck.Status -ne 'PASS') { throw "Profile still reported as WARN after repair: $($linkCheck.Status)" }
    }
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host "`n[FAIL] test_profile_auditor.ps1 had $($failures.Count) failure(s)" -ForegroundColor Red
    exit 1
}

Write-Host "`n[PASS] test_profile_auditor.ps1 passed all checks" -ForegroundColor Green
exit 0
