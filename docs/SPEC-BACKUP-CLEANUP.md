# Specification: Destructive Backup Cleanup

**Spec ID**: SPEC-BACKUP-CLEANUP-001  
**Status**: Implemented  
**Component**: `modules/Sync/Backup.ps1` (`Remove-PSManagerBackup`), CLI, TUI, GUI  

---

## 1. Problem

`psmgr backup` / `psmgr backup-cloud` accumulate archives both locally
(`%LOCALAPPDATA%\PSManager\backups\profile_backup_*.zip[.enc]`) and as GitHub
Releases. There was no supported way to delete them, forcing users into manual
`Remove-Item` / `gh release delete` with no guardrails.

Deletion is **irreversible**, so the feature must be deliberately hard to
trigger by accident.

---

## 2. Functional Requirements

### 2.1 Core module (`Remove-PSManagerBackup`)
- **FR-BC-1.1**: MUST implement `SupportsShouldProcess` with
  `ConfirmImpact = 'High'` so `-WhatIf` previews and default confirmation is
  elevated.
- **FR-BC-1.2**: MUST support three selection modes:
  - `-Name <string[]>` — one or many backup file names (multi-delete);
  - `-All` — every backup currently present;
  - neither → MUST throw (fail-closed, never default to deleting everything).
- **FR-BC-1.3**: MUST return a result object
  `{ Deleted, Skipped, FreedKB, Paths, Errors }`.
- **FR-BC-1.4**: MUST be idempotent-safe: a missing directory returns a zeroed
  result rather than throwing.

### 2.2 Safety invariants
- **FR-BC-2.1 (containment)**: Every resolved target MUST start with the
  backups directory prefix (case-insensitive, path-separator aware). Anything
  outside MUST be refused and reported, never deleted.
- **FR-BC-2.2 (scope)**: Only files matching
  `^profile_backup_.*\.zip(\.enc)?$` are eligible. Non-backup files in the same
  directory MUST remain untouched even when named explicitly.
- **FR-BC-2.3 (race)**: A file that disappears between listing and deletion
  MUST be counted as skipped, not as an error that aborts the batch.

### 2.3 CLI (`psmgr clean-backups`)
- **FR-BC-3.1**: MUST print a destructive banner
  (`!! WARNING: DESTRUCTIVE OPERATION ... !!`) followed by the exact list of
  files selected for deletion.
- **FR-BC-3.2**: Selection syntax: `all`, or one/more names separated by
  `,` `;` or whitespace. Each token MUST resolve to **exactly one** archive:
  1. an exact file-name match wins;
  2. otherwise a partial token is accepted only when it matches exactly one
     archive;
  3. zero matches → report `not found` and abort with exit `1`;
  4. more than one match → list the candidates and abort with exit `1`
     (never silently pick the first);
  5. a selector that yields no tokens at all (e.g. `","`) MUST abort with exit
     `1` rather than proceeding with an empty selection.
  This holds even with `-Force`: the resolved file list is always echoed before
  deletion, so a partial token can never delete a different archive than the
  caller intended.
- **FR-BC-3.3**: In an interactive session the user MUST type the literal
  string `DELETE` to proceed; anything else aborts with no deletion.
- **FR-BC-3.4**: In a **non-interactive** session (redirected stdin) the
  command MUST refuse and exit `1` unless `-Force` is supplied.
- **FR-BC-3.5**: `-Force` bypasses prompts but MUST still honour containment
  and scope invariants.

### 2.4 TUI (`[X]`)
- **FR-BC-4.1**: MUST open with the destructive warning before listing anything.
- **FR-BC-4.2**: MUST list backups as numbered entries and accept
  `1,3,5`, ranges (`1-3`), or `all`; blank input aborts.
- **FR-BC-4.3**: MUST show the resolved selection and require typed `DELETE`
  before executing.

### 2.5 GUI (`BtnDeleteBackups`)
- **FR-BC-5.1**: Button MUST use a danger palette (`#7F1D1D` / `#DC2626`)
  and a destructive tooltip.
- **FR-BC-5.2**: Dialog MUST show a red banner, an **extended multi-select**
  list of backups, and a confirmation textbox.
- **FR-BC-5.3**: The confirm button MUST stay disabled until the textbox
  contains exactly `DELETE` **and** at least one item is selected.
- **FR-BC-5.4**: Cancelling MUST log an abort message and delete nothing.

### 2.6 Parity
- **FR-BC-6.1**: The capability MUST be registered in
  `modules/Core/ActionRegistry.ps1` as `clean-backups` with
  `CliAction = 'clean-backups'`, `TuiKey = 'X'`,
  `GuiButton = 'BtnDeleteBackups'`.
- **FR-BC-6.2**: `tests/test_interface_parity.ps1` MUST pass with 23
  capabilities.

---

## 3. Non-Goals

- Deleting **cloud** releases (GitHub) — separate destructive surface, not in
  this spec.
- Scheduling / automatic retention pruning — `Clear-PSManagerLogs` covers log
  retention only.
- Restore-then-delete workflows.

---

## 4. Acceptance Tests

`tests/test_backup_cleanup.ps1` (registered in `tests/harness.ps1`):

| # | Case | Expectation |
|---|------|-------------|
| 1 | `-All` on 2 backups | both deleted, dir empty |
| 2 | `-Name` one of 3 | exactly that one deleted |
| 3 | `-Name` two of 3 | 2 deleted, correct survivor |
| 4 | `-WhatIf` | nothing deleted |
| 5 | non-backup file named explicitly | untouched, skipped |
| 6 | `..\outside.zip` traversal | refused, outside file intact |
| 7 | no `-All` and no `-Name` | throws |
| 8 | missing directory | zeroed result, no throw |
| 9 | successful deletion | `Backup cleanup: deleted=1` in log |
| 10 | `Test-FileHardLink` on a link pair / independent file | correctly reports linked / not linked |
| 11 | `Set-DetachedFileContent` on a hardlinked target | other link holder byte-identical; target updated; `DetachedFromLink = $true` |
| 12 | `Set-DetachedFileContent` on a missing path | file created; `DetachedFromLink = $false` |
| 13 | CLI token matching 2+ archives, with `-Force` | lists candidates, exits `1`, deletes nothing |
| 14 | `Get-HardLinkPaths` on a link pair | lists both paths, one of them the queried file |
| 15 | `Set-DetachedFileContent -Bytes` (UTF-16 payload) | bytes reproduced verbatim; peer untouched |
| 16 | `Restore-PSManagerBackup` from a UTF-16 profile | restored file byte-identical to the archived one |
| 17 | CLI selector that yields no tokens (`,`) | exits `1`, deletes nothing |

CLI smoke (manual):

```
psmgr clean-backups                    # non-interactive -> exit 1, nothing deleted
psmgr clean-backups <name> -Force      # deletes only <name>
```
