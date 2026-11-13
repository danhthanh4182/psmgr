# Implementation Plan: Asynchronous GUI & Logging Hardening

**Plan ID**: PLAN-GUI-ASYNC-001  
**Status**: Ready for Execution  

---

## 1. Overview & Strategy

Execute surgical fixes across the 5 affected files to ensure non-blocking UI operations, clean multiline log rendering, correct exit code signaling, dual-runtime compatibility, and robust error handling.

---

## 2. Step-by-Step File Edits

### Step 1: `gui.ps1`
1. Remove dead `$outFile = ...` allocation.
2. Update docstring to describe pipe-drained task polling.
3. Wrap `$proc.Start()` in a `try/catch` block: on catch, log error, call `Set-BusyState $false`, and return.
4. In the `DispatcherTimer` tick handler:
   - Wrap task result access and exit code reading in `try/catch`.
   - Separate stdout and stderr with a newline if both exist.
   - Strip ANSI escapes (`$clean = $raw -replace '\x1b\[[0-9;]*[a-zA-Z]', ''`).
   - Iterate each line individually: `foreach ($line in ($clean.TrimEnd() -split "`r?`n")) { Add-Log (" | " + $line) }`.
   - Pass `$window` to `[System.Windows.MessageBox]::Show`.

### Step 2: `ps-manager.ps1` & `modules/UI/Theme.ps1`
1. Implement `Set-PSManagerTheme` and `Disable-PSManagerColor` in `modules/UI/Theme.ps1` with `$Script:THEME_ENABLED` gate.
2. Export both functions in `PSManager.psd1` and `PSManager.psm1`.
3. Update `Format-ColorText` and `Format-ColorBadge` to return plain unadorned strings when colors are disabled.
4. In `ps-manager.ps1`: consume `$NoColor` by invoking `Disable-PSManagerColor`.
5. In `ps-manager.ps1`: in `'sync'` action switch case, invoke `exit 1` when `-not $res.Success`.
6. In `tests/harness.ps1`: add dual-engine regression asserting `help -NoColor` emits zero ESC characters.
### Step 3: `modules/Package/SourceManager.ps1`
1. Update lines 140, 153, 160, and 170: wrap `" `n" + (Get-I18nText "press_key")` in parentheses.

### Step 4: `modules/Core/Logger.ps1`
1. In `Get-PSManagerLogs`, change `Sort-Object LastWriteTime` to `Sort-Object Name` for deterministic chronological order.

### Step 5: `tests/test_e2e_sync.ps1`
1. Dynamically select PowerShell executable:
   ```powershell
   $psBin = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { "pwsh.exe" } else { (Get-Process -Id $PID).Path }
   ```
2. Replace hardcoded `& pwsh.exe` with `& $psBin`.

---

## 3. Verification & Validation Steps

1. Run unit test for async GUI CLI bridge: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_gui_async.ps1`.
2. Run end-to-end sync tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_e2e_sync.ps1`.
3. Run full cross-version suite: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Run-Tests.ps1`.
4. Run PSScriptAnalyzer: `pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-ScriptAnalyzer -Path . -Settings PSScriptAnalyzerSettings.psd1 -Recurse"`.
5. Run Module Manifest validation: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Test-ModuleManifest PSManager.psd1"`.
6. Update `CHANGELOG.md` under `[Unreleased]`.
