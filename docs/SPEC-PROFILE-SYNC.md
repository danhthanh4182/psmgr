# PSManager Profile Sync & Multi-Package Provisioning Specification

- **Subsystem**: Profile Sync & Tool Provisioning Engine
- **Target Parent**: PSManager (`psmgr`) v1.4.0
- **Status**: Approved Design
- **Platform**: Windows 10 (Build 19041+) / Windows 11 (Build 22000+)
- **Runtime**: Windows PowerShell 5.1 (Desktop) & PowerShell 7.4+ (Core)

---

## 1. Vision & Architecture

### 1.1 Problem Statement
When setting up a clean Windows machine or syncing configurations across multiple workstations, users face repetitive, error-prone manual setup: installing PowerShell 7, configuring default shells, installing package managers (Winget, Scoop), installing developer CLI tools and PowerShell modules, and linking dotfiles. Furthermore, configurations must operate seamlessly across both legacy Windows PowerShell 5.1 and modern PowerShell 7 without font corruption or missing command errors.

### 1.2 The Decoupled 3-Layer Hybrid Architecture
```
+-----------------------------------------------------------------------------------+
| 1. ENGINE LAYER: PSManager (Public Open-Source)                                   |
|    Location: ~/tools/ps-manager                                                   |
|    Modules:                                                                       |
|      - modules/Sync/Manifest.ps1     : Parse & validate manifest.json schema      |
|      - modules/Sync/Linker.ps1       : Safe Hardlink / Junction / Copy engine     |
|      - modules/Sync/Provisioner.ps1  : Orchestrate Winget, Scoop, PSGallery       |
|      - modules/Sync/Backup.ps1       : Profile backup & snapshot engine           |
|      - modules/Sync/SyncEngine.ps1   : End-to-end sync dispatcher & doctor check  |
|    Entrypoint: boot.ps1 (Remote web-bootstrap executable from raw PS 5.1)         |
+-----------------------------------------+-----------------------------------------+
                                          | Orchestrates & Loads
+-----------------------------------------v-----------------------------------------+
| 2. PAYLOAD LAYER: User Dotfiles (Private / Git Remote)                             |
|    Default Location: ~/.dotfiles                                                  |
|    Contents:                                                                      |
|      ├── manifest.json              : Package list, bucket list, link bindings    |
|      ├── profiles/                                                                |
|      │   └── master_profile.ps1     : Unified profile for both PS 5.1 and PS 7    |
|      ├── configs/                                                                 |
|      │   ├── starship.toml          : Starship prompt theme configuration         |
|      │   └── powershell.config.json : PowerShell Core runtime options             |
|      └── local.ps1.example          : Template for host-specific tokens/keys      |
+-----------------------------------------+-----------------------------------------+
                                          | Applies To
+-----------------------------------------v-----------------------------------------+
| 3. OS TARGET LAYER: Dual-Shell Runtime Environment                                |
|    - Windows PowerShell 5.1: $HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1
|    - PowerShell 7 Core     : $HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1
|    - CLI Shims Directory   : $HOME\scoop\shims (added to User PATH)               |
|    - App Locations         : %ProgramFiles% (PowerShell 7, Windows Terminal, Git) |
|    - Shell Delegation Host : HKCU:\Console\%%Startup                              |
+-----------------------------------------------------------------------------------+
```

---

## 2. Functional Requirements

### FR-1: Manifest Schema & Validation (`manifest.json`)
- **FR-1.1**: Support structured JSON schema declaring:
  - `version`: Manifest format version (SemVer).
  - `packages.winget`: Array of `{ "id": string, "source": string }`.
  - `packages.scoop.buckets`: Array of bucket names (e.g., `extras`, `nerd-fonts`).
  - `packages.scoop.apps`: Array of app names (e.g., `starship`, `fnm`, `fzf`, `ripgrep`).
  - `packages.psgallery`: Array of `{ "name": string, "minVersion": string, "scope": string }`.
  - `links`: Array of `{ "source": string, "targets": string[], "type": "hardlink" | "symlink" | "copy" }`.
  - `env`: Key-value map of environment variables to export to User environment.
- **FR-1.2**: Provide strict schema validation. Missing optional fields must fall back gracefully to empty arrays/objects.

### FR-2: Safe Linking Engine (`Linker.ps1`)
- **FR-2.1**: Implement `New-SafeLink` with automatic fallback strategy:
  1. Primary: **Hardlink** (`fsutil hardlink create` or Win32 API `CreateHardLink`). Requires no Developer Mode or Administrator privileges.
  2. Secondary: **Symbolic Link** (`New-Item -ItemType SymbolicLink`). Used if targets cross volume boundaries.
  3. Tertiary: **Copy** (`Copy-Item -Force`) with SHA256 checksum comparison.
- **FR-2.2**: Conflict Resolution: If target exists and is not already linked to source:
  - Automatically create `.bak.<timestamp>` backup before replacing.
- **FR-2.3**: Path Normalization: Expand `~` and `$HOME` to current user profile path reliably on both PS5 and PS7.

### FR-3: Multi-Package Provisioning Engine (`Provisioner.ps1`)
- **FR-3.1 Winget Orchestrator**:
  - Detect installed packages using `winget list --exact --id <id>`.
  - Install missing packages using `winget install --exact --id <id> --accept-source-agreements --accept-package-agreements --silent`.
- **FR-3.2 Scoop Orchestrator**:
  - Check if Scoop is installed at `~scoop\shims\scoop.cmd`.
  - If missing, automatically bootstrap Scoop via `irm get.scoop.io | iex`.
  - Synchronize configured buckets (`scoop bucket add <bucket>`).
  - Install declared apps (`scoop install <app>`).
- **FR-3.3 PSGallery Orchestrator**:
  - Enforce TLS 1.2 on PS 5.1 (`[Net.ServicePointManager]::SecurityProtocol`).
  - Ensure NuGet package provider is installed and trusted.
  - Install/update declared modules with `-Scope CurrentUser -Force -AllowClobber`.

### FR-4: Dual-Profile Runtime Architecture (`master_profile.ps1`)
- **FR-4.1 Encoding Guard**:
  - On PS 5.1: set `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` to prevent raster font corruption.
  - On PS 7+: set `$OutputEncoding = [System.Text.UTF8Encoding]::new($false)` and console streams to UTF-8.
- **FR-4.2 CLI Tools Integration**:
  - Prepend `$env:USERPROFILE\scoop\shims` to `$env:PATH` idempotently.
  - Initialize `fnm` if installed: `fnm env --use-on-cd --shell powershell`.
  - Initialize `starship` if installed: `Invoke-Expression (& starship init powershell)`.
- **FR-4.3 PS7 Modern Extensions**:
  - Configure `PSReadLine` predictive IntelliSense (`HistoryAndPlugin`, `ListView`).
  - Load `Terminal-Icons` if available.
- **FR-4.4 Host-Specific Extensibility**:
  - Probe for `local.ps1` in the profile directory and dot-source it if present (`. $LocalProfile`).
  - `local.ps1` must be excluded from Git tracking.

### FR-5: CLI Subcommands & TUI Integration
- **`psmgr sync`**:
  - Pull latest commits from dotfiles Git remote (if Git repo).
  - Provision missing packages across Winget, Scoop, PSGallery.
  - Apply link mappings from `manifest.json`.
  - Configure environment variables.
- **`psmgr backup`**:
  - Archive active profiles and configs into a timestamped `.zip` bundle under `~/tools/ps-manager/backups/`.
  - Supports passphrase-based Encrypt-then-MAC (`psmgr backup enc`: AES-256-CBC + HMAC-SHA256, 100k PBKDF2 rounds, `.zip.enc`).
  - Supports Windows DPAPI mode (`psmgr backup dpapi`: `System.Security.Cryptography.ProtectedData`, current-user machine bound).
- **`psmgr backup-cloud`**:
  - Create a fresh profile backup and publish it as an asset to a private GitHub repository release using `gh release create`.
  - Automatically prompts for passphrase encryption; resolves destination repository dynamically.
- **`psmgr restore`**:
  - Restore shell profiles and configs from previous `.zip` or `.zip.enc` backup.
  - Automatically detects `PSMGRD` (DPAPI) for transparent restore or prompts for passphrase if protected by `PSMGR2` / `PSMGR1`.
- **`psmgr doctor`**:
  - Audit status of all declared links, package availability (with `AppResolver.ps1` binary mapping), and environment variables with formatted color output.
  - 1-click auto-repair via `psmgr doctor -Fix`.
- **`psmgr adopt`**:
  - Reverse adoption: copy active machine profiles (`PowerShell` + `WindowsPowerShell`) and `starship.toml` into payload templates as the new source of truth (`Import-PSManagerProfiles`), with `.bak.<timestamp>` backups and automatic re-linking.
- **`psmgr edit-profile` / `psmgr edit`**:
  - Quick launcher opening active shell profile in VS Code or Notepad.
- **`psmgr sync-sources`**:
  - Refresh and update registered Winget catalog sources (`winget source update`).
- **`psmgr logs`**:
  - Inspect persistent diagnostic logs (`psmgr_*.log`) with `--tail <N>` and `--errors` filters.
- **TUI Dashboard Menu**:
  - Complete 23-action keyboard integration synchronized with Action Registry:
    - `[1][2]` Default Shell (PS7 / PS5.1)
    - `[3][4][5]` Update Source, Upgrade, and Install
    - `[6][7][8][9]` Launch targets (PS7, PS7 Admin, Split, PS5)
    - `[0][G][L][P]` Diagnostics, Desktop GUI, Language, Edit Profile
    - `[Y][O][A]` Dotfiles Sync, Doctor Audit / Fix, Adopt Profiles
    - `[B][C][K]` Local Backup, Cloud Backup, Restore Backup
    - `[V][W][Q]` View Logs, Sync Sources, Exit
    - `[T]` Audit & Repair profile compatibility (PS 5.1 / PS 7)
    - `[X]` Delete local backups (destructive, typed `DELETE`)

### FR-6: Zero-State Web Bootstrapper (`boot.ps1`)
- **FR-6.1**: Single-command execution from clean Windows PowerShell 5.1 prompt:
  ```powershell
  irm https://raw.githubusercontent.com/<user>/ps-manager/main/boot.ps1 | iex
  ```
- **FR-6.2 2-Stage Handover Lifecycle**:
  - **Stage 1 (PS 5.1)**:
    1. Set TLS 1.2 security protocol.
    2. Check and install `winget` (if on older Win10 build) and `git`.
    3. Install PowerShell 7 (`winget install Microsoft.PowerShell`).
    4. Clone `ps-manager` repo to `$env:USERPROFILE\tools\ps-manager`.
    5. Handover: spawn `pwsh.exe -File "$env:USERPROFILE\tools\ps-manager\ps-manager.ps1" sync --bootstrap`.
  - **Stage 2 (PS 7 Core)**:
    1. Complete package provisioning via Scoop and PSGallery.
    2. Apply profile links.
    3. Call `Set-PowerShell7Default` to configure Windows Terminal, delegation, and PATH shims.

---

## 3. Data Schema & Contracts

### 3.1 `manifest.json`
```json
{
  "$schema": "https://raw.githubusercontent.com/danhthanh4182/psmgr/main/schema/v1.json",
  "version": "1.0.0",
  "packages": {
    "winget": [
      { "id": "Microsoft.PowerShell", "source": "winget" },
      { "id": "Microsoft.WindowsTerminal", "source": "winget" },
      { "id": "Git.Git", "source": "winget" }
    ],
    "scoop": {
      "buckets": ["extras", "nerd-fonts"],
      "apps": ["starship", "fnm", "fzf", "ripgrep", "jq", "zoxide"]
    },
    "psgallery": [
      { "name": "PSReadLine", "minVersion": "2.3.4", "scope": "CurrentUser" },
      { "name": "Terminal-Icons", "scope": "CurrentUser" },
      { "name": "posh-git", "scope": "CurrentUser" }
    ]
  },
  "links": [
    {
      "source": "profiles/master_profile.ps1",
      "targets": [
        "~/Documents/PowerShell/Microsoft.PowerShell_profile.ps1",
        "~/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"
      ],
      "type": "hardlink"
    },
    {
      "source": "configs/starship.toml",
      "targets": ["~/.config/starship.toml"],
      "type": "hardlink"
    },
    {
      "source": "configs/powershell.config.json",
      "targets": ["~/Documents/PowerShell/powershell.config.json"],
      "type": "copy"
    }
  ],
  "env": {
    "STARSHIP_CONFIG": "~/.config/starship.toml"
  }
}
```

### 3.2 `config.json` Extension
```json
{
  "updateSource": "winget",
  "channel": "stable",
  "language": "vi",
  "dotfilesRepo": "https://github.com/user/dotfiles.git",
  "dotfilesPath": "~/.dotfiles",
  "autoBackup": true
}
```

---

## 4. Security & Safety Principles

1. **Zero Secret Leakage**: `ps-manager` engine remains 100% public-safe. All private tokens, SSH keys, and custom secrets are stored strictly in `local.ps1` or private dotfiles repos.
2. **Reversible Operations**: Every file overwritten during linking is snapshotted into `.bak.<timestamp>` or the zip backup directory.
3. **Execution Safety**: Execution policy is managed per-session (`-ExecutionPolicy Bypass`), leaving global Windows security untouched.
4. **Idempotence**: Running `psmgr sync` 10 times in a row produces identical state without duplicate PATH entries, redundant installs, or broken links.
