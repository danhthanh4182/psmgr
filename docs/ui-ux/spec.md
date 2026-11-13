# PSManager UI/UX — SPEC

Two scopes share this document:

- **Track A/B — Desktop GUI** (main prompt): `omp` owns Track A (theme, XAML split, navigation
  shell, log, title bar); `pi` owns Track B (async runner, shell-default switch, backup list,
  health merge, shortcuts).
- **Track C — TUI/CLI** (addendum): `pi` owns registry + CLI (C0–C4, C9), `omp` owns the TUI
  (C5–C8, C10); C11 is joint.

Hard constraints (H1–H14) are binding for every ticket: no real side-effecting operation in tests,
no new runtime dependency, every capability present in each interface that already had it, old CLI
commands/TUI keys keep working as aliases, terminal state always restored, `i18n.json` carries every
new string in `en`/`vi`/`vi-ascii`.

Naming: one capability = one name in GUI, TUI and CLI. The authoritative mapping is
`docs/ui-ux/action-map.md` (AC-X1); new names are taken from `modules/Core/ActionRegistry.ps1`
`TitleKey` so all three interfaces can adopt them without another rename pass.

---

## 1. Acceptance criteria — GUI (Track A)

| id | Criterion |
|---|---|
| AC1 | The window's XAML lives in `ui/PSManager.MainWindow.xaml` and is loaded through `ui/GuiLoader.ps1`; `gui.ps1` contains no window markup. |
| AC2 | All colours, fonts and control styles come from `ui/PSManager.Theme.xaml`; the window XAML uses `DynamicResource` only (`StaticResource` is limited to icon geometries). |
| AC3 | Each of the five pages has exactly one primary (accent) action. |
| AC4 | Five navigation items (Overview, Update, Backup, Health, Profiles); selecting one shows its page and hides the others. |
| AC5 | Page and log content are centred and never exceed 1200 px, at 1280/1920/2560 px window widths. |
| AC6 | The activity log colour-codes entries by severity, shows dim timestamps, and caps history at 500 entries. |
| AC7 | `http(s)://` and `file://` URLs in the log render as underlined links that open in the default handler. |
| AC8 | The log filter narrows entries live, shows a placeholder when empty, and clearing restores every entry. |
| AC9 | Full keyboard accessibility: every button, segment, rail item, text input, log and splitter is focusable with a high-contrast focus ring; rail and segments support `Enter`/`Space` activation, arrow navigation (`↑/↓/←/→`, `Home`/`End`) with wrap; global shortcuts `Ctrl+1..5`, `Ctrl+Tab`, `Ctrl+Shift+Tab`, and `F6` route to page navigation; focus lifecycle is preserved across busy actions; dialogs support `Esc` cancel and `Enter` default. |
| AC10 | The window frame is dark via `DwmSetWindowAttribute` (20, fallback 19) and degrades silently when unavailable. |
| AC11 | Section labels are sentence case in all three languages; body text is ≥ 12 px; text contrast is ≥ 4.5:1 against its background. |
| AC12 | No action is lost or re-pointed: all 23 registry capabilities still call their original handler, and every new string exists in `en`, `vi`, `vi-ascii`. |

## 2. Acceptance criteria — TUI (Track C, addendum Appendix J)

| id | Criterion |
|---|---|
| AC-T1 | Status band with four values (default shell, terminal, shim, source:channel) from the same data source as the GUI. |
| AC-T2 | Actions grouped in five groups matching the GUI; group headers are not selectable; no action is lost. |
| AC-T3 | Initial cursor follows state; "Set PS7 as default" always shows a preview; destructive actions default to cancel, require `y`, and are red with `!`. |
| AC-T4 | Snapshots at 80x24, 100x30, 120x40 and 200x50 (vi/en × Unicode/ASCII): no line overflow, no broken box, every item reachable; below 80x24 a clear notice instead of a broken frame. |
| AC-T5 | Moving the cursor does not repaint the whole screen; no `Clear-Host` inside the key loop. |
| AC-T6 | `q`, Ctrl+C and a simulated exception all restore cursor, main screen and colours (tested). |
| AC-T7 | `/` search is diacritic-insensitive ("dat" matches "Đặt", "sao luu" matches "Sao lưu"). |
| AC-T8 | Result screens persist, include a summary and duration; progress uses a spinner and does not flood the log. |
| AC-T9 | Every legacy key still triggers its old action; new keys avoid O/0 and I/l/1 collisions and are unique. |
| AC-T10 | Full fallback: ASCII without Unicode support, no colour with `NO_COLOR`, plain mode, and no TUI when there is no TTY. |
| AC-T11 | Switching language updates the TUI immediately without breaking layout. |

## 3. Acceptance criteria — CLI (Track C, addendum Appendix J)

| id | Criterion |
|---|---|
| AC-C1 | `psmgr --help` and `<command> --help` list groups, examples and exit codes; `--version` exists. |
| AC-C2 | stdout carries data, stderr carries progress/warnings/errors; `--json` output parses with `ConvertFrom-Json` for the documented commands. |
| AC-C3 | Exit codes follow the table 0/1/2/3/4 (tested per code). |
| AC-C4 | No prompt without a TTY; a destructive action missing `--yes` fails with a clear message and exit code 2. |
| AC-C5 | `--dry-run` on every side-effecting command and it changes nothing (temp-directory test). |
| AC-C6 | `NO_COLOR` and `--no-color` honoured; no ANSI when stdout is redirected. |
| AC-C7 | Legacy commands still work and print one deprecation line to stderr. |
| AC-C8 | Error messages follow "what happened / why / how to fix". |
| AC-C9 | Completers registered for commands, `--source`, `--channel` and backup ids. |
| AC-C10 | Bare `psmgr`: TTY → TUI; no TTY → help and exit. |

## 4. Cross-cutting

| id | Criterion |
|---|---|
| AC-X1 | `docs/ui-ux/action-map.md` has GUI/TUI/CLI columns and the names match across interfaces. |
| AC-X2 | Tests and PSScriptAnalyzer are green and Phase 5 reports the commands and their output. |


## 4b. Track C implementation notes (TUI, as built)

- The TUI is split into four omp-owned modules: `TuiCapabilities.ps1` (interim C1 contract),
  `TuiCatalog.ps1` (interim C0 data: groups, keys, flags, executor ids), `TuiRender.ps1`
  (pure frames + diff writer) and `TuiState.ps1` (pure key reducer). `TuiEngine.ps1` only does
  terminal I/O. Both interim modules expose the exact contract C1/C0 need, so replacing them is a
  module swap, not a rewrite.
- Actions run on the **normal** screen (their output stays in scrollback) and the session returns to
  the alternate screen with a persistent result screen; this is the interim C8 runner until C9 lands.
- `PSMGR_PLAIN=1` switches to a numbered, ANSI-free, no-repaint list. A non-TTY invocation prints help
  and never enters a loop.
- VT is probed independently of colour: host flag, Windows Terminal/`TERM`, else the console mode
  bit. Sessions without VT use the plain list, so legacy conhost never sees raw escape sequences.
- All TUI copy lives in `i18n.json` (`tui_*` keys, 100 per language); the four TUI sources are
  ASCII-only and a test enforces both rules.

## 5. Non-goals for this round

- The GUI keeps its own handler wiring; reading `ActionRegistry` at runtime is backlog (T10), so the
  registry stays the naming/parity source, not the GUI's execution source.
- No new runtime module or dependency for TUI (no Spectre.Console/Terminal.Gui) and none for GUI.
- Track B features (switch, backup list, merged health, shortcuts, async runner) are out of Track A
  scope; the controls they will replace stay functional and restyled.
