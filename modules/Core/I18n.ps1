#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Core - Internationalization (i18n) Engine
#>

# Resolve from the module layout (<root>\modules\Core\I18n.ps1 -> <root>\i18n.json)
# so a worktree, a copy, or an installed package all read their own dictionary.
$Script:I18N_PATH = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'i18n.json'
$Script:I18N_DATA = $null

function Get-EffectiveLanguage {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $cfg = Get-PSManagerConfig
    $lang = if ($cfg.language) { ([string]$cfg.language).Trim().ToLowerInvariant() } else { "" }

    # An explicit stored mode wins on both engines: PS 5.1 may render 'vi' when
    # its terminal is UTF-8, and PS 7 may still be pinned to 'vi-ascii'.
    switch ($lang) {
        'en' { return 'en' }
        'vi' { return 'vi' }
        'vi-ascii' { return 'vi-ascii' }
    }

    # Unknown or missing mode: use the safest encoding for the active engine.
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        return 'vi'
    } else {
        return 'vi-ascii'
    }
}

function Get-I18nText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Key,
        # Optional explicit language override: the GUI passes its selected
        # mode and the TUI passes the effective mode for its terminal.
        [Parameter(Position=1)]
        [string]$Language
    )

    if ($null -eq $Script:I18N_DATA -and (Test-Path $Script:I18N_PATH)) {
        try {
            $Script:I18N_DATA = Get-Content $Script:I18N_PATH -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Verbose "Could not load i18n file: $($_.Exception.Message)"
        }
    }

    $effLang = if ($Language) { $Language } else { Get-EffectiveLanguage }

    if ($Script:I18N_DATA) {
        if ($Script:I18N_DATA.$effLang -and $Script:I18N_DATA.$effLang.$Key) {
            return $Script:I18N_DATA.$effLang.$Key
        }
        if ($Script:I18N_DATA.en -and $Script:I18N_DATA.en.$Key) {
            return $Script:I18N_DATA.en.$Key
        }
    }

    return $Key
}
