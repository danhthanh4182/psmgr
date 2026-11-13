#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Unit Tests - Notification store, help catalog and PSManager self-update.
.DESCRIPTION
    Exercises the surfaces added for update notifications, the shared help catalog and the
    verified self-update pipeline. No network access is required: the release payloads are
    fixtures and the state directory is redirected through PSMGR_STATE_DIR.
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

$prevStateDir = $env:PSMGR_STATE_DIR
$prevDisableToast = $env:PSMGR_DISABLE_TOASTS
$prevDisableCheck = $env:PSMGR_DISABLE_UPDATE_CHECK

$stateDir = Join-Path $env:TEMP ("psmgr-notify-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
$env:PSMGR_STATE_DIR = $stateDir
$env:PSMGR_DISABLE_TOASTS = '1'
$env:PSMGR_DISABLE_UPDATE_CHECK = $null

Import-Module (Join-Path $RootDir "PSManager.psd1") -Force

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

function New-FakeRelease {
    param(
        [string]$Tag = 'v9.9.9',
        [string[]]$AssetNames = @()
    )
    $assets = @()
    foreach ($name in $AssetNames) {
        $assets += [pscustomobject]@{
            name                 = $name
            size                 = 123
            browser_download_url = "https://github.com/danhthanh4182/psmgr/releases/download/v$Latest/$name"
            url                  = "https://api.github.com/repos/danhthanh4182/psmgr/releases/assets/1"
        }
    }
    return [pscustomobject]@{
        tag_name     = $Tag
        name         = $Tag
        html_url     = "https://github.com/danhthanh4182/psmgr/releases/tag/$Tag"
        published_at = '2026-10-31T09:30:33Z'
        assets       = @($assets)
    }
}

function New-FakeStatus {
    param(
        [string]$Latest = '9.9.9',
        [string]$Current = ([string](Get-Module PSManager).Version),
        [string[]]$AssetNames = @()
    )
    $assets = @()
    foreach ($name in $AssetNames) {
        $assets += [pscustomobject]@{
            Name               = $name
            Size               = 123
            BrowserDownloadUrl = "https://github.com/danhthanh4182/psmgr/releases/download/v$Latest/$name"
            ApiUrl             = "https://api.github.com/repos/danhthanh4182/psmgr/releases/assets/1"
        }
    }
    return [pscustomobject]@{
        CurrentVersion  = $Current
        LatestVersion   = $Latest
        UpdateAvailable = $true
        Status          = 'Available'
        ReleaseName     = "v$Latest"
        ReleaseUrl      = "https://github.com/danhthanh4182/psmgr/releases/tag/v$Latest"
        PublishedAt     = '2026-10-31T09:30:33Z'
        CheckedAt       = (Get-Date)
        FromCache       = $false
        Stale           = $false
        Error           = $null
        Assets          = @($assets)
    }
}

try {
    $running = [string](Get-Module PSManager).Version
    $notificationsPath = Join-Path $stateDir 'notifications.json'
    $updatesPath = Join-Path $stateDir 'updates.json'

    Assert-Check -Name "Release status compares semantic versions" -TestBlock {
        $newer = ConvertTo-PSManagerReleaseStatus -CurrentVersion '1.6.2' -Release (New-FakeRelease -Tag 'v9.9.9')
        if ($newer.Status -ne 'Available' -or -not $newer.UpdateAvailable) {
            throw "Expected Available/true, got $($newer.Status)/$($newer.UpdateAvailable)"
        }
        if ($newer.LatestVersion -ne '9.9.9') { throw "Leading v not trimmed: $($newer.LatestVersion)" }

        $same = ConvertTo-PSManagerReleaseStatus -CurrentVersion '1.6.2' -Release (New-FakeRelease -Tag 'v1.6.2')
        if ($same.Status -ne 'Current' -or $same.UpdateAvailable) {
            throw "Expected Current/false, got $($same.Status)/$($same.UpdateAvailable)"
        }

        $broken = ConvertTo-PSManagerReleaseStatus -CurrentVersion '1.6.2' -Release (New-FakeRelease -Tag 'not-a-version')
        if ($broken.Status -ne 'Error' -or $broken.UpdateAvailable) {
            throw "Malformed tag should be Error/false, got $($broken.Status)/$($broken.UpdateAvailable)"
        }
        if (-not $broken.Error) { throw "Malformed tag produced no error message" }
    }

    Assert-Check -Name "Release selection ignores backup, draft and prerelease tags" -TestBlock {
        $fixture = @(
            [pscustomobject]@{ tag_name = 'profile-backup-20261030_022028'; draft = $false; prerelease = $false }
            [pscustomobject]@{ tag_name = 'v1.6.2'; draft = $false; prerelease = $false }
            [pscustomobject]@{ tag_name = 'v1.7.0'; draft = $false; prerelease = $false }
            [pscustomobject]@{ tag_name = 'v9.0.0'; draft = $false; prerelease = $true }
            [pscustomobject]@{ tag_name = 'v9.0.1'; draft = $true; prerelease = $false }
            [pscustomobject]@{ tag_name = 'v1.5.0'; draft = $false; prerelease = $false }
        )
        $module = Get-Module PSManager
        $picked = & $module { param($list) Select-PSManagerRelease -Releases $list } $fixture
        if ($null -eq $picked) { throw "Select-PSManagerRelease returned null" }
        if ($picked.tag_name -ne 'v1.7.0') { throw "Expected v1.7.0, got $($picked.tag_name)" }

        $onlyJunk = @(
            [pscustomobject]@{ tag_name = 'profile-backup-20261030_022028'; draft = $false; prerelease = $false }
            [pscustomobject]@{ tag_name = 'nightly'; draft = $false; prerelease = $false }
        )
        $none = & $module { param($list) Select-PSManagerRelease -Releases $list } $onlyJunk
        if ($null -ne $none) { throw "Non-version tags must not be selected" }
    }

    Assert-Check -Name "Cache-only status reads a cache written for the running version" -TestBlock {
        $fixture = [ordered]@{
            schemaVersion       = 1
            checkedAt           = (Get-Date).ToUniversalTime().ToString('o')
            currentVersion      = $running
            latestVersion       = '7.7.7'
            releaseName         = 'v7.7.7'
            releaseUrl          = 'https://github.com/danhthanh4182/psmgr/releases/tag/v7.7.7'
            publishedAt         = '2026-10-31T09:30:33Z'
            assets              = @()
            lastNotifiedVersion = ''
        } | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $updatesPath -Value $fixture -Encoding UTF8 -Force

        $status = Get-PSManagerUpdateStatus -CacheOnly
        if (-not $status.FromCache) { throw "Expected FromCache=true" }
        if ($status.LatestVersion -ne '7.7.7') { throw "Expected cached 7.7.7, got $($status.LatestVersion)" }
    }

    Assert-Check -Name "A network check failure preserves existing good cache as Stale with Error" -TestBlock {
        $fixture = [ordered]@{
            schemaVersion       = 1
            checkedAt           = (Get-Date).ToUniversalTime().ToString('o')
            currentVersion      = $running
            latestVersion       = '7.7.7'
            releaseName         = 'v7.7.7'
            releaseUrl          = 'https://github.com/danhthanh4182/psmgr/releases/tag/v7.7.7'
            publishedAt         = '2026-10-31T09:30:33Z'
            assets              = @()
            lastNotifiedVersion = ''
        } | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $updatesPath -Value $fixture -Encoding UTF8 -Force

        $module = Get-Module PSManager
        $origListFn = & $module { Get-Item function:Get-PSManagerReleaseList -ErrorAction SilentlyContinue }
        & $module {
            Set-Item function:Get-PSManagerReleaseList {
                param($Headers, $TimeoutSec, $MaxPages, $PerPage)
                throw "Network simulation failure: 503 Service Unavailable"
            }
        }
        try {
            $status = Get-PSManagerUpdateStatus -Force
            if (-not $status.FromCache) { throw "Expected FromCache=true" }
            if (-not $status.Stale) { throw "Expected Stale=true" }
            if ($status.LatestVersion -ne '7.7.7') { throw "Expected cached latest version 7.7.7, got $($status.LatestVersion)" }
            if ($status.Error -notmatch '503 Service Unavailable') { throw "Error message not preserved: $($status.Error)" }
        } finally {
            if ($origListFn) {
                & $module { param($fn) Set-Item function:Get-PSManagerReleaseList $fn.ScriptBlock } $origListFn
            }
        }
    }

    Assert-Check -Name "Cache TTL calculation correctly identifies fresh vs stale" -TestBlock {
        $module = Get-Module PSManager
        $now = Get-Date
        $freshCache = [pscustomobject]@{ checkedAt = $now.ToUniversalTime().ToString('o') }
        $staleCache = [pscustomobject]@{ checkedAt = $now.AddHours(-7).ToUniversalTime().ToString('o') }
        $ttl = & $module { $Script:PSMANAGER_CACHE_TTL }
        $freshAge = & $module { param($c) Get-PSManagerUpdateCacheAge -Cache $c } $freshCache
        $staleAge = & $module { param($c) Get-PSManagerUpdateCacheAge -Cache $c } $staleCache
        if ($freshAge -ge $ttl) { throw "Expected fresh age < TTL ($freshAge vs $ttl)" }
        if ($staleAge -lt $ttl) { throw "Expected stale age >= TTL ($staleAge vs $ttl)" }
    }

    Assert-Check -Name "PSMGR_DISABLE_UPDATE_CHECK=1 returns Disabled status without rewriting cache" -TestBlock {
        $env:PSMGR_DISABLE_UPDATE_CHECK = '1'
        try {
            $disabledStatus = Get-PSManagerUpdateStatus
            if ($disabledStatus.Status -ne 'Disabled') { throw "Expected Status='Disabled', got $($disabledStatus.Status)" }
            if ($disabledStatus.UpdateAvailable) { throw "UpdateAvailable must be false when disabled" }
            if ($disabledStatus.CheckedAt) { throw "CheckedAt must be null when disabled" }
        } finally {
            $env:PSMGR_DISABLE_UPDATE_CHECK = $null
        }
    }

    Assert-Check -Name "Save-PSManagerUpdatePackage verifies SHA-256 and maps scopes to arguments" -TestBlock {
        $module = Get-Module PSManager
        $testWorkDir = Join-Path $env:TEMP ('psmgr-save-unit-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testWorkDir -Force | Out-Null
        try {
            $fakeInstaller = Join-Path $testWorkDir 'PSManager-9.9.9-Setup.exe'
            [System.IO.File]::WriteAllBytes($fakeInstaller, [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8))
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $fs = [System.IO.File]::OpenRead($fakeInstaller)
            $expectedHash = ([System.BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant()
            $fs.Dispose()
            $sha.Dispose()

            $statusObj = New-FakeStatus -Latest '9.9.9' -AssetNames @('PSManager-9.9.9-Setup.exe', 'SHA256SUMS.txt')

            $origAssetFn = & $module { Get-Item function:Save-PSManagerReleaseAsset -ErrorAction SilentlyContinue }
            & $module {
                param($insPath, $hash)
                $sb = {
                    param($Asset, $Destination, $WorkDir, $Token, $ReleaseName)
                    if ($Asset.Name -like '*.exe') {
                        Copy-Item -LiteralPath $insPath -Destination $Destination -Force
                        return $true
                    } elseif ($Asset.Name -eq 'SHA256SUMS.txt') {
                        "$hash  PSManager-9.9.9-Setup.exe" | Set-Content -LiteralPath $Destination -Encoding UTF8
                        return $true
                    }
                    return $false
                }.GetNewClosure()
                Set-Item function:Save-PSManagerReleaseAsset $sb
            } $fakeInstaller $expectedHash

            # 1. Happy path: CurrentUser scope
            $pkgUser = Save-PSManagerUpdatePackage -Status $statusObj -Scope CurrentUser
            if (-not (Test-Path -LiteralPath $pkgUser.InstallerPath)) { throw "Installer path does not exist" }
            if ($pkgUser.Sha256 -ne $expectedHash) { throw "Hash mismatch" }
            if ($pkgUser.Arguments[-1] -ne '/CURRENTUSER') { throw "Expected /CURRENTUSER argument, got $($pkgUser.Arguments[-1])" }
            Remove-Item -LiteralPath (Split-Path -Parent $pkgUser.InstallerPath) -Recurse -Force -ErrorAction SilentlyContinue

            # 2. AllUsers scope
            $pkgAll = Save-PSManagerUpdatePackage -Status $statusObj -Scope AllUsers
            if ($pkgAll.Arguments[-1] -ne '/ALLUSERS') { throw "Expected /ALLUSERS argument, got $($pkgAll.Arguments[-1])" }
            Remove-Item -LiteralPath (Split-Path -Parent $pkgAll.InstallerPath) -Recurse -Force -ErrorAction SilentlyContinue

            # 3. Digest mismatch throws and cleans up installer
            & $module {
                param($insPath)
                $sb = {
                    param($Asset, $Destination, $WorkDir, $Token, $ReleaseName)
                    if ($Asset.Name -like '*.exe') {
                        Copy-Item -LiteralPath $insPath -Destination $Destination -Force
                        return $true
                    } elseif ($Asset.Name -eq 'SHA256SUMS.txt') {
                        "0000000000000000000000000000000000000000000000000000000000000000  PSManager-9.9.9-Setup.exe" | Set-Content -LiteralPath $Destination -Encoding UTF8
                        return $true
                    }
                    return $false
                }.GetNewClosure()
                Set-Item function:Save-PSManagerReleaseAsset $sb
            } $fakeInstaller

            $threwMismatch = $false
            try {
                $null = Save-PSManagerUpdatePackage -Status $statusObj -Scope CurrentUser
            } catch {
                $threwMismatch = $true
                if ($_.Exception.Message -notmatch 'SHA-256 mismatch') { throw "Wrong exception message: $($_.Exception.Message)" }
            }
            if (-not $threwMismatch) { throw "Expected SHA-256 mismatch to throw" }
        } finally {
            if ($origAssetFn) {
                & $module { param($fn) Set-Item function:Save-PSManagerReleaseAsset $fn.ScriptBlock } $origAssetFn
            }
            Remove-Item -LiteralPath $testWorkDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Assert-Check -Name "A cache from another version is ignored" -TestBlock {
        $fixture = [ordered]@{
            schemaVersion  = 1
            checkedAt      = (Get-Date).ToUniversalTime().ToString('o')
            currentVersion = '0.0.1'
            latestVersion  = '7.7.7'
            assets         = @()
        } | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $updatesPath -Value $fixture -Encoding UTF8 -Force

        $status = Get-PSManagerUpdateStatus -CacheOnly
        if ($status.Status -ne 'Unknown') { throw "Expected Unknown, got $($status.Status)" }
        if ($status.LatestVersion) { throw "Stale cache leaked latestVersion $($status.LatestVersion)" }
    }

    Assert-Check -Name "A rejected state write reports Added=false and toasts nothing" -TestBlock {
        $null = Clear-PSManagerNotifications
        # A directory squatting on the temp file makes the atomic write fail.
        $blocker = Join-Path $stateDir 'notifications.json.tmp'
        if (Test-Path -LiteralPath $blocker) { Remove-Item -LiteralPath $blocker -Recurse -Force }
        New-Item -ItemType Directory -Path $blocker -Force | Out-Null
        try {
            $result = Add-PSManagerNotification -Kind 'Info' -TitleKey 'notif_update_title' `
                -MessageKey 'notif_update_body' -Params @('1.0.0', $running) -DedupeKey 'unit-blocked'
            if ($result.Added) { throw "A notification that was not persisted must not report Added=true" }
            if ($result.NativeToast) { throw "A rejected write must not raise a toast" }
        } finally {
            Remove-Item -LiteralPath $blocker -Recurse -Force -ErrorAction SilentlyContinue
            $null = Clear-PSManagerNotifications
        }
    }

    Assert-Check -Name "Notifications persist, localize and deduplicate" -TestBlock {
        $first = Add-PSManagerNotification -Kind 'Update' -TitleKey 'notif_update_title' `
            -MessageKey 'notif_update_body' -Params @('9.9.9', $running) `
            -Url 'https://github.com/danhthanh4182/psmgr/releases' -DedupeKey 'unit-dedupe'
        if (-not $first.Added) { throw "First insert should report Added=true" }
        if (-not (Test-Path -LiteralPath $notificationsPath)) { throw "notifications.json was not written" }

        $view = @(Get-PSManagerNotificationView -Language 'en')
        if ($view.Count -ne 1) { throw "Expected 1 notification, got $($view.Count)" }
        if ($view[0].Title -eq 'notif_update_title') { throw "Title was not localized" }
        if ($view[0].Message -notmatch '9\.9\.9') { throw "Message placeholders were not expanded: $($view[0].Message)" }
        if ($view[0].Read) { throw "New notification should be unread" }
        if (@(Get-PSManagerNotifications -UnreadOnly).Count -ne 1) { throw "UnreadOnly did not return the new item" }

        $second = Add-PSManagerNotification -Kind 'Update' -TitleKey 'notif_update_title' `
            -MessageKey 'notif_update_body' -Params @('9.9.9', $running) -DedupeKey 'unit-dedupe'
        if ($second.Added) { throw "Duplicate dedupe key should report Added=false" }
        if (@(Get-PSManagerNotifications -Limit 50).Count -ne 1) { throw "Duplicate dedupe key added a second row" }

        # Action notifications format both the title and the body from the same params.
        $action = Add-PSManagerNotification -Kind 'Action' -Level 'Success' `
            -TitleKey 'notif_action_title' -MessageKey 'notif_action_body' `
            -Params @('Sync profiles', 0) -DedupeKey 'unit-action'
        if (-not $action.Added) { throw "Action notification should be added" }
        $actionView = @(Get-PSManagerNotificationView -Language 'en') | Where-Object { $_.Kind -eq 'Action' } | Select-Object -First 1
        if ($null -eq $actionView) { throw "Action notification missing from the view" }
        if ($actionView.Title -ne 'Sync profiles finished') { throw "Action title not expanded: '$($actionView.Title)'" }
        if ($actionView.Message -ne 'Exit code 0.') { throw "Action message not expanded: '$($actionView.Message)'" }
        $null = Clear-PSManagerNotifications
        $null = Add-PSManagerNotification -Kind 'Update' -TitleKey 'notif_update_title' `
            -MessageKey 'notif_update_body' -Params @('9.9.9', $running) -DedupeKey 'unit-dedupe'
    }

    Assert-Check -Name "Marking read and clearing the store" -TestBlock {
        $null = Set-PSManagerNotificationRead -All
        if (@(Get-PSManagerNotifications -UnreadOnly).Count -ne 0) { throw "Unread count should be 0 after -All" }

        $null = Clear-PSManagerNotifications
        if (@(Get-PSManagerNotifications -Limit 50).Count -ne 0) { throw "Store should be empty after Clear" }
        if (@(Get-PSManagerNotificationView).Count -ne 0) { throw "View should be empty after Clear" }
    }

    Assert-Check -Name "Update notification is raised once per version" -TestBlock {
        $status = New-FakeStatus -Latest '9.9.9' -AssetNames @('PSManager-9.9.9-Setup.exe', 'SHA256SUMS.txt')
        $first = Add-PSManagerUpdateNotification -Status $status
        if ($null -eq $first -or -not $first.Added) { throw "First update notification should be added" }
        if (@(Get-PSManagerNotifications -Limit 50).Count -ne 1) { throw "Expected exactly one notification" }

        $second = Add-PSManagerUpdateNotification -Status $status
        if (@(Get-PSManagerNotifications -Limit 50).Count -ne 1) { throw "Second call added a duplicate" }
        if ($null -ne $second -and $second.Added) { throw "Second call must not report Added=true" }

        $forced = Add-PSManagerUpdateNotification -Status $status -Force
        if (@(Get-PSManagerNotifications -Limit 50).Count -ne 1) { throw "-Force added a duplicate row" }
        if ($null -ne $forced -and $forced.NativeToast) { throw "Toasts were not suppressed by PSMGR_DISABLE_TOASTS" }

        $cache = Get-Content -LiteralPath $updatesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cache.lastNotifiedVersion -ne '9.9.9') { throw "lastNotifiedVersion not persisted: $($cache.lastNotifiedVersion)" }
    }

    Assert-Check -Name "Help catalog exposes the new commands" -TestBlock {
        $sections = @(Get-PSManagerHelpSections -Language 'en')
        if ($sections.Count -eq 0) { throw "No help sections returned" }

        $names = @()
        foreach ($section in $sections) {
            foreach ($item in $section.Items) { $names += $item.Name }
        }
        foreach ($expected in @('help', 'update-check', 'update-app', 'notifications', 'tui', 'status')) {
            if ($names -notcontains $expected) { throw "Help catalog is missing '$expected'" }
        }

        $entry = Get-PSManagerHelpEntry -Name 'update-app' -Language 'en'
        if ($null -eq $entry) { throw "Get-PSManagerHelpEntry returned null for update-app" }
        if ($entry.Usage -notmatch 'psmgr update-app') { throw "Unexpected usage line: $($entry.Usage)" }

        $prefixed = Get-PSManagerHelpEntry -Name 'psmgr update-app' -Language 'en'
        if ($null -eq $prefixed -or $prefixed.Name -ne 'update-app') { throw "A 'psmgr ' prefix was not stripped" }
        if ($null -ne (Get-PSManagerHelpEntry -Name 'no-such-command' -Language 'en')) { throw "Unknown command resolved to an entry" }
    }

    Assert-Check -Name "Help links point at the project" -TestBlock {
        $links = Get-PSManagerHelpLinks
        foreach ($key in @('Repository', 'Releases', 'Issues', 'Docs', 'License')) {
            if ($links[$key] -notmatch '^https://github\.com/danhthanh4182/psmgr') { throw "Unexpected $key URL: $($links[$key])" }
        }
    }

    Assert-Check -Name "Package download refuses a release without SHA256SUMS.txt" -TestBlock {
        $status = New-FakeStatus -Latest '9.9.9' -AssetNames @('PSManager-9.9.9-Setup.exe')
        $threw = $false
        $message = ''
        try {
            $null = Save-PSManagerUpdatePackage -Status $status
        } catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        if (-not $threw) { throw "Expected Save-PSManagerUpdatePackage to throw" }
        if ($message -notmatch 'SHA256SUMS') { throw "Error message does not name the missing digest file: $message" }
    }

    Assert-Check -Name "Package download refuses a release without an installer" -TestBlock {
        $status = New-FakeStatus -Latest '9.9.9' -AssetNames @('SHA256SUMS.txt')
        $threw = $false
        try {
            $null = Save-PSManagerUpdatePackage -Status $status
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw "Expected Save-PSManagerUpdatePackage to throw for a missing installer" }
    }
} finally {
    # Leave PSManager loaded: tests/harness.ps1 imports it once and reuses it.
    if ($null -eq $prevStateDir) { Remove-Item Env:PSMGR_STATE_DIR -ErrorAction SilentlyContinue } else { $env:PSMGR_STATE_DIR = $prevStateDir }
    if ($null -eq $prevDisableToast) { Remove-Item Env:PSMGR_DISABLE_TOASTS -ErrorAction SilentlyContinue } else { $env:PSMGR_DISABLE_TOASTS = $prevDisableToast }
    if ($null -eq $prevDisableCheck) { Remove-Item Env:PSMGR_DISABLE_UPDATE_CHECK -ErrorAction SilentlyContinue } else { $env:PSMGR_DISABLE_UPDATE_CHECK = $prevDisableCheck }
    Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ("`n[FAIL] test_update_notifier.ps1 failed with " + $failures.Count + " failure(s).") -ForegroundColor Red
    exit 1
}

Write-Host "`n[PASS] test_update_notifier.ps1 passed all checks" -ForegroundColor Green
exit 0
