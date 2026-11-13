# PLAN — Port `08bab27` (GUI audit callback context) onto `feat/uiux-omp`

Implements `docs/SPEC-BRANCH-PARITY.md`.

**Goal:** this branch carries every capability of `main`, including the deferred-callback fix, with
a regression test that does not depend on the executing machine's profiles.

**Scope:** `gui.ps1` (`Invoke-GuiCliAction` only), `tests/test_gui_async.ps1` (Test 4b),
`CHANGELOG.md`. Nothing else.

---

## Task 1 — Capture action metadata in the completion callback

**Files:** `gui.ps1` (`Invoke-GuiCliAction`)

**Steps**

1. Before the `Invoke-PSManagerAction` call, build the script-scoped state object:

   ```powershell
   $cliState = [pscustomobject]@{
       Proc      = $null
       Done      = $false
       Header    = if ($LogHeader) { $LogHeader } else { $CliAction }
       ExitCode  = $null
       Action    = $CliAction
       Arguments = $CliArgs
   }
   $Script:CliState = $cliState
   ```

2. Build the callback as `$onCompleted` and read everything from the captured object:

   ```powershell
   $onCompleted = {
       param($res)
       $actionState = $Script:CliState
       $hdr = if ($actionState -and $actionState.Header) { $actionState.Header } else { $res.Action }
       $Script:CliState = $null
       $Script:GuiBusy = $false
       Set-BusyState $false
       try { Update-DashboardUI } catch {}
       if (-not $res.Success) {
           if ($actionState -and $actionState.Action -eq 'audit-profile' -and $res.ExitCode -eq 1) {
               Add-Log ("[!] " + $hdr + ": " + (Get-Text "gui_audit_issues_found"))
               if ($actionState.Arguments -notcontains '-Fix') { <offer -Fix> }
           } else { <generic error log + dialog> }
       } elseif ($actionState -and $actionState.Action -eq 'audit-profile') {
           Add-Log ("[OK] " + $hdr + ": " + (Get-Text "gui_audit_clean"))
       }
   }
   ```

3. Pass `-OnCompleted $onCompleted` to `Invoke-PSManagerAction`.

4. After the call, set the process handle only if the state object is still the current one (the
   child may already have completed on a fast path):

   ```powershell
   if ([object]::ReferenceEquals($Script:CliState, $cliState)) {
       $cliState.Proc = if ($handle) { $handle.Process } else { $null }
   }
   ```

**Check:** `Select-String -Path gui.ps1 -Pattern 'actionState'` finds the callback reads; no
`$CliAction -eq` remains inside `-OnCompleted`.

---

## Task 2 — Make Test 4b machine-independent

**Files:** `tests/test_gui_async.ps1`

**Steps**

1. Create a temporary stub root containing `ps-manager.ps1`:

   ```powershell
   param([string]$Action)
   if ($Action -eq 'audit-profile') { Write-Output 'Profile findings'; exit 1 }
   exit 0
   ```

2. Point `$Script:scriptRoot` at the stub root for the duration of the test, call
   `Invoke-GuiCliAction -CliAction 'audit-profile' -LogHeader 'unit-audit'`, and `Wait-GuiIdle`.

3. Assert:
   - the log contains `[!] unit-audit: gui_audit_issues_found`;
   - the log does **not** match `ERROR:\s+unit-audit\s+exited with code 1`;
   - no recorded dialog text matches `gui_err_failed`.

4. Restore `$Script:scriptRoot` and delete the stub root in `finally`.

**Check:** run `tests/test_gui_async.ps1` on this machine (clean profiles) — the test must exercise
the findings path rather than a passing audit.

---

## Task 3 — Record the change

**Files:** `CHANGELOG.md` (under `[Unreleased]` → `Fixed`, in the existing GUI audit bullet)

Add:

> Preserved audit action metadata in GUI async state, so its deferred completion callback still
> recognizes exit code `1` after the initiating function returns; `test_gui_async.ps1` now uses a
> controlled failing CLI child instead of host profile state.

`CONTEXT.md`/`README.md` need no change: no public command, flag or UI text moves.

---

## Task 4 — Verification

Run, in this order, and record the output:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test_gui_async.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Run-Tests.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-ScriptAnalyzer -Path . -Settings PSScriptAnalyzerSettings.psd1 -Recurse"
```

Expected: GUI async suite green; harness 95/95 on 5.1 and 95/95 on 7; analyzer silent.

Finally confirm no capability is left behind:

```powershell
git diff main -- gui.ps1 tests/test_gui_async.ps1
```

Expected: the diff shows only this branch's own changes; the captured-state callback
(`$actionState`), the stub-CLI regression test and the CHANGELOG line are all present.
`git log main --not HEAD` still lists `08bab27` until the branches are merged — that is the commit
graph, not a functional gap.
