#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Core - Native Toast Dispatcher Host (Windows PowerShell 5.1)
.DESCRIPTION
    Launched by Show-PSManagerToast with -PayloadPath. Reads the JSON payload, shows one
    Windows.UI.Notifications toast, then deletes the payload. PowerShell 7 cannot load the
    WinRT toast types, so this host runs under powershell.exe -Sta.
    The host never writes to the console and exits silently on any error.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadPath
)

try {
    if (-not (Test-Path -LiteralPath $PayloadPath)) { return }

    $raw = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $payload = $raw | ConvertFrom-Json

    $title = [System.Security.SecurityElement]::Escape([string]$payload.title)
    $message = [System.Security.SecurityElement]::Escape([string]$payload.message)

    $appId = 'PSManager'
    if ($payload.PSObject.Properties['appId'] -and $payload.appId) { $appId = [string]$payload.appId }

    # activationType/launch make the toast clickable; both are omitted without a URL, and only
    # http(s) links are allowed so a planted state file cannot make Windows run a local target.
    $toastAttributes = ''
    $launchUri = $null
    if ($payload.PSObject.Properties['url'] -and $payload.url) {
        $candidate = $null
        if ([System.Uri]::TryCreate([string]$payload.url, [System.UriKind]::Absolute, [ref]$candidate)) {
            if ($candidate.Scheme -eq [System.Uri]::UriSchemeHttp -or $candidate.Scheme -eq [System.Uri]::UriSchemeHttps) {
                $launchUri = $candidate.AbsoluteUri
            }
        }
    }
    if ($launchUri) {
        $toastAttributes = ' activationType="protocol" launch="' + [System.Security.SecurityElement]::Escape($launchUri) + '"'
    }

    # Level picks the system sound; the default sound is left to Windows otherwise.
    $audio = ''
    if ($payload.PSObject.Properties['level']) {
        switch ([string]$payload.level) {
            'Warning' { $audio = '<audio src="ms-winsoundevent:Notification.Reminder"/>' }
            'Error'   { $audio = '<audio src="ms-winsoundevent:Notification.Alarm"/>' }
        }
    }

    $xmlText = '<toast' + $toastAttributes + '><visual><binding template="ToastGeneric">' +
        '<text>' + $title + '</text><text>' + $message + '</text>' +
        '</binding></visual>' + $audio + '</toast>'

    # Prime the WinRT projections before the generic factory call.
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

    $xmlDoc = New-Object -TypeName Windows.Data.Xml.Dom.XmlDocument
    $xmlDoc.LoadXml($xmlText)

    $toast = [Windows.UI.Notifications.ToastNotification]::new($xmlDoc)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
} catch {
    # Best effort only: the in-app notification center is the guaranteed surface.
} finally {
    try {
        if (Test-Path -LiteralPath $PayloadPath) { Remove-Item -LiteralPath $PayloadPath -Force }
    } catch {}
}
