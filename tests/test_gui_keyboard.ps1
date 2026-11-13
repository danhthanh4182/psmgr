#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Unit Tests - GUI keyboard navigation and accessibility.
.DESCRIPTION
    Guards GUI keyboard navigation:
      1. Radio helper on a synthetic group (Enter, Space, arrows, wrap, Home/End).
      2. Navigation wiring without a visible window.
      3. Real-window keyboard behavior (initial focus, Tab reachability, Down/Enter, wrap, F6).
      4. Segmented selectors (source and channel arrows/Enter).
      5. Shortcut mapping (Ctrl+1..5, Ctrl+Tab, Ctrl+Shift+Tab).
      6. Focusability / focus-visual audit (ButtonBase, TextBoxBase, GridSplitter).
#>

$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $procPath = (Get-Process -Id $PID).Path
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"' + $PSCommandPath + '"'))
    $child = Start-Process -FilePath $procPath -ArgumentList $relaunchArgs -NoNewWindow -Wait -PassThru
    exit $child.ExitCode
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$XamlDir = Join-Path $RootDir 'ui'

Import-Module (Join-Path $RootDir 'PSManager.psd1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

. (Join-Path $XamlDir 'GuiLoader.ps1')
. (Join-Path $XamlDir 'GuiKeyboard.ps1')
. (Join-Path $XamlDir 'GuiNavigation.ps1')

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

function Send-GuiKey {
    param(
        [Parameter(Mandatory = $true)][System.Windows.UIElement]$Target,
        [Parameter(Mandatory = $true)][System.Windows.Input.Key]$Key,
        [System.Windows.RoutedEvent]$RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
    )
    $source = [System.Windows.PresentationSource]::FromVisual($Target)
    $keyArgs = [System.Windows.Input.KeyEventArgs]::new(
        [System.Windows.Input.Keyboard]::PrimaryDevice, $source, 0, $Key)
    $keyArgs.RoutedEvent = $RoutedEvent
    $Target.RaiseEvent($keyArgs)
    return $keyArgs.Handled
}

function Get-LogicalDescendant {
    param([object]$Root)
    $results = [System.Collections.Generic.List[object]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }
        $results.Add($node)
        if ($node -is [System.Windows.Controls.Panel]) {
            foreach ($child in $node.Children) { $stack.Push($child) }
        } elseif ($node -is [System.Windows.Controls.Decorator]) {
            $stack.Push($node.Child)
        } elseif ($node -is [System.Windows.Controls.ContentControl]) {
            $stack.Push($node.Content)
        } elseif ($node -is [System.Windows.Controls.ItemsControl]) {
            foreach ($item in $node.Items) { $stack.Push($item) }
        }
    }
    return $results
}

# --- Check 1: Radio helper on a synthetic group ---
Assert-Check -Name "Radio helper on a synthetic group" -TestBlock {
    $win = [System.Windows.Window]::new()
    $win.Left = -10000
    $win.Top = -10000
    $win.Width = 300
    $win.Height = 200

    $panel = [System.Windows.Controls.StackPanel]::new()
    $r1 = [System.Windows.Controls.RadioButton]::new()
    $r1.Content = "R1"
    $r1.GroupName = "TestGroup"
    $r1.IsChecked = $true

    $r2 = [System.Windows.Controls.RadioButton]::new()
    $r2.Content = "R2"
    $r2.GroupName = "TestGroup"

    $r3 = [System.Windows.Controls.RadioButton]::new()
    $r3.Content = "R3"
    $r3.GroupName = "TestGroup"

    $panel.Children.Add($r1) | Out-Null
    $panel.Children.Add($r2) | Out-Null
    $panel.Children.Add($r3) | Out-Null
    $win.Content = $panel

    Add-GuiRadioGroupKeyboard -Panel $panel

    $win.Show()
    $win.UpdateLayout()

    try {
        $r1.Focus() | Out-Null

        # Down selects and focuses R2
        $h = Send-GuiKey -Target $r1 -Key ([System.Windows.Input.Key]::Down)
        if (-not $h) { throw "Down on R1 was not handled" }
        if (-not $r2.IsChecked) { throw "R2 should be checked after Down from R1" }
        if (-not $r2.IsFocused) { throw "R2 should be focused after Down from R1" }

        # Down selects and focuses R3
        $h = Send-GuiKey -Target $r2 -Key ([System.Windows.Input.Key]::Down)
        if (-not $h) { throw "Down on R2 was not handled" }
        if (-not $r3.IsChecked) { throw "R3 should be checked after Down from R2" }
        if (-not $r3.IsFocused) { throw "R3 should be focused after Down from R2" }

        # Down wraps to R1
        $h = Send-GuiKey -Target $r3 -Key ([System.Windows.Input.Key]::Down)
        if (-not $h) { throw "Down on R3 was not handled" }
        if (-not $r1.IsChecked) { throw "R1 should be checked after Down wrap from R3" }
        if (-not $r1.IsFocused) { throw "R1 should be focused after Down wrap from R3" }

        # Up wraps to R3
        $h = Send-GuiKey -Target $r1 -Key ([System.Windows.Input.Key]::Up)
        if (-not $h) { throw "Up on R1 was not handled" }
        if (-not $r3.IsChecked) { throw "R3 should be checked after Up wrap from R1" }
        if (-not $r3.IsFocused) { throw "R3 should be focused after Up wrap from R1" }

        # Home selects R1
        $h = Send-GuiKey -Target $r3 -Key ([System.Windows.Input.Key]::Home)
        if (-not $h) { throw "Home on R3 was not handled" }
        if (-not $r1.IsChecked) { throw "R1 should be checked after Home" }
        if (-not $r1.IsFocused) { throw "R1 should be focused after Home" }

        # End selects R3
        $h = Send-GuiKey -Target $r1 -Key ([System.Windows.Input.Key]::End)
        if (-not $h) { throw "End on R1 was not handled" }
        if (-not $r3.IsChecked) { throw "R3 should be checked after End" }
        if (-not $r3.IsFocused) { throw "R3 should be focused after End" }

        # Focus R2 while R1 is checked; Enter checks R2
        $r1.IsChecked = $true
        $r2.Focus() | Out-Null
        $h = Send-GuiKey -Target $r2 -Key ([System.Windows.Input.Key]::Enter)
        if (-not $h) { throw "Enter on R2 was not handled" }
        if (-not $r2.IsChecked) { throw "R2 should be checked after Enter" }

        # Space PreviewKeyDown+KeyUp on unchecked R3 checks R3
        $r3.Focus() | Out-Null
        $hDown = Send-GuiKey -Target $r3 -Key ([System.Windows.Input.Key]::Space) -RoutedEvent ([System.Windows.Input.Keyboard]::PreviewKeyDownEvent)
        $hUp = Send-GuiKey -Target $r3 -Key ([System.Windows.Input.Key]::Space) -RoutedEvent ([System.Windows.Input.Keyboard]::KeyUpEvent)
        if (-not $hDown) { throw "Space PreviewKeyDown on R3 was not handled" }
        if (-not $r3.IsChecked) { throw "R3 should be checked after Space" }
    } finally {
        $win.Close()
    }
}

# --- Checks 2, 3, 4, 6 on real window instance ---
$realWin = New-PSManagerGuiWindow -XamlPath (Join-Path $XamlDir 'PSManager.MainWindow.xaml') `
                              -ThemePath (Join-Path $XamlDir 'PSManager.Theme.xaml')

try {
    $navOverview = $realWin.FindName('NavOverview')
    $navUpdate   = $realWin.FindName('NavUpdate')
    $navBackup   = $realWin.FindName('NavBackup')
    $navHealth   = $realWin.FindName('NavHealth')
    $navProfile  = $realWin.FindName('NavProfile')
    $navHelp     = $realWin.FindName('NavHelp')

    $pageOverview = $realWin.FindName('PageOverview')
    $pageUpdate   = $realWin.FindName('PageUpdate')
    $pageBackup   = $realWin.FindName('PageBackup')
    $pageHealth   = $realWin.FindName('PageHealth')
    $pageProfile  = $realWin.FindName('PageProfile')
    $pageHelp     = $realWin.FindName('PageHelp')

    $btnRefresh    = $realWin.FindName('BtnRefresh')
    $btnSrcWinget  = $realWin.FindName('BtnSrcWinget')
    $btnSrcMsstore = $realWin.FindName('BtnSrcMsstore')
    $btnSrcGithub  = $realWin.FindName('BtnSrcGithub')
    $btnChStable   = $realWin.FindName('BtnChStable')
    $btnChPreview  = $realWin.FindName('BtnChPreview')
    $btnChLts      = $realWin.FindName('BtnChLts')
    $txtLogFilter  = $realWin.FindName('TxtLogFilter')
    $rtbConsoleLog = $realWin.FindName('RtbConsoleLog')

    $pages = @{
        'overview' = $pageOverview
        'update'   = $pageUpdate
        'backup'   = $pageBackup
        'health'   = $pageHealth
        'profile'  = $pageProfile
        'help'     = $pageHelp
    }
    $nav = @{
        'overview' = $navOverview
        'update'   = $navUpdate
        'backup'   = $navBackup
        'health'   = $navHealth
        'profile'  = $navProfile
        'help'     = $navHelp
    }
    $pageOrder = @('overview', 'update', 'backup', 'health', 'profile', 'help')
    $radioPanels = @($navOverview.Parent, $btnSrcWinget.Parent, $btnChStable.Parent)

    # --- Check 2: Navigation wiring without a visible window ---
    Assert-Check -Name "Navigation wiring without a visible window" -TestBlock {
        Initialize-GuiNavigation -Window $realWin -Pages $pages -Nav $nav -PageOrder $pageOrder -RadioPanels $radioPanels

        # Set navUpdate checked; PageUpdate visible, all others collapsed
        $navUpdate.IsChecked = $true
        if ($pageUpdate.Visibility -ne [System.Windows.Visibility]::Visible) {
            throw "PageUpdate should be Visible"
        }
        if ($pageOverview.Visibility -ne [System.Windows.Visibility]::Collapsed) {
            throw "PageOverview should be Collapsed"
        }
        if ($pageBackup.Visibility -ne [System.Windows.Visibility]::Collapsed) {
            throw "PageBackup should be Collapsed"
        }
        if ($pageHealth.Visibility -ne [System.Windows.Visibility]::Collapsed) {
            throw "PageHealth should be Collapsed"
        }
        if ($pageProfile.Visibility -ne [System.Windows.Visibility]::Collapsed) {
            throw "PageProfile should be Collapsed"
        }

        # Reset navOverview checked before check 3
        $navOverview.IsChecked = $true
    }

    # --- Check 3: Real-window keyboard behavior ---
    Assert-Check -Name "Real-window keyboard behavior" -TestBlock {
        $realWin.Left = -10000
        $realWin.Top = -10000
        $realWin.Show()
        $realWin.UpdateLayout()

        foreach ($navName in @('NavOverview', 'NavUpdate', 'NavBackup', 'NavHealth', 'NavProfile', 'NavHelp')) {
            $navItem = $realWin.FindName($navName)
            $label = $realWin.FindName('Txt' + $navName)
            $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($navItem)
            if ($peer.GetName() -ne $label.Text) {
                throw "$navName accessible name must match its localized label"
            }
        }

        $source = [System.Windows.PresentationSource]::FromVisual($navOverview)
        if ($null -eq $source) { throw "PresentationSource for NavOverview is null" }

        # Initial focus is NavOverview (the checked item)
        if (-not $navOverview.IsFocused) {
            throw "Initial focus should be on NavOverview, got: $([System.Windows.Input.Keyboard]::FocusedElement)"
        }

        # From NavOverview, MoveFocus(Next) reaches NavUpdate (Tab reachability)
        $moved = $navOverview.MoveFocus([System.Windows.Input.TraversalRequest]::new([System.Windows.Input.FocusNavigationDirection]::Next))
        if (-not $moved) { throw "MoveFocus(Next) failed" }
        if (-not $navUpdate.IsFocused) {
            throw "MoveFocus(Next) should reach NavUpdate, got: $([System.Windows.Input.Keyboard]::FocusedElement)"
        }

        # Send Down on NavOverview: NavUpdate checked, PageUpdate visible, focus NavUpdate
        $navOverview.Focus() | Out-Null
        $h = Send-GuiKey -Target $navOverview -Key ([System.Windows.Input.Key]::Down)
        if (-not $h) { throw "Down on NavOverview was not handled" }
        if (-not $navUpdate.IsChecked) { throw "NavUpdate should be checked after Down" }
        if ($pageUpdate.Visibility -ne [System.Windows.Visibility]::Visible) { throw "PageUpdate should be Visible" }
        if (-not $navUpdate.IsFocused) { throw "NavUpdate should be focused" }

        # Focus NavBackup (unchecked) and send Enter: NavBackup checked and PageBackup visible
        $navBackup.Focus() | Out-Null
        $h = Send-GuiKey -Target $navBackup -Key ([System.Windows.Input.Key]::Enter)
        if (-not $h) { throw "Enter on NavBackup was not handled" }
        if (-not $navBackup.IsChecked) { throw "NavBackup should be checked after Enter" }
        if ($pageBackup.Visibility -ne [System.Windows.Visibility]::Visible) { throw "PageBackup should be Visible" }

        # Focus NavProfile and send Down: reaches NavHelp (the last rail item)
        $navProfile.Focus() | Out-Null
        $h = Send-GuiKey -Target $navProfile -Key ([System.Windows.Input.Key]::Down)
        if (-not $h) { throw "Down on NavProfile was not handled" }
        if (-not $navHelp.IsChecked) { throw "NavHelp should be checked after Down from NavProfile" }
        if (-not $navHelp.IsFocused) { throw "NavHelp should be focused after Down from NavProfile" }

        # Focus NavHelp and send Down: wraps to NavOverview
        $navHelp.Focus() | Out-Null
        $h = Send-GuiKey -Target $navHelp -Key ([System.Windows.Input.Key]::Down)
        if (-not $h) { throw "Down on NavHelp was not handled" }
        if (-not $navOverview.IsChecked) { throw "NavOverview should be checked after Down wrap" }
        if (-not $navOverview.IsFocused) { throw "NavOverview should be focused after Down wrap" }

        # Focus a page button and send F6 via a PreviewKeyDownEvent: focus returns to the checked nav item
        $btnSrcWinget.Focus() | Out-Null
        $f6Args = [System.Windows.Input.KeyEventArgs]::new(
            [System.Windows.Input.Keyboard]::PrimaryDevice,
            [System.Windows.PresentationSource]::FromVisual($realWin),
            0,
            [System.Windows.Input.Key]::F6)
        $f6Args.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
        $realWin.RaiseEvent($f6Args)
        if (-not $f6Args.Handled) { throw "F6 was not handled" }
        if (-not $navOverview.IsFocused) {
            throw "Focus should return to NavOverview on F6, got: $([System.Windows.Input.Keyboard]::FocusedElement)"
        }

        # Direct navigation key routing (shortcuts & sequential cycling)
        $ctrl = [System.Windows.Input.ModifierKeys]::Control
        $shift = [System.Windows.Input.ModifierKeys]::Shift
        $ctrlShift = [System.Windows.Input.ModifierKeys]($ctrl.value__ -bor $shift.value__)

        # Ctrl+3 routes to Backup page
        $hCtrl3 = Invoke-GuiNavigationKey -Key ([System.Windows.Input.Key]::D3) -Modifiers $ctrl
        if (-not $hCtrl3) { throw "Invoke-GuiNavigationKey for Ctrl+3 should be handled" }
        if (-not $navBackup.IsChecked) { throw "NavBackup should be checked after Ctrl+3" }
        if (-not $navBackup.IsFocused) { throw "NavBackup should be focused after Ctrl+3" }
        if ($pageBackup.Visibility -ne [System.Windows.Visibility]::Visible) { throw "PageBackup should be Visible after Ctrl+3" }

        # Ctrl+Tab cycles to Health page
        $hCtrlTab = Invoke-GuiNavigationKey -Key ([System.Windows.Input.Key]::Tab) -Modifiers $ctrl
        if (-not $hCtrlTab) { throw "Invoke-GuiNavigationKey for Ctrl+Tab should be handled" }
        if (-not $navHealth.IsChecked) { throw "NavHealth should be checked after Ctrl+Tab" }
        if (-not $navHealth.IsFocused) { throw "NavHealth should be focused after Ctrl+Tab" }
        if ($pageHealth.Visibility -ne [System.Windows.Visibility]::Visible) { throw "PageHealth should be Visible after Ctrl+Tab" }

        # Ctrl+Shift+Tab cycles back to Backup page
        $hCtrlShiftTab = Invoke-GuiNavigationKey -Key ([System.Windows.Input.Key]::Tab) -Modifiers $ctrlShift
        if (-not $hCtrlShiftTab) { throw "Invoke-GuiNavigationKey for Ctrl+Shift+Tab should be handled" }
        if (-not $navBackup.IsChecked) { throw "NavBackup should be checked after Ctrl+Shift+Tab" }
        if (-not $navBackup.IsFocused) { throw "NavBackup should be focused after Ctrl+Shift+Tab" }

        # Unhandled key returns false
        $hUnused = Invoke-GuiNavigationKey -Key ([System.Windows.Input.Key]::A) -Modifiers ([System.Windows.Input.ModifierKeys]::None)
        if ($hUnused) { throw "Unhandled key should return false" }
    }

    # --- Check 4: Segmented selectors ---
    Assert-Check -Name "Segmented selectors" -TestBlock {
        $navUpdate.IsChecked = $true
        $realWin.UpdateLayout()
        $btnSrcWinget.Focus() | Out-Null
        $btnSrcWinget.IsChecked = $true
        # send Down -> BtnSrcMsstore checked
        $h = Send-GuiKey -Target $btnSrcWinget -Key ([System.Windows.Input.Key]::Down)
        if (-not $h) { throw "Down on BtnSrcWinget was not handled" }
        if (-not $btnSrcMsstore.IsChecked) { throw "BtnSrcMsstore should be checked" }

        # send Down -> BtnSrcGithub checked
        $h = Send-GuiKey -Target $btnSrcMsstore -Key ([System.Windows.Input.Key]::Down)
        if (-not $h) { throw "Down on BtnSrcMsstore was not handled" }
        if (-not $btnSrcGithub.IsChecked) { throw "BtnSrcGithub should be checked" }

        # focus BtnChStable, send End -> BtnChLts checked
        $btnChStable.Focus() | Out-Null
        $btnChStable.IsChecked = $true
        $h = Send-GuiKey -Target $btnChStable -Key ([System.Windows.Input.Key]::End)
        if (-not $h) { throw "End on BtnChStable was not handled" }
        if (-not $btnChLts.IsChecked) { throw "BtnChLts should be checked after End" }

        # focus BtnChLts (checked) and send Enter -> stays checked and handled
        $btnChLts.Focus() | Out-Null
        $h = Send-GuiKey -Target $btnChLts -Key ([System.Windows.Input.Key]::Enter)
        if (-not $h) { throw "Enter on BtnChLts was not handled" }
        if (-not $btnChLts.IsChecked) { throw "BtnChLts should remain checked after Enter" }
    }

    # --- Check 6: Focusability / focus-visual audit ---
    Assert-Check -Name "Focusability / focus-visual audit" -TestBlock {
        $allElements = Get-LogicalDescendant -Root $realWin
        $focusableCandidates = @($allElements | Where-Object {
            $_ -is [System.Windows.Controls.Primitives.ButtonBase] -or
            $_ -is [System.Windows.Controls.Primitives.TextBoxBase] -or
            $_ -is [System.Windows.Controls.GridSplitter]
        })
        foreach ($elem in $focusableCandidates) {
            if (-not $elem.Focusable) {
                throw "Element $($elem.Name) ($($elem.GetType().Name)) Focusable is not true"
            }
            if (-not [System.Windows.Input.KeyboardNavigation]::GetIsTabStop($elem)) {
                throw "Element $($elem.Name) ($($elem.GetType().Name)) IsTabStop is not true"
            }
        }

        $auditNamed = @($navOverview, $btnSrcWinget, $btnRefresh, $txtLogFilter, $rtbConsoleLog)
        foreach ($elem in $auditNamed) {
            if ($null -eq $elem.FocusVisualStyle) {
                throw "Element $($elem.Name) has null FocusVisualStyle"
            }
        }

        $splitters = @($allElements | Where-Object { $_ -is [System.Windows.Controls.GridSplitter] })
        if ($splitters.Count -eq 0) { throw "No GridSplitter found in window" }
        foreach ($sp in $splitters) {
            if ($null -eq $sp.FocusVisualStyle) {
                throw "GridSplitter has null FocusVisualStyle"
            }
        }
    }
} finally {
    if ($realWin) { $realWin.Close() }
}

# --- Check 5: Shortcut mapping ---
Assert-Check -Name "Shortcut mapping" -TestBlock {
    $ctrl = [System.Windows.Input.ModifierKeys]::Control
    $none = [System.Windows.Input.ModifierKeys]::None
    $shift = [System.Windows.Input.ModifierKeys]::Shift
    $ctrlShift = [System.Windows.Input.ModifierKeys]($ctrl.value__ -bor $shift.value__)

    # D1..D5 and NumPad1..NumPad5 with Control
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::D1) -Modifiers $ctrl) -ne 'overview') { throw "D1 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::NumPad1) -Modifiers $ctrl) -ne 'overview') { throw "NumPad1 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::D2) -Modifiers $ctrl) -ne 'update') { throw "D2 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::NumPad2) -Modifiers $ctrl) -ne 'update') { throw "NumPad2 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::D3) -Modifiers $ctrl) -ne 'backup') { throw "D3 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::NumPad3) -Modifiers $ctrl) -ne 'backup') { throw "NumPad3 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::D4) -Modifiers $ctrl) -ne 'health') { throw "D4 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::NumPad4) -Modifiers $ctrl) -ne 'health') { throw "NumPad4 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::D5) -Modifiers $ctrl) -ne 'profile') { throw "D5 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::NumPad5) -Modifiers $ctrl) -ne 'profile') { throw "NumPad5 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::D6) -Modifiers $ctrl) -ne 'help') { throw "D6 failed" }
    if ((Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::NumPad6) -Modifiers $ctrl) -ne 'help') { throw "NumPad6 failed" }

    # Without Control, returns null
    if ($null -ne (Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::D1) -Modifiers $none)) { throw "D1 without Ctrl should be null" }
    if ($null -ne (Get-GuiPageShortcut -Key ([System.Windows.Input.Key]::D1) -Modifiers $shift)) { throw "D1 with Shift should be null" }

    # Get-GuiPageStep
    if ((Get-GuiPageStep -Key ([System.Windows.Input.Key]::Tab) -Modifiers $ctrl) -ne 1) { throw "Ctrl+Tab should be 1" }
    if ((Get-GuiPageStep -Key ([System.Windows.Input.Key]::Tab) -Modifiers $ctrlShift) -ne -1) { throw "Ctrl+Shift+Tab should be -1" }
    if ((Get-GuiPageStep -Key ([System.Windows.Input.Key]::Tab) -Modifiers $none) -ne 0) { throw "Plain Tab should be 0" }
    if ((Get-GuiPageStep -Key ([System.Windows.Input.Key]::D1) -Modifiers $ctrl) -ne 0) { throw "Ctrl+D1 should be 0" }
}

if ($failures.Count -gt 0) {
    Write-Host ("`nGUI keyboard tests FAILED: " + $failures.Count + " failure(s)") -ForegroundColor Red
    exit 1
}

Write-Host "test_gui_keyboard.ps1 passed all checks" -ForegroundColor Green
exit 0
