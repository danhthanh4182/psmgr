#Requires -Version 5.1
<#
.SYNOPSIS
    GUI page navigation controller and window keyboard shortcut router.
.DESCRIPTION
    Manages page visibility switching, initial window focus, nav rail checked
    events, and top-level navigation shortcuts (Ctrl+1..5, Ctrl+Tab, F6).
#>

function Show-GuiPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not $Script:GuiPages.ContainsKey($Name)) {
        throw "Unknown page: '$Name'"
    }

    foreach ($key in $Script:GuiPages.Keys) {
        $page = $Script:GuiPages[$key]
        if ($null -eq $page) { continue }
        $page.Visibility = if ($key -eq $Name) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
}

function Initialize-GuiNavigation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$Window,

        [Parameter(Mandatory = $true)]
        [hashtable]$Pages,

        [Parameter(Mandatory = $true)]
        [hashtable]$Nav,

        [Parameter(Mandatory = $true)]
        [string[]]$PageOrder,

        [System.Windows.Controls.Panel[]]$RadioPanels = @()
    )

    if ($null -eq $PageOrder -or $PageOrder.Count -eq 0) {
        throw "PageOrder cannot be empty"
    }

    foreach ($name in $PageOrder) {
        if (-not $Pages.ContainsKey($name) -or $null -eq $Pages[$name]) {
            throw "Page '$name' is missing or null in Pages hashtable"
        }
        if (-not $Nav.ContainsKey($name) -or $null -eq $Nav[$name]) {
            throw "Nav item '$name' is missing or null in Nav hashtable"
        }
    }

    $Script:GuiPages = $Pages
    $Script:GuiNav = $Nav
    $Script:GuiPageOrder = @($PageOrder)

    foreach ($name in $PageOrder) {
        $item = $Nav[$name]
        $item.Add_Checked({ Show-GuiPage -Name $this.Tag })
    }

    if ($RadioPanels) {
        foreach ($panel in $RadioPanels) {
            if ($panel) {
                Add-GuiRadioGroupKeyboard -Panel $panel
            }
        }
    }

    $Window.Add_Loaded({
        $checked = $null
        foreach ($name in $Script:GuiPageOrder) {
            $n = $Script:GuiNav[$name]
            if ($n -and $n.IsChecked) {
                $checked = $n
                break
            }
        }
        if (-not $checked -and $Script:GuiPageOrder.Count -gt 0) {
            $checked = $Script:GuiNav[$Script:GuiPageOrder[0]]
        }
        if ($checked) {
            $checked.Focus() | Out-Null
        }
    })

    $Window.Add_PreviewKeyDown({
        $keyArgs = $_
        $key = $keyArgs.Key
        $mods = [System.Windows.Input.Keyboard]::Modifiers
        if (Invoke-GuiNavigationKey -Key $key -Modifiers $mods) {
            $keyArgs.Handled = $true
        }
    })
}

function Invoke-GuiNavigationKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Input.Key]$Key,

        [System.Windows.Input.ModifierKeys]$Modifiers = [System.Windows.Input.ModifierKeys]::None
    )

    # F6 with no modifiers: focus the checked nav item (fallback first); Handled = $true.
    if ($Key -eq [System.Windows.Input.Key]::F6 -and $Modifiers -eq [System.Windows.Input.ModifierKeys]::None) {
        $checked = $null
        foreach ($name in $Script:GuiPageOrder) {
            $n = $Script:GuiNav[$name]
            if ($n -and $n.IsChecked) {
                $checked = $n
                break
            }
        }
        if (-not $checked -and $Script:GuiPageOrder.Count -gt 0) {
            $checked = $Script:GuiNav[$Script:GuiPageOrder[0]]
        }
        if ($checked) {
            $checked.Focus() | Out-Null
            return $true
        }
        return $false
    }

    # Get-GuiPageShortcut: set that nav item's IsChecked = $true, call Focus(), return $true.
    $shortcutPage = Get-GuiPageShortcut -Key $Key -Modifiers $Modifiers
    if ($shortcutPage -and $Script:GuiNav.ContainsKey($shortcutPage)) {
        $target = $Script:GuiNav[$shortcutPage]
        if ($target) {
            $target.Focus() | Out-Null
            $target.IsChecked = $true
            return $true
        }
    }

    # Get-GuiPageStep: find the checked page in $Script:GuiPageOrder (start at index 0 when none is checked),
    # compute ($index + $step + $count) % $count, set the target's IsChecked = $true, call Focus(), return $true.
    $step = Get-GuiPageStep -Key $Key -Modifiers $Modifiers
    if ($step -ne 0 -and $Script:GuiPageOrder.Count -gt 0) {
        $count = $Script:GuiPageOrder.Count
        $currentIndex = 0
        for ($i = 0; $i -lt $count; $i++) {
            $n = $Script:GuiNav[$Script:GuiPageOrder[$i]]
            if ($n -and $n.IsChecked) {
                $currentIndex = $i
                break
            }
        }
        $targetIndex = ($currentIndex + $step + $count) % $count
        $target = $Script:GuiNav[$Script:GuiPageOrder[$targetIndex]]
        if ($target) {
            $target.Focus() | Out-Null
            $target.IsChecked = $true
            return $true
        }
    }

    return $false
}
