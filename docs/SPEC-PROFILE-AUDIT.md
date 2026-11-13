# Specification: Profile Compatibility Auditor & Repair

**Spec ID**: SPEC-PROFILE-AUDIT-001  
**Status**: Implemented  
**Components**: `modules/Sync/ProfileAuditor.ps1`, `modules/Sync/SyncEngine.ps1`, CLI / TUI / GUI  

---

## 1. Problem

A single PowerShell profile is synced to **both** Windows PowerShell 5.1 and
PowerShell 7. Any PS7-only construct (`??`, `?.`, ternary, `&&`/`||`) or any
PS7-only module (`Terminal-Icons`) silently breaks the 5.1 session. Module
ordering also matters: `posh-git` ships its own `prompt` function, so importing
it *after* `starship init` silently replaces the Starship prompt.

There was no way to detect or repair these conditions; failures surfaced as
"prompt disappeared" or "profile throws on startup".

---

## 2. Functional Requirements

### 2.1 `Test-PSManagerProfile`
- **FR-PA-1.1**: MUST audit both targets by default (`5.1`, `7`), with
  `-TargetVersion` (`5.1` | `7` | `All`) and `-ProfilePath` overrides.
- **FR-PA-1.2**: Checks per target, each producing
  `{ Category, Item, Status, Details, Recommendation }`:
  1. **File Existence** — `WARN` when missing.
  2. **AST Syntax** — `FAIL` on any `[Parser]::ParseInput` error.
  3. **PS 5.1 Syntax Compatibility** (5.1 only) — `FAIL` when the body contains
     `??`, `?.`, ternary `?:`, or `&&` / `||` chaining.
  4. **Module Load Order** — `FAIL` when `posh-git` appears after
     `starship init`.
  5. **Terminal-Icons Guard** (5.1 only) — `FAIL` unless the import is lexically
     inside a `if ($PSVersionTable.PSVersion.Major -ge 7) { ... }` block.
  6. **PSReadLine Prediction Guard** — `WARN` unless the
     `Set-PSReadLineOption -Prediction*` call is inside `try { ... }` (the call
     throws when stdout is redirected).
  7. **`STARSHIP_CONFIG` (User)** — `FAIL` when the user-scoped variable points
     at a file that does not exist.
  8. **Payload Link Safety** — `Get-HardLinkPaths` lists the actual inodes peers:
     `PASS` when the profile is independent (or shares only with another live
     profile), `WARN` when one of the peers lives under `templates\profiles\`
     (an editor save would rewrite the tracked payload), and the literal state
     "unknown" when the host cannot report links.
- **FR-PA-1.3**: Brace-nesting MUST be honoured: guard detection MUST NOT rely
  on `[^}]*`-style regexes that break on nested blocks.
  Implemented by `Test-ProfileBlockEnclosing`, which walks the text between the
  nearest opener and the anchor counting `{` / `}` and fails the moment the
  running balance goes negative.
- **FR-PA-1.4**: PS7-operator detection MUST be **token-based**, never a raw-text
  regex. A regex misreads `?` inside string literals (e.g. the signed-command
  pattern `'^--?model(=|$)'`) as a ternary. `Get-ProfilePs7OnlyConstructs`
  inspects `TokenKind` (`QuestionQuestion`, `QuestionQuestionEquals`,
  `QuestionMark`, `AndAnd`, `OrOr`, plus `Variable` ending in `?` followed by
  `Dot` for `?.`). On Windows PowerShell 5.1 those constructs do not tokenize and
  surface as AST parse errors instead.

### 2.2 `Repair-PSManagerProfile`
- **FR-PA-2.1**: MUST back up each profile to
  `<profile>.bak.<yyyyMMdd_HHmmss>` before mutating it.
- **FR-PA-2.2**: MUST repair, in order:
  - reorder `posh-git` before `starship`;
  - wrap an unguarded `Import-Module Terminal-Icons` in a PS7 guard;
  - wrap `Set-PSReadLineOption -Prediction*` in
    `try { if (-not [Console]::IsOutputRedirected) { ... } } catch {}`;
  - restore an invalid user-scoped `STARSHIP_CONFIG` to
    `~/.config/starship.toml`;
  - scaffold a missing profile from
    `templates/profiles/master_profile.ps1`, resolved relative to the module
    root (never a hardcoded installer path).
- **FR-PA-2.3**: MUST be idempotent — a second run on a compliant profile
  MUST report `PASS`/"no repairs needed" and not rewrite the file.
- **FR-PA-2.4**: MUST return one result row per applied repair with
  `Status = 'FIXED'`.
- **FR-PA-2.5 (link safety)**: Live profiles may be **hardlinks** to
  `templates/profiles/master_profile.ps1`. A plain `Set-Content` on such a path
  mutates the tracked repo payload as a side effect. Repair MUST therefore write
  through `Set-DetachedFileContent` (temp file → rename target aside → rename
  temp into place → delete the aside copy, rolling back if the swap fails), which
  drops only the target's directory entry and leaves every other link holder
  untouched. It MUST preserve the original file attributes and report
  `Item = "Link Safety"`, `Status = 'FIXED'` when a link was detached.
- **FR-PA-2.6**: `Restore-PSManagerBackup` MUST use the same link-detaching write,
  and MUST pass `-Bytes` (`[IO.File]::ReadAllBytes`) so the archived profile is
  reproduced byte-for-byte instead of being decoded and re-encoded.

### 2.3 Doctor integration
- **FR-PA-3.1**: `Invoke-PSManagerDoctor` MUST include profile checks as
  check #8.
- **FR-PA-3.2**: With `-Fix`, doctor MUST run `Repair-PSManagerProfile` first
  and surface only non-`PASS` repair rows.

### 2.4 Interfaces
- **FR-PA-4.1**: CLI — `psmgr audit-profile` (audit) and
  `psmgr audit-profile -Fix` (audit + repair). Exits `1` when unresolved
  `WARN`/`FAIL` remain and `-Fix` was not requested.
- **FR-PA-4.2**: TUI — `[T]` menu action; `[F]` triggers repair when issues are
  found.
- **FR-PA-4.3**: GUI — `BtnAuditProfiles` delegates to
  `Invoke-PSManagerAction -Action 'audit-profile'`.
- **FR-PA-4.4**: Registered as `audit-prof` in `ActionRegistry.ps1`
  (`TuiKey = 'T'`, `GuiButton = 'BtnAuditProfiles'`).

### 2.5 Template contract
- **FR-PA-5.1**: `templates/profiles/master_profile.ps1` MUST itself satisfy
  every check: `posh-git` before `starship`, guarded `Terminal-Icons`,
  `try/catch`-wrapped prediction, no PS7-only operators.
- **FR-PA-5.2**: The template MUST NOT contain machine-specific content
  (host paths, API keys, personal functions). Those belong in `local.ps1`,
  which the template dot-sources from `$PSScriptRoot`.

---

## 3. Non-Goals

- Executing the profile during the audit (no side effects in a checker).
- Rewriting user-authored sections other than the four targeted repairs.
- Detecting arbitrary PS7-only cmdlets via static analysis of module manifests.

---

## 4. Acceptance Tests

`tests/test_profile_auditor.ps1`:

| # | Case | Expectation |
|---|------|-------------|
| 1 | compliant fixture | 0 `FAIL` rows |
| 2 | `posh-git` after `starship` | `Module Load Order` = `FAIL` |
| 3 | unguarded `Terminal-Icons` on 5.1 | `Terminal-Icons Guard` = `FAIL` |
| 4 | repair run | order fixed, guard added, prediction wrapped |
| 5 | `??` / `?:` / `&&` in body | `PS 5.1 Syntax Compatibility` = `FAIL` (PS 7) or `AST Syntax` = `FAIL` (PS 5.1) |
| 6 | `?` only inside a string literal / `?` Where-Object alias | `PS 5.1 Syntax Compatibility` = `PASS` (no false positive) |
| 7 | repair of a **hardlinked** profile | payload template byte-identical afterwards; live profile updated; `Link Safety` = `FIXED` |
| 8 | write to a missing path | file created, `DetachedFromLink = $false` |
| 9 | profile hardlinked to `templates\profiles\master_profile.ps1` | `Payload Link Safety` = `WARN`, names the peer, suggests `audit-profile -Fix` |
| 10 | live 5.1↔7 link pair | `Payload Link Safety` = `PASS`, names the live peer, makes no payload claim |

Live fixture (`templates/profiles/master_profile.ps1` synced to both profiles)
MUST return `PASS` on all 14 reported rows.
