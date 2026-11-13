# PSManager Engineering Plan & Roadmap

## 1. Project Milestones

### Phase 1: Foundation & Default Shell Orchestration (Completed)
- [x] Detect Windows Terminal profiles & GUID resolution.
- [x] Configure Windows 11 default terminal delegation host in registry.
- [x] Create PATH shims (`powershell.cmd`, `winps.cmd`).
- [x] Context menu integration for folders and `.ps1` files.
- [x] VS Code integrated terminal settings synchronization.
- [x] 1-Click revert functionality to PowerShell 5.1.

### Phase 2: Package Source & Channel Management (Completed)
- [x] Implement multi-source catalog: `winget` vs `msstore` vs `github`.
- [x] Map package IDs across release channels (`stable`, `preview`, `lts`).
- [x] Winget source cache synchronization (`winget source update`).
- [x] Direct GitHub Releases API integration for offline / direct installer download.
- [x] Persistent JSON configuration layer (`config.json`).

### Phase 3: Modern UI & Bilingual Engine (Completed)
- [x] Build interactive TUI with ANSI theme, live status header, arrow navigation, and fast hotkeys.
- [x] Implement WPF XAML native Dark Desktop Application (`gui.ps1`) with status cards, action buttons, and live log console.
- [x] Implement bilingual dictionary (`i18n.json`).
- [x] Dynamic font adaptation: accented Unicode on PS7, unaccented ASCII on PS5 to eliminate `?` font corruption.

### Phase 4: Modular Refactoring & Enterprise Standards (Completed)
- [x] Decompose monolith script into Single Responsibility submodules under `modules/`.
- [x] Create official PowerShell Module Manifest (`PSManager.psd1`) and Root Module (`PSManager.psm1`).
- [x] 100% compliance with PowerShell Approved Verbs (`Get-Verb`).
- [x] Zero-warning module import across both PS 5.1 and PS 7.
- [x] Clean executable entry point (`ps-manager.ps1`).

### Phase 5: Verification Harness & CI (Completed)
- [x] Develop automated test harness (`tests/harness.ps1`).
- [x] Comprehensive AST syntax linting on all codebase files.
- [x] Module manifest and export contract validation.
- [x] GitHub Actions CI workflow for automated testing on Windows runner.
- [x] Node 24 runner compatibility (`actions/checkout@v7`, `upload-artifact@v7`, `action-gh-release@v3`).
- [x] CI verification mandate: `gh run watch --exit-status` after every push.

### Phase 6: Profile Sync, Adoption & Doctor (Completed)
- [x] Manifest-driven profile sync with hardlink → symlink → copy fallback.
- [x] Reverse adoption (`psmgr adopt` / `Import-PSManagerProfiles`).
- [x] Health audit with auto-repair (`psmgr doctor -Fix`).
- [x] Local, encrypted, DPAPI, and cloud backups + restore.
- [x] Sandboxed end-to-end tests (no live-machine mutation).

### Phase 7: Async Execution & GUI Hardening (Completed)
- [x] `modules/Core/ActionEngine.ps1` deep module (sync + async, streaming, cancellation).
- [x] Live line-by-line output streaming with pipe-tail flush on exit.
- [x] Busy progress bar, cancel button, filterable 500-line log, window geometry persistence.
- [x] ToolTip wrapping and full-Unicode `Tiếng Việt` rendering in the GUI.

### Phase 8: Profile Compatibility Audit (Completed)
- [x] `Test-PSManagerProfile` (7 checks × 2 runtimes) with brace-balanced guard detection.
- [x] `Repair-PSManagerProfile` with timestamped backups and idempotent repairs.
- [x] Canonical `templates/profiles/master_profile.ps1`; machine specifics moved to `local.ps1`.
- [x] Doctor check #8, CLI `audit-profile`, TUI `[T]`, GUI `BtnAuditProfiles`.

### Phase 9: Destructive Operation Guardrails (Completed)
- [x] `Remove-PSManagerBackup` with containment guard, `-WhatIf`, `-Force`, multi-select.
- [x] Typed `DELETE` confirmation in CLI/TUI; gated confirm button in GUI.
- [x] Non-interactive refusal (exit 1) and `WARN` audit logging.

### Phase 10: Future Roadmap
- [ ] Cloud backup cleanup (`psmgr clean-backups --cloud`).
- [ ] Backup retention policy (`--keep N`).
- [ ] Notification daemon for background PowerShell updates.
- [ ] Containerised CI leg for profile audit only.

---

## 2. Quality Gates & Acceptance Criteria

1. **Linting**: Every `.ps1`, `.psm1`, `.psd1` file must parse cleanly via `[System.Management.Automation.Language.Parser]` with 0 errors.
2. **Module Validation**: `Test-ModuleManifest` must pass with 0 errors.
3. **Execution Safety**: Non-interactive pipelines must never throw unhandled console exceptions.
4. **Encoding Integrity**: Console output must remain readable without garbled characters on legacy conhost and Windows Terminal.
5. **Tri-Interface Parity**: `tests/test_interface_parity.ps1` must report every registry capability present in CLI, TUI, and GUI.
6. **Destructive Safety**: deletion paths must be containment-guarded, typed-confirmation gated, and fail closed when non-interactive.
7. **Remote Verification**: a change is only "done" after `gh run watch --exit-status` reports success.
