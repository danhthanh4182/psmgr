# PSManager Coding Standards & Engineering Guardrails

This document establishes the technical, architectural, and security guardrails for contributing code to PSManager.

---

## 1. Naming & API Contracts

### 1.1 PowerShell Approved Verbs
Every public and exported function **MUST** use an official PowerShell verb recognized by `Get-Verb`.
- **Approved Examples**:
  - `Get-` : Retrieve system or configuration state (`Get-PSManagerConfig`, `Get-PSManagerLogs`)
  - `Set-` : Change persistent or system configuration (`Set-PowerShell7Default`)
  - `New-` : Create a new resource or link (`New-SafeLink`)
  - `Invoke-` : Execute an end-to-end orchestration (`Invoke-PSManagerSync`, `Invoke-PSManagerDoctor`)
  - `Install-` : Deploy software packages (`Install-WingetBatch`, `Install-ScoopBatch`)
  - `Backup-` : Snapshot state into archive (`Backup-PSManagerProfiles`)
  - `Restore-` : Rollback state from archive (`Restore-PSManagerBackup`)
  - `Test-` : Boolean verification probe (`Test-FileIdentical`, `Test-SyncManifest`)
  - `Clear-` : Wipe or purge resources (`Clear-PSManagerLogs`)
- **Prohibited Verbs**:
  - `Append-`, `Refresh-`, `Check-`, `Create-`, `Delete-` (use `Add-`, `Update-`, `Test-`, `New-`, `Remove-`).

### 1.2 Singular Noun Preference
Prefer singular nouns for functions targeting single entities. Plural nouns are permitted exclusively when the function semantically returns a collection (`Get-PSManagerLogs`, `Get-PSManagerBackups`, `Get-PSInstallations`).

---

## 2. Dual-Runtime Compatibility (PS 5.1 & PS 7+)

### 2.1 Prohibited Language Features in Shared Code
Code running on or loaded by Windows PowerShell 5.1 must avoid PowerShell 7+ syntax additions:
| Feature | PS7 Syntax (PROHIBITED in shared code) | PS 5.1 / Shared Equivalent (REQUIRED) |
|---|---|---|
| Null-coalescing | `$a ?? $b` | `if ($null -ne $a) { $a } else { $b }` |
| Null-conditional | `$obj?.Prop` | `if ($obj) { $obj.Prop }` |
| Pipeline chain | `cmd1 && cmd2` | `cmd1; if ($?) { cmd2 }` |
| Pipeline chain | `cmd1 \|\| cmd2` | `cmd1; if (-not $?) { cmd2 }` |
| Ternary operator | `$c ? $a : $b` | `if ($c) { $a } else { $b }` |

### 2.2 Drive-Colon Variable Collision Guard
In Windows PowerShell 5.1, double-quoted strings containing `$variable:` parse `:` as a drive qualifier (e.g. `$env:`).
- ❌ **Broken**: `"$src -> $target: error"` -> Throws `InvalidVariableReferenceWithDrive`.
- ✅ **Safe**: `"$($src) -> $($target): error"` or `"${src} -> ${target}: error"`.

---

## 3. Filesystem & Linking Guardrails

1. **Always Use `-LiteralPath`**:
   Wildcard characters (`[`, `]`, `*`, `?`) in paths will fail or trigger unexpected expansions under `-Path`. Always pass `-LiteralPath`.
2. **Volume Boundary Verification**:
   Hardlinks cannot span across different file volumes. Always compare root paths:
   ```powershell
   if ([System.IO.Path]::GetPathRoot($src) -ne [System.IO.Path]::GetPathRoot($dst)) {
       # Fall back to file copy
   }
   ```
3. **Fail-Safe Linking Hierarchy**:
   Every link operation must attempt `Hardlink -> Symlink -> Copy` with nested `try/catch` fallbacks. Linking must never leave the user without a working profile.
4. **Non-Destructive Backups**:
   Never overwrite differing destination files without generating `.bak.<timestamp>`.

---

## 4. Performance & Memory Guardrails

1. **Avoid Array `+=` in Loops**:
   PowerShell arrays are fixed-size in .NET. Using `$array += $item` recreates the entire array in memory on each iteration.
   - Use `[System.Collections.Generic.List[T]]::new()` for accumulators.
2. **Native Cryptography & Streaming**:
   Use .NET streams (`[System.Security.Cryptography.SHA256]`) for file hashing to avoid cmdlet loading overhead on large dotfiles.
3. **Non-Locking File Streams**:
   File reads on shared resources (like log files) must explicitly allow shared writing:
   ```powershell
   [System.IO.FileStream]::new($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
   ```

---

## 5. Security & Elevation

1. **Least Privilege Principle**:
   All core capabilities (sync, backup, linking, scoop installation) must operate cleanly under standard user privileges.
2. **Registry Scoping**:
   All registry modifications must target `HKCU` (`CurrentUser`). Never write to `HKLM` without explicit user interaction and warning.
3. **Execution Policy Boundaries**:
   Pass `-ExecutionPolicy Bypass` scoped per-process. Never execute `Set-ExecutionPolicy -Scope LocalMachine` without operator confirmation.
