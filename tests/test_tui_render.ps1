#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Contract Tests - TUI Pure Rendering Engine & Capabilities
.DESCRIPTION
    Validates:
      1. TuiCapabilities detection, Unicode vs ASCII fallback symbols, 16-color ANSI palettes.
      2. TuiCatalog group structure (5 groups), mnemonic key uniqueness, legacy alias mappings.
      3. Diacritic-insensitive search key normalization (FormD).
      4. Responsive layout thresholds (<80x24 notice, 80x24 single-pane, >=110 2-pane).
      5. Frame dimension invariants across four resolutions, languages and symbol modes.
      6. Minimal frame diffing for flicker-free rendering.
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

Import-Module (Join-Path $RootDir "PSManager.psd1") -Force

. (Join-Path $RootDir "modules/UI/TuiCapabilities.ps1")
. (Join-Path $RootDir "modules/UI/TuiCatalog.ps1")
 . (Join-Path $RootDir "modules/UI/TuiRender.ps1")
 . (Join-Path $RootDir "modules/UI/TuiState.ps1")

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Check {
    param([string]$Name, [scriptblock]$TestBlock)
    try {
        & $TestBlock
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $Name - $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add("$Name :: $($_.Exception.Message)")
    }
}

# Mock state generator
function New-MockTuiState {
    param(
        [string]$Language = "vi",
        [int]$SelectedIndex = 0,
        [string]$SearchQuery = "",
        [switch]$SearchActive,
        [string]$StatusMessage = ""
    )

    $groups  = Get-TuiGroups -Language $Language
    $catalog = Get-TuiCatalog -Language $Language

    return @{
        Version       = "1.4.0"
        Language      = $Language
        Groups        = $groups
        Catalog       = $catalog
        SelectedIndex = $SelectedIndex
        ScrollOffset  = 0
        SearchQuery   = $SearchQuery
        SearchActive  = [bool]$SearchActive
        StatusMessage = $StatusMessage
        Status        = [pscustomobject]@{
            WTDefaultIsPS7    = $true
            WTDefaultIsPS5    = $false
            IsWTDefaultHost   = $true
            ShimActive        = $true
            CurrentHostVersion= "7.4.5"
            CurrentHostEdition= "Core"
            Installations     = @{ PS7 = @{ Version = "7.4.5" } }
        }
        Config        = [pscustomobject]@{
            updateSource = "winget"
            channel      = "stable"
            language     = $Language
        }
    }
}

# ----------------------------------------------------------------------------
# 1. Capabilities Unit Tests
# ----------------------------------------------------------------------------
Assert-Check -Name "Get-TuiCapabilities returns complete contract" -TestBlock {
    $caps = Get-TuiCapabilities
    foreach ($key in @('IsTty', 'PlainMode', 'HasUnicode', 'HasColor', 'HasVt', 'Width', 'Height', 'Symbols', 'Colors')) {
        if (-not $caps.ContainsKey($key)) { throw "Missing capability '$key'" }
    }
    if ($caps.HasVt -isnot [bool]) { throw 'HasVt must be a boolean' }
    if ($caps.Symbols.HLine.Length -eq 0) { throw "Empty HLine symbol" }
}

Assert-Check -Name "VT capability can be forced off for legacy conhost fallback" -TestBlock {
    $caps = Get-TuiCapabilities -Override @{ IsTty = $true; PlainMode = $false; HasVt = $false }
    if ($caps.HasVt) { throw 'HasVt override ignored' }
}

Assert-Check -Name "Get-TuiCapabilities accepts overrides for headless simulation" -TestBlock {
    $caps = Get-TuiCapabilities -Override @{ HasUnicode = $false; HasColor = $false; Width = 80; Height = 24 }
    if ($caps.HasUnicode) { throw "HasUnicode override ignored" }
    if ($caps.HasColor) { throw "HasColor override ignored" }
    if ($caps.Width -ne 80 -or $caps.Height -ne 24) { throw "Dimension override ignored" }
    if ($caps.Symbols.HLine -ne "-") { throw "Expected ASCII HLine '-' when HasUnicode is false" }
    if ($caps.Colors.Cyan -ne "") { throw "Expected empty ANSI color when HasColor is false" }
}

# ----------------------------------------------------------------------------
# 2. Search Key Normalization Tests
# ----------------------------------------------------------------------------
Assert-Check -Name "ConvertTo-TuiSearchKey strips Vietnamese diacritics and d-bar" -TestBlock {
    $testCases = @{
        "Cấu hình shell mặc định" = "cau hinh shell mac dinh"
        "Đồng bộ & công cụ"       = "dong bo & cong cu"
        "Mở PS7"                 = "mo ps7"
        "Xóa Backup Trên Máy"     = "xoa backup tren may"
        "Khôi phục PS5"          = "khoi phuc ps5"
        "SAO LƯU"                = "sao luu"
    }

    foreach ($orig in $testCases.Keys) {
        $expected = $testCases[$orig]
        $actual = ConvertTo-TuiSearchKey $orig
        if ($actual -ne $expected) {
            throw "Normalization failed for '$orig': expected '$expected', got '$actual'"
        }
    }
}

# ----------------------------------------------------------------------------
# 3. Action Catalog & Keyboard Mapping Tests
# ----------------------------------------------------------------------------
Assert-Check -Name "Get-TuiCatalog provides 5 groups matching Desktop GUI IA" -TestBlock {
    $groups = Get-TuiGroups
    if ($groups.Count -ne 5) { throw "Expected 5 groups, got $($groups.Count)" }
    $expectedGroups = @('shell', 'launch', 'update', 'backup', 'health')
    foreach ($eg in $expectedGroups) {
        if (-not ($groups | Where-Object { $_.Id -eq $eg })) {
            throw "Missing group '$eg'"
        }
    }
}

Assert-Check -Name "All primary mnemonic keys in TuiCatalog are unique and lowercase" -TestBlock {
    $catalog = Get-TuiCatalog
    $keys = @($catalog | ForEach-Object { $_.Key })
    $unique = @($keys | Sort-Object -Unique)
    if ($keys.Count -ne $unique.Count) {
        throw "Duplicate mnemonic keys detected in catalog: $($keys -join ', ')"
    }
    # List actions must not reuse the global hotkeys (g/l/q/?//); the two documented
    # global entries (gui, lang) are the exception.
    $reserved = @('g', 'l', 'q', '?', '/')
    foreach ($item in @($catalog | Where-Object { $_.GroupId -ne 'global' })) {
        if ($item.Key -in $reserved) {
            throw "Catalog action '$($item.Id)' uses reserved global hotkey '$($item.Key)'"
        }
    }
}

Assert-Check -Name "Find-TuiActionByKey dispatches mnemonic keys and legacy aliases" -TestBlock {
    $catalog = Get-TuiCatalog

    # Mnemonic 'd' -> def7 (not legacy)
    $m1 = Find-TuiActionByKey -InputKey 'd' -Catalog $catalog
    if ($null -eq $m1 -or $m1.Item.Id -ne 'def7' -or $m1.IsLegacy) {
        throw "Failed to resolve mnemonic key 'd' to def7"
    }

    # Legacy '1' -> def7 (is legacy, points to 'd')
    $l1 = Find-TuiActionByKey -InputKey '1' -Catalog $catalog
    if ($null -eq $l1 -or $l1.Item.Id -ne 'def7' -or -not $l1.IsLegacy -or $l1.PrimaryKey -ne 'd') {
        throw "Failed to resolve legacy key '1' to def7"
    }

    # Legacy 'X' -> clean-backups (destructive)
    $lx = Find-TuiActionByKey -InputKey 'X' -Catalog $catalog
    if ($null -eq $lx -or $lx.Item.Id -ne 'clean-backups' -or -not $lx.IsLegacy) {
        throw "Failed to resolve legacy key 'X' to clean-backups"
    }
}

# ----------------------------------------------------------------------------
# 4. Pure Frame Builder Resolution & Layout Tests
# ----------------------------------------------------------------------------
Assert-Check -Name "New-TuiFrame produces 'too small' notice when dimensions < 80x24" -TestBlock {
    $state = New-MockTuiState
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false }
    
    $frame70x20 = New-TuiFrame -State $state -Width 70 -Height 20 -Caps $caps
    if ($frame70x20.Count -ne 20) { throw "Expected 20 lines, got $($frame70x20.Count)" }
    $text = $frame70x20 -join "`n"
    if ($text -notmatch "80x24") { throw "Missing resolution warning in frame output" }
}

Assert-Check -Name "New-TuiFrame at 80x24 renders exactly 24 lines in single-pane mode" -TestBlock {
    $state = New-MockTuiState
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $false; Width = 80; Height = 24 }
    
    $frame = New-TuiFrame -State $state -Width 80 -Height 24 -Caps $caps
    if ($frame.Count -ne 24) { throw "Expected exactly 24 lines, got $($frame.Count)" }
    foreach ($line in $frame) {
        $w = Get-TuiStringWidth $line
        if ($w -gt 80) { throw "Line width overflow ($w > 80): $line" }
    }
}

Assert-Check -Name "New-TuiFrame at 110x30 renders 2-pane layout with detail pane" -TestBlock {
    $state = New-MockTuiState
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $true; Width = 110; Height = 30 }
    
    $frame = New-TuiFrame -State $state -Width 110 -Height 30 -Caps $caps
    if ($frame.Count -ne 30) { throw "Expected exactly 30 lines, got $($frame.Count)" }
    
    # Verify presence of right detail pane splitter
    $hasSplitter = $false
    foreach ($l in $frame) {
        if ($l -match '│.*│.*│') { $hasSplitter = $true; break }
    }
    if (-not $hasSplitter) { throw "Expected 2-pane vertical splitter '│' in 110x30 frame" }
}

Assert-Check -Name "Long action titles wrap instead of truncating" -TestBlock {
    # Two-pane at 110 columns leaves a 38-column title column, so the longest
    # catalog title must wrap. Single-pane at 80 is wide enough not to wrap.
    $state = New-MockTuiState -Language 'en'
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $false }
    $frame = New-TuiFrame -State $state -Width 110 -Height 60 -Caps $caps

    # Drop the key badge and the scrollbar column so a wrapped title is contiguous.
    $leftCells = @(foreach ($line in $frame) {
        $parts = $line.Split('|')
        if ($parts.Count -ge 4) {
            $cell = [string]$parts[1]
            if ($cell.Length -gt 0) { $cell = $cell.Substring(0, $cell.Length - 1) }
            $cell -replace '\[[0-9A-Za-z]\]', ' '
        }
    })

    $haystack = (($leftCells -join ' ') -replace '\s+', ' ').Trim()

    $wrappedTitles = 0
    foreach ($item in (Get-TuiVisibleItems -State $state)) {
        $title = ([string]$item.Title -replace '\s+', ' ').Trim()
        if (-not $haystack.Contains($title)) {
            throw "The action list hides part of '$title'"
        }
        if (@(Get-TuiWrappedText -Text ([string]$item.Title) -MaxWidth 38).Count -gt 1) {
            $wrappedTitles++
        }
    }
    if ($wrappedTitles -eq 0) { throw 'The fixture does not exercise wrapping at 110 columns' }

    $badgedCells = @($leftCells | Where-Object { $_ -match '\[[0-9A-Za-z]\]' })
    if (@($badgedCells | Where-Object { $_.Contains('...') }).Count -gt 0) {
        throw 'The action list still truncates titles with an ellipsis'
    }
}

Assert-Check -Name "A wrapped title continues in the next row with one key badge" -TestBlock {
    $state = New-MockTuiState -Language 'en'
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $false }
    $frame = New-TuiFrame -State $state -Width 110 -Height 60 -Caps $caps
    $leftCells = @(foreach ($line in $frame) {
        $parts = $line.Split('|')
        if ($parts.Count -ge 4) { $parts[1] }
    })

    $long = (Get-TuiVisibleItems -State $state) |
        Sort-Object { ([string]$_.Title).Length } -Descending |
        Select-Object -First 1
    $segments = @(Get-TuiWrappedText -Text ([string]$long.Title) -MaxWidth 38)
    if ($segments.Count -lt 2) { throw "Expected the longest title to wrap, got $($segments.Count) segment(s)" }

    $firstIdx = -1
    for ($i = 0; $i -lt $leftCells.Count; $i++) {
        if ($leftCells[$i].Contains($segments[0]) -and $leftCells[$i] -match '\[[0-9A-Za-z]\]') { $firstIdx = $i; break }
    }
    if ($firstIdx -lt 0) { throw "First segment of '$($long.Title)' was not rendered with its key badge" }
    if (-not $leftCells[$firstIdx + 1].Contains($segments[1])) {
        throw "Second segment of '$($long.Title)' is not on the following row"
    }

    $badges = @($leftCells | Where-Object { $_ -match '\[[0-9A-Za-z]\]' })
    $selectable = @(Get-TuiVisibleItems -State $state).Count
    if ($badges.Count -ne $selectable) {
        throw "Expected one key badge per action ($selectable), found $($badges.Count)"
    }
}

Assert-Check -Name "Group headers and action classes carry colour and icons" -TestBlock {
    $state = New-MockTuiState -Language 'vi'
    $caps = Get-TuiCapabilities -Override @{ HasColor = $true; HasUnicode = $true; Width = 120; Height = 40 }
    $frame = New-TuiFrame -State $state -Width 120 -Height 40 -Caps $caps
    $text = $frame -join "`n"

    if (-not $text.Contains([char]27 + '[')) { throw 'No ANSI colour was emitted with HasColor' }
    foreach ($icon in @($caps.Symbols.IconShell, $caps.Symbols.IconLaunch, $caps.Symbols.IconUpdate)) {
        if (-not $text.Contains($icon)) { throw "Group icon '$icon' is missing from the frame" }
    }
    if (-not $text.Contains($caps.Symbols.Undo)) { throw 'Undoable actions are missing their icon' }
    if (-not $text.Contains($caps.Symbols.Pointer)) { throw 'The selection pointer is missing' }
}

Assert-Check -Name "Header names the active language mode" -TestBlock {
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $false }
    $expected = @{
        'en'       = (Get-I18nText 'tui_lang_en' 'en')
        'vi-ascii' = (Get-I18nText 'gui_lang_vi_ascii' 'vi-ascii')
        'vi'       = (Get-I18nText 'tui_lang_vi' 'vi')
    }
    foreach ($mode in $expected.Keys) {
        $state = New-MockTuiState -Language $mode
        $frame = New-TuiFrame -State $state -Width 120 -Height 30 -Caps $caps
        $header = [string]$frame[1]
        if (-not $header.Contains($expected[$mode])) {
            throw "Header does not name the '$mode' mode (expected '$($expected[$mode])')"
        }
    }
}

Assert-Check -Name "Active action is drawn as an accent bar" -TestBlock {
    $state = New-MockTuiState -Language 'vi'
    $caps = Get-TuiCapabilities -Override @{ HasColor = $true; HasUnicode = $true; Width = 120; Height = 40 }
    $frame = New-TuiFrame -State $state -Width 120 -Height 40 -Caps $caps
    $invert = [char]27 + '[7m'
    $bars = @($frame | Where-Object { $_.Contains($invert) })
    if ($bars.Count -eq 0) { throw 'The selected action has no accent bar' }

    # The bar covers exactly the selected action's wrapped lines: one per segment.
    $leftW = [Math]::Max(44, [int][Math]::Floor(118 * 0.45))
    $segments = @(Get-TuiWrappedText -Text ([string]$state.Catalog[0].Title) -MaxWidth (($leftW - 1) - 9))
    if ($bars.Count -ne $segments.Count) {
        throw "Accent bar covers $($bars.Count) line(s), expected $($segments.Count)"
    }

    # The key badge sits inside the bar's first line, and the bar spans the left pane.
    $plain = @($bars | ForEach-Object { ($_ -replace '\x1b\[[0-9;]*[a-zA-Z]', '').Split([char]0x2502)[1] })
    if (-not $plain[0].Contains('[' + [string]$state.Catalog[0].Key + ']')) {
        throw 'The accent bar does not include the key badge'
    }
    if ((Get-TuiStringWidth $plain[0]) -ne $leftW) {
        throw "Accent bar is $(Get-TuiStringWidth $plain[0]) wide, expected $leftW"
    }
}

Assert-Check -Name "Overflowing list shows a proportional scrollbar thumb" -TestBlock {
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $true; Width = 100; Height = 24 }
    $state = New-MockTuiState -Language 'vi'

    # Small viewport: the list overflows and the scrollbar appears with a thumb.
    $top = New-TuiFrame -State $state -Width 100 -Height 24 -Caps $caps
    $topText = $top -join "`n"
    if (-not $topText.Contains($caps.Symbols.ScrollThumb)) { throw 'No scrollbar thumb when the list overflows' }
    if (-not $topText.Contains($caps.Symbols.ScrollTrack)) { throw 'No scrollbar track when the list overflows' }

    # Moving to the end moves the thumb to the bottom of the track.
    $state.SelectedIndex = 20
    $bottom = New-TuiFrame -State $state -Width 100 -Height 24 -Caps $caps
    $thumbRow = {
        param($frame)
        for ($i = 0; $i -lt $frame.Count; $i++) {
            if ($frame[$i].Contains($caps.Symbols.ScrollThumb)) { return $i }
        }
        return -1
    }
    $topRow = & $thumbRow $top
    $bottomRow = & $thumbRow $bottom
    if ($bottomRow -le $topRow) { throw "Thumb did not move down (top row $topRow, bottom row $bottomRow)" }

    # A list that fits needs no scrollbar.
    $tall = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $true; Width = 100; Height = 80 }
    $roomy = New-TuiFrame -State $state -Width 100 -Height 80 -Caps $tall
    if (($roomy -join "`n").Contains($tall.Symbols.ScrollThumb)) {
        throw 'A scrollbar was drawn although every action fits'
    }
}

Assert-Check -Name "Two-pane detail shows the full title and description" -TestBlock {
    $state = New-MockTuiState -Language 'vi'
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $false }
    $frame = New-TuiFrame -State $state -Width 180 -Height 40 -Caps $caps
    $rightCells = @(foreach ($line in $frame) {
        $parts = $line.Split('|')
        if ($parts.Count -ge 4) { $parts[2] }
    })
    $detail = (($rightCells -join ' ') -replace '\s+', ' ').Trim()
    $item = (Get-TuiVisibleItems -State $state)[0]
    $title = ([string]$item.Title -replace '\s+', ' ').Trim()
    $desc = ([string]$item.Desc -replace '\s+', ' ').Trim()
    if (-not $detail.Contains($title)) { throw "The detail pane hides part of '$title'" }
    if (-not $detail.Contains($desc)) { throw 'The detail pane hides part of the description' }
    foreach ($line in $frame) {
        if ((Get-TuiStringWidth $line) -gt 180) { throw 'The frame exceeds the terminal width' }
    }
}

# ----------------------------------------------------------------------------
# 5. Frame dimension tests
# ----------------------------------------------------------------------------
Assert-Check -Name "Frames fit six resolutions in Vietnamese and English with Unicode and ASCII symbols" -TestBlock {

    # 110 and 111 are the narrowest two-pane widths, where the detail pane is tightest.
    $resolutions = @(
        @{ W = 80;  H = 24 },
        @{ W = 100; H = 30 },
        @{ W = 110; H = 30 },
        @{ W = 111; H = 30 },
        @{ W = 120; H = 40 },
        @{ W = 200; H = 50 }
    )
    $languages = @('vi', 'en')
    $symbolModes = @(
        @{ Name = 'unicode'; HasUnicode = $true },
        @{ Name = 'ascii';   HasUnicode = $false }
    )

    foreach ($res in $resolutions) {
        foreach ($lang in $languages) {
            foreach ($sm in $symbolModes) {
                $case = "{0}x{1}_{2}_{3}" -f $res.W, $res.H, $lang, $sm.Name

                $state = New-MockTuiState -Language $lang
                $caps = Get-TuiCapabilities -Override @{
                    HasColor   = $false
                    HasUnicode = $sm.HasUnicode
                    Width      = $res.W
                    Height     = $res.H
                }

                $renderedLines = New-TuiFrame -State $state -Width $res.W -Height $res.H -Caps $caps
                if ($renderedLines.Count -ne $res.H) {
                    throw "Rendered frame for $case produced $($renderedLines.Count) lines, expected $($res.H)"
                }

                # Every row must be exactly as wide as the frame, so the right border lands
                # in the same column on every line.
                for ($lineIdx = 0; $lineIdx -lt $renderedLines.Count; $lineIdx++) {
                    $lw = Get-TuiStringWidth $renderedLines[$lineIdx]
                    if ($lw -ne $res.W) {
                        throw "Line $lineIdx in $case is $lw columns wide, expected $($res.W)"
                    }
                }
            }
        }
    }
}

# ----------------------------------------------------------------------------
# 5b. Golden snapshots (AC-T4 visual regression net)
# ----------------------------------------------------------------------------
Assert-Check -Name "Golden snapshots match at 80x24, 100x30, 120x40 and 200x50" -TestBlock {
    $snapshotDir = Join-Path $RootDir 'tests/snapshots/tui'
    if (-not (Test-Path -LiteralPath $snapshotDir)) {
        New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    }
    $resolutions = @(
        @{ W = 80;  H = 24 },
        @{ W = 100; H = 30 },
        @{ W = 120; H = 40 },
        @{ W = 200; H = 50 }
    )
    $updateSnapshots = ($env:PSMGR_UPDATE_SNAPSHOTS -eq '1')

    foreach ($res in $resolutions) {
        foreach ($lang in @('vi', 'en')) {
            foreach ($sm in @(
                @{ Name = 'unicode'; HasUnicode = $true },
                @{ Name = 'ascii';   HasUnicode = $false }
            )) {
                $snapName = "{0}x{1}_{2}_{3}.txt" -f $res.W, $res.H, $lang, $sm.Name
                $snapPath = Join-Path $snapshotDir $snapName
                $state = New-MockTuiState -Language $lang
                $caps = Get-TuiCapabilities -Override @{
                    HasColor   = $false
                    HasUnicode = $sm.HasUnicode
                    Width      = $res.W
                    Height     = $res.H
                }
                $rendered = New-TuiFrame -State $state -Width $res.W -Height $res.H -Caps $caps
                $current = ($rendered -join "`r`n")

                if ($updateSnapshots) {
                    Set-Content -LiteralPath $snapPath -Value $current -Encoding UTF8 -Force
                    continue
                }
                if (-not (Test-Path -LiteralPath $snapPath)) {
                    throw "Missing snapshot $snapName; regenerate the baselines with PSMGR_UPDATE_SNAPSHOTS=1"
                }

                $golden = Get-Content -LiteralPath $snapPath -Raw -Encoding UTF8
                $curNorm = ($current -replace "`r`n", "`n").TrimEnd("`n")
                $goldNorm = ($golden -replace "`r`n", "`n").TrimEnd("`n")
                if ($curNorm -ne $goldNorm) {
                    $curArr = $curNorm -split "`n"
                    $goldArr = $goldNorm -split "`n"
                    $firstDiff = -1
                    for ($ci = 0; $ci -lt [Math]::Min($curArr.Count, $goldArr.Count); $ci++) {
                        if ($curArr[$ci] -cne $goldArr[$ci]) { $firstDiff = $ci; break }
                    }
                    if ($firstDiff -lt 0) { $firstDiff = [Math]::Min($curArr.Count, $goldArr.Count) }
                    $goldLine = if ($firstDiff -lt $goldArr.Count) { $goldArr[$firstDiff] } else { '<missing>' }
                    $curLine = if ($firstDiff -lt $curArr.Count) { $curArr[$firstDiff] } else { '<missing>' }
                    throw ("Snapshot mismatch in {0} at line {1}.`n  golden: {2}`n  actual: {3}`nRe-run with PSMGR_UPDATE_SNAPSHOTS=1 after an intentional layout change." -f $snapName, ($firstDiff + 1), $goldLine, $curLine)
                }
            }
        }
    }
}

# ----------------------------------------------------------------------------
# 6. Differential Renderer Tests
# ----------------------------------------------------------------------------
Assert-Check -Name "Get-TuiFrameDiff returns only changed lines between frames" -TestBlock {
    $frame1 = @("Line 1", "Line 2", "Line 3", "Line 4")
    $frame2 = @("Line 1", "Line 2 MODIFIED", "Line 3", "Line 4")

    $diffs = @(Get-TuiFrameDiff -Previous $frame1 -Current $frame2)
    if ($diffs.Count -ne 1) { throw "Expected 1 diff, got $($diffs.Count)" }
    if ($diffs[0].Row -ne 1) { throw "Expected diff at Row 1, got $($diffs[0].Row)" }
    if ($diffs[0].Text -ne "Line 2 MODIFIED") { throw "Incorrect diff text: $($diffs[0].Text)" }

    # Identical frames produce 0 diffs
    $noDiffs = @(Get-TuiFrameDiff -Previous $frame1 -Current $frame1)
    if ($noDiffs.Count -ne 0) { throw "Expected 0 diffs for identical frames" }
}

Assert-Check -Name "Write-TuiFrame positions every row without newlines" -TestBlock {
    $esc = [char]27
    $frame = @('AAA', 'BBB', 'CCC')
    $captured = ''
    $writer = { param($chunk) $script:capturedChunk = $chunk }
    Write-TuiFrame -Frame $frame -Writer $writer
    $captured = $script:capturedChunk

    if ($captured.Contains("`n") -or $captured.Contains("`r")) {
        throw 'A full-width frame must not rely on newlines; the pending wrap smears the screen'
    }
    for ($i = 1; $i -le $frame.Count; $i++) {
        if (-not $captured.Contains("$esc[$i;1H")) { throw "Row $i was not positioned explicitly" }
    }
    if (-not $captured.Contains("$esc[K")) { throw 'Rows are not erased to end of line' }

    # Differential repaint touches only the changed row.
    $script:capturedChunk = ''
    Write-TuiFrame -Frame @('AAA', 'BBB2', 'CCC') -PreviousFrame $frame -Writer $writer
    $delta = $script:capturedChunk
    if (-not $delta.Contains("$esc[2;1H")) { throw 'Changed row was not repainted' }
    if ($delta.Contains("$esc[1;1H") -or $delta.Contains("$esc[3;1H")) {
        throw 'Unchanged rows were repainted'
    }
}

Assert-Check -Name "Modal screens render at exact size with localised titles" -TestBlock {
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $false; Width = 100; Height = 30 }
    $titleKeys = @{
        Help    = 'tui_help_title'
        Preview = 'tui_preview_title'
        Confirm = 'tui_confirm_title'
        Result  = 'tui_result_title'
    }
    foreach ($mode in $titleKeys.Keys) {
        $state = New-MockTuiState
        $state.Mode = $mode
        $state.PreviewItem = $state.Catalog[0]
        if ($mode -eq 'Result') { $state.Result = @{ Ok = $true; Duration = 1.5; Errors = @() } }
        if ($mode -eq 'Confirm') { $state.ConfirmBuffer = 'y' }

        $frame = New-TuiFrame -State $state -Width 100 -Height 30 -Caps $caps
        if ($frame.Count -ne 30) { throw "$mode frame produced $($frame.Count) lines" }
        foreach ($line in $frame) {
            $lw = Get-TuiStringWidth $line
            if ($lw -gt 100) { throw "$mode line exceeded width ($lw)" }
        }
        $text = $frame -join "`n"
        $expected = Get-I18nText $titleKeys[$mode] 'vi'
        if ($text -notmatch [regex]::Escape($expected)) {
            throw "$mode frame missing title '$expected'"
        }
    }

    # Destructive confirmation marks the typed 'y'
    $confirmState = New-MockTuiState
    $confirmState.Mode = 'Confirm'
    $confirmState.PreviewItem = $confirmState.Catalog | Where-Object { $_.Destructive } | Select-Object -First 1
    $confirmState.ConfirmBuffer = 'y'
    $confirmFrame = (New-TuiFrame -State $confirmState -Width 100 -Height 30 -Caps $caps) -join "`n"
    if ($confirmFrame -notmatch '\[y\]') { throw "Confirm screen does not show the typed y marker" }
}

Assert-Check -Name "Notifications modal renders markers, selection and the empty placeholder" -TestBlock {
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $false; Width = 100; Height = 30 }
    $state = New-MockTuiState -Language 'vi'
    $state.Notifications = @(
        [pscustomobject]@{ Id = 'a'; Title = 'Alpha'; Message = 'first'; Time = '2026-01-01 10:00'; Url = 'https://example.com/a'; Read = $false }
        [pscustomobject]@{ Id = 'b'; Title = 'Beta'; Message = 'second'; Time = '2026-01-01 11:00'; Url = ''; Read = $true }
    )
    $state.NotificationIndex = 0
    $state.Mode = 'Notifications'

    $frame = New-TuiFrame -State $state -Width 100 -Height 30 -Caps $caps
    if ($frame.Count -ne 30) { throw "Notifications frame produced $($frame.Count) lines" }
    foreach ($line in $frame) {
        if ((Get-TuiStringWidth $line) -gt 100) { throw "Notifications line exceeded width" }
    }
    $text = $frame -join "`n"
    foreach ($key in @('tui_notif_title', 'tui_notif_close')) {
        $expected = Get-I18nText $key 'vi'
        if ($text -notmatch [regex]::Escape($expected)) { throw "Notifications frame missing '$key'" }
    }
    if ($text -notmatch [regex]::Escape('[x]')) { throw "Unread marker missing" }
    if ($text -notmatch [regex]::Escape('[ ]')) { throw "Read marker missing" }
    if ($text -notmatch [regex]::Escape('> [x]')) { throw "Selection pointer missing" }
    if ($text -notmatch 'Alpha' -or $text -notmatch 'Beta') { throw "Notification titles missing" }

    $empty = New-MockTuiState -Language 'vi'
    $empty.Mode = 'Notifications'
    $emptyText = (New-TuiFrame -State $empty -Width 100 -Height 30 -Caps $caps) -join "`n"
    if ($emptyText -notmatch [regex]::Escape((Get-I18nText 'tui_notif_empty' 'vi'))) {
        throw "Empty notification placeholder missing"
    }
}

Assert-Check -Name "Unread badge appears only when notifications are unread" -TestBlock {
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $false; Width = 80; Height = 24 }
    $state = New-MockTuiState -Language 'en'
    $without = (New-TuiFrame -State $state -Width 80 -Height 24 -Caps $caps) -join "`n"
    if ($without -match '!3') { throw "Badge rendered without unread notifications" }

    $state.UnreadCount = 3
    $with = (New-TuiFrame -State $state -Width 80 -Height 24 -Caps $caps) -join "`n"
    if ($with -notmatch '!3') { throw "Unread badge missing" }
}

Assert-Check -Name "Result screen renders optional details" -TestBlock {
    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $false; Width = 100; Height = 30 }
    $state = New-MockTuiState -Language 'en'
    $state.Mode = 'Result'
    $state.PreviewItem = $state.Catalog[0]
    $state.Result = @{
        Ok       = $true
        Duration = 0.2
        Errors   = @()
        Details  = @('Release: https://example.com/rel')
    }
    $text = (New-TuiFrame -State $state -Width 100 -Height 30 -Caps $caps) -join "`n"
    if ($text -notmatch [regex]::Escape('Release: https://example.com/rel')) { throw "Result details missing" }

    $plain = New-MockTuiState -Language 'en'
    $plain.Mode = 'Result'
    $plain.PreviewItem = $plain.Catalog[0]
    $plain.Result = @{ Ok = $true; Duration = 0.2; Errors = @() }
    $plainText = (New-TuiFrame -State $plain -Width 100 -Height 30 -Caps $caps) -join "`n"
    if ($plainText -match 'Release:') { throw "A result without Details rendered a details row" }
}

# ----------------------------------------------------------------------------
# 7. Localisation Guards
# ----------------------------------------------------------------------------
Assert-Check -Name "TUI render/catalog source stays ASCII (all copy lives in i18n.json)" -TestBlock {
    $tuiSources = @(
        'modules/UI/TuiRender.ps1', 'modules/UI/TuiCatalog.ps1',
        'modules/UI/TuiState.ps1', 'modules/UI/TuiEngine.ps1'
    )
    foreach ($rel in $tuiSources) {
        $path = Join-Path $RootDir $rel
        $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($path))
        for ($ci = 0; $ci -lt $text.Length; $ci++) {
            if ($text[$ci] -eq [char]0xFEFF) { continue }  # UTF-8 BOM is allowed
            if ([int]$text[$ci] -gt 126) {
                throw ("{0} contains a non-ASCII character at offset {1}; move the string to i18n.json and call Get-I18nText" -f $rel, $ci)
            }
        }
    }
}

Assert-Check -Name "Every tui_* i18n key exists in en, vi and vi-ascii" -TestBlock {
    $i18n = Get-Content -LiteralPath (Join-Path $RootDir 'i18n.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $tuiKeys = @(($i18n.en | Get-Member -MemberType NoteProperty).Name | Where-Object { $_ -like 'tui_*' })
    if ($tuiKeys.Count -eq 0) { throw "No tui_* keys found in i18n.json" }
    foreach ($lang in @('en', 'vi', 'vi-ascii')) {
        $names = ($i18n.$lang | Get-Member -MemberType NoteProperty).Name
        foreach ($key in $tuiKeys) {
            if ($names -notcontains $key) { throw "Key '$key' missing from '$lang'" }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host ("`n[FAIL] TUI render tests failed with " + $failures.Count + " failure(s).") -ForegroundColor Red
    exit 1
}

Write-Host "`n[PASS] test_tui_render.ps1 passed all checks" -ForegroundColor Green
exit 0
