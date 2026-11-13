#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Unified Action Execution Engine (Deep Module)
.DESCRIPTION
    Encapsulates subprocess lifecycle, stream decoding, pipe task draining,
    ANSI escape sanitization, UI Dispatcher synchronization, and exit code contracts.
#>

$Script:ACTIVE_ACTION_PROCESSES = [System.Collections.Generic.Dictionary[string, object]]::new()

function Get-PSManagerCliPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $root = if ($PSScriptRoot) {
        Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    } else {
        (Get-Location).Path
    }
    return (Join-Path $root "ps-manager.ps1")
}

function Stop-PSManagerAction {
    <#
    .SYNOPSIS
        Terminates a running background action handle.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [psobject]$Handle
    )
    process {
        if ($Handle) {
            if ($Handle.Stop) {
                try { & $Handle.Stop } catch {}
            }
            if ($Handle.ExecutionId -and $Script:ACTIVE_ACTION_PROCESSES.ContainsKey($Handle.ExecutionId)) {
                $item = $Script:ACTIVE_ACTION_PROCESSES[$Handle.ExecutionId]
                $p = if ($item -is [System.Diagnostics.Process]) { $item } else { $item.Process }
                if ($p -and -not $p.HasExited) {
                    try { $p.Kill() } catch {}
                }
                $null = $Script:ACTIVE_ACTION_PROCESSES.Remove($Handle.ExecutionId)
            }
        }
    }
}

function Format-PSManagerActionOutput {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$RawText,
        [scriptblock]$OutputCallback,
        [switch]$NoAnsiStrip
    )
    if (-not $RawText) { return @() }
    $clean = if ($NoAnsiStrip) { $RawText } else { $RawText -replace '\x1b\[[0-9;]*[a-zA-Z]', '' }
    $lines = @($clean.TrimEnd() -split "`r?`n" | Where-Object { $_ -ne "" })
    if ($OutputCallback) {
        foreach ($line in $lines) {
            try { & $OutputCallback $line } catch {}
        }
    }
    return $lines
}

function Invoke-PSManagerAction {
    <#
    .SYNOPSIS
        Unified entry point for executing PSManager actions synchronously or asynchronously.
    .DESCRIPTION
        Hides process creation, UTF-8 non-locking pipe tasks, buffer deadlock prevention,
        ANSI escape stripping, WPF Dispatcher thread marshalling, and error code normalization.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Action,

        [Parameter(Position = 1)]
        [string[]]$Arguments = @(),

        [Parameter()]
        [switch]$Async,

        [Parameter()]
        [scriptblock]$OnOutput,

        [Parameter()]
        [scriptblock]$OnCompleted,

        [Parameter()]
        [int]$TimeoutSeconds = 0,

        [Parameter()]
        [switch]$NoAnsiStrip,

        [Parameter()]
        [string]$CliScriptPath
    )

    $cliPath = if ($CliScriptPath) { $CliScriptPath } else { Get-PSManagerCliPath }
    if (-not (Test-Path -LiteralPath $cliPath)) {
        $errResult = [pscustomobject]@{
            PSTypeName = 'PSManagerActionResult'
            Action     = $Action
            Success    = $false
            ExitCode   = 1
            Output     = @()
            Error      = "ps-manager.ps1 not found at: $cliPath"
            Duration   = [TimeSpan]::Zero
        }
        if ($OnCompleted) { & $OnCompleted $errResult }
        return $errResult
    }

    $psBin = (Get-Process -Id $PID).Path
    if (-not $psBin) {
        $psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
    }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cliPath, $Action) + $Arguments
    $argString = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo.FileName = $psBin
    $proc.StartInfo.Arguments = $argString
    $proc.StartInfo.UseShellExecute = $false
    $proc.StartInfo.CreateNoWindow = $true
    $proc.StartInfo.RedirectStandardOutput = $true
    $proc.StartInfo.RedirectStandardError = $true
    $proc.StartInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $proc.StartInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $startTime = [DateTime]::UtcNow
    $executionId = [guid]::NewGuid().ToString("N")

    try {
        $null = $proc.Start()
        if (-not $Async) {
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
        }
    } catch {
        $failResult = [pscustomobject]@{
            PSTypeName = 'PSManagerActionResult'
            Action     = $Action
            Success    = $false
            ExitCode   = 1
            Output     = @()
            Error      = "Failed to spawn process: $($_.Exception.Message)"
            Duration   = [TimeSpan]::Zero
        }
        $proc.Dispose()
        if ($OnCompleted) { & $OnCompleted $failResult }
        return $failResult
    }

    $state = [pscustomobject]@{
        ExecutionId = $executionId
        Action      = $Action
        Process     = $proc
        OutTask     = $outTask
        ErrTask     = $errTask
        StartTime   = $startTime
        OnOutput    = $OnOutput
        OnCompleted = $OnCompleted
        NoAnsiStrip = $NoAnsiStrip
        Timer       = $null
    }
    $Script:ACTIVE_ACTION_PROCESSES[$executionId] = $state

    # ---------------------------------------------------------------------------
    # Synchronous Execution Mode (CLI / Script / Direct tests)
    # ---------------------------------------------------------------------------
    if (-not $Async) {
        try {
            $timeoutMs = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds * 1000 } else { [System.Threading.Timeout]::Infinite }
            $exitedInTime = $proc.WaitForExit($timeoutMs)

            if (-not $exitedInTime) {
                try { $proc.Kill() } catch {}
                $outStr = if ($outTask) { $outTask.Result } else { "" }
                $errStr = if ($errTask) { $errTask.Result } else { "" }
                $combined = @($outStr, $errStr | Where-Object { $_ }) -join "`n"
                $lines = Format-PSManagerActionOutput -RawText $combined -OutputCallback $OnOutput -NoAnsiStrip:$NoAnsiStrip
                $duration = [DateTime]::UtcNow - $startTime

                $timeoutResult = [pscustomobject]@{
                    PSTypeName = 'PSManagerActionResult'
                    Action     = $Action
                    Success    = $false
                    ExitCode   = 1004
                    Output     = $lines
                    Error      = "Action '$Action' timed out after ${TimeoutSeconds}s"
                    Duration   = $duration
                }
                if ($OnCompleted) { & $OnCompleted $timeoutResult }
                return $timeoutResult
            }

            $outStr = if ($outTask) { $outTask.Result } else { "" }
            $errStr = if ($errTask) { $errTask.Result } else { "" }
            $combined = @($outStr, $errStr | Where-Object { $_ }) -join "`n"
            $lines = Format-PSManagerActionOutput -RawText $combined -OutputCallback $OnOutput -NoAnsiStrip:$NoAnsiStrip
            $exitCode = $proc.ExitCode
            $duration = [DateTime]::UtcNow - $startTime

            $result = [pscustomobject]@{
                PSTypeName = 'PSManagerActionResult'
                Action     = $Action
                Success    = ($exitCode -eq 0)
                ExitCode   = $exitCode
                Output     = $lines
                Error      = if ($exitCode -ne 0) { if ($errStr.Trim()) { $errStr.Trim() } else { "Process exited with code $exitCode" } } else { "" }
                Duration   = $duration
            }
            if ($OnCompleted) { & $OnCompleted $result }
            return $result
        } finally {
            $null = $Script:ACTIVE_ACTION_PROCESSES.Remove($executionId)
            $proc.Dispose()
        }
    }

    # ---------------------------------------------------------------------------
    # Asynchronous Execution Mode (WPF GUI / Non-blocking Dispatcher polling)
    # ---------------------------------------------------------------------------
    $table = $Script:ACTIVE_ACTION_PROCESSES
    $targetProc = $proc
    $targetId = $executionId
    $stopAction = {
        if ($targetProc -and -not $targetProc.HasExited) {
            try { $targetProc.Kill() } catch {}
        }
        if ($table -and $targetId) {
            $null = $table.Remove($targetId)
        }
    }

    $actionHandle = [pscustomobject]@{
        PSTypeName  = 'PSManagerActionHandle'
        ExecutionId = $executionId
        Action      = $Action
        StartTime   = $startTime
        Process     = $proc
        Stop        = $stopAction
    }

    # Detect active WPF Dispatcher on current thread
    $hasDispatcher = $false
    try {
        if ([System.Windows.Threading.Dispatcher]::CurrentDispatcher) {
            $hasDispatcher = $true
        }
    } catch {}

    if ($hasDispatcher) {
        $outputLines = [System.Collections.Generic.List[string]]::new()
        $state = [pscustomobject]@{
            ExecutionId = $executionId
            Action      = $Action
            Process     = $proc
            StartTime   = $startTime
            OnOutput    = $OnOutput
            OnCompleted = $OnCompleted
            NoAnsiStrip = $NoAnsiStrip
            OutputLines = $outputLines
            OutTask     = $proc.StandardOutput.ReadLineAsync()
            ErrTask     = $proc.StandardError.ReadLineAsync()
            Timer       = $null
        }
        $Script:ACTIVE_ACTION_PROCESSES[$executionId] = $state

        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $timer | Add-Member -NotePropertyName 'State' -NotePropertyValue $state -Force
        $timer.Add_Tick({
            $s = $this.State
            if (-not $s) { return }

            # Drain available stdout lines live
            while ($s.OutTask -and $s.OutTask.IsCompleted) {
                $line = $s.OutTask.Result
                if ($null -eq $line) {
                    $s.OutTask = $null
                    break
                }
                $clean = if ($s.NoAnsiStrip) { $line } else { $line -replace '\x1b\[[0-9;]*[a-zA-Z]', '' }
                if ($clean.Trim()) {
                    $s.OutputLines.Add($clean)
                    if ($s.OnOutput) {
                        try { & $s.OnOutput $clean } catch {}
                    }
                }
                $s.OutTask = $s.Process.StandardOutput.ReadLineAsync()
            }

            # Drain available stderr lines live
            while ($s.ErrTask -and $s.ErrTask.IsCompleted) {
                $errLine = $s.ErrTask.Result
                if ($null -eq $errLine) {
                    $s.ErrTask = $null
                    break
                }
                $cleanErr = if ($s.NoAnsiStrip) { $errLine } else { $errLine -replace '\x1b\[[0-9;]*[a-zA-Z]', '' }
                if ($cleanErr.Trim()) {
                    $s.OutputLines.Add($cleanErr)
                    if ($s.OnOutput) {
                        try { & $s.OnOutput $cleanErr } catch {}
                    }
                }
                $s.ErrTask = $s.Process.StandardError.ReadLineAsync()
            }

            # Check for process completion
            if ($s.Process.HasExited) {
                if ($s.OutTask) {
                    try {
                        $line = $s.OutTask.Result
                        if ($null -ne $line) {
                            $clean = if ($s.NoAnsiStrip) { $line } else { $line -replace '\x1b\[[0-9;]*[a-zA-Z]', '' }
                            if ($clean.Trim()) {
                                $s.OutputLines.Add($clean)
                                if ($s.OnOutput) { try { & $s.OnOutput $clean } catch {} }
                            }
                        }
                    } catch {}
                    $s.OutTask = $null
                }
                if ($s.ErrTask) {
                    try {
                        $errLine = $s.ErrTask.Result
                        if ($null -ne $errLine) {
                            $cleanErr = if ($s.NoAnsiStrip) { $errLine } else { $errLine -replace '\x1b\[[0-9;]*[a-zA-Z]', '' }
                            if ($cleanErr.Trim()) {
                                $s.OutputLines.Add($cleanErr)
                                if ($s.OnOutput) { try { & $s.OnOutput $cleanErr } catch {} }
                            }
                        }
                    } catch {}
                    $s.ErrTask = $null
                }
                try {
                    $remOut = $s.Process.StandardOutput.ReadToEnd()
                    if ($remOut) {
                        $remLines = Format-PSManagerActionOutput -RawText $remOut -OutputCallback $s.OnOutput -NoAnsiStrip:$s.NoAnsiStrip
                        foreach ($rl in $remLines) { $s.OutputLines.Add($rl) }
                    }
                } catch {}
                try {
                    $remErr = $s.Process.StandardError.ReadToEnd()
                    if ($remErr) {
                        $remErrLines = Format-PSManagerActionOutput -RawText $remErr -OutputCallback $s.OnOutput -NoAnsiStrip:$s.NoAnsiStrip
                        foreach ($rel in $remErrLines) { $s.OutputLines.Add($rel) }
                    }
                } catch {}
                $this.Stop()
                $null = $Script:ACTIVE_ACTION_PROCESSES.Remove($s.ExecutionId)
                $exitCode = $s.Process.ExitCode
                $duration = [DateTime]::UtcNow - $s.StartTime

                $result = [pscustomobject]@{
                    PSTypeName = 'PSManagerActionResult'
                    Action     = $s.Action
                    Success    = ($exitCode -eq 0)
                    ExitCode   = $exitCode
                    Output     = $s.OutputLines.ToArray()
                    Error      = if ($exitCode -ne 0) { "Process exited with code $exitCode" } else { "" }
                    Duration   = $duration
                }

                if ($s.OnCompleted) {
                    try { & $s.OnCompleted $result } catch {}
                }
                $s.Process.Dispose()
            }
        })
        $state.Timer = $timer
        $timer.Start()
    }

    return $actionHandle
}
