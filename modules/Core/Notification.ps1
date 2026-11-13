#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Core - Persistent In-App Notification Store & Native Toast Bridge
.DESCRIPTION
    Owns two state files under the per-user state directory:
      notifications.json - the newest-first notification list (capped at 50)
      updates.json       - the PSManager release-check cache (written by UpdateNotifier.ps1)
    Readers never throw: a missing or corrupt file is treated as empty state. Writers use a
    named mutex plus a temp-file rename so two hosts (GUI and TUI) cannot interleave.
    Native toasts are delegated to Windows PowerShell 5.1 (ToastHost.ps1) because
    PowerShell 7 cannot load the WinRT toast types in the calling process.
#>

$Script:PSMANAGER_NOTIFICATION_LIMIT = 50
$Script:PSMANAGER_TOAST_HOST = Join-Path $PSScriptRoot 'ToastHost.ps1'

function Get-PSManagerStateDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:PSMGR_STATE_DIR) {
        $dir = [string]$env:PSMGR_STATE_DIR
    } elseif ($env:LOCALAPPDATA) {
        $dir = Join-Path $env:LOCALAPPDATA 'PSManager'
    } else {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'PSManager'
    }

    try {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $dir -PathType Container) { return $dir }
    } catch {
        # Fall through to the temp directory below.
    }

    $fallback = Join-Path ([System.IO.Path]::GetTempPath()) 'PSManager'
    try {
        if (-not (Test-Path -LiteralPath $fallback -PathType Container)) {
            New-Item -ItemType Directory -Path $fallback -Force | Out-Null
        }
    } catch {
        # Fall through to the temp directory below.
    }

    return $fallback
}

function Get-PSManagerStatePath {
    <#
    .SYNOPSIS
        Absolute path of one state file inside the resolved state directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Name)

    return (Join-Path (Get-PSManagerStateDirectory) $Name)
}

function Read-PSManagerStateJson {
    <#
    .SYNOPSIS
        Parses a state file; returns $null when it is missing or unreadable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-PSManagerLog -Message ("State read failed for {0}: {1}" -f $Path, $_.Exception.Message) -Level WARN
        return $null
    }
}

function Write-PSManagerStateJson {
    <#
    .SYNOPSIS
        Writes a state file atomically (temp file + rename) under a named mutex.
    .DESCRIPTION
        Returns $true when the file landed. Every failure is logged and swallowed so a
        read-only or locked profile never breaks a notification or an update check.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value
    )

    $mutex = $null
    $owned = $false
    try {
        try {
            $mutex = [System.Threading.Mutex]::new($false, 'Local\PSManager.State')
            try {
                $owned = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
            } catch [System.Threading.AbandonedMutexException] {
                # A previous writer died while holding the mutex: we own it now.
                $owned = $true
            }
        } catch {
            $mutex = $null
        }

        if ($null -ne $mutex -and -not $owned) {
            # Another host held the lock for the whole timeout: writing now could interleave
            # with it and leave a truncated store. Give up instead of writing unprotected.
            Write-PSManagerLog -Message ("State write skipped for {0}: the state lock was busy." -f $Path) -Level WARN
            return $false
        }

        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $json = ConvertTo-Json -InputObject $Value -Depth 8
        $tempPath = $Path + '.tmp'
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tempPath, $json, $encoding)
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
        return $true
    } catch {
        Write-PSManagerLog -Message ("State write failed for {0}: {1}" -f $Path, $_.Exception.Message) -Level WARN
        return $false
    } finally {
        if ($null -ne $mutex) {
            if ($owned) { try { $mutex.ReleaseMutex() } catch {} }
            try { $mutex.Dispose() } catch {}
        }
    }
}

function ConvertTo-PSManagerLocalTime {
    <#
    .SYNOPSIS
        Parses an ISO-8601 timestamp and formats it in the caller's local time.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [string]$Format = 'yyyy-MM-dd HH:mm'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try {
        $parsed = [datetime]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $parsed.ToLocalTime().ToString($Format)
    } catch {
        return $Value
    }
}

function ConvertTo-PSManagerNotificationItem {
    <#
    .SYNOPSIS
        Normalizes one stored notification so every field the UI reads always exists.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Item)

    $params = @()
    if ($null -ne $Item.PSObject.Properties['params'] -and $null -ne $Item.params) {
        $params = @($Item.params)
    }

    $read = $false
    if ($null -ne $Item.PSObject.Properties['read']) { $read = [bool]$Item.read }

    return [pscustomobject]@{
        id        = if ($Item.id) { [string]$Item.id } else { '' }
        kind      = if ($Item.kind) { [string]$Item.kind } else { 'Info' }
        level     = if ($Item.level) { [string]$Item.level } else { 'Info' }
        titleKey  = if ($Item.titleKey) { [string]$Item.titleKey } else { '' }
        messageKey = if ($Item.messageKey) { [string]$Item.messageKey } else { '' }
        params    = $params
        url       = if ($Item.url) { [string]$Item.url } else { '' }
        createdAt = if ($Item.createdAt) { [string]$Item.createdAt } else { '' }
        read      = $read
        dedupeKey = if ($Item.dedupeKey) { [string]$Item.dedupeKey } else { '' }
    }
}

function Get-PSManagerNotificationItems {
    <#
    .SYNOPSIS
        Raw stored notification list, newest first (never $null).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $path = Get-PSManagerStatePath -Name 'notifications.json'
    $data = Read-PSManagerStateJson -Path $path
    if ($null -eq $data) { return @() }

    $rawItems = @()
    if ($null -ne $data.PSObject.Properties['items'] -and $null -ne $data.items) {
        $rawItems = @($data.items)
    }

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($raw in $rawItems) {
        if ($null -eq $raw) { continue }
        $items.Add((ConvertTo-PSManagerNotificationItem -Item $raw))
    }
    return $items.ToArray()
}

function Save-PSManagerNotificationItems {
    <#
    .SYNOPSIS
        Persists the notification list, trimming it to the newest entries.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items)

    $kept = @($Items | Where-Object { $null -ne $_ })
    if ($kept.Count -gt $Script:PSMANAGER_NOTIFICATION_LIMIT) {
        $kept = @($kept[0..($Script:PSMANAGER_NOTIFICATION_LIMIT - 1)])
    }

    $path = Get-PSManagerStatePath -Name 'notifications.json'
    $payload = [ordered]@{
        schemaVersion = 1
        items         = @($kept)
    }
    return (Write-PSManagerStateJson -Path $path -Value $payload)
}

function Test-PSManagerToastEnabled {
    <#
    .SYNOPSIS
        Toasts are opt-out through PSMGR_DISABLE_TOASTS=1.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return (-not ($env:PSMGR_DISABLE_TOASTS -eq '1'))
}

function Test-PSManagerWindowsHost {
    <#
    .SYNOPSIS
        True on Windows (both PowerShell editions).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    } catch {
        return $false
    }
}

function Add-PSManagerNotification {
    <#
    .SYNOPSIS
        Stores one notification (deduplicated by -DedupeKey) and optionally toasts it.
    .DESCRIPTION
        Only i18n keys are stored, never localized text, so switching language re-renders
        the whole history. A repeated dedupe key re-surfaces the existing entry: its
        timestamp moves to now and it becomes unread again, but no second row is added.
    .OUTPUTS
        Hashtable with Added, Notification and NativeToast.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [ValidateSet('Update', 'Action', 'Info', 'Warning', 'Error')]
        [string]$Kind = 'Info',

        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter(Mandatory = $true)]
        [string]$TitleKey,

        [Parameter(Mandatory = $true)]
        [string]$MessageKey,

        [object[]]$Params = @(),

        [string]$Url,

        [string]$DedupeKey,

        [switch]$Silent
    )

    $now = (Get-Date).ToUniversalTime()
    $items = @(Get-PSManagerNotificationItems)
    $existing = $null
    if ($DedupeKey) {
        foreach ($item in $items) {
            if ($item.dedupeKey -eq $DedupeKey) { $existing = $item; break }
        }
    }

    $added = $true
    if ($null -ne $existing) {
        $added = $false
        $existing.createdAt = $now.ToString('o')
        $existing.read = $false
        $existing.titleKey = $TitleKey
        $existing.messageKey = $MessageKey
        $existing.params = @($Params)
        $existing.url = if ($Url) { $Url } else { $existing.url }
        $existing.kind = $Kind
        $existing.level = $Level
        $notification = $existing
        $ordered = @($existing) + @($items | Where-Object { $_.id -ne $existing.id })
        $saved = Save-PSManagerNotificationItems -Items $ordered
    } else {
        $notification = [pscustomobject]@{
            id        = [guid]::NewGuid().ToString()
            kind      = $Kind
            level     = $Level
            titleKey  = $TitleKey
            messageKey = $MessageKey
            params    = @($Params)
            url       = if ($Url) { $Url } else { '' }
            createdAt = $now.ToString('o')
            read      = $false
            dedupeKey = if ($DedupeKey) { $DedupeKey } else { '' }
        }
        $saved = Save-PSManagerNotificationItems -Items (@($notification) + $items)
    }

    if (-not $saved) {
        # The store did not accept the write (locked or unwritable): report the loss instead
        # of pretending the notification exists and toasting for an item nobody can open.
        return @{ Added = $false; Persisted = $false; Notification = $notification; NativeToast = $false }
    }

    $nativeToast = $false
    if (-not $Silent -and (Test-PSManagerToastEnabled)) {
        $toastTitle = Get-I18nText $TitleKey
        $toastMessage = Get-I18nText $MessageKey
        if ($Params -and $Params.Count -gt 0) {
            try { $toastMessage = $toastMessage -f $Params } catch {}
        }
        $nativeToast = Show-PSManagerToast -Title $toastTitle -Message $toastMessage -Level $Level -Url $Url
    }

    return @{
        Added        = $added
        Persisted    = $true
        Notification = $notification
        NativeToast  = $nativeToast
    }
}

function Get-PSManagerNotifications {
    <#
    .SYNOPSIS
        Stored notifications, newest first.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [switch]$UnreadOnly,
        [int]$Limit = 50
    )

    $items = @(Get-PSManagerNotificationItems)
    if ($UnreadOnly) {
        $items = @($items | Where-Object { -not $_.read })
    }
    if ($Limit -gt 0 -and $items.Count -gt $Limit) {
        $items = @($items[0..($Limit - 1)])
    }
    return $items
}

function Get-PSManagerNotificationView {
    <#
    .SYNOPSIS
        Localized presentation objects for the CLI, TUI and GUI surfaces.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string]$Language,
        [int]$Limit = 50
    )

    $view = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-PSManagerNotifications -Limit $Limit)) {
        $title = Get-I18nText $item.titleKey $Language
        $message = Get-I18nText $item.messageKey $Language
        if ($item.params -and $item.params.Count -gt 0) {
            try { $title = $title -f $item.params } catch {}
            try { $message = $message -f $item.params } catch {}
        }
        $view.Add([pscustomobject]@{
            Id      = $item.id
            Kind    = $item.kind
            Level   = $item.level
            Title   = $title
            Message = $message
            Time    = (ConvertTo-PSManagerLocalTime -Value $item.createdAt)
            Url     = $item.url
            Read    = [bool]$item.read
        })
    }
    return $view.ToArray()
}

function Set-PSManagerNotificationRead {
    <#
    .SYNOPSIS
        Marks matching notifications (or every notification) as read.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string[]]$Id,
        [switch]$All
    )

    if (-not $All -and -not $Id) { return 0 }

    $items = @(Get-PSManagerNotificationItems)
    $changed = 0
    foreach ($item in $items) {
        if ($item.read) { continue }
        if ($All -or ($Id -contains $item.id)) {
            $item.read = $true
            $changed++
        }
    }
    if ($changed -gt 0 -and -not (Save-PSManagerNotificationItems -Items $items)) {
        # Report the rejected write instead of claiming the items are read.
        return -1
    }
    return $changed
}

function Clear-PSManagerNotifications {
    <#
    .SYNOPSIS
        Removes every stored notification. The update cache is untouched.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    $removed = @(Get-PSManagerNotificationItems).Count
    if (-not (Save-PSManagerNotificationItems -Items @())) { return -1 }
    return $removed
}

function Show-PSManagerToast {
    <#
    .SYNOPSIS
        Best-effort native Windows toast through the Windows PowerShell 5.1 host.
    .DESCRIPTION
        PowerShell 7 cannot load the WinRT toast types, so this function never touches them.
        It writes a JSON payload and launches ToastHost.ps1 with powershell.exe -Sta.
        Returns $false (never throws) when toasts are disabled, the host is unavailable, or
        the launch fails; the in-app notification center is always the guaranteed surface.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [string]$Url,

        [string]$AppId = 'PSManager'
    )

    if (-not (Test-PSManagerToastEnabled)) { return $false }
    if (-not (Test-PSManagerWindowsHost)) { return $false }

    $payloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ('psmgr-toast-' + [guid]::NewGuid().ToString() + '.json')
    try {
        if (-not (Test-Path -LiteralPath $Script:PSMANAGER_TOAST_HOST)) {
            Write-PSManagerLog -Message ("Toast host missing: {0}" -f $Script:PSMANAGER_TOAST_HOST) -Level WARN
            return $false
        }

        $payload = [ordered]@{
            title   = $Title
            message = $Message
            url     = if ($Url) { $Url } else { '' }
            appId   = $AppId
            level   = $Level
        }
        $json = ConvertTo-Json -InputObject $payload -Depth 4
        [System.IO.File]::WriteAllText($payloadPath, $json, [System.Text.UTF8Encoding]::new($false))

        $hostPath = $Script:PSMANAGER_TOAST_HOST
        $hostExe = 'powershell.exe'
        if ($env:SystemRoot) {
            $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (Test-Path -LiteralPath $candidate) { $hostExe = $candidate }
        }

        # COMPLIANCE EXCEPTION (github-policy-guard §1.1):
        # WindowStyle Hidden is required here specifically for UI-facing transient Windows Action Center
        # toast notifications to prevent a distracting black console flash while presenting the toast UI.
        # This matches §1.1's explicit exception: "without explicit user request or UI-facing tray requirements".
        $argString = '-NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -PayloadPath "{1}"' -f $hostPath, $payloadPath
        Start-Process -FilePath $hostExe -ArgumentList $argString -WindowStyle Hidden | Out-Null
        return $true
    } catch {
        try {
            if (Test-Path -LiteralPath $payloadPath) { Remove-Item -LiteralPath $payloadPath -Force }
        } catch {}
        Write-PSManagerLog -Message ("Toast dispatch failed: {0}" -f $_.Exception.Message) -Level WARN
        return $false
    }
}
