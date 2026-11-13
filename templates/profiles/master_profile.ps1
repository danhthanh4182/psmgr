# ==============================================================================
# PSManager Universal Profile (Compatible with PS 5.1 and PS 7+)
# Managed by PSManager (https://github.com/danhthanh4182/psmgr)
# ==============================================================================

# 1. Console Encoding & Stream Guards
if ($PSVersionTable.PSVersion.Major -ge 7) {
    # Modern PowerShell 7+ Core UTF-8
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
} else {
    # Windows PowerShell 5.1 conhost character preservation guard
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}

# 2. Package Manager PATH Initialization (Idempotent)
$ScoopShims = Join-Path $env:USERPROFILE "scoop\shims"
if ((Test-Path -LiteralPath $ScoopShims) -and ($env:PATH -notmatch [regex]::Escape($ScoopShims))) {
    $env:PATH = "$ScoopShims;$env:PATH"
}

# 3. Fast Node.js Manager (fnm)
if (Get-Command fnm -ErrorAction SilentlyContinue) {
    fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression
}

# 4. Git Prompt Helpers (must load before Starship, otherwise its prompt wins)
if (Get-Module -ListAvailable posh-git) {
    Import-Module posh-git -ErrorAction SilentlyContinue
}

# 5. Starship Cross-Shell Prompt
if ($env:TERM -ne 'dumb' -and (Get-Command starship -ErrorAction SilentlyContinue)) {
    Invoke-Expression (& starship init powershell)
}

# 6. PowerShell 7 Modern Enhancements
if ($PSVersionTable.PSVersion.Major -ge 7) {
    if (Get-Module -ListAvailable PSReadLine) {
        try {
            if (-not [Console]::IsOutputRedirected) {
                Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
                Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    if (Get-Module -ListAvailable Terminal-Icons) {
        Import-Module Terminal-Icons -ErrorAction SilentlyContinue
    }
}

# 7. Core Navigation & Management Aliases
function psmgr {
    $script = Join-Path $env:USERPROFILE "tools\ps-manager\ps-manager.ps1"
    if (Test-Path -LiteralPath $script) {
        & $script @args
    } else {
        Write-Error "PSManager harness not found at: $script"
    }
}

function ps7 {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) { & $pwsh.Source @args } else { Write-Error "PowerShell 7 (pwsh.exe) is not installed." }
}

function winps {
    $legacy = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $legacy) { & $legacy @args } else { Write-Error "Windows PowerShell 5.1 not found." }
}

# 8. Machine-Local Customizations (Excluded from Git dotfiles)
$LocalProfile = Join-Path $PSScriptRoot "local.ps1"
if (Test-Path -LiteralPath $LocalProfile) {
    . $LocalProfile
}
