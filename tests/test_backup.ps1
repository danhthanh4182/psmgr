#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$BackupModule = Join-Path $RootDir "modules\Sync\Backup.ps1"

if (-not (Test-Path $BackupModule)) {
    Write-Error "Backup module not found at: $BackupModule"
    exit 1
}

. $BackupModule

$TempDir = Join-Path $env:TEMP "psmgr_test_backup_$(Get-Random)"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    # Create mock profiles
    $ps5Dir = Join-Path $TempDir "WindowsPowerShell"
    New-Item -ItemType Directory -Path $ps5Dir -Force | Out-Null
    "Write-Host 'PS5 Mock Profile'" | Out-File (Join-Path $ps5Dir "Microsoft.PowerShell_profile.ps1") -Encoding utf8

    $ps7Dir = Join-Path $TempDir "PowerShell"
    New-Item -ItemType Directory -Path $ps7Dir -Force | Out-Null
    "Write-Host 'PS7 Mock Profile'" | Out-File (Join-Path $ps7Dir "Microsoft.PowerShell_profile.ps1") -Encoding utf8

    $configDir = Join-Path $TempDir ".config"
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    "format = 'test_starship_theme'" | Out-File (Join-Path $configDir "starship.toml") -Encoding utf8

    $backupOutDir = Join-Path $TempDir "backups"

    # Test 1: Backup-PSManagerProfiles
    $zipCreated = Backup-PSManagerProfiles -DestinationDir $backupOutDir -MockBaseDir $TempDir
    if (-not (Test-Path $zipCreated)) {
        throw "Backup zip file was not created: $zipCreated"
    }

    # Test 2: Get-PSManagerBackups
    $backups = Get-PSManagerBackups -DestinationDir $backupOutDir
    if ($backups.Count -eq 0) {
        throw "Get-PSManagerBackups returned 0 backups"
    }

    # Test 3: Restore-PSManagerBackup
    # Modify files then restore
    "Modified Content" | Out-File (Join-Path $ps7Dir "Microsoft.PowerShell_profile.ps1") -Encoding utf8
    "Corrupted Starship" | Out-File (Join-Path $configDir "starship.toml") -Encoding utf8
    $restored = Restore-PSManagerBackup -BackupZipPath $zipCreated -MockBaseDir $TempDir
    if (-not $restored) {
        throw "Restore-PSManagerBackup failed"
    }
    $restoredContent = Get-Content (Join-Path $ps7Dir "Microsoft.PowerShell_profile.ps1") -Raw
    if ($restoredContent -notmatch "PS7 Mock Profile") {
        throw "Restored content did not match original backup"
    }
    $restoredStarship = Get-Content (Join-Path $configDir "starship.toml") -Raw
    if ($restoredStarship -notmatch "test_starship_theme") {
        throw "Restored starship.toml did not match original backup"
    }

    # Test 3b: Restore reproduces the archived bytes exactly (no re-encoding)
    $utf16Profile = Join-Path $ps5Dir "Microsoft.PowerShell_profile.ps1"
    $utf16Text = "Write-Host 'PS5 UTF-16 Profile'`r`n"
    [System.IO.File]::WriteAllText($utf16Profile, $utf16Text, [System.Text.UnicodeEncoding]::new($false, $true))
    $utf16Bytes = [System.IO.File]::ReadAllBytes($utf16Profile)
    $zipUtf16 = Backup-PSManagerProfiles -DestinationDir $backupOutDir -MockBaseDir $TempDir
    [System.IO.File]::WriteAllText($utf16Profile, "overwritten", [System.Text.UTF8Encoding]::new($false))
    $restoredUtf16 = Restore-PSManagerBackup -BackupZipPath $zipUtf16 -MockBaseDir $TempDir
    if (-not $restoredUtf16) { throw "Restore of the UTF-16 backup failed" }
    $afterBytes = [System.IO.File]::ReadAllBytes($utf16Profile)
    if ([System.Convert]::ToBase64String($afterBytes) -ne [System.Convert]::ToBase64String($utf16Bytes)) {
        throw "Restore re-encoded the profile instead of copying the archived bytes"
    }

    # Helper: build SecureString without ConvertTo-SecureString -AsPlainText
    function New-TestSecureString {
        param([string]$Plain)
        $ss = [System.Security.SecureString]::new()
        foreach ($c in $Plain.ToCharArray()) { $ss.AppendChar($c) }
        $ss.MakeReadOnly()
        return $ss
    }

    # Test 4: Passphrase-encrypted backup (PSMGR2 with HMAC-SHA256)
    $pass = New-TestSecureString "Test-Secure-P@ssphr4se-2026"
    $encBackup = Backup-PSManagerProfiles -DestinationDir $backupOutDir -MockBaseDir $TempDir -Passphrase $pass
    if (-not $encBackup.EndsWith(".enc") -or -not (Test-Path $encBackup)) {
        throw "Encrypted backup was not created: $encBackup"
    }

    # Test 5: Verify Get-PSManagerBackups sees encrypted backups
    $encList = Get-PSManagerBackups -DestinationDir $backupOutDir | Where-Object { $_.IsEncrypted -eq $true }
    if ($encList.Count -eq 0) {
        throw "Get-PSManagerBackups did not list encrypted backup"
    }

    # Test 6: Restore with wrong passphrase fails
    "Wrong Password Overwrite" | Out-File (Join-Path $ps7Dir "Microsoft.PowerShell_profile.ps1") -Encoding utf8
    $badPass = New-TestSecureString "WrongP@ssword!"
    $badRestore = $false
    try {
        $badRestore = Restore-PSManagerBackup -BackupZipPath $encBackup -MockBaseDir $TempDir -Passphrase $badPass -ErrorAction Stop
    } catch {
        # Expected error on bad passphrase
        $badRestore = $false
    }
    if ($badRestore) {
        throw "Restore with wrong passphrase unexpectedly succeeded"
    }

    # Test 7: Restore with correct passphrase succeeds
    $goodRestore = Restore-PSManagerBackup -BackupZipPath $encBackup -MockBaseDir $TempDir -Passphrase $pass
    if (-not $goodRestore) {
        throw "Restore with correct passphrase failed"
    }
    $restoredEncContent = Get-Content (Join-Path $ps7Dir "Microsoft.PowerShell_profile.ps1") -Raw
    if ($restoredEncContent -notmatch "PS7 Mock Profile") {
        throw "Restored content from encrypted backup did not match original"
    }

    # Test 8: DPAPI backup and transparent restore
    $dpapiBackup = Backup-PSManagerProfiles -DestinationDir $backupOutDir -MockBaseDir $TempDir -UseDPAPI
    if (-not $dpapiBackup.EndsWith(".enc") -or -not (Test-Path $dpapiBackup)) {
        throw "DPAPI backup was not created: $dpapiBackup"
    }
    "DPAPI Overwrite" | Out-File (Join-Path $ps7Dir "Microsoft.PowerShell_profile.ps1") -Encoding utf8
    $dpapiRestore = Restore-PSManagerBackup -BackupZipPath $dpapiBackup -MockBaseDir $TempDir
    if (-not $dpapiRestore) {
        throw "DPAPI restore failed"
    }
    $restoredDpapiContent = Get-Content (Join-Path $ps7Dir "Microsoft.PowerShell_profile.ps1") -Raw
    if ($restoredDpapiContent -notmatch "PS7 Mock Profile") {
        throw "Restored content from DPAPI backup did not match original"
    }

    # Test 9: Ciphertext tampering must fail HMAC authentication (PSMGR2)
    $tamperSrc = Backup-PSManagerProfiles -DestinationDir $backupOutDir -MockBaseDir $TempDir -Passphrase $pass
    $tamperBytes = [System.IO.File]::ReadAllBytes($tamperSrc)
    if ($tamperBytes.Length -le 70) {
        throw "Ciphertext buffer is unexpectedly smaller than header size (70 bytes)"
    }
    # Mutate a guaranteed ciphertext byte beyond the 70-byte header
    $flipIndex = [Math]::Min(75, $tamperBytes.Length - 1)
    $tamperBytes[$flipIndex] = $tamperBytes[$flipIndex] -bxor 0x01
    $tamperPath = "$tamperSrc.tampered.enc"
    [System.IO.File]::WriteAllBytes($tamperPath, $tamperBytes)
    "Tamper Overwrite" | Out-File (Join-Path $ps7Dir "Microsoft.PowerShell_profile.ps1") -Encoding utf8
    $tamperRestore = $false
    try {
        $tamperRestore = Restore-PSManagerBackup -BackupZipPath $tamperPath -MockBaseDir $TempDir -Passphrase $pass -ErrorAction Stop
    } catch {
        $tamperRestore = $false
    }
    if ($tamperRestore) {
        throw "Restore of tampered ciphertext unexpectedly succeeded - HMAC check is broken"
    }



    # Test 9b: the default backup directory is per-user, never the repo/install tree,
    # because a clone can live under a junction Windows rejects as an untrusted mount point.
    $defaultDir = Get-PSManagerBackupDir
    if ($defaultDir -notlike (Join-Path $env:LOCALAPPDATA 'PSManager\backups')) {
        throw ("Default backup dir is not the per-user state root: {0}" -f $defaultDir)
    }
    $env:PSMGR_BACKUP_DIR = (Join-Path $TempDir 'override-backups')
    try {
        if ((Get-PSManagerBackupDir) -ne $env:PSMGR_BACKUP_DIR) { throw 'PSMGR_BACKUP_DIR override ignored' }
    } finally {
        $env:PSMGR_BACKUP_DIR = $null
    }

    # Test 10: cloud repo resolution, normalization and the deploy-repo guard.

    # Stubs keep the checks offline: `gh`/`git` are plain functions, so no process runs and
    # every call is recorded, which also proves that a refused target never reaches an upload.
    $script:GhCalls = [System.Collections.Generic.List[string]]::new()
    $script:GhOutput = ''
    $script:GhExit = 0
    $script:GitOutput = ''
    $script:GitExit = 0
    $script:GhApiOutput = 'private true'
    $script:GhApiExit = 0
    $script:GhReleaseRepo = 'alice/private-backups'
    $script:GhReleaseOutput = ''
    $script:GhReleaseExit = 0
    $originalCloudRepoEnv = $env:PSMGR_CLOUD_REPO
    $originalCloudTokenEnv = $env:PSMGR_CLOUD_TOKEN
    $originalGhTokenEnv = $env:GH_TOKEN

    function gh.exe { }
    function gh {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
        $script:SeenGhToken = [string]$env:GH_TOKEN
        $script:GhCalls.Add(($Args -join ' '))
        if ($Args.Count -ge 1 -and $Args[0] -eq 'api') {
            if ($script:GhApiOutput) { Write-Output $script:GhApiOutput }
            $global:LASTEXITCODE = $script:GhApiExit
            return
        }
        if ($Args.Count -ge 2 -and $Args[0] -eq 'release' -and $Args[1] -eq 'create') {
            if ($script:GhReleaseExit -ne 0) {
                Write-Output $script:GhReleaseOutput
                $global:LASTEXITCODE = $script:GhReleaseExit
                return
            }
            Write-Output ('https://github.com/{0}/releases/tag/{1}' -f $script:GhReleaseRepo, $Args[2])
            $global:LASTEXITCODE = 0
            return
        }
        if ($script:GhOutput) { Write-Output $script:GhOutput }
        $global:LASTEXITCODE = $script:GhExit
    }
    function git {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
        if ($script:GitOutput) { Write-Output $script:GitOutput }
        $global:LASTEXITCODE = $script:GitExit
    }
    function Get-PSManagerConfig { [pscustomobject]@{ cloudRepo = $script:TestCloudRepo } }
    function Set-PSManagerConfig {
        param([string]$CloudRepo)
        $script:TestCloudRepo = $CloudRepo
        return [pscustomobject]@{ cloudRepo = $CloudRepo }
    }
    $script:TestCloudRepo = $null

    $slugCases = @{
        'owner/repo'                     = 'owner/repo'
        'owner/repo.git'                 = 'owner/repo'
        'github.com/owner/repo'          = 'owner/repo'
        'git@github.com:owner/repo.git'  = 'owner/repo'
        'https://github.com/owner/repo'  = 'owner/repo'
        'ssh://git@github.com/owner/repo' = 'owner/repo'
    }
    foreach ($slugInput in $slugCases.Keys) {
        if ((ConvertTo-PSManagerRepoSlug -Repo $slugInput) -ne $slugCases[$slugInput]) {
            throw ("ConvertTo-PSManagerRepoSlug('{0}') returned '{1}', expected '{2}'" -f $slugInput, (ConvertTo-PSManagerRepoSlug -Repo $slugInput), $slugCases[$slugInput])
        }
    }
    foreach ($bad in @('', 'owner', 'a/b/c', 'https://gitlab.com/owner/repo', 'owner/repo/extra')) {
        if ($null -ne (ConvertTo-PSManagerRepoSlug -Repo $bad)) {
            throw ("ConvertTo-PSManagerRepoSlug('{0}') accepted an unsupported reference" -f $bad)
        }
    }

    $appRepo = [string]$Script:PSMANAGER_APP_REPO
    $appForms = @(
        $appRepo,
        ('github.com/{0}' -f $appRepo),
        ('git@github.com:{0}.git' -f $appRepo),
        ('https://github.com/{0}' -f $appRepo)
    )
    foreach ($form in $appForms) {
        if (-not (Test-PSManagerSelfBackupRepo -Repo $form)) {
            throw ("Test-PSManagerSelfBackupRepo('{0}') did not detect the deploy repo" -f $form)
        }
        if (Test-PSManagerBackupRepo -Repo $form) {
            throw ("Test-PSManagerBackupRepo allowed the deploy repo via '{0}'" -f $form)
        }
    }
    if ($script:GhCalls.Count -ne 0) { throw 'The deploy-repo guard called an external command; refusal must be unconditional' }
    if (Test-PSManagerSelfBackupRepo -Repo 'someone/psmgr') { throw 'A foreign repo was reported as the deploy repo' }

    # A user repository is always allowed and never triggers a probe.
    if (-not (Test-PSManagerBackupRepo -Repo 'alice/private-backups')) { throw 'A foreign private repo was refused' }
    if ($script:GhCalls.Count -ne 0) { throw 'A foreign repo triggered an external call' }

    # Implicit resolution must skip the deploy repo.
    $script:GitOutput = ('git@github.com:{0}.git' -f $appRepo)
    $script:GitExit = 0
    $script:GhOutput = $appRepo
    $script:GhExit = 0
    $env:PSMGR_CLOUD_REPO = $null
    $script:TestCloudRepo = $null
    if ($null -ne (Get-DefaultBackupRepo)) {
        throw 'Get-DefaultBackupRepo resolved the deploy repo from git/gh instead of refusing it'
    }

    # A user clone resolves from its own origin, and an explicit env override wins.
    $script:GitOutput = 'git@github.com:alice/dotfiles.git'
    if ((Get-DefaultBackupRepo) -ne 'alice/dotfiles') { throw 'Get-DefaultBackupRepo did not use the clone origin' }
    $env:PSMGR_CLOUD_REPO = 'alice/env-backups'
    if ((Get-DefaultBackupRepo) -ne 'alice/env-backups') { throw 'PSMGR_CLOUD_REPO did not override resolution' }
    $env:PSMGR_CLOUD_REPO = $null

    # Set-PSManagerCloudRepo validates and guards before persisting.
    $invalidThrew = $false
    try { $null = Set-PSManagerCloudRepo -Repo 'not a repo' } catch { $invalidThrew = $true }
    if (-not $invalidThrew) { throw 'Set-PSManagerCloudRepo accepted an invalid reference' }
    $deployThrew = $false
    try { $null = Set-PSManagerCloudRepo -Repo ('github.com/{0}' -f $appRepo) } catch { $deployThrew = $true }
    if (-not $deployThrew) { throw 'Set-PSManagerCloudRepo accepted the deploy repo' }
    $saved = Set-PSManagerCloudRepo -Repo 'alice/private-backups'
    if ($saved.cloudRepo -ne 'alice/private-backups') { throw 'Set-PSManagerCloudRepo refused a user repo' }
    $saved = Set-PSManagerCloudRepo -Repo ''
    if ($saved.cloudRepo) { throw 'Set-PSManagerCloudRepo did not clear the target' }

    # Publish refuses the deploy repo in every accepted spelling, with zero uploads.
    $zipForPublish = Join-Path $backupOutDir 'publish-dummy.zip'
    Set-Content -LiteralPath $zipForPublish -Value 'not a real archive' -Encoding ASCII
    foreach ($target in $appForms) {
        $script:GhCalls.Clear()
        $refused = $false
        try {
            $null = Publish-PSManagerCloudBackup -BackupZipPath $zipForPublish -Repo $target
        } catch {
            $refused = $true
        }
        if (-not $refused) { throw ("Publish accepted the deploy repo via '{0}'" -f $target) }
        if ($script:GhCalls -match 'release') { throw ("Publish uploaded before the guard refused '{0}'" -f $target) }
    }

    # Credential / write-permission gating: missing token, read-only token and a wrong repo
    # must each abort before any release is created.
    $script:GhApiOutput = ''
    $script:GhApiExit = 1
    $script:GhCalls.Clear()
    $authThrew = $false
    try { $null = Publish-PSManagerCloudBackup -BackupZipPath $zipForPublish -Repo 'alice/private-backups' } catch { $authThrew = $_.Exception.Message }
    if (-not $authThrew -or $authThrew -notmatch 'credential|write-permission') {
        throw ("A missing credential did not produce an actionable error: {0}" -f $authThrew)
    }
    if ($script:GhCalls -match 'release') { throw 'Publish created a release without a valid credential' }

    $script:GhApiOutput = 'private false'
    $script:GhApiExit = 0
    $pushThrew = $false
    try { $null = Publish-PSManagerCloudBackup -BackupZipPath $zipForPublish -Repo 'alice/private-backups' } catch { $pushThrew = $_.Exception.Message }
    if (-not $pushThrew -or $pushThrew -notmatch 'cannot write') {
        throw ("A read-only credential did not produce a write-permission error: {0}" -f $pushThrew)
    }
    if ($script:GhCalls -match 'release') { throw 'Publish created a release with a read-only credential' }

    $script:GhApiOutput = 'private true'
    $script:GhApiExit = 0
    $script:GhCalls.Clear()
    $published = Publish-PSManagerCloudBackup -BackupZipPath $zipForPublish -Repo 'alice/private-backups'
    if (-not $published -or $published.Repo -ne 'alice/private-backups') {
        throw 'A fully authorised publish did not reach the upload step'
    }
    if (-not ($script:GhCalls -match '^release create')) { throw 'A fully authorised publish never called gh release create' }


    # A fine-grained token can pass the role-level preflight and still be refused by the upload
    # itself; that 403 must be reported as a missing Contents: write permission.
    $script:GhApiOutput = 'private true'
    $script:GhApiExit = 0
    $script:GhReleaseOutput = 'HTTP 403: Resource not accessible by personal access token (https://api.github.com/repos/alice/private-backups/releases)'
    $script:GhReleaseExit = 1
    $script:GhCalls.Clear()
    $restrictedThrew = $false
    try { $null = Publish-PSManagerCloudBackup -BackupZipPath $zipForPublish -Repo 'alice/private-backups' } catch { $restrictedThrew = $_.Exception.Message }
    if (-not $restrictedThrew -or $restrictedThrew -notmatch 'Contents: write') {
        throw ("A Contents:read-only token did not produce a Contents: write error: {0}" -f $restrictedThrew)
    }
    $script:GhReleaseOutput = ''
    $script:GhReleaseExit = 0

    # A public data repository is refused: personal archives may not be uploaded publicly.
    $script:GhApiOutput = 'public true'
    $script:GhApiExit = 0
    $publicThrew = $false
    try { $null = Publish-PSManagerCloudBackup -BackupZipPath $zipForPublish -Repo 'alice/public-repo' } catch { $publicThrew = $_.Exception.Message }
    if (-not $publicThrew -or $publicThrew -notmatch 'must be private') {
        throw ("A public data repo was not refused with a privacy error: {0}" -f $publicThrew)
    }

    # An explicit per-call token is scoped to the operation and the previous GH_TOKEN is restored.
    $script:GhApiOutput = 'private true'
    $script:GhApiExit = 0
    $env:GH_TOKEN = 'previous-token'
    $perCall = [System.Security.SecureString]::new()
    foreach ($ch in 'per-call-token'.ToCharArray()) { $perCall.AppendChar($ch) }
    $script:SeenGhToken = ''
    $null = Publish-PSManagerCloudBackup -BackupZipPath $zipForPublish -Repo 'alice/private-backups' -Token $perCall
    if ($script:SeenGhToken -ne 'per-call-token') { throw ('The per-call token never reached gh: {0}' -f $script:SeenGhToken) }
    if ($env:GH_TOKEN -ne 'previous-token') { throw 'The previous GH_TOKEN was not restored after the call' }
    $env:GH_TOKEN = $null

    # PSMGR_CLOUD_TOKEN is used when no token is supplied, and GH_TOKEN is still restored.
    $script:GhApiOutput = 'private true'
    $script:GhApiExit = 0
    $env:PSMGR_CLOUD_TOKEN = 'env-token'
    $script:SeenGhToken = ''
    $null = Publish-PSManagerCloudBackup -BackupZipPath $zipForPublish -Repo 'alice/private-backups'
    if ($script:SeenGhToken -ne 'env-token') { throw ('PSMGR_CLOUD_TOKEN never reached gh: {0}' -f $script:SeenGhToken) }
    if ($env:GH_TOKEN) { throw 'GH_TOKEN was not cleared after the env-token call' }
    $env:PSMGR_CLOUD_TOKEN = $null

    # An empty SecureString must not be forwarded: it would blank GH_TOKEN for the gh calls.
    $emptyToken = [System.Security.SecureString]::new()
    $env:GH_TOKEN = $null
    $script:SeenGhToken = 'sentinel'
    $null = Publish-PSManagerCloudBackup -BackupZipPath $zipForPublish -Repo 'alice/private-backups' -Token $emptyToken
    if ($script:SeenGhToken -ne '') { throw ('An empty token set GH_TOKEN to "{0}"' -f $script:SeenGhToken) }

    # Real native stderr under ErrorActionPreference=Stop: Windows PowerShell 5.1 turns a
    # merged '2>&1' native error into NativeCommandError, so a temporary gh.cmd proves the
    # capture still yields the credential verdict instead of an unhandled exception.
    $nativeDir = Join-Path $TempDir 'nativebin'
    New-Item -ItemType Directory -Path $nativeDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $nativeDir 'gh.cmd') -Encoding ASCII -Value @(
        '@echo off'
        'echo HTTP 401: Bad credentials (https://api.github.com/repos/alice/x) 1>&2'
        'exit /b 1'
    )
    $probe = Join-Path $TempDir 'native-probe.ps1'
    $probeBody = @"
`$ErrorActionPreference = 'Stop'
. '$BackupModule'
`$env:PATH = '$nativeDir;' + `$env:PATH
`$r = Test-PSManagerCloudWriteAccess -Repo 'alice/private-backups'
if (`$r.Ok) { throw 'native 401 was reported as success' }
if (`$r.Reason -notmatch 'credential') { throw ('unexpected reason: ' + `$r.Reason) }
'PROBE-OK'
"@
    Set-Content -LiteralPath $probe -Value $probeBody -Encoding UTF8
    $probeOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1 | Out-String
    if ($probeOutput -notmatch 'PROBE-OK') {
        throw ("Native stderr under ErrorActionPreference=Stop broke the credential check: {0}" -f $probeOutput.Trim())
    }

    # The CLI must surface a refused/invalid target as a readable error with a non-zero exit.
    $cliScript = Join-Path $RootDir 'ps-manager.ps1'
    $env:PSMGR_CLOUD_REPO = 'not-a-valid-repo'
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $cliOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File $cliScript backup-cloud -Value plain 2>&1 | Out-String)
        $cliExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        $env:PSMGR_CLOUD_REPO = $originalCloudRepoEnv
    }
    if ($cliExit -eq 0) { throw 'CLI backup-cloud exited 0 for an invalid repository reference' }
    if ($cliOut -notmatch 'Invalid repository reference|GitHub CLI') {
        throw ("CLI backup-cloud did not report the failure: {0}" -f $cliOut.Trim())
    }
    Write-Host "[PASS] test_backup.ps1 passed all checks" -ForegroundColor Green
    exit 0
}
finally {
    $env:PSMGR_CLOUD_REPO = $originalCloudRepoEnv
    $env:PSMGR_CLOUD_TOKEN = $originalCloudTokenEnv
    $env:GH_TOKEN = $originalGhTokenEnv
    if (Test-Path $TempDir) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
