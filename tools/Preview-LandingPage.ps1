#Requires -Version 5.1
<#
.SYNOPSIS
    Serves site/ locally for review, under a /psmgr/ prefix.
.DESCRIPTION
    The landing page and its 404 page use absolute /psmgr/... asset paths (that is how GitHub
    Pages serves the project site), so a plain `http.server --directory site` breaks the 404 page
    and the canonical links. This helper builds a throwaway directory that contains a `psmgr`
    junction to `site`, serves that directory on a loopback port, opens the browser, and removes
    the junction when you press Ctrl+C.

    Nothing is published, no Pages deployment is involved, and no network access is needed
    beyond the local port.
.PARAMETER Port
    Loopback port to bind. Default 8765.
.PARAMETER NoOpen
    Skip opening the default browser.
.EXAMPLE
    pwsh -NoProfile -File tools/Preview-LandingPage.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools/Preview-LandingPage.ps1 -Port 9000
#>
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765,

    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'

$siteDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'site'
if (-not (Test-Path -LiteralPath (Join-Path $siteDir 'index.html'))) {
    throw "site/index.html not found under $siteDir"
}

$python = Get-Command 'python' -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command 'py' -ErrorAction SilentlyContinue
}
if (-not $python) {
    throw 'Python was not found on PATH. Install Python, or serve the site with any static server that maps /psmgr/ to site/.'
}

function Remove-PreviewRoot {
    # A preview root can contain a junction back to site/. Remove reparse points
    # non-recursively first: Remove-Item -Recurse may follow a link and empty the repository.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if ((($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
            try { [System.IO.Directory]::Delete($child.FullName) } catch {}
        }
    }

    $linksLeft = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Where-Object { (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0 })
    if ($linksLeft.Count -gt 0) {
        Write-Warning ('Could not remove the preview link under ' + $Path + '; leaving it in place.')
        return
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

# A fixed directory keeps interrupted runs from piling up; it is purged before and after use.
$previewRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'psmgr-preview'
$linkPath = Join-Path $previewRoot 'psmgr'

try {
    Remove-PreviewRoot -Path $previewRoot
    New-Item -ItemType Directory -Path $previewRoot -Force | Out-Null
    try {
        $null = New-Item -ItemType Junction -Path $linkPath -Target $siteDir -ErrorAction Stop
    } catch {
        # Filesystems without junction support (or a locked path): fall back to a copy.
        Copy-Item -LiteralPath $siteDir -Destination $linkPath -Recurse -Force
    }

    $url = 'http://127.0.0.1:' + $Port + '/psmgr/'
    Write-Host ('Serving ' + $siteDir)
    Write-Host ('  page   ' + $url)
    Write-Host ('  expect ' + $url + ' to load; a missing path shows 404 only on a server that maps it, so open ' + $url + '404.html directly')
    Write-Host 'Press Ctrl+C to stop.'

    if (-not $NoOpen) {
        try { Start-Process $url } catch {}
    }

    $serverArgs = @('-m', 'http.server', [string]$Port, '--bind', '127.0.0.1', '--directory', $previewRoot)
    $server = Start-Process -FilePath $python.Source -ArgumentList $serverArgs -PassThru -NoNewWindow
    try {
        while (-not $server.HasExited) {
            Start-Sleep -Milliseconds 400
            $server.Refresh()
        }
    } finally {
        if (-not $server.HasExited) {
            try { Stop-Process -Id $server.Id -Force } catch {}
        }
    }
} finally {
    Remove-PreviewRoot -Path $previewRoot
    Write-Host 'Preview stopped.'
}
