#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager - Universal Git Hooks Setup
.DESCRIPTION
    Configures git core.hooksPath to .agents/hooks for all agents and contributors.
#>

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-Warning "Git is not installed or not in PATH. Skipping hook configuration."
    exit 0
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repoRoot ".git"))) {
    $repoRoot = $PSScriptRoot
}

if (Test-Path (Join-Path $repoRoot ".git")) {
    & git -C $repoRoot config core.hooksPath .agents/hooks
    $configured = & git -C $repoRoot config --get core.hooksPath
    if ($configured -eq ".agents/hooks") {
        Write-Host "✅ Universal Git Hooks configured successfully (.agents/hooks)" -ForegroundColor Green
    } else {
        Write-Warning "Failed to set core.hooksPath in $repoRoot"
    }
} else {
    Write-Warning "Not a git repository: $repoRoot"
}
