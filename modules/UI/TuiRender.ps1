#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager TUI - Pure Frame Renderer & ANSI Diff Writer
.DESCRIPTION
    Pure rendering engine: transforms TUI state and terminal capabilities into a string[] frame.
    Separates frame computation from terminal output, allowing full off-screen golden snapshot
    testing without an active console window.
#>

function Get-TuiStringWidth {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter()]$Text)
    if ($null -eq $Text) { return 0 }
    $s = [string]$Text
    if ($s.Length -eq 0) { return 0 }

    # Strip ANSI escape sequences before calculating visual column width (\x1b for PS 5.1 compatibility)
    $clean = $s -replace '\x1b\[[0-9;]*[a-zA-Z]', ""
    try { $clean = $clean.Normalize([System.Text.NormalizationForm]::FormC) } catch {}
    $enumerator = [System.Globalization.StringInfo]::GetTextElementEnumerator($clean)
    $width = 0
    while ($enumerator.MoveNext()) {
        $te = [string]$enumerator.Current
        $code = [int][char]0
        if ($te.Length -eq 1) {
            $code = [int]$te[0]
        } elseif ($te.Length -eq 2 -and [char]::IsHighSurrogate($te[0])) {
            $code = [char]::ConvertToUtf32($te[0], $te[1])
        }
        # East-Asian wide/fullwidth characters occupy 2 columns
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6) -or
            ($code -ge 0x20000 -and $code -le 0x3FFFD)) {
            $width += 2
        } else {
            $width += 1
        }
    }
    return $width
}

function Get-TuiPaddedText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]$Text,
        [Parameter(Mandatory = $true)][int]$TargetWidth,
        [switch]$Truncate,
        [string]$Ellipsis = "..."
    )
    $s = if ($null -eq $Text) { "" } else { [string]$Text }
    $curWidth = Get-TuiStringWidth $s
    if ($curWidth -eq $TargetWidth) { return $s }

    if ($curWidth -lt $TargetWidth) {
        return ($s + (" " * ($TargetWidth - $curWidth)))
    }

    if ($Truncate) {
        $ellW = Get-TuiStringWidth $Ellipsis
        $maxW = [Math]::Max(0, ($TargetWidth - $ellW))
        $clean = $s -replace '\x1b\[[0-9;]*[a-zA-Z]', ""
        $sb = [System.Text.StringBuilder]::new()
        $w = 0
        $enum = [System.Globalization.StringInfo]::GetTextElementEnumerator($clean)
        while ($enum.MoveNext()) {
            $elem = [string]$enum.Current
            $elemW = Get-TuiStringWidth $elem
            if ($w + $elemW -gt $maxW) { break }
            $null = $sb.Append($elem)
            $w += $elemW
        }
        $null = $sb.Append($Ellipsis)
        $pad = $TargetWidth - (Get-TuiStringWidth $sb.ToString())
        if ($pad -gt 0) { $null = $sb.Append(" " * $pad) }
        return $sb.ToString()
    }

    return $s
}

function Get-TuiWrappedText {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]$Text,
        [Parameter(Mandatory = $true)][int]$MaxWidth
    )
    if ($null -eq $Text -or [string]::IsNullOrWhiteSpace($Text)) { return @() }
    if ($MaxWidth -le 0) { return @([string]$Text) }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($para in ($Text -split "`r?`n")) {
        if (-not $para) {
            $lines.Add("")
            continue
        }
        $words = $para -split '[ \t]+'
        $curLine = [System.Text.StringBuilder]::new()
        $curW = 0
        foreach ($word in $words) {
            if (-not $word) { continue }
            $wW = Get-TuiStringWidth $word
            if ($curW -eq 0) {
                $null = $curLine.Append($word)
                $curW = $wW
            } elseif ($curW + 1 + $wW -le $MaxWidth) {
                $null = $curLine.Append(" ").Append($word)
                $curW += 1 + $wW
            } else {
                $lines.Add($curLine.ToString())
                $null = $curLine.Clear().Append($word)
                $curW = $wW
            }
        }
        if ($curLine.Length -gt 0) {
            $lines.Add($curLine.ToString())
        }
    }
    return $lines.ToArray()
}

function ConvertTo-TuiSearchKey {
    <#
    .SYNOPSIS
        Diacritic-insensitive normalization (FormD) for fast Unicode Vietnamese matching.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Text)
    if (-not $Text) { return "" }
    $norm = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $norm.ToCharArray()) {
        $uc = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($uc -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            $null = $sb.Append($ch)
        }
    }
    $res = $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
    # d-bar has no Unicode decomposition, so map it explicitly (U+0111 / U+0110).
    $res = $res.Replace([string][char]0x0111, 'd').Replace([string][char]0x0110, 'D')
    return $res.ToLowerInvariant()
}

function New-TuiFrame {
    <#
    .SYNOPSIS
        Pure frame rendering function. Takes state + width/height + caps -> returns string[] lines.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][hashtable]$Caps
    )

    $sym = $Caps.Symbols
    $c   = $Caps.Colors
    $lang = [string]$State.Language

    # Every user-visible string comes from i18n.json (no hardcoded copy in this file).
    $i18nKeys = @(
        'tui_help_hint', 'tui_more', 'tui_search_prompt',
        'tui_status_shell', 'tui_status_host', 'tui_status_shim', 'tui_status_source',
        'tui_status_shim_on', 'tui_status_shim_off', 'tui_status_custom', 'tui_status_conhost',
        'tui_lang_vi', 'tui_lang_en',
        'tui_footer_full', 'tui_footer_medium', 'tui_footer_min',
        'tui_meta_admin', 'tui_meta_admin_yes', 'tui_meta_admin_no',
        'tui_meta_undo', 'tui_meta_undo_no', 'tui_meta_type', 'tui_meta_destructive',
        'tui_hint_preview', 'tui_hint_confirm', 'tui_hint_run',
        'tui_too_small_title', 'tui_too_small_detail', 'tui_search_empty',
        'tui_help_title', 'tui_help_global', 'tui_help_close',
        'tui_preview_title', 'tui_preview_apply', 'tui_preview_cancel',
        'tui_confirm_title', 'tui_confirm_body', 'tui_confirm_type',
        'tui_result_title', 'tui_result_ok', 'tui_result_fail', 'tui_result_time', 'tui_result_close',
        'tui_notif_title', 'tui_notif_empty', 'tui_notif_close', 'tui_notif_unread', 'tui_update_available'
    )
    $T = @{}
    foreach ($key in $i18nKeys) { $T[$key] = Get-I18nText $key $lang }

    # Guard: Terminal smaller than minimum supported resolution (80x24)
    if ($Width -lt 80 -or $Height -lt 24) {
        $tooSmallLines = [System.Collections.Generic.List[string]]::new()
        $msg1 = $T['tui_too_small_title']
        $msg2 = $T['tui_too_small_detail'] -f $Width, $Height

        $topPad = [Math]::Max(0, [int](($Height - 4) / 2))
        for ($i = 0; $i -lt $topPad; $i++) { $tooSmallLines.Add((" " * $Width)) }

        $tooSmallLines.Add((Get-TuiPaddedText -Text ("  " + $c.Yellow + $sym.Warning + " " + $msg1 + $c.Reset) -TargetWidth $Width -Truncate))
        $tooSmallLines.Add((Get-TuiPaddedText -Text ("    " + $c.Dim + $msg2 + $c.Reset) -TargetWidth $Width -Truncate))

        while ($tooSmallLines.Count -lt $Height) { $tooSmallLines.Add((" " * $Width)) }
        return $tooSmallLines.ToArray()
    }
    # Modal screens (help / preview / confirm / result) share the same box chrome.
    if ($State.Mode -in @('Help', 'Preview', 'Confirm', 'Result', 'Notifications')) {
        return (New-TuiModalFrame -State $State -Width $Width -Height $Height -Caps $Caps -Text $T)
    }


    # Outer Box Dimensions
    $boxW = $Width
    $innerW = $boxW - 2

    $frame = [System.Collections.Generic.List[string]]::new()

    # --- Header (Row 1) ---
    $titleLeft = " PSManager v" + $State.Version
    # The header names the active mode, so "vi" and "vi-ascii" are never confused.
    $langText = if ($lang -eq 'en') {
        $T['tui_lang_en']
    } elseif ($lang -eq 'vi-ascii') {
        Get-I18nText 'gui_lang_vi_ascii' $lang
    } else {
        $T['tui_lang_vi']
    }
    $helpHint  = $T['tui_help_hint']
    $titleRight = $langText + "   " + $helpHint + " "
    # Unread notifications prefix the legend; with no notifications the header is unchanged.
    $unreadCount = 0
    if ($State.ContainsKey('UnreadCount') -and $null -ne $State.UnreadCount) { $unreadCount = [int]$State.UnreadCount }
    if ($unreadCount -gt 0) { $titleRight = ('!' + $unreadCount + '  ') + $titleRight }
    $titleFillW = [Math]::Max(0, ($innerW - (Get-TuiStringWidth $titleLeft) - (Get-TuiStringWidth $titleRight)))

    $headerLine = $c.Cyan + $sym.VLine + $c.Bold + $c.BrightCyan + $titleLeft + $c.Reset + `
                  (" " * $titleFillW) + `
                  $c.Dim + $titleRight + $c.Reset + $c.Cyan + $sym.VLine + $c.Reset
    
    $topBorder = $c.Cyan + $sym.TopLeft + ($sym.HLine * $innerW) + $sym.TopRight + $c.Reset
    $divBorder = $c.Cyan + $sym.TRight + ($sym.HLine * $innerW) + $sym.TLeft + $c.Reset

    $frame.Add($topBorder)
    $frame.Add($headerLine)
    $frame.Add($divBorder)

    # --- Status Band (Rows 4-5) ---
    # 4 Status items: Default Shell, Terminal Host, Command Shim, Update Source
    $st = $State.Status
    $cfg = $State.Config

    # 1. Default Shell
    $shText = $T['tui_status_custom']
    $shColor = $c.Dim
    $shSym = $sym.EmptyCircle
    if ($st.WTDefaultIsPS7) {
        $shText = "PowerShell 7"
        $shColor = $c.Green
        $shSym = $sym.Bullet
    } elseif ($st.WTDefaultIsPS5) {
        $shText = "PowerShell 5.1"
        $shColor = $c.Yellow
        $shSym = $sym.Warning
    }
    $lblShell = $T['tui_status_shell']

    # 2. Terminal Host
    $hostText = if ($st.IsWTDefaultHost) { "Windows Terminal" } else { $T['tui_status_conhost'] }
    $hostColor = if ($st.IsWTDefaultHost) { $c.Green } else { $c.Yellow }
    $hostSym = if ($st.IsWTDefaultHost) { $sym.Bullet } else { $sym.Warning }
    $lblHost = $T['tui_status_host']

    # 3. Command Shim
    $shimText = if ($st.ShimActive) { $T['tui_status_shim_on'] } else { $T['tui_status_shim_off'] }
    $shimColor = if ($st.ShimActive) { $c.Green } else { $c.Dim }
    $shimSym = if ($st.ShimActive) { $sym.Bullet } else { $sym.EmptyCircle }
    $lblShim = $T['tui_status_shim']

    # 4. Source & Channel
    $srcName = if ($cfg.updateSource) { $cfg.updateSource } else { "winget" }
    $chName  = if ($cfg.channel) { $cfg.channel } else { "stable" }
    $sep = if ($sym.ContainsKey('Sep')) { $sym.Sep } else { "-" }
    $srcText = "$srcName $sep $chName"
    $srcColor = $c.Cyan
    $srcSym = $sym.Bullet
    $lblSrc = $T['tui_status_source']

    # Column split for the status band; each cell is truncated to its column so the
    # band can never overflow at narrow widths.
    $colW = [int]($innerW / 2)
    $colW2 = $innerW - $colW

    $cellShell = Get-TuiPaddedText -Text ("  " + $lblShell + "  " + $shSym + " " + $shText) -TargetWidth $colW -Truncate -Ellipsis $sym.Ellipsis
    $cellSrc   = Get-TuiPaddedText -Text ("  " + $lblSrc + "  " + $srcSym + " " + $srcText) -TargetWidth $colW2 -Truncate -Ellipsis $sym.Ellipsis
    $statLine1 = $c.Cyan + $sym.VLine + $c.Reset + $shColor + $cellShell + $c.Reset + $srcColor + $cellSrc + $c.Reset + $c.Cyan + $sym.VLine + $c.Reset
    $frame.Add($statLine1)

    $cellHost = Get-TuiPaddedText -Text ("  " + $lblHost + "  " + $hostSym + " " + $hostText) -TargetWidth $colW -Truncate -Ellipsis $sym.Ellipsis
    $cellShim = Get-TuiPaddedText -Text ("  " + $lblShim + "  " + $shimSym + " " + $shimText) -TargetWidth $colW2 -Truncate -Ellipsis $sym.Ellipsis
    $statLine2 = $c.Cyan + $sym.VLine + $c.Reset + $hostColor + $cellHost + $c.Reset + $shimColor + $cellShim + $c.Reset + $c.Cyan + $sym.VLine + $c.Reset
    $frame.Add($statLine2)
    $frame.Add($divBorder)

    # --- Flatten visible items (groups + items) ---
    $allCatalog = $State.Catalog
    $allGroups  = $State.Groups

    # Filtered view (single source of truth shared with the key reducer)
    $filteredItems = @(Get-TuiVisibleItems -State $State)

    # Build display list with non-selectable group headers
    $displayRows = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($grp in $allGroups) {
        $grpItems = @($filteredItems | Where-Object { $_.GroupId -eq $grp.Id })
        if ($grpItems.Count -eq 0) { continue }
        # Add group header row
        $displayRows.Add(@{
            IsHeader = $true
            GroupId  = $grp.Id
            Title    = $grp.Title
            Item     = $null
        })
        foreach ($it in $grpItems) {
            $displayRows.Add(@{
                IsHeader = $false
                Title    = $it.Title
                Item     = $it
            })
        }
    }

    # Selectable items index mapping (empty list when the search matches nothing)
    $noMatches = ($displayRows.Count -eq 0)
    $selectableRows = @($displayRows | Where-Object { (-not $_.IsHeader) -and ($null -ne $_.Item) })
    $selectedItem = $null
    if ($selectableRows.Count -gt 0) {
        $selIdx = [Math]::Max(0, [Math]::Min($State.SelectedIndex, ($selectableRows.Count - 1)))
        $selectedItem = $selectableRows[$selIdx].Item
    }

    # --- Layout mode ---
    # 2-pane needs >= 110 columns; below that the description sits under the list.
    $isTwoPane = ($Width -ge 110)
    $leftW = if ($isTwoPane) { [Math]::Max(44, [int][Math]::Floor($innerW * 0.45)) } else { $innerW }
    $rightW = if ($isTwoPane) { $innerW - $leftW - 1 } else { 0 }

    # Titles are never truncated: a row expands to as many visual lines as its title
    # needs. The pointer/icon gutter (4 columns), the key badge (3) and the scrollbar
    # column (1) keep their space.
    $paneW = [Math]::Max(20, ($leftW - 1))
    $titleAvailW = [Math]::Max(8, ($paneW - 9))
    $listLines = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($rowObj in $displayRows) {
        if ($rowObj.IsHeader) {
            $listLines.Add(@{ Kind = 'header'; GroupId = [string]$rowObj.GroupId; Item = $null; Text = [string]$rowObj.Title; First = $true })
            continue
        }
        $it = $rowObj.Item
        $segments = @(Get-TuiWrappedText -Text ([string]$it.Title) -MaxWidth $titleAvailW)
        if ($segments.Count -eq 0) { $segments = @('') }
        for ($si = 0; $si -lt $segments.Count; $si++) {
            $listLines.Add(@{ Kind = 'item'; GroupId = [string]$it.GroupId; Item = $it; Text = [string]$segments[$si]; First = ($si -eq 0) })
        }
    }

    # Group identity: icon and colour per section, so the list is scannable.
    $groupIcon = @{
        shell  = $sym.IconShell
        launch = $sym.IconLaunch
        update = $sym.IconUpdate
        backup = $sym.IconBackup
        health = $sym.IconHealth
    }
    $groupColor = @{
        shell  = $c.Magenta
        launch = $c.Green
        update = $c.Cyan
        backup = $c.Yellow
        health = $c.Blue
    }

    # Single-pane caption: the selected description wraps instead of being cut off.
    $captionLines = [System.Collections.Generic.List[string]]::new()
    if (-not $isTwoPane -and $null -ne $selectedItem) {
        $capW = [Math]::Max(10, ($innerW - 3))
        foreach ($dLine in (Get-TuiWrappedText -Text ([string]$selectedItem.Desc) -MaxWidth $capW)) {
            $captionLines.Add($dLine)
        }
        $maxCap = [Math]::Max(1, ($Height - 14))
        if ($captionLines.Count -gt $maxCap) {
            $kept = @($captionLines | Select-Object -First ($maxCap - 1))
            $captionLines.Clear()
            foreach ($k in $kept) { $captionLines.Add($k) }
            $captionLines.Add($sym.Ellipsis)
        }
        if ($captionLines.Count -eq 0) { $captionLines.Add('') }
    }

    # --- Body height ---
    # Fixed chrome: top border, header, divider, 2 status rows, divider, footer,
    # bottom border = 8. The divider above the footer plus the optional search/notice/
    # caption rows complete the budget.
    $optionalRows = 0
    if ($State.SearchActive -or $State.StatusMessage) {
        $optionalRows = 1
    } elseif ($captionLines.Count -gt 0) {
        $optionalRows = $captionLines.Count
    }
    $bodyHeight = [Math]::Max(5, ($Height - 9 - $optionalRows))

    # Scrolling: two rows are reserved for the up/down indicators when the list overflows,
    # so an indicator never hides an item. Selection drives the viewport.
    $showIndicators = ($bodyHeight -ge 6)
    $listRows = if ($showIndicators) { $bodyHeight - 2 } else { $bodyHeight }
    $scrollOffset = 0
    if ($null -ne $selectedItem -and $listLines.Count -gt 0) {
        $vStart = -1
        $vEnd = -1
        for ($k = 0; $k -lt $listLines.Count; $k++) {
            $ln = $listLines[$k]
            if ($ln.Kind -eq 'item' -and $ln.Item.Id -eq $selectedItem.Id) {
                if ($vStart -lt 0) { $vStart = $k }
                $vEnd = $k
            }
        }
        if ($vStart -ge 0) {
            $maxScroll = [Math]::Max(0, ($listLines.Count - $listRows))
            $scrollOffset = [Math]::Min([Math]::Max(0, ($vEnd - $listRows + 1)), $maxScroll)
            if ($scrollOffset -gt $vStart) { $scrollOffset = [Math]::Max(0, $vStart) }
        }
    }

    # Scrollbar (Terminal.Gui convention): a track with a proportional thumb, so the
    # user always sees position and remaining content.
    $hasScrollBar = ($listLines.Count -gt $listRows)
    $thumbH = 1
    $thumbTop = 0
    if ($hasScrollBar) {
        $thumbH = [Math]::Max(1, [int][Math]::Floor(($listRows * $listRows) / $listLines.Count))
        $thumbH = [Math]::Min($thumbH, $listRows)
        $denom = [Math]::Max(1, ($listLines.Count - $listRows))
        $thumbTop = [int][Math]::Floor(($scrollOffset * ($listRows - $thumbH)) / $denom)
    }
    $hasMoreAbove = ($scrollOffset -gt 0)
    $hasMoreBelow = ($scrollOffset + $listRows -lt $listLines.Count)

    # Prepare right-pane detail lines if 2-pane
    $rightPaneLines = [System.Collections.Generic.List[string]]::new()
    if ($isTwoPane -and $selectedItem) {
        $it = $selectedItem
        foreach ($tLine in (Get-TuiWrappedText -Text ([string]$it.Title) -MaxWidth ($rightW - 4))) {
            $rightPaneLines.Add($c.Bold + $c.BrightWhite + $tLine + $c.Reset)
        }
        $rightPaneLines.Add("")

        # Description wrapped
        foreach ($dLine in (Get-TuiWrappedText -Text $it.Desc -MaxWidth ($rightW - 4))) {
            $rightPaneLines.Add($c.Dim + $dLine + $c.Reset)
        }
        $rightPaneLines.Add("")

        # Metadata badges (labels and values from i18n)
        $adminLabel = $T['tui_meta_admin']
        $adminVal   = if ($it.NeedAdmin) { $c.Yellow + $T['tui_meta_admin_yes'] + $c.Reset } else { $c.Dim + $T['tui_meta_admin_no'] + $c.Reset }
        $rightPaneLines.Add("  " + (Get-TuiPaddedText -Text $adminLabel -TargetWidth 18 -Truncate -Ellipsis $sym.Ellipsis) + $adminVal)

        $undoLabel  = $T['tui_meta_undo']
        $undoVal    = if ($it.Undoable) { $c.Green + $it.UndoHint + $c.Reset } else { $c.Dim + $T['tui_meta_undo_no'] + $c.Reset }
        $rightPaneLines.Add("  " + (Get-TuiPaddedText -Text $undoLabel -TargetWidth 18 -Truncate -Ellipsis $sym.Ellipsis) + $undoVal)

        if ($it.Destructive) {
            $destLabel = $T['tui_meta_type']
            $rightPaneLines.Add("  " + (Get-TuiPaddedText -Text $destLabel -TargetWidth 18 -Truncate -Ellipsis $sym.Ellipsis) + $c.BrightRed + $c.Bold + $T['tui_meta_destructive'] + $c.Reset)
        }

        $rightPaneLines.Add("")
        $actionHint = if ($it.Destructive) {
            $T['tui_hint_confirm']
        } elseif ($it.Undoable) {
            $T['tui_hint_preview']
        } else {
            $T['tui_hint_run']
        }
        $rightPaneLines.Add($c.Cyan + $actionHint + $c.Reset)
    }

    # Render body rows
    $moreLabel = $T['tui_more']
    $topIndicatorText = $c.Yellow + "  " + $sym.ArrowUp + " " + $moreLabel + $c.Reset
    $bottomIndicatorText = $c.Yellow + "  " + $sym.ArrowDown + " " + $moreLabel + $c.Reset

    for ($r = 0; $r -lt $bodyHeight; $r++) {
        $leftStr = ""
        $isTopIndicatorRow = ($showIndicators -and $r -eq 0)
        $isBottomIndicatorRow = ($showIndicators -and $r -eq ($bodyHeight - 1))

        if ($noMatches -and $r -eq 0) {
            $leftStr = "  " + $c.Yellow + $T['tui_search_empty'] + $c.Reset
        } elseif ($isTopIndicatorRow) {
            if ($hasMoreAbove) { $leftStr = $topIndicatorText }
        } elseif ($isBottomIndicatorRow) {
            if ($hasMoreBelow) { $leftStr = $bottomIndicatorText }
        } else {
            $listRow = if ($showIndicators) { $r - 1 } else { $r }
            $lineIdx = $scrollOffset + $listRow
            if ($lineIdx -ge 0 -and $lineIdx -lt $listLines.Count) {
                $lineObj = $listLines[$lineIdx]
                $gid = [string]$lineObj.GroupId
                $gc = if ($groupColor.ContainsKey($gid)) { $groupColor[$gid] } else { $c.BrightCyan }
                if ($lineObj.Kind -eq 'header') {
                    # Group header: non-selectable, sentence case (never ALL CAPS)
                    $gi = if ($groupIcon.ContainsKey($gid)) { $groupIcon[$gid] } else { "" }
                    $leftStr = " " + $gc + $c.Bold + $gi + " " + $lineObj.Text + $c.Reset
                } else {
                    $it = $lineObj.Item
                    $isSelected = ($null -ne $selectedItem -and $it.Id -eq $selectedItem.Id)
                    $classIcon = if ($it.Destructive) { $sym.Warning } elseif ($it.Undoable) { $sym.Undo } else { "" }
                    $iconColor = if ($it.Destructive) { $c.BrightRed } elseif ($it.Undoable) { $c.Yellow } else { $gc }
                    $badge = "[" + $it.Key + "]"
                    if ($isSelected) {
                        # Active row: a full-width inverse-video bar is the accent. Inverting
                        # the terminal's own colours keeps contrast on every theme, and one
                        # colour run avoids inner resets cutting the bar short.
                        $ptrChar = if ($lineObj.First) { $sym.Pointer + " " } else { "  " }
                        $iconChar = if ($classIcon) { $classIcon + " " } else { "  " }
                        if ($lineObj.First) {
                            $gap = [Math]::Max(1, ($titleAvailW - (Get-TuiStringWidth $lineObj.Text)))
                            $plain = $ptrChar + $iconChar + $lineObj.Text + (" " * $gap) + $badge
                        } else {
                            $plain = "    " + $lineObj.Text
                        }
                        $barPad = [Math]::Max(0, ($paneW - (Get-TuiStringWidth $plain)))
                        $leftStr = $c.Invert + $c.Bold + $plain + (" " * $barPad) + $c.Reset
                    } else {
                        $tColor = if ($it.Destructive) { $c.BrightRed } else { "" }
                        $ptr = "  "
                        $iconCell = if ($classIcon) { $iconColor + $classIcon + " " + $c.Reset } else { "  " }
                        if ($lineObj.First) {
                            $bColor = if ($it.Destructive) { $c.BrightRed } else { $c.Dim }
                            $gap = [Math]::Max(1, ($titleAvailW - (Get-TuiStringWidth $lineObj.Text)))
                            $leftStr = $ptr + $iconCell + $tColor + $lineObj.Text + $c.Reset + (" " * $gap) + $bColor + $badge + $c.Reset
                        } else {
                            $leftStr = "    " + $tColor + $lineObj.Text + $c.Reset
                        }
                    }
                }
            }
        }

        $leftPad = [Math]::Max(0, ($paneW - (Get-TuiStringWidth $leftStr)))
        $barIdx = if ($showIndicators) { [Math]::Min([Math]::Max(0, ($r - 1)), ($listRows - 1)) } else { $r }
        $barChar = " "
        if ($hasScrollBar) {
            $barChar = if ($barIdx -ge $thumbTop -and $barIdx -lt ($thumbTop + $thumbH)) { $sym.ScrollThumb } else { $sym.ScrollTrack }
        }
        $leftCell = $leftStr + (" " * $leftPad) + $c.Dim + $barChar + $c.Reset

        if ($isTwoPane) {
            $rightCell = ""
            if ($r -lt $rightPaneLines.Count) {
                $rLine = $rightPaneLines[$r]
                $rPad = [Math]::Max(0, ($rightW - (Get-TuiStringWidth $rLine)))
                $rightCell = "  " + $rLine + (" " * [Math]::Max(0, ($rPad - 2)))
            } else {
                $rightCell = " " * $rightW
            }
            $fullRow = $c.Cyan + $sym.VLine + $c.Reset + $leftCell + $c.Cyan + $sym.VLine + $c.Reset + $rightCell + $c.Cyan + $sym.VLine + $c.Reset
            $frame.Add($fullRow)
        } else {
            $fullRow = $c.Cyan + $sym.VLine + $c.Reset + $leftCell + $c.Cyan + $sym.VLine + $c.Reset
            $frame.Add($fullRow)
        }
    }

    $frame.Add($divBorder)

    # --- Search bar, status notice, or single-pane caption (never wider than the frame) ---
    $lineBudget = $innerW - 1
    if ($State.SearchActive) {
        $sPrompt = " " + $T['tui_search_prompt']
        $sBody = (Get-TuiPaddedText -Text ($sPrompt + $State.SearchQuery + "_") -TargetWidth $lineBudget -Truncate -Ellipsis $sym.Ellipsis)
        $frame.Add($c.Cyan + $sym.VLine + $c.Reset + $c.Yellow + $c.Bold + $sBody + $c.Reset + " " + $c.Cyan + $sym.VLine + $c.Reset)
    } elseif ($State.StatusMessage) {
        $nBody = Get-TuiPaddedText -Text ("  " + $State.StatusMessage) -TargetWidth $lineBudget -Truncate -Ellipsis $sym.Ellipsis
        $frame.Add($c.Cyan + $sym.VLine + $c.Reset + $c.Yellow + $nBody + $c.Reset + " " + $c.Cyan + $sym.VLine + $c.Reset)
    } elseif (-not $isTwoPane -and $selectedItem) {
        # One row per wrapped description line, matching the reserved caption budget.
        foreach ($capLine in $captionLines) {
            $cBody = Get-TuiPaddedText -Text ("  " + $capLine) -TargetWidth $lineBudget -Truncate -Ellipsis $sym.Ellipsis
            $frame.Add($c.Cyan + $sym.VLine + $c.Reset + $c.Dim + $cBody + $c.Reset + " " + $c.Cyan + $sym.VLine + $c.Reset)
        }
    }

    # --- Footer: pick the longest key legend that fits the current width ---
    $footerCandidates = @(
        $T['tui_footer_full'],
        $T['tui_footer_medium'],
        $T['tui_footer_min']
    )
    $navFooter = $footerCandidates[$footerCandidates.Count - 1]
    foreach ($cand in $footerCandidates) {
        if ((Get-TuiStringWidth $cand) -le $lineBudget) { $navFooter = $cand; break }
    }
    $navFooter = Get-TuiPaddedText -Text $navFooter -TargetWidth $lineBudget -Truncate -Ellipsis $sym.Ellipsis
    $footerLine = $c.Cyan + $sym.VLine + $c.Reset + $c.Dim + $navFooter + $c.Reset + " " + $c.Cyan + $sym.VLine + $c.Reset
    $frame.Add($footerLine)

    # --- Bottom Border ---
    $bottomBorder = $c.Cyan + $sym.BottomLeft + ($sym.HLine * $innerW) + $sym.BottomRight + $c.Reset
    $frame.Add($bottomBorder)

    # Normalise to an exact Width x Height canvas so a frame can never wrap or scroll.
    for ($fi = 0; $fi -lt $frame.Count; $fi++) {
        $fw = Get-TuiStringWidth $frame[$fi]
        if ($fw -lt $Width) { $frame[$fi] = $frame[$fi] + (" " * ($Width - $fw)) }
    }
    while ($frame.Count -lt $Height) { $frame.Add((" " * $Width)) }
    if ($frame.Count -gt $Height) { $frame.RemoveRange($Height, $frame.Count - $Height) }

    return $frame.ToArray()
}

function Get-TuiFrameDiff {
    <#
    .SYNOPSIS
        Computes minimal line diff between consecutive frames for flicker-free rendering.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][string[]]$Previous,
        [Parameter(Mandatory = $true)][string[]]$Current
    )

    $diffs = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Current.Count; $i++) {
        $newLine = $Current[$i]
        $oldLine = if ($Previous -and $i -lt $Previous.Count) { $Previous[$i] } else { $null }
        if ($oldLine -ne $newLine) {
            $diffs.Add([pscustomobject]@{
                Row  = $i
                Text = $newLine
            })
        }
    }
    return $diffs.ToArray()
}

function Write-TuiFrame {
    <#
    .SYNOPSIS
        Outputs the rendered frame to console using differential cursor positioning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Frame,
        [Parameter()][string[]]$PreviousFrame,
        # Indirection so tests can capture the terminal byte stream.
        [scriptblock]$Writer = $null
    )

    $diffs = @(Get-TuiFrameDiff -Previous $PreviousFrame -Current $Frame)
    if ($diffs.Count -eq 0) { return }

    $esc = [char]27
    $sb = [System.Text.StringBuilder]::new()

    # Every row is positioned explicitly and terminated with erase-to-end-of-line.
    # A frame is exactly as wide as the terminal, so relying on newlines would make
    # the pending wrap advance an extra row and smear the previous frame down the
    # screen (duplicated menu rows, stale detail lines).
    if ($null -eq $PreviousFrame -or $PreviousFrame.Count -eq 0) {
        for ($i = 0; $i -lt $Frame.Count; $i++) {
            $row1Based = $i + 1
            $null = $sb.Append("$esc[${row1Based};1H").Append($Frame[$i]).Append("$esc[K")
        }
    } else {
        foreach ($d in $diffs) {
            $row1Based = $d.Row + 1
            $null = $sb.Append("$esc[${row1Based};1H").Append($d.Text).Append("$esc[K")
        }
    }
    $chunk = $sb.ToString()
    if ($Writer) { & $Writer $chunk } else { [Console]::Write($chunk) }
}

function New-TuiModalFrame {
    <#
    .SYNOPSIS
        Builds a full-screen modal (help / preview / confirm / result) at an exact size.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][hashtable]$Caps,
        [Parameter(Mandatory = $true)][hashtable]$Text
    )

    $sym = $Caps.Symbols
    $c = $Caps.Colors
    $innerW = $Width - 2
    $textW = [Math]::Max(10, $innerW - 4)
    $title = ""
    $titleColor = $c.Bold + $c.BrightCyan
    $footer = ""
    $body = [System.Collections.Generic.List[string]]::new()

    $item = $State.PreviewItem
    $itemTitle = if ($null -ne $item) { [string]$item.Title } else { "" }

    switch ($State.Mode) {
        'Help' {
            $title = $Text['tui_help_title']
            $footer = $Text['tui_help_close']
            foreach ($gLine in (Get-TuiWrappedText -Text ([string]$Text['tui_help_global']) -MaxWidth $textW)) {
                $body.Add("  " + $c.Cyan + $gLine + $c.Reset)
            }
            $body.Add("")
            $items = @($State.Catalog)
            $half = [int][Math]::Ceiling($items.Count / 2)
            $colW = [int](($innerW - 4) / 2)
            for ($i = 0; $i -lt $half; $i++) {
                $left = "  [" + $items[$i].Key + "] " + $items[$i].Title
                $left = Get-TuiPaddedText -Text $left -TargetWidth $colW -Truncate -Ellipsis $sym.Ellipsis
                $rightIdx = $i + $half
                if ($rightIdx -lt $items.Count) {
                    $right = "[" + $items[$rightIdx].Key + "] " + $items[$rightIdx].Title
                    $right = Get-TuiPaddedText -Text $right -TargetWidth $colW -Truncate -Ellipsis $sym.Ellipsis
                    $body.Add($left + "  " + $right)
                } else {
                    $body.Add($left)
                }
            }
        }
        'Preview' {
            $title = $Text['tui_preview_title']
            $footer = $Text['tui_preview_apply'] + "     " + $Text['tui_preview_cancel']
            $body.Add("  " + $c.Bold + $c.White + $itemTitle + $c.Reset)
            $body.Add("")
            foreach ($line in (Get-TuiWrappedText -Text ([string]$item.Desc) -MaxWidth $textW)) {
                $body.Add("  " + $c.Dim + $line + $c.Reset)
            }
            $body.Add("")
            $adminVal = if ($item.NeedAdmin) { $c.Yellow + $Text['tui_meta_admin_yes'] } else { $c.Dim + $Text['tui_meta_admin_no'] }
            $body.Add("  " + (Get-TuiPaddedText -Text $Text['tui_meta_admin'] -TargetWidth 20 -Truncate -Ellipsis $sym.Ellipsis) + $adminVal + $c.Reset)
            if ($item.Undoable) {
                $body.Add("  " + (Get-TuiPaddedText -Text $Text['tui_meta_undo'] -TargetWidth 20 -Truncate -Ellipsis $sym.Ellipsis) + $c.Green + [string]$item.UndoHint + $c.Reset)
            } else {
                $body.Add("  " + (Get-TuiPaddedText -Text $Text['tui_meta_undo'] -TargetWidth 20 -Truncate -Ellipsis $sym.Ellipsis) + $c.Dim + $Text['tui_meta_undo_no'] + $c.Reset)
            }
        }
        'Confirm' {
            $title = $Text['tui_confirm_title']
            $titleColor = $c.Bold + $c.BrightRed
            $footer = $Text['tui_preview_cancel']
            $wrapped = Get-TuiWrappedText -Text ($Text['tui_confirm_body'] -f $itemTitle) -MaxWidth $textW
            foreach ($line in $wrapped) { $body.Add("  " + $c.BrightRed + $c.Bold + $line + $c.Reset) }
            $body.Add("")
            foreach ($line in (Get-TuiWrappedText -Text ([string]$item.Desc) -MaxWidth $textW)) {
                $body.Add("  " + $c.Dim + $line + $c.Reset)
            }
            $body.Add("")
            $body.Add("  " + $c.Yellow + $Text['tui_confirm_type'] + $c.Reset)
            if ($State.ConfirmBuffer -eq 'y') {
                $body.Add("  " + $c.Green + "[y] " + $c.Reset)
            }
        }
        'Result' {
            $title = $Text['tui_result_title']
            $footer = $Text['tui_result_close']
            $res = $State.Result
            $ok = $true
            if ($null -ne $res -and $res.ContainsKey('Ok')) { $ok = [bool]$res['Ok'] }
            $statusText = if ($ok) { $Text['tui_result_ok'] } else { $Text['tui_result_fail'] }
            $statusColor = if ($ok) { $c.Green } else { $c.Red }
            $body.Add("  " + $statusColor + $c.Bold + $sym.Check + " " + $statusText + $c.Reset)
            $body.Add("")
            $body.Add("  " + $c.White + $itemTitle + $c.Reset)
            if ($null -ne $res -and $res.ContainsKey('Duration')) {
                $body.Add("  " + $c.Dim + ($Text['tui_result_time'] -f [double]$res['Duration']) + $c.Reset)
            }
            if ($null -ne $res -and $res.ContainsKey('Details')) {
                foreach ($detailLine in @($res['Details'])) {
                    if (-not $detailLine) { continue }
                    $body.Add("  " + $c.Dim + [string]$detailLine + $c.Reset)
                }
            }
            if ($null -ne $res -and $res.ContainsKey('Errors')) {
                foreach ($errLine in @($res['Errors'])) {
                    if (-not $errLine) { continue }
                    $body.Add("  " + $c.Red + "- " + [string]$errLine + $c.Reset)
                }
            }
        }
        'Notifications' {
            $title = $Text['tui_notif_title']
            $footer = $Text['tui_notif_close']
            $notes = @()
            if ($State.ContainsKey('Notifications') -and $null -ne $State.Notifications) { $notes = @($State.Notifications) }
            if ($notes.Count -eq 0) {
                $body.Add("  " + $c.Dim + $Text['tui_notif_empty'] + $c.Reset)
            } else {
                $selected = 0
                if ($State.ContainsKey('NotificationIndex') -and $null -ne $State.NotificationIndex) {
                    $selected = [int]$State.NotificationIndex
                }
                $selected = [Math]::Max(0, [Math]::Min($selected, ($notes.Count - 1)))
                $availRows = [Math]::Max(1, $Height - 6)
                $startIdx = 0
                if ($notes.Count -gt $availRows) {
                    $startIdx = [Math]::Max(0, [Math]::Min($selected - [int]($availRows / 2), $notes.Count - $availRows))
                }
                $endIdx = [Math]::Min($notes.Count - 1, $startIdx + $availRows - 1)
                for ($ni = $startIdx; $ni -le $endIdx; $ni++) {
                    $note = $notes[$ni]
                    $mark = if ($note.Read) { ' ' } else { 'x' }
                    $rowText = '[' + $mark + '] ' + [string]$note.Time + '  ' + [string]$note.Title + ' - ' + [string]$note.Message
                    $prefix = if ($ni -eq $selected) { '> ' } else { '  ' }
                    $padded = Get-TuiPaddedText -Text ('  ' + $prefix + $rowText) -TargetWidth $textW -Truncate -Ellipsis $sym.Ellipsis
                    if ($ni -eq $selected) {
                        $body.Add($c.Cyan + $c.Bold + $padded + $c.Reset)
                    } else {
                        $body.Add($c.Dim + $padded + $c.Reset)
                    }
                }
            }
        }
    }

    # --- Compose the box ---
    $rows = [System.Collections.Generic.List[string]]::new()
    $top = $c.Cyan + $sym.TopLeft + ($sym.HLine * $innerW) + $sym.TopRight + $c.Reset
    $div = $c.Cyan + $sym.TRight + ($sym.HLine * $innerW) + $sym.TLeft + $c.Reset
    $bottom = $c.Cyan + $sym.BottomLeft + ($sym.HLine * $innerW) + $sym.BottomRight + $c.Reset
    $rows.Add($top)
    $rows.Add($c.Cyan + $sym.VLine + $c.Reset + (Get-TuiPaddedText -Text (" " + $titleColor + $title + $c.Reset) -TargetWidth $innerW -Truncate -Ellipsis $sym.Ellipsis) + $c.Cyan + $sym.VLine + $c.Reset)
    $rows.Add($div)

    $bodyRows = [Math]::Max(1, $Height - 6)
    for ($i = 0; $i -lt $bodyRows; $i++) {
        $line = if ($i -lt $body.Count) { $body[$i] } else { "" }
        $rows.Add($c.Cyan + $sym.VLine + $c.Reset + (Get-TuiPaddedText -Text $line -TargetWidth $innerW -Truncate -Ellipsis $sym.Ellipsis) + $c.Cyan + $sym.VLine + $c.Reset)
    }

    $rows.Add($div)
    $rows.Add($c.Cyan + $sym.VLine + $c.Reset + (Get-TuiPaddedText -Text (" " + $c.Dim + $footer + $c.Reset) -TargetWidth $innerW -Truncate -Ellipsis $sym.Ellipsis) + $c.Cyan + $sym.VLine + $c.Reset)
    $rows.Add($bottom)

    for ($fi = 0; $fi -lt $rows.Count; $fi++) {
        $fw = Get-TuiStringWidth $rows[$fi]
        if ($fw -lt $Width) { $rows[$fi] = $rows[$fi] + (" " * ($Width - $fw)) }
    }
    while ($rows.Count -lt $Height) { $rows.Add((" " * $Width)) }
    if ($rows.Count -gt $Height) { $rows.RemoveRange($Height, $rows.Count - $Height) }
    return $rows.ToArray()
}
