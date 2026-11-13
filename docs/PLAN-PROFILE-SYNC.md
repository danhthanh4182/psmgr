# PSManager Profile Sync & Multi-Package Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a robust, idempotent profile synchronization and multi-package provisioning engine in PSManager (`psmgr`), enabling 1-command machine bootstrapping and dotfile synchronization across both Windows PowerShell 5.1 and modern PowerShell 7.

**Architecture:** A decoupled 3-layer hybrid system: PSManager as the public open-source engine (`tools/ps-manager/modules/Sync`), user dotfiles as private/personal payload (`~/.dotfiles`), and a dual-runtime profile bridging PS5 conhost and PS7 core via native hardlinks and fallback copies.

**Tech Stack:** PowerShell 5.1 & PowerShell 7.4+ (`pwsh`), Windows Win32 API (`CreateHardLinkW`), Winget CLI, Scoop package manager, PowerShellGet/PSGallery.

**Spec:** `docs/superpowers/specs/2026-10-28-profile-sync-design.md` / `tools/ps-manager/docs/SPEC-PROFILE-SYNC.md`

---

## Global Constraints

- Must run identically on both Windows PowerShell 5.1 (Desktop edition) and PowerShell 7.4+ (Core edition).
- Zero administrator privilege requirement for standard sync, hardlinks, or Scoop user installations.
- All file link operations must create `.bak.<timestamp>` backups if the destination already exists and differs.
- No secrets or credentials in the engine codebase; all personal configurations delegate to `local.ps1` or private dotfile repos.
- 100% compliance with PowerShell Approved Verbs (`Invoke-`, `Install-`, `Get-`, `New-`, `Backup-`, `Test-`).
- Zero syntax or parser errors against `[System.Management.Automation.Language.Parser]`.

---

## Review Focus

1. **Volume Boundary Traversal**: Hardlinks cannot span across different disk volumes (e.g., C: to D:). Linker must automatically detect volume mismatch and fall back to file copy without throwing an unhandled exception.
2. **Missing Package Manager Graceful Fallback**: If Winget is absent on older Windows 10 builds or Scoop installation fails due to network restrictions, the provisioner must log warning diagnostics and continue rather than aborting mid-sync.
3. **Circular or Broken Profile Symlinks**: If an existing profile target is a broken symlink or points to a non-existent directory, `New-SafeLink` must repair or replace it cleanly.
4. **Encoding Corruption on Legacy Conhost (PS 5.1)**: Accented Vietnamese or UTF-8 characters loaded in PS 5.1 must not produce `?` raster corruption or crash console streams.
5. **Path Normalization Edge Cases**: Paths declared with `~`, `$HOME`, `%USERPROFILE%`, or forward slashes (`/`) in `manifest.json` must be normalized to valid Windows paths before filesystem operations.

---

## Task Breakdown

### Task 1: Safe Linker & Path Normalizer (`modules/Sync/Linker.ps1`)

**Files:**
- Create: `tools/ps-manager/modules/Sync/Linker.ps1`
- Test: `tools/ps-manager/tests/test_linker.ps1`

**Interfaces:**
- Produces:
  - `Resolve-NormalizedPath([string]$Path) -> [string]`
  - `New-SafeLink([string]$SourcePath, [string]$TargetPath, [string]$LinkType = "hardlink") -> [pscustomobject]@{ Success: bool, Method: string, BackupPath: string, Message: string }`
  - `Test-FileIdentical([string]$PathA, [string]$PathB) -> [bool]`

- [ ] **Step 1: Write test harness for Linker**
  Create `tools/ps-manager/tests/test_linker.ps1` asserting:
  - `Resolve-NormalizedPath` expands `~` to `$env:USERPROFILE`.
  - `New-SafeLink` creates hardlink on same volume.
  - `New-SafeLink` backs up existing differing target to `.bak`.
  - `New-SafeLink` is idempotent (does nothing if target already identical).
- [ ] **Step 2: Run test to verify it fails**
  Run: `powershell -ExecutionPolicy Bypass -File tools/ps-manager/tests/test_linker.ps1`
  Expected: FAIL with command not found.
- [ ] **Step 3: Implement `Linker.ps1`**
  Implement `Resolve-NormalizedPath`, `Test-FileIdentical` (using SHA256 or FileInfo equivalence), and `New-SafeLink` using `mklink /H`, `New-Item -ItemType HardLink`, or P/Invoke `CreateHardLinkW` with fallback to `Copy-Item`.
- [ ] **Step 4: Run test to verify it passes**
  Run: `powershell -ExecutionPolicy Bypass -File tools/ps-manager/tests/test_linker.ps1`
  Expected: PASS on both PS 5.1 and PS 7 (`pwsh`).
- [ ] **Step 5: Commit**
  Run: `rtk git add tools/ps-manager/modules/Sync/Linker.ps1 tools/ps-manager/tests/test_linker.ps1 && rtk git commit -m "feat(sync): implement safe linker and path normalization"`

---

### Task 2: Manifest Parser & Schema Validator (`modules/Sync/Manifest.ps1`)

**Files:**
- Create: `tools/ps-manager/modules/Sync/Manifest.ps1`
- Test: `tools/ps-manager/tests/test_manifest.ps1`

**Interfaces:**
- Produces:
  - `Get-DefaultManifestTemplate() -> [hashtable]`
  - `Read-SyncManifest([string]$ManifestPath) -> [pscustomobject]`
  - `Test-SyncManifest([psobject]$Manifest) -> [pscustomobject]@{ IsValid: bool, Errors: string[] }`

- [ ] **Step 1: Write test harness for Manifest**
  Create `tools/ps-manager/tests/test_manifest.ps1` testing:
  - Reading valid `manifest.json`.
  - Schema validation rejecting missing required sections.
  - Default fallback for missing optional package managers.
- [ ] **Step 2: Run test to verify it fails**
  Run: `powershell -ExecutionPolicy Bypass -File tools/ps-manager/tests/test_manifest.ps1`
  Expected: FAIL.
- [ ] **Step 3: Implement `Manifest.ps1`**
  Implement JSON reading with UTF-8 encoding support, schema validation, and normalization.
- [ ] **Step 4: Run test to verify it passes**
  Run: `powershell -ExecutionPolicy Bypass -File tools/ps-manager/tests/test_manifest.ps1`
  Expected: PASS.
- [ ] **Step 5: Commit**
  Run: `rtk git add tools/ps-manager/modules/Sync/Manifest.ps1 tools/ps-manager/tests/test_manifest.ps1 && rtk git commit -m "feat(sync): implement manifest parser and schema validator"`

---

### Task 3: Multi-Package Provisioner (`modules/Sync/Provisioner.ps1`)

**Files:**
- Create: `tools/ps-manager/modules/Sync/Provisioner.ps1`
- Test: `tools/ps-manager/tests/test_provisioner.ps1`

**Interfaces:**
- Produces:
  - `Install-WingetBatch([array]$Packages, [switch]$DryRun) -> [pscustomobject]`
  - `Install-ScoopBatch([string[]]$Buckets, [string[]]$Apps, [switch]$DryRun) -> [pscustomobject]`
  - `Install-PSGalleryBatch([array]$Modules, [switch]$DryRun) -> [pscustomobject]`
  - `Initialize-ScoopEnvironment() -> [bool]`

- [ ] **Step 1: Write test harness for Provisioner**
  Create `tools/ps-manager/tests/test_provisioner.ps1` checking package detection and mock dry-run installation logic.
- [ ] **Step 2: Run test to verify it fails**
  Run: `powershell -ExecutionPolicy Bypass -File tools/ps-manager/tests/test_provisioner.ps1`
  Expected: FAIL.
- [ ] **Step 3: Implement `Provisioner.ps1`**
  - Winget: Query `winget list --exact --id <id>`; invoke silent install if missing.
  - Scoop: Check `$env:USERPROFILE\scoop\shims\scoop.cmd`; auto-bootstrap if missing; sync buckets; install apps.
  - PSGallery: Enforce TLS 1.2; check `Get-InstalledModule`; install missing via `Install-Module -Scope CurrentUser -Force`.
- [ ] **Step 4: Run test to verify it passes**
  Run: `powershell -ExecutionPolicy Bypass -File tools/ps-manager/tests/test_provisioner.ps1`
  Expected: PASS.
- [ ] **Step 5: Commit**
  Run: `rtk git add tools/ps-manager/modules/Sync/Provisioner.ps1 tools/ps-manager/tests/test_provisioner.ps1 && rtk git commit -m "feat(sync): implement multi-package provisioner for winget, scoop, psgallery"`

---

### Task 4: Profile Snapshot & Backup (`modules/Sync/Backup.ps1`)

**Files:**
- Create: `tools/ps-manager/modules/Sync/Backup.ps1`
- Test: `tools/ps-manager/tests/test_backup.ps1`

**Interfaces:**
- Produces:
  - `Backup-PSManagerProfiles([string]$DestinationDir) -> [string]`
  - `Get-PSManagerBackups() -> [pscustomobject[]]`
  - `Restore-PSManagerBackup([string]$BackupZipPath) -> [bool]`

- [ ] **Step 1: Write test harness for Backup**
  Create `tools/ps-manager/tests/test_backup.ps1` validating zip archiving and restore of PS5 & PS7 profile files.
- [ ] **Step 2: Run test to verify it fails**
  Run: `powershell -ExecutionPolicy Bypass -File tools/ps-manager/tests/test_backup.ps1`
  Expected: FAIL.
- [ ] **Step 3: Implement `Backup.ps1`**
  Uses `Compress-Archive` / `[System.IO.Compression.ZipFile]` to bundle `Documents\PowerShell`, `Documents\WindowsPowerShell`, and `.config` files into a timestamped zip.
- [ ] **Step 4: Run test to verify it passes**
  Run: `powershell -ExecutionPolicy Bypass -File tools/ps-manager/tests/test_backup.ps1`
  Expected: PASS.
- [ ] **Step 5: Commit**
  Run: `rtk git add tools/ps-manager/modules/Sync/Backup.ps1 tools/ps-manager/tests/test_backup.ps1 && rtk git commit -m "feat(sync): implement profile snapshot and restore module"`

---

### Task 5: Master Profile Template & Dual-PS Integration

**Files:**
- Create: `tools/ps-manager/templates/master_profile.ps1`
- Create: `tools/ps-manager/templates/manifest.default.json`
- Create: `tools/ps-manager/templates/local.ps1.example`

**Interfaces:**
- Standardized cross-shell profile compatible with PS 5.1 and PS 7.4+.

- [ ] **Step 1: Create master profile template**
  Write `templates/master_profile.ps1` containing:
  - UTF-8 console output setup (differentiating PS5 conhost and PS7 UTF-8 encoding).
  - Idempotent Scoop shims PATH injection.
  - `fnm` and `starship` dynamic initialization.
  - PS7-only `PSReadLine` ListView prediction and `Terminal-Icons`.
  - Core aliases (`psmgr`, `ps7`, `winps`).
  - `local.ps1` dot-source loader.
- [ ] **Step 2: Create default manifest and local example templates**
  Write `templates/manifest.default.json` and `templates/local.ps1.example`.
- [ ] **Step 3: Verify AST syntax on templates**
  Run parser verification across both PS5 and PS7.
- [ ] **Step 4: Commit**
  Run: `rtk git add tools/ps-manager/templates/ && rtk git commit -m "feat(sync): add universal master profile template and default manifest"`

---

### Task 6: Sync Orchestrator & Doctor Audit (`modules/Sync/SyncEngine.ps1`)

**Files:**
- Create: `tools/ps-manager/modules/Sync/SyncEngine.ps1`
- Modify: `tools/ps-manager/PSManager.psm1`
- Modify: `tools/ps-manager/PSManager.psd1`

**Interfaces:**
- Produces:
  - `Invoke-PSManagerSync([string]$ManifestPath, [switch]$SkipPackages, [switch]$DryRun) -> [pscustomobject]`
  - `Invoke-PSManagerDoctor() -> [pscustomobject[]]`

- [ ] **Step 1: Write test harness for SyncEngine**
  Create `tools/ps-manager/tests/test_sync_engine.ps1` executing dry-run sync and doctor audit.
- [ ] **Step 2: Implement `SyncEngine.ps1`**
  Coordinate Manifest parsing, Linker execution, Provisioner calls, and output formatting.
- [ ] **Step 3: Export module functions**
  Update `PSManager.psm1` and `PSManager.psd1` to export `Invoke-PSManagerSync`, `Invoke-PSManagerDoctor`, `Backup-PSManagerProfiles`.
- [ ] **Step 4: Run tests**
  Run: `powershell -ExecutionPolicy Bypass -File tools/ps-manager/tests/test_sync_engine.ps1`
  Expected: PASS.
- [ ] **Step 5: Commit**
  Run: `rtk git add tools/ps-manager/modules/Sync/SyncEngine.ps1 tools/ps-manager/PSManager.* tools/ps-manager/tests/test_sync_engine.ps1 && rtk git commit -m "feat(sync): implement sync orchestrator and doctor audit engine"`

---

### Task 7: CLI Subcommands & TUI Integration

**Files:**
- Modify: `tools/ps-manager/ps-manager.ps1`
- Modify: `tools/ps-manager/modules/UI/TuiEngine.ps1`
- Modify: `tools/ps-manager/i18n.json`

**Interfaces:**
- CLI: `psmgr sync`, `psmgr doctor`, `psmgr backup`, `psmgr restore`
- TUI: Menu item `[Y] Profile Sync & Backup`

- [ ] **Step 1: Update CLI dispatcher `ps-manager.ps1`**
  Add cases for `sync`, `doctor`, `backup`, `restore` subcommands with help documentation.
- [ ] **Step 2: Update TUI engine `TuiEngine.ps1`**
  Add submenu for Sync operations and live status card.
- [ ] **Step 3: Update i18n dictionary `i18n.json`**
  Add strings for sync/doctor/backup across `vi`, `vi-ascii`, and `en`.
- [ ] **Step 4: Test CLI commands manually**
  Run `psmgr sync --dry-run` and `psmgr doctor`.
- [ ] **Step 5: Commit**
  Run: `rtk git add tools/ps-manager/ps-manager.ps1 tools/ps-manager/modules/UI/TuiEngine.ps1 tools/ps-manager/i18n.json && rtk git commit -m "feat(sync): add sync subcommands to cli and tui dashboard"`

---

### Task 8: Zero-State Web Bootstrapper (`boot.ps1`)

**Files:**
- Create: `tools/ps-manager/boot.ps1`
- Test: `tools/ps-manager/tests/test_bootstrapper.ps1`

**Interfaces:**
- Remote execution: `irm https://.../boot.ps1 | iex` on clean Windows 10/11 machine.

- [ ] **Step 1: Implement `boot.ps1`**
  - PS 5.1 guard: Set TLS 1.2, set ExecutionPolicy RemoteSigned.
  - Ensure Winget & Git are available.
  - Install PowerShell 7 (`winget install Microsoft.PowerShell --silent`).
  - Clone or update `ps-manager` repo at `~/tools/ps-manager`.
  - Handover to PS7: `& pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\tools\ps-manager\ps-manager.ps1" sync --bootstrap`.
- [ ] **Step 2: Validate AST parsing on `boot.ps1`**
  Parse with PS 5.1 engine to guarantee zero modern syntax leaks.
- [ ] **Step 3: Commit**
  Run: `rtk git add tools/ps-manager/boot.ps1 tools/ps-manager/tests/test_bootstrapper.ps1 && rtk git commit -m "feat(bootstrap): add zero-state web bootstrapper with ps5-to-ps7 handover"`

---

### Task 9: Comprehensive Test Suite & CI Integration

**Files:**
- Modify: `tools/ps-manager/tests/harness.ps1`
- Modify: `tools/ps-manager/.github/workflows/ci.yml`

- [ ] **Step 1: Extend test harness `harness.ps1`**
  Add Test Suite 6 (Sync & Linking tests), Test Suite 7 (Manifest & Schema validation), and Test Suite 8 (Backup & Restore).
- [ ] **Step 2: Run complete harness on PS 5.1 and PS 7**
  Run:
  - `powershell -ExecutionPolicy Bypass -File tools/ps-manager/tests/harness.ps1`
  - `pwsh -ExecutionPolicy Bypass -File tools/ps-manager/tests/harness.ps1`
  Expected: 100% tests passing on both versions.
- [ ] **Step 3: Verify GitHub Actions CI config**
  Ensure CI runs the updated harness across both matrix environments.
- [ ] **Step 4: Commit**
  Run: `rtk git add tools/ps-manager/tests/harness.ps1 tools/ps-manager/.github/workflows/ci.yml && rtk git commit -m "test(ci): integrate profile sync test suites into automated harness"`
