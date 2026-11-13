# ⚡ PSManager (`psmgr`)

> **Modern PowerShell Version Manager & Control Center for Windows**  
> 1-Click Set PowerShell 7 as Default, Interactive TUI, Native Desktop App (WPF), Multi-Source Updater (Winget / MSStore / GitHub), and Adaptive Bilingual Engine.

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-blue.svg)](https://microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207.4%2B-5391FE.svg?logo=powershell)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-119%2F119%20Passing-brightgreen.svg)](tests/)

---

## 🌟 Overview

When users install modern PowerShell 7 (`pwsh`), Windows continues routing traditional launch points (Run dialog, `powershell` command, Windows Terminal default profiles, context menus) to legacy Windows PowerShell 5.1.

**PSManager** is an enterprise-grade, modular tool suite that:
1. **Sets PowerShell 7 as the default shell** across Windows Terminal, Windows 11 host delegation, PATH command shims, VS Code, and Explorer context menus.
2. **Reverts to Windows PowerShell 5.1** in 1 click whenever needed.
3. **Manages update sources**: switch seamlessly between **Winget Community**, **Microsoft Store**, and **GitHub Direct Releases**.
4. **Offers 3 modern interfaces**:
   - 💻 **Interactive TUI**: Arrow-key navigation, ANSI theme, live status badges, hotkeys.
   - 🖥️ **Desktop GUI**: Native, zero-dependency dark-mode WPF application.
   - ⌨️ **Scriptable CLI**: Fast, robust commands for automation and terminal pros.
5. **Three-Mode Language Engine**: **English**, **Tiếng Việt có dấu** (`vi`), and **Tiếng Việt không dấu** (`vi-ascii`) are explicit, user-selectable modes shared by the CLI, TUI and desktop GUI.

---

## 📦 Install

`install.ps1` resolves a release, verifies the installer digest against the published
`SHA256SUMS.txt`, and installs it. It runs on Windows PowerShell 5.1 and PowerShell 7 alike.

> **Private repository:** the release assets are not publicly reachable yet, so every method needs
> an authenticated request. Either run `gh auth login` once, or export `PSMGR_GITHUB_TOKEN`, or pass
> `-Token`. The direct script download and bare `winget` forms become credential-free once the repository is
> public; the same commands then work unchanged.

> **Pin the bootstrapper when you can.** The `.../main/install.ps1` one-liners execute whatever
> is on `main` at that moment. For reproducible installs download `install.ps1` from a release tag
> (`.../raw/v<version>/install.ps1`) or read the script before running it; the release assets it
> installs are always digest-verified.

### 1. Windows PowerShell 5.1

```powershell
# Authenticated (works today): read install.ps1 from the private repo, then run it
powershell -NoProfile -ExecutionPolicy Bypass -Command "gh api repos/danhthanh4182/psmgr/contents/install.ps1 -H 'Accept: application/vnd.github.raw' | Set-Content -Path $env:TEMP\psmgr-install.ps1 -Encoding UTF8; & $env:TEMP\psmgr-install.ps1 -Silent"

# Public repository (one-liner)
Invoke-RestMethod -Uri "https://raw.githubusercontent.com/danhthanh4182/psmgr/main/install.ps1" -OutFile "$env:TEMP\install.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\install.ps1"
```

### 2. PowerShell 7 (`pwsh`)

```powershell
# Authenticated (works today)
gh api repos/danhthanh4182/psmgr/contents/install.ps1 -H "Accept: application/vnd.github.raw" | Out-File "$env:TEMP\psmgr-install.ps1" -Encoding utf8
pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\psmgr-install.ps1" -Silent

# Public repository (one-liner)
Invoke-RestMethod -Uri "https://raw.githubusercontent.com/danhthanh4182/psmgr/main/install.ps1" -OutFile "$env:TEMP\install.ps1"; pwsh -NoProfile -File "$env:TEMP\install.ps1"
```

### 3. winget

`-Method Winget` generates a version-pinned singleton manifest from the release metadata, including
the verified SHA256 digest, and hands it to winget. Generate it without installing with
`-WriteManifest`:

```powershell
# Install through winget
.\install.ps1 -Method Winget -Silent

# Or materialise the manifest and pass it to winget yourself
.\install.ps1 -WriteManifest "$env:TEMP\danhthanh4182.PSManager.yaml"
winget install -m "$env:TEMP\danhthanh4182.PSManager.yaml" --accept-package-agreements --accept-source-agreements
```

winget cannot authenticate to a private repository, so `-Method Winget` works once the release
assets are public (or when the manifest points at a mirror you host).

### Installer options

| Parameter | Effect |
|---|---|
| `-Version <x.y.z>` | Install a specific release instead of the latest. |
| `-Scope CurrentUser` | Per-user install under `%LOCALAPPDATA%\Programs\PSManager` (default). |
| `-Scope AllUsers` | Machine-wide install under `%ProgramFiles%\PSManager`; needs an elevated shell. |
| `-InstallDir <path>` | Custom target directory (`/DIR`). |
| `-Silent` | No wizard (`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`). |
| `-NoLaunch` | Do not start PSManager after installing. |
| `-WhatIf` | Print the resolved release, URL, digest source and installer arguments. |

### Code signing (SmartScreen / antivirus)

Unsigned installers trigger SmartScreen and antivirus heuristics. Every artifact can be signed:
the launchers, the launchers inside each archive, and the installer.

```powershell
# 1. Create a self-signed code-signing certificate and trust it on this machine
$cert = .\tools\New-PSManagerSigningCertificate.ps1 -Trust

# 2. Build a fully signed release
.\build\build.ps1 -Action all -Destination C:\temp\dist `
    -CertificatePath $cert.PfxPath -CertificatePassword $cert.Password

# 3. Sign artifacts of an existing build, then refresh the digests
.\build\build.ps1 -Action sign -Destination C:\temp\dist -CertificateThumbprint $cert.Thumbprint
```

`-CertificateThumbprint` signs from the certificate store instead of a `.pfx`; add
`-MachineStore` for `LocalMachine\My`. CI signs when `PSMGR_CERT_PFX_BASE64` and
`PSMGR_CERT_PASSWORD` repository secrets are set, and then verifies every executable with
`signtool verify /pa` before publishing.

A self-signed certificate removes the unsigned-binary signal and shows a publisher name, but it
does not buy SmartScreen reputation: machines that have not trusted the `.cer` still warn on first
run. Distribute without warnings by using a commercial OV/EV certificate, or deploy the `.cer` to
Trusted Root + Trusted Publishers (for example through Group Policy). `certs/` is git-ignored so a
private key can never be committed.

---

## 🚀 Quick Start

### 1. Launch Interactive TUI
```powershell
psmgr
```
*Use `↑/↓` arrow keys to navigate, `Enter` to select, `S` for Source, `L` for Language, `G` for GUI, `Q` to quit.*

### 2. Launch Native Desktop App (GUI)
```powershell
psmgr-gui
# Or from CLI
psmgr gui
```
*Or double-click `PSManager Desktop.lnk` on your Desktop / Start Menu.*

The navigation rail pairs each page label with a vector icon.

*Keyboard navigation*: Full keyboard access without a mouse. Use `Tab`/`Shift+Tab` to move focus, `Enter`/`Space` to select or activate, arrow keys (`↑/↓/←/→`) and `Home`/`End` to navigate the page rail and segmented selectors with wrapping. Use `Ctrl+1`…`Ctrl+6` to jump directly to pages (Overview, Update, Backup, Health, Profile, Help), `Ctrl+Tab` / `Ctrl+Shift+Tab` to cycle pages, `F6` to return focus to the active navigation item, and `Esc` to cancel open dialogs. The header bell shows the unread notification count; `h`, `v`, `!`, `p` are the CLI/TUI equivalents of Help, Check for updates, Notifications and Install update.

### 2b. Prebuilt launchers (release packages)

Every release zip ships ready-to-run Windows launchers next to the scripts, so nothing has to be
typed and no module install is needed:

| File | Runs | Notes |
|---|---|---|
| `psmgr.exe` | `ps-manager.ps1` | Console launcher for the CLI and TUI; forwards every argument and the child exit code. |
| `psmgr-gui.exe` | `gui.ps1` | Desktop launcher; opens the WPF app without a console window. |
| `psmgr.cmd` / `psmgr-gui.cmd` | same scripts | Plain batch shims for environments that block executables. |

The launchers resolve the script next to themselves, prefer `pwsh.exe` when it is on `PATH`, and
fall back to the built-in `powershell.exe` by absolute path. Build them for a custom layout with:

```powershell
pwsh ./build/build.ps1 -Action build -Destination C:\path\to\package
```

### 2c. Builder module and MCP server

`build/PSManager.Builder.psm1` is a reusable app builder: metadata-rich launchers, single-file
bundles, release archives, an Inno Setup installer, and signature verification.

```powershell
Import-Module ./build/PSManager.Builder.psm1
New-PSManagerLauncher -Destination C:\temp\app -Name psmgr.exe -ScriptName ps-manager.ps1 -Kind Console
New-PSManagerBuildPackage -Destination C:\temp\dist -Version 1.8.0
New-PSManagerInstaller -Destination C:\temp\dist
Test-PSManagerSignature -Path C:\temp\dist\psmgr.exe -ExpectedThumbprint <thumbprint>
```

`build/mcp-server.ps1` exposes the same operations over stdio JSON-RPC 2.0 (`build_info`,
`build_icon`, `build_launcher`, `build_app`, `package_release`, `build_installer`,
`sign_artifacts`, `verify_build`). Copy a block from `build/mcp.example.json` into your client's
configuration and **replace `C:\path\to\psmgr` with your clone path**: MCP hosts pass `args`
literally and do not expand `%USERPROFILE%` or other environment variables.


### 3. Quick CLI Commands
```powershell
# 1-Click set PowerShell 7 as default across all Windows points
psmgr set-default ps7

# 1-Click revert default back to Windows PowerShell 5.1
psmgr set-default ps5

# Synchronize dotfiles, links, and auto-provision packages
psmgr sync

# Test sync in Dry-Run mode without altering filesystem
psmgr sync -DryRun

# Run environment health audit on links, tools & variables
psmgr doctor

# Create timestamped zip backup of current shell profiles
psmgr backup

# Create an encrypted backup (AES-256-CBC + HMAC-SHA256, passphrase-protected)
psmgr backup enc

# Create a backup encrypted with Windows DPAPI (current-user, machine-bound)
psmgr backup dpapi

# Create a fresh backup and upload it as a release to your own private GitHub repo
# (offers passphrase encryption; the target resolves from $env:PSMGR_CLOUD_REPO,
# config.json 'cloudRepo', or the clone's git remote — never from this app repo)
psmgr backup-cloud

# Choose the private repo that receives cloud backups (also GUI: Backup → Set Backup Repo,
# TUI: [j]). Stored in config.json; an empty value clears it.
psmgr set-cloud-repo me/private-backups

# Restore from the most recent backup (.zip and .zip.enc are auto-detected;
# encrypted backups prompt for the passphrase)
psmgr restore

# Restore from a specific archive
psmgr restore C:\path\to\profile_backup_20261028_193057.zip

# DESTRUCTIVE: permanently delete local backups (irreversible).
# Interactive runs require typing DELETE; non-interactive runs require -Force.
psmgr clean-backups                       # prompts for the selection
psmgr clean-backups profile_backup_20261028_193057.zip
psmgr clean-backups "a.zip,b.zip" -Force  # multiple backups, no prompt
psmgr clean-backups all -Force            # every backup in the backups folder

# Check status of all shell environments
psmgr status

# Switch update source to Microsoft Store or Winget
psmgr set-source msstore
psmgr set-source winget
psmgr set-source github

# Update PowerShell through active source
psmgr update

# Reverse adoption: copy active machine profiles into payload templates as new source of truth
psmgr adopt

# Synchronize package catalog sources (winget source update)
psmgr sync-sources

# Inspect recent diagnostic logs (optional -Tail N, -Errors)
psmgr logs
psmgr logs -Tail 25
psmgr logs -Tail 50 -Errors

# Open shell profile in VS Code or Notepad
psmgr edit-profile
psmgr edit

# Switch language (en / vi / vi-ascii)
psmgr set-lang vi
psmgr set-lang vi-ascii
psmgr set-lang en

# View detailed diagnostics table
psmgr diagnostics

# Audit (and optionally auto-repair) PS 5.1 / PS 7 profile compatibility
psmgr audit-profile
psmgr audit-profile -Fix

# Suppress ANSI escape codes (useful for CI, script pipelines, plain logs)
psmgr help -NoColor
psmgr sync -NoColor

# Human-friendly output: headings, aligned panels and coloured status glyphs
psmgr status          # panel: shell & host, runtime, updates
psmgr doctor          # per-item audit with PASS/WARN/FAIL glyphs
psmgr help            # grouped command reference, examples and exit codes
```

> **Two separate repositories.** The deploy repo ships code and app releases; your profile
> backups belong to *your own* private repository (for example `me/private-backups`). The deploy
> repo is never used automatically and `backup-cloud` refuses it unconditionally — a user who
> clones this project can never upload personal data into it.


### 4. Help & updates
```powershell
# Grouped command reference (or the detail for one command)
psmgr help
psmgr help update-app

# Check GitHub for a newer PSManager release (cached for six hours)
psmgr update-check

# Download the SHA-256 verified installer and upgrade in place
psmgr update-app

# Review, read or clear the in-app notification store
psmgr notifications
psmgr notifications -Value all
psmgr notifications -Value read
psmgr notifications -Value clear
```

Notifications are stored in `%LOCALAPPDATA%\PSManager\notifications.json` (newest 50, i18n
keys only) and surface in the CLI, the TUI modal (`!`), the GUI bell panel and, on installed
builds, as native Windows toasts. Installation always requires an explicit action: the
background check only ever caches a release and raises one notification per version.

### 5. Environment overrides
| Variable | Effect |
|---|---|
| `PSMGR_DISABLE_UPDATE_CHECK=1` | Never contact GitHub; the UI renders the cached status as "disabled". |
| `PSMGR_DISABLE_TOASTS=1` | Keep in-app notifications but skip native Windows toasts. |
| `PSMGR_STATE_DIR=<path>` | Store `notifications.json` and `updates.json` somewhere else (tests, portable runs). |
| `PSMGR_GITHUB_TOKEN=<token>` | Release check and asset download (update/install); precedence `-Token` → `PSMGR_GITHUB_TOKEN` → `GH_TOKEN` → `GITHUB_TOKEN` → `gh auth token`. |
| `PSMGR_CLOUD_TOKEN=<token>` | `backup-cloud` only: used when the GUI/TUI token field is empty. Precedence `-Token`/field → `PSMGR_CLOUD_TOKEN` → `GH_TOKEN` → `GITHUB_TOKEN` → `gh auth login`. |
| `PSMGR_CLOUD_REPO=<owner/repo>` | Cloud backup target; wins over `cloudRepo`, the git remote and `gh` (no `config.json` edit needed). |
| `GH_TOKEN` / `GITHUB_TOKEN` | Standard gh credential variables honoured by every feature. A fine-grained token scoped to *one* private repository with `Contents: read and write` is enough. |

### 6. Landing page (local preview)
`site/` is a self-contained bilingual static site (no external fonts, frameworks or analytics).
Nothing is published today: the site is reviewed locally and the Pages workflow stays dormant.

```powershell
# Serves site/ under /psmgr/ so the absolute asset paths and 404 page work, then opens the browser
pwsh -NoProfile -File tools/Preview-LandingPage.ps1          # default port 8765
pwsh -NoProfile -File tools/Preview-LandingPage.ps1 -Port 9000 -NoOpen
```

`python -m http.server 8765 --directory site` also works for the index page, but it serves `/`
instead of `/psmgr/`, so `404.html` (which uses absolute `/psmgr/assets/...` paths) loses its CSS
there — use the helper when checking the 404 page.

The workflow builds a Pages artifact on `site/**` changes, but the deploy job only runs when the
repository variable `PSMGR_PAGES_ENABLED` is `true`. Publication is intentionally skipped for now;
the prerequisites live in [`docs/PUBLISHING.md`](docs/PUBLISHING.md).

Website: <https://danhthanh4182.github.io/psmgr/> (live once Pages is enabled and the repository is public).

Publishing the repository is **not** just a visibility toggle: `psmgr adopt` copies live profiles
into the tracked payload templates, so run it only inside a private dotfiles repository. Profile
backups never target this repo (`backup-cloud` refuses the deploy repo unconditionally); follow
[`docs/PUBLISHING.md`](docs/PUBLISHING.md) before flipping visibility.

---


## 📐 Architecture & Module Breakdown

PSManager is engineered according to **PowerShell Module Best Practices** and **Single Responsibility Principle (SRP)**:

```
tools/ps-manager/
├── AGENTS.md                      # Universal Agent Instructions & Guardrails (Root SSoT)
├── CHANGELOG.md                   # Semantic version history (Keep a Changelog)
├── PSManager.psd1                 # Module Manifest (v1.8.0, Approved Verbs, Exports)
├── install.ps1                    # Release installer (digest-verified; Installer or winget method)
├── PSManager.psm1                 # Root Module Loader & API Dispatcher
├── ps-manager.ps1                 # CLI & TUI Executable Harness (Tri-Interface SSoT)
├── gui.ps1                        # Native WPF Desktop GUI (SVG Vector Graphics)
├── ui/                            # Extracted WPF window markup & design tokens
│   ├── PSManager.MainWindow.xaml  # Window layout, navigation rail and pages
│   ├── PSManager.Theme.xaml       # Design tokens (colours, fonts, control styles)
│   ├── GuiKeyboard.ps1            # Keyboard interaction primitives & shortcut resolvers
│   ├── GuiLoader.ps1              # XAML loader + theme dictionary merge
│   ├── GuiNavigation.ps1          # Page navigation controller & shortcut router
│   ├── GuiNotifications.ps1       # Notification center, unread badge, toast, update job
│   └── GuiHelp.ps1                # Help & About page (command catalog, update status, links)
├── boot.ps1                       # Zero-State Web Bootstrapper for clean machines
├── setup-hooks.ps1 / .cmd         # Universal Git Hooks auto-configurator (.agents/hooks)
├── tools/Capture-PSManagerGui.ps1 # Dev-only off-screen WPF renderer (before/after screenshots)
├── tools/New-PSManagerIcon.ps1     # Generates multi-size application icon (assets/psmgr.ico)
├── tools/Preview-LandingPage.ps1   # Local review server: serves site/ under /psmgr/ (no publish)
├── site/                          # Bilingual (EN/VI) landing page (local preview; publish deferred)
├── .github/workflows/pages.yml    # Builds the Pages artifact; deploy gated by PSMGR_PAGES_ENABLED
├── tools/New-PSManagerSigningCertificate.ps1 # Self-signed code-signing certificate generator
├── certs/                         # Git-ignored signing material (.pfx + .cer)
├── build/                         # Reusable App Builder (PSManager.Builder.psm1, build.ps1, mcp-server.ps1)
├── config.json                    # Persistent configuration (source, channel, lang, cloudRepo)
├── i18n.json                      # Multilingual dictionary (vi, vi-ascii, en - 384 keys)
├── PSScriptAnalyzerSettings.psd1  # Static analysis rule configuration
├── .editorconfig                  # Formatting standards (UTF-8/lf; BOM for scripts, 4 spaces)
├── .agents/                       # Universal Agent Subsystem
│   └── hooks/                     # Unified Git & PreToolUse interceptor hooks
├── docs/                          # Specifications, Architecture, Plans, SDLC
│   ├── SPEC.md                    # Core functional requirements (FR-1..FR-9)
│   ├── PLAN.md                    # Milestones & quality gates (Phases 1-10)
│   ├── ARCHITECTURE.md            # Topology, module map, seams
│   ├── DIAGRAMS.md                # Behavioural Mermaid flows
│   ├── SDLC.md                    # Lifecycle stages, gates, destructive-change protocol
│   ├── SPEC-GUI-KEYBOARD.md       # Full GUI keyboard accessibility specification
│   ├── SPEC-PROFILE-SYNC.md       # Profile sync & provisioning specification
│   ├── PLAN-PROFILE-SYNC.md       # Sync implementation milestones
│   ├── SPEC-PROFILE-AUDIT.md      # Profile compatibility auditor & repair specification
│   ├── PLAN-PROFILE-AUDIT.md      # Profile auditor work breakdown
│   ├── SPEC-BACKUP-CLEANUP.md     # Destructive backup deletion specification
│   ├── PLAN-BACKUP-CLEANUP.md     # Backup cleanup work breakdown & rollback
│   ├── SPEC-ASYNC-GUI-LOGGING.md  # Async execution & log rendering specification
│   ├── PLAN-ASYNC-GUI-LOGGING.md  # Async execution plan
│   ├── SPEC-BRANCH-PARITY.md      # Branch-vs-main capability gap specification
│   ├── PLAN-BRANCH-PARITY.md      # Port plan for the missing GUI audit fix
│   ├── ui-ux/                     # UI/UX programme artefacts
│   │   ├── spec.md                # Acceptance criteria (GUI Track A, TUI/CLI addendum)
│   │   ├── tickets.md             # Ticket board (T0-T10, C0-C11)
│   │   ├── action-map.md          # GUI / TUI / CLI action mapping (AC-X1)
│   │   ├── PR.md                  # Track A pull-request body & acceptance matrix
│   │   └── shots/                 # Before/after screenshots (1280, 1920, 2560 + live capture)
│   ├── PUBLISHING.md              # Publish checklist: backup releases, payload split, history scan
│   └── ISSUE-ASYNC-GUI-LOGGING.md # Original defect report
├── templates/                     # Out-of-the-box defaults & payload layer
│   ├── profiles/master_profile.ps1 # Universal dual-PS profile (encoding, fnm, posh-git, starship, PS7 addons)
│   ├── configs/starship.toml      # Optimized prompt configuration (scan_timeout=2000)
│   ├── manifest.default.json      # Default package and link manifest
│   └── local.ps1.example          # Template for host-specific secrets
├── tests/                         # Automated validation harness (119 tests across PS5 & PS7)
│   ├── harness.ps1                # Comprehensive test runner
│   ├── Run-Tests.ps1              # Cross-runtime dual-shell executor
│   ├── test_interface_parity.ps1  # Automated 3-way CLI/TUI/GUI contract enforcement
│   ├── test_action_engine.ps1     # ActionEngine unit & contract tests
│   ├── test_profile_auditor.ps1   # Profile compatibility auditor tests
│   ├── test_backup_cleanup.ps1    # Destructive deletion safety tests
│   ├── test_gui_async.ps1         # Async GUI bridge & XAML binding tests
│   ├── test_gui_keyboard.ps1      # GUI keyboard navigation and accessibility unit tests
│   ├── test_gui_xaml.ps1          # Window XAML, theme, page and log contract tests
│   ├── test_tui_render.ps1        # TUI frames, snapshots (16), catalog, search normalisation
│   ├── test_tui_state.ps1         # TUI key reducer: navigation, legacy keys, search, help
│   ├── test_tui_engine.ps1        # TUI terminal restore, key conversion, plain mode, TTY guard
│   ├── test_e2e_sync.ps1          # Sandboxed end-to-end sync tests
│   ├── test_backup.ps1            # AES-256 + HMAC-SHA256, DPAPI, and tamper tests
│   ├── test_sync_engine.ps1       # Sync & Doctor tests
│   ├── test_update_notifier.ps1   # Notification store, help catalog and self-update tests
│   └── ...                        # Additional unit test suites
└── modules/                       # Specialized single-responsibility modules
    ├── Core/
    │   ├── ActionRegistry.ps1     # Central 28-action capability registry (Tri-Interface Parity)
    │   ├── Help.ps1               # Shared help catalog for CLI, TUI and GUI
    │   ├── Notification.ps1       # Persistent notification store + native toast bridge
    │   ├── ToastHost.ps1          # WinRT toast host (Windows PowerShell 5.1, -Sta)
    │   ├── ActionEngine.ps1       # Deep action execution engine (sync/async, streaming, pipes)
    │   ├── Encoding.ps1           # UTF-8 CP 65001 & Win32 console host stream setup
    │   ├── Config.ps1             # Get-PSManagerConfig & Set-PSManagerConfig (cloudRepo)
    │   ├── Logger.ps1             # Non-locking persistent file logger (psmgr_*.log)
    │   ├── Security.ps1           # Test-PSManagerPassphrase (zero-freed BSTR compare)
    │   └── I18n.ps1               # Adaptive language resolver with WPF Unicode override
    ├── Environment/
    │   ├── Detection.ps1          # Query PS installations, WT profiles, delegation
    │   └── SystemConfig.ps1       # Set-PowerShell7Default & Set-PowerShell5Default
    ├── Package/
    │   ├── SourceManager.ps1      # Package target resolver (winget/store/github)
    │   ├── UpdateNotifier.ps1     # PSManager release check, cache and verified self-update
    │   └── Updater.ps1            # Invoke-PowerShellUpdate & Install operations
    ├── Launcher/
    │   └── ShellSwitcher.ps1      # Start-QuickShell (Split view) & Start-DesktopGUI
    ├── Sync/
    │   ├── AppResolver.ps1        # Package name to binary shim mapper (e.g. ripgrep -> rg.exe)
    │   ├── Backup.ps1             # AES-256-CBC, HMAC-SHA256, DPAPI, Cloud Releases & guarded deletion
    │   ├── Linker.ps1             # Safe Hardlink / Symlink / Copy engine & backup
    │   ├── Manifest.ps1           # Parse & validate manifest.json schema
    │   ├── ProfileAuditor.ps1     # Test/Repair-PSManagerProfile (PS 5.1 vs PS 7 compatibility)
    │   ├── Provisioner.ps1        # Orchestrate Winget, Scoop, PSGallery installs
    │   └── SyncEngine.ps1         # Sync orchestrator, Import-PSManagerProfiles & Doctor
    └── UI/
        ├── Theme.ps1              # ANSI Palette, Format-ColorText, Format-ColorBadge
        ├── Diagnostics.ps1        # Side-by-side system diagnostics reporting
        ├── TuiCapabilities.ps1    # TTY/Unicode/VT/NO_COLOR detection + symbol & colour tables
        ├── TuiCatalog.ps1         # 21 actions in 5 groups, mnemonic keys + legacy aliases
        ├── TuiRender.ps1          # Pure New-TuiFrame, diff writer, modal screens
        ├── TuiState.ps1           # Pure key reducer, search filter, state-driven cursor
        └── TuiEngine.ps1          # Alternate-screen session, action runner, plain mode
```

---

## ⌨️ TUI Keyboard Shortcuts

| Key | Action |
|---|---|
| `d` (legacy `1`, `D`) | **Set PS7 as Default** (1-click apply all points) |
| `r` (legacy `2`, `R`) | **Restore PS5 Default** (revert system) |
| `c` (legacy `3`, `S`) | **Update Source & Channel** (Winget / Store / GitHub) |
| `u` (legacy `4`, `U`) | **Update PowerShell 7** (via active source) |
| `i` (legacy `5`, `I`) | **Install PowerShell** |
| `y` (legacy `Y`) | **Profile Sync & Multi-Package Provisioning** |
| `w` (legacy `W`) | **Sync Winget Sources** |
| `o` (legacy `O`) | **Doctor Audit** (`F` = auto-fix, any key = back) |
| `z` (legacy `0`) | **Diagnostics Screen** |
| `6` | **Launch PowerShell 7** (new tab/window) |
| `7` | **Launch PS7 (Admin)** (elevated) |
| `8` | **Launch Split View** (PS7 + PS5 side-by-side) |
| `9` | **Launch Windows PowerShell 5.1** |
| `g` (legacy `G`) | **Open the desktop GUI** |
| `l` (legacy `L`) | **Cycle language**: English → `vi-ascii` → `vi` → English |
| `e` (legacy `P`) | **Edit Profiles** (VS Code / Notepad) |
| `t` (legacy `T`) | **Audit Profiles** (`F` = auto-repair) |
| `m` (legacy `A`) | **Adopt Current Profiles** into the payload |
| `b` (legacy `B`) | **Backup Profiles** (.zip, optional encryption) |
| `n` (legacy `C`) | **Backup to Cloud** (GitHub Release) |
| `k` (legacy `K`) | **Restore Backup** (pick archive) |
| `f` (legacy `V`) | **View Logs** (last 40 diagnostic lines) |
| `x` (legacy `X`) | **Delete Local Backups** (typed `y`, then `DELETE`) |
| `↑` `↓` / `Home` `End` / `PgUp` `PgDn` | Move the cursor |
| `Tab` / `Shift+Tab` | Jump to the next / previous group |
| `/` | Search all actions (diacritic-insensitive: `dat` finds "Đặt…") |
| `?` / `h` | Keyboard help overlay |
| `v` | **Check for PSManager updates** (result screen with release, latest version and check time) |
| `!` | **Notifications** modal (`c` clear, `r` mark all read, `o` open the selected link, `↑`/`↓` move) |
| `p` | **Install PSManager update** (confirmation, then the verified installer) |
| `q` / `Ctrl+C` | Exit (terminal is always restored) |

Legacy keys still run their original action and show a "new key" hint. `PSMGR_PLAIN=1` switches to a
numbered, ANSI-free list for screen readers; without a TTY the TUI prints help instead of looping.
Titles are never truncated: a row wraps onto continuation lines, so every action keeps its full
name. Sections carry their own icon and colour, the active row is a full-width inverse-video
accent bar, undoable actions show `↺`, destructive actions show `!` in red, and an overflowing
list gets a proportional scrollbar. Terminals below 80x24 show a clear notice instead of a
broken frame; at 110 columns or wider the list keeps its detail pane.

---

## 🌐 Three-Mode Language Engine (i18n)

The interface language is an explicit setting, not a guess based on the PowerShell engine:

- **English** (`en`) - full English interface.
- **Tiếng Việt có dấu** (`vi`) - UTF-8 Vietnamese with full diacritics; correct on Windows Terminal, VS Code and PowerShell 7.
- **Tiếng Việt không dấu** (`vi-ascii`) - unaccented Vietnamese for legacy consoles whose raster fonts cannot render diacritics (`?`).

Switch modes with `psmgr set-lang <en|vi|vi-ascii>`, the TUI `L` key, or the GUI language button.
All three interfaces cycle `en` → `vi-ascii` → `vi` → `en` and persist the choice in `config.json`.
`i18n.json` carries 279 keys in each mode (100 of them `tui_*`).

---

## 🧪 Test Harness & Validation

Run the automated test suite locally:
```powershell
pwsh ./tests/harness.ps1
# Or in PowerShell 5.1
powershell ./tests/harness.ps1
```

All 47 test cases cover:
- AST Syntax Linting across all scripts
- Module Manifest verification (`Test-ModuleManifest`)
- Profile Safe Linking & Hardlink fallback
- Multi-Package provisioning logic (Winget, Scoop, PSGallery)
- Zip Backup & Rollback integrity
- Dual-shell runtime compatibility (PS 5.1 & PS 7)
- Exported public API contract checks
- Configuration persistence CRUD
- Package source resolution (`winget`, `msstore`, `github`)
- Language adaptation under active PowerShell engine
- Environment detection queries

---

## 📄 License

MIT License. Designed with best practices, production-ready reliability, and zero third-party bloat.

