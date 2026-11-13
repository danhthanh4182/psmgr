# Action map — GUI / TUI / CLI

Canonical cross-interface table (AC-X1). Names come from `modules/Core/ActionRegistry.ps1`
(`Id`, `TitleKey`), so the same capability carries the same name in every interface. The GUI
column is post-Track A (navigation page + element); the TUI and CLI columns are the *current*
state, which Track C (addendum scope) will restructure — old keys/commands must keep working as
aliases until then.

CLI syntax today is `ps-manager.ps1 -Action <name>` (plus `-Value`, `-Url`, `-Fix`, `-DryRun`,
`-NoColor`, `-Force`); the `psmgr <verb>` tree in the addendum is a proposal, not shipped.

| Action (shared name) | GUI | TUI | CLI |
|---|---|---|---|
| Set PS7 as default | Overview → `BtnSetDefaultPS7` (primary) | `d` (legacy `1`, `D`) | `-Action set-default-ps7` |
| Restore PS5 as default | Overview → `BtnRestorePS5` | `r` (legacy `2`, `R`) | `-Action set-default-ps5` |
| Update source & channel | Update → `BtnSrcWinget` / `BtnSrcMsstore` / `BtnSrcGithub`, `BtnChStable` / `BtnChPreview` / `BtnChLts` | `c` (legacy `3`, `S`) | `-Action source` / `set-source` / `set-channel` |
| Update PowerShell | Update → `BtnUpdate` (primary) | `u` (legacy `4`, `U`) | `-Action update` |
| Install / reinstall PowerShell | Update → `BtnInstall` | `i` (legacy `5`, `I`) | `-Action install` |
| Sync links & packages | Update → `BtnSyncNow` | `y` (legacy `Y`) | `-Action sync` |
| Sync Winget sources | Update → `BtnSyncSources` | `w` (legacy `W`) | `-Action sync-sources` |
| Doctor audit | Health → `BtnDoctorAudit` (primary) | `o` (legacy `O`) | `-Action doctor` |
| Doctor fix | Health → `BtnDoctorFix` | `o`, then `F` on the issue prompt | `-Action doctor -Fix` |
| Diagnostics | Health → `BtnDiagnostics` | `z` (legacy `0`) | `-Action diagnostics` |
| Launch PS7 | Overview → `BtnLaunchPS7` | `6` | `-Action switch-ps7` |
| Launch PS7 (admin) | Overview → `BtnLaunchPS7Admin` | `7` | `-Action switch` |
| Split view PS7 + PS5 | Overview → `BtnLaunchSplit` | `8` | `-Action switch` |
| Launch PS5 | Overview → `BtnLaunchPS5` | `9` | `-Action switch-ps5` |
| Open TUI console | Header → `BtnLaunchTUI` | `g` global (legacy `G`) | `-Action gui` (GUI launcher) / `-Action tui` |
| Switch language | Header → `BtnLangToggle` | `l` global (legacy `L`) | `-Action set-lang` |
| Edit profiles | Profiles → `BtnEditProfile` | `e` (legacy `P`) | `-Action edit-profile` |
| Audit / repair profiles | Profiles → `BtnAuditProfiles` (primary) | `t` (legacy `T`) | `-Action audit-profile [-Fix]` |
| Adopt live profiles | Profiles → `BtnAdoptProfiles` | `m` (legacy `A`) | `-Action adopt` |
| Backup profiles | Backup → `BtnBackupProfiles` (primary) | `b` (legacy `B`) | `-Action backup` |
| Backup to cloud | Backup → `BtnBackupCloud` | `n` (legacy `C`) | `-Action backup-cloud` |
| Set backup repo | Backup → `BtnSetCloudRepo` | `j` | `-Action set-cloud-repo [owner/repo]` |
| Restore backup | Backup → `BtnRestoreBackup` | `k` (legacy `K`) | `-Action restore` |
| View logs | Log header → `BtnViewLogs` | `f` (legacy `V`) | `-Action logs` |
| Delete backups | Backup → `BtnDeleteBackups` (**destructive**) | `x` (legacy `X`; typed `y` confirm) | `-Action clean-backups` |
| Status | Overview status cards + Header → `BtnRefresh` | status band (top of screen) | `-Action status` |
| Copy log | Log header → `BtnLogCopy` | — (GUI-only) | — (GUI-only) |
| Clear log | Log header → `BtnLogClear` | — (GUI-only) | — (GUI-only) |
| Cancel running action | Log header → `BtnCancelAction` | — (not implemented yet) | — (not implemented yet) |
| Help & About | Header → `BtnHelp`, rail → `NavHelp` (page `PageHelp`) | `h` (legacy `H`, `?` overlay) | `-Action help [command]` |
| Check for PSManager updates | Help → `BtnCheckUpdate` (primary) | `v` | `-Action update-check` |
| Install PSManager update | Help → `BtnInstallUpdate` | `p` (typed `y` confirm) | `-Action update-app [-Force]` |
| Notifications | Header → `BtnNotifications` (badge `NotifBadge`) | `!` (modal: `c` clear, `r` read, `o` open) | `-Action notifications -Value all\|read\|clear` |

## Notes

- GUI names in this table are `x:Name` values in `ui/PSManager.MainWindow.xaml`; the same strings are
  asserted by `tests/test_gui_xaml.ps1` and `tests/test_interface_parity.ps1`.
- `BtnCancelAction` and the log copy/clear controls are GUI-local; Track C may add a cancel path to
  TUI/CLI, in which case this table gains entries rather than renaming existing ones.
- TUI key letters here are the *current* keys. Track C introduces mnemonic keys with the old ones as
  hidden aliases (addendum H-keys rule), so this column becomes "new key (alias old key)".
- Screen names follow the GUI information architecture: Overview, Update, Backup, Health, Profiles;
  the TUI grouping (Shell, Quick launch, Update, Backup, Health & Profiles) maps onto the same set.
