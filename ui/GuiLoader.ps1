#Requires -Version 5.1
<#
.SYNOPSIS
    Loads the PSManager WPF window from the XAML files under ui\.
.DESCRIPTION
    Keeps XAML out of the PowerShell scripts so the layout can be edited (and diffed)
    as markup. The theme dictionary is merged into the window's resources, so every
    {DynamicResource} reference in the window XAML resolves against ui\PSManager.Theme.xaml.
#>

function Import-PSManagerGuiResourceDictionary {
    <#
    .SYNOPSIS
        Reads a single XAML ResourceDictionary from disk.
    .PARAMETER Path
        Absolute path to the .xaml file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "XAML resource not found: $Path"
    }

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return [System.Windows.Markup.XamlReader]::Load(
        [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($text)))
}

function Add-PSManagerGuiTheme {
    <#
    .SYNOPSIS
        Merges the theme dictionary into a window's resources.
    .PARAMETER Window
        The window whose resources receive the dictionary.
    .PARAMETER ThemePath
        Absolute path to PSManager.Theme.xaml.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$Window,
        [Parameter(Mandatory = $true)]
        [string]$ThemePath
    )

    $dictionary = Import-PSManagerGuiResourceDictionary -Path $ThemePath
    $null = $Window.Resources.MergedDictionaries.Add($dictionary)
}

function New-PSManagerGuiWindow {
    <#
    .SYNOPSIS
        Loads the main window XAML and attaches the theme dictionary.
    .PARAMETER XamlPath
        Absolute path to PSManager.MainWindow.xaml.
    .PARAMETER ThemePath
        Absolute path to PSManager.Theme.xaml.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$XamlPath,
        [Parameter(Mandatory = $true)]
        [string]$ThemePath
    )

    $window = Import-PSManagerGuiResourceDictionary -Path $XamlPath
    if ($window -isnot [System.Windows.Window]) {
        throw "Expected a Window in $XamlPath, got $($window.GetType().FullName)"
    }
    Add-PSManagerGuiTheme -Window $window -ThemePath $ThemePath
    return $window
}
