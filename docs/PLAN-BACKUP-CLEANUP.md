# Implementation Plan: Destructive Backup Cleanup

**Plan ID**: PLAN-BACKUP-CLEANUP-001  
**Spec**: `docs/SPEC-BACKUP-CLEANUP.md`  
**Status**: Complete  

---

## 1. Work Breakdown

| Step | File | Change |
|------|------|--------|
| 1 | `modules/Sync/Backup.ps1` | Add `Remove-PSManagerBackup` after `Get-PSManagerBackups` |
| 2 | `PSManager.psm1`, `PSManager.psd1` | Export `Remove-PSManagerBackup` |
| 3 | `modules/Core/ActionRegistry.ps1` | Register `clean-backups` (`X` / `BtnDeleteBackups`) |
| 4 | `ps-manager.ps1` | `ValidateSet` + `-Force` switch + `clean-backups` case |
| 5 | `modules/UI/TuiEngine.ps1` | `[X]` menu item + multi-select handler |
| 6 | `gui.ps1` | `BtnDeleteBackups` XAML, bindings, `Show-BackupDeleteDialog`, handler |
| 7 | `i18n.json` | `menu_clean_backups*`, `gui_btn_clean_backups*`, `gui_clean_backups_*` (en/vi/vi-ascii) |
| 8 | `tests/test_backup_cleanup.ps1` | 9 safety cases |
| 9 | `tests/harness.ps1` | Export list + suite registration |
| 10 | Docs | README, CONTEXT, CHANGELOG |

---

## 2. Safety-Ordered Implementation

Order matters: the guardrails must exist before any UI can call the deletion.

```
1. Containment + scope guard        (module)
2. ShouldProcess / -WhatIf          (module)
3. Audit logging                    (module)
4. CLI typed-DELETE gate            (driver)
5. TUI numbered multi-select gate   (driver)
6. GUI multi-select + DELETE field  (driver)
7. Parity registration + tests      (contract)
```

If step 1–3 are wrong, every later step becomes dangerous, so module logic was
written and unit-tested first.

---

## 3. Verification Performed

| Gate | Command | Result |
|------|---------|--------|
| Backup safety suite | `powershell -File tests/test_backup_cleanup.ps1` | 9/9 PASS |
| Same suite on PS 7 | `pwsh -File tests/test_backup_cleanup.ps1` | 9/9 PASS |
| Tri-interface parity | `powershell -File tests/test_interface_parity.ps1` | 23/23 PASS |
| GUI XAML load + resolve | ad-hoc XAML loader probe | main + dialog OK |
| GUI binding audit | `test_gui_async.ps1` binding regression | PASS |
| Full harness (PS 5.1) | `tests/Run-Tests.ps1` | 72/72 PASS |
| Full harness (PS 7) | `tests/Run-Tests.ps1` | 72/72 PASS |
| Static analysis | `Invoke-ScriptAnalyzer -Recurse` | 0 errors / 0 warnings |
| Manifest | `Test-ModuleManifest PSManager.psd1` | PASS (1.4.0) |
| Live CLI refusal | `psmgr clean-backups` (redirected stdin) | exit 1, no deletion |
| Live CLI delete | `psmgr clean-backups <name> -Force` | 1 deleted, sibling kept |

---

## 4. Rollback

No persisted schema changed. Reverting the commit removes the button, menu item,
and command; existing backup archives are unaffected because deletion is only
ever performed inside `Remove-PSManagerBackup`.

---

## 5. Out of Scope / Follow-ups

- `psmgr clean-backups --cloud` for GitHub Release cleanup (needs `gh release
  delete` + tag cleanup + stronger confirmation).
- Retention policy (`--keep N`).
- Recycle-Bin-style soft delete for local archives.
