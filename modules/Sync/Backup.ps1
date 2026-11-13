#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Profile Snapshot & Restore Engine
.DESCRIPTION
    Creates versioned zip backups of active shell profiles and configurations,
    with fast rollback / restore capabilities.
#>

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# The deploy repository (this project). The deploy repo and a user's data repository are two
# separate repositories, so profile backups — which hold personal data — never target it: not
# by implicit resolution, not via -Repo, and not even while it is private.
$Script:PSMANAGER_APP_REPO = 'danhthanh4182/psmgr'

function ConvertTo-PSManagerRepoSlug {
    # Normalizes a GitHub.com repository reference to 'owner/repo'.
    # Accepted: owner/repo, owner/repo.git, github.com/owner/repo,
    # git@github.com:owner/repo.git, https://github.com/owner/repo(.git),
    # ssh://git@github.com/owner/repo(.git). Any other host or malformed
    # reference returns $null: this engine publishes to GitHub only, so a
    # foreign host must never be silently rewritten into a github.com slug.
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Repo)

    if ([string]::IsNullOrWhiteSpace($Repo)) { return $null }
    $value = (([string]$Repo).Trim() -replace '\s+', '')
    $value = $value -replace '[#?].*$', ''
    $value = $value.TrimEnd('/')

    $patterns = @(
        '^(?i:https?)://(?i:github\.com)/(?<slug>[^/]+/[^/]+)$',
        '^(?i:ssh)://(?i:git@)?(?i:github\.com)/(?<slug>[^/]+/[^/]+)$',
        '^(?i:git@)?(?i:github\.com)[:/](?<slug>[^/]+/[^/]+)$'
    )
    foreach ($pattern in $patterns) {
        if ($value -match $pattern) { $value = $Matches['slug']; break }
    }

    if ($value.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(0, $value.Length - 4)
    }
    if ($value -match '^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$') { return $value }
    return $null
}

function Test-PSManagerSelfBackupRepo {
    # True when $Repo (in any gh-accepted form) is the PSManager application repository.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Repo)

    $slug = ConvertTo-PSManagerRepoSlug -Repo $Repo
    if (-not $slug) { return $false }
    return ($slug.ToLowerInvariant() -eq $Script:PSMANAGER_APP_REPO)
}

function Test-PSManagerBackupRepo {
    # Returns $true only when a profile backup may be published to $Repo.
    # The deploy repository (code + app releases) and the data repository (profile backups)
    # are always two separate repositories, so the app repo is refused unconditionally —
    # not even while it is private. Malformed references are refused too.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Repo)

    $slug = ConvertTo-PSManagerRepoSlug -Repo $Repo
    if (-not $slug) { return $false }
    return (-not (Test-PSManagerSelfBackupRepo -Repo $slug))
}
function Test-PSManagerCloudWriteAccess {
    # Best-effort preflight for the credential gh will use (GH_TOKEN -> GITHUB_TOKEN ->
    # 'gh auth token'). It proves the credential exists, can read $Repo and holds the push
    # role there. It cannot prove a fine-grained PAT carries Contents: write, because
    # '.permissions.push' describes the account's role; the release upload's own 403 is
    # authoritative and is reported separately. Returns @{ Ok; Reason }.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][string]$Repo)

    # Windows PowerShell 5.1 turns merged native stderr (2>&1) into a terminating
    # NativeCommandError when ErrorActionPreference is Stop, so the capture runs under Continue.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& gh api "repos/$Repo" --jq '.visibility + " " + (.permissions.push|tostring)' 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -eq 0) {
        $parts = @($output -split '\s+' | Where-Object { $_ })
        $visibility = if ($parts.Count -ge 1) { $parts[0].ToUpperInvariant() } else { '' }
        $push = if ($parts.Count -ge 2) { $parts[1].ToLowerInvariant() } else { '' }
        if ($visibility -in @('PUBLIC', 'INTERNAL')) {
            return @{
                Ok     = $false
                Reason = ("'{0}' is {1}. A profile backup carries personal data, so the data repository must be private; change the repository visibility or point cloudRepo at a private one" -f $Repo, $visibility.ToLowerInvariant())
            }
        }
        if ($push -eq 'true') { return @{ Ok = $true; Reason = '' } }
        return @{
            Ok     = $false
            Reason = ("the current GitHub credential can read '{0}' but cannot write to it; grant Contents: read and write (or a repo scope) to the token" -f $Repo)
        }
    }
    if ($output -match '(?i)(401|bad credentials|authenticat|gh_token|gh auth login)') {
        return @{
            Ok     = $false
            Reason = 'no valid GitHub credential was found; run ''gh auth login'' once or export GH_TOKEN / GITHUB_TOKEN (fine-grained token limited to this private repository, Contents: read and write)'
        }
    }
    if ($output -match '(?i)(404|not found)') {
        return @{
            Ok     = $false
            Reason = ("'{0}' was not found for the current credential; check the name and that the token may access that private repository" -f $Repo)
        }
    }
    return @{ Ok = $false; Reason = ("the write-permission check failed: {0}" -f $output) }
}
function Set-PSManagerCloudRepo {
    <#
    .SYNOPSIS
        Sets or clears the cloud backup target repository.
    .DESCRIPTION
        Validates the reference, refuses targets that would publish personal data into the
        PSManager app repository (see Test-PSManagerBackupRepo), then persists the choice in
        config.json. Pass an empty string to clear it and fall back to auto-resolution.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Repo)

    $slug = ConvertTo-PSManagerRepoSlug -Repo $Repo
    if (-not [string]::IsNullOrWhiteSpace($Repo)) {
        if (-not $slug) { throw ("Invalid repository reference '{0}'. Pass 'owner/repo'." -f $Repo) }
        if (-not (Test-PSManagerBackupRepo -Repo $slug)) {
            throw ("Refusing to use '{0}' as the cloud backup repository. The deploy repository and your data repository are separate: backups hold personal data, so point this at your own private repository." -f $slug)
        }
    }
    $envSlug = ConvertTo-PSManagerRepoSlug -Repo ([string]$env:PSMGR_CLOUD_REPO)
    if ($slug -and $envSlug -and $envSlug -ne $slug) {
        Write-Warning ("`$env:PSMGR_CLOUD_REPO='{0}' takes precedence over the saved target '{1}' on this machine." -f $env:PSMGR_CLOUD_REPO, $slug)
    }
    return (Set-PSManagerConfig -CloudRepo $slug)
}

function Backup-PSManagerProfiles {
    [CmdletBinding()]
    param(
        [string]$DestinationDir,
        [string]$MockBaseDir,
        [Security.SecureString]$Passphrase,
        [switch]$UseDPAPI
    )

    $defaultBackupDir = if (-not [string]::IsNullOrEmpty($DestinationDir)) {
        $DestinationDir
    } else {
        Join-Path $env:USERPROFILE "tools\ps-manager\backups"
    }

    if (-not (Test-Path -LiteralPath $defaultBackupDir)) {
        New-Item -ItemType Directory -Path $defaultBackupDir -Force | Out-Null
    }

    $baseDocs = if (-not [string]::IsNullOrEmpty($MockBaseDir)) {
        $MockBaseDir
    } else {
        [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments)
    }

    $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
    $stagingDir = Join-Path $env:TEMP "psmgr_backup_stage_$timestamp"
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

    try {
        # PS5 Profile
        $ps5Profile = Join-Path $baseDocs "WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
        if (Test-Path -LiteralPath $ps5Profile) {
            $destPs5Dir = Join-Path $stagingDir "WindowsPowerShell"
            New-Item -ItemType Directory -Path $destPs5Dir -Force | Out-Null
            Copy-Item -LiteralPath $ps5Profile -Destination (Join-Path $destPs5Dir "Microsoft.PowerShell_profile.ps1") -Force
        }

        # PS7 Profile
        $ps7Profile = Join-Path $baseDocs "PowerShell\Microsoft.PowerShell_profile.ps1"
        if (Test-Path -LiteralPath $ps7Profile) {
            $destPs7Dir = Join-Path $stagingDir "PowerShell"
            New-Item -ItemType Directory -Path $destPs7Dir -Force | Out-Null
            Copy-Item -LiteralPath $ps7Profile -Destination (Join-Path $destPs7Dir "Microsoft.PowerShell_profile.ps1") -Force
        }

        # Configs
        $configHome = if (-not [string]::IsNullOrEmpty($MockBaseDir)) {
            Join-Path $MockBaseDir ".config"
        } else {
            Join-Path $env:USERPROFILE ".config"
        }
        $starshipToml = Join-Path $configHome "starship.toml"
        if (Test-Path -LiteralPath $starshipToml) {
            $destConfigDir = Join-Path $stagingDir "configs"
            New-Item -ItemType Directory -Path $destConfigDir -Force | Out-Null
            Copy-Item -LiteralPath $starshipToml -Destination (Join-Path $destConfigDir "starship.toml") -Force
        }

        $zipPath = Join-Path $defaultBackupDir "profile_backup_$timestamp.zip"
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force
        }

        [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $zipPath)

        if ($Passphrase) {
            $encPath = Protect-PSManagerBackup -BackupZipPath $zipPath -Passphrase $Passphrase
            Remove-Item -LiteralPath $zipPath -Force
            return $encPath
        } elseif ($UseDPAPI) {
            $encPath = Protect-PSManagerBackup -BackupZipPath $zipPath -UseDPAPI
            Remove-Item -LiteralPath $zipPath -Force
            return $encPath
        }

        return $zipPath
    } finally {
        if (Test-Path -LiteralPath $stagingDir) {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Protect-PSManagerBackup {
    # Encrypts a backup zip with AES-256-CBC + HMAC-SHA256 (Encrypt-then-MAC, PSMGR2)
    # under a passphrase-derived key, or via Windows DPAPI (PSMGRD) for user-bound local backups.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupZipPath,

        [Security.SecureString]$Passphrase,

        [switch]$UseDPAPI
    )

    if (-not (Test-Path -LiteralPath $BackupZipPath -PathType Leaf)) {
        throw "Backup archive not found: $BackupZipPath"
    }

    if (-not $Passphrase -and -not $UseDPAPI) {
        throw "Either -Passphrase or -UseDPAPI must be specified to protect backup"
    }

    $plain = [System.IO.File]::ReadAllBytes($BackupZipPath)

    if ($UseDPAPI) {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $entropy = [System.Text.Encoding]::UTF8.GetBytes("PSManagerBackupEntropy")
        $enc = [System.Security.Cryptography.ProtectedData]::Protect(
            $plain, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)

        $magic = [System.Text.Encoding]::ASCII.GetBytes("PSMGRD")
        $blob = [byte[]]::new($magic.Length + $enc.Length)
        [Array]::Copy($magic, 0, $blob, 0, $magic.Length)
        [Array]::Copy($enc, 0, $blob, $magic.Length, $enc.Length)

        $outPath = "$BackupZipPath.enc"
        [System.IO.File]::WriteAllBytes($outPath, $blob)
        return $outPath
    }

    # Passphrase path: PSMGR2 format (AES-256-CBC + HMAC-SHA256)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase)
    try {
        $pass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        if ([string]::IsNullOrEmpty($pass)) { throw "Passphrase is empty" }

        $salt = [byte[]]::new(16)
        $iv   = [byte[]]::new(16)
        $rng  = [Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($salt)
        $rng.GetBytes($iv)
        $rng.Dispose()

        $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($pass, $salt, 100000,
            [Security.Cryptography.HashAlgorithmName]::SHA256)
        $keyMat = $derive.GetBytes(64)
        $encKey = [byte[]]::new(32); [Array]::Copy($keyMat, 0, $encKey, 0, 32)
        $macKey = [byte[]]::new(32); [Array]::Copy($keyMat, 32, $macKey, 0, 32)

        $aes = [Security.Cryptography.Aes]::Create()
        try {
            $aes.Key = $encKey
            $aes.IV = $iv
            $aes.Mode = [Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
            $enc = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
        } finally {
            $aes.Dispose()
            $derive.Dispose()
        }

        # AuthData = Magic(6) + Salt(16) + IV(16) + Ciphertext(N)
        $magic = [System.Text.Encoding]::ASCII.GetBytes("PSMGR2")
        $authData = [byte[]]::new(38 + $enc.Length)
        [Array]::Copy($magic, 0, $authData, 0, 6)
        [Array]::Copy($salt, 0, $authData, 6, 16)
        [Array]::Copy($iv, 0, $authData, 22, 16)
        [Array]::Copy($enc, 0, $authData, 38, $enc.Length)

        $hmac = [Security.Cryptography.HMACSHA256]::new($macKey)
        $tag = $hmac.ComputeHash($authData)
        $hmac.Dispose()

        # Blob = Magic(6) + Salt(16) + IV(16) + Tag(32) + Ciphertext(N)
        $blob = [byte[]]::new(70 + $enc.Length)
        [Array]::Copy($magic, 0, $blob, 0, 6)
        [Array]::Copy($salt, 0, $blob, 6, 16)
        [Array]::Copy($iv, 0, $blob, 22, 16)
        [Array]::Copy($tag, 0, $blob, 38, 32)
        [Array]::Copy($enc, 0, $blob, 70, $enc.Length)

        $outPath = "$BackupZipPath.enc"
        [System.IO.File]::WriteAllBytes($outPath, $blob)
        return $outPath
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Unprotect-PSManagerBackup {
    # Decrypts a .zip.enc produced by Protect-PSManagerBackup.
    # Automatically dispatches to DPAPI (PSMGRD) or Passphrase (PSMGR2 with HMAC verification / legacy PSMGR1).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EncryptedPath,

        [Security.SecureString]$Passphrase,

        [switch]$UseDPAPI,

        [string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $EncryptedPath -PathType Leaf)) {
        throw "Encrypted archive not found: $EncryptedPath"
    }

    $blob = [System.IO.File]::ReadAllBytes($EncryptedPath)
    if ($blob.Length -lt 6) {
        throw "Invalid encrypted backup: file is too small"
    }

    $magic = [System.Text.Encoding]::ASCII.GetString($blob, 0, 6)
    if (-not $DestinationPath) { $DestinationPath = $EncryptedPath -replace '\.enc$', '' }

    # DPAPI format
    if ($magic -eq "PSMGRD") {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $entropy = [System.Text.Encoding]::UTF8.GetBytes("PSManagerBackupEntropy")
        $encBytes = [byte[]]::new($blob.Length - 6)
        [Array]::Copy($blob, 6, $encBytes, 0, $blob.Length - 6)
        $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [System.IO.File]::WriteAllBytes($DestinationPath, $dec)
        return $DestinationPath
    }

    if ($magic -ne "PSMGR1" -and $magic -ne "PSMGR2") {
        throw "Not a recognized PSManager encrypted backup format (magic: $magic)"
    }

    if (-not $Passphrase) {
        throw "Passphrase required to decrypt backup"
    }

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Passphrase)
    try {
        $pass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        if ([string]::IsNullOrEmpty($pass)) { throw "Passphrase is empty" }

        if ($magic -eq "PSMGR2") {
            if ($blob.Length -lt 70) {
                throw "Encrypted backup is corrupted or truncated (PSMGR2)"
            }

            $salt = [byte[]]::new(16); [Array]::Copy($blob, 6, $salt, 0, 16)
            $iv   = [byte[]]::new(16); [Array]::Copy($blob, 22, $iv, 0, 16)
            $storedTag = [byte[]]::new(32); [Array]::Copy($blob, 38, $storedTag, 0, 32)

            $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($pass, $salt, 100000,
                [Security.Cryptography.HashAlgorithmName]::SHA256)
            $keyMat = $derive.GetBytes(64)
            $encKey = [byte[]]::new(32); [Array]::Copy($keyMat, 0, $encKey, 0, 32)
            $macKey = [byte[]]::new(32); [Array]::Copy($keyMat, 32, $macKey, 0, 32)

            # Recompute HMAC over [Magic + Salt + IV + Ciphertext]
            $authData = [byte[]]::new(38 + ($blob.Length - 70))
            [Array]::Copy($blob, 0, $authData, 0, 38)
            [Array]::Copy($blob, 70, $authData, 38, $blob.Length - 70)
            $hmac = [Security.Cryptography.HMACSHA256]::new($macKey)
            $computedTag = $hmac.ComputeHash($authData)
            $hmac.Dispose()

            # Constant-time comparison to prevent timing side-channel attacks
            $diff = 0
            for ($i = 0; $i -lt 32; $i++) {
                $diff = $diff -bor ($storedTag[$i] -bxor $computedTag[$i])
            }
            if ($diff -ne 0) {
                throw "Authentication failed: invalid passphrase or backup has been tampered with"
            }

            $aes = [Security.Cryptography.Aes]::Create()
            try {
                $aes.Key = $encKey
                $aes.IV = $iv
                $aes.Mode = [Security.Cryptography.CipherMode]::CBC
                $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
                $dec = $aes.CreateDecryptor().TransformFinalBlock($blob, 70, $blob.Length - 70)
            } finally {
                $aes.Dispose()
                $derive.Dispose()
            }

            [System.IO.File]::WriteAllBytes($DestinationPath, $dec)
            return $DestinationPath
        }

        # Legacy PSMGR1 format
        if ($blob.Length -lt 38) {
            throw "Encrypted backup is corrupted (PSMGR1)"
        }
        $salt = [byte[]]::new(16); [Array]::Copy($blob, 6, $salt, 0, 16)
        $iv   = [byte[]]::new(16); [Array]::Copy($blob, 22, $iv, 0, 16)
        $derive = [Security.Cryptography.Rfc2898DeriveBytes]::new($pass, $salt, 100000,
            [Security.Cryptography.HashAlgorithmName]::SHA256)
        $key = $derive.GetBytes(32)
        $aes = [Security.Cryptography.Aes]::Create()
        try {
            $aes.Key = $key
            $aes.IV = $iv
            $aes.Mode = [Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
            $dec = $aes.CreateDecryptor().TransformFinalBlock($blob, 38, $blob.Length - 38)
        } finally {
            $aes.Dispose()
            $derive.Dispose()
        }

        [System.IO.File]::WriteAllBytes($DestinationPath, $dec)
        return $DestinationPath
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Get-DefaultBackupRepo {
    # Resolves the cloud backup target repo: environment variable ($env:PSMGR_CLOUD_REPO)
    # > explicit config > git remote origin > gh CLI default repo. Returns $null when nothing resolvable.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # 0. Environment variable override
    if (-not [string]::IsNullOrWhiteSpace($env:PSMGR_CLOUD_REPO)) {
        return $env:PSMGR_CLOUD_REPO.Trim()
    }

    # 1. Explicit user config override
    try {
        $cfg = Get-PSManagerConfig
        if ($cfg.PSObject.Properties['cloudRepo'] -and $cfg.cloudRepo) { return [string]$cfg.cloudRepo }
    } catch {}

    # 2. git remote origin of the install directory. The app repo is skipped: cloning the
    # public project must never make a user's personal archive target the maintainer's repo,
    # whatever its visibility. An explicit cloudRepo/env/-Repo stays the only opt-in path.
    try {
        $root = if ($Script:ROOT_PATH) { $Script:ROOT_PATH } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
        $url = & git -C $root remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and $url) {
            if ("$url" -match 'github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$') {
                $candidate = $Matches[1]
                if (-not (Test-PSManagerSelfBackupRepo -Repo $candidate)) { return $candidate }
            }
        }
    } catch {}

    # 3. gh CLI default repo (also never the app repo, for the same reason)
    try {
        $repo = & gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null
        if ($LASTEXITCODE -eq 0 -and $repo) {
            $candidate = ([string]$repo).Trim()
            if (-not (Test-PSManagerSelfBackupRepo -Repo $candidate)) { return $candidate }
        }
    } catch {}

    return $null
}
function Publish-PSManagerCloudBackup {
    # Uploads a profile backup zip (optionally encrypted with $Passphrase) to the user's data
    # repository via 'gh release create'. -Token is optional: when supplied it is used only for
    # this call ($env:GH_TOKEN is set and restored), so a user can avoid the global gh login.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$BackupZipPath,
        [Security.SecureString]$Passphrase,
        [string]$Repo,
        [Security.SecureString]$Token
    )

    if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found in PATH"
    }

    if (-not $Repo) { $Repo = Get-DefaultBackupRepo }
    if (-not $Repo) {
        throw "Could not resolve a target GitHub repo. Pass -Repo owner/repo, set 'cloudRepo' (psmgr set-cloud-repo owner/repo) or `$env:PSMGR_CLOUD_REPO. The deploy repository is never used automatically: backups hold personal data and must go to your own private repository."
    }

    # Normalize before the guard and the upload so -Repo, config.json and the git remote all
    # funnel through the same comparison and 'gh' always receives a bare 'owner/repo' slug.
    $slug = ConvertTo-PSManagerRepoSlug -Repo $Repo
    if (-not $slug) {
        throw ("Invalid repository reference '{0}'. Pass a GitHub.com 'owner/repo' (bare slug, github.com URL or git@github.com remote)." -f $Repo)
    }
    $Repo = $slug
    if (-not (Test-PSManagerBackupRepo -Repo $Repo)) {
        throw ("Refusing to publish a profile backup to '{0}'. The deploy repository and your data repository are separate: point 'cloudRepo' in config.json, `$env:PSMGR_CLOUD_REPO, or -Repo at your own private repository instead." -f $Repo)
    }

    # A credential is scoped to this call only: gh reads GH_TOKEN for the probe and the upload,
    # then the previous value (or absence) is restored. A SecureString BSTR is zero-freed.
    $previousGhToken = $env:GH_TOKEN
    $tokenPtr = [IntPtr]::Zero
    $tokenText = $null
    if ($Token -and $Token.Length -gt 0) {
        $tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
        $tokenText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPtr)
    } elseif (-not [string]::IsNullOrWhiteSpace($env:PSMGR_CLOUD_TOKEN)) {
        # Already a plain environment value on this machine; no SecureString round-trip needed.
        $tokenText = [string]$env:PSMGR_CLOUD_TOKEN
    }
    if ($tokenText) { $env:GH_TOKEN = $tokenText }
    try {
        # Credential and permission check before a single byte is written or uploaded: a token that
        # is missing, invalid, read-only or pointing at a public repo must be reported up front.
        $access = Test-PSManagerCloudWriteAccess -Repo $Repo
        if (-not $access.Ok) {
            throw ("Cannot publish a profile backup to '{0}': {1}" -f $Repo, $access.Reason)
        }

        # Resolve zip: use passed path, or create fresh backup. When creating a
        # fresh backup, encryption happens inside the backup step so no plaintext
        # zip is ever left on disk.
        $uploadFile = $null
        if ($BackupZipPath -and (Test-Path -LiteralPath $BackupZipPath -PathType Leaf)) {
            $uploadFile = $BackupZipPath
            if ($Passphrase -and -not $uploadFile.EndsWith(".enc", [System.StringComparison]::OrdinalIgnoreCase)) {
                $uploadFile = Protect-PSManagerBackup -BackupZipPath $uploadFile -Passphrase $Passphrase
            }
        } else {
            $uploadFile = Backup-PSManagerProfiles -Passphrase $Passphrase
        }
        $encrypted = $uploadFile.EndsWith(".enc", [System.StringComparison]::OrdinalIgnoreCase)

        $tag = "profile-backup-" + (Get-Date).ToString("yyyyMMdd_HHmmss")
        $notes = "PSManager profile backup`n- Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n- Encrypted: $encrypted (AES-256-CBC, PBKDF2 100k)`n- File: $(Split-Path -Leaf $uploadFile)"

        # Same 5.1 caveat as the permission probe: capture merged stderr under Continue, not Stop.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & gh release create $tag $uploadFile --repo $Repo --title "Profile Backup $(Get-Date -Format 'yyyy-MM-dd HH:mm')" --notes $notes 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($exitCode -ne 0) {
            $hint = ''
            if ($out -match '(?i)(resource not accessible|contents.*write|403)') {
                $hint = "`nThe credential can read '$Repo' but the upload was refused: the token lacks Contents: write for this repository. Re-issue it with Contents: read and write (fine-grained PAT limited to '$Repo'), or run 'gh auth login' and pick an account with push access. PSManager never stores your token."
            } elseif ($out -match '(?i)(401|bad credentials|authenticat)') {
                $hint = "`nNo valid GitHub credential was found. Enter a token in the GUI/TUI backup dialog, or export `$env:PSMGR_CLOUD_TOKEN, GH_TOKEN or GITHUB_TOKEN. PSManager never stores your token."
            }
            throw ("gh release create failed: $out$hint")
        }

        $releaseUrl = @($out.TrimEnd() -split "`r?`n" | Where-Object { $_ -match '^https?://github\.com/' })
        if (-not $releaseUrl -or $releaseUrl.Count -eq 0) {
            $releaseUrl = @($out.TrimEnd() -split "`r?`n" | Select-Object -Last 1)
        }

        return [pscustomobject]@{
            Success       = $true
            Tag           = $tag
            Repo          = $Repo
            FileUploaded  = $uploadFile
            Encrypted     = $encrypted
            Url           = [string]$releaseUrl[0]
        }
    } finally {
        if ($tokenPtr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
        }
        $env:GH_TOKEN = $previousGhToken
    }
}

function Get-PSManagerBackups {
    [CmdletBinding()]
    param(
        [string]$DestinationDir
    )

    $dir = if (-not [string]::IsNullOrEmpty($DestinationDir)) {
        $DestinationDir
    } else {
        Join-Path $env:USERPROFILE "tools\ps-manager\backups"
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        return @()
    }

    Get-ChildItem -LiteralPath $dir -File |
        Where-Object { $_.Name -match '^profile_backup_.*\.zip(\.enc)?$' } |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            [pscustomobject]@{
                Name         = $_.Name
                FullName     = $_.FullName
                CreationTime = $_.CreationTime
                SizeKB       = [math]::Round($_.Length / 1KB, 2)
                IsEncrypted  = ($_.Extension -eq '.enc')
            }
        }
}

function Remove-PSManagerBackup {
    <#
    .SYNOPSIS
        Permanently deletes local profile backups.
    .DESCRIPTION
        DESTRUCTIVE. Deletion is irreversible, so every target is validated to live
        strictly inside the backups directory, and ShouldProcess (ConfirmImpact=High)
        prompts before each removal. Use -WhatIf to preview or -Force to confirm.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)]
        [string[]]$Name,

        [switch]$All,

        [string]$DestinationDir,

        [switch]$Force
    )

    $dir = if (-not [string]::IsNullOrEmpty($DestinationDir)) {
        $DestinationDir
    } else {
        Join-Path $env:USERPROFILE "tools\ps-manager\backups"
    }

    $result = [pscustomobject]@{
        Deleted = 0
        Skipped = 0
        FreedKB = 0
        Paths   = @()
        Errors  = @()
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        return $result
    }

    $rootFull = [System.IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
    $existing = @(Get-PSManagerBackups -DestinationDir $dir)

    $targets = [System.Collections.Generic.List[object]]::new()
    if ($All) {
        foreach ($b in $existing) { $targets.Add($b) }
    } elseif ($Name) {
        foreach ($n in $Name) {
            $leaf = Split-Path -Leaf $n
            $match = $existing | Where-Object { $_.Name -eq $leaf } | Select-Object -First 1
            if ($match) {
                $targets.Add($match)
            } else {
                $result.Skipped++
                $result.Errors += "Backup not found: $leaf"
            }
        }
    } else {
        throw "Specify -All or at least one backup -Name."
    }

    $confirm = if ($Force) { $false } else { $true }

    foreach ($t in $targets) {
        $full = [System.IO.Path]::GetFullPath($t.FullName)
        # Containment guard: refuse anything outside the backups directory.
        if (-not $full.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            $result.Skipped++
            $result.Errors += "Refused path outside backups directory: $full"
            continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $result.Skipped++
            $result.Errors += "File disappeared before deletion: $full"
            continue
        }

        $sizeKB = [math]::Round((Get-Item -LiteralPath $full).Length / 1KB, 2)
        if ($PSCmdlet.ShouldProcess($full, 'Permanently delete profile backup')) {
            try {
                Remove-Item -LiteralPath $full -Force -ErrorAction Stop -Confirm:$confirm
                $result.Deleted++
                $result.FreedKB += $sizeKB
                $result.Paths += $full
            } catch {
                $result.Skipped++
                $result.Errors += "Failed to delete $full : $($_.Exception.Message)"
            }
        } else {
            $result.Skipped++
        }
    }

    if (Get-Command Write-PSManagerLog -ErrorAction SilentlyContinue) {
        Write-PSManagerLog -Message "Backup cleanup: deleted=$($result.Deleted) skipped=$($result.Skipped) freed=$($result.FreedKB)KB" -Level "WARN"
    }

    return $result
}

function Restore-PSManagerBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupZipPath,

        [string]$MockBaseDir,

        [Security.SecureString]$Passphrase
    )

    if (-not (Test-Path -LiteralPath $BackupZipPath -PathType Leaf)) {
        Write-Error "Backup archive not found: $BackupZipPath"
        return $false
    }

    $isEnc = $BackupZipPath.EndsWith(".enc", [System.StringComparison]::OrdinalIgnoreCase)
    $zipToExtract = $BackupZipPath
    $tempDecrypted = $null

    if ($isEnc) {
        $blob = [System.IO.File]::ReadAllBytes($BackupZipPath)
        $magic = if ($blob.Length -ge 6) { [System.Text.Encoding]::ASCII.GetString($blob, 0, 6) } else { "" }
        $tempDecrypted = Join-Path $env:TEMP "psmgr_dec_$(Get-Random).zip"

        if ($magic -eq "PSMGRD") {
            # DPAPI transparent restore
            try {
                Unprotect-PSManagerBackup -EncryptedPath $BackupZipPath -DestinationPath $tempDecrypted -UseDPAPI | Out-Null
                $zipToExtract = $tempDecrypted
            } catch {
                Write-Error "DPAPI decryption failed: $($_.Exception.Message)"
                return $false
            }
        } elseif ($magic -in @("PSMGR1", "PSMGR2")) {
            $pass = $Passphrase
            if (-not $pass) {
                try {
                    if (-not [Console]::IsInputRedirected) {
                        $pass = Read-Host -Prompt "Enter backup decryption passphrase" -AsSecureString
                    }
                } catch {}
            }
            if (-not $pass) {
                Write-Error "Passphrase required to restore encrypted backup."
                return $false
            }
            try {
                Unprotect-PSManagerBackup -EncryptedPath $BackupZipPath -Passphrase $pass -DestinationPath $tempDecrypted | Out-Null
                $zipToExtract = $tempDecrypted
            } catch {
                Write-Error "Decryption failed: $($_.Exception.Message)"
                return $false
            }
        } else {
            Write-Error "Unrecognized encrypted backup format (magic: $magic)"
            return $false
        }
    }

    $baseDocs = if (-not [string]::IsNullOrEmpty($MockBaseDir)) {
        $MockBaseDir
    } else {
        [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments)
    }

    $tempExtract = Join-Path $env:TEMP "psmgr_restore_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null

    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipToExtract, $tempExtract)

        # Restore PS5
        $extractedPs5 = Join-Path $tempExtract "WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
        if (Test-Path -LiteralPath $extractedPs5) {
            $destPs5Dir = Join-Path $baseDocs "WindowsPowerShell"
            if (-not (Test-Path -LiteralPath $destPs5Dir)) {
                New-Item -ItemType Directory -Path $destPs5Dir -Force | Out-Null
            }
            $destPs5 = Join-Path $destPs5Dir "Microsoft.PowerShell_profile.ps1"
            $null = Set-DetachedFileContent -Path $destPs5 -Bytes ([System.IO.File]::ReadAllBytes($extractedPs5))
        }

        # Restore PS7
        $extractedPs7 = Join-Path $tempExtract "PowerShell\Microsoft.PowerShell_profile.ps1"
        if (Test-Path -LiteralPath $extractedPs7) {
            $destPs7Dir = Join-Path $baseDocs "PowerShell"
            if (-not (Test-Path -LiteralPath $destPs7Dir)) {
                New-Item -ItemType Directory -Path $destPs7Dir -Force | Out-Null
            }
            $destPs7 = Join-Path $destPs7Dir "Microsoft.PowerShell_profile.ps1"
            $null = Set-DetachedFileContent -Path $destPs7 -Bytes ([System.IO.File]::ReadAllBytes($extractedPs7))
        }

        # Restore Configs (starship.toml)
        $extractedStarship = Join-Path $tempExtract "configs\starship.toml"
        if (Test-Path -LiteralPath $extractedStarship) {
            $configHome = if (-not [string]::IsNullOrEmpty($MockBaseDir)) {
                Join-Path $MockBaseDir ".config"
            } else {
                Join-Path $env:USERPROFILE ".config"
            }
            if (-not (Test-Path -LiteralPath $configHome)) {
                New-Item -ItemType Directory -Path $configHome -Force | Out-Null
            }
            $destStarship = Join-Path $configHome "starship.toml"
            $null = Set-DetachedFileContent -Path $destStarship -Bytes ([System.IO.File]::ReadAllBytes($extractedStarship))
        }

        return $true
    } catch {
        Write-Error "Failed to restore backup: $($_.Exception.Message)"
        return $false
    } finally {
        if (Test-Path -LiteralPath $tempExtract) {
            Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($tempDecrypted -and (Test-Path -LiteralPath $tempDecrypted)) {
            Remove-Item -LiteralPath $tempDecrypted -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-HardLinkPaths {
    <#
    .SYNOPSIS
        Lists every path that shares the file record (inode) of -Path.
    .DESCRIPTION
        Returns an empty array when the state cannot be determined, so callers can
        tell "no peers" apart from "unknown" by also checking Test-FileHardLink.
        A file with a single link returns exactly one path (itself).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }

    try {
        $fsutil = Get-Command fsutil.exe -ErrorAction SilentlyContinue
        if ($fsutil) {
            $lines = @(& $fsutil.Source hardlink list $Path 2>$null |
                ForEach-Object { "$_".Trim() } |
                Where-Object { $_ })
            if ($lines.Count -gt 0) { return $lines }
        }
    } catch {}

    return @()
}

function Test-FileHardLink {
    <#
    .SYNOPSIS
        Reports whether a file has more than one hard link (i.e. writing it would
        also mutate every other path that shares the same file record).
    .OUTPUTS
        [bool] when the state is known; $null when it cannot be determined
        (fsutil unavailable and the runtime does not expose LinkType).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    $peers = @(Get-HardLinkPaths -Path $Path)
    if ($peers.Count -gt 0) { return ($peers.Count -gt 1) }

    # Hosts without fsutil: .NET exposes LinkType only on PowerShell 6+.
    try {
        $lt = (Get-Item -LiteralPath $Path -ErrorAction Stop).LinkType
        if ($lt) { return ($lt -eq 'HardLink') }
    } catch {}

    return $null
}

function Set-DetachedFileContent {
    <#
    .SYNOPSIS
        Writes file content in a way that never writes *through* a hard link.
    .DESCRIPTION
        Live PowerShell profiles may share an inode with
        templates/profiles/master_profile.ps1. A plain Set-Content/Copy-Item on
        such a path mutates the tracked repo payload as a side effect.
        This helper writes a sibling temp file, renames the target aside (which
        only drops that directory entry and leaves every other link holder
        intact), renames the temp into place, then deletes the aside copy. If the
        swap fails the original is restored, so the target is never lost.
    .PARAMETER Bytes
        Exact bytes to write, for callers that must not re-encode (backup restore).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true, ParameterSetName = 'Text')][AllowEmptyString()][string]$Content,
        [Parameter(ParameterSetName = 'Text')][switch]$Utf8Bom,
        [Parameter(Mandatory = $true, ParameterSetName = 'Bytes')][byte[]]$Bytes
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $exists = Test-Path -LiteralPath $full -PathType Leaf
    $wasLinked = [bool](Test-FileHardLink -Path $full)
    $attrs = if ($exists) { (Get-Item -LiteralPath $full -Force).Attributes } else { $null }
    $leaf = Split-Path -Leaf $full
    $id = [guid]::NewGuid().ToString("N")
    $tmp = Join-Path $dir (".{0}.psmgr-tmp-{1}" -f $leaf, $id)
    $aside = Join-Path $dir (".{0}.psmgr-old-{1}" -f $leaf, $id)

    try {
        if ($PSCmdlet.ParameterSetName -eq 'Bytes') {
            [System.IO.File]::WriteAllBytes($tmp, $Bytes)
        } else {
            $enc = if ($Utf8Bom) { [System.Text.UTF8Encoding]::new($true) } else { [System.Text.UTF8Encoding]::new($false) }
            [System.IO.File]::WriteAllText($tmp, $Content, $enc)
        }

        if ($exists) { Move-Item -LiteralPath $full -Destination $aside -Force }
        try {
            Move-Item -LiteralPath $tmp -Destination $full -Force
        } catch {
            if ($exists -and -not (Test-Path -LiteralPath $full) -and (Test-Path -LiteralPath $aside)) {
                Move-Item -LiteralPath $aside -Destination $full -Force
            }
            throw
        }

        if ($attrs -and $attrs -ne [System.IO.FileAttributes]::Normal) {
            [System.IO.File]::SetAttributes($full, $attrs)
        }
    } finally {
        foreach ($p in @($tmp, $aside)) {
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return [pscustomobject]@{ Path = $full; DetachedFromLink = $wasLinked }
}
