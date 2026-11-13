#Requires -Version 5.1
<#
.SYNOPSIS
    GUI keyboard interaction primitives and helpers.
.DESCRIPTION
    Provides keyboard navigation handlers for radio groups (including nav rail
    and segmented selectors) and keyboard shortcut resolvers for page navigation.
#>

function Add-GuiRadioGroupKeyboard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Controls.Panel]$Panel
    )

    $initialRadios = @($Panel.Children | Where-Object { $_ -is [System.Windows.Controls.RadioButton] })
    if ($initialRadios.Count -eq 0) {
        throw "Panel contains no RadioButton children"
    }

    $Panel.Add_PreviewKeyDown({
        $panelHost = $this
        $keyArgs = $_
        $radios = @($panelHost.Children | Where-Object { $_ -is [System.Windows.Controls.RadioButton] })
        if ($radios.Count -eq 0) { return }

        $focused = $keyArgs.OriginalSource
        if ($focused -isnot [System.Windows.Controls.RadioButton]) {
            $focused = [System.Windows.Input.Keyboard]::FocusedElement
        }
        if ($focused -isnot [System.Windows.Controls.RadioButton] -or -not ($radios -contains $focused)) {
            return
        }

        $key = $keyArgs.Key
        if ($key -eq [System.Windows.Input.Key]::Enter -or $key -eq [System.Windows.Input.Key]::Space) {
            $focused.IsChecked = $true
            $keyArgs.Handled = $true
            return
        }

        $currentIndex = $radios.IndexOf($focused)
        if ($currentIndex -lt 0) { return }
        $count = $radios.Count

        $targetIndex = -1
        if ($key -eq [System.Windows.Input.Key]::Down -or $key -eq [System.Windows.Input.Key]::Right) {
            $targetIndex = ($currentIndex + 1) % $count
        } elseif ($key -eq [System.Windows.Input.Key]::Up -or $key -eq [System.Windows.Input.Key]::Left) {
            $targetIndex = ($currentIndex - 1 + $count) % $count
        } elseif ($key -eq [System.Windows.Input.Key]::Home) {
            $targetIndex = 0
        } elseif ($key -eq [System.Windows.Input.Key]::End) {
            $targetIndex = $count - 1
        }

        if ($targetIndex -ge 0) {
            $target = $radios[$targetIndex]
            $target.Focus() | Out-Null
            $target.IsChecked = $true
            $keyArgs.Handled = $true
        }
    })
}

function Get-GuiPageShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Input.Key]$Key,

        [System.Windows.Input.ModifierKeys]$Modifiers = [System.Windows.Input.ModifierKeys]::None
    )

    if (($Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne [System.Windows.Input.ModifierKeys]::Control) {
        return $null
    }

    if ($Key -eq [System.Windows.Input.Key]::D1 -or $Key -eq [System.Windows.Input.Key]::NumPad1) { return 'overview' }
    if ($Key -eq [System.Windows.Input.Key]::D2 -or $Key -eq [System.Windows.Input.Key]::NumPad2) { return 'update' }
    if ($Key -eq [System.Windows.Input.Key]::D3 -or $Key -eq [System.Windows.Input.Key]::NumPad3) { return 'backup' }
    if ($Key -eq [System.Windows.Input.Key]::D4 -or $Key -eq [System.Windows.Input.Key]::NumPad4) { return 'health' }
    if ($Key -eq [System.Windows.Input.Key]::D5 -or $Key -eq [System.Windows.Input.Key]::NumPad5) { return 'profile' }
    if ($Key -eq [System.Windows.Input.Key]::D6 -or $Key -eq [System.Windows.Input.Key]::NumPad6) { return 'help' }

    return $null
}

function Get-GuiPageStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Input.Key]$Key,

        [System.Windows.Input.ModifierKeys]$Modifiers = [System.Windows.Input.ModifierKeys]::None
    )

    if (($Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne [System.Windows.Input.ModifierKeys]::Control) {
        return 0
    }

    if ($Key -ne [System.Windows.Input.Key]::Tab) {
        return 0
    }

    if (($Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -eq [System.Windows.Input.ModifierKeys]::Shift) {
        return -1
    }

    return 1
}
