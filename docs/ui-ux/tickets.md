# PSManager UI/UX — TICKETS

Two tracks, one branch (`feat/uiux-omp`). Status legend: `done`, `in review`, `gate`, `todo`,
`blocked`.

## Track A/B — Desktop GUI

| id | Owner | Scope | Depends | Status |
|---|---|---|---|---|
| T0 | omp | Off-screen capture tool + before screenshots | — | done |
| T1 | omp | Design-token theme (`ui/PSManager.Theme.xaml`) + loader (`ui/GuiLoader.ps1`) | T0 | done |
| T2 | omp | Window XAML extraction (`ui/PSManager.MainWindow.xaml`) + i18n keys/labels | T1 | done |
| T3 | omp | `gui.ps1` cutover, RichTextBox log, page navigation, filter, links, dark title bar, i18n path fix, parity-test support | T2 | done |
| T4 | omp | XAML/log contract tests, harness + dist packaging, after screenshots, docs, changelog | T3 | done |
| T5 | pi | Async action runner shared by GUI/TUI (event stream, cancel) | T4 | todo |
| T6 | pi | Replace the PS7/PS5 button pair with a single state switch (`Switch` style is ready and unused) | T5 | todo |
| T7 | pi | Backup list inside the Backup page (replaces the modal `ContextMenu`) | T5 | todo |
| T8 | pi | Merge the health page entries with the doctor result set | T5 | todo |
| T9 | pi | Keyboard shortcuts for the pages and primary actions | T6, T7, T8 | todo |
| T10 | pi | GUI reads `ActionRegistry` at runtime (backlog from the addendum) | T5 | todo |

## Track C — TUI / CLI (addendum)

| id | Owner | Scope | Depends | Status |
|---|---|---|---|---|
| C0 | pi | Inventory CLI/TUI; build the action registry (id, group, names, keys, admin/destructive/undoable flags, executor, CLI command) | — | todo — TUI ships an interim `TuiCatalog` (groups + flags + executor ids) that C0 can absorb |
| C1 | pi | Terminal capability module (TTY, Unicode, VT, `NO_COLOR`, size) + tests | — | todo — TUI ships an interim `TuiCapabilities` (same contract, `-Override` for tests) |
| C2 | pi | CLI command tree, parser, legacy aliases + deprecation warnings, help | C0, C1 | todo |
| C3 | pi | CLI output contract (stdout/stderr, `--json`, exit codes, `--dry-run`, `--yes`, error template) | C2 | todo |
| C4 | pi | CLI `status` + completer | C2 | todo |
| C5 | omp | TUI `New-TuiFrame` (pure) + `Write-TuiFrame` diff + alternate screen + terminal restore + ASCII fallback + frame tests | C1 | done (`TuiRender.ps1`, `TuiCapabilities.ps1`, 16 golden snapshots, dimension and behavior tests, restore test) |
| C6 | omp | TUI two-pane layout, status band, responsive breakpoints, scroll indicators | C0, C5 | done (`TuiRender.ps1`: ≥110 columns two-pane, single-pane below, 80x24 notice, `▲▼` indicators) |
| C7 | omp | TUI grouped navigation, new keys + legacy aliases, diacritic-insensitive search, `?` help | C6 | done (`TuiCatalog.ps1` + `TuiState.ps1`; every legacy key covered by test) |
| C8 | omp | TUI preview/confirm screens, progress/result screens, destructive-action flow | C6, C9 | done with an interim in-engine runner (preview modal, typed-`y` confirm, persistent result screen); C9 replaces the runner when it lands |
| C9 | pi | Shared step-event runner (same contract as T5) for GUI/TUI/CLI | C0, T5 | todo |
| C10 | omp | TUI plain/accessibility mode | C5 | done (`PSMGR_PLAIN=1`, no ANSI/alt-screen, numbered list; non-TTY prints help) |
| C11 | both | Docs: README, `docs/cli.md`, help text, TUI screenshots, CHANGELOG, ADRs | all | in progress — CHANGELOG + tickets/spec/action-map updated; CLI docs wait for C2–C4 |

Gate status: Track A is complete and reviewed-ready. Track C TUI tickets (C5, C6, C7, C8, C10) are
implemented on `feat/uiux-omp` and verified by `tests/test_tui_render.ps1`,
`tests/test_tui_state.ps1`, `tests/test_tui_engine.ps1`, plus a PTY smoke run. C0/C1 remain `pi`'s
general modules; the interim TUI-scoped equivalents are documented above and are drop-in replaceable.
CLI tickets C2–C4 and the shared runner C9 are untouched and still need `pi`.
