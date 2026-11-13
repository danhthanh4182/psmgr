#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager UI - ANSI Theme & Formatters
#>

$Script:THEME_ENABLED = $true
$Script:ESC = [char]27
$Script:THEME = @{
    Reset   = "$($Script:ESC)[0m"
    Bold    = "$($Script:ESC)[1m"
    Dim     = "$($Script:ESC)[2m"
    Cyan    = "$($Script:ESC)[38;2;86;182;194m"
    Blue    = "$($Script:ESC)[38;2;97;175;239m"
    Green   = "$($Script:ESC)[38;2;152;195;121m"
    Yellow  = "$($Script:ESC)[38;2;229;192;123m"
    Red     = "$($Script:ESC)[38;2;224;108;117m"
    Purple  = "$($Script:ESC)[38;2;198;120;221m"
    Gray    = "$($Script:ESC)[38;2;92;99;112m"
    White   = "$($Script:ESC)[38;2;220;223;228m"
}

function Set-PSManagerTheme {
    [CmdletBinding()]
    param(
        [switch]$NoColor
    )
    if ($NoColor) {
        $Script:THEME_ENABLED = $false
        foreach ($k in @($Script:THEME.Keys)) {
            $Script:THEME[$k] = ""
        }
    } else {
        $Script:THEME_ENABLED = $true
        $Script:THEME['Reset']   = "$($Script:ESC)[0m"
        $Script:THEME['Bold']    = "$($Script:ESC)[1m"
        $Script:THEME['Dim']     = "$($Script:ESC)[2m"
        $Script:THEME['Cyan']    = "$($Script:ESC)[38;2;86;182;194m"
        $Script:THEME['Blue']    = "$($Script:ESC)[38;2;97;175;239m"
        $Script:THEME['Green']   = "$($Script:ESC)[38;2;152;195;121m"
        $Script:THEME['Yellow']  = "$($Script:ESC)[38;2;229;192;123m"
        $Script:THEME['Red']     = "$($Script:ESC)[38;2;224;108;117m"
        $Script:THEME['Purple']  = "$($Script:ESC)[38;2;198;120;221m"
        $Script:THEME['Gray']    = "$($Script:ESC)[38;2;92;99;112m"
        $Script:THEME['White']   = "$($Script:ESC)[38;2;220;223;228m"
    }
}

function Disable-PSManagerColor {
    [CmdletBinding()]
    param()
    Set-PSManagerTheme -NoColor
}

function Format-ColorText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position=0)]
        [string]$Color = "",
        [Parameter(Mandatory=$true, Position=1)]
        [string]$Text
    )
    if (-not $Script:THEME_ENABLED) { return $Text }
    if (-not $Color) { $Color = if ($Script:THEME) { $Script:THEME.White } else { "" } }
    $reset = if ($Script:THEME) { $Script:THEME.Reset } else { "" }
    return ($Color + $Text + $reset)
}

function Format-ColorBadge {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position=0)]
        [string]$Color = "",
        [Parameter(Mandatory=$true, Position=1)]
        [string]$Text
    )
    if (-not $Script:THEME_ENABLED) { return "[$Text]" }
    if (-not $Color) { $Color = if ($Script:THEME) { $Script:THEME.White } else { "" } }
    $reset = if ($Script:THEME) { $Script:THEME.Reset } else { "" }
    return ($Color + '[' + $Text + ']' + $reset)
}

function Get-PSManagerTheme {
    [CmdletBinding()]
    param(
        [switch]$NoColor
    )
    if ($NoColor) {
        Disable-PSManagerColor
    }
    return $Script:THEME
}
# Compatibility aliases
New-Alias -Name 'Color-Text' -Value 'Format-ColorText' -Force -ErrorAction SilentlyContinue

function Test-CliUnicode {
    # Console glyphs are only worth emitting when the code page can carry them.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        return ([Console]::OutputEncoding.CodePage -eq 65001 -or [Console]::OutputEncoding.WebName -match '^utf-?8$')
    } catch {
        return $false
    }
}

function Get-CliGlyph {
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateSet('OK', 'Fail', 'Warn', 'Info', 'Arrow', 'Bullet', 'Rule')][string]$Kind)
    $unicode = Test-CliUnicode
    switch ($Kind) {
        'OK'     { return $(if ($unicode) { [string][char]0x2713 } else { 'OK' }) }
        'Fail'   { return $(if ($unicode) { [string][char]0x2717 } else { 'x' }) }
        'Warn'   { return '!' }
        'Info'   { return 'i' }
        'Arrow'  { return $(if ($unicode) { [string][char]0x2192 } else { '->' }) }
        'Bullet' { return $(if ($unicode) { [string][char]0x00B7 } else { '-' }) }
        'Rule'   { return $(if ($unicode) { [string][char]0x2500 } else { '-' }) }
    }
    return ''
}

function Get-CliTextWidth {
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $clean = $Text -replace '\x1b\[[0-9;]*[a-zA-Z]', ''
    return $clean.Length
}

function Write-CliRule {
    [CmdletBinding()]
    param([int]$Width = 0)
    if ($Width -le 0) {
        $Width = 64
        try { if ([Console]::WindowWidth -gt 20) { $Width = [Math]::Min(78, [Console]::WindowWidth - 2) } } catch {}
    }
    $glyph = Get-CliGlyph -Kind Rule
    $line = ''
    for ($i = 0; $i -lt $Width; $i++) { $line += $glyph }
    Write-Host (Format-ColorText $Script:THEME.Gray $line)
}

function Write-CliHeading {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host ''
    Write-Host (Format-ColorText ($Script:THEME.Cyan + $Script:THEME.Bold) $Text)
    Write-CliRule
}

function Write-CliSuccess {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host (Format-ColorText $Script:THEME.Green ((Get-CliGlyph -Kind OK) + ' ' + $Text))
}

function Write-CliWarning {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host (Format-ColorText $Script:THEME.Yellow ((Get-CliGlyph -Kind Warn) + ' ' + $Text))
}

function Write-CliError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Hint = ''
    )
    Write-Host (Format-ColorText $Script:THEME.Red ((Get-CliGlyph -Kind Fail) + ' ' + $Text))
    if ($Hint) {
        Write-Host (Format-ColorText $Script:THEME.Gray ('  ' + (Get-CliGlyph -Kind Arrow) + ' ' + $Hint))
    }
}

function Write-CliInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host (Format-ColorText $Script:THEME.Gray ('  ' + (Get-CliGlyph -Kind Bullet) + ' ' + $Text))
}
function Test-CliRowKey {
    # Rows may be hashtables (CLI panels) or PSCustomObjects (audit reports).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][object]$Row,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if ($Row -is [System.Collections.IDictionary]) { return $Row.Contains($Key) }
    return ($null -ne $Row.PSObject.Properties[$Key])
}

function Get-CliRowValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Row,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.Contains($Key)) { return $Row[$Key] }
        return $null
    }
    $prop = $Row.PSObject.Properties[$Key]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function Write-CliKeyValueTable {
    <#
    .SYNOPSIS
        Renders aligned "label  value" rows, grouped by section, with optional status colour.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [int]$LabelWidth = 0
    )
    if ($LabelWidth -le 0) {
        $LabelWidth = 20
        foreach ($row in $Rows) {
            if ((Test-CliRowKey -Row $row -Key 'Section') -and (Get-CliRowValue -Row $row -Key 'Section')) { continue }
            $w = ([string](Get-CliRowValue -Row $row -Key 'Label')).Length
            if ($w -gt $LabelWidth) { $LabelWidth = $w }
        }
        $LabelWidth = [Math]::Min(28, $LabelWidth + 2)
    }
    foreach ($row in $Rows) {
        if ((Test-CliRowKey -Row $row -Key 'Section') -and (Get-CliRowValue -Row $row -Key 'Section')) {
            Write-Host ''
            Write-Host (Format-ColorText ($Script:THEME.Cyan + $Script:THEME.Bold) ('  ' + [string](Get-CliRowValue -Row $row -Key 'Section')))
            continue
        }
        $label = ([string](Get-CliRowValue -Row $row -Key 'Label')).PadRight($LabelWidth)
        $color = Get-CliRowValue -Row $row -Key 'Color'
        if (-not $color) { $color = $Script:THEME.White }
        Write-Host ('  ' + (Format-ColorText $Script:THEME.Gray $label) + (Format-ColorText $color ([string](Get-CliRowValue -Row $row -Key 'Value'))))
    }
}

function Write-CliStatusTable {
    <#
    .SYNOPSIS
        Renders audit/doctor rows with a coloured status glyph, item and details.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [switch]$ShowRecommendation
    )
    foreach ($row in $Rows) {
        $status = [string](Get-CliRowValue -Row $row -Key 'Status')
        $glyph = Get-CliGlyph -Kind Info
        $color = $Script:THEME.White
        switch -Regex ($status) {
            '^(PASS|OK)$'      { $glyph = Get-CliGlyph -Kind OK;   $color = $Script:THEME.Green;  break }
            '^(WARN|WARNING)$' { $glyph = Get-CliGlyph -Kind Warn; $color = $Script:THEME.Yellow; break }
            '^(FAIL|ERROR)$'   { $glyph = Get-CliGlyph -Kind Fail; $color = $Script:THEME.Red;    break }
            default            { $glyph = Get-CliGlyph -Kind Info; $color = $Script:THEME.Gray;   break }
        }
        $category = [string](Get-CliRowValue -Row $row -Key 'Category')
        $item = [string](Get-CliRowValue -Row $row -Key 'Item')
        $label = $category + ' ' + (Get-CliGlyph -Kind Bullet) + ' ' + $item
        Write-Host ('  ' + (Format-ColorText $color ($glyph + ' ' + $status.PadRight(5))) + (Format-ColorText $Script:THEME.White $label))
        $details = Get-CliRowValue -Row $row -Key 'Details'
        if ($details) {
            Write-Host ('      ' + (Format-ColorText $Script:THEME.Gray ([string]$details)))
        }
        $recommendation = Get-CliRowValue -Row $row -Key 'Recommendation'
        if ($ShowRecommendation -and $recommendation -and $status -match '^(WARN|FAIL)$') {
            Write-Host ('      ' + (Format-ColorText $Script:THEME.Yellow ((Get-CliGlyph -Kind Arrow) + ' ' + [string]$recommendation)))
        }
    }
}
New-Alias -Name 'Color-Badge' -Value 'Format-ColorBadge' -Force -ErrorAction SilentlyContinue
