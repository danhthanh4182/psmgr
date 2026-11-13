#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Sync - App Name Resolution
.DESCRIPTION
    Maps manifest app names to the binary shims scoop actually creates,
    so health checks and fixes work when package name != exe name.
#>

$Script:APP_BIN_MAP = @{
    "ripgrep"   = "rg"
    "grep"      = "grep"
    "fd"        = "fd"
    "eza"       = "eza"
    "bat"       = "bat"
}

function Get-AppShimPaths {
    # All shim paths an app could expose (package name + mapped binary name).
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$App)

    $names = @($App)
    if ($Script:APP_BIN_MAP[$App]) { $names += $Script:APP_BIN_MAP[$App] }

    $paths = [System.Collections.Generic.List[string]]::new()
    $shimDir = Join-Path $env:USERPROFILE "scoop\shims"
    foreach ($n in $names) {
        $paths.Add((Join-Path $shimDir "$n.exe"))
        $paths.Add((Join-Path $shimDir "$n.cmd"))
    }
    return $paths.ToArray()
}

function Test-AppAvailable {
    # True when the app binary is reachable via PATH or any of its shims.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$App)

    if (Get-Command $App -ErrorAction SilentlyContinue) { return $true }
    foreach ($bin in @($App) + @($(if ($Script:APP_BIN_MAP[$App]) { @($Script:APP_BIN_MAP[$App]) } else { @() }))) {
        if ($bin -ne $App -and (Get-Command $bin -ErrorAction SilentlyContinue)) { return $true }
    }
    foreach ($p in (Get-AppShimPaths -App $App)) {
        if (Test-Path -LiteralPath $p) { return $true }
    }
    return $false
}