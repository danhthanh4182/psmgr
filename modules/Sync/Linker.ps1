#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Safe Linker & Filesystem Bridge
.DESCRIPTION
    Provides path normalization, idempotent file comparison, and multi-tier
    safe linking (Hardlink -> Symlink -> Copy) with automatic backups.
#>

function Resolve-NormalizedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded.StartsWith("~")) {
        $userHome = $env:USERPROFILE
        if ($expanded -eq "~") {
            $expanded = $userHome
        } elseif ($expanded.StartsWith("~/") -or $expanded.StartsWith("~\")) {
            $expanded = Join-Path $userHome ($expanded.Substring(2))
        }
    }

    # Normalize directory separators
    $normalized = $expanded.Replace("/", [System.IO.Path]::DirectorySeparatorChar.ToString())
    return [System.IO.Path]::GetFullPath($normalized)
}

function Test-FileIdentical {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathA,

        [Parameter(Mandatory = $true)]
        [string]$PathB
    )

    $fullA = Resolve-NormalizedPath -Path $PathA
    $fullB = Resolve-NormalizedPath -Path $PathB

    if (-not (Test-Path -LiteralPath $fullA -PathType Leaf) -or -not (Test-Path -LiteralPath $fullB -PathType Leaf)) {
        return $false
    }

    $itemA = Get-Item -LiteralPath $fullA -ErrorAction SilentlyContinue
    $itemB = Get-Item -LiteralPath $fullB -ErrorAction SilentlyContinue

    if (-not $itemA -or -not $itemB) { return $false }
    if ($itemA.Length -ne $itemB.Length) { return $false }

    try {
        $streamA = [System.IO.File]::OpenRead($fullA)
        $streamB = [System.IO.File]::OpenRead($fullB)
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $hashA = [System.BitConverter]::ToString($sha.ComputeHash($streamA)).Replace("-", "")
            $hashB = [System.BitConverter]::ToString($sha.ComputeHash($streamB)).Replace("-", "")
            return ($hashA -eq $hashB)
        } finally {
            $streamA.Close()
            $streamA.Dispose()
            $streamB.Close()
            $streamB.Dispose()
        }
    } catch {
        return $false
    }
}

function New-SafeLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath,

        [ValidateSet("hardlink", "symlink", "copy")]
        [string]$LinkType = "hardlink"
    )

    $resolvedSource = Resolve-NormalizedPath -Path $SourcePath
    $resolvedTarget = Resolve-NormalizedPath -Path $TargetPath

    if (-not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
        return [pscustomobject]@{
            Success    = $false
            Method     = "None"
            BackupPath = $null
            Message    = "Source file does not exist: $resolvedSource"
        }
    }

    # Ensure parent directory exists
    $targetDir = Split-Path -Parent $resolvedTarget
    if (-not [string]::IsNullOrEmpty($targetDir) -and -not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    # Check if target already identical
    if (Test-Path -LiteralPath $resolvedTarget) {
        if (Test-FileIdentical -PathA $resolvedSource -PathB $resolvedTarget) {
            return [pscustomobject]@{
                Success    = $true
                Method     = "SkippedIdentical"
                BackupPath = $null
                Message    = "Target file is already identical to source"
            }
        }

        # Backup existing differing file
        $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
        $backupPath = "$resolvedTarget.bak.$timestamp"
        try {
            Move-Item -LiteralPath $resolvedTarget -Destination $backupPath -Force -ErrorAction Stop
        } catch {
            return [pscustomobject]@{
                Success    = $false
                Method     = "BackupFailed"
                BackupPath = $null
                Message    = "Failed to backup existing target file: $($_.Exception.Message)"
            }
        }
    } else {
        $backupPath = $null
    }

    # Check volume root
    $sourceRoot = [System.IO.Path]::GetPathRoot($resolvedSource)
    $targetRoot = [System.IO.Path]::GetPathRoot($resolvedTarget)
    $isCrossVolume = ($sourceRoot -ne $targetRoot)

    $methodUsed = $LinkType
    try {
        if ($LinkType -eq "hardlink") {
            if ($isCrossVolume) {
                # Hardlinks cannot cross volumes, fallback to copy
                Copy-Item -LiteralPath $resolvedSource -Destination $resolvedTarget -Force -ErrorAction Stop
                $methodUsed = "CopyFallbackVolumeMismatch"
            } else {
                try {
                    New-Item -ItemType HardLink -Path $resolvedTarget -Value $resolvedSource -Force -ErrorAction Stop | Out-Null
                    $methodUsed = "Hardlink"
                } catch {
                    Copy-Item -LiteralPath $resolvedSource -Destination $resolvedTarget -Force -ErrorAction Stop
                    $methodUsed = "CopyFallbackHardlinkError"
                }
            }
        } elseif ($LinkType -eq "symlink") {
            try {
                New-Item -ItemType SymbolicLink -Path $resolvedTarget -Value $resolvedSource -Force -ErrorAction Stop | Out-Null
                $methodUsed = "SymbolicLink"
            } catch {
                Copy-Item -LiteralPath $resolvedSource -Destination $resolvedTarget -Force -ErrorAction Stop
                $methodUsed = "CopyFallbackSymlinkError"
            }
        } else {
            Copy-Item -LiteralPath $resolvedSource -Destination $resolvedTarget -Force -ErrorAction Stop
            $methodUsed = "Copy"
        }

        if (Get-Command Write-PSManagerLog -ErrorAction SilentlyContinue) {
            Write-PSManagerLog -Message "Linked $resolvedSource -> $resolvedTarget using $methodUsed" -Level "INFO"
        }

        return [pscustomobject]@{
            Success    = $true
            Method     = $methodUsed
            BackupPath = $backupPath
            Message    = "Linked successfully using $methodUsed"
        }
    } catch {
        if (Get-Command Write-PSManagerLog -ErrorAction SilentlyContinue) {
            Write-PSManagerLog -Message "Failed to link $($resolvedSource) -> $($resolvedTarget): $($_.Exception.Message)" -Level "ERROR"
        }

        return [pscustomobject]@{
            Success    = $false
            Method     = "Failed"
            BackupPath = $backupPath
            Message    = "Failed to link file: $($_.Exception.Message)"
        }
    }
}
