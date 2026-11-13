#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Builder CLI - build launchers, packages and verification reports.
.DESCRIPTION
    Thin wrapper over build/PSManager.Builder.psm1 so humans and CI can run the same steps the MCP
    server exposes. Exit code is 0 on success and 1 on the first failure.
.PARAMETER Action
    info | icon | build | package | verify | all
.PARAMETER Root
    Repository root. Defaults to the parent of this script.
.PARAMETER Destination
    Output directory for launchers/packages. Defaults to <Root>\dist\build.
.EXAMPLE
    pwsh ./build/build.ps1 -Action all -Destination C:\temp\psmgr-dist
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
    Justification = 'The certificate password is forwarded to signtool.exe /p')]
param(
    [ValidateSet('info', 'icon', 'build', 'package', 'installer', 'sign', 'verify', 'all')]
    [string]$Action = 'info',
    [string]$Root = '',
    [string]$Destination = '',
    [string]$Version = '',
    [ValidateSet('Launcher', 'Bundle')]
    [string]$Mode = 'Launcher',
    [string]$IconPath = '',
    [hashtable]$Metadata = @{},
    [switch]$RequireAdmin,
    [switch]$SkipInstaller,
    [string]$CertificatePath = '',
    [string]$CertificatePassword = '',
    [string]$CertificateThumbprint = '',
    [switch]$MachineStore,
    [switch]$SmokeRun
)

$ErrorActionPreference = 'Stop'
$builderModule = Join-Path $PSScriptRoot 'PSManager.Builder.psm1'
if (-not (Test-Path -LiteralPath $builderModule)) {
    Write-Error "Builder module missing: $builderModule"
    exit 1
}
Import-Module $builderModule -Force

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path
if (-not $Destination) { $Destination = Join-Path $Root 'dist\build' }

$metadataObject = if ($Metadata.Count -gt 0) { [pscustomobject]$Metadata } else { $null }

function Get-SignArguments {
    $signArgs = @{}
    if ($CertificatePath) { $signArgs['CertificatePath'] = $CertificatePath }
    if ($CertificatePassword) { $signArgs['CertificatePassword'] = $CertificatePassword }
    if ($CertificateThumbprint) {
        $signArgs['CertificateThumbprint'] = $CertificateThumbprint
        if ($MachineStore) { $signArgs['MachineStore'] = $true }
    }
    return $signArgs
}

function Invoke-BuildLaunchers {
    param([string]$Target)
    # Leave -IconPath empty unless the caller set it: New-PSManagerLauncher resolves the root icon
    # and falls back to the builder icon, while an explicit path that does not exist is an error.
    $launcherIcon = $IconPath
    $signArgs = Get-SignArguments
    $launcher = New-PSManagerLauncher -Destination $Target -Name 'psmgr.exe' -ScriptName 'ps-manager.ps1' `
        -Kind Console -Metadata $metadataObject -IconPath $launcherIcon -RequireAdmin:$RequireAdmin -Root $Root @signArgs
    $gui = New-PSManagerLauncher -Destination $Target -Name 'psmgr-gui.exe' -ScriptName 'gui.ps1' `
        -Kind Windows -ExtraArguments '' -StaThread -Metadata $metadataObject -IconPath $launcherIcon -Root $Root @signArgs
    return @($launcher, $gui)
}

$signArgs = Get-SignArguments
try {
    switch ($Action) {
        'info' {
            Get-PSManagerBuildInfo -Root $Root | Format-List
        }
        'icon' {
            $path = New-PSManagerBuildIcon -OutputPath $IconPath
            Write-Host ("Icon: " + $path)
        }
        'build' {
            $paths = Invoke-BuildLaunchers -Target $Destination
            $paths | ForEach-Object { Write-Host ("Launcher: " + $_) }
        }
        'package' {
            $archives = New-PSManagerBuildPackage -Destination $Destination -Version $Version -Mode $Mode -IconPath $IconPath -Root $Root @signArgs
            $archives | ForEach-Object { Write-Host ("Package: " + $_.Path + " (" + $_.SizeBytes + " bytes)") }
        }
        'installer' {
            $setup = New-PSManagerInstaller -Destination $Destination -Version $Version -IconPath $IconPath `
                -Root $Root @signArgs -SkipIfMissing:$SkipInstaller
            if ($setup) { Write-Host ("Installer: " + $setup) }
        }
        'sign' {
            $targets = @(Get-ChildItem -LiteralPath $Destination -Filter '*.exe' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            if ($targets.Count -eq 0) { throw "No executables found in $Destination; build first." }
            $result = Invoke-PSManagerCodeSign -Path $targets @signArgs
            if ($result) { Write-Host ("Signed " + $result.Count + " file(s).") }
            $null = New-PSManagerChecksumFile -Destination $Destination
        }
        'verify' {
            $targets = @(Get-ChildItem -LiteralPath $Destination -Filter '*.exe' -ErrorAction SilentlyContinue)
            if ($targets.Count -eq 0) { throw "No executables found in $Destination; run -Action build first." }
            $failed = $false
            foreach ($target in $targets) {
                $smoke = ($SmokeRun -and $target.Name -eq 'psmgr.exe')
                $report = Test-PSManagerBuild -Path $target.FullName -ExpectedVersion $Version -SmokeRun:$smoke
                Write-Host ("{0}: {1}" -f $target.Name, $(if ($report.Passed) { 'PASS' } else { 'FAIL' }))
                $report.Problems | ForEach-Object { Write-Host ("  - " + $_) }
                if (-not $report.Passed) { $failed = $true }
            }
            if ($failed) { exit 1 }
        }
        'all' {
            $null = New-PSManagerBuildIcon -OutputPath $IconPath
            $paths = Invoke-BuildLaunchers -Target $Destination
            $paths | ForEach-Object { Write-Host ("Launcher: " + $_) }
            $archives = New-PSManagerBuildPackage -Destination $Destination -Version $Version -Mode $Mode -IconPath $IconPath -Root $Root @signArgs
            $archives | ForEach-Object { Write-Host ("Package: " + $_.Path) }
            if (-not $SkipInstaller) {
                $setup = New-PSManagerInstaller -Destination $Destination -Version $Version -IconPath $IconPath -Root $Root @signArgs
                if ($setup) { Write-Host ("Installer: " + $setup) }
            }
            # Covers archives, launchers and the installer in one published digest file.
            $sums = New-PSManagerChecksumFile -Destination $Destination
            Write-Host ("Checksums: " + $sums)
            $failed = $false
            foreach ($path in $paths) {
                $smoke = ($SmokeRun -and (Split-Path -Leaf $path) -eq 'psmgr.exe')
                $report = Test-PSManagerBuild -Path $path -ExpectedVersion $Version -SmokeRun:$smoke
                if (-not $report.Passed) {
                    Write-Host ("FAIL: " + $path)
                    $report.Problems | ForEach-Object { Write-Host ("  - " + $_) }
                    $failed = $true
                }
            }
            if ($failed) { exit 1 }
            Write-Host 'Build complete.'
        }
    }
} catch {
    Write-Host ("BUILD ERROR: " + $_.Exception.Message)
    exit 1
}
