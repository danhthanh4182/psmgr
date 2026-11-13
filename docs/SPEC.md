# PSManager Technical Specification (SPEC)

- **Product Name**: PSManager (`psmgr`)
- **Version**: 1.3.0
- **Authors**: Thanh
- **Status**: Stable / Production Ready
- **Platform**: Windows 10 (Build 19041+) / Windows 11 (Build 22000+)
- **Runtime**: PowerShell 5.1 (Desktop) & PowerShell 7.4+ (Core)

---

## 1. Vision & Problem Statement

Windows ships with Windows PowerShell 5.1 as system default. When users install modern PowerShell 7 (`pwsh`), Windows continues routing various invocation vectors (`powershell` command, Run dialog, Explorer context menu, file association, Windows Terminal default profiles) to legacy PowerShell 5.1.

**PSManager** provides an end-to-end management suite to:
1. Seamlessly configure PowerShell 7 as the default shell across all Windows touchpoints without breaking system stability.
2. Provide a 1-click revert capability back to Windows PowerShell 5.1.
3. Manage update sources across **Winget Community**, **Microsoft Store**, and **GitHub Direct Releases**.
4. Offer 3 operation interfaces:
   - **Interactive TUI**: Arrow-key driven, ANSI-styled console dashboard.
   - **CLI**: Standard scriptable subcommands for automated workflows.
   - **Desktop GUI**: Native, zero-dependency dark-mode WPF application.
5. Provide explicit three-mode language selection (**English**, **Tiếng Việt có dấu**, **Tiếng Việt không dấu**) shared by the CLI, TUI and desktop GUI.

---

## 2. Functional Requirements

### FR-1: Default Shell Orchestration
- **FR-1.1**: Set Windows Terminal `defaultProfile` to detected PowerShell 7 GUID (`{5fb123f1-af88-5b5c-8953-d14a8def1978}` or dynamic Core profile).
- **FR-1.2**: Update Windows 11 default terminal delegation host in `HKCU:\Console\%%Startup` (`DelegationConsole` and `DelegationTerminal` targeting Windows Terminal CLSID).
- **FR-1.3**: Deploy user PATH redirection shim (`powershell.cmd`) forwarding CLI calls to `pwsh.exe %*`.
- **FR-1.4**: Provide fallback shim `winps.cmd` allowing explicit invocation of native Windows PowerShell 5.1.
- **FR-1.5**: Set VS Code user profile default terminal: `"terminal.integrated.defaultProfile.windows": "PowerShell 7"`.
- **FR-1.6**: Register Explorer right-click context menus: "Open in PowerShell 7" (folder and background) and `.ps1` "Run with PowerShell 7".
- **FR-1.7**: Revert operation restoring all configurations back to standard 5.1 state in a single action.

### FR-2: Update Source Management
- **FR-2.1**: Support switching primary package source between:
  - `winget`: Community repository (Package ID: `Microsoft.PowerShell`).
  - `msstore`: Microsoft Store repository (Package ID: `9MZ1SNWT0N5D`).
  - `github`: Direct GitHub Releases API (`PowerShell/PowerShell`).
- **FR-2.2**: Support release channels: `stable`, `preview` (`Microsoft.PowerShell.Preview` / `9P95ZZKTNRN4`), and `lts` (`9MXBK0PFV7PJ`).
- **FR-2.3**: Allow repository catalog synchronization (`winget source update`) and source reset.

### FR-3: User Interfaces
- **FR-3.1 TUI Console**:
  - Live status badges: Terminal profile, delegation host, shim state, active source/channel, language.
  - Interactive navigation: Up/Down arrow keys, Enter to activate, direct number/letter hotkeys.
  - Non-interactive / piped fallback to standard prompt without crashing.
- **FR-3.2 CLI Commands**:
  - `psmgr status`, `psmgr set-default [ps7|ps5]`, `psmgr source`, `psmgr set-source <src>`, `psmgr set-channel <ch>`, `psmgr set-lang <lang>`, `psmgr update`, `psmgr install`, `psmgr diagnostics`, `psmgr gui`, `psmgr help`.
  - `psmgr sync [-DryRun] [-SkipPackages]`, `psmgr doctor [-Fix]`, `psmgr backup`, `psmgr backup-cloud`, `psmgr restore`, `psmgr clean-backups [all|<names>] [-Force]`, `psmgr adopt`, `psmgr edit-profile`, `psmgr logs`, `psmgr audit-profile [-Fix]`, `psmgr sync-sources`.
- **FR-3.3 Desktop GUI**:
  - Standalone WPF XAML dark-mode window (`#0F172A`).
  - Real-time status cards, action buttons, execution output log console.

### FR-4: Internationalization (i18n)
- **FR-4.1 Explicit language modes**: The interface language is a stored setting, not a guess based on the PowerShell engine.
  - `en` - English.
  - `vi` - Tiếng Việt có dấu (UTF-8). Correct on Windows Terminal, VS Code and PowerShell 7.
  - `vi-ascii` - Tiếng Việt không dấu, for legacy consoles whose raster fonts cannot render diacritics (`?`).
  - `Get-EffectiveLanguage` returns the stored mode verbatim on PowerShell 5.1 and PowerShell 7; a missing or unknown value falls back to `vi` (PS 7) or `vi-ascii` (PS 5.1).
- **FR-4.2**: Every interface cycles `en` → `vi-ascii` → `vi` → `en`: `[L]` in the TUI, the language button in the GUI, and `psmgr set-lang <lang>` in the CLI. The TUI header and the GUI button label name the active mode.
- **FR-4.3**: The WPF GUI renders all three modes with full Unicode via DirectWrite and labels the active mode; it never silently rewrites the stored mode.

### FR-5: Unified Action Execution
- **FR-5.1**: All long-running operations MUST dispatch through `Invoke-PSManagerAction`, which owns subprocess creation, UTF-8 pipe handling, deadlock-free draining, ANSI stripping, and exit-code normalisation.
- **FR-5.2**: Asynchronous mode MUST stream output line-by-line (`ReadLineAsync`) on the WPF dispatcher and MUST flush the remaining pipe tail via `ReadToEnd()` after exit.
- **FR-5.3**: `Stop-PSManagerAction` MUST be able to terminate an in-flight action, clearing busy state without raising a completion callback.

### FR-6: Profile Compatibility
- **FR-6.1**: `Test-PSManagerProfile` MUST audit both runtime profiles for: file existence, AST validity, PS7-only operators on 5.1, `posh-git`→`starship` ordering, `Terminal-Icons` PS7 guard, `PSReadLine` prediction guard, and `STARSHIP_CONFIG` integrity.
- **FR-6.2**: `Repair-PSManagerProfile` MUST back up each profile before mutation and MUST be idempotent.
- **FR-6.3**: `templates/profiles/master_profile.ps1` MUST satisfy every audit check and MUST NOT contain machine-specific content (that belongs in `local.ps1`).
- **FR-6.4**: See [`SPEC-PROFILE-AUDIT.md`](SPEC-PROFILE-AUDIT.md).

### FR-7: Destructive Operations
- **FR-7.1**: Every operation that deletes user data MUST be containment-guarded, previewable (`-WhatIf` where applicable), and require explicit typed confirmation.
- **FR-7.2**: Non-interactive contexts MUST fail closed (exit `1`) unless `-Force` is passed.
- **FR-7.3**: Each invocation MUST emit a `WARN` audit entry.
- **FR-7.4**: See [`SPEC-BACKUP-CLEANUP.md`](SPEC-BACKUP-CLEANUP.md).

### FR-8: Tri-Interface Parity
- **FR-8.1**: Every user-facing capability MUST be registered in `modules/Core/ActionRegistry.ps1` and implemented in CLI, TUI, and GUI in the same commit.
- **FR-8.2**: `tests/test_interface_parity.ps1` MUST fail the build when any of the three drivers is missing a registered capability.

### FR-9: Development Lifecycle
- **FR-9.1**: Changes follow Issue → Spec → Plan → Implement → Verify → Ship → CI gate → Docs sync; see [`SDLC.md`](SDLC.md).
---

## 3. Data Schema & Contracts

### 3.1 `config.json`
```json
{
  "updateSource": "winget",
  "channel": "stable",
  "language": "vi"
}
```
- `updateSource`: `"winget"` | `"msstore"` | `"github"`
- `channel`: `"stable"` | `"preview"` | `"lts"`
- `language`: `"vi"` | `"vi-ascii"` | `"en"`

### 3.2 Registry Targets
| Path | Value Name | Target Value |
|---|---|---|
| `HKCU:\Console\%%Startup` | `DelegationConsole` | `{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}` |
| `HKCU:\Console\%%Startup` | `DelegationTerminal` | `{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}` |
| `HKCU:\Software\Classes\Directory\Background\shell\OpenPowerShell7` | `(default)` | `"Open in PowerShell 7"` |
| `HKCU:\Software\Classes\SystemFileAssociations\.ps1\shell\RunPS7` | `(default)` | `"Run with PowerShell 7"` |

---

## 4. Security & Safety Principles

1. **User Scope Only (`HKCU`)**: No administrative privileges required for default switching. System root remains untampered.
2. **Explicit Fallback Path (`winps`)**: Native `powershell.exe` in `System32` is never deleted or replaced on disk. Full path calls by Windows internals continue functioning normally.
3. **ExecutionPolicy Bypass**: All launcher shims pass `-ExecutionPolicy Bypass` scoped to script execution, avoiding system-wide policy tampering.
