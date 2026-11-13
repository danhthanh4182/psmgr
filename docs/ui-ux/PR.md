# PR — UI/UX: GUI design tokens, navigation shell, colour-coded log; TUI render engine, groups and keys

Adds a state-driven, low-ambiguity GUI without dropping or re-pointing a single action, and rebuilds
the TUI on the same information architecture. The window markup moves from a 510-line here-string in
`gui.ps1` into `ui/` (loaded by `ui/GuiLoader.ps1`, styled by `ui/PSManager.Theme.xaml`); the
two-column button wall becomes a five-page navigation shell with one primary action per page; the
plain log becomes a filterable, colour-coded, clickable activity log. The TUI gains a pure
capability-aware renderer, a five-group catalog with mnemonic keys (every legacy key preserved),
diacritic-insensitive search, preview/confirm/result screens, plain mode and an always-restored
terminal. No new runtime dependency; PS 5.1 and PS 7 both stay green.

## Tickets

| Ticket | Scope | Commit |
|---|---|---|
| T0 | Off-screen capture tool + before screenshots | `12583a8` |
| T1 | Theme dictionary (`ui/PSManager.Theme.xaml`) + loader (`ui/GuiLoader.ps1`) | `5489b1c` |
| T2 | Window XAML extraction + i18n keys/sentence-case labels | `2c4b832` |
| T3 | `gui.ps1` cutover, page navigation, RichTextBox log + filter + links, dark title bar, i18n path fix, parity-test support | `4e5f145` |
| T4 | XAML/theme/page/log contract tests, harness + packaging, after screenshots | `d442a09` |
| — | Docs, spec, tickets, action map, this PR body | current commit |

## Changed files

```
 .github/workflows/dist.yml                   |   2 +-
 CHANGELOG.md                                 |  10 +
 gui.ps1                                      | 818 ++++++++-------------------
 i18n.json                                    | 120 ++--
 modules/Core/I18n.ps1                        |   4 +-
 tests/harness.ps1                            |   7 +
 tests/test_gui_xaml.ps1                      | 252 +++++++++
 tests/test_interface_parity.ps1              |   8 +
 tools/Capture-PSManagerGui.ps1               | 275 +++++++++
 ui/GuiLoader.ps1                             |  77 +++
 ui/PSManager.MainWindow.xaml                 | 489 ++++++++++++++++
 ui/PSManager.Theme.xaml                      | 281 +++++++++
 docs/ui-ux/**                                | evidence, spec, tickets, action map
```

`gui.ps1` shrinks by ~560 net lines (markup moved to XAML); handlers, element names and CLI/TUI
paths are untouched.

## Acceptance matrix (GUI Track A)

| AC | Criterion | Status | Evidence |
|---|---|---|---|
| AC1 | Window XAML lives in `ui/PSManager.MainWindow.xaml`, loaded via `ui/GuiLoader.ps1`; `gui.ps1` has no window markup | Đạt | `ui/PSManager.MainWindow.xaml`, `gui.ps1:39-47`, `test_gui_xaml.ps1` → "Both XAML resources exist" / "Loader builds a Window…" |
| AC2 | All colours/fonts/styles come from the theme; window uses `DynamicResource` only (icons may use `StaticResource`) | Đạt | `test_gui_xaml.ps1` → "Window XAML only uses StaticResource for icon geometries", "Theme tokens and styles resolve from the merged dictionary" |
| AC3 | Exactly one primary (accent) action per page | Đạt | `test_gui_xaml.ps1` → "Each page declares exactly one primary action"; `docs/ui-ux/shots/after/1280x800.png` |
| AC4 | Five nav items; selecting one shows its page, hides the others | Đạt | `ui/GuiNavigation.ps1` `Show-GuiPage`, `Initialize-GuiNavigation`; `docs/ui-ux/shots/after/gui-live-{overview,update,backup,health,profile}.png` (rail selection and page content verified per shot) |
| AC5 | Content centred and ≤ 1200 px at 1280/1920/2560 | Đạt | `docs/ui-ux/shots/after/{1280x800,1920x1080,2560x1440}.png` |
| AC6 | Log colour-codes severity, dim timestamps, 500-entry cap | Đạt | `test_gui_xaml.ps1` → "Log entries render level colours…"; `docs/ui-ux/shots/after/1280x800.png` |
| AC7 | `http(s)://` and `file://` URLs are underlined and open externally | Đạt | `test_gui_xaml.ps1` → "Log entries render level colours and clickable hyperlinks" (asserts `NavigateUri` + `RequestNavigate` wiring) |
| AC8 | Filter narrows live, placeholder when empty, clearing restores all | Đạt | `test_gui_xaml.ps1` → "Log filter narrows entries and clearing restores them"; `docs/ui-ux/shots/after/gui-live-filter.png` |
| AC9 | Full keyboard accessibility: activation, arrows, shortcuts, focus rings | Đạt | `tests/test_gui_keyboard.ps1` (6 checks, dual-runtime PS5/PS7); global shortcuts `Ctrl+1..5`, `Ctrl+Tab`, `Ctrl+Shift+Tab`, `F6`; `FocusRing` in `ui/PSManager.Theme.xaml` and `ui/PSManager.MainWindow.xaml` |
| AC10 | Dark title bar via `DwmSetWindowAttribute` (20, fallback 19), silent degradation | Đạt | `docs/ui-ux/shots/after/gui-live.png` (live window, dark caption); `gui.ps1` SourceInitialized handler wrapped in try/catch |
| AC11 | Sentence-case labels in en/vi/vi-ascii; body ≥ 12 px; contrast ≥ 4.5:1 | Đạt | `i18n.json`; contrast 7.65:1 (dim on panel) and 16.33:1 (body on bg) computed in `docs/ui-ux/omp/discovery.md` §2 |
| AC12 | No action lost or re-pointed; every new string in all three languages | Đạt | `docs/ui-ux/omp/actions.md` (27 controls), `docs/ui-ux/action-map.md`; `test_interface_parity.ps1` → "all 23 capabilities synchronized"; `i18n.json` key counts 279/279/279 |

## Verification (commands actually run)

- `powershell -NoProfile -File tests/Run-Tests.ps1` → **all suites pass** on Windows PowerShell 5.1, then the same harness under `pwsh` 7 → all pass (94+ tests, incl. the TUI suites).
- `pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Settings PSScriptAnalyzerSettings.psd1 -Recurse"` → no findings.
- `tests/test_interface_parity.ps1` → `✅ [PASS] Tri-Interface Parity Contract verified: all 23 capabilities synchronized` (TUI ids read from `TuiCatalog.ps1`).
- Screenshots: `tools/Capture-PSManagerGui.ps1` (off-screen) and live captures of a real launched process (`gui-live-*.png`).
- TUI smoke: launched `ps-manager.ps1 -Action tui` in a PTY (120 cols): two-pane frame, status band, grouped list, action result screen, clean exit with terminal restored.
- Side-effect safety: no default switch, package install/update, profile write, backup/restore/cloud or `doctor -Fix` was executed; the one action run by the TUI smoke was the quick-launch `PS7` (opens a terminal only).

## Track C — TUI delivered (addendum), CLI pending (pi)

| Ticket | Status | Evidence |
|---|---|---|
| C5 render engine + capabilities | done | `modules/UI/TuiRender.ps1`, `TuiCapabilities.ps1`; 16 golden snapshots (`tests/snapshots/tui`), dimension and behavior tests in `tests/test_tui_render.ps1` |
| C6 layout, status band, responsive, scroll | done | two-pane ≥110 cols (checked at 110/111), single-pane below, 80x24 notice; golden snapshots and dimension tests |
| C7 groups, new keys + legacy aliases, `/` search, `?` help | done | `TuiCatalog.ps1`, `TuiState.ps1`; `tests/test_tui_state.ps1` covers every legacy key and mnemonic |
| C8 preview, confirm, result screens | done with interim runner | `TuiState.ps1` modes + `TuiEngine.ps1` result flow; modal-frame checks in `test_tui_render.ps1` |
| C10 plain mode + non-TTY guard | done | `Show-TuiPlain`, `tests/test_tui_engine.ps1` |
| C0/C1 general modules | interim in TUI scope | `TuiCatalog.ps1` / `TuiCapabilities.ps1` expose the contracts C0/C1 can absorb |
| C2–C4 CLI, C9 shared runner | not started | `pi`; see `docs/ui-ux/tickets.md` |

All TUI copy is in `i18n.json` (100 `tui_*` keys × en/vi/vi-ascii, 279 keys per mode); the four TUI
sources are ASCII-only, enforced by a test. Spec: `docs/ui-ux/spec.md` §2–§4b. Inventory and open CLI
questions: `docs/ui-ux/omp/discovery.md` §5–§6.

### Track C — TUI layout and language addendum

- Action titles are never truncated: each row wraps onto continuation lines, with one key badge per
  action and an indented continuation. The detail pane wraps the title and description too.
- Visual language follows Terminal.Gui conventions: group headers carry an icon and a per-section
  colour, the active row is a full-width inverse-video accent bar, undoable actions show `↺`,
  destructive actions show `!` in red, and an overflowing list gets a proportional scrollbar.
- `Write-TuiFrame` positions every row with an explicit cursor address plus erase-to-end-of-line.
  A full-width frame written with newlines smears the previous frame down the screen (duplicated
  rows, stale detail lines); a test pins the no-newline contract.
- Language is an explicit three-mode setting (`en`, `vi`, `vi-ascii`) shared by CLI, TUI and GUI;
  every interface cycles `en` → `vi-ascii` → `vi` → `en` and persists it. The TUI header names the
  active mode, so `vi` and `vi-ascii` are never confused.

No tag, release, push to `main`, or real PR is created by this branch.
