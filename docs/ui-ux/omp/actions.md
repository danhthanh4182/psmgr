# GUI action inventory (Track A baseline)

27 user-facing GUI controls that perform an action, captured before the XAML/theme refactor and
re-verified after it. Source of truth for the count: `modules/Core/ActionRegistry.ps1` (23 registered
capabilities) plus 4 GUI-only log/header controls that have no registry entry.

Every row keeps its original handler (`Add_Click` body) and its original `x:Name`; the refactor moved
markup only. Side-effect class is what the handler does when activated — none of these were executed
during this development track.

## Registry-backed actions (23)

| # | Id | GUI element | Handler target | TUI key | CLI (`-Action`) | Side-effect class | New page |
|---|----|-------------|----------------|---------|-----------------|-------------------|----------|
| 1 | def7 | `BtnSetDefaultPS7` | `Set-PowerShell7Default -Silent` | `1` (Alt `D`) | `set-default-ps7` | system config (WT profile, host, shim, context menu, VSCode) | Overview |
| 2 | def5 | `BtnRestorePS5` | `Set-PowerShell5Default -Silent` | `2` (Alt `R`) | `set-default-ps5` | system config | Overview |
| 3 | source | `BtnSrcWinget` / `BtnSrcMsstore` / `BtnSrcGithub` | `Set-PSManagerConfig -Source` | `3` (Alt `S`) | `source` / `set-source` | config only | Update |
| 4 | update | `BtnUpdate` | `wt.exe … ps-manager.ps1 update` | `4` (Alt `U`) | `update` | installs packages | Update |
| 5 | install | `BtnInstall` | `wt.exe … ps-manager.ps1 install` | `5` (Alt `I`) | `install` | installs packages | Update |
| 6 | sync | `BtnSyncNow` | `Invoke-PSManagerAction -Action sync -Async` | `Y` | `sync` | writes links/packages | Update |
| 7 | doctor | `BtnDoctorAudit` | `Invoke-PSManagerAction -Action doctor -Async` | `O` | `doctor` | read-only audit | Health |
| 8 | adopt | `BtnAdoptProfiles` | `Adopt-PSManagerProfiles` | `A` | `adopt` | writes payload files | Profiles |
| 9 | backup | `BtnBackupProfiles` | `Backup-PSManagerProfiles` | `B` | `backup` | writes backup zip | Backup |
| 10 | backup-cloud | `BtnBackupCloud` | `Publish-PSManagerCloudBackup` | `C` | `backup-cloud` | network upload | Backup |
| 11 | restore | `BtnRestoreBackup` | `Restore-PSManagerBackup` | `K` | `restore` | overwrites profiles | Backup |
| 12 | logs | `BtnViewLogs` | `Get-PSManagerLogs -Tail 40` | `V` | `logs` | read-only | Log header |
| 13 | sync-sources | `BtnSyncSources` | `Invoke-PSManagerAction -Action sync-sources -Async` | `W` | `sync-sources` | network catalog update | Update |
| 14 | q_ps7 | `BtnLaunchPS7` | `Start-QuickShell -Target PS7` | `6` | `switch-ps7` | launches process | Overview |
| 15 | q_ps7a | `BtnLaunchPS7Admin` | `Start-QuickShell -Target PS7-Admin` | `7` | `switch` | launches elevated process | Overview |
| 16 | q_split | `BtnLaunchSplit` | `Start-QuickShell -Target Split` | `8` | `switch` | launches process | Overview |
| 17 | q_ps5 | `BtnLaunchPS5` | `Start-QuickShell -Target PS5` | `9` | `switch-ps5` | launches process | Overview |
| 18 | diag | `BtnDiagnostics` | `wt.exe … ps-manager.ps1 diagnostics` | `0` | `diagnostics` | read-only | Health |
| 19 | gui | `BtnLaunchTUI` | `wt.exe … ps-manager.ps1 tui` | `G` | `gui` | launches process | Header |
| 20 | lang | `BtnLangToggle` | `Set-PSManagerConfig -Language` | `L` | `set-lang` | config only | Header |
| 21 | prof | `BtnEditProfile` | `Start-Process code|notepad.exe` | `P` | `edit-profile` | launches editor | Profiles |
| 22 | audit-prof | `BtnAuditProfiles` | `Invoke-PSManagerAction -Action audit-profile -Async` | `T` | `audit-profile` | read-only audit (offers `-Fix`) | Profiles |
| 23 | clean-backups | `BtnDeleteBackups` | `Remove-PSManagerBackup -Force` | `X` | `clean-backups` | **destructive** | Backup |

## GUI-only controls (4)

| # | Id | GUI element | Handler target | TUI | CLI | Side-effect class | New page |
|---|----|-------------|----------------|-----|-----|-------------------|----------|
| 24 | refresh | `BtnRefresh` | `Update-DashboardUI` | — | — | read-only refresh | Header |
| 25 | copy-log | `BtnLogCopy` | `TextRange` → `Clipboard.SetText` | — | — | clipboard only | Log header |
| 26 | clear-log | `BtnLogClear` | clears `$Script:LogEntries` + document | — | — | UI state only | Log header |
| 27 | cancel-action | `BtnCancelAction` | `Stop-PSManagerAction` | — | — | stops a running action | Log header |

## Channel selector (part of action 3)

`BtnChStable` / `BtnChPreview` / `BtnChLts` call `Set-PSManagerConfig -Channel` and are the segmented
partner of action 3; they are counted once, not as three actions.

## Verification

`tests/test_interface_parity.ps1` asserts the registry-backed rows still exist as `x:Name`s in `ui\*.xaml`
and `gui.ps1`; `tests/test_gui_xaml.ps1` asserts all 27 names resolve through `FindName`. See
`docs/ui-ux/action-map.md` for the GUI/TUI/CLI mapping table.
