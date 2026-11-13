# GUI Keyboard Accessibility Specification (`SPEC-GUI-KEYBOARD.md`)

## 1. Overview & Problem Statement

The desktop WPF application (`gui.ps1` with `ui/PSManager.MainWindow.xaml` and `ui/PSManager.Theme.xaml`) historically required a mouse for reliable operation. Radio-based navigation rail items and segmented selectors received focus and focus rings, but ignored standard keyboard interaction (`Enter` and arrow keys produced unhandled events, while `Space` acted only on `KeyUp`). Furthermore, window-level shortcuts, intentional initial focus, focus persistence across asynchronous busy cycles, and focus rings on certain interactive elements were absent.

This specification establishes full keyboard operability for the desktop GUI interface without introducing layout redesigns, new CLI/TUI capabilities, or new localization strings.

---

## 2. Issues Observed on Legacy Main

| # | Defect | Root Cause / Evidence | Impact |
|---|---|---|---|
| 1 | Navigation rail ignores `Enter` and arrow keys | Rail items are `RadioButton`s wired via `Add_Checked` only; `ButtonBase` does not route arrow keys or `Enter`. | Keyboard users cannot activate or switch pages with standard radio group keys. |
| 2 | Segmented selectors ignore `Enter` and arrows | Source/channel selectors use `Add_Click` on `RadioButton`s; arrows/Enter are inert. | Update source and release channel cannot be toggled via keyboard. |
| 3 | Missing page shortcuts and focus handoff | No window-level key handlers existed; `Show-GuiPage` toggled visibility only. | Lack of quick navigation (`Ctrl+1..5`, `Ctrl+Tab`, `F6`); focus could remain on hidden page elements. |
| 4 | Unintentional initial focus | Main window lacked an `Add_Loaded` focus director. | Keyboard users tabbed through header elements before reaching primary navigation. |
| 5 | Focus loss during long operations | `Set-BusyState` disabled interactive controls without saving and restoring focus. | Keyboard position was lost after operations completed. |
| 6 | Missing focus rings on inputs, log, splitter, dialogs | Missing `FocusVisualStyle` on `TextBox` (`Input` style), `RichTextBox` (`RtbConsoleLog`), `GridSplitter`, and dialog controls. | Keyboard focus was invisible on dark theme backgrounds. |
| 7 | Delete-backups dialog lacked initial focus and styling | Dialog lacked `Add_Loaded` focus on list and merged theme dictionary. | Inconsistent keyboard entry and invisible focus outline. |

---

## 3. Functional Requirements (`FR-KB-1..8`)

- **FR-KB-1 (Rail Navigation)**: Page rail items must be reachable via `Tab`/`Shift+Tab`; `Enter` and `Space` must activate the focused item; arrow keys (`Up`/`Left`, `Down`/`Right`) and `Home`/`End` must navigate with wrapping and switch visible pages.
- **FR-KB-2 (Segmented Selectors)**: Update source and channel segmented selectors must support arrow navigation, `Home`/`End`, and `Enter`/`Space` activation, persisting config changes exactly once.
- **FR-KB-3 (Initial Focus & Handoff)**: Window opening must place initial focus on the active navigation rail item; page shortcuts must direct focus to the corresponding rail element.
- **FR-KB-4 (Global Shortcuts)**: Window-level keyboard shortcuts must be available anywhere in the window: `Ctrl+1` through `Ctrl+5` (and Numpad equivalents) for direct page selection, `Ctrl+Tab` / `Ctrl+Shift+Tab` for sequential page cycling, and `F6` to focus the active rail item.
- **FR-KB-5 (Focus Visibility)**: Every button, input box, log viewport, and grid splitter must be focusable (`Focusable=True`, `IsTabStop=True`) and display a high-contrast focus ring (`FocusVisualStyle`).
- **FR-KB-6 (Focus Lifecycle)**: Long-running asynchronous operations must save focus before disabling controls and restore focus upon completion if not deliberately moved by the user.
- **FR-KB-7 (Dialog Operability)**: Modal dialogs (passphrase prompt and backup deletion) must merge the theme dictionary, set initial focus on their primary input element, handle `Esc` for cancel, and safely bind `Enter` for default submission.
- **FR-KB-8 (Quality Gates & Cross-Runtime Parity)**: All keyboard interaction must execute identically on Windows PowerShell 5.1 and PowerShell 7.4+, passing static analysis with zero warnings and full regression suite verification.

---

## 4. Keyboard Navigation Map

| Context | Keys | Expected Behavior |
|---|---|---|
| Navigation Rail | `Enter`, `Space` | Selects focused rail item; displays the corresponding page view. |
| Navigation Rail | `Down`, `Right` | Moves focus and selection to the next page item (wraps from last to first). |
| Navigation Rail | `Up`, `Left` | Moves focus and selection to the previous page item (wraps from first to last). |
| Navigation Rail | `Home`, `End` | Moves focus and selection to the first (`Overview`) or last (`Profiles`) page. |
| Segmented Selectors | Arrow keys, `Home`, `End`, `Enter` | Moves selection across source (`Winget`, `Store`, `GitHub`) or channel (`Stable`, `Preview`, `LTS`), immediately updating configuration. |
| Window (Global) | `Ctrl+1` / `Ctrl+NumPad1` | Switches to Overview page and focuses its rail item. |
| Window (Global) | `Ctrl+2` / `Ctrl+NumPad2` | Switches to Update page and focuses its rail item. |
| Window (Global) | `Ctrl+3` / `Ctrl+NumPad3` | Switches to Backup page and focuses its rail item. |
| Window (Global) | `Ctrl+4` / `Ctrl+NumPad4` | Switches to Health page and focuses its rail item. |
| Window (Global) | `Ctrl+5` / `Ctrl+NumPad5` | Switches to Profiles page and focuses its rail item. |
| Window (Global) | `Ctrl+Tab` / `Ctrl+Shift+Tab` | Cycles to next / previous page with wrapping and moves focus to the rail item. |
| Window (Global) | `F6` | Focuses the currently checked navigation rail item. |
| Standard Controls | `Tab` / `Shift+Tab` | Advances / reverses logical focus along the established tab order. |
| Standard Controls | `Enter`, `Space` | Activates standard buttons and toggles. |
| Modal Dialogs | `Esc` | Cancels dialog and returns focus to the parent window. |
| Modal Dialogs | `Enter` | Confirms default action where defined (`BtnOK` in passphrase dialog). |

---

## 5. Acceptance Criteria Mapping

| Requirement | Acceptance Criterion | Verification Method |
|---|---|---|
| FR-KB-1 | **AC-K1**: Every rail item is reachable via `Tab`; `Enter`/`Space` activates; arrows and `Home`/`End` move selection with wrap and switch page visibility. | `tests/test_gui_keyboard.ps1` (Checks 1, 2, 3) |
| FR-KB-2 | **AC-K2**: Source and channel segmented selectors support arrow navigation and persist config through existing handlers. | `tests/test_gui_keyboard.ps1` (Check 4) + manual smoke |
| FR-KB-3 | **AC-K3**: Window opens with focus on the active rail item; page shortcuts move focus to the rail. | `tests/test_gui_keyboard.ps1` (Check 3) |
| FR-KB-4 | **AC-K4**: `Ctrl+1..5`, `Ctrl+Tab`, `Ctrl+Shift+Tab`, and `F6` route correctly. | `tests/test_gui_keyboard.ps1` (Checks 3, 5) |
| FR-KB-5 | **AC-K5**: All interactive controls are focusable tab stops and present a visible `FocusVisualStyle`. | `tests/test_gui_keyboard.ps1` (Check 6) |
| FR-KB-6 | **AC-K6**: Focus is captured when busy state begins and restored upon completion unless deliberately moved. | `gui.ps1` (`Set-BusyState`) code audit and async test suite |
| FR-KB-7 | **AC-K7**: Dialogs have merged theme styles, visible focus rings, proper initial focus, and standard escape/enter semantics. | `gui.ps1` dialog implementation audit |
| FR-KB-8 | **AC-K8**: Cross-runtime validation harness passes on PS 5.1 and PS 7+, PSScriptAnalyzer emits zero warnings, and documentation is synchronized. | `tests/Run-Tests.ps1`, PSScriptAnalyzer, documentation review |

---

## 6. Architecture & Implementation Components

1. **`ui/GuiKeyboard.ps1`**:
   - `Add-GuiRadioGroupKeyboard`: Attaches single key listener per panel; manages focus and checked state transitions with wrap-around.
   - `Get-GuiPageShortcut`: Pure function resolving `Key` and `ModifierKeys` to page identifiers.
   - `Get-GuiPageStep`: Pure function resolving sequential page step (+1, -1, 0) for `Ctrl+Tab` navigation.

2. **`ui/GuiNavigation.ps1`**:
   - `Show-GuiPage`: Toggles visibility across registered pages with contract guards.
   - `Initialize-GuiNavigation`: Orchestrates page registration, nav rail events, radio group keyboard handlers, initial window focus, and top-level preview key handling.

3. **`gui.ps1` & XAML Integration**:
   - Dot-sources keyboard and navigation modules.
   - Binds segmented selectors using `Add_Checked` to support keyboard and programmatic updates.
   - Enhances `Set-BusyState` with focus save/restore lifecycle.
   - Inlines `FocusVisualStyle` into `Input` style (`PSManager.Theme.xaml`) and controls (`PSManager.MainWindow.xaml`).
