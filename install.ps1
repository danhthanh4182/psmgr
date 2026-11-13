#Requires -Version 5.1
<#
.SYNOPSIS
    Installs PSManager from its GitHub release, directly or through winget.
.DESCRIPTION
    Resolves a PSManager release, downloads PSManager-<version>-Setup.exe, verifies its SHA256
    digest against the published SHA256SUMS.txt, and installs it. Works on Windows PowerShell 5.1
    and PowerShell 7.x.

    The repository is private, so release assets need an authenticated request: pass -Token, set
    PSMGR_GITHUB_TOKEN, or sign in with the GitHub CLI (gh auth login). Once the repository is
    public the same commands work without credentials.

    -Method Winget generates a version-pinned winget singleton manifest from the release metadata
    (including the verified digest) and installs through winget. Winget cannot authenticate to a
    private repository, so that method needs the release assets to be publicly reachable.
.PARAMETER Version
    Release to install (for example 1.6.1 or v1.6.1). Defaults to the latest release.
.PARAMETER Method
    Installer runs the setup executable directly; Winget hands a generated manifest to winget.
.PARAMETER Scope
    CurrentUser installs to %LOCALAPPDATA%\Programs\PSManager; AllUsers installs to
    %ProgramFiles%\PSManager and needs an elevated shell.
.PARAMETER InstallDir
    Explicit installation directory passed to the installer as /DIR.
.PARAMETER Silent
    Install without a wizard (/VERYSILENT /SUPPRESSMSGBOXES /NORESTART).
.PARAMETER NoLaunch
    Do not let the installer start PSManager after a successful install.
.PARAMETER Token
    GitHub token used to read release assets of a private repository.
.PARAMETER WriteManifest
    Write the generated winget manifest to this path instead of installing.
.PARAMETER WhatIf
    Print the resolved download and installer arguments without downloading or installing.
.EXAMPLE
    irm https://raw.githubusercontent.com/danhthanh4182/psmgr/main/install.ps1 | iex
.EXAMPLE
    .\install.ps1 -Version 1.6.1 -Silent -Scope CurrentUser
.EXAMPLE
    .\install.ps1 -Method Winget -Silent
.EXAMPLE
    .\install.ps1 -WhatIf
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [ValidateSet('Installer', 'Winget')]
    [string]$Method = 'Installer',
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',
    [string]$InstallDir = '',
    [switch]$Silent,
    [switch]$NoLaunch,
    [string]$Token = $env:PSMGR_GITHUB_TOKEN,
    [string]$WriteManifest = '',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 defaults to TLS 1.0 on older builds, which GitHub rejects.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$repo = 'danhthanh4182/psmgr'
$apiBase = 'https://api.github.com/repos/' + $repo

function Write-Step {
    param([string]$Message)
    Write-Host ('==> ' + $Message) -ForegroundColor Cyan
}

function Resolve-GhCli {
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return ''
}

function Resolve-GitHubToken {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:PSMGR_GITHUB_TOKEN) { return $env:PSMGR_GITHUB_TOKEN }
    if ($env:GH_TOKEN) { return $env:GH_TOKEN }
    if ($env:GITHUB_TOKEN) { return $env:GITHUB_TOKEN }
    $gh = Resolve-GhCli
    if ($gh) {
        try {
            $token = (& $gh auth token 2>$null | Out-String).Trim()
            if ($token) { return $token }
        } catch { }
    }
    return ''
}

function New-GitHubHeaders {
    param([string]$AccessToken)
    $headers = @{ 'User-Agent' = 'psmgr-install'; 'Accept' = 'application/vnd.github+json' }
    if ($AccessToken) { $headers['Authorization'] = 'Bearer ' + $AccessToken }
    return $headers
}

function Get-ReleaseInfo {
    param([string]$Tag, [hashtable]$Headers)
    $uri = if ($Tag -eq 'latest') { $apiBase + '/releases/latest' } else { $apiBase + '/releases/tags/' + $Tag }
    try {
        return Invoke-RestMethod -Uri $uri -Headers $Headers -UseBasicParsing
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404) {
            if ($Tag -eq 'latest') {
                throw ('No published release found for {0}, or the repository is private and the request was anonymous. Pass -Token, set PSMGR_GITHUB_TOKEN, or run "gh auth login".' -f $repo)
            }
            throw ('Release {0} was not found in {1}. Pass -Token, set PSMGR_GITHUB_TOKEN, or run "gh auth login".' -f $Tag, $repo)
        }
        throw
    }
}

function Save-Asset {
    param($Asset, [string]$Tag, [string]$OutFile, [hashtable]$Headers)
    # Private repositories reject the browser URL for token auth, so authenticated runs use the
    # REST asset endpoint with an octet-stream accept header; public runs use the plain URL.
    $uri = if ($Headers.ContainsKey('Authorization') -and $Asset.url) { [string]$Asset.url } else { [string]$Asset.browser_download_url }
    $assetHeaders = @{}
    foreach ($key in $Headers.Keys) { $assetHeaders[$key] = $Headers[$key] }
    if ($assetHeaders.ContainsKey('Authorization')) {
        $assetHeaders['Accept'] = 'application/octet-stream'
    }
    try {
        Invoke-WebRequest -Uri $uri -Headers $assetHeaders -OutFile $OutFile -UseBasicParsing
        return
    } catch {
        Write-Verbose ('Direct download failed: ' + $_.Exception.Message)
    }
    # Fall back to the GitHub CLI, which handles private repositories on its own.
    $gh = Resolve-GhCli
    if (-not $gh) { throw ('Could not download ' + $Asset.name + '. Pass -Token, set PSMGR_GITHUB_TOKEN, or run "gh auth login".') }
    Write-Step ('Retrying ' + $Asset.name + ' through gh release download')
    & $gh release download $Tag --repo $repo --pattern ([string]$Asset.name) --dir (Split-Path -Parent $OutFile) --clobber
    if ($LASTEXITCODE -ne 0) { throw ('gh release download failed for ' + $Asset.name) }
    if (-not (Test-Path -LiteralPath $OutFile)) { throw ('gh release download did not produce ' + $OutFile) }
}

function Get-Sha256 {
    param([string]$File)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($File)
        try {
            return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha.Dispose()
    }
}

function Read-ExpectedDigest {
    param([string]$SumsPath, [string]$Name)
    foreach ($line in [System.IO.File]::ReadAllLines($SumsPath)) {
        if ($line -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($Name) + '$')) {
            return $Matches[1].ToLowerInvariant()
        }
    }
    return ''
}

function New-WingetManifest {
    param(
        [string]$PackageVersion,
        [string]$InstallerUrl,
        [string]$Sha256
    )
    $silent = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    $progress = '/SILENT /SUPPRESSMSGBOXES /NORESTART'
    $lines = @(
        '# yaml-language-server: $schema=https://aka.ms/winget-manifest.singleton.1.6.0.schema.json',
        'PackageIdentifier: danhthanh4182.PSManager',
        ('PackageVersion: ' + $PackageVersion),
        'PackageLocale: en-US',
        'Publisher: Danh Thanh',
        'PublisherUrl: https://github.com/danhthanh4182',
        'PackageName: PSManager',
        'PackageUrl: https://github.com/danhthanh4182/psmgr',
        'License: MIT',
        'ShortDescription: PowerShell version manager with a CLI, an interactive TUI and a native WPF desktop app.',
        'Moniker: psmgr',
        'Tags:',
        '- powershell',
        '- version-manager',
        '- tui',
        '- cli',
        'Installers:',
        '- Architecture: x64',
        '  InstallerType: inno',
        ('  InstallerUrl: ' + $InstallerUrl),
        ('  InstallerSha256: ' + $Sha256.ToUpperInvariant()),
        '  InstallerSwitches:',
        ('    Silent: ' + $silent),
        ('    SilentWithProgress: ' + $progress),
        ('    Custom: ' + $(if ($Scope -eq 'AllUsers') { '/ALLUSERS' } else { '/CURRENTUSER' })),
        ('  Scope: ' + $(if ($Scope -eq 'AllUsers') { 'machine' } else { 'user' })),
        'ManifestType: singleton',
        'ManifestVersion: 1.6.0'
    )
    return ($lines -join "`n")
}

$accessToken = Resolve-GitHubToken -Explicit $Token
$headers = New-GitHubHeaders -AccessToken $accessToken
$tag = if ($Version -eq 'latest') { 'latest' } else { 'v' + ($Version -replace '^[vV]', '') }

Write-Step ('Resolving PSManager release: ' + $tag)
$release = Get-ReleaseInfo -Tag $tag -Headers $headers
$resolvedVersion = ([string]$release.tag_name) -replace '^[vV]', ''

$installerAsset = $null
$sumsAsset = $null
foreach ($asset in @($release.assets)) {
    if ($asset.name -like 'PSManager-*-Setup.exe') { $installerAsset = $asset }
    if ($asset.name -eq 'SHA256SUMS.txt') { $sumsAsset = $asset }
}
if (-not $installerAsset) {
    throw ('Release {0} does not publish a PSManager-*-Setup.exe installer asset.' -f $release.tag_name)
}

$installerArgs = @('/SUPPRESSMSGBOXES', '/NORESTART')
if ($Silent) { $installerArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') }
if ($Scope -eq 'AllUsers') { $installerArgs += '/ALLUSERS' } else { $installerArgs += '/CURRENTUSER' }
if ($InstallDir) { $installerArgs += ('/DIR="' + $InstallDir + '"') }
# Inno rejects unknown switches, so "do not launch" travels through the environment.
if ($NoLaunch) { $env:PSMGR_NOLAUNCH = '1' }

if ($WhatIf) {
    Write-Host ''
    Write-Host ('Release        : ' + $release.tag_name + ' (' + $resolvedVersion + ')')
    Write-Host ('Method         : ' + $Method)
    Write-Host ('Installer URL  : ' + $installerAsset.browser_download_url)
    Write-Host ('Installer size : ' + $installerAsset.size + ' bytes')
    Write-Host ('Checksum file  : ' + $(if ($sumsAsset) { $sumsAsset.browser_download_url } else { '(not published)' }))
    Write-Host ('Installer args : ' + ($installerArgs -join ' '))
    Write-Host ('Authenticated  : ' + [bool]$accessToken)
    return
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('psmgr-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
try {
    $installerPath = Join-Path $workDir $installerAsset.name
    Write-Step ('Downloading ' + $installerAsset.name)
    Save-Asset -Asset $installerAsset -Tag $release.tag_name -OutFile $installerPath -Headers $headers
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw ('Download did not produce ' + $installerPath)
    }

    $expected = ''
    if ($sumsAsset) {
        Write-Step 'Verifying SHA256 digest'
        $sumsPath = Join-Path $workDir 'SHA256SUMS.txt'
        Save-Asset -Asset $sumsAsset -Tag $release.tag_name -OutFile $sumsPath -Headers $headers
        $expected = Read-ExpectedDigest -SumsPath $sumsPath -Name $installerAsset.name
        if (-not $expected) {
            throw ('SHA256SUMS.txt does not list ' + $installerAsset.name)
        }
        $actual = Get-Sha256 -File $installerPath
        if ($actual -ne $expected) {
            throw ('SHA256 mismatch for ' + $installerAsset.name + ' (expected ' + $expected + ', got ' + $actual + ')')
        }
        Write-Host ('    digest ok: ' + $expected) -ForegroundColor Green
    } else {
        # Never install an unverified package: this path is what a compromised release or a
        # hostile mirror would exploit. Older releases must publish SHA256SUMS.txt first.
        throw ('Release ' + $release.tag_name + ' does not publish SHA256SUMS.txt; refusing to install an unverified package.')
    }

    if ($WriteManifest) {
        if (-not $expected) {
            throw 'Cannot write a winget manifest without a published SHA256 digest.'
        }
        $manifestText = New-WingetManifest -PackageVersion $resolvedVersion -InstallerUrl ([string]$installerAsset.browser_download_url) -Sha256 $expected
        $manifestDir = Split-Path -Parent $WriteManifest
        if ($manifestDir -and -not (Test-Path -LiteralPath $manifestDir)) {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($WriteManifest, $manifestText, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ('Winget manifest written: ' + $WriteManifest) -ForegroundColor Green
        return
    }

    if ($Method -eq 'Winget') {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $winget) {
            $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            if (Test-Path -LiteralPath $candidate) { $winget = Get-Item -LiteralPath $candidate }
        }
        if (-not $winget) { throw 'winget was not found. Install App Installer, or use -Method Installer.' }
        if (-not $expected) {
            throw 'Winget needs the published SHA256 digest; this release does not publish SHA256SUMS.txt.'
        }
        $manifestPath = Join-Path $workDir 'danhthanh4182.PSManager.yaml'
        $manifestText = New-WingetManifest -PackageVersion $resolvedVersion -InstallerUrl ([string]$installerAsset.browser_download_url) -Sha256 $expected
        [System.IO.File]::WriteAllText($manifestPath, $manifestText, (New-Object System.Text.UTF8Encoding($false)))
        Write-Step ('Installing PSManager ' + $resolvedVersion + ' through winget')
        $wingetArgs = @('install', '-m', $manifestPath, '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($Silent) { $wingetArgs += '--silent' }
        & $winget.Source @wingetArgs
        if ($LASTEXITCODE -ne 0) { throw ('winget exited with code ' + $LASTEXITCODE) }
    } else {
        Write-Step ('Installing PSManager ' + $resolvedVersion + ' (' + $Scope + ')')
        $process = Start-Process -FilePath $installerPath -ArgumentList $installerArgs -Wait -PassThru
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
            throw ('Installer exited with code ' + $process.ExitCode)
        }
        if ($process.ExitCode -eq 3010) {
            Write-Warning 'Installation succeeded; a reboot is required to finish.'
        }
    }

    Write-Host ('PSManager ' + $resolvedVersion + ' installed. Run "psmgr" for the TUI or "psmgr-gui" for the desktop app.') -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}
