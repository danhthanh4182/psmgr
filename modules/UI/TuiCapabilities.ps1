#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager TUI - Terminal Capability Detection & Symbols
.DESCRIPTION
    Detects terminal capabilities: TTY redirection, UTF-8/Unicode box drawing support,
    16-color ANSI VT support, NO_COLOR, terminal window dimensions, and plain mode.
    Provides resolution-independent box-drawing symbols and character width helpers.
#>

function Get-TuiCapabilities {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable]$Override = @{}
    )

    # 1. TTY Detection
    $isOutRedirected = $false
    $isInRedirected  = $false
    try { $isOutRedirected = [Console]::IsOutputRedirected } catch {}
    try { $isInRedirected  = [Console]::IsInputRedirected }  catch {}
    $isTty = (-not $isOutRedirected) -and (-not $isInRedirected)

    # 2. Plain Mode
    $plainMode = $false
    if ($env:PSMGR_PLAIN -eq '1') {
        $plainMode = $true
    }

    # 3. Unicode Support
    # Requires OutputEncoding CodePage 65001 or utf-8, and not forced to plain/ascii
    $encodingIsUtf8 = $false
    try {
        if ([Console]::OutputEncoding.CodePage -eq 65001 -or [Console]::OutputEncoding.WebName -match '^utf-?8$') {
            $encodingIsUtf8 = $true
        }
    } catch {}
    $hasUnicode = $encodingIsUtf8 -and (-not $plainMode)

    # 4. Colour support and VT (virtual terminal) support are separate concerns:
    # NO_COLOR disables colours, but the alternate screen and cursor addressing still
    # need VT. Without VT the engine falls back to the plain list.
    $hasColor = $true
    if ($null -ne $env:NO_COLOR -and $env:NO_COLOR -ne "") {
        $hasColor = $false
    }
    if ($plainMode -or -not $isTty) {
        $hasColor = $false
    }

    $hasVt = $false
    try { if ($Host.UI.SupportsVirtualTerminal) { $hasVt = $true } } catch {}
    if (-not $hasVt -and $env:WT_SESSION) { $hasVt = $true }
    if (-not $hasVt -and $env:TERM -and $env:TERM -match '^(xterm|screen|tmux|linux)') { $hasVt = $true }
    if (-not $hasVt -and $isTty) {
        # Legacy conhost: VT is only usable when the console mode already enables it.
        try {
            if (-not ('PSManager.Native.ConsoleMode' -as [type])) {
                Add-Type -Namespace PSManager.Native -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
'@
            }
            $handle = [PSManager.Native.ConsoleMode]::GetStdHandle(-11)
            $mode = [uint32]0
            if ([PSManager.Native.ConsoleMode]::GetConsoleMode($handle, [ref]$mode)) {
                if (($mode -band 0x0004) -ne 0) { $hasVt = $true }
            }
        } catch {}
    }
    if ($plainMode -or -not $isTty) { $hasVt = $false }

    # 5. Window Dimensions
    $width = 110
    $height = 30
    try {
        if ([Console]::WindowWidth -gt 0)  { $width = [Console]::WindowWidth }
        if ([Console]::WindowHeight -gt 0) { $height = [Console]::WindowHeight }
    } catch {
        try {
            $rawSize = $Host.UI.RawUI.WindowSize
            if ($rawSize.Width -gt 0)  { $width = $rawSize.Width }
            if ($rawSize.Height -gt 0) { $height = $rawSize.Height }
        } catch {}
    }
    if ($Override) {
        if ($Override.ContainsKey('HasUnicode')) { $hasUnicode = [bool]$Override['HasUnicode'] }
        if ($Override.ContainsKey('HasColor'))   { $hasColor   = [bool]$Override['HasColor'] }
        if ($Override.ContainsKey('Width'))      { $width      = [int]$Override['Width'] }
        if ($Override.ContainsKey('Height'))     { $height     = [int]$Override['Height'] }
        if ($Override.ContainsKey('PlainMode'))  { $plainMode  = [bool]$Override['PlainMode'] }
        if ($Override.ContainsKey('IsTty'))      { $isTty      = [bool]$Override['IsTty'] }
    }

    # Symbols table: Unicode vs ASCII fallback (NEVER use emoji per spec §3.41)
    $esc = [char]27
    $symbols = if ($hasUnicode) {
        @{
            HLine        = "─"
            VLine        = "│"
            TopLeft      = "┌"
            TopRight     = "┐"
            BottomLeft   = "└"
            BottomRight  = "┘"
            TDown        = "┬"
            TUp          = "┴"
            TRight       = "├"
            TLeft        = "┤"
            Cross        = "┼"
            Bullet       = "●"
            Check        = "✓"
            CrossMark    = "✗"
            ArrowUp      = "▲"
            ArrowDown    = "▼"
            Pointer      = "›"
            Warning      = "!"
            EmptyCircle  = "○"
            Ellipsis     = "…"
            Sep          = "·"
            IconShell    = "◆"
            IconLaunch   = "▸"
            IconUpdate   = "↻"
            IconBackup   = "▣"
            IconHealth   = "✚"
            Undo         = "↺"
            ScrollTrack  = "░"
            ScrollThumb  = "█"
        }
    } else {
        @{
            HLine        = "-"
            VLine        = "|"
            TopLeft      = "+"
            TopRight     = "+"
            BottomLeft   = "+"
            BottomRight  = "+"
            TDown        = "+"
            TUp          = "+"
            TRight       = "+"
            TLeft        = "+"
            Cross        = "+"
            Bullet       = "*"
            Check        = "v"
            CrossMark    = "x"
            ArrowUp      = "^"
            ArrowDown    = "v"
            Pointer      = ">"
            Warning      = "!"
            EmptyCircle  = "o"
            Ellipsis     = "..."
            Sep          = "-"
            IconShell    = "*"
            IconLaunch   = ">"
            IconUpdate   = "~"
            IconBackup   = "#"
            IconHealth   = "+"
            Undo         = "<"
            ScrollTrack  = ":"
            ScrollThumb  = "#"
        }
    }

    # 16-color ANSI Palette (honors user's terminal theme, never hardcoded 24-bit RGB)
    $colors = if ($hasColor) {
        @{
            Reset       = "$esc[0m"
            Bold        = "$esc[1m"
            Dim         = "$esc[2m"
            Underline   = "$esc[4m"
            Invert      = "$esc[7m"
            Black       = "$esc[30m"
            Red         = "$esc[31m"
            Green       = "$esc[32m"
            Yellow      = "$esc[33m"
            Blue        = "$esc[34m"
            Magenta     = "$esc[35m"
            Cyan        = "$esc[36m"
            White       = "$esc[37m"
            BrightBlack = "$esc[90m"
            BrightRed   = "$esc[91m"
            BrightGreen = "$esc[92m"
            BrightYellow= "$esc[93m"
            BrightBlue  = "$esc[94m"
            BrightMagenta="$esc[95m"
            BrightCyan  = "$esc[96m"
            BrightWhite = "$esc[97m"
            BgBlue      = "$esc[44m"
            BgDark      = "$esc[40m"
        }
    } else {
        @{
            Reset       = ""
            Bold        = ""
            Dim         = ""
            Underline   = ""
            Invert      = ""
            Black       = ""
            Red         = ""
            Green       = ""
            Yellow      = ""
            Blue        = ""
            Magenta     = ""
            Cyan        = ""
            White       = ""
            BrightBlack = ""
            BrightRed   = ""
            BrightGreen = ""
            BrightYellow= ""
            BrightBlue  = ""
            BrightMagenta=""
            BrightCyan  = ""
            BrightWhite = ""
            BgBlue      = ""
            BgDark      = ""
        }
    }

    $caps = @{
        IsTty       = $isTty
        PlainMode   = $plainMode
        HasUnicode  = $hasUnicode
        HasColor    = $hasColor
        HasVt       = $hasVt
        Width       = $width
        Height      = $height
        Symbols     = $symbols
        Colors      = $colors
    }

    # Apply overrides (for test harness, snapshot generators, headless simulation)
    if ($Override) {
        foreach ($k in $Override.Keys) {
            if ($k -eq 'Symbols' -and $Override[$k] -is [hashtable]) {
                foreach ($sk in $Override[$k].Keys) { $caps.Symbols[$sk] = $Override[$k][$sk] }
            } elseif ($k -eq 'Colors' -and $Override[$k] -is [hashtable]) {
                foreach ($ck in $Override[$k].Keys) { $caps.Colors[$ck] = $Override[$k][$ck] }
            } else {
                $caps[$k] = $Override[$k]
            }
        }
    }

    return $caps
}
