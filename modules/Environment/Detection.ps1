#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Environment - PowerShell & Terminal State Detection
#>

$Script:WT_SETTINGS_PATH = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
$Script:WT_UNPACKAGED_SETTINGS = "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
$Script:USER_BIN_PATH = Join-Path $env:USERPROFILE 'bin'
$Script:LOCAL_BIN_PATH = Join-Path $env:USERPROFILE '.local\bin'
$Script:VSCODE_SETTINGS = "$env:APPDATA\Code\User\settings.json"

$Script:WT_DELEGATION_CONSOLE = "{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}"
$Script:WT_DELEGATION_TERMINAL = "{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}"

function Get-WTSettingsPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (Test-Path $Script:WT_SETTINGS_PATH) { return $Script:WT_SETTINGS_PATH }
    if (Test-Path $Script:WT_UNPACKAGED_SETTINGS) { return $Script:WT_UNPACKAGED_SETTINGS }
    return $null
}

function Get-PSInstallations {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $res = [ordered]@{
        PS5 = $null
        PS7 = $null
        PS7Preview = $null
    }

    # 1. Windows PowerShell 5.1
    $ps5Exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $ps5Exe) {
        $v5 = $null
        try {
            $rawV5 = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ps5Exe)
            $v5 = $rawV5.ProductVersion
        } catch {}
        $res.PS5 = [pscustomobject]@{
            Version      = if ($v5) { $v5 } else { "5.1" }
            Path         = $ps5Exe
            Edition      = "Desktop"
            Architecture = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
        }
    }

    # 2. PowerShell 7+
    $pwshCommands = @(Get-Command pwsh.exe -All -ErrorAction SilentlyContinue)
    $pwshExe = $null
    if ($pwshCommands.Count -gt 0) {
        $pwshExe = $pwshCommands[0].Source
    } else {
        $possiblePaths = @(
            "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe",
            "$env:ProgramFiles\PowerShell\7\pwsh.exe",
            "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe"
        )
        foreach ($p in $possiblePaths) {
            if (Test-Path $p) { $pwshExe = $p; break }
        }
    }

    if ($pwshExe) {
        $ver = $null
        try {
            $verOut = & $pwshExe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            if ($verOut) { $ver = $verOut.Trim() }
        } catch {}
        if (-not $ver) {
            try {
                $ver = ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($pwshExe)).ProductVersion
            } catch {}
        }
        $res.PS7 = [pscustomobject]@{
            Version      = if ($ver) { $ver } else { "7.x" }
            Path         = $pwshExe
            Edition      = "Core"
            Architecture = "x64"
        }
    }

    # 3. PowerShell Preview
    $previewCmd = Get-Command pwsh-preview.exe -ErrorAction SilentlyContinue
    if ($previewCmd) {
        $res.PS7Preview = [pscustomobject]@{
            Version = "Preview"
            Path    = $previewCmd.Source
            Edition = "Core Preview"
        }
    }

    return $res
}

function Get-PSManagerStatus {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $inst = Get-PSInstallations
    $wtPath = Get-WTSettingsPath
    $wtDefaultProfile = $null
    $wtProfiles = @()
    $wtDefaultIsPS7 = $false
    $wtDefaultIsPS5 = $false
    $ps7Guid = $null
    $ps5Guid = $null

    if ($wtPath) {
        try {
            $json = Get-Content $wtPath -Raw | ConvertFrom-Json
            $wtDefaultProfile = $json.defaultProfile
            if ($json.profiles.list) {
                $wtProfiles = $json.profiles.list
            } elseif ($json.profiles) {
                $wtProfiles = $json.profiles
            }
            foreach ($p in $wtProfiles) {
                if ($p.name -match 'PowerShell 7' -or ($p.source -match 'PowershellCore' -and $p.name -eq 'PowerShell 7')) {
                    $ps7Guid = $p.guid
                } elseif (-not $ps7Guid -and ($p.source -match 'PowershellCore' -or $p.name -eq 'PowerShell')) {
                    $ps7Guid = $p.guid
                }
                if ($p.name -match 'Windows PowerShell' -or $p.commandline -match 'WindowsPowerShell') {
                    $ps5Guid = $p.guid
                }
            }
            if ($wtDefaultProfile -eq $ps7Guid) { $wtDefaultIsPS7 = $true }
            if ($wtDefaultProfile -eq $ps5Guid) { $wtDefaultIsPS5 = $true }
        } catch {}
    }

    # Terminal Host Delegation (Windows 11)
    $regDelegation = $null
    $isWTDefaultHost = $false
    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Console\%%Startup' -ErrorAction SilentlyContinue
        if ($reg) {
            $regDelegation = $reg.DelegationTerminal
            if ($regDelegation -eq $Script:WT_DELEGATION_TERMINAL) {
                $isWTDefaultHost = $true
            }
        }
    } catch {}

    # PATH Command Shim
    $shimActive = $false
    $shimPaths = @("$Script:USER_BIN_PATH\powershell.cmd", "$Script:LOCAL_BIN_PATH\powershell.cmd")
    foreach ($sp in $shimPaths) {
        if (Test-Path $sp) {
            $content = Get-Content $sp -Raw -ErrorAction SilentlyContinue
            if ($content -match 'pwsh') {
                $shimActive = $true
                break
            }
        }
    }

    # VS Code Default Terminal
    $vscodePS7 = $false
    if (Test-Path $Script:VSCODE_SETTINGS) {
        try {
            $vc = Get-Content $Script:VSCODE_SETTINGS -Raw | ConvertFrom-Json
            if ($vc.'terminal.integrated.defaultProfile.windows' -match 'PowerShell 7|PowerShell|pwsh') {
                $vscodePS7 = $true
            }
        } catch {}
    }

    # Context Menu
    $contextMenuInstalled = $false
    if (Test-Path 'HKCU:\Software\Classes\Directory\Background\shell\OpenPowerShell7') {
        $contextMenuInstalled = $true
    }

    $overallPS7 = $wtDefaultIsPS7 -and $isWTDefaultHost
    $cfg = Get-PSManagerConfig
    $target = Get-SourcePackageTarget

    return [pscustomobject]@{
        Installations        = $inst
        WTSettingsPath       = $wtPath
        WTDefaultProfile     = $wtDefaultProfile
        PS7Guid              = $ps7Guid
        PS5Guid              = $ps5Guid
        WTDefaultIsPS7       = $wtDefaultIsPS7
        WTDefaultIsPS5       = $wtDefaultIsPS5
        IsWTDefaultHost      = $isWTDefaultHost
        ShimActive           = $shimActive
        VSCodeDefaultPS7     = $vscodePS7
        ContextMenuInstalled = $contextMenuInstalled
        OverallPS7Default    = $overallPS7
        CurrentHostVersion   = $PSVersionTable.PSVersion.ToString()
        CurrentHostEdition   = $PSVersionTable.PSEdition
        UpdateSource         = $cfg.updateSource
        Channel              = $cfg.channel
        Language             = $cfg.language
        TargetPackage        = $target
    }
}
