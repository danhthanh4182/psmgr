#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager TUI - State Model & Keyboard Reducer
.DESCRIPTION
    Pure state transitions: New-TuiState builds the initial screen state (including the
    state-driven initial cursor), Update-TuiState maps one key press to a new state plus
    a command for the engine to perform. No console I/O happens here, so every key path
    is testable with synthetic input.
#>

function Get-TuiVisibleItems {
    <#
    .SYNOPSIS
        Catalog items passing the current search filter, in display order.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory = $true)][hashtable]$State)
    # Global shortcuts live in the catalog for registry parity but never render as rows.
    $items = @($State.Catalog | Where-Object { $_.GroupId -ne 'global' })
    $query = [string]$State.SearchQuery
    if (-not $query) { return $items }

    $needle = ConvertTo-TuiSearchKey $query
    if (-not $needle) { return $items }

    return @($items | Where-Object {
        $haystack = ConvertTo-TuiSearchKey ([string]$_.Title + " " + [string]$_.Desc)
        $haystack -like ("*" + $needle + "*")
    })
}

function New-TuiState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Version = "",
        [string]$Language = "vi",
        [object]$Status = $null,
        [object]$Config = $null,
        [object[]]$Groups = @(),
        [object[]]$Catalog = @(),
        [object]$UpdateStatus = $null,
        [object[]]$Notifications = @()
    )

    $state = @{
        Version       = $Version
        Language      = $Language
        Groups        = $Groups
        Catalog       = $Catalog
        Mode          = 'List'
        SelectedIndex = 0
        ScrollOffset  = 0
        SearchQuery   = ''
        SearchActive  = $false
        StatusMessage = ''
        Status        = $Status
        Config        = $Config
        PreviewItem   = $null
        ConfirmBuffer = ''
        Result        = $null
        UpdateStatus  = $UpdateStatus
        Notifications = @($Notifications)
        NotificationIndex = 0
        UnreadCount   = 0
    }
    $state.SelectedIndex = Get-TuiDefaultIndex -State $state
    return $state
}

function Get-TuiDefaultIndex {
    <#
    .SYNOPSIS
        Cursor follows system state: offer "set default" only while PS7 is not the default.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $items = @(Get-TuiVisibleItems -State $State)
    if ($items.Count -eq 0) { return 0 }

    $isDefault = $false
    try { $isDefault = [bool]$State.Status.OverallPS7Default } catch {}
    $wanted = if ($isDefault) { 'q_ps7' } else { 'def7' }

    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Id -eq $wanted) { return $i }
    }
    return 0
}

function Get-TuiSelectedItem {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $items = @(Get-TuiVisibleItems -State $State)
    if ($items.Count -eq 0) { return $null }
    $idx = [Math]::Min([Math]::Max(0, [int]$State.SelectedIndex), $items.Count - 1)
    return $items[$idx]
}

function Set-TuiSelectionIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $items = @(Get-TuiVisibleItems -State $State)
    if ($items.Count -eq 0) { $State.SelectedIndex = 0; return }
    $clamped = [Math]::Min([Math]::Max(0, $Index), $items.Count - 1)
    $State.SelectedIndex = $clamped
}

function Get-TuiCommandForItem {
    <#
    .SYNOPSIS
        Enter behaviour by action class: destructive -> confirm, undoable -> preview, else run.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][object]$Item)

    if ($Item.Destructive) { return 'confirm' }
    if ($Item.Undoable) { return 'preview' }
    return 'run'
}

function Update-TuiState {
    <#
    .SYNOPSIS
        Reduces one key press into a new state plus an engine command.
    .DESCRIPTION
        Key accepts character keys ("d", "1", "/", "?") and named keys:
        Up, Down, Home, End, PgUp, PgDn, Enter, Esc, Backspace, Tab, ShiftTab.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Key
    )

    $s = $State.Clone()
    $command = 'none'

    # --- Modal states -------------------------------------------------------
    if ($s.Mode -eq 'Help') {
        if ($Key -in @('Esc', 'Enter', '?', 'q')) { $s.Mode = 'List' }
        return @{ State = $s; Command = $command }
    }
    if ($s.Mode -eq 'Preview') {
        if ($Key -eq 'Enter') {
            $command = 'apply'
        } elseif ($Key -in @('Esc', 'q')) {
            $s.Mode = 'List'
        }
        return @{ State = $s; Command = $command }
    }
    if ($s.Mode -eq 'Confirm') {
        # Destructive actions default to cancel: only a typed 'y' + Enter applies.
        if ($Key -eq 'Enter') {
            if ($s.ConfirmBuffer -eq 'y') {
                $command = 'apply'
                $s.ConfirmBuffer = ''
            } else {
                $s.Mode = 'List'
                $s.ConfirmBuffer = ''
            }
        } elseif ($Key -in @('Esc', 'q')) {
            $s.Mode = 'List'
            $s.ConfirmBuffer = ''
        } elseif ($Key -eq 'Backspace') {
            $s.ConfirmBuffer = ''
        } elseif ($Key.Length -eq 1 -and $Key -match '^[yY]$') {
            $s.ConfirmBuffer = 'y'
        }
        return @{ State = $s; Command = $command }
    }
    if ($s.Mode -eq 'Result') {
        if ($Key -in @('Enter', 'Esc', 'q')) { $s.Mode = 'List' }
        return @{ State = $s; Command = $command }
    }
    if ($s.Mode -eq 'Notifications') {
        $notes = @($s.Notifications)
        $last = [Math]::Max(0, ($notes.Count - 1))
        $idx = [Math]::Max(0, [Math]::Min([int]$s.NotificationIndex, $last))
        if ($Key -in @('Esc', 'Enter', 'q')) {
            $s.Mode = 'List'
        } elseif ($Key -eq 'Up') {
            $s.NotificationIndex = [Math]::Max(0, ($idx - 1))
        } elseif ($Key -eq 'Down') {
            $s.NotificationIndex = [Math]::Min($last, ($idx + 1))
        } elseif ($Key -eq 'c') {
            $command = 'notifications-clear'
        } elseif ($Key -eq 'r') {
            $command = 'notifications-read'
        } elseif ($Key -eq 'o') {
            if ($notes.Count -gt 0 -and $notes[$idx].Url) { $command = 'notifications-open' }
        }
        return @{ State = $s; Command = $command }
    }

    # --- Search input -------------------------------------------------------
    if ($s.Mode -eq 'Search') {
        if ($Key -eq 'Enter') {
            $s.Mode = 'List'
            $s.SearchActive = $false
        } elseif ($Key -eq 'Esc') {
            $s.Mode = 'List'
            $s.SearchActive = $false
            $s.SearchQuery = ''
            $s.SelectedIndex = 0
        } elseif ($Key -eq 'Backspace') {
            if ($s.SearchQuery.Length -gt 0) {
                $s.SearchQuery = $s.SearchQuery.Substring(0, $s.SearchQuery.Length - 1)
                $s.SelectedIndex = 0
            }
        } elseif ($Key -eq 'Up' -or $Key -eq 'PgUp') {
            Set-TuiSelectionIndex -State $s -Index ([int]$s.SelectedIndex - 1)
        } elseif ($Key -eq 'Down' -or $Key -eq 'PgDn') {
            Set-TuiSelectionIndex -State $s -Index ([int]$s.SelectedIndex + 1)
        } elseif ($Key.Length -eq 1 -and [int][char]$Key -ge 32) {
            $s.SearchQuery = $s.SearchQuery + $Key
            $s.SelectedIndex = 0
        }
        return @{ State = $s; Command = $command }
    }

    # --- List mode ----------------------------------------------------------
    $items = @(Get-TuiVisibleItems -State $s)
    $current = Get-TuiSelectedItem -State $s

    switch ($Key) {
        'Up'     { Set-TuiSelectionIndex -State $s -Index ([int]$s.SelectedIndex - 1); return @{ State = $s; Command = 'none' } }
        'Down'   { Set-TuiSelectionIndex -State $s -Index ([int]$s.SelectedIndex + 1); return @{ State = $s; Command = 'none' } }
        'PgUp'   { Set-TuiSelectionIndex -State $s -Index ([int]$s.SelectedIndex - 5); return @{ State = $s; Command = 'none' } }
        'PgDn'   { Set-TuiSelectionIndex -State $s -Index ([int]$s.SelectedIndex + 5); return @{ State = $s; Command = 'none' } }
        'Home'   { Set-TuiSelectionIndex -State $s -Index 0; return @{ State = $s; Command = 'none' } }
        'End'    { Set-TuiSelectionIndex -State $s -Index ($items.Count - 1); return @{ State = $s; Command = 'none' } }
        '?'      { $s.Mode = 'Help'; return @{ State = $s; Command = 'none' } }
        '/'      {
            $s.Mode = 'Search'
            $s.SearchActive = $true
            $s.SearchQuery = ''
            $s.SelectedIndex = 0
            return @{ State = $s; Command = 'none' }
        }
        'Esc'    {
            if ($s.SearchQuery) { $s.SearchQuery = ''; $s.SelectedIndex = 0 }
            $s.StatusMessage = ''
            return @{ State = $s; Command = 'none' }
        }
        'Enter'  {
            if ($null -eq $current) { return @{ State = $s; Command = 'none' } }
            $command = Get-TuiCommandForItem -Item $current
            $s.PreviewItem = $current
            $s.ConfirmBuffer = ''
            if ($command -eq 'preview') { $s.Mode = 'Preview' }
            elseif ($command -eq 'confirm') { $s.Mode = 'Confirm' }
            return @{ State = $s; Command = $command }
        }
    }

    # --- Group jump: Tab / Shift+Tab ---------------------------------------
    if ($Key -eq 'Tab' -or $Key -eq 'ShiftTab') {
        if ($items.Count -gt 0 -and $null -ne $current) {
            $groupIds = @($s.Groups | ForEach-Object { $_.Id })
            $ci = [Array]::IndexOf($groupIds, $current.GroupId)
            if ($ci -ge 0) {
                $step = if ($Key -eq 'Tab') { 1 } else { -1 }
                for ($hop = 1; $hop -le $groupIds.Count; $hop++) {
                    $gi = (($ci + ($step * $hop)) % $groupIds.Count + $groupIds.Count) % $groupIds.Count
                    $target = $groupIds[$gi]
                    $found = -1
                    for ($i = 0; $i -lt $items.Count; $i++) {
                        if ($items[$i].GroupId -eq $target) { $found = $i; break }
                    }
                    if ($found -ge 0) { Set-TuiSelectionIndex -State $s -Index $found; break }
                }
            }
        }
        return @{ State = $s; Command = 'none' }
    }

    # --- Global shortcuts (lowercase mnemonic + legacy uppercase aliases) ----
    if ($Key -in @('g', 'G')) { return @{ State = $s; Command = 'gui' } }
    if ($Key -in @('l', 'L')) { return @{ State = $s; Command = 'lang' } }
    if ($Key -in @('q', 'Q')) { return @{ State = $s; Command = 'quit' } }

    # --- Global help / update / notification keys ---------------------------
    if ($Key -in @('h', 'H')) { $s.Mode = 'Help'; return @{ State = $s; Command = 'none' } }
    if ($Key -eq '!') { return @{ State = $s; Command = 'notifications' } }
    if ($Key -ceq 'v') { return @{ State = $s; Command = 'update-check' } }
    if ($Key -ceq 'p') { return @{ State = $s; Command = 'update-app' } }

    # --- Catalog keys (mnemonic first, legacy alias second) -----------------
    $match = Find-TuiActionByKey -InputKey $Key -Catalog @($s.Catalog)
    if ($null -ne $match) {
        $visible = @(Get-TuiVisibleItems -State $s)
        $targetIndex = -1
        for ($i = 0; $i -lt $visible.Count; $i++) {
            if ($visible[$i].Id -eq $match.Item.Id) { $targetIndex = $i; break }
        }
        if ($targetIndex -ge 0) {
            Set-TuiSelectionIndex -State $s -Index $targetIndex
            if ($match.IsLegacy) {
                $hint = Get-I18nText 'tui_legacy_hint' $s.Language
                $s.StatusMessage = $hint -f $Key, $match.PrimaryKey
            } else {
                $s.StatusMessage = ''
            }
            $command = Get-TuiCommandForItem -Item $match.Item
            $s.PreviewItem = $match.Item
            $s.ConfirmBuffer = ''
            if ($command -eq 'preview') { $s.Mode = 'Preview' }
            elseif ($command -eq 'confirm') { $s.Mode = 'Confirm' }
            return @{ State = $s; Command = $command }
        }
    }

    return @{ State = $s; Command = 'none' }
}
