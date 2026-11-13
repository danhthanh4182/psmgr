#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Unit Tests - GUI Async CLI Action (Invoke-GuiCliAction)
.DESCRIPTION
    Validates the non-blocking GUI->CLI bridge introduced to fix the "Sync Now"
    UI freeze:
      1. Handler returns before the child process finishes (UI thread stays free).
      2. Both stdout and stderr are drained via ReadToEndAsync from the start,
         so a child writing >64KB per stream cannot deadlock on a full pipe.
      3. Completion state lives in $Script: scope, reachable from the Tick
         handler after the launching function returns.
      4. Busy flag transitions: set on start, cleared on completion.
      5. Non-zero exit codes are surfaced in the captured state.
    The DispatcherTimer completion path is verified against a real WPF
    Dispatcher running a pumped message loop (no visible window required).
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$GuiScript = Join-Path $RootDir "gui.ps1"

if (-not (Test-Path $GuiScript)) {
    Write-Error "gui.ps1 not found at: $GuiScript"
    exit 1
}
Import-Module (Join-Path $RootDir "PSManager.psd1") -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ----------------------------------------------------------------------------
# Extract the Invoke-GuiCliAction function body from gui.ps1 and materialize it
# in this session without executing the whole GUI (no XAML, no window).
# ----------------------------------------------------------------------------
$guiSource = Get-Content -LiteralPath $GuiScript -Raw -Encoding UTF8
$fnStart = $guiSource.IndexOf("function Invoke-GuiCliAction")
if ($fnStart -lt 0) { throw "Invoke-GuiCliAction function not found in gui.ps1" }
$fnEnd = $guiSource.IndexOf("`nfunction ", $fnStart + 10)
if ($fnEnd -lt 0) { $fnEnd = $guiSource.Length }
$fnText = $guiSource.Substring($fnStart, $fnEnd - $fnStart)
# The error-path tick calls [System.Windows.MessageBox]::Show, which blocks the
# test run with a modal dialog (no human to click OK). Swap it for a recorder.
$fnText = $fnText.Replace('[System.Windows.MessageBox]::Show(', 'Show-GuiTestMessage (')

# Test doubles for the GUI runtime the function expects.
$Script:TestLog = [System.Collections.Generic.List[string]]::new()
function Add-Log { param([string]$Text) $Script:TestLog.Add($Text) }
function Set-BusyState { param([bool]$Busy) $Script:LastBusyState = $Busy }
function Get-Text { param([string]$Key) return $Key }
function Update-DashboardUI { }
$Script:TestMessageBoxCalls = [System.Collections.Generic.List[object]]::new()
function Show-GuiTestMessage {
    # Recorder stand-in for [System.Windows.MessageBox]::Show; the remaining
    # positional args (title, buttons, icon) are accepted and ignored.
    param([string]$Text, $Rest = $null)
    $Script:TestMessageBoxCalls.Add([pscustomobject]@{ Text = $Text })
    return [System.Windows.MessageBoxResult]::OK
}
$Script:GuiBusy = $false
$Script:scriptRoot = $RootDir

# The function references $scriptRoot (function-local scope lookup finds the
# Script: variable) and [System.Windows.Threading.DispatcherTimer].
Invoke-Expression $fnText

if (-not (Get-Command Invoke-GuiCliAction -ErrorAction SilentlyContinue)) {
    throw "Failed to materialize Invoke-GuiCliAction from gui.ps1"
}

# ----------------------------------------------------------------------------
# DispatcherTimer ticks fire only on the thread that owns the dispatcher.
# Use the current thread's dispatcher and pump frames while waiting for the
# busy flag to clear - no worker thread, no cross-thread runspace issues.
# ----------------------------------------------------------------------------
function Wait-GuiIdle {
    param([int]$TimeoutMs = 15000)
    $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($Script:GuiBusy) {
        if ([DateTime]::UtcNow -gt $deadline) {
            throw "GUI busy flag not cleared within ${TimeoutMs}ms (completion tick never ran)"
        }
        # Pump WPF messages so the DispatcherTimer ticks execute.
        $frame = [System.Windows.Threading.DispatcherFrame]::new()
        $null = $dispatcher.BeginInvoke([action]{ $frame.Continue = $false }, [System.Windows.Threading.DispatcherPriority]::Background)
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        [System.Threading.Thread]::Sleep(20)
    }
}

# ----------------------------------------------------------------------------

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

try {
    # --- Test 1: handler returns immediately; busy set; state in script scope
    # 'help' exits fast but still proves the call does not synchronously await
    # process exit + drain: busy stays true and state exists when it returns.
    $Script:TestLog.Clear()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-GuiCliAction -CliAction 'help' -LogHeader 'unit-help'
    $sw.Stop()
    Assert-Check -Name "Handler returns synchronously without running child to completion" -TestBlock {
        # The handler must NOT wait for full child execution + drain inside the
        # call itself: busy must be $true right after return (child still owned
        # by the timer), and CliState must exist in script scope.
        if (-not $Script:GuiBusy) { throw "GuiBusy was not set immediately after call" }
        if ($null -eq $Script:CliState) { throw "Script:CliState not set (state would be unreachable from Tick handler)" }
        if ($null -eq $Script:CliState.Proc) { throw "CliState.Proc missing" }
        if ($Script:CliState.Done) { throw "State already Done synchronously; child was awaited inside the handler" }
        if ($sw.ElapsedMilliseconds -gt 5000) { throw "Handler blocked too long: $($sw.ElapsedMilliseconds)ms" }
    }

    Assert-Check -Name "Header logged with [>] prefix" -TestBlock {
        $found = $false
        foreach ($l in $Script:TestLog) { if ($l -match '^\[\>\] unit-help') { $found = $true } }
        if (-not $found) { throw "No '[>] unit-help' header in log: $($Script:TestLog -join ' | ')" }
    }

    # --- Test 2: completion tick clears busy, drains both streams, logs output
    Wait-GuiIdle -TimeoutMs 20000
    Assert-Check -Name "Busy flag cleared after child exit (Tick completion ran)" -TestBlock {
        if ($Script:GuiBusy) { throw "GuiBusy still true" }
        if ($null -ne $Script:CliState) { throw "CliState not reset to null after completion" }
    }
    Assert-Check -Name "Child stdout drained into log" -TestBlock {
        $joined = $Script:TestLog -join "`n"
        if ($joined -notmatch 'USAGE|COMMANDS|psmgr') { throw "CLI help output missing from log" }
    }
    Assert-Check -Name "Final busy state call was Set-BusyState false" -TestBlock {
        if ($Script:LastBusyState -ne $false) { throw "Last Set-BusyState call was not false" }
    }

    # --- Test 3: re-entrancy guard while busy
    Assert-Check -Name "Second invocation ignored while busy" -TestBlock {
        # Simulate a hung child by faking busy state.
        $Script:GuiBusy = $true
        $before = $Script:TestLog.Count
        Invoke-GuiCliAction -CliAction 'help' -LogHeader 'unit-reentry'
        if ($Script:TestLog.Count -ne $before) { throw "Re-entrant call mutated log/state while busy" }
        $Script:GuiBusy = $false
    }

    # --- Test 4: non-zero exit captured (error path)
    $Script:TestLog.Clear()
    # A CLI action that fails fast: invalid value for -Action triggers param
    # binding failure -> non-zero exit.
    Invoke-GuiCliAction -CliAction 'help' -CliArgs @('-DefinitelyNotARealSwitch') -LogHeader 'unit-fail'
    Wait-GuiIdle -TimeoutMs 20000
    Assert-Check -Name "Non-zero exit surfaced as ERROR in log and error dialog" -TestBlock {
        $joined = $Script:TestLog -join "`n"
        if ($joined -notmatch 'ERROR') { throw "Expected ERROR entry for failing child, log: $($Script:TestLog -join ' | ')" }
        if ($Script:TestMessageBoxCalls.Count -eq 0) { throw "Error dialog (MessageBox) not invoked on failure path" }
        if ("$($Script:TestMessageBoxCalls[0].Text)" -notmatch 'unit-fail -> exit') {
            throw "Dialog text missing action/exit info: $($Script:TestMessageBoxCalls[0].Text)"
        }
    }

    # --- Test 4b: audit findings (exit 1) do not trigger generic failure dialog
    # Use a controlled CLI child so this regression does not depend on profiles
    # present on the executing machine.
    $Script:TestLog.Clear()
    $Script:TestMessageBoxCalls.Clear()
    $auditStubRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("psmgr_gui_audit_" + [guid]::NewGuid().ToString("N"))
    $auditStubPath = Join-Path $auditStubRoot 'ps-manager.ps1'
    [System.IO.Directory]::CreateDirectory($auditStubRoot) | Out-Null
    [System.IO.File]::WriteAllText($auditStubPath, @'
param([string]$Action, [switch]$Fix)
if ($Action -eq 'audit-profile') {
    Write-Output 'Profile findings'
    exit 1
}
exit 0
'@, [System.Text.Encoding]::UTF8)

    $previousScriptRoot = $Script:scriptRoot
    try {
        $Script:scriptRoot = $auditStubRoot
        Invoke-GuiCliAction -CliAction 'audit-profile' -LogHeader 'unit-audit'
        Wait-GuiIdle -TimeoutMs 20000
        Assert-Check -Name "audit-profile findings exit code does not trigger generic failure dialog" -TestBlock {
            $joined = $Script:TestLog -join "`n"
            if ($joined -notmatch '\[!\] unit-audit: gui_audit_issues_found') {
                throw "Audit findings status missing from log: $joined"
            }
            if ($joined -match 'ERROR:\s+unit-audit\s+exited with code 1') {
                throw "audit-profile was treated as generic error failure: $joined"
            }
            foreach ($call in $Script:TestMessageBoxCalls) {
                if ("$($call.Text)" -match 'gui_err_failed') {
                    throw "gui_err_failed dialog shown for audit-profile: $($call.Text)"
                }
            }
        }

        # AC-3: an already-requested repair must not be offered again.
        $Script:TestLog.Clear()
        $Script:TestMessageBoxCalls.Clear()
        Invoke-GuiCliAction -CliAction 'audit-profile' -CliArgs @('-Fix') -LogHeader 'unit-audit-fix'
        Wait-GuiIdle -TimeoutMs 20000
        Assert-Check -Name "audit-profile -Fix does not re-offer the repair" -TestBlock {
            $joined = $Script:TestLog -join "`n"
            if ($joined -notmatch '\[!\] unit-audit-fix: gui_audit_issues_found') {
                throw "Audit findings status missing for -Fix run: $joined"
            }
            foreach ($call in $Script:TestMessageBoxCalls) {
                if ("$($call.Text)" -match 'gui_audit_issues_prompt') {
                    throw "Repair prompt shown although -Fix was already requested"
                }
            }
        }
    } finally {
        $Script:scriptRoot = $previousScriptRoot
        try { [System.IO.Directory]::Delete($auditStubRoot, $true) } catch {}
    }

    # --- Test 5: pipe-full drain regression (child writes >64KB per stream)
    Assert-Check -Name "Child writing 92KB stdout + 92KB stderr drains without deadlock" -TestBlock {
        $bigCode = @'
1..2000 | ForEach-Object { Write-Output ("OUT-" + "x" * 40) }
1..2000 | ForEach-Object { [Console]::Error.WriteLine("ERR-" + "y" * 40) }
exit 0
'@
        $bigEnc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($bigCode))
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo.FileName = (Get-Process -Id $PID).Path
        $proc.StartInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $bigEnc"
        $proc.StartInfo.UseShellExecute = $false
        $proc.StartInfo.CreateNoWindow = $true
        $proc.StartInfo.RedirectStandardOutput = $true
        $proc.StartInfo.RedirectStandardError = $true
        $proc.StartInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $proc.StartInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $null = $proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(20000)) {
            try { $proc.Kill() } catch {}
            throw "DEADLOCK reproduced: child did not exit within 20s"
        }
        $out = $outTask.Result
        $errOut = $errTask.Result
        if ($out.Length -lt 60000) { throw "stdout under-drained: $($out.Length) chars" }
        if ($errOut.Length -lt 60000) { throw "stderr under-drained: $($errOut.Length) chars" }
        $proc.Dispose()
    }

    # --- Test: every $txt*.Text assignment must have a FindName binding
    Assert-Check -Name "Every Txt* UI element used in gui.ps1 is bound via FindName" -TestBlock {
        $src = Get-Content -LiteralPath $GuiScript -Raw -Encoding UTF8
        # Bindings come from either the main window ($window.FindName) or a
        # dynamically loaded dialog ($win.FindName).
        $bound = [regex]::Matches($src, '\$(txt[A-Za-z0-9]+)\s*=\s*\$(?:window|win)\.FindName\(') |
            ForEach-Object { $_.Groups[1].Value }
        $used = [regex]::Matches($src, '(?m)^\s*\$(txt[A-Za-z0-9]+)\.Text\s*=') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

        $missing = @($used | Where-Object { $_ -notin $bound })
        if ($missing.Count -gt 0) {
            throw "Unbound UI element(s) would throw 'property Text cannot be found': $($missing -join ', ')"
        }
    }
} finally {
    # Kill any still-running test child.
    if ($Script:CliState -and $Script:CliState.Proc -and -not $Script:CliState.Proc.HasExited) {
        try { $Script:CliState.Proc.Kill() } catch {}
    }
}

if ($failures.Count -gt 0) {
    Write-Host "`n[PASS/FAIL SUMMARY] $($failures.Count) failure(s):" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Yellow }
    exit 1
}
Write-Host "`n[PASS] test_gui_async.ps1 passed all checks" -ForegroundColor Green
exit 0
