# Agent Instructions & Guidelines (`AGENTS.md`)

Instructions for AI coding agents and automated contributors working in this repository.

---

## 1. Core Mandates

- **Dual-Runtime Enforcement**: Every `.ps1`, `.psm1`, and `.psd1` file MUST execute and parse cleanly on **both Windows PowerShell 5.1 (Desktop)** and **PowerShell 7.4+ (Core)**.
- **Prohibited Operators in Shared Code**: Never use PS7-only operators (`??`, `?.`, `&&`, `||`, ternary `?:`) in files loaded by PS 5.1.
- **PowerShell Approved Verbs**: Every exported and public function MUST use official PowerShell verbs (`Get-Verb`). Run `Get-Verb` to verify before choosing function names.
- **Literal Paths**: Always use `-LiteralPath` rather than `-Path` on filesystem cmdlets (`Test-Path`, `Get-Item`, `Copy-Item`, `Move-Item`, `Remove-Item`) to guard against bracket syntax errors (`[`, `]`).
- **Zero Secret Leakage**: The engine is 100% public-safe. Never hardcode API keys, passwords, or personal credentials. Delegate all machine overrides to `local.ps1` or environment variables.
- **Tri-Interface Parity Mandate**: Every user-facing capability MUST be implemented simultaneously across all three interfaces:
  1. **CLI** (`ps-manager.ps1`): registered in parameter `[ValidateSet()]` and dispatched in `switch ($Action)`.
  2. **TUI** (`modules/UI/TuiEngine.ps1`): registered in `$menuItems` with dedicated keybinding and handler.
  3. **Desktop GUI** (`gui.ps1`): declared with native SVG vector button and wired to `Invoke-GuiAction`.
  4. **Central Registry** (`modules/Core/ActionRegistry.ps1`): registered in `Get-PSManagerActions`.
  Enforced automatically by contract test `tests/test_interface_parity.ps1` in pre-commit and pre-push gates. Any feature implemented in one interface while omitting another will FAIL the test suite.

---

## 2. Validation & Quality Gates

Before declaring any task or PR complete, run the complete cross-version verification suite:

```powershell
# 1. Run automated cross-version test suite (PS 5.1 & PS 7)
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Run-Tests.ps1

# 2. Run static analysis linter (Must produce 0 Errors, 0 Warnings)
pwsh -NoProfile -ExecutionPolicy Bypass -Command "Invoke-ScriptAnalyzer -Path . -Settings PSScriptAnalyzerSettings.psd1 -Recurse"

# 3. Validate Module Manifest
powershell -NoProfile -ExecutionPolicy Bypass -Command "Test-ModuleManifest PSManager.psd1"
```

If any test fails or PSScriptAnalyzer emits a warning, fix the root cause before committing.

---

## 3. Filesystem & Linking Conventions

- **Safe Linking Order**: Hardlink -> Symlink -> Copy.
  - Hardlinks cannot cross volumes (`C:` to `D:`). Check volume roots via `[System.IO.Path]::GetPathRoot`.
  - Wrap hardlink and symlink attempts in nested `try/catch` with fallback to `Copy-Item`.
- **Automatic Backups**: Always create `.bak.<timestamp>` when modifying or replacing existing differing files.
- **Path Normalization**: Use `Resolve-NormalizedPath` to expand `~`, `$HOME`, `%USERPROFILE%`, and normalize slashes.
- **Environment Variables**: In `manifest.json`, only normalize path-like values (`~`, `.\`, `/`, `\`); preserve scalar configuration strings (`"dark"`, `"true"`) intact.

---

## 4. Diagnostic Logging

- Use `Write-PSManagerLog -Message <string> -Level <INFO|WARN|ERROR|DEBUG>`.
- File logger operates in non-locking mode (`[System.IO.FileShare]::ReadWrite`) to prevent concurrent terminal deadlocks.
- Logging failures must be non-fatal (never fail a core operation because logging threw).

---

## 5. Git Commit & Review Discipline

- All commits must follow Conventional Commits (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `ci:`).
- Git pre-commit hooks (`.agents/hooks/pre-commit`) execute `Run-Tests.ps1` automatically on every commit. Never bypass with `--no-verify` unless explicitly instructed.
- **CI Verification Mandate**: Whenever changes are pushed to remote, the agent/contributor MUST verify GitHub Actions CI using native `gh run watch --exit-status` until the workflow run completes with success. Never declare a task complete while CI is failing or unverified.
---

## 6. Documentation & Changelog Synchronization

- **Changelog Integrity**: Every commit that introduces a `feat:` or `fix:` modifying code MUST update `CHANGELOG.md` under `[Unreleased]` or the targeted version section.
- **Documentation Parity**: Whenever CLI subcommands, parameters, GUI controls, or configuration options are added or modified, update `README.md`, `CONTEXT.md`, and relevant files under `docs/` in the same commit.
- **Universal Agent Architecture (`AGENTS.md` + `.agents/`)**:
  - **`AGENTS.md`** (Root): Canonical Single Source of Truth for all coding agents (Cursor, Windsurf, Cline, Roo Code, Claude Code, Gemini, Copilot, Pi, OpenCode, Devin, Aider).
  - **`.agents/hooks/`**: Universal hook directory housing both native Git hooks (`commit-msg`, `pre-commit`, `pre-push`) and agent PreToolUse interceptors (`guard-changelog-docs.sh`, `block-dangerous-git.sh`).
  - **Universal Git Enforcement**: `git config core.hooksPath .agents/hooks` activates hooks for all CLI, API, and IDE git operations. Run `setup-hooks.cmd` or `setup-hooks.ps1` to configure anytime.
  - **Hooks are LF-only**: `.agents/hooks/*` are parsed by `sh`, which treats `\r` as a literal character and fails on CRLF (`$'\r': command not found`), silently disabling the guard. `.gitattributes` pins `eol=lf`; `tests/harness.ps1` fails the suite if any hook contains CR.
  - **Every `tests/test_*.ps1` must be registered in `tests/harness.ps1`**: the harness asserts this, so a new test file that no gate runs breaks the build instead of being silently skipped.
  - Legacy entrypoints (`CLAUDE.md`, `GEMINI.md`, `.cursorrules`) are maintained as lightweight pointers to `AGENTS.md`.
