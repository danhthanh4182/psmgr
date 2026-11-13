# PSManager Architecture & Internal Design

## 1. System Topology

```
+---------------------------------------------------------------------------------+
|                                USER INTERFACES                                  |
|   +-----------------------+  +-----------------------+  +-------------------+   |
|   |   Interactive TUI     |  |      CLI Harness      |  |  WPF Desktop App  |   |
|   | (TuiEngine / Theme)   |  |   (ps-manager.ps1)    |  |     (gui.ps1)     |   |
|   +-----------+-----------+  +-----------+-----------+  +---------+---------+   |
+---------------|--------------------------|------------------------|-------------+
                |                          |                        |
                +--------------------------v------------------------+
                                           |
                              +-------------------------+
                              |     PSManager Module    |
                              |     (PSManager.psm1)    |
                              +------------+------------+
                                           |
         +---------------------------------+---------------------------------+
         |                                 |                                 |
+--------v--------+               +--------v--------+               +--------v--------+
|   Core Engine   |               |   Environment   |               | Package Manager |
| - Encoding.ps1  |               | - Detection.ps1 |               | - SourceMgr.ps1 |
| - Config.ps1    |               | - SysConfig.ps1 |               | - Updater.ps1   |
| - I18n.ps1      |               | - Launcher.ps1  |               +-----------------+
| - Logger.ps1    |               +-----------------+                        |
+-----------------+                        |                                 |
         |                                 |                        +--------v--------+
         |                                 |                        |   Sync Engine   |
         |                                 |                        | - Manifest.ps1  |
         |                                 |                        | - Linker.ps1    |
         |                                 |                        | - Provision.ps1 |
         |                                 |                        | - AppResolver   |
         |                                 |                        | - Backup.ps1    |
         |                                 |                        | - SyncEngine.ps1|
         |                                 |                        +-----------------+
         |                                 |                                 |
+--------v--------+               +--------v--------+               +--------v--------+
| config.json     |               | Windows Terminal|               | winget CLI      |
| i18n.json       |               | Registry (HKCU) |               | msstore ID      |
| Win32 Console   |               | User PATH shims |               | GitHub Releases |
| psmgr_*.log     |               | Explorer Shell  |               | backups/*.enc   |
+-----------------+               +-----------------+               +-----------------+
```

---

## 2. Module Responsibilities

### `Core/`
- **`ActionRegistry.ps1`**: Defines the central **23-action** capability registry ensuring simultaneous tri-interface feature parity across CLI (`ps-manager.ps1`), TUI (`modules/UI/TuiEngine.ps1`), and Desktop GUI (`gui.ps1`).
- **`ActionEngine.ps1`**: Deep execution module (`Invoke-PSManagerAction`, `Stop-PSManagerAction`, `Format-PSManagerActionOutput`). Owns subprocess lifecycle, UTF-8 non-locking pipe tasks, deadlock-free draining (>64KB), live `ReadLineAsync` streaming on the WPF `DispatcherTimer`, ANSI sanitisation, and exit-code contracts. Callers see one function; GUI, CLI and tests cross the same seam.
- **`Encoding.ps1`**: Enforces Code Page 65001 (UTF-8) across managed console streams and underlying Win32 console host. Prevents character decoding failures on legacy conhost.
- **`Config.ps1`**: Reads and writes persistent state (`config.json`) with strict schema validation and fallback defaults.
- **`I18n.ps1`**: Manages the multilingual string dictionary (`i18n.json`, 279 keys per mode). `Get-EffectiveLanguage` returns the stored mode (`en`, `vi`, `vi-ascii`) verbatim on PowerShell 5.1 and 7; only a missing or unknown value falls back to `vi` (PS 7) or `vi-ascii` (PS 5.1). Supports per-call language override for the WPF GUI, which renders all three modes as Unicode.
- **`Logger.ps1`**: Persistent diagnostic file logger with non-locking shared read/write streams (`psmgr_*.log`), tail filtering, and retention pruning.

### `Environment/`
- **`Detection.ps1`**: Gathers hardware bitness, installed PowerShell versions, Windows Terminal profile GUIDs, registry delegation state, and PATH shims.
- **`SystemConfig.ps1`**: Implements 1-click apply and revert operations across Windows Terminal `settings.json`, `HKCU:\Console\%%Startup`, user PATH `.cmd` shims, VS Code settings, and Explorer context menu.
- **`Launcher/ShellSwitcher.ps1`**: Dispatches target shell instances (PS7, PS7 Admin, PS5, PS5 Admin, Split view via `new-tab ; split-pane`) using `wt.exe` or direct executables.

### `Package/`
- **`SourceManager.ps1`**: Resolves target package IDs and channel mappings for `winget` (`Microsoft.PowerShell`), `msstore` (`9MZ1SNWT0N5D`), and `github`.
- **`Updater.ps1`**: Orchestrates update and install workflows using Winget or GitHub Releases API.

### `Sync/`
- **`Manifest.ps1`**: Validates and parses `manifest.json` schema v1.0.0 for package and link specifications.
- **`Linker.ps1`**: Safe hardlink, symlink, and copy engine with volume-root check, directory auto-creation, and `.bak.<timestamp>` file backups.
- **`Provisioner.ps1`**: Batched, idempotent package installer across Winget, Scoop, and PSGallery.
- **`AppResolver.ps1`**: Maps package names to binary executable shims (e.g. `ripgrep` -> `rg.exe`) for accurate availability audits.
- **`Backup.ps1`**: Profile snapshot, restore, **and guarded deletion** engine. Supports AES-256-CBC + HMAC-SHA256 Encrypt-then-MAC (`PSMGR2`), Windows DPAPI (`PSMGRD`), automated cloud publishing via `gh release create`, and `Remove-PSManagerBackup` (`SupportsShouldProcess`, `ConfirmImpact = High`, containment-guarded, multi-name/`-All` selection, WARN audit logging).
- **`SyncEngine.ps1`**: End-to-end sync dispatcher, reverse profile adoption (`Import-PSManagerProfiles`), and environment health doctor audit with 1-click auto-repair (`psmgr doctor -Fix`). Doctor check #8 delegates to `ProfileAuditor`.
- **`ProfileAuditor.ps1`**: Dual-runtime profile compatibility auditor and repair engine (`Test-PSManagerProfile`, `Repair-PSManagerProfile`). Detects PS7-only operators on 5.1, `posh-git`/`starship` ordering inversions, unguarded `Terminal-Icons`, unprotected `PSReadLine` prediction calls, and broken `STARSHIP_CONFIG`; repairs are preceded by timestamped `.bak` copies. Guard detection uses brace-balanced scanning (`Test-ProfileBlockEnclosing`) rather than flat regexes.

### `UI/`
- **`Theme.ps1`**: Defines 24-bit TrueColor ANSI palette and approved formatting helpers (`Format-ColorText`, `Format-ColorBadge`).
- **`Diagnostics.ps1`**: Renders comprehensive side-by-side version and environment audit table.
- **`TuiEngine.ps1`**: Full-screen interactive terminal dashboard with key navigation, grapheme cluster column alignment (`Get-DisplayWidth`), live status badges, **23 action keybindings**, and submenus.
- **`gui.ps1`**: Standalone WPF XAML Dark Application running native DirectX/DirectWrite text rendering with 24 resolution-independent SVG vector icons (`StreamGeometry`) and full feature parity (Backup, Restore, Cloud, Doctor, Sync, Profile Adoption, Profile Audit, Backup Deletion). Async work is delegated to `ActionEngine`; the window also renders a busy `ProgressBar`, a cancel button, a filterable 500-line log, and persists geometry to `gui_state.json`.

---

## 3. Delegation & Invocation Mechanics

```
User runs "powershell"
         |
         v
PATH Lookup: C:\Users\<User>\bin\powershell.cmd (High Priority)
         |
         v
Executes pwsh.exe %* (PowerShell 7)

User runs "winps"
         |
         v
Executes %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe %* (Legacy 5.1)

Windows Terminal launch
         |
         v
settings.json defaultProfile: {5fb123f1-af88-5b5c-8953-d14a8def1978} -> PowerShell 7
```

> Behavioural diagrams (parity enforcement, action execution, sync, profile
> audit/repair, destructive cleanup, dual-runtime selection) live in
> [`docs/DIAGRAMS.md`](DIAGRAMS.md). The development lifecycle and gates are in
> [`docs/SDLC.md`](SDLC.md).

---

## 4. Seams & Extension Points

| Seam | Interface | Adapters |
|------|-----------|----------|
| Action dispatch | `Invoke-PSManagerAction` / `Stop-PSManagerAction` | in-process (sync), hidden child process (async), test doubles |
| Capability contract | `Get-PSManagerActions` (registry) | CLI `ValidateSet`, TUI `menuItems`, GUI `x:Name`/`Add_Click` |
| Package provisioning | `Install-WingetBatch` / `Install-ScoopBatch` / `Install-PSGalleryBatch` | winget, scoop, PSGallery; `-DryRun` |
| Linking | `New-SafeLink` | hardlink → symlink → copy fallback |
| Backup storage | `Backup-PSManagerProfiles` / `Get-PSManagerBackups` / `Remove-PSManagerBackup` / `Restore-PSManagerBackup` | local dir, cloud release |
| Profile truth | `Test-PSManagerProfile` / `Repair-PSManagerProfile` | per-runtime targets (5.1, 7) |

New capability checklist:

1. Add the entry to `modules/Core/ActionRegistry.ps1`.
2. Implement the engine function in `modules/`.
3. Wire CLI (`ValidateSet` + `switch`), TUI (`$menuItems` + `switch`), GUI
   (`x:Name`, `FindName`, `busyButtons`, label, `Add_Click`).
4. Add i18n keys for all three languages.
5. Add/extend a test suite and register it in `tests/harness.ps1`.
6. Update `README.md`, `CONTEXT.md`, `CHANGELOG.md`, and the relevant
   `docs/SPEC-*` / `docs/PLAN-*`.
