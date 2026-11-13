#Requires -Version 5.1
<#
.SYNOPSIS
    Safety and behaviour tests for PSManager backup deletion (Remove-PSManagerBackup).
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
        if (-not (Test-Path -LiteralPath $Dir)) {
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        }
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

function New-BackupFixture {
    param([string]$Dir, [string[]]$Names)
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    foreach ($n in $Names) {
        Set-Content -LiteralPath (Join-Path $Dir $n) -Value "fixture-$n" -Encoding UTF8
    }
}

Write-Host "--> Running Backup Cleanup Safety Tests..." -ForegroundColor Cyan

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("psmgr_bkdel_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root -Force | Out-Null

try {
    # 1. -All removes every matching backup in the directory
    $d1 = Join-Path $root "all"
    New-BackupFixture -Dir $d1 -Names @('profile_backup_20260101_000001.zip', 'profile_backup_20260101_000002.zip')
    Assert-Check -Name "Remove-PSManagerBackup -All deletes every matching backup" -TestBlock {
        $res = Remove-PSManagerBackup -All -DestinationDir $d1 -Force -Confirm:$false
        if ($res.Deleted -ne 2) { throw "Expected 2 deleted, got $($res.Deleted)" }
        $left = @(Get-PSManagerBackups -DestinationDir $d1)
        if ($left.Count -ne 0) { throw "Expected 0 backups left, got $($left.Count)" }
    }

    # 2. -Name deletes exactly one backup and leaves the others intact
    $d2 = Join-Path $root "single"
    New-BackupFixture -Dir $d2 -Names @('profile_backup_20260102_000001.zip', 'profile_backup_20260102_000002.zip', 'profile_backup_20260102_000003.zip')
    Assert-Check -Name "Remove-PSManagerBackup -Name deletes only the named backup" -TestBlock {
        $res = Remove-PSManagerBackup -Name @('profile_backup_20260102_000002.zip') -DestinationDir $d2 -Force -Confirm:$false
        if ($res.Deleted -ne 1) { throw "Expected 1 deleted, got $($res.Deleted)" }
        $left = @(Get-PSManagerBackups -DestinationDir $d2)
        if ($left.Count -ne 2) { throw "Expected 2 backups left, got $($left.Count)" }
        if ($left.Name -contains 'profile_backup_20260102_000002.zip') { throw "Named backup was not deleted" }
    }

    # 3. Multiple names in one call
    $d3 = Join-Path $root "multi"
    New-BackupFixture -Dir $d3 -Names @('profile_backup_20260103_000001.zip', 'profile_backup_20260103_000002.zip', 'profile_backup_20260103_000003.zip')
    Assert-Check -Name "Remove-PSManagerBackup accepts multiple -Name values in one call" -TestBlock {
        $res = Remove-PSManagerBackup -Name @('profile_backup_20260103_000001.zip', 'profile_backup_20260103_000003.zip') -DestinationDir $d3 -Force -Confirm:$false
        if ($res.Deleted -ne 2) { throw "Expected 2 deleted, got $($res.Deleted)" }
        $left = @(Get-PSManagerBackups -DestinationDir $d3)
        if ($left.Count -ne 1) { throw "Expected 1 backup left, got $($left.Count)" }
        if ($left[0].Name -ne 'profile_backup_20260103_000002.zip') { throw "Wrong backup survived: $($left[0].Name)" }
    }

    # 4. -WhatIf must not delete anything
    $d4 = Join-Path $root "whatif"
    New-BackupFixture -Dir $d4 -Names @('profile_backup_20260104_000001.zip')
    Assert-Check -Name "Remove-PSManagerBackup -WhatIf performs no deletion" -TestBlock {
        $null = Remove-PSManagerBackup -All -DestinationDir $d4 -WhatIf
        $left = @(Get-PSManagerBackups -DestinationDir $d4)
        if ($left.Count -ne 1) { throw "WhatIf deleted files: $($left.Count) remain" }
    }

    # 5. Containment guard: a non-backup file in the same directory is never touched
    $d5 = Join-Path $root "guard"
    New-BackupFixture -Dir $d5 -Names @('profile_backup_20260105_000001.zip')
    $sentinel = Join-Path $d5 "do_not_delete.txt"
    Set-Content -LiteralPath $sentinel -Value "keep me" -Encoding UTF8
    Assert-Check -Name "Remove-PSManagerBackup never deletes non-backup files" -TestBlock {
        $null = Remove-PSManagerBackup -Name @('do_not_delete.txt') -DestinationDir $d5 -Force -Confirm:$false
        if (-not (Test-Path -LiteralPath $sentinel)) { throw "Non-backup file was deleted!" }
        $left = @(Get-PSManagerBackups -DestinationDir $d5)
        if ($left.Count -ne 1) { throw "Backup count changed unexpectedly: $($left.Count)" }
    }

    # 6. Path traversal attempt is refused
    $d6 = Join-Path $root "traversal"
    New-BackupFixture -Dir $d6 -Names @('profile_backup_20260106_000001.zip')
    $outside = Join-Path $root "outside_backup.zip"
    Set-Content -LiteralPath $outside -Value "outside" -Encoding UTF8
    Assert-Check -Name "Remove-PSManagerBackup refuses paths outside the backups directory" -TestBlock {
        $res = Remove-PSManagerBackup -Name @('..\outside_backup.zip') -DestinationDir $d6 -Force -Confirm:$false
        if ($res.Deleted -ne 0) { throw "Deleted $($res.Deleted) file(s) outside the backups directory" }
        if (-not (Test-Path -LiteralPath $outside)) { throw "File outside backups directory was deleted!" }
    }

    # 7. Missing selector is rejected (fail-closed)
    Assert-Check -Name "Remove-PSManagerBackup without -All or -Name throws" -TestBlock {
        $threw = $false
        try { $null = Remove-PSManagerBackup -DestinationDir $d6 -Force -Confirm:$false } catch { $threw = $true }
        if (-not $threw) { throw "Expected an exception when neither -All nor -Name is supplied" }
    }

    # 8. Non-existent directory returns a zeroed result instead of throwing
    Assert-Check -Name "Remove-PSManagerBackup on missing directory returns zeroed result" -TestBlock {
        $res = Remove-PSManagerBackup -All -DestinationDir (Join-Path $root "does-not-exist") -Force -Confirm:$false
        if ($res.Deleted -ne 0) { throw "Expected 0 deleted, got $($res.Deleted)" }
    }

    # 9. Logging records the destructive action
    Assert-Check -Name "Deletion writes a WARN entry to the diagnostic log" -TestBlock {
        $d9 = Join-Path $root "logged"
        New-BackupFixture -Dir $d9 -Names @('profile_backup_20260107_000001.zip')
        $null = Remove-PSManagerBackup -All -DestinationDir $d9 -Force -Confirm:$false
        $logs = Get-PSManagerLogs -Tail 20
        $hit = @($logs | Where-Object { $_ -match 'Backup cleanup: deleted=1' })
        if ($hit.Count -eq 0) { throw "No 'Backup cleanup' entry found in recent logs" }
    }

    # 10. Test-FileHardLink distinguishes linked vs independent files
    Assert-Check -SkipWhen { -not (Test-HardLinkSupport -Dir $root) } -Name "Test-FileHardLink detects a hardlinked file and clears a plain file" -TestBlock {
        $d10 = Join-Path $root "hardlink"
        New-Item -ItemType Directory -Path $d10 -Force | Out-Null
        $a = Join-Path $d10 "payload.ps1"
        $b = Join-Path $d10 "live.ps1"
        Set-Content -LiteralPath $a -Value "# payload" -Encoding UTF8
        $null = New-Item -ItemType HardLink -Path $b -Target $a -Force

        $mod = Get-Module PSManager
        $linked = & $mod { param($p) Test-FileHardLink -Path $p } $b
        $plain = & $mod { param($p) Test-FileHardLink -Path $p } $a
        # Both share the same inode, so both must be reported as linked.
        if (-not $linked) { throw "Hardlinked file was not detected as linked" }
        if (-not $plain) { throw "Original path of a hardlink pair was not detected as linked" }

        $c = Join-Path $d10 "solo.ps1"
        Set-Content -LiteralPath $c -Value "# solo" -Encoding UTF8
        $soloLinked = & $mod { param($p) Test-FileHardLink -Path $p } $c
        if ($soloLinked) { throw "Independent file was incorrectly reported as hardlinked" }
    }

    # 11. Set-DetachedFileContent must not mutate the other link holder
    Assert-Check -SkipWhen { -not (Test-HardLinkSupport -Dir $root) } -Name "Set-DetachedFileContent breaks the link instead of writing through it" -TestBlock {
        $d11 = Join-Path $root "detach"
        New-Item -ItemType Directory -Path $d11 -Force | Out-Null
        $payload = Join-Path $d11 "master_profile.ps1"
        $live = Join-Path $d11 "Microsoft.PowerShell_profile.ps1"
        Set-Content -LiteralPath $payload -Value "# canonical payload" -Encoding UTF8
        $null = New-Item -ItemType HardLink -Path $live -Target $payload -Force

        $mod = Get-Module PSManager
        $res = & $mod { param($p, $c) Set-DetachedFileContent -Path $p -Content $c } $live "# repaired live"
        if (-not $res.DetachedFromLink) { throw "DetachedFromLink flag was not set for a hardlinked target" }

        $payloadText = (Get-Content -LiteralPath $payload -Raw).Trim()
        $liveText = (Get-Content -LiteralPath $live -Raw).Trim()
        if ($payloadText -ne '# canonical payload') { throw "Payload template was mutated through the hardlink: $payloadText" }
        if ($liveText -ne '# repaired live') { throw "Live profile was not updated: $liveText" }
    }

    # 12. Set-DetachedFileContent creates missing files and reports no detachment
    Assert-Check -Name "Set-DetachedFileContent creates a missing file with a clean result" -TestBlock {
        $d12 = Join-Path $root "create"
        $target = Join-Path $d12 "nested\Microsoft.PowerShell_profile.ps1"
        $mod = Get-Module PSManager
        $res = & $mod { param($p, $c) Set-DetachedFileContent -Path $p -Content $c } $target "# new profile"
        if ($res.DetachedFromLink) { throw "DetachedFromLink should be false for a new file" }
        if (-not (Test-Path -LiteralPath $target)) { throw "File was not created" }
        if ((Get-Content -LiteralPath $target -Raw).Trim() -ne '# new profile') { throw "Content mismatch" }
    }

    # 13. Get-HardLinkPaths names every peer of a shared inode
    Assert-Check -SkipWhen { -not (Test-HardLinkSupport -Dir $root) } -Name "Get-HardLinkPaths lists both paths sharing an inode" -TestBlock {
        $d13 = Join-Path $root "peers"
        New-Item -ItemType Directory -Path $d13 -Force | Out-Null
        $a = Join-Path $d13 "master_profile.ps1"
        $b = Join-Path $d13 "Microsoft.PowerShell_profile.ps1"
        Set-Content -LiteralPath $a -Value "# payload" -Encoding UTF8
        $null = New-Item -ItemType HardLink -Path $b -Target $a -Force
        $mod = Get-Module PSManager
        $peers = @(& $mod { param($p) Get-HardLinkPaths -Path $p } $b)
        if ($peers.Count -lt 2) { throw "Expected 2 peer paths, got $($peers.Count): $($peers -join ', ')" }
        if (-not (@($peers | Where-Object { $_ -like '*Microsoft.PowerShell_profile.ps1' }).Count)) {
            throw "Peer list did not include the queried path: $($peers -join ', ')"
        }
        if (-not (@($peers | Where-Object { $_ -like '*master_profile.ps1' }).Count)) {
            throw "Peer list did not include the linked payload: $($peers -join ', ')"
        }
    }

    # 14. -Bytes writes verbatim (no re-encoding) and still detaches links
    Assert-Check -SkipWhen { -not (Test-HardLinkSupport -Dir $root) } -Name "Set-DetachedFileContent -Bytes preserves the exact byte sequence" -TestBlock {
        $d14 = Join-Path $root "bytes"
        New-Item -ItemType Directory -Path $d14 -Force | Out-Null
        $payload = Join-Path $d14 "master_profile.ps1"
        $live = Join-Path $d14 "Microsoft.PowerShell_profile.ps1"
        [System.IO.File]::WriteAllText($payload, "# payload`r`n", [System.Text.UTF8Encoding]::new($false))
        $null = New-Item -ItemType HardLink -Path $live -Target $payload -Force

        # UTF-16LE with BOM: any UTF-8 round-trip would corrupt these bytes.
        $bytes = [System.Text.UnicodeEncoding]::new($false, $true).GetBytes("Write-Host 'PS5'`r`n")
        $mod = Get-Module PSManager
        $res = & $mod { param($p, $b) Set-DetachedFileContent -Path $p -Bytes $b } $live $bytes
        if (-not $res.DetachedFromLink) { throw "DetachedFromLink flag was not set" }

        $written = [System.IO.File]::ReadAllBytes($live)
        if ([System.Convert]::ToBase64String($written) -ne [System.Convert]::ToBase64String($bytes)) {
            throw "Bytes were not written verbatim"
        }
        $payloadBytes = [System.IO.File]::ReadAllBytes($payload)
        if ([System.Convert]::ToBase64String($payloadBytes) -ne [System.Convert]::ToBase64String(
                [System.Text.UTF8Encoding]::new($false).GetBytes("# payload`r`n"))) {
            throw "Payload template was mutated through the hardlink"
        }
    }
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host "`n[FAIL] test_backup_cleanup.ps1 had $($failures.Count) failure(s)" -ForegroundColor Red
    exit 1
}

Write-Host "`n[PASS] test_backup_cleanup.ps1 passed all checks" -ForegroundColor Green
exit 0
