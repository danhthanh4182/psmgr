# UI/UX discovery — omp (GUI Track A + TUI/CLI Phase 1)

Environment: Windows 11 (10.0.26300), Windows PowerShell 5.1 + PowerShell 7.4, repo
`C:\Users\<user>\tools\ps-manager`, worktree `..\psmgr-wt-omp` on branch `feat/uiux-omp`.
No side-effecting operation was executed while producing this document (no default switch, package
install/update, `$PROFILE` write, backup/restore/cloud/`doctor -Fix`). Status/version queries and
off-screen WPF rendering only.

---

## 1. GUI baseline (before Track A)

Evidence: `docs/ui-ux/shots/before/{1280x800,1920x1080,2560x1440}.png`, produced by
`tools/Capture-PSManagerGui.ps1 -Source inline` from the 510-line XAML here-string in `gui.ps1`.

Facts measured from the code and the shots:

1. The whole window was a here-string (`gui.ps1:39-548`), loaded with `XamlReader.Load`; there was no
   XAML file, so no editor/validation/diff story and no theme dictionary.
2. Colours were hardcoded hex at ~40 sites (`#0F172A`, `#1E293B`, `#38BDF8`, `#4ADE80`, `#FACC15`,
   `#B45309`, `#7F1D1D`, …) and mirrored again in PowerShell (`$bc.ConvertFromString(...)`, 9 brushes).
3. All 27 controls sat in two 50/50 panels: no chapter separation, no navigation, no page concept.
   The destructive "Delete Backups" button was one row below "Backup to Cloud".
4. Section labels were ALL CAPS ("DEFAULT SHELL", "MAINTENANCE", "EXECUTION LOG"); at 11-13 px this
   flattens diacritics and reads as shouting.
5. The log was a plain `TextBox`: single colour, no timestamps, no severity, no filtering, and URLs
   were dead text.
6. No keyboard focus ring (the implicit template only recoloured the border), no
   `AutomationProperties.Name`, so screen readers announced "button".
7. Buttons carried five different ad-hoc fills; the accent colour was also used for the source
   selector and the TUI button, so "primary action" was visually ambiguous.
8. WPF's default (light) `ToolTip` and the stock light window frame clashed with the dark surface.
9. Baseline suite before any change: `tests/Run-Tests.ps1` → **80/80 passed** on 5.1 and again on
   pwsh 7 (cross-verification runs the same harness under `pwsh.exe -File`).

## 2. GUI after Track A

Evidence: `docs/ui-ux/shots/after/{1280x800,1920x1080,2560x1440}.png` (renderer, `-Source files`),
`docs/ui-ux/shots/after/gui-live-*.png` (real launched process captured with `PrintWindow`/
`CopyFromScreen`), `gui-live.png` shows the dark title bar.

| Concern | Result |
|---|---|
| Markup location | `ui/PSManager.MainWindow.xaml` (598 lines) + `ui/PSManager.Theme.xaml` (tokens/styles), loaded by `ui/GuiLoader.ps1` |
| Colour source | 13 brush tokens + 3 font tokens + 15 styles in the theme dictionary; `gui.ps1` keeps 3 brush lookups (`OkBrush`, `WarnBrush`, `TextDimBrush`) |
| Navigation | 5-item rail (Overview, Update, Backup, Health, Profiles); `RadioButton` + `ui/GuiNavigation.ps1` (`Show-GuiPage`, `Initialize-GuiNavigation`) |
| Primary action | exactly one `BtnPrimary` per page, asserted by `tests/test_gui_xaml.ps1` |
| Content width | wrapper `MaxWidth=1200` with `Stretch` alignment (WPF centres the clamped block); verified at 2560 px |
| Log | `RichTextBox`, per-level colours, dim `[HH:mm:ss]` runs, clickable links, live filter (150 px) with placeholder |
| Focus | `FocusRing` on `Btn`, `BtnPrimary`, `BtnDanger`, `BtnRow`, `Segment`, `NavItem`; visible in `gui-live-focus.png` |
| Title bar | dark via `DwmSetWindowAttribute(hwnd, 20|19, 1, 4)`, wrapped in try/catch |
| Labels | sentence case in all three i18n sections |

### Contrast (computed, not eyeballed)

Relative luminance per WCAG 2.1 (sRGB, 0.03928 threshold), ratio = (L1+0.05)/(L2+0.05):

| Foreground | Background | Ratio | Requirement |
|---|---|---|---|
| `#9BAECB` TextDimBrush | `#0D1B30` SurfaceBrush | **7.65:1** | AA body ≥ 4.5:1 → pass |
| `#9BAECB` TextDimBrush | `#07101F` BgBrush | 8.44:1 | pass |
| `#E8EEF8` TextBrush | `#07101F` BgBrush | **16.33:1** | pass |
| `#4DA3FF` AccentBrush | `#07101F` BgBrush | 7.25:1 | pass |
| `#04122B` OnAccentBrush | `#4DA3FF` AccentBrush (primary button) | 7.10:1 | pass |
| `#3DD68C` OkBrush | `#0D1B30` | 9.20:1 | pass |
| `#F2B84B` WarnBrush | `#0D1B30` | 9.64:1 | pass |
| `#F0605D` DangerBrush | `#0D1B30` | 5.37:1 | pass |

## 3. Defects found during implementation

1. **`i18n.json` was read from an absolute path** (`modules/Core/I18n.ps1:7` →
   `C:\Users\<user>\tools\ps-manager\i18n.json`). In any worktree, copy or installed package every
   `Get-I18nText` call returned the raw key (the GUI rendered `gui_nav_overview` instead of
   "Overview"). Fixed by resolving `<root>\i18n.json` from `$PSScriptRoot`; the harness i18n test
   passes on both engines.
2. **Centring a WPF block by `MaxWidth` alone does not work**: a Grid with `HorizontalAlignment=Center`
   sizes to its desired width (measured 684 px), and binding `Width` to `Window.ActualWidth` produced a
   0-width block before the first layout pass (blank screenshot). `MaxWidth` + default `Stretch`
   alignment is the reliable form — WPF centres the clamped block.
3. **`Hyperlink` without `NavigateUri` never raises `RequestNavigate`**, so log links looked right but
   did nothing. Found by the new test, fixed in `Add-LogEntryBlock`.
4. `param($sender, $args)` in the navigation handler tripped `PSAvoidAssignmentToAutomaticVariable`;
   renamed to `$navSource`/`$navEvent`.

## 4. Deviations from the approved plan (and why)

| Plan item | Actual | Reason |
|---|---|---|
| Theme: only `FieldLabel`, `NavItem`, implicit `Button` added | also added `Input` (TextBox) and an implicit `ToolTip` style | the window cannot style its own log filter/tooltips once `Window.Resources` holds only icon geometries; without these the filter box and tooltips stayed white |
| Header not wrapped in the 1200 px block | whole window body (header, pages, log) is one centred 1200 px block | otherwise the title sat 20 px left of the cards at every width |
| Add `gui_btn_backup_cloud_tip` | not added; `gui_btn_cloud_backup_tip` is reused | grep found the existing key; a second key with the same meaning would be dead weight |
| Tooltips from `menu_*_desc` | GUI buttons now use the new short `gui_btn_*_tip` keys | shorter, single-purpose copy; the long TUI descriptions stay with the TUI |
| `-Source inline` shell extraction line `'$xaml = @"'` exact match | matched on `Trim()` | the here-string line has no leading spaces but this keeps the tool robust |

## 5. TUI / CLI inventory (addendum Phase 1)

Scope: facts needed for C0–C4 (pi) and C5–C8/C10 (omp). No TUI/CLI code was changed.

### TUI (`modules/UI/TuiEngine.ps1`, 623 lines)

| Aspect | Current behaviour (file:line) | Addendum expectation |
|---|---|---|
| Menu | one flat list of 24 items + exit, fixed order (`TuiEngine.ps1:156-181`) | 5 groups matching GUI IA |
| Grouping | none; `Category` exists in the registry but is unused by the TUI | required |
| Selected item | description expands under the item, pushing the rows below (`:229-231`) | fixed right-hand detail pane |
| Layout | fixed inner width `$Script:TUI_WIDTH = 74` (`:9`), ASCII box `+ - |` (`:195`) | responsive, Unicode box with ASCII fallback |
| Screen writes | `Clear-Host` at the top of every loop (`:153`), one `Write-Host` per line (~30 lines) | diff rendering, no `Clear-Host` |
| Key input | `[Console]::ReadKey($true)` when a TTY, otherwise `Read-Host` with a numeric prompt (`:242-264`) | raw key handling + plain mode |
| Key map | digits 1-9/0 plus letters D R S U I Y O A B C K V W G L P T X Q (`:266-302`) — `O` and `0` are different actions, `S` is a hidden alias for `3`, `L`/`G` double as footer hints | mnemonic keys, no O/0 or I/l/1 collisions, old keys as aliases |
| Initial cursor | item 0 = "Set PS7 as default" (`:145`) — one Enter changes WT profile, host, shim, context menu and VSCode | state-driven cursor + preview |
| Preview/confirm | none: `Set-PowerShell7Default`, `Set-PowerShell5Default`, `Invoke-PowerShellUpdate`, `Invoke-PowerShellInstall` run directly from the menu (`:305-330`) | preview screen, destructive actions default to cancel |
| Status area | three badge rows (WT/host/shim/source) built ad hoc (`:184-219`) | shared state source with GUI |
| Terminal repair | cursor hidden at start (`:148`), shown only after the loop exits normally (`:620`); no `try/finally`, no colour reset | `try/finally`, always restore |
| Size handling | none: no `WindowWidth/WindowHeight` checks, no scrolling, no "window too small" state | responsive + `▲▼` scroll indicator |
| Search | none | `/` diacritic-insensitive search |
| Help | footer hint string only (`nav_help`) | `?` help screen |
| Colour | ANSI via `Format-ColorText`, no `NO_COLOR` check, 16-colour palette via `$Script:THEME` | `NO_COLOR`/`--no-color` honoured |
| Plain mode | none | `PSMGR_PLAIN=1` / `--plain` |
| Language | switches live through `Set-PSManagerConfig -Language` then redraws (`:592-595`) | same, with layout re-flow test |

Consequences for the addendum's TUI acceptance criteria: AC-T1, T2, T3, T4, T5, T6, T7, T8, T9, T10,
T11 are all currently **not met**. AC-T4 cannot even be measured — the 74-column box has no responsive
behaviour and no snapshot baseline.

### CLI (`ps-manager.ps1`, 380 lines)

| Aspect | Current behaviour | Addendum expectation |
|---|---|---|
| Invocation | one parameter set: `-Action <ValidateSet 31 values>` + `-Value/-Url/-Manifest/-DryRun/-SkipPackages/-Fix/-AutoResolve/-NoColor/-Force` (`ps-manager.ps1:10-30`); default `-Action tui` | `psmgr <verb> [<object>]` tree, old form kept as alias with a deprecation line |
| Help | `-Action help`, `--help`, `-h` values inside the same `switch` | `psmgr --help`, `psmgr <cmd> --help` with examples and exit codes; `--version` |
| Machine output | human text; `status` uses `Format-List` (`:80`) | `--json` for `status`, `backup list`, `doctor`, `update --check`, `source show` |
| Stream separation | `Write-Host` for both results and progress; `Write-Error` in a few paths | stdout = data, stderr = progress/warnings/errors |
| Exit codes | 0 success, 1 failure (13 `exit 1` sites); `doctor` returns 1 when issues remain (`:182`) | 0/1/2/3/4 taxonomy |
| Dry run | `-DryRun` exists and is honoured by sync/provisioning paths | `--dry-run` on every side-effecting command, plus `-WhatIf`/`-Confirm` |
| Non-interactive safety | `clean-backups` requires typed `DELETE` and `Read-Host` even when stdin is redirected (`:249`); other destructive paths call `Read-Host` for passphrases | never prompt without a TTY; exit 2 with a clear message instead |
| Colour | `-NoColor` / `Disable-PSManagerColor`; ANSI is emitted regardless of `NO_COLOR` | `NO_COLOR` env var, no ANSI when redirected |
| Completion | none | `Register-ArgumentCompleter` for commands, `--source`, `--channel`, backup ids |
| Deprecation | none | one stderr line per legacy command |
| Back-compat risk | `-Action status | Format-List` output is documented in `README.md` and used by scripts; changing the default format would break them | keep default format, add `--json` as the new contract |

Consequences: AC-C1..C10 are currently **not met**, except the partially-satisfied `-NoColor`
(switches) and `-DryRun` (sync only).

## 6. Open questions for GATE 1b

1. The addendum proposes `psmgr default set pwsh7` while today every verb is `-Action <name>`. Do we
   implement the verb tree as a **new positional parameter set** in `ps-manager.ps1` (keeping
   `-Action` as the alias path), or add a separate dispatcher script?
2. `status` currently prints `Format-List`; `README.md` shows that output. Confirm "keep default
   output, add `--json`" (H12 reading) is the intended compatibility contract.
3. TUI width: the addendum's 2-pane layout needs ≥110 columns; below 80x24 it must print a "resize"
   notice. Confirm 80x24 keeps a scrollable single-pane view rather than only the notice.
4. `Cancel` has no TUI/CLI equivalent today (GUI-only `BtnCancelAction`); should C9's shared runner
   expose cancellation to TUI, or stay GUI-only for this round?
