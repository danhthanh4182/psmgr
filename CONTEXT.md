# PSManager System Context (`CONTEXT.md`)

## 1. System Vision & Architecture

PSManager (`psmgr`) is a production-grade PowerShell management and machine synchronization suite for Windows 10/11. It operates on a **Decoupled 3-Layer Hybrid Architecture**:

```
+-----------------------------------------------------------------------------------+
| 1. ENGINE LAYER: PSManager (Public Open-Source)                                   |
|    Location: ~/tools/ps-manager                                                   |
|    Responsibilities:                                                              |
|      - CLI, TUI, and Desktop WPF interfaces                                       |
|      - Package orchestration (Winget, Scoop, PSGallery)                           |
|      - Safe linking engine (Hardlink -> Symlink -> Copy with automatic backup)    |
|      - Zero-state web bootstrapper (boot.ps1) with PS5 -> PS7 handover            |
|      - Observability and diagnostic logging (modules/Core/Logger.ps1)             |
+-----------------------------------------+-----------------------------------------+
                                          | Orchestrates & Applies
+-----------------------------------------v-----------------------------------------+
| 2. PAYLOAD LAYER: User Dotfiles (Private / Git Remote)                             |
|    Default Location: ~/.dotfiles                                                  |
|    Contents:                                                                      |
|      ├── manifest.json              : Package lists, link bindings, environment   |
|      ├── profiles/                                                                |
|      │   └── master_profile.ps1     : Unified profile bridging PS 5.1 and PS 7    |
|      ├── configs/                                                                 |
|      │   └── starship.toml          : Prompt theme configuration                  |
|      └── local.ps1                  : Machine-local overrides (excluded from Git) |
+-----------------------------------------+-----------------------------------------+
                                          | Targets
+-----------------------------------------v-----------------------------------------+
| 3. OS TARGET LAYER: Dual-Shell Runtime Environment                                |
|    - Windows PowerShell 5.1: $HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1
|    - PowerShell 7 Core     : $HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1
|    - CLI Shims Directory   : $HOME\scoop\shims (User PATH)                        |
|    - App Locations         : %ProgramFiles% (PowerShell 7, Windows Terminal, Git) |
|    - Shell Delegation Host : HKCU:\Console\%%Startup                              |
+-----------------------------------------------------------------------------------+
```

---

## 2. Module Boundaries & Responsibilities

```
tools/ps-manager/
├── AGENTS.md                      # Universal agent instructions & guardrails (Root SSoT)
├── CHANGELOG.md                   # Semantic version history (Keep a Changelog)
├── PSManager.psd1                 # Module manifest (v1.8.1, exports & metadata)
├── install.ps1                    # Release installer (digest-verified; Installer or winget method)
├── PSManager.psm1                 # Root loader & public API dispatcher
├── ps-manager.ps1                 # CLI & TUI entrypoint harness (Tri-Interface Parity)
├── gui.ps1                        # Native WPF Dark Desktop Application (SVG Vector Graphics)
├── ui/                            # Extracted WPF window markup & design tokens
│   ├── PSManager.MainWindow.xaml  # Window layout, navigation rail and pages
│   ├── PSManager.Theme.xaml       # Design tokens (colours, fonts, control styles)
│   ├── GuiKeyboard.ps1            # Keyboard interaction primitives & shortcut resolvers
│   ├── GuiLoader.ps1              # XAML loader + theme dictionary merge
│   ├── GuiNavigation.ps1          # Page navigation controller & shortcut router
│   ├── GuiNotifications.ps1       # Notification center, unread badge, toast, update job
│   └── GuiHelp.ps1                # Help & About page (catalog, update status, links)
├── boot.ps1                       # Zero-state web bootstrapper for clean machines
├── setup-hooks.ps1 / .cmd         # Universal git hooks auto-configurator (.agents/hooks)
├── tools/Capture-PSManagerGui.ps1 # Dev-only off-screen WPF renderer (before/after screenshots)
├── tools/New-PSManagerIcon.ps1    # Generates multi-size application icon (assets/psmgr.ico)
├── build/                        # Reusable app builder (PSManager.Builder.psm1, build.ps1, mcp-server.ps1)
├── config.json                    # Local state (source, channel, language, cloudRepo)
├── i18n.json                      # Multilingual dictionary (vi, vi-ascii, en - 384 keys)
├── PSScriptAnalyzerSettings.psd1  # Static analysis rule configuration
├── .editorconfig                  # Formatting standards (UTF-8/lf; BOM for scripts, 4 spaces)
├── .agents/                       # Universal Agent Subsystem
│   └── hooks/                     # Unified Git & PreToolUse interceptor hooks
├── docs/                          # Specifications, Architecture, Plans, SDLC
│   ├── SPEC.md                    # Core functional requirements (FR-1..FR-9)
│   ├── PLAN.md                    # Milestones & quality gates (Phases 1-10)
│   ├── ARCHITECTURE.md            # Static topology, module map, seams
│   ├── DIAGRAMS.md                # Behavioural Mermaid flows (parity, engine, sync, audit, cleanup)
│   ├── SDLC.md                    # Lifecycle stages, gate matrix, destructive-change protocol
│   ├── SPEC-GUI-KEYBOARD.md       # Full GUI keyboard accessibility specification
│   ├── SPEC-PROFILE-SYNC.md      # Profile sync specification
│   ├── PLAN-PROFILE-SYNC.md      # Sync implementation tasks and milestones
│   ├── SPEC-PROFILE-AUDIT.md     # Profile compatibility auditor & repair specification
│   ├── PLAN-PROFILE-AUDIT.md     # Profile auditor work breakdown & verification
│   ├── SPEC-BACKUP-CLEANUP.md    # Destructive backup deletion specification
│   ├── PLAN-BACKUP-CLEANUP.md    # Backup cleanup work breakdown & rollback
│   ├── SPEC-ASYNC-GUI-LOGGING.md # Async execution & log rendering specification
│   ├── PLAN-ASYNC-GUI-LOGGING.md # Async execution plan
│   ├── SPEC-BRANCH-PARITY.md     # Branch-vs-main capability gap specification
│   ├── PLAN-BRANCH-PARITY.md     # Port plan for the missing GUI audit fix
│   ├── ui-ux/                     # UI/UX programme artefacts
│   │   ├── spec.md                # Acceptance criteria (GUI Track A, TUI/CLI addendum)
│   │   ├── tickets.md             # Ticket board (T0-T10, C0-C11)
│   │   ├── action-map.md          # GUI / TUI / CLI action mapping (AC-X1)
│   │   ├── PR.md                  # Track A pull-request body & acceptance matrix
│   │   └── shots/                 # Before/after screenshots (1280, 1920, 2560 + live capture)
│   └── ISSUE-ASYNC-GUI-LOGGING.md# Original defect report
├── templates/                     # Out-of-the-box defaults
│   ├── profiles/master_profile.ps1 # Universal dual-PS profile (encoding, fnm, posh-git, starship, PS7 addons)
│   ├── configs/starship.toml      # Optimized prompt theme (scan_timeout=2000)
│   ├── manifest.default.json      # Default package and link manifest
│   └── local.ps1.example          # Template for host-specific secrets
├── tests/                         # Automated validation harness
│   ├── harness.ps1                # 119 automated tests across 12 test suites
│   ├── Run-Tests.ps1              # Cross-version executor (PS5 + PS7)
│   ├── test_interface_parity.ps1  # Automated 3-way CLI/TUI/GUI contract enforcement
│   ├── test_action_engine.ps1     # ActionEngine deep module unit and contract tests
│   ├── test_profile_auditor.ps1   # Profile compatibility auditor unit and contract tests
│   ├── test_gui_async.ps1         # Async GUI CLI bridge unit tests
│   ├── test_gui_keyboard.ps1      # GUI keyboard navigation and accessibility unit tests
│   ├── test_gui_xaml.ps1          # Window XAML, theme, page and log contract tests
│   ├── test_tui_render.ps1        # TUI frame dimensions, catalog & search tests
│   ├── test_tui_state.ps1         # TUI key reducer: navigation, legacy keys, search, help
│   ├── test_tui_engine.ps1        # TUI terminal restore, key conversion, plain mode, TTY guard
│   ├── test_e2e_sync.ps1          # End-to-end sync & doctor execution tests
│   ├── test_backup.ps1            # AES-256 + HMAC-SHA256, DPAPI, tamper, cloud-target guard tests
│   ├── test_backup_cleanup.ps1    # Destructive backup deletion safety & containment tests
│   ├── test_sync_engine.ps1       # Sync & Doctor tests
│   ├── test_update_notifier.ps1   # Notification store, help catalog, self-update tests
│   ├── site/                      # Bilingual (EN/VI) static landing page + shots
│   └── .github/workflows/pages.yml # Pages artifact build; deploy gated by PSMGR_PAGES_ENABLED
└── modules/                       # Specialized single-responsibility modules
    ├── Core/
    │   ├── ActionRegistry.ps1     # Central 28-action capability registry (Tri-Interface Parity)
    │   ├── Help.ps1               # Shared help catalog for CLI, TUI and GUI
    │   ├── Notification.ps1       # Persistent notification store + native toast bridge
    │   ├── ToastHost.ps1          # WinRT toast host (Windows PowerShell 5.1, -Sta)
    │   ├── ActionEngine.ps1       # Deep action execution engine (sync/async, streaming, pipes)
    │   ├── Encoding.ps1           # CP 65001 UTF-8 console stream guards
    │   ├── Config.ps1             # Persistent config schema validation (config.json)
    │   ├── Logger.ps1             # Non-locking persistent file logger (psmgr_*.log)
    │   ├── Security.ps1           # Test-PSManagerPassphrase (zero-freed BSTR compare)
    │   └── I18n.ps1               # Adaptive language resolver (PS5 vs PS7)
    ├── Environment/
    │   ├── Detection.ps1          # Query PS runtimes, WT profiles, and PATH shims
    │   └── SystemConfig.ps1       # 1-click apply/revert default shell targets
    ├── Package/
    │   ├── SourceManager.ps1      # Package target resolver (winget, store, github)
    │   ├── UpdateNotifier.ps1     # PSManager release check, cache and verified self-update
    │   └── Updater.ps1            # Update & install orchestration
    ├── Launcher/
    │   └── ShellSwitcher.ps1      # Terminal launcher (PS7, PS5, Split, Admin)
    ├── Sync/
    │   ├── AppResolver.ps1        # Package name to binary shim mapper (ripgrep -> rg.exe)
    │   ├── Linker.ps1             # Safe Hardlink / Symlink / Copy engine & backup
    │   ├── Manifest.ps1           # JSON schema parser and contract validator
    │   ├── Provisioner.ps1        # Multi-package installer (Winget, Scoop, PSGallery)
    │   ├── Backup.ps1             # AES-256-CBC, HMAC-SHA256, DPAPI, and Cloud Releases
    │   ├── SyncEngine.ps1         # Sync orchestrator, Import-PSManagerProfiles & Doctor
    │   └── ProfileAuditor.ps1     # Profile compatibility auditor & repair (Test/Repair-PSManagerProfile)
    └── UI/
        ├── Theme.ps1              # 24-bit ANSI TrueColor palette, Set-PSManagerTheme, Disable-PSManagerColor & helpers
        ├── Diagnostics.ps1        # Environment audit and diagnostic cards
        ├── TuiCapabilities.ps1    # TTY/Unicode/VT/NO_COLOR detection, symbols, 16-colour palette
        ├── TuiCatalog.ps1         # 5-group action catalog, mnemonic keys, legacy aliases, flags
        ├── TuiRender.ps1          # Pure frame builder, diff writer, modal screens
        ├── TuiState.ps1           # Pure key reducer, search filter, state-driven cursor
        └── TuiEngine.ps1          # Alternate-screen session, action runner, plain mode
```

### Cloud backup target resolution (`modules/Sync/Backup.ps1`)

| Order | Source | Notes |
|---|---|---|
| 0 | `$env:PSMGR_CLOUD_REPO` | Machine override; leaves the tracked `config.json` untouched. |
| 1 | `config.json` → `cloudRepo` | Set by `psmgr set-cloud-repo owner/repo`, TUI `[j]`, GUI **Backup → Set Backup Repo** (`Set-PSManagerCloudRepo`). |
| 2 | Clone's `git remote origin` | Skipped when it resolves to the PSManager app repo. |
| 3 | `gh repo view` default | Skipped when it resolves to the PSManager app repo. |

`ConvertTo-PSManagerRepoSlug` accepts `owner/repo`, `github.com/owner/repo`, `git@github.com:owner/repo.git`
and `https://github.com/owner/repo(.git)`; any other host or malformed reference is rejected.
`Publish-PSManagerCloudBackup` refuses the deploy repo unconditionally (deploy repo ≠ data repo), then
runs `Test-PSManagerCloudWriteAccess` (`gh api repos/<repo>` → visibility + `.permissions.push`)
before creating a backup; the data repository must be **private** and writable.

Credential precedence: the GUI/TUI token field or `-Token` → `$env:PSMGR_CLOUD_TOKEN` → `GH_TOKEN` /
`GITHUB_TOKEN` → the `gh` CLI login. A per-call token is applied through `$env:GH_TOKEN` for that
operation only and restored afterwards; the app never persists it. Failures (invalid token, missing
write permission, refused target, public data repo) surface through the CLI error line, the TUI
result screen and the GUI log.

---

## 3. Dual-Runtime Principles (PS 5.1 vs PS 7+)

1. **Console Encoding Guard**:
   - The language mode is explicit (`en`, `vi`, `vi-ascii`) and persisted in `config.json`; the engine no longer forces a mode.
   - PS 5.1 on legacy Windows Console Host (`conhost.exe`) cannot render diacritics with raster fonts: choose `vi-ascii` there. `vi` requires UTF-8 output (Windows Terminal, VS Code, PS 7).
2. **Syntax Isolation**:
   - Shared code, modules, and `boot.ps1` **MUST NOT** use modern PowerShell 7 operators (`??`, `?.`, `&&`, `||`, ternary `?:`).
   - All code must pass `[System.Management.Automation.Language.Parser]` under Windows PowerShell 5.1.
3. **Execution Safety**:
   - Hardlinks require same volume root. Cross-volume targets automatically fall back to copy.
   - All file operations use `-LiteralPath` to prevent wildcard interpretation on paths containing `[` or `]`.
   - All overwritten files produce `.bak.<timestamp>` backups.
   - **Never write through a hardlink.** Live profiles may share an inode with
     `templates/profiles/master_profile.ps1`, so `Set-Content` / `Copy-Item` would
     silently rewrite the tracked repo payload. Use `Set-DetachedFileContent`
     (temp file → rename target aside → rename temp into place → drop the aside
     copy, rolling back on failure); `Test-FileHardLink` reports the state and
     `Get-HardLinkPaths` names the peers.
   - Backup restore is **byte-exact**: pass `-Bytes` (`[IO.File]::ReadAllBytes`)
     instead of decoding and re-encoding, so UTF-16/ANSI files survive intact.

