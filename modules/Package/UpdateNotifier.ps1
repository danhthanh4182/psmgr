#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Package - PSManager Release Checker, Update Cache and Self-Update
.DESCRIPTION
    Tracks PSManager's own GitHub releases (separate from the PowerShell 7 updater in
    Updater.ps1), caches the answer for six hours, and installs a newer release only from an
    explicit user action. Downloads are verified against the release SHA256SUMS.txt before
    the installer is ever launched.
#>

$Script:PSMANAGER_REPO = 'danhthanh4182/psmgr'
$Script:PSMANAGER_API_BASE = 'https://api.github.com/repos/danhthanh4182/psmgr'
$Script:PSMANAGER_CACHE_TTL = [TimeSpan]::FromHours(6)
$Script:PSMANAGER_PACKAGE_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function ConvertTo-PSManagerVersion {
    <#
    .SYNOPSIS
        Normalizes a release tag ("v1.7.0") into a comparable [version], or $null.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Tag)

    if ([string]::IsNullOrWhiteSpace($Tag)) { return $null }
    $text = ([string]$Tag).Trim()
    if ($text.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
        $text = $text.Substring(1)
    }

    $parsed = $null
    if ([version]::TryParse($text, [ref]$parsed)) { return $parsed }

    # Pre-release / build suffixes ("1.7.0-rc1", "1.7.0+c0ffee") compare on the numeric core.
    $core = ($text -split '[-+]')[0]
    if ($core -and [version]::TryParse($core, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-PSManagerCurrentVersion {
    <#
    .SYNOPSIS
        The running module version (the manifest is the single source of truth).
    .DESCRIPTION
        Delegates to Get-PSManagerVersion in the root module so there is exactly one
        manifest lookup and one fallback behaviour.
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param()

    return [version](Get-PSManagerVersion)
}

function Resolve-PSManagerGhPath {
    <#
    .SYNOPSIS
        Locates the GitHub CLI: PATH first, then the two documented install roots.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $command = Get-Command 'gh' -ErrorAction SilentlyContinue
    if ($command -and $command.Path) { return [string]$command.Path }

    if ($env:ProgramFiles) {
        $candidate = Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    if ($env:LOCALAPPDATA) {
        $candidate = Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-PSManagerGitHubToken {
    <#
    .SYNOPSIS
        Resolves a GitHub token: explicit argument, environment, then the gh CLI session.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Token)

    if ($Token) { return $Token }
    if ($env:PSMGR_GITHUB_TOKEN) { return [string]$env:PSMGR_GITHUB_TOKEN }
    if ($env:GH_TOKEN) { return [string]$env:GH_TOKEN }
    if ($env:GITHUB_TOKEN) { return [string]$env:GITHUB_TOKEN }

    $gh = Resolve-PSManagerGhPath
    if (-not $gh) { return $null }
    try {
        $output = & $gh auth token 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            $first = @($output)[0]
            if ($first) { return ([string]$first).Trim() }
        }
    } catch {
        # Not signed in: callers fall back to an anonymous request.
    }
    return $null
}

function Get-PSManagerHttpStatus {
    <#
    .SYNOPSIS
        HTTP status code carried by an Invoke-RestMethod failure (0 when unknown).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][object]$ErrorRecord)

    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response -and $null -ne $response.StatusCode) {
            return [int]$response.StatusCode
        }
    } catch {
        # Fall through to the unknown-status sentinel.
    }
    return 0
}

function ConvertTo-PSManagerReleaseStatus {
    <#
    .SYNOPSIS
        Builds the status object from one GitHub release payload.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentVersion,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Release,

        [datetime]$CheckedAt = (Get-Date),

        [switch]$FromCache
    )

    $current = ConvertTo-PSManagerVersion -Tag $CurrentVersion
    if ($null -eq $current) { $current = Get-PSManagerCurrentVersion }

    $tag = ''
    if ($null -ne $Release -and $Release.PSObject.Properties['tag_name']) { $tag = [string]$Release.tag_name }
    $latest = ConvertTo-PSManagerVersion -Tag $tag

    $assets = @()
    if ($null -ne $Release -and $null -ne $Release.PSObject.Properties['assets'] -and $null -ne $Release.assets) {
        foreach ($asset in @($Release.assets)) {
            if ($null -eq $asset) { continue }
            $assets += [pscustomobject]@{
                Name               = [string]$asset.name
                Size               = [long]$asset.size
                BrowserDownloadUrl = [string]$asset.browser_download_url
                ApiUrl             = [string]$asset.url
            }
        }
    }

    $status = [pscustomobject]@{
        CurrentVersion  = $current.ToString()
        LatestVersion   = $null
        UpdateAvailable = $false
        Status          = 'Unknown'
        ReleaseName     = ''
        ReleaseUrl      = ''
        PublishedAt     = ''
        CheckedAt       = $CheckedAt
        FromCache       = [bool]$FromCache
        Stale           = $false
        Error           = $null
        Assets          = @($assets)
    }

    if ($null -eq $latest) {
        $status.Status = 'Error'
        $status.Error = ("Release tag '{0}' is not a semantic version." -f $tag)
        return $status
    }

    $status.LatestVersion = $latest.ToString()
    $status.ReleaseName = if ($null -ne $Release -and $Release.PSObject.Properties['name'] -and $Release.name) { [string]$Release.name } else { $tag }
    $status.ReleaseUrl = if ($null -ne $Release -and $Release.PSObject.Properties['html_url']) { [string]$Release.html_url } else { '' }
    $status.PublishedAt = if ($null -ne $Release -and $Release.PSObject.Properties['published_at'] -and $Release.published_at) { [string]$Release.published_at } else { '' }

    if ($latest -gt $current) {
        $status.UpdateAvailable = $true
        $status.Status = 'Available'
    } else {
        $status.UpdateAvailable = $false
        $status.Status = 'Current'
    }
    return $status
}

function ConvertFrom-PSManagerUpdateCache {
    <#
    .SYNOPSIS
        Rebuilds a status object from a cached updates.json document.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Cache,

        [switch]$Stale,

        [string]$ErrorMessage
    )

    $current = Get-PSManagerCurrentVersion
    $latest = ConvertTo-PSManagerVersion -Tag ([string]$Cache.latestVersion)
    $checkedAt = Get-Date
    if ($Cache.checkedAt) {
        try {
            $checkedAt = [datetime]::Parse([string]$Cache.checkedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
        } catch {
            $checkedAt = Get-Date
        }
    }

    $assets = @()
    if ($null -ne $Cache.PSObject.Properties['assets'] -and $null -ne $Cache.assets) {
        foreach ($asset in @($Cache.assets)) {
            if ($null -eq $asset) { continue }
            $assets += [pscustomobject]@{
                Name               = [string]$asset.name
                Size               = [long]$asset.size
                BrowserDownloadUrl = [string]$asset.browser_download_url
                ApiUrl             = [string]$asset.url
            }
        }
    }

    $status = [pscustomobject]@{
        CurrentVersion  = $current.ToString()
        LatestVersion   = $null
        UpdateAvailable = $false
        Status          = 'Unknown'
        ReleaseName     = if ($Cache.releaseName) { [string]$Cache.releaseName } else { '' }
        ReleaseUrl      = if ($Cache.releaseUrl) { [string]$Cache.releaseUrl } else { '' }
        PublishedAt     = if ($Cache.publishedAt) { [string]$Cache.publishedAt } else { '' }
        CheckedAt       = $checkedAt
        FromCache       = $true
        Stale           = [bool]$Stale
        Error           = $ErrorMessage
        Assets          = @($assets)
    }

    if ($null -eq $latest) {
        $status.Status = 'Unknown'
        if (-not $status.Error) { $status.Error = "Cached release version is not valid: $($Cache.latestVersion)" }
        return $status
    }

    $status.LatestVersion = $latest.ToString()
    if ($latest -gt $current) {
        $status.UpdateAvailable = $true
        $status.Status = 'Available'
    } else {
        $status.UpdateAvailable = $false
        $status.Status = 'Current'
    }
    return $status
}

function Get-PSManagerUpdateCache {
    <#
    .SYNOPSIS
        Reads updates.json; ignores a cache written for a different running version.
    #>
    [CmdletBinding()]
    param()

    $path = Get-PSManagerStatePath -Name 'updates.json'
    $cache = Read-PSManagerStateJson -Path $path
    if ($null -eq $cache) { return $null }

    $current = (Get-PSManagerCurrentVersion).ToString()
    if ($null -eq $cache.PSObject.Properties['currentVersion']) { return $null }
    if ([string]$cache.currentVersion -ne $current) { return $null }
    return $cache
}

function Get-PSManagerUpdateCacheAge {
    <#
    .SYNOPSIS
        Age of a cache document, or [TimeSpan]::MaxValue when the timestamp is unreadable.
    #>
    [CmdletBinding()]
    [OutputType([TimeSpan])]
    param([Parameter(Mandatory = $true)][object]$Cache)

    if (-not $Cache.PSObject.Properties['checkedAt'] -or -not $Cache.checkedAt) { return [TimeSpan]::MaxValue }
    try {
        $checked = [datetime]::Parse([string]$Cache.checkedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return ((Get-Date).ToUniversalTime() - $checked.ToUniversalTime())
    } catch {
        return [TimeSpan]::MaxValue
    }
}

function New-PSManagerUpdateStatus {
    <#
    .SYNOPSIS
        Synthesizes a status object for a state that has no release payload (Unknown/Error/Disabled).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Available', 'Current', 'Unknown', 'Error', 'Disabled')]
        [string]$Status,

        [string]$ErrorMessage,
        [switch]$FromCache
    )

    $current = Get-PSManagerCurrentVersion
    return [pscustomobject]@{
        CurrentVersion  = $current.ToString()
        LatestVersion   = $null
        UpdateAvailable = $false
        Status          = $Status
        ReleaseName     = ''
        ReleaseUrl      = ''
        PublishedAt     = ''
        CheckedAt       = if ($Status -in @('Unknown', 'Disabled')) { $null } else { Get-Date }
        FromCache       = [bool]$FromCache
        Stale           = $false
        Error           = if ($ErrorMessage) { $ErrorMessage } else { $null }
        Assets          = @()
    }
}

function Save-PSManagerUpdateCache {
    <#
    .SYNOPSIS
        Writes updates.json, preserving lastNotifiedVersion across every rewrite.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][object]$Status)

    $path = Get-PSManagerStatePath -Name 'updates.json'
    $existing = Read-PSManagerStateJson -Path $path
    $lastNotified = ''
    if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['lastNotifiedVersion'] -and $existing.lastNotifiedVersion) {
        $lastNotified = [string]$existing.lastNotifiedVersion
    }

    $assets = @()
    foreach ($asset in @($Status.Assets)) {
        if ($null -eq $asset) { continue }
        $assets += [ordered]@{
            name                 = [string]$asset.Name
            browser_download_url = [string]$asset.BrowserDownloadUrl
            url                  = [string]$asset.ApiUrl
            size                 = [long]$asset.Size
        }
    }

    $payload = [ordered]@{
        schemaVersion        = 1
        checkedAt            = ([datetime]$Status.CheckedAt).ToUniversalTime().ToString('o')
        currentVersion       = [string]$Status.CurrentVersion
        latestVersion        = [string]$Status.LatestVersion
        releaseName          = [string]$Status.ReleaseName
        releaseUrl           = [string]$Status.ReleaseUrl
        publishedAt          = [string]$Status.PublishedAt
        assets               = @($assets)
        lastNotifiedVersion  = $lastNotified
    }
    return (Write-PSManagerStateJson -Path $path -Value $payload)
}

function Set-PSManagerUpdateLastNotified {
    <#
    .SYNOPSIS
        Records the version the user has already been told about.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Version)

    $path = Get-PSManagerStatePath -Name 'updates.json'
    $existing = Read-PSManagerStateJson -Path $path
    if ($null -eq $existing) {
        $existing = [pscustomobject]@{ schemaVersion = 1 }
    }


    if ($null -eq $existing.PSObject.Properties['lastNotifiedVersion']) {
        $existing | Add-Member -NotePropertyName lastNotifiedVersion -NotePropertyValue $Version -Force
    } else {
        $existing.lastNotifiedVersion = $Version
    }
    return (Write-PSManagerStateJson -Path $path -Value $existing)
}

function Get-PSManagerReleaseList {
    <#
    .SYNOPSIS
        Reads recent releases, paging until app releases are found.
    .DESCRIPTION
        `/releases` returns newest first, and this repository also publishes `profile-backup-*`
        releases (about three per backup run), so the newest page can hold no version tag at all.
        Page a bounded number of times, stopping once enough `vX.Y.Z` releases were seen, so the
        check keeps working as backups accumulate.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [int]$TimeoutSec = 8,
        [int]$MaxPages = 5,
        [int]$PerPage = 100
    )

    $all = [System.Collections.Generic.List[object]]::new()
    $versioned = 0
    for ($page = 1; $page -le $MaxPages; $page++) {
        $uri = $Script:PSMANAGER_API_BASE + '/releases?per_page=' + $PerPage + '&page=' + $page
        $batch = @(Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop)
        if ($batch.Count -eq 0) { break }
        foreach ($release in $batch) {
            $all.Add($release)
            if ($null -ne $release -and $null -ne $release.PSObject.Properties['tag_name'] -and ([string]$release.tag_name -match '^(?i)v?\d+\.\d+')) {
                $versioned++
            }
        }
        if ($batch.Count -lt $PerPage) { break }
        if ($versioned -ge 1) { break }
    }
    return $all.ToArray()
}


function Get-PSManagerUpdateStatusText {
    <#
    .SYNOPSIS
        Localized label for one update status code, shared by CLI, TUI and GUI.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object]$Status,
        [string]$Language
    )

    $code = ''
    if ($null -ne $Status -and $null -ne $Status.PSObject.Properties['Status']) { $code = [string]$Status.Status }
    switch ($code) {
        'Available' { return (Get-I18nText 'update_status_available' $Language) }
        'Current'   { return (Get-I18nText 'update_status_current' $Language) }
        'Disabled'  { return (Get-I18nText 'update_status_disabled' $Language) }
        'Error'     { return (Get-I18nText 'update_status_error' $Language) }
        default     { return (Get-I18nText 'update_status_unknown' $Language) }
    }
}

function Select-PSManagerRelease {
    <#
    .SYNOPSIS
        Picks the newest published semantic-version release from a release list.
    .DESCRIPTION
        `/releases/latest` returns the newest non-prerelease release by creation date, so any
        other release published on the same repository (for example a `profile-backup-<stamp>`
        release created by `psmgr backup-cloud`) would become "latest" and break the version
        comparison for every user. Filtering the list by a `vX.Y` tag keeps the check working.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Releases)

    $bestRelease = $null
    $bestVersion = $null
    foreach ($release in @($Releases)) {
        if ($null -eq $release) { continue }
        if ($null -ne $release.PSObject.Properties['draft'] -and [bool]$release.draft) { continue }
        if ($null -ne $release.PSObject.Properties['prerelease'] -and [bool]$release.prerelease) { continue }
        $tag = ''
        if ($null -ne $release.PSObject.Properties['tag_name']) { $tag = [string]$release.tag_name }
        if ($tag -notmatch '^(?i)v?\d+\.\d+') { continue }
        $version = ConvertTo-PSManagerVersion -Tag $tag
        if ($null -eq $version) { continue }
        if ($null -eq $bestVersion -or $version -gt $bestVersion) {
            $bestVersion = $version
            $bestRelease = $release
        }
    }
    return $bestRelease
}

function Get-PSManagerUpdateStatus {
    <#
    .SYNOPSIS
        Resolves the PSManager release status, from a six-hour cache or the GitHub API.
    .DESCRIPTION
        Never throws and never installs anything. A failed check keeps the previous good
        cache (flagged Stale) so the UI can still describe the last known release.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force,
        [switch]$CacheOnly,
        [int]$TimeoutSec = 8
    )

    if ($env:PSMGR_DISABLE_UPDATE_CHECK -eq '1') {
        return (New-PSManagerUpdateStatus -Status 'Disabled')
    }

    $cache = Get-PSManagerUpdateCache
    if ($CacheOnly) {
        if ($null -ne $cache) { return (ConvertFrom-PSManagerUpdateCache -Cache $cache) }
        return (New-PSManagerUpdateStatus -Status 'Unknown' -FromCache)
    }

    if ($null -ne $cache -and -not $Force) {
        $age = Get-PSManagerUpdateCacheAge -Cache $cache
        if ($age -lt $Script:PSMANAGER_CACHE_TTL -and $age -ge [TimeSpan]::Zero) {
            return (ConvertFrom-PSManagerUpdateCache -Cache $cache)
        }
    }

    $token = Get-PSManagerGitHubToken
    $headers = @{
        'User-Agent' = 'psmgr-update-check'
        'Accept'     = 'application/vnd.github+json'
    }
    if ($token) { $headers['Authorization'] = 'Bearer ' + $token }

    try {
        $releases = Get-PSManagerReleaseList -Headers $headers -TimeoutSec $TimeoutSec
        $release = Select-PSManagerRelease -Releases $releases
        if ($null -eq $release) {
            $message = ("No semantic-version release found for {0}." -f $Script:PSMANAGER_REPO)
            if ($null -ne $cache) {
                # Keep the last good release data visible instead of erasing it.
                return (ConvertFrom-PSManagerUpdateCache -Cache $cache -Stale -ErrorMessage $message)
            }
            return (New-PSManagerUpdateStatus -Status 'Error' -ErrorMessage $message)
        }
        $status = ConvertTo-PSManagerReleaseStatus -CurrentVersion (Get-PSManagerCurrentVersion).ToString() -Release $release
        $null = Save-PSManagerUpdateCache -Status $status
        return $status
    } catch {
        $message = $_.Exception.Message
        $statusCode = Get-PSManagerHttpStatus -ErrorRecord $_
        if ($statusCode -eq 401 -or $statusCode -eq 404) {
            $message = ("GitHub returned HTTP {0}. The repository https://github.com/{1} may be private: run 'gh auth login', set PSMGR_GITHUB_TOKEN, or pass -Token to Save-PSManagerUpdatePackage." -f $statusCode, $Script:PSMANAGER_REPO)
        }
        Write-PSManagerLog -Message ("PSManager update check failed: {0}" -f $message) -Level WARN
        if ($null -ne $cache) {
            return (ConvertFrom-PSManagerUpdateCache -Cache $cache -Stale -ErrorMessage $message)
        }
        return (New-PSManagerUpdateStatus -Status 'Error' -ErrorMessage $message)
    }
}

function Add-PSManagerUpdateNotification {
    <#
    .SYNOPSIS
        Raises the update notification once per published version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Status,

        [switch]$Force
    )

    if ($null -eq $Status) { return $null }
    if (-not $Status.UpdateAvailable) { return $null }
    if ($Status.Error) { return $null }
    if (-not $Status.LatestVersion) { return $null }

    $path = Get-PSManagerStatePath -Name 'updates.json'
    $cache = Read-PSManagerStateJson -Path $path
    $lastNotified = ''
    if ($null -ne $cache -and $null -ne $cache.PSObject.Properties['lastNotifiedVersion'] -and $cache.lastNotifiedVersion) {
        $lastNotified = [string]$cache.lastNotifiedVersion
    }

    $dedupeKey = 'update-' + [string]$Status.LatestVersion
    if ($lastNotified -eq [string]$Status.LatestVersion -and -not $Force) {
        foreach ($item in @(Get-PSManagerNotifications -Limit 50)) {
            if ($item.dedupeKey -eq $dedupeKey) {
                return @{ Added = $false; Notification = $item; NativeToast = $false }
            }
        }
        return $null
    }

    $result = Add-PSManagerNotification -Kind 'Update' -Level 'Info' `
        -TitleKey 'notif_update_title' -MessageKey 'notif_update_body' `
        -Params @([string]$Status.LatestVersion, [string]$Status.CurrentVersion) `
        -Url ([string]$Status.ReleaseUrl) -DedupeKey $dedupeKey

    # Only record the "already told the user" marker when the row really exists; a rejected
    # store write must stay retryable on the next check.
    if ($result -and $result.Persisted) {
        $null = Set-PSManagerUpdateLastNotified -Version ([string]$Status.LatestVersion)
    }
    return $result
}

function Resolve-PSManagerInstallScope {
    <#
    .SYNOPSIS
        Derives the installer scope from where this module is running.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Scope)

    if ($Scope -eq 'AllUsers' -or $Scope -eq 'CurrentUser') { return $Scope }

    $root = [string]$Script:PSMANAGER_PACKAGE_ROOT
    if ($env:ProgramFiles -and $root) {
        $machineRoot = Join-Path $env:ProgramFiles 'PSManager'
        if ($root.TrimEnd('\').StartsWith($machineRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'AllUsers'
        }
    }
    return 'CurrentUser'
}

function Get-PSManagerFileSha256 {
    <#
    .SYNOPSIS
        Lowercase hex SHA-256 of a file, computed with .NET (no cmdlet formatting).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $hash = $sha.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function ConvertTo-PSManagerSafeFileName {
    <#
    .SYNOPSIS
        Reduces a release asset name to a safe leaf file name.
    .DESCRIPTION
        Release JSON is remote input: `..\`, rooted paths, drive letters, colon alternate data
        streams or separators must never reach Join-Path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)

    $leaf = [System.IO.Path]::GetFileName(([string]$Name).Replace('\', '/'))
    if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -eq '.' -or $leaf -eq '..') {
        throw ("Release asset name '{0}' is not a valid file name." -f $Name)
    }
    if ($leaf.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $leaf.Contains(':')) {
        throw ("Release asset name '{0}' contains invalid file-name characters." -f $Name)
    }
    return $leaf
}

function Test-PSManagerGitHubAssetUrl {
    <#
    .SYNOPSIS
        True when a release asset URL is an HTTPS GitHub endpoint that may receive a token.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Url)

    if (-not $Url) { return $false }
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne [System.Uri]::UriSchemeHttps) { return $false }
    $hostName = $uri.Host.ToLowerInvariant()
    return ($hostName -eq 'api.github.com' -or $hostName -eq 'github.com' -or $hostName -eq 'objects.githubusercontent.com')
}

function Save-PSManagerReleaseAsset {
    <#
    .SYNOPSIS
        Downloads one release asset, falling back to the authenticated gh CLI.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][object]$Asset,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [string]$Token,
        [string]$ReleaseName
    )

    $apiUrl = [string]$Asset.ApiUrl
    $browserUrl = [string]$Asset.BrowserDownloadUrl
    $url = if ($Token -and (Test-PSManagerGitHubAssetUrl -Url $apiUrl)) { $apiUrl } else { $browserUrl }
    if (-not (Test-PSManagerGitHubAssetUrl -Url $url)) {
        # Never download (or hand a token to) a host that is not GitHub.
        Write-PSManagerLog -Message ("Refusing non-GitHub asset URL for {0}: {1}" -f $Asset.Name, $url) -Level WARN
        return $false
    }
    $headers = @{
        'User-Agent' = 'psmgr-update-check'
        'Accept'     = 'application/octet-stream'
    }
    # The bearer token is only ever sent to the API host.
    if ($Token -and ($url -like 'https://api.github.com/*')) { $headers['Authorization'] = 'Bearer ' + $Token }

    if ($url) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $Destination -Headers $headers -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            if ((Test-Path -LiteralPath $Destination) -and (Get-Item -LiteralPath $Destination).Length -gt 0) { return $true }
        } catch {
            Write-PSManagerLog -Message ("Direct asset download failed for {0}: {1}" -f $Asset.Name, $_.Exception.Message) -Level WARN
        }
    }

    $gh = Resolve-PSManagerGhPath
    if (-not $gh) { return (Test-Path -LiteralPath $Destination) }
    $release = if ($ReleaseName) { $ReleaseName } else { 'latest' }
    try {
        & $gh release download $release --repo $Script:PSMANAGER_REPO --pattern $Asset.Name --dir $WorkDir --clobber 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination)) { return $true }
    } catch {
        Write-PSManagerLog -Message ("gh release download failed for {0}: {1}" -f $Asset.Name, $_.Exception.Message) -Level WARN
    }
    return (Test-Path -LiteralPath $Destination)
}

function Save-PSManagerUpdatePackage {
    <#
    .SYNOPSIS
        Downloads and verifies the release installer into a fresh temp directory.
    .DESCRIPTION
        The installer is never launched here. The digest from SHA256SUMS.txt must match the
        downloaded file, otherwise the installer is deleted and the call throws: there is no
        unsigned install path.
    .OUTPUTS
        Hashtable with InstallerPath, FileName, Sha256, Arguments, Version and ReleaseUrl.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][object]$Status,
        [string]$Token,
        [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope
    )

    if (-not $Status.UpdateAvailable) { throw 'No PSManager update is available to download.' }
    if ($Status.Error) { throw ("The update status carries an error: {0}" -f $Status.Error) }

    $assets = @($Status.Assets | Where-Object { $null -ne $_ })
    if ($assets.Count -eq 0) {
        $Status = Get-PSManagerUpdateStatus -Force
        if (-not $Status.UpdateAvailable) { throw 'No PSManager update is available to download.' }
        if ($Status.Error) { throw ("The update status carries an error: {0}" -f $Status.Error) }
        $assets = @($Status.Assets | Where-Object { $null -ne $_ })
        if ($assets.Count -eq 0) { throw 'The release lists no downloadable assets.' }
    }

    $installer = $assets | Where-Object { $_.Name -like 'PSManager-*-Setup.exe' } | Select-Object -First 1
    $sums = $assets | Where-Object { $_.Name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    if (-not $installer) {
        throw ("The release {0} has no PSManager-*-Setup.exe asset; cannot install an unverified build." -f $Status.LatestVersion)
    }
    if (-not $sums) {
        throw ("The release {0} has no SHA256SUMS.txt asset; refusing to install an unverified build." -f $Status.LatestVersion)
    }

    $resolvedScope = Resolve-PSManagerInstallScope -Scope $Scope
    $arguments = if ($resolvedScope -eq 'AllUsers') {
        @('/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/ALLUSERS')
    } else {
        @('/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER')
    }

    $versionText = ([string]$Status.LatestVersion) -replace '[^0-9A-Za-z\.\-]', '_'
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('psmgr-update-' + $versionText + '-' + [guid]::NewGuid().ToString('N'))
    $authToken = Get-PSManagerGitHubToken -Token $Token

    try {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $installerFile = ConvertTo-PSManagerSafeFileName -Name ([string]$installer.Name)
        $installerPath = Join-Path $workDir $installerFile
        $sumsPath = Join-Path $workDir 'SHA256SUMS.txt'

        if (-not (Save-PSManagerReleaseAsset -Asset $installer -Destination $installerPath -WorkDir $workDir -Token $authToken -ReleaseName ([string]$Status.ReleaseName))) {
            throw ("Could not download {0} from release {1}." -f $installer.Name, $Status.LatestVersion)
        }
        if (-not (Save-PSManagerReleaseAsset -Asset $sums -Destination $sumsPath -WorkDir $workDir -Token $authToken -ReleaseName ([string]$Status.ReleaseName))) {
            throw ("Could not download SHA256SUMS.txt from release {0}." -f $Status.LatestVersion)
        }

        $expected = $null
        $pattern = '^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($installerFile) + '$'
        foreach ($line in @(Get-Content -LiteralPath $sumsPath -Encoding UTF8)) {
            if ($line -match $pattern) { $expected = $Matches[1].ToLowerInvariant(); break }
        }
        if (-not $expected) {
            Remove-Item -LiteralPath $installerPath -Force
            throw ("SHA256SUMS.txt has no digest for {0}; refusing to install an unverified build." -f $installer.Name)
        }

        $actual = Get-PSManagerFileSha256 -Path $installerPath
        if ($actual -ne $expected) {
            Remove-Item -LiteralPath $installerPath -Force
            throw ("SHA-256 mismatch for {0}: expected {1}, got {2}." -f $installer.Name, $expected, $actual)
        }

        return @{
            InstallerPath = $installerPath
            FileName      = $installerFile
            Sha256        = $actual
            Arguments     = $arguments
            Version       = [string]$Status.LatestVersion
            ReleaseUrl    = [string]$Status.ReleaseUrl
        }
    } catch {
        # A failed download must not leave a partial directory behind.
        try {
            if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
        } catch {}
        throw
    }
}

function Install-PSManagerUpdate {
    <#
    .SYNOPSIS
        Downloads the verified installer and runs it (explicit user action only).
    .DESCRIPTION
        Never called by the background checker. Exit code 0 and 3010 count as success;
        3010 additionally requires a restart.
    .OUTPUTS
        Hashtable with Success, ExitCode, InstallerPath, RestartRequired and Error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [object]$Status,
        [switch]$Force,
        [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope,
        [string]$Token
    )

    $resolvedScope = Resolve-PSManagerInstallScope -Scope $Scope
    $effective = $Status
    if ($null -eq $effective) {
        $effective = Get-PSManagerUpdateStatus -Force
    }
    if ($Force) {
        # Reinstall request: bypass the availability guard, never refetch a supplied status.
        $effective = [pscustomobject]@{
            CurrentVersion  = [string]$effective.CurrentVersion
            LatestVersion   = [string]$effective.LatestVersion
            UpdateAvailable = $true
            Status          = [string]$effective.Status
            ReleaseName     = [string]$effective.ReleaseName
            ReleaseUrl      = [string]$effective.ReleaseUrl
            PublishedAt     = [string]$effective.PublishedAt
            CheckedAt       = $effective.CheckedAt
            FromCache       = [bool]$effective.FromCache
            Stale           = [bool]$effective.Stale
            Error           = $null
            Assets          = @($effective.Assets)
        }
    }

    $package = Save-PSManagerUpdatePackage -Status $effective -Token $Token -Scope $resolvedScope

    try {
        # Defense in depth: the digest is checked above, but a tampered binary that still has a
        # stale signature can be caught here. Unsigned/self-signed builds stay installable.
        try {
            $signature = Get-AuthenticodeSignature -LiteralPath $package.InstallerPath -ErrorAction Stop
            if ($signature -and [string]$signature.Status -eq 'HashMismatch') {
                throw ("Installer signature does not match its content: {0}" -f $package.InstallerPath)
            }
            if ($signature -and [string]$signature.Status -ne 'Valid') {
                Write-PSManagerLog -Message ("Installer signature status: {0}" -f $signature.Status) -Level WARN
            }
        } catch {
            if ($_.Exception.Message -like 'Installer signature*') { throw }
            Write-PSManagerLog -Message ("Signature check unavailable: {0}" -f $_.Exception.Message) -Level WARN
        }

        $process = Start-Process -FilePath $package.InstallerPath -ArgumentList $package.Arguments -PassThru
        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode
        return @{
            Success         = ($exitCode -eq 0 -or $exitCode -eq 3010)
            ExitCode        = $exitCode
            InstallerPath   = $package.InstallerPath
            RestartRequired = ($exitCode -eq 3010)
            Error           = $null
        }
    } catch {
        return @{
            Success         = $false
            ExitCode        = -1
            InstallerPath   = $package.InstallerPath
            RestartRequired = $false
            Error           = $_.Exception.Message
        }
    }
}
