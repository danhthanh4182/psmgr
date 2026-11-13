#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Zero-State Web Bootstrapper
.DESCRIPTION
    1-command bootstrap designed to run directly from clean Windows PowerShell 5.1:
    Invoke-RestMethod -Uri https://raw.githubusercontent.com/danhthanh4182/psmgr/main/boot.ps1 -OutFile $env:TEMP/boot.ps1; powershell -File $env:TEMP/boot.ps1
    Prepares runtime, installs PowerShell 7, clones PSManager, and handovers execution to PS7 Core.
#>

[CmdletBinding()]
param(
    [string]$RepoUrl = "https://github.com/danhthanh4182/psmgr.git",
    [string]$DotfilesUrl = "",
    [switch]$SkipPS7Install
)

$ErrorActionPreference = 'Stop'

# Enforce TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Preload compression library for zip fallback on raw PS 5.1
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# Fix conhost UTF-8 output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "              PSManager Zero-State Web Bootstrapper (PS5 -> PS7)                " -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "Host Runtime: Windows PowerShell $($PSVersionTable.PSVersion.ToString()) ($($PSVersionTable.PSEdition))`n"

# Step 1: Execution Policy Check
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -eq 'Restricted' -or $policy -eq 'Undefined') {
    Write-Host "==> Setting ExecutionPolicy to RemoteSigned for CurrentUser..." -ForegroundColor Yellow
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
}

# Step 2: Ensure Winget CLI
$wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
if (-not $wingetCmd) {
    Write-Warning "winget is not available in PATH. Please ensure Windows App Installer is installed."
}

# Step 3: Ensure Git CLI
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    if ($wingetCmd) {
        Write-Host "==> Installing Git via Winget..." -ForegroundColor Yellow
        & winget install --exact --id Git.Git --silent --accept-source-agreements --accept-package-agreements
        # Refresh PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if (-not $gitCmd) {
            $gitProgFiles = "$env:ProgramFiles\Git\cmd\git.exe"
            if (Test-Path $gitProgFiles) {
                $gitCmd = Get-Item $gitProgFiles
                $env:PATH = "$env:ProgramFiles\Git\cmd;$env:PATH"
            }
        }
    }
}

# Step 4: Ensure PowerShell 7
$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $pwshCmd -and -not $SkipPS7Install) {
    if ($wingetCmd) {
        Write-Host "==> Installing PowerShell 7 via Winget..." -ForegroundColor Yellow
        & winget install --exact --id Microsoft.PowerShell --silent --accept-source-agreements --accept-package-agreements
        # Probe standard Program Files path
        $standardPS7 = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
        if (Test-Path $standardPS7) {
            $pwshCmd = Get-Item $standardPS7
        }
    }
}

# Step 5: Clone or Update PSManager Repo
$installDir = Join-Path $env:USERPROFILE "tools\ps-manager"
if (Test-Path $installDir) {
    Write-Host "==> Updating existing PSManager at $installDir..." -ForegroundColor Yellow
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Push-Location $installDir
        try {
            & git pull --quiet
        } catch {
            Write-Warning "Could not git pull in $installDir"
        } finally {
            Pop-Location
        }
    }
} else {
    Write-Host "==> Cloning PSManager into $installDir..." -ForegroundColor Yellow
    $parentDir = Split-Path -Parent $installDir
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        & git clone --quiet $RepoUrl $installDir
    } else {
        # Fallback to zip download if Git unavailable
        $zipUrl = "$($RepoUrl.Replace('.git', ''))/archive/refs/heads/main.zip"
        $tmpZip = Join-Path $env:TEMP "psmgr_main.zip"
        Invoke-WebRequest -Uri $zipUrl -OutFile $tmpZip -UseBasicParsing
        [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpZip, $parentDir)
        $extracted = Get-ChildItem -LiteralPath $parentDir -Directory |
            Where-Object { $_.Name -match '^psmgr-main|^ps-manager-main' } |
            Select-Object -First 1
        if ($extracted) {
            Rename-Item -LiteralPath $extracted.FullName -NewName "ps-manager" -Force
        }
    }
}

# Auto-configure universal git hooks for all agents and contributors
if (Test-Path (Join-Path $installDir ".git") -and (Get-Command git -ErrorAction SilentlyContinue)) {
    & git -C $installDir config core.hooksPath .agents/hooks 2>$null
}

# Step 6: Clone Dotfiles if URL specified
if (-not [string]::IsNullOrEmpty($DotfilesUrl)) {
    $dotfilesDir = Join-Path $env:USERPROFILE ".dotfiles"
    if (-not (Test-Path $dotfilesDir) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "==> Cloning Dotfiles from $DotfilesUrl into $dotfilesDir..." -ForegroundColor Yellow
        & git clone --quiet $DotfilesUrl $dotfilesDir
    }
}

# Step 7: Handover execution to PowerShell 7 Core
$harnessScript = Join-Path $installDir "ps-manager.ps1"
$pwshExe = if ($pwshCmd) {
    if ($pwshCmd -is [string]) { $pwshCmd } else { $pwshCmd.Source }
} else {
    $cand = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (Test-Path $cand) { $cand } else { $null }
}

if ($pwshExe -and (Test-Path $pwshExe)) {
    Write-Host "`n==> Handing over execution to PowerShell 7 Core: $pwshExe..." -ForegroundColor Green
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $harnessScript sync
    & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $harnessScript set-default-ps7
    Write-Host "`n[PSManager Bootstrap Complete] Open Windows Terminal to start your modern shell." -ForegroundColor Cyan
} else {
    Write-Host "`n==> Running sync under Windows PowerShell 5.1..." -ForegroundColor Yellow
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $harnessScript sync
    Write-Host "`n[PSManager Bootstrap Completed on PS 5.1]" -ForegroundColor Cyan
}
