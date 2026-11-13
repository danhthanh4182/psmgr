#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Diagnostic Logger
.DESCRIPTION
    Provides persistent file logging, level filtering, log query,
    and automatic rotation to facilitate issue triage and system health diagnostics.
#>

function Get-PSManagerLogDir {
    [CmdletBinding()]
    param(
        [string]$LogDirectory
    )

    if (-not [string]::IsNullOrEmpty($LogDirectory)) {
        $dir = $LogDirectory
    } else {
        $baseDir = if ($PSScriptRoot) {
            Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        } else {
            Join-Path $env:USERPROFILE "tools\ps-manager"
        }
        $dir = Join-Path $baseDir "logs"
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Write-PSManagerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",

        [string]$LogDirectory
    )

    try {
        $dir = Get-PSManagerLogDir -LogDirectory $LogDirectory
        $logPath = Join-Path $dir "psmgr_$((Get-Date).ToString('yyyyMMdd')).log"
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        $line = "[$timestamp] [$Level] $Message"
        # FileShare.ReadWrite: concurrent processes may log simultaneously;
        # AppendAllText's default Read-only share makes the second writer
        # throw (silently swallowed) and lose its line.
        $written = $false
        for ($attempt = 0; $attempt -lt 5 -and -not $written; $attempt++) {
            try {
                $fs = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
                try {
                    $sw.WriteLine($line)
                    $written = $true
                } finally {
                    $sw.Dispose()
                    $fs.Dispose()
                }
            } catch {
                [System.Threading.Thread]::Sleep(10)
            }
        }
    } catch {
        # Non-fatal: Never fail an operation because logging threw
    }
}

function Get-PSManagerLogs {
    [CmdletBinding()]
    param(
        [int]$Tail = 50,
        [switch]$ErrorsOnly,
        [string]$LogDirectory
    )

    $dir = Get-PSManagerLogDir -LogDirectory $LogDirectory
    if (-not (Test-Path -LiteralPath $dir)) {
        return @()
    }

    # Sort by Name (psmgr_yyyyMMdd.log) so entries read chronologically; the $Tail
    # slice then returns the newest lines, not stale entries from yesterday's file.
    $files = Get-ChildItem -LiteralPath $dir -Filter "psmgr_*.log" | Sort-Object Name
    if (-not $files -or $files.Count -eq 0) {
        return @()
    }

    $allLines = [System.Collections.Generic.List[string]]::new()
    # Read the 3 newest log files (ascending order) using non-locking shared read
    foreach ($file in ($files | Select-Object -Last 3)) {
        try {
            $stream = [System.IO.FileStream]::new($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
            try {
                while (-not $reader.EndOfStream) {
                    $allLines.Add($reader.ReadLine())
                }
            } finally {
                $reader.Dispose()
                $stream.Dispose()
            }
        } catch {}
    }

    $filtered = if ($ErrorsOnly) {
        @($allLines | Where-Object { $_ -match '\[ERROR\]|\[WARN\]' })
    } else {
        @($allLines)
    }

    if ($filtered.Count -gt $Tail) {
        return @($filtered[($filtered.Count - $Tail)..($filtered.Count - 1)])
    } else {
        return @($filtered)
    }
}

function Clear-PSManagerLogs {
    [CmdletBinding()]
    param(
        [int]$RetentionDays = 7,
        [string]$LogDirectory
    )

    $dir = Get-PSManagerLogDir -LogDirectory $LogDirectory
    if (-not (Test-Path -LiteralPath $dir)) {
        return 0
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $filesToDelete = Get-ChildItem -LiteralPath $dir -Filter "psmgr_*.log" | Where-Object { $_.LastWriteTime -le $cutoff }

    $count = 0
    foreach ($f in $filesToDelete) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force
            $count++
        } catch {}
    }
    return $count
}
