# Specification: Asynchronous GUI Execution & Structured Logging

**Spec ID**: SPEC-GUI-ASYNC-001  
**Status**: Approved  
**Targets**: `gui.ps1`, `ps-manager.ps1`, `modules/Package/SourceManager.ps1`, `modules/Core/Logger.ps1`, `tests/test_e2e_sync.ps1`  

---

## 1. Functional Requirements

### 1.1 Process Lifecycle & Exception Safety (`gui.ps1`)
- **REQ-GUI-1.1**: `Invoke-GuiCliAction` MUST wrap process initialization and start in a `try/catch` block. If `Process.Start()` throws, `Set-BusyState $false` MUST be called immediately, the error MUST be logged to the console, and execution MUST terminate gracefully without leaving the UI locked.
- **REQ-GUI-1.2**: Unused `$outFile` variable MUST be eliminated, and the docstring MUST accurately document pipe-based task buffering.
- **REQ-GUI-1.3**: When displaying the completion error dialog via `[System.Windows.MessageBox]::Show`, the main window (`$window`) SHOULD be passed as owner to maintain modal hierarchy.

### 1.2 Output Stream Sanitization & Rendering (`gui.ps1`)
- **REQ-GUI-2.1**: Output lines drained from stdout and stderr MUST be iterated individually: each line MUST be passed to `Add-Log` independently to prevent string flattening via array-to-string coercion.
- **REQ-GUI-2.2**: ANSI escape sequences (`\x1b\[[0-9;]*[a-zA-Z]`) MUST be stripped from output text before feeding to `Add-Log`, ensuring clean rendering in the WPF `TextBox`.
- **REQ-GUI-2.3**: Joining stdout and stderr tasks MUST separate non-empty streams cleanly with newlines and guard against task faults using structured error handling.

### 1.3 CLI Exit Code & Color Contracts (`ps-manager.ps1`)
- **REQ-CLI-1.1**: When `ps-manager.ps1 sync` encounters an unsuccessful sync (`$res.Success -eq $false`), the script MUST exit with code `1` rather than silently exiting with `0`.
- **REQ-CLI-1.2**: Module `Theme.ps1` MUST export `Set-PSManagerTheme` and `Disable-PSManagerColor` with `$Script:THEME_ENABLED` gate, ensuring `Format-ColorText`, `Format-ColorBadge`, and `Show-PSManagerHelp` emit zero ESC characters across both PowerShell 5.1 and 7 engines when `-NoColor` is requested.

### 1.4 Interactive TUI Key Prompts (`SourceManager.ps1`)
- **REQ-TUI-1.1**: All `Write-Host "`n" + (Get-I18nText "press_key")` calls in `SourceManager.ps1` MUST be wrapped in parentheses `Write-Host ("`n" + (Get-I18nText "press_key"))` to prevent argument parser corruption.

### 1.5 Deterministic Log File Sequencing (`Logger.ps1`)
- **REQ-LOG-1.1**: `Get-PSManagerLogs` MUST sort matching `psmgr_*.log` files by `Name` ascending so that ISO date names (`psmgr_yyyyMMdd.log`) guarantee strict chronological order regardless of filesystem timestamp jitter.

### 1.6 Dual-Runtime Test Compatibility (`test_e2e_sync.ps1`)
- **REQ-TST-1.1**: `test_e2e_sync.ps1` MUST detect the active PowerShell binary (`(Get-Process -Id $PID).Path`) or check if `pwsh.exe` is present before spawning CLI processes, falling back to `powershell.exe` on Windows PowerShell 5.1 environments.
