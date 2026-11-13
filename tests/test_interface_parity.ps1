#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Automated Contract Test - Tri-Interface Parity (CLI, TUI, GUI)
.DESCRIPTION
    Enforces simultaneous 3-way parity across CLI, TUI, and Desktop GUI interfaces.
    Fails if any capability defined in ActionRegistry is missing in any interface.
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

Import-Module (Join-Path $RootDir "PSManager.psd1") -Force

$actions = Get-PSManagerActions
if (-not $actions -or $actions.Count -eq 0) {
    throw "Get-PSManagerActions returned no registered actions."
}

# 1. Read CLI Action Set
$cliScript = Get-Content (Join-Path $RootDir "ps-manager.ps1") -Raw
$cliValidateMatch = [regex]::Match($cliScript, "\[ValidateSet\(([^)]+)\)\]")
if (-not $cliValidateMatch.Success) {
    throw "Could not locate [ValidateSet] in ps-manager.ps1"
}
$cliRegistered = $cliValidateMatch.Groups[1].Value -replace "['\s]", "" -split ","

# 2. Read TUI Action Set (menu ids now live in the action catalog module)
$tuiScript = Get-Content (Join-Path $RootDir "modules\UI\TuiEngine.ps1") -Raw
$tuiCatalog = Get-Content (Join-Path $RootDir "modules\UI\TuiCatalog.ps1") -Raw
$tuiMatches = [regex]::Matches(($tuiScript + "`n" + $tuiCatalog), "Id\s*=\s*'([^']+)'")
$tuiRegistered = @($tuiMatches | ForEach-Object { $_.Groups[1].Value })

# 3. Read GUI Button Set
$guiScript = Get-Content (Join-Path $RootDir "gui.ps1") -Raw
# Window markup moved to ui\*.xaml, so element names must be read from both the
# script (dialog XAML) and the extracted window/theme resources.
$guiXamlDir = Join-Path $RootDir "ui"
if (Test-Path -LiteralPath $guiXamlDir) {
    foreach ($xamlFile in Get-ChildItem -LiteralPath $guiXamlDir -Filter *.xaml -File) {
        $guiScript += Get-Content -LiteralPath $xamlFile.FullName -Raw -Encoding UTF8
    }
}
$guiMatches = [regex]::Matches($guiScript, 'x:Name="([^"]+)"')
$guiRegistered = @($guiMatches | ForEach-Object { $_.Groups[1].Value })

# 4. Verify Every Action Exists in ALL 3 Interfaces
$violations = [System.Collections.Generic.List[string]]::new()

foreach ($action in $actions) {
    $id = $action.Id
    $cliAct = $action.CliAction
    $guiBtn = $action.GuiButton

    # Check CLI
    if ($cliAct -and ($cliAct -notin $cliRegistered)) {
        $violations.Add("Action '$id' missing from CLI ValidateSet in ps-manager.ps1 (expected '$cliAct')")
    }

    # Check TUI
    if ($action.TuiKey -and ($id -notin $tuiRegistered)) {
        $violations.Add("Action '$id' missing from TUI menuItems in modules/UI/TuiEngine.ps1")
    }

    # Check GUI
    if ($guiBtn -and ($guiBtn -notin $guiRegistered)) {
        $violations.Add("Action '$id' missing from GUI XAML elements in gui.ps1 (expected '$guiBtn')")
    }
}

# 5. Verify CLI Actions Exist in Help Catalog
$catalogSections = Get-PSManagerHelpSections -Language 'en'
$helpActions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($section in $catalogSections) {
    foreach ($item in $section.Items) {
        if ($item.CliAction) {
            $null = $helpActions.Add([string]$item.CliAction)
        }
    }
}

foreach ($cli in $cliRegistered) {
    if ($cli -in @('edit', '--help', '-h')) { continue }
    if (-not $helpActions.Contains($cli)) {
        $violations.Add("CLI action '$cli' is registered in ps-manager.ps1 but missing from the help catalog")
    }
}

if ($violations.Count -gt 0) {
    Write-Host "`n❌ TRI-INTERFACE PARITY VIOLATIONS DETECTED ($($violations.Count)):" -ForegroundColor Red
    foreach ($v in $violations) {
        Write-Host "  - $v" -ForegroundColor Yellow
    }
    throw "Tri-interface parity check failed with $($violations.Count) violation(s). All features must be implemented across CLI, TUI, and GUI simultaneously."
}

Write-Host "✅ [PASS] Tri-Interface Parity Contract verified: all $($actions.Count) capabilities synchronized across CLI, TUI, and GUI." -ForegroundColor Green
exit 0
