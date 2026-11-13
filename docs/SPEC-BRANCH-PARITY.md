# SPEC — Branch parity: `feat/uiux-omp` vs `main`

Status: approved for implementation
Date: 2026-10-30

## 1. Context

`feat/uiux-omp` branched from `main` at merge-base `9604740`. The branch carries 13 commits
(GUI XAML/theme work, TUI render engine and language work). `main` has moved one commit ahead:

| Commit | Subject | Files |
|---|---|---|
| `08bab27` | `fix(gui): preserve audit callback context` | `gui.ps1`, `tests/test_gui_async.ps1`, `CHANGELOG.md` |

`git log main --not HEAD` reports exactly that commit; there is no other commit, file or exported
function present in `main` and absent from this branch (`git diff --name-status main` shows only
additions from the UI/UX work, no deletions).

## 2. The missing capability

`Invoke-GuiCliAction` runs the CLI child asynchronously through `Invoke-PSManagerAction -Async`.
Its `-OnCompleted` callback is a scriptblock executed later by a `DispatcherTimer`, after
`Invoke-GuiCliAction` has already returned.

On this branch the callback still reads the launching function's parameters:

```powershell
-OnCompleted {
    param($res)
    ...
    if ($CliAction -eq 'audit-profile' -and $res.ExitCode -eq 1) { ... }
    if ($CliArgs -notcontains '-Fix') { ... }
}
```

Those variables belong to a function scope that no longer exists when the timer fires. The
callback therefore cannot recognise `audit-profile`, so a findings exit code (`1`) is reported as a
generic failure (`ERROR: <header> exited with code 1` plus the `gui_err_failed` dialog), and the
"offer auto-repair" branch never runs. `main` fixed this by capturing the action metadata in the
script-scoped state object and reading it from the callback.

The branch's regression test does not catch it either: `test_gui_async.ps1` Test 4b depends on the
profiles present on the executing machine, so on a clean profile it passes for the wrong reason.

## 3. Requirements

- **FR-1** The deferred completion callback MUST take action identity, arguments and header from a
  captured state object, not from the launching function's parameters.
- **FR-2** `audit-profile` exit code `1` MUST log `[!] <header>: <gui_audit_issues_found>` and MUST
  NOT raise `gui_err_failed`. It MUST offer the `-Fix` follow-up only when `-Fix` is not already
  among the arguments.
- **FR-3** A successful `audit-profile` MUST log `[OK] <header>: <gui_audit_clean>`.
- **FR-4** The regression test MUST drive the bridge with a controlled stub CLI child that exits `1`
  for `audit-profile`, so the assertion does not depend on host profile state.
- **FR-5** The state object MUST still expose `Proc`, `Done`, `Header` and `ExitCode`, because the
  Tick handler and the cancel path read those fields.
- **FR-6** `CHANGELOG.md` MUST record the fix under `[Unreleased]` → `Fixed`.

## 4. Non-goals

- No behaviour change for any other CLI action.
- No refactor of `Invoke-PSManagerAction` or the ActionEngine.
- No change to the three-mode language work, TUI renderer or CLI presentation added on this branch.
- No new runtime dependency.

## 5. Acceptance criteria

| id | Criterion |
|---|---|
| AC-1 | No functional gap remains: every change of `08bab27` is present in this branch's `gui.ps1`, `tests/test_gui_async.ps1` and `CHANGELOG.md`. (`git log main --not HEAD` keeps listing the upstream commit until the branch is merged; parity is judged by content, not by the commit graph.) |
| AC-2 | With a stub CLI that exits `1`, `Invoke-GuiCliAction -CliAction 'audit-profile'` logs the findings line, does not log `ERROR ... exited with code 1`, and records no `gui_err_failed` dialog. |
| AC-3 | `Invoke-GuiCliAction -CliAction 'audit-profile' -CliArgs @('-Fix')` does not re-offer the fix. |
| AC-4 | `tests/test_gui_async.ps1` passes on a machine whose profiles are clean and on one with findings. |
| AC-5 | `tests/Run-Tests.ps1` passes 95/95 on Windows PowerShell 5.1 and on PowerShell 7. |
| AC-6 | `Invoke-ScriptAnalyzer` reports no errors or warnings. |
