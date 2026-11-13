# Issue Report: Async GUI CLI Execution & Logging Pipeline

**Issue ID**: ISS-GUI-ASYNC-001  
**Component**: `gui.ps1`, `ps-manager.ps1`, `modules/Package/SourceManager.ps1`, `modules/Core/Logger.ps1`, `tests/test_e2e_sync.ps1`  
**Severity**: High  
**Status**: Open  

---

## 1. Summary

The asynchronous GUI-to-CLI bridge (`Invoke-GuiCliAction`) introduced to keep the WPF UI responsive during long-running background tasks introduces log rendering defects, unhandled failure paths, and exit-code masking. Companion modules also retain string-formatting and cross-runtime compatibility issues.

---

## 2. Identified Defects

### Defect 1: Log Line Array Flattening in GUI (`gui.ps1:733`)
- **Severity**: Critical (🔴)
- **Problem**: When `Invoke-GuiCliAction` drains child process output, it passes pipeline array output `($rest.TrimEnd() -split "`r?`n" | ForEach-Object { " | " + $_ })` to `Add-Log`. Because `Add-Log` accepts scalar `[string]$Text`, PowerShell coerces the array to a single space-delimited string, joining all lines horizontally without line breaks.
- **Impact**: GUI execution logs for `sync`, `doctor`, and `sync-sources` appear as an unreadable single-line blob.

### Defect 2: Masked CLI Sync Exit Codes (`ps-manager.ps1:130` & `gui.ps1:743`)
- **Severity**: Critical (🔴)
- **Problem**: `Invoke-GuiCliAction` evaluates process success purely by `$s.ExitCode -ne 0`. However, `ps-manager.ps1 sync` never exits with a non-zero exit code when `$res.Success -eq $false` (it only prints a yellow warning and terminates with exit code 0).
- **Impact**: Failed profile synchronization is reported as successful in GUI, and error dialogs never trigger.

### Defect 3: ANSI Escape Leakage into WPF UI (`gui.ps1:698`, `ps-manager.ps1:21`)
- **Severity**: Moderate (🟡)
- **Problem**: `ps-manager.ps1` declares `[switch]$NoColor` but never consumes it, and `Invoke-GuiCliAction` does not strip ANSI escape sequences before feeding strings to `Add-Log`.
- **Impact**: WPF `TextBox` renders raw escape characters (`←[38;2;...m`) in GUI console log.

### Defect 4: Unhandled Process Start Exception (`gui.ps1:708`)
- **Severity**: Moderate (🟡)
- **Problem**: `$proc.Start()` runs without `try/catch`. If process spawning fails, `Set-BusyState $true` has already locked buttons and set cursor to `Wait`.
- **Impact**: GUI remains permanently locked in busy state with no recovery.

### Defect 5: Unhandled Task Fault in Dispatcher Timer (`gui.ps1:732`)
- **Severity**: Moderate (🟡)
- **Problem**: Accessing `$s.OutTask.Result` inside `timer.Add_Tick` without `try/catch` propagates `AggregateException` to WPF dispatcher if task faults.
- **Impact**: Application crash on stream read error.

### Defect 6: Unparenthesized `Write-Host` Concat in `SourceManager.ps1`
- **Severity**: Moderate (🟡)
- **Problem**: `modules/Package/SourceManager.ps1` lines 140, 153, 160, and 170 use `Write-Host "`n" + (Get-I18nText "press_key")`.
- **Impact**: Argument parsing treats `+` as an argument, printing a literal `+` before the prompt.

### Defect 7: Non-Deterministic Log Rotation Ordering (`Logger.ps1:89`)
- **Severity**: Minor (🟢)
- **Problem**: `Get-PSManagerLogs` sorts log files by `LastWriteTime`. If file timestamps are touched or identical, chronological ordering can be inverted.
- **Impact**: Log tail slicing can return older lines instead of the most recent entries.

### Defect 8: Hardcoded `pwsh.exe` in Test Suite (`tests/test_e2e_sync.ps1:49, 66`)
- **Severity**: Moderate (🟡)
- **Problem**: `test_e2e_sync.ps1` explicitly calls `& pwsh.exe ...`, breaking test runs on machines with only Windows PowerShell 5.1 installed.
- **Impact**: Fails AGENTS.md Dual-Runtime Mandate.

### Defect 9: Dead `$outFile` in `gui.ps1:697`
- **Severity**: Minor (🟢)
- **Problem**: `$outFile` variable is created via `Join-Path` but never used.
- **Impact**: Dead code and misleading docstring.
