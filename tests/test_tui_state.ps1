#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Contract Tests - TUI State Reducer & Keyboard Mapping
.DESCRIPTION
    Exercises Update-TuiState with synthetic key input (no console, no real actions):
      - state-driven initial cursor
      - arrow / Home / End / page navigation with clamping
      - Tab / Shift+Tab group jumping (wraps)
      - mnemonic keys and 100% legacy-key compatibility (with "new key" hint)
      - Enter routing: destructive -> confirm, undoable -> preview, else -> run
      - global shortcuts g / l / q
      - search mode: diacritic-insensitive filtering, Enter keeps, Esc clears
      - help overlay toggle
      - reducer purity (input state is never mutated)
      - empty search result renders the localised placeholder
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

function New-TestState {
    param(
        [string]$Language = 'vi',
        [bool]$PS7Default = $false,
        [string]$SearchQuery = ''
    )

    $status = [pscustomobject]@{
        WTDefaultIsPS7     = $PS7Default
        WTDefaultIsPS5     = (-not $PS7Default)
        IsWTDefaultHost    = $true
        ShimActive         = $true
        OverallPS7Default  = $PS7Default
        CurrentHostVersion = '7.4.5'
        CurrentHostEdition = 'Core'
        Installations      = @{ PS7 = @{ Version = '7.4.5' } }
    }
    $cfg = [pscustomobject]@{ updateSource = 'winget'; channel = 'stable'; language = $Language }

    $state = New-TuiState -Version '1.4.0' -Language $Language -Status $status -Config $cfg `
        -Groups (Get-TuiGroups -Language $Language) -Catalog (Get-TuiCatalog -Language $Language)

    if ($SearchQuery) {
        $state.Mode = 'Search'
        $state.SearchActive = $true
        $state.SearchQuery = $SearchQuery
    }
    return $state
}

function Invoke-Key {
    param([hashtable]$State, [string]$Key)
    return Update-TuiState -State $State -Key $Key
}

# ----------------------------------------------------------------------------
# Initial state
# ----------------------------------------------------------------------------
Assert-Check -Name "Initial cursor is state-driven (def7 only while PS7 is not the default)" -TestBlock {
    $notDefault = New-TestState -PS7Default $false
    $item = Get-TuiSelectedItem -State $notDefault
    if ($item.Id -ne 'def7') { throw "Expected def7 cursor, got $($item.Id)" }

    $isDefault = New-TestState -PS7Default $true
    $item2 = Get-TuiSelectedItem -State $isDefault
    if ($item2.Id -ne 'q_ps7') { throw "Expected q_ps7 cursor when PS7 is already default, got $($item2.Id)" }
}

# ----------------------------------------------------------------------------
# Navigation
# ----------------------------------------------------------------------------
Assert-Check -Name "Arrow keys move and clamp at both ends" -TestBlock {
    $s = New-TestState
    $r = Invoke-Key -State $s -Key 'Down'
    if ($r.State.SelectedIndex -ne 1) { throw "Down did not advance" }

    $r2 = Invoke-Key -State $r.State -Key 'Up'
    if ($r2.State.SelectedIndex -ne 0) { throw "Up did not return to 0" }

    $r3 = Invoke-Key -State $s -Key 'Up'
    if ($r3.State.SelectedIndex -ne 0) { throw "Up at top should clamp at 0" }

    $end = Invoke-Key -State $s -Key 'End'
    $count = @(Get-TuiVisibleItems -State $s).Count
    if ($end.State.SelectedIndex -ne ($count - 1)) { throw "End did not jump to the last item" }

    $past = Invoke-Key -State $end.State -Key 'Down'
    if ($past.State.SelectedIndex -ne ($count - 1)) { throw "Down at bottom should clamp" }
}

Assert-Check -Name "PgDn/PgUp/Home move by page and to edges" -TestBlock {
    $s = New-TestState
    $down = Invoke-Key -State $s -Key 'PgDn'
    if ($down.State.SelectedIndex -ne 5) { throw "PgDn expected index 5, got $($down.State.SelectedIndex)" }
    $toTop = Invoke-Key -State $down.State -Key 'Home'
    if ($toTop.State.SelectedIndex -ne 0) { throw "Home expected 0" }
}

Assert-Check -Name "Tab/Shift+Tab jump between groups and wrap" -TestBlock {
    $s = New-TestState
    $first = Get-TuiSelectedItem -State $s
    if ($first.GroupId -ne 'shell') { throw "Expected to start in shell group" }

    $tab = Invoke-Key -State $s -Key 'Tab'
    $afterTab = Get-TuiSelectedItem -State $tab.State
    if ($afterTab.GroupId -ne 'launch') { throw "Tab expected 'launch' group, got $($afterTab.GroupId)" }

    $shift = Invoke-Key -State $tab.State -Key 'ShiftTab'
    $afterShift = Get-TuiSelectedItem -State $shift.State
    if ($afterShift.GroupId -ne 'shell') { throw "Shift+Tab expected 'shell' group, got $($afterShift.GroupId)" }

    # Wrap: from health forward goes back to shell
    $health = $s.Clone()
    $health.SelectedIndex = 18
    $item = Get-TuiSelectedItem -State $health
    if ($item.GroupId -ne 'health') { throw "Fixture expected health group at index 18, got $($item.GroupId)" }
    $wrapped = Invoke-Key -State $health -Key 'Tab'
    $wItem = Get-TuiSelectedItem -State $wrapped.State
    if ($wItem.GroupId -ne 'shell') { throw "Tab should wrap to shell, got $($wItem.GroupId)" }
}

# ----------------------------------------------------------------------------
# Keys: mnemonic, legacy, globals, Enter routing
# ----------------------------------------------------------------------------
Assert-Check -Name "Mnemonic keys route to the right command class" -TestBlock {
    $s = New-TestState
    $d = Invoke-Key -State $s -Key 'd'
    if ($d.State.PreviewItem.Id -ne 'def7') { throw "'d' should select def7" }
    if ($d.Command -ne 'preview') { throw "'d' should request preview, got $($d.Command)" }

    $x = Invoke-Key -State $s -Key 'x'
    if ($x.State.PreviewItem.Id -ne 'clean-backups') { throw "'x' should select clean-backups" }
    if ($x.Command -ne 'confirm') { throw "'x' (destructive) should request confirm, got $($x.Command)" }

    $f = Invoke-Key -State $s -Key 'f'
    if ($f.Command -ne 'run') { throw "read-only action should run directly, got $($f.Command)" }
    if ($f.State.PreviewItem.Id -ne 'logs') { throw "'f' should select logs" }
}

Assert-Check -Name "Every legacy key still resolves to its original action" -TestBlock {
    $s = New-TestState
    $expected = @{
        '1' = 'def7'; '2' = 'def5'; '3' = 'source'; '4' = 'update'; '5' = 'install'
        '6' = 'q_ps7'; '7' = 'q_ps7a'; '8' = 'q_split'; '9' = 'q_ps5'; '0' = 'diag'
        'Y' = 'sync'; 'O' = 'doctor'; 'A' = 'adopt'; 'B' = 'backup'; 'C' = 'backup-cloud'
        'K' = 'restore'; 'V' = 'logs'; 'W' = 'sync-sources'; 'P' = 'prof'; 'T' = 'audit-prof'
        'X' = 'clean-backups'; 'D' = 'def7'; 'R' = 'def5'; 'S' = 'source'; 'U' = 'update'; 'I' = 'install'
    }
    foreach ($legacy in $expected.Keys) {
        $res = Invoke-Key -State $s -Key $legacy
        $want = $expected[$legacy]
        if ($null -eq $res.State.PreviewItem -or $res.State.PreviewItem.Id -ne $want) {
            $got = if ($res.State.PreviewItem) { $res.State.PreviewItem.Id } else { '<none>' }
            throw "Legacy key '$legacy' expected '$want', got '$got'"
        }
        $newKey = ($s.Catalog | Where-Object { $_.Id -eq $want }).Key
        if ($legacy -ceq $newKey) {
            # Key is now the primary mnemonic too: no deprecation hint expected.
            continue
        }
        if ([string]::IsNullOrEmpty($res.State.StatusMessage)) {
            throw "Legacy key '$legacy' produced no deprecation hint"
        }
        if ($res.State.StatusMessage -notmatch [regex]::Escape($newKey)) {
            throw "Legacy hint for '$legacy' does not mention the new key '$newKey'"
        }
    }
}

Assert-Check -Name "Global shortcuts g/l/q map to engine commands" -TestBlock {
    $s = New-TestState
    if ((Invoke-Key -State $s -Key 'g').Command -ne 'gui') { throw "'g' should request GUI" }
    if ((Invoke-Key -State $s -Key 'l').Command -ne 'lang') { throw "'l' should toggle language" }
    if ((Invoke-Key -State $s -Key 'q').Command -ne 'quit') { throw "'q' should quit" }
    if ((Invoke-Key -State $s -Key 'Q').Command -ne 'quit') { throw "Legacy 'Q' should still quit" }
}

Assert-Check -Name "Enter on the selected item returns its command class" -TestBlock {
    $s = New-TestState
    $enter = Invoke-Key -State $s -Key 'Enter'
    if ($enter.Command -ne 'preview') { throw "def7 Enter expected preview, got $($enter.Command)" }
}

# ----------------------------------------------------------------------------
# Search and help modes
# ----------------------------------------------------------------------------
Assert-Check -Name "Search mode filters with diacritic-insensitive matching" -TestBlock {
    $s = New-TestState
    $s = (Invoke-Key -State $s -Key '/').State
    if ($s.Mode -ne 'Search') { throw "Expected Search mode" }

    foreach ($ch in @('d', 'a', 't')) { $s = (Invoke-Key -State $s -Key $ch).State }
    if ($s.SearchQuery -ne 'dat') { throw "Query accumulation failed: $($s.SearchQuery)" }
    $items = @(Get-TuiVisibleItems -State $s)
    if (-not ($items | Where-Object { $_.Id -eq 'def7' })) {
        throw "'dat' should match 'Đặt PS7...' but matched: $(($items | ForEach-Object { $_.Id }) -join ',')"
    }

    # Backspace narrows the query again
    $s = (Invoke-Key -State $s -Key 'Backspace').State
    if ($s.SearchQuery -ne 'da') { throw "Backspace failed: $($s.SearchQuery)" }

    # Enter keeps the filter and returns to list mode
    $done = Invoke-Key -State $s -Key 'Enter'
    if ($done.State.Mode -ne 'List') { throw "Enter should leave search mode" }
    if ($done.State.SearchQuery -ne 'da') { throw "Enter should keep the query" }

    # Esc in list mode clears it
    $cleared = Invoke-Key -State $done.State -Key 'Esc'
    if ($cleared.State.SearchQuery -ne '') { throw "Esc should clear the filter" }
    $visibleGroups = @((Get-TuiGroups -Language 'en').Id)
    $allActions = @((Get-TuiCatalog -Language 'en') | Where-Object { $_.GroupId -in $visibleGroups }).Count
    if (@(Get-TuiVisibleItems -State $cleared.State).Count -ne $allActions) {
        throw "Cleared filter should show all $allActions actions"
    }
}

Assert-Check -Name "Unmatched search renders the localised placeholder" -TestBlock {
    $s = New-TestState -SearchQuery 'zzzznomatch'
    $items = @(Get-TuiVisibleItems -State $s)
    if ($items.Count -ne 0) { throw "Expected zero matches, got $($items.Count)" }

    $caps = Get-TuiCapabilities -Override @{ HasColor = $false; HasUnicode = $false; Width = 100; Height = 30 }
    $frame = New-TuiFrame -State $s -Width 100 -Height 30 -Caps $caps
    $text = $frame -join "`n"
    $expected = Get-I18nText 'tui_search_empty' 'vi'
    if ($text -notmatch [regex]::Escape($expected)) {
        throw "Frame does not show the '$expected' placeholder"
    }
}

Assert-Check -Name "Help overlay toggles with ? and closes with Esc/Enter" -TestBlock {
    $s = New-TestState
    $help = Invoke-Key -State $s -Key '?'
    if ($help.State.Mode -ne 'Help') { throw "? should open help" }
    if ((Invoke-Key -State $help.State -Key 'Esc').State.Mode -ne 'List') { throw "Esc should close help" }
    if ((Invoke-Key -State $help.State -Key 'Enter').State.Mode -ne 'List') { throw "Enter should close help" }
}

Assert-Check -Name "Help, update and notification keys route to engine commands" -TestBlock {
    $s = New-TestState
    if ((Invoke-Key -State $s -Key 'h').State.Mode -ne 'Help') { throw "'h' should open the help overlay" }
    if ((Invoke-Key -State $s -Key 'H').State.Mode -ne 'Help') { throw "legacy 'H' should open the help overlay" }
    if ((Invoke-Key -State $s -Key '!').Command -ne 'notifications') { throw "'!' should open the notification modal" }
    if ((Invoke-Key -State $s -Key 'v').Command -ne 'update-check') { throw "'v' should check for a PSManager release" }
    if ((Invoke-Key -State $s -Key 'p').Command -ne 'update-app') { throw "'p' should install a PSManager release" }

    # Uppercase legacy keys keep their original meaning.
    $vLegacy = Invoke-Key -State $s -Key 'V'
    if ($null -eq $vLegacy.State.PreviewItem -or $vLegacy.State.PreviewItem.Id -ne 'logs') {
        throw "legacy 'V' should still open logs"
    }
    $pLegacy = Invoke-Key -State $s -Key 'P'
    if ($null -eq $pLegacy.State.PreviewItem -or $pLegacy.State.PreviewItem.Id -ne 'prof') {
        throw "legacy 'P' should still open the profile editor"
    }
}

Assert-Check -Name "Visible action count is unchanged by the global shortcuts" -TestBlock {
    $s = New-TestState
    $visibleGroups = @((Get-TuiGroups -Language 'en').Id)
    $allActions = @((Get-TuiCatalog -Language 'en') | Where-Object { $_.GroupId -in $visibleGroups }).Count
    if (@(Get-TuiVisibleItems -State $s).Count -ne $allActions) {
        throw "Expected $allActions visible actions, got $(@(Get-TuiVisibleItems -State $s).Count)"
    }
    $globalIds = @($s.Catalog | Where-Object { $_.GroupId -eq 'global' } | ForEach-Object { $_.Id })
    foreach ($expected in @('help', 'update-check', 'update-app', 'notifications')) {
        if ($globalIds -notcontains $expected) { throw "Catalog is missing the global entry '$expected'" }
    }
}

Assert-Check -Name "Notifications modal navigates, routes and closes" -TestBlock {
    $s = New-TestState
    $s.Notifications = @(
        [pscustomobject]@{ Id = 'a'; Title = 'Alpha'; Message = 'first'; Time = '2026-01-01 10:00'; Url = 'https://example.com/a'; Read = $false }
        [pscustomobject]@{ Id = 'b'; Title = 'Beta'; Message = 'second'; Time = '2026-01-01 11:00'; Url = ''; Read = $true }
    )
    $s.UnreadCount = 1
    $s.Mode = 'Notifications'
    $s.NotificationIndex = 0

    $down = Invoke-Key -State $s -Key 'Down'
    if ($down.State.NotificationIndex -ne 1) { throw "Down should advance the notification cursor" }
    $downAgain = Invoke-Key -State $down.State -Key 'Down'
    if ($downAgain.State.NotificationIndex -ne 1) { throw "Down should clamp at the last notification" }
    $up = Invoke-Key -State $down.State -Key 'Up'
    if ($up.State.NotificationIndex -ne 0) { throw "Up should move back" }

    if ((Invoke-Key -State $s -Key 'o').Command -ne 'notifications-open') { throw "'o' should open the selected notification" }
    if ((Invoke-Key -State $down.State -Key 'o').Command -ne 'none') { throw "'o' without a URL must not open anything" }
    if ((Invoke-Key -State $s -Key 'c').Command -ne 'notifications-clear') { throw "'c' should clear the store" }
    if ((Invoke-Key -State $s -Key 'r').Command -ne 'notifications-read') { throw "'r' should mark everything read" }

    foreach ($closeKey in @('Esc', 'Enter', 'q')) {
        if ((Invoke-Key -State $s -Key $closeKey).State.Mode -ne 'List') {
            throw "$closeKey should close the notification modal"
        }
    }
}

# ----------------------------------------------------------------------------
# Purity
# ----------------------------------------------------------------------------
Assert-Check -Name "Reducer never mutates the input state" -TestBlock {
    $s = New-TestState
    $before = $s.SelectedIndex
    $beforeMode = $s.Mode
    $null = Invoke-Key -State $s -Key 'End'
    $null = Invoke-Key -State $s -Key '?'
    if ($s.SelectedIndex -ne $before) { throw "Input SelectedIndex changed to $($s.SelectedIndex)" }
    if ($s.Mode -ne $beforeMode) { throw "Input Mode changed to $($s.Mode)" }
}

if ($failures.Count -gt 0) {
    Write-Host ("`n[FAIL] TUI state tests failed with " + $failures.Count + " failure(s).") -ForegroundColor Red
    exit 1
}

Write-Host "`n[PASS] test_tui_state.ps1 passed all checks" -ForegroundColor Green
exit 0
