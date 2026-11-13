# Changelog

All notable changes to **PSManager** (`psmgr`) are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.8.0] - 2026-11-14

### Added
- **Configurable cloud backup repo across all interfaces (`Set-PSManagerCloudRepo`, `ps-manager.ps1`, `modules/UI/*`, `gui.ps1`, `modules/Core/ActionRegistry.ps1`)**: `psmgr set-cloud-repo owner/repo`, the TUI `[j]` action and the GUI **Backup → Set Backup Repo** button all persist `cloudRepo` through one validated wrapper. An empty value clears it. `$env:PSMGR_CLOUD_REPO` now takes precedence over `config.json`, the git remote and `gh`, so a machine can override the target without editing the tracked `config.json`.
- **Optional per-run GitHub token (`Publish-PSManagerCloudBackup -Token`, GUI/TUI field, `PSMGR_CLOUD_TOKEN`)**: a user who does not want the global `gh` login can supply a token for one backup; it is applied through `$env:GH_TOKEN` for that call only, never stored, and the previous value is restored. Precedence: field/`-Token` → `PSMGR_CLOUD_TOKEN` → `GH_TOKEN` → `GITHUB_TOKEN` → `gh auth login`. The data repo must also be **private** and writable — `Test-PSManagerCloudWriteAccess` checks both and refuses public targets.
- **Two-repository separation (`docs/PUBLISHING.md`, `README.md`, `CONTEXT.md`)**: the deploy repository (code + app releases) and the user's data repository (profile backups) are distinct by design. Auto-resolution never selects the deploy repo, the target guard refuses it unconditionally, and the docs state the split explicitly.

### Security & Compliance
- **Installer refuses unverified downloads (`install.ps1`)**: a release without `SHA256SUMS.txt` previously produced a warning and installed anyway, contradicting the documented "no unsigned install path". It now aborts before running the installer.
- **`GH_TOKEN` honoured by update checks and the installer (`UpdateNotifier.ps1`, `install.ps1`)**: both resolvers skipped gh's native `GH_TOKEN` variable, so a machine authenticated only through it fell back to an anonymous request (and failed on the private repo). Precedence now matches gh: `-Token`/`PSMGR_GITHUB_TOKEN` → `GH_TOKEN` → `GITHUB_TOKEN` → `gh auth token`.
- **Profile backups can no longer target the app repo (`modules/Sync/Backup.ps1`)**: the deploy repo (code + app releases) and a user's data repo (profile backups) are strictly separate. `Get-DefaultBackupRepo` skips `danhthanh4182/psmgr` in both implicit fallbacks (clone origin, `gh` default), so cloning the public project never aims a user's personal archive at the maintainer's repo. `Publish-PSManagerCloudBackup` normalizes every target to a GitHub `owner/repo` slug (`git@`, https, host-qualified spellings included) and refuses the deploy repo **unconditionally, even while it is private**; foreign hosts and malformed references are rejected as well. Failed uploads explain `gh auth login` and fine-grained per-repo `GH_TOKEN` scoping.
- **GitHub Policy Compliance (`build/PSManager.Builder.psm1`, `modules/Sync/Provisioner.ps1`, `tests/harness.ps1`)**:
  - Removed stealth `-WindowStyle Hidden` execution flags from builder generation.
  - Replaced `Invoke-Expression` with safe temporary script file execution in Scoop provisioner.
  - Eliminated hardcoded developer user directory in `tests/harness.ps1`.
  - Added repository `SECURITY.md` and `PRIVACY.md` compliance documentation.

## [1.7.3] - 2026-11-01

### Fixed
- **Taskbar identity (`gui.ps1`, `build/PSManager.Builder.psm1`)**: the process-level AUMID is ignored while the WPF window is hosted by `pwsh.exe`, so the window now also sets `PKEY_AppUserModel_ID` on its HWND through `SHGetPropertyStoreForWindow`. The installer gives the desktop shortcuts `AppUserModelID: "PSManager.Desktop"` and the TUI shortcut `"PSManager.TUI"`; the taskbar now shows a separate **PSManager** button with the PSManager icon instead of grouping under PowerShell. Verified with the taskbar UIA tree and a 32 px icon probe.
- **Analyzer gate could pass silently (`tests/Run-Tests.ps1`)**: when both `Invoke-ScriptAnalyzer` attempts threw, `$results` stayed null, `$issues` stayed empty and the gate printed PASS. Analyzer crashes are now collected and fail the suite.

## [1.7.2] - 2026-10-31

### Fixed
- **Taskbar icon quality (`gui.ps1`)**: the window icon is decoded through `BitmapDecoder` and the smallest frame >= 32 px is used, because `BitmapFrame::Create` always returns the 16 px frame and the shell draws the taskbar thumbnail from a 32 px image.
- **Documented limitation**: `SetCurrentProcessExplicitAppUserModelID("PSManager")` is set before the window is created, but Windows 11 still groups the window under the hosting `pwsh.exe` taskbar button, so the button keeps the PowerShell icon. The window's own icon (title bar, Alt+Tab thumbnail) is the PSManager icon.

## [1.7.1] - 2026-10-31

### Fixed
- **Single-window launcher execution and taskbar icon synchronization**:
  - `psmgr-gui.exe` sets `CreateNoWindow = true` and `WindowStyle = ProcessWindowStyle.Hidden` on `ProcessStartInfo` so Windows and Windows Terminal never allocate a lingering black console window alongside the desktop GUI.
  - `psmgr.exe` and `psmgr-gui.exe` forward command-line arguments using index iteration (`for (int i = 1; i < args.Length; i++)`) over `Environment.GetCommandLineArgs()`, avoiding argument validation failures caused by path separator discrepancies between argv[0] and assembly location.
  - `gui.ps1` calls `SetCurrentProcessExplicitAppUserModelID("PSManager")` so Windows Taskbar groups the window under `PSManager` and synchronizes with the Start Menu shortcut.
  - `gui.ps1` sets `$window.Icon` from `assets/psmgr.ico` (with fallback to the extracted launcher icon) so the window title bar and taskbar preview show the official application icon; the ICO is decoded through `BitmapDecoder` and the smallest frame >= 32 px is selected, because `BitmapFrame::Create` always returns the 16 px frame and the shell draws the taskbar button at 32 px.
  - Added `assets/` directory to the release builder and Inno Setup installer packaging payloads so `assets/psmgr.ico` is deployed to the installed location.

## [1.7.0] - 2026-10-31

### Added
- **PSManager release awareness and self-update** (`modules/Package/UpdateNotifier.ps1`): `psmgr update-check` reads `https://api.github.com/repos/danhthanh4182/psmgr/releases/latest`, caches the answer in `updates.json` for six hours, and never installs anything on its own. `psmgr update-app` downloads the published installer plus `SHA256SUMS.txt`, verifies the SHA-256 digest, and only then runs the Inno Setup package with `/SILENT /CURRENTUSER` (or `/ALLUSERS` for a machine-wide install). A missing digest or a mismatch deletes the download and aborts; there is no unsigned install path. Auth resolves `PSMGR_GITHUB_TOKEN`, `GITHUB_TOKEN`, then `gh auth token`, and a 401/404 explains how to authenticate against the (currently private) repository.
- **Persistent notification store** (`modules/Core/Notification.ps1`): `notifications.json` under `%LOCALAPPDATA%\PSManager` keeps the newest 50 items with i18n keys instead of rendered text, deduplicated by `update-<version>` so a re-check never raises a second row. `Add-PSManagerNotification`, `Get-PSManagerNotifications`, `Get-PSManagerNotificationView`, `Set-PSManagerNotificationRead`, `Clear-PSManagerNotifications` and `Show-PSManagerToast` are exported. Writes use a named mutex plus a temp-file rename, and every read/write failure degrades to a warning instead of breaking the caller.
- **Native Windows toasts** (`modules/Core/ToastHost.ps1`): PowerShell 7 cannot load the WinRT toast types, so `Show-PSManagerToast` writes a JSON payload and launches the Windows PowerShell 5.1 host with `-Sta`. Installer builds now stamp `AppUserModelID: "PSManager"` on the Start Menu and desktop shortcuts so the toast is attributed to the app; portable runs fall back to the in-app surfaces.
- **GUI notification center, badge and toast** (`ui/GuiNotifications.ps1`): a bell button with an unread badge opens a right-hand panel listing title, message and local time; rows with a URL are focusable buttons that open the release page. The panel marks everything read on open, `Clear all` empties the store, and a 6-second in-app toast (cancellable, DispatcherTimer-driven) reports action outcomes. The update check runs in a `Start-Job` and is polled by a 750 ms timer, so the window never freezes and startup only reads the cache.
- **Shared help catalog and Help page** (`modules/Core/Help.ps1`, `ui/GuiHelp.ps1`): one table drives `psmgr help`, `psmgr help <command>`, the TUI overlay and a sixth GUI page (`Ctrl+6` / the rail) with quick start, the full command reference, update status, shortcuts, project links and an About card. `psmgr help <unknown>` now exits 1 with a localized pointer to `psmgr help`.
- **TUI global keys** (`modules/UI/TuiState.ps1`, `modules/UI/TuiRender.ps1`, `modules/UI/TuiEngine.ps1`): `h` opens the help overlay, `!` opens a notification modal (`c` clear, `r` mark read, `o` open the selected URL), `v` runs a release check with a result screen, and `p` installs a verified release after confirmation. Legacy `V` (logs) and `P` (profile editor) are unchanged, the visible action count stays 21, the golden snapshots are byte-identical, and an unread badge prefixes the header legend only when notifications are pending.
- **Notification and update commands in the CLI** (`ps-manager.ps1`): `update-check`, `update-app [-Force]` and `notifications [-Value all|clear|read]` join the `ValidateSet`, and the action registry grows to 27 actions so the tri-interface parity gate covers them.
- **Bilingual landing page and gated Pages workflow** (`site/`, `.github/workflows/pages.yml`): a self-contained English/Vietnamese static site (install tabs with copy buttons, feature tour, screenshots, FAQ, JSON-LD, Open Graph, `robots.txt`, `sitemap.xml`, 404) with no external fonts, frameworks or analytics. The workflow always builds the artifact; the deploy job only runs when repository variable `PSMGR_PAGES_ENABLED` is `true`, so `main` stays green while the repository is private.
- **Localization**: 105 new keys in `en`, `vi` and `vi-ascii` (384 total each), including the help, update, notification and `tui_notif_*` strings, plus a refreshed `nav_help` legend.
- **MIT `LICENSE`**: the README badge, Help page link and site footer all point at it.
- **Installer shortcuts carry `AppUserModelID`**: the generated Inno Setup `[Icons]` entries now stamp `AppUserModelID: "PSManager"` on the Start Menu and desktop shortcuts, which is what lets a native toast be attributed to the app instead of appearing as an unnamed sender.
- **Publish checklist (`docs/PUBLISHING.md`)**: a public repo exposes the git history *and every release asset*. The checklist covers purging or migrating the `Profile Backup` releases (one archive is currently plaintext), moving the payload to its own private repo, pinning `cloudRepo` away from `danhthanh4182/psmgr`, avoiding `psmgr adopt` in the app repo, scanning history for tokens and machine paths, and the post-flip Pages/Actions steps.

### Fixed
- **Notification titles expand their parameters (`modules/Core/Notification.ps1`)**: action titles such as `{0} finished` and `{0} failed` were rendered literally in the notification center, CLI list and TUI modal because only the message body was formatted. Titles now go through the same `-f $params` step, and `tests/test_update_notifier.ps1` asserts the header and exit code of a stored action notification.
- **TUI install failures and plain-mode shortcuts (`modules/UI/TuiEngine.ps1`)**: the interactive `update-app` path now catches download and digest failures, printing `notif_update_failed` instead of letting the exception escape the alternate screen, and plain mode lists only the global entries that have a runnable action (`help`, `update-check`, `update-app`, `notifications`) so `gui`/`lang` no longer answer "Unknown action".
- **Review hardening for the new surfaces**:
  - `Write-PSManagerStateJson` no longer writes without the state lock: when another host holds `Local\PSManager.State` for the full five-second wait, the write is skipped and logged instead of racing.
  - `Get-PSManagerStateDirectory` requires a directory, so a `PSMGR_STATE_DIR` that points at a file falls back to `%TEMP%\PSManager` instead of producing unwritable `file\notifications.json` paths.
  - The release list is paged (`Get-PSManagerReleaseList`, up to five pages of 100) until `vX.Y.Z` releases are found, so accumulated `profile-backup-*` releases can never push the app releases out of the window; a "no semantic-version release" result preserves the previous good release cache as Stale instead of clearing it.
  - GUI: header/help buttons take their accessible names from i18n on the first render (they previously announced an empty string or `System.Windows.Controls.StackPanel`), `Esc` closes the notification center and the toast, and the Help page localizes the inner button labels so the vector icons survive a language switch.
  - `Add-PSManagerNotification` now reports `Added = $false` and raises no toast when the store rejects the write (locked or unwritable), instead of claiming a notification that was never persisted.
  - TUI: the notification modal keeps the plan's order (render, then mark all read), so the rows still show which items were unread; the unread counter is zeroed because the full-screen modal hides the header badge.
  - `site/assets/img/gui-health.png` and `gui-backup.png` were unreferenced (135 KB); the landing page now ships only the three images it uses.
- **`update-check` breaks once a non-app release is newest (`modules/Package/UpdateNotifier.ps1`)**: the check trusted `/releases/latest`, which returns the newest non-prerelease release by creation date — so the next `psmgr backup-cloud` run (it publishes `profile-backup-<stamp>` releases into this repo) would have become "latest", failed the semver parse, and turned every user's update check into `Status='Error'`. The check now pages through `/releases` and picks the highest published `vX.Y.Z` tag via `Select-PSManagerRelease`, ignoring backup, draft and prerelease tags, with a regression test covering that fixture.
- **Review fleet hardening across API, UX, security, and test strategy**:
  - Exported and consolidated `Get-PSManagerUpdateStatusText` across CLI, TUI, and Desktop GUI interfaces.
  - Added `Persisted` boolean flag to `Add-PSManagerNotification` and gated `Set-PSManagerUpdateLastNotified` to prevent permanent notification suppression when the store write fails.
  - Added GitHub API domain validation (`api.github.com`, `github.com`, `objects.githubusercontent.com`) and file name traversal sanitization (`ConvertTo-PSManagerSafeFileName`) in self-update asset downloads.
  - Added Authenticode signature validation (`Get-AuthenticodeSignature` checking for `HashMismatch`) before running installer packages.
  - Added confirmation prompt to plain/accessible TUI `update-app` mode and stopped the plain loop after successful installation.
  - Mapped `audit-profile` exit code 1 (issues found) to findings status rather than failure notification toast in GUI.
  - Fixed `nav_help` legend to advertise lowercase `[v]` and `[p]` matching TUI case-sensitive dispatch.
  - Fixed help catalog to display the complete CLI `switch`/`switch-ps7`/`switch-ps5` suite under Shell while excluding redundant `q_*` quick-launch rows.
  - Added comprehensive offline unit tests covering SHA-256 digest parsing, verification, scope arguments, and cache TTL calculations.
- **Notification store cleanup count (`modules/Core/Notification.ps1`)**: `Clear-PSManagerNotifications` restores returning the count of removed notifications.
- **Desktop GUI keyboard navigation and accessibility**:
  - Navigation rail items and segmented selectors (`RadioButton`s) now respond to `Enter`, `Space`, and arrow keys (`Up`/`Down`/`Left`/`Right`, `Home`/`End`) with wrap-around, ensuring complete keyboard operability without a mouse (`ui/GuiKeyboard.ps1`, `ui/GuiNavigation.ps1`).
  - Handle radio-group keys during `PreviewKeyDown`, before controls consume keyboard input, and show vector icons beside all five navigation labels.
  - Extracted `Invoke-GuiNavigationKey` in `ui/GuiNavigation.ps1` for direct, testable navigation shortcut routing (`Ctrl+1..5`, `Ctrl+Tab`, `Ctrl+Shift+Tab`, `F6`).
  - Added global navigation keyboard shortcuts: `Ctrl+1` through `Ctrl+5` (and Numpad equivalents) for direct page selection, `Ctrl+Tab` / `Ctrl+Shift+Tab` for sequential page cycling, and `F6` to return focus to the checked rail item.
  - Initial focus is set intentionally to the active navigation rail item on window load.
  - Implemented focus lifecycle preservation in `Set-BusyState` across asynchronous actions so focus is not lost or stolen.
  - Restored high-contrast focus rings (`FocusVisualStyle`) for `TextBox` (`Input` style), `RichTextBox` (`RtbConsoleLog`), `GridSplitter`, and modal dialog controls.
  - Enhanced passphrase and delete-backups modal dialogs with merged theme styles, proper initial focus, and accessible keyboard dismissal/confirmation.
  - Added automated unit and integration coverage in `tests/test_gui_keyboard.ps1` with 6 exhaustive checks registered in `tests/harness.ps1`.
- **Pre-push runner executed the same PowerShell version twice (`tests/Run-Tests.ps1`)**: when invoked by a modern shell (`pwsh`), `Run-Tests.ps1` previously executed in the current PowerShell 7 engine and then unconditionally spawned `pwsh.exe`, running the suite twice on the same version while never testing Windows PowerShell 5.1. It now detects `$isCore` and cross-verifies against the opposite engine (`powershell.exe` on PS 7+, `pwsh` on PS 5.1).
- **`Test-ModuleManifest` errors and icon fallback warning in builder test (`tests/test_builder.ps1`)**: the staging test fixture (`fakeroot`) copied `PSManager.psd1` without its RootModule (`PSManager.psm1`) and `assets`, triggering 20 `Test-ModuleManifest` error lines and a missing icon warning on packaging refusal. `PSManager.psm1` and `assets` are now staged alongside the manifest.
- **Optimized git hooks and builder packaging performance (`.agents/hooks/`, `tests/Run-Tests.ps1`, `build/PSManager.Builder.psm1`)**: introduced an explicit fast hook profile (`Run-Tests.ps1 -Fast`) for `pre-commit` and `pre-push` validating AST syntax across all sources, manifest integrity, targeted `PSScriptAnalyzer` rule audit on changed files, tri-interface parity, and automation invariants in under 10s; cached `Get-PSManagerBuildInfo` by resolved root and de-duplicated identical launcher compilations in `New-PSManagerBuildPackage` to eliminate hook bottlenecks while leaving the full dual-runtime gate complete for manual and CI validation.

## [1.6.2] - 2026-10-31

### Fixed
- **Bundle extraction could poison a payload hash (`build/PSManager.Builder.psm1`)**: a failed `Directory.Move` deleted the staging tree but still created the runtime directory and wrote `.complete`, so every later run reused an empty directory and failed permanently. The marker is now written only when the runtime directory really holds the payload, an incomplete staging tree leaves no marker, and a leftover directory with fewer files than the payload is replaced instead of reused.
- **Empty bundles were built silently**: a payload path that did not exist under the build root was skipped, producing a launcher with a hash for zero files. `New-PSManagerLauncher` now throws for a missing payload path and for a payload that resolves to zero files, and the compiled launcher refuses to extract a zero-entry payload.
- **`-Root` was half-plumbed**: `New-PSManagerLauncher` resolved `-PayloadFiles` against the module root, so a bundle built for another tree embedded nothing. `-Root` now reaches `New-PSManagerLauncher`, `New-PSManagerBuildPackage`, `New-PSManagerInstaller`, `ConvertTo-BuilderMetadata` and every `build.ps1` action, so the payload, icon and metadata all come from the requested tree.
- **Icon generation polluted the MCP stream**: `tools/New-PSManagerIcon.ps1` printed through `Write-Host`, which reached stdout inside `build/mcp-server.ps1` and broke JSON-RPC framing. It now uses `Write-Verbose`, and the wrapper captures every stream.
- **Unapproved-verb alias removed**: `Build-PSManagerLauncher` is gone; the module, MCP server, tests and docs use `New-PSManagerLauncher`.
- **`build/mcp.example.json` used `%USERPROFILE%`**: MCP hosts pass `args` literally and do not expand environment variables, so the example pointed at a nonexistent path. It now uses an explicit placeholder plus a note.
- **De-duplicate bundle payload entries (`build/PSManager.Builder.psm1`)**: overlapping `-PayloadFiles` entries (a directory plus a file inside it) are now de-duplicated by relative path, preventing file-count discrepancies during extraction.
- **Icon fallback notice and CLI pre-fill fix (`build/build.ps1`, `build/PSManager.Builder.psm1`)**: `Resolve-BuilderIconPath` warns when a `-Root` tree has no `assets/psmgr.ico`, and `build.ps1` no longer pre-fills an icon path so the fallback applies cleanly.
- **Deterministic `-Root` provenance test (`tests/test_builder.ps1`)**: string literals in compiled C# binaries are stored as UTF-16LE; `Test-EmbeddedString` scans raw bytes for both encodings and proves the marker path from `-Root` is embedded.

## [1.6.1] - 2026-10-31

### Added
- **One-command installer (`install.ps1`)**: resolves a GitHub release, downloads `PSManager-<version>-Setup.exe`, verifies its SHA256 digest against the published `SHA256SUMS.txt`, and installs it. Supports `-Version`, `-Scope CurrentUser|AllUsers`, `-InstallDir`, `-Silent`, `-NoLaunch`, `-WhatIf`, and reads credentials from `-Token`, `PSMGR_GITHUB_TOKEN`, or `gh auth token` so private releases install non-interactively.
- **winget install path (`install.ps1 -Method Winget`)**: generates a version-pinned singleton manifest from the release metadata (with the verified digest) and installs through winget; `-WriteManifest <path>` emits the same manifest for inspection or manual `winget install -m`.
- **`New-PSManagerChecksumFile` (`build/PSManager.Builder.psm1`)**: exported helper that writes sorted, lowercase, BOM-free `SHA256SUMS.txt` for every release artifact.
- **`Test-PSManagerSignature`**: verifies an Authenticode signature through `WinVerifyTrust`, which checks the digest over the file bytes and reports chain trust separately. A modified executable returns `SignatureValid = $false` (`TRUST_E_BAD_DIGEST`) while an untrusted self-signed root still verifies as signed, so pinning the signer thumbprint alone can no longer mask tampering.
- **Code signing (`tools/New-PSManagerSigningCertificate.ps1`, `build/PSManager.Builder.psm1`)**: generates a self-signed code-signing certificate (EKU 1.3.6.1.5.5.7.3.3, SHA-256, 3072-bit) without relying on the `Cert:` provider, exports `.pfx`/`.cer`, and can trust it for the current user. `Invoke-PSManagerCodeSign` now signs by `.pfx` or by `-CertificateThumbprint` (with `-MachineStore`), always uses an RFC 3161 timestamp, captures signtool output instead of writing to the console, and throws on failure so a release cannot ship half-signed.
- **Signed packaging**: `New-PSManagerBuildPackage` and `New-PSManagerInstaller` accept the certificate, so the launchers embedded in every archive and the installer itself are signed; `build.ps1` gained `-CertificateThumbprint`/`-MachineStore` and signs loose launchers during `-Action all`.
- **CI signing gate (`.github/workflows/dist.yml`)**: restores a certificate from `PSMGR_CERT_PFX_BASE64`/`PSMGR_CERT_PASSWORD` secrets when present, builds signed artifacts, refreshes digests after the bundle extraction, and fails the run when any published executable fails `Test-PSManagerSignature` with the release thumbprint pinned.

### Fixed
- **Checksums now cover every published asset**: `SHA256SUMS.txt` previously listed only the five archives, so the installer and loose launchers shipped without a digest and `install.ps1` could not verify them. It now enumerates `*.zip` and `*.exe`, sorted by file name.
- **`-Action all` checksum ordering**: digests are regenerated after the installer and code signing, so the published file matches the exact bytes released.


## [1.6.0] - 2026-10-31

### Added
- **Reusable app builder (`build/`, `tools/New-PSManagerIcon.ps1`, `assets/psmgr.ico`)**: PowerShell module (`build/PSManager.Builder.psm1`), CLI (`build/build.ps1`), and stdio JSON-RPC 2.0 MCP server (`build/mcp-server.ps1`) that compile metadata-rich Windows launchers (`psmgr.exe`, `psmgr-gui.exe`) with an embedded multi-size icon, optional single-file bundle payloads, bilingual Inno Setup 6 installer (`PSManager-<version>-Setup.exe`), release archives with sorted BOM-free checksums, and a verification report (`Test-PSManagerBuild`). Packaging refuses a staged tree that still contains a developer-specific path.

### Fixed
- **Inno Setup PATH management (`build/PSManager.Builder.psm1`)**: `NeedsAddPath` and `RemoveFromPath` now dynamically inspect and clean `HKEY_LOCAL_MACHINE` in admin mode (`/AllUsers`) and `HKEY_CURRENT_USER` in user mode, ensuring clean uninstalls without orphaned environment entries.
- **Windows argv argument quoting (`build/PSManager.Builder.psm1`)**: `Quote()` in launcher compilation now implements full Windows `CommandLineToArgvW` escaping, doubling trailing backslashes before closing quotes so paths ending in `\` are preserved without escaping the quote.
- **Fail-fast installer gate (`build/build.ps1`)**: `-Action all` no longer silently ignores a missing Inno Setup unless `-SkipInstaller` is explicitly provided.
- **Standalone loose binaries (`.github/workflows/dist.yml`)**: Releases now unpack the self-contained bundle binaries as loose `.exe` assets so direct downloads run anywhere without local script dependencies.
## [1.5.1] - 2026-10-31

### Fixed
- **Portable configuration paths (v1.5.0 shipped developer paths)**: `modules/Core/Config.ps1` no longer pins `C:\Users\<user>\tools\ps-manager\config.json`; the file resolves from the module root, so a worktree, copy or release archive reads and writes its own `config.json`. `Detection.ps1` derives the bin paths from `%USERPROFILE%`, and `SystemConfig.ps1` derives the install root from the module layout and uses `%USERPROFILE%` as the shortcut working directory.
- **Guard tests**: `tests/harness.ps1` asserts the resolved config path lives under the package root and fails when any shipped `.ps1/.psm1/.psd1/.json/.xaml` still contains a `C:\Users\<name>` literal.

## [1.5.0] - 2026-10-30

### Added
- **TUI render engine: capability detection, action catalog and pure frame builder (Track C · C5)**:
  - Added `modules/UI/TuiCapabilities.ps1`: TTY/redirection detection, UTF-8 box-drawing vs ASCII fallback, 16-colour ANSI palette honouring `NO_COLOR` and `PSMGR_PLAIN`, window dimensions, plus overrides for headless tests.
  - Added `modules/UI/TuiCatalog.ps1`: the 21 actions grouped into five sections matching the desktop information architecture, mnemonic keys (`d`, `r`), legacy digits kept on their original actions (`6`–`9`), and wider legacy letters (`D`, `R`, `S`, `U`, `I`, `Y`, `O`, `A`, `B`, `C`, `K`, `V`, `W`, `P`, `T`, `X`) preserved as aliases with a "new key" hint.
  - Added `modules/UI/TuiRender.ps1`: pure `New-TuiFrame` (state + size + capabilities → `string[]`), two-pane layout at ≥110 columns, single-pane below, centred 80x24 minimum notice, and `Get-TuiFrameDiff`/`Write-TuiFrame` for flicker-free output. Titles wrap onto continuation lines instead of being truncated; group headers carry an icon and a per-section colour; the active row is a full-width inverse-video accent bar; undoable actions show `↺`, destructive actions show `!` in red; an overflowing list gets a proportional scrollbar.
  - All TUI copy now comes from `i18n.json` (100 `tui_*` keys in `en`, `vi`, `vi-ascii`); the render, catalog, state and engine sources are ASCII-only and a test enforces it.
  - Added `modules/UI/TuiState.ps1`: pure state reducer (`New-TuiState`, `Update-TuiState`) covering arrow/Home/End/page navigation, group jumps with Tab/Shift+Tab, state-driven initial cursor, `g`/`l`/`q` globals, diacritic-insensitive `/` search, `?` help modal, and Enter routing (destructive → confirm, undoable → preview, else → run).
  - Added `tests/test_tui_render.ps1` (frame dimensions at 80x24/100x30/120x40/200x50 x vi/en x Unicode/ASCII, plus capability, catalog, search-normalisation, diff and i18n-purity checks) and `tests/test_tui_state.ps1` (every legacy key, mnemonic routing, search, help, reducer purity).
  - Rewrote `modules/UI/TuiEngine.ps1`: alternate-screen session with `try/finally` restoration on `q`, Ctrl+C and exceptions, diff-based repainting, a full repaint on resize, actions executed on the normal screen (their output stays in scrollback) followed by a persistent result screen (status, duration), preview and typed-`y` confirmation modals, plain mode (`PSMGR_PLAIN=1`) and a non-TTY guard that prints help instead of looping.
  - Added `tests/test_tui_engine.ps1`: alternate-screen restore on normal exit and on exception, key conversion, non-TTY guard, and plain-mode dispatch (actions stubbed, nothing is executed).
  - Encrypted backup and cloud-backup now abort on a mismatched or empty passphrase instead of silently producing/publishing an unencrypted archive; `Test-PSManagerPassphrase` moved to `modules/Core/Security.ps1`, exported, and shared with the CLI harness.
  - Plain mode now honours the same safety contract as the framed TUI: reversible actions print their description and undo hint and default to cancel, destructive actions require a typed `y`; tests assert that a declined prompt never reaches the executor.
  - Added a VT capability probe (`$Host.UI.SupportsVirtualTerminal`, Windows Terminal / `TERM`, else `GetConsoleMode`'s `ENABLE_VIRTUAL_TERMINAL_PROCESSING`); consoles without VT now fall back to plain mode instead of printing raw escape sequences.
- **Desktop GUI: design-token theme, navigation shell, colour-coded log (Track A)**:
  - Window markup moved out of `gui.ps1` into `ui/PSManager.MainWindow.xaml`, with design tokens in `ui/PSManager.Theme.xaml` and a loader in `ui/GuiLoader.ps1`. Handlers, element names and actions are unchanged.
  - Five-item navigation rail (Overview, Update, Backup, Health, Profiles); every page exposes exactly one primary (accent) action, and page content is centred and capped at 1200 px.
  - Activity log is now a `RichTextBox`: per-level colours, dim timestamps, clickable `http(s)://`/`file://` links, and a live filter with placeholder text.
  - Keyboard focus rings on every interactive control, `AutomationProperties.Name` on all action buttons, and a dark window title bar via `DwmSetWindowAttribute` (attribute 20, falling back to 19).
  - Section labels changed from ALL CAPS to sentence case in `en`, `vi` and `vi-ascii`; contrast measured at 7.65:1 (dim text on panel) and 16.33:1 (body text on background).
  - `i18n.json` is now resolved from the module layout instead of a hardcoded absolute path, so worktrees, copies and installed packages read their own dictionary.
  - Added `tools/Capture-PSManagerGui.ps1` (off-screen WPF renderer used for before/after screenshots) and `tests/test_gui_xaml.ps1` (XAML/theme/page/log contract, including hyperlink and filter behaviour).
- **SVG Vector Icon System (`gui.ps1`)**:
  - Replaced all Unicode emoji glyphs with 24 crisp, resolution-independent `StreamGeometry` vector paths rendered via native DirectX/DirectWrite pipeline.
  - Dedicated TextBlock element bindings for button labels ensuring text updates never overwrite vector icons.
- **Tri-Interface Parity Contract & Central Action Registry**:
  - Added `modules/Core/ActionRegistry.ps1` defining all 21 capabilities across PSManager.
  - Added automated contract test `tests/test_interface_parity.ps1` enforcing simultaneous 3-way parity across CLI (`ps-manager.ps1`), TUI (`TuiEngine.ps1`), and Desktop GUI (`gui.ps1`).
  - Added CLI `psmgr adopt` and `psmgr edit-profile`.
  - Added TUI menu actions for Adopt, Backup, Cloud Backup, Restore, Logs, and Sync Winget Sources.
  - Exported approved verb `Import-PSManagerProfiles` with backward-compatible alias `Adopt-PSManagerProfiles`.
- **Unified Action Execution Engine (`modules/Core/ActionEngine.ps1`)**:
  - Implemented deep module encapsulating subprocess execution, UTF-8 non-locking pipe tasks, buffer deadlock prevention (>64KB), ANSI escape sanitization, and exit code contracts.
  - Exported `Invoke-PSManagerAction` supporting synchronous and asynchronous Dispatcher-aware execution modes.
  - Exported `Stop-PSManagerAction` supporting clean background process tree termination.
  - Added unit and contract tests in `tests/test_action_engine.ps1`.
  - Refactored `gui.ps1` to delegate to `Invoke-PSManagerAction -Async`, eliminating 50+ lines of ad-hoc process and timer plumbing.
- **Profile Compatibility Auditor & Repair Engine (`modules/Sync/ProfileAuditor.ps1`)**:
  - Added `Test-PSManagerProfile` auditing PS 5.1 & PS 7 profiles for AST syntax, prohibited PS7-only operators (`??`, `?.`, ternary, `&&`/`||`), module load ordering (posh-git before starship), Terminal-Icons PS7 guard, PSReadLine prediction crash guard, and `STARSHIP_CONFIG` environment integrity.
  - Added `Repair-PSManagerProfile` auto-fixing module ordering, adding PS7 version guards, wrapping prediction options in try/catch, restoring invalid `STARSHIP_CONFIG`, and scaffolding missing profiles from the master template.
  - Integrated profile compatibility audit into `Invoke-PSManagerDoctor` (check #8) with `-Fix` support.
  - Registered `psmgr audit-profile [-Fix]` CLI subcommand, TUI `[T]` menu action, and Desktop GUI `BtnAuditProfiles` button (Tri-Interface Parity: 22 capabilities).
  - Added unit and contract tests in `tests/test_profile_auditor.ps1`.

- **Destructive Backup Cleanup (`Remove-PSManagerBackup`)**:
  - Added `Remove-PSManagerBackup` with `SupportsShouldProcess` (`ConfirmImpact = High`), `-WhatIf` preview, `-Force` bypass, `-All`, and multi-name `-Name` selection.
  - Every target is validated to live strictly inside the backups directory; path traversal and non-backup files are refused.
  - Each deletion is recorded as a `WARN` entry in the diagnostic log.
  - CLI: `psmgr clean-backups [all|<name>[,<name>...]]` shows a red destructive banner, lists targets, and requires typing `DELETE`; refuses to run in non-interactive sessions without `-Force` (exit 1).
  - TUI: `[X]` menu action lists numbered backups and accepts `1,3,5`, ranges (`1-3`), or `all`, then requires typed `DELETE`.
  - GUI: `BtnDeleteBackups` opens a modal with a red danger banner, extended multi-select list, and a `DELETE` confirmation field that gates the destructive button.
  - Added safety tests in `tests/test_backup_cleanup.ps1` covering single/multi/all deletion, `-WhatIf`, containment guard, fail-closed selector, and audit logging.
- **GUI UX & Streaming Enhancements (`gui.ps1`, `ActionEngine.ps1`)**:
  - Implemented live line-by-line output streaming via non-blocking `ReadLineAsync` on DispatcherTimer tick.
  - Added indeterminate accent `ProgressBar` (`#38BDF8`) communicating background progress.
  - Added user action cancellation button (`BtnCancelAction`) to abort long-running tasks via `Stop-PSManagerAction`.
  - Added real-time log search and filter box (`TxtLogFilter`) with automatic buffer capping (500 lines).
  - Added desktop window geometry persistence (`gui_state.json`) restoring custom window coordinates on launch.
  - Hardened async stream completion with full `ReadToEnd()` drain on process exit, preventing truncated log tails.
  - Configured ToolTip DataTemplate with `TextWrapping="Wrap"` and `MaxWidth="480"`, preventing long Vietnamese tooltip descriptions from clipping.
  - Switched language toggle label to `Get-GuiLanguage`, ensuring "Tiếng Việt" renders with full diacritics across all PowerShell runtimes.
### Changed
- **Consolidated into Universal `AGENTS.md` & `.agents/` Standard**:
  - Removed fragmented, redundant per-agent files (`.windsurfrules`, `.clinerules`, `.cursor/`, `.github/copilot-instructions.md`).
  - Unified all instructions into root **`AGENTS.md`** as the single source of truth across all AI agents (Pi, Cursor, Windsurf, Cline, Roo Code, Copilot, Gemini, Claude, OpenCode, Devin).
  - Maintained minimal 2-line redirect stubs in `CLAUDE.md`, `GEMINI.md`, and `.cursorrules` pointing directly to `AGENTS.md`.
  - Consolidated all hooks into **`.agents/hooks/`** (`commit-msg`, `pre-commit`, `pre-push`, `block-dangerous-git.sh`, `guard-changelog-docs.sh`).
  - Updated `setup-hooks.ps1`, `setup-hooks.cmd`, `boot.ps1`, and `psmgr doctor` to enforce `git config core.hooksPath .agents/hooks`.
- **Upgraded GitHub Actions to Node 24**:
  - Updated `actions/checkout@v7`, `actions/upload-artifact@v7`, and `softprops/action-gh-release@v3` across `ci.yml` and `dist.yml`, eliminating Node.js 20 deprecation warnings on GitHub-hosted runners.
### Fixed
- **TUI: full titles, accent bar, icons and scrollbar (Terminal.Gui conventions)**:
  - Rows wrap instead of truncating, so no action name is ever cut off; the detail pane wraps its title and description as well.
  - The active row is a full-width inverse-video bar, which keeps contrast on any terminal theme; group headers use per-section colours and icons (`◆ ▸ ↻ ▣ ✚`).
  - Added a proportional scrollbar (track + thumb) to the list pane, plus erase-to-end-of-line on every repaint.
- **TUI repaint smear fixed (`Write-TuiFrame`)**: a full-width frame was written with newlines, so the terminal's pending wrap advanced an extra row and left duplicated menu rows and stale detail lines behind. Every row is now addressed explicitly (`CSI row;1H`) and cleared with `CSI K`; a test pins the no-newline contract.
- **Three-mode language selection (`en`, `vi-ascii`, `vi`)**: `Get-EffectiveLanguage` returns the configured mode verbatim on PS 5.1 and PS 7 instead of forcing `vi-ascii` on 5.1. CLI `set-lang` accepts all three values, and the TUI `L` key and GUI language button cycle `en` → `vi-ascii` → `vi` → `en`. The TUI header names the active mode; `i18n.json` now carries 279 keys per mode.
- **CLI presentation layer (`modules/UI/Theme.ps1`, `ps-manager.ps1`)**: `status` and `source` now render aligned, grouped panels instead of a raw `Format-List`; `doctor` and `audit-profile` render one line per check with a coloured `PASS`/`WARN`/`FAIL` glyph, details and the repair hint; `help` is a grouped command reference with examples, TUI keys and exit codes. Failures print what happened plus the next step, and every glyph falls back to ASCII on non-UTF-8 consoles. `-NoColor` still emits zero ANSI escapes.
- **TUI layout regressions closed**: the single-pane description caption now emits one row per wrapped line (it reserved several rows but drew one, so 80x24 frames came out one row short); the golden-snapshot suite is restored with regenerated 80x24/100x30/120x40/200x50 baselines (`PSMGR_UPDATE_SNAPSHOTS=1` regenerates them) alongside the dimension checks, which now also cover the narrowest two-pane widths (110 and 111 columns) and assert every row is exactly frame-wide.
- **CLI flag spelling and exit codes**: help and README now use the PowerShell spellings `-DryRun`, `-Tail`, `-Errors`; the EXIT CODES block documents the actual contract (0 success, 1 failure/findings/refusal) instead of an unimplemented 2.
- **GUI Profile Audit False Failure & Link Detach Fix (`gui.ps1`, `ProfileAuditor.ps1`)**:
  - `psmgr audit-profile` returns exit code `1` when issues or warnings remain; `Invoke-GuiCliAction` previously treated all non-zero exit codes as catastrophic command failures and popped up `gui_err_failed` ("Thao tác thất bại: Kiểm tra Profile -> exit 1").
  - `Invoke-GuiCliAction` now recognizes `audit-profile` exit code `1` as audit findings, logs the findings status, and prompts the user to auto-repair (`audit-profile -Fix`).
  - Preserved audit action metadata in GUI async state, so its deferred completion callback still recognizes exit code `1` after the initiating function returns; `test_gui_async.ps1` now uses a controlled failing CLI child instead of host profile state.
  - `Repair-PSManagerProfile` now detaches profiles hardlinked to `templates\profiles\*` even when the profile content was already compliant, properly clearing the `Payload Link Safety` warning.
  - Defined `$payloadRoot` in `Test-PSManagerProfile` so link safety hints display the full repository template path.
  - Added regression tests in `test_gui_async.ps1` and `test_profile_auditor.ps1`.
- **Master Profile & E2E Test Isolation**:
  - Cleaned duplicate `fnm`, `starship`, and `agy` sections from `templates/profiles/master_profile.ps1`.
  - Changed `test_e2e_sync.ps1` fixture environment variable to safe `PSMGR_E2E_TEST` to prevent test executions from altering user's `STARSHIP_CONFIG`.
  - Restored canonical `templates/profiles/master_profile.ps1` (removed adopted machine-specific `agy` block and stray blank lines; `posh-git` now loads before `starship`; PSReadLine prediction wrapped in `try/catch`).
  - Restored the missing `$txtBtnInstall = $window.FindName("TxtBtnInstall")` binding in `gui.ps1`, fixing `The property 'Text' cannot be found on this object`.
  - Replaced naive `[^}]*` guard regexes in `ProfileAuditor` with brace-aware `Test-ProfileBlockEnclosing`, so nested `if`/`try` blocks are detected correctly and `audit-profile` no longer reports false `FAIL`s.
  - Added a static regression test asserting every `$txt*.Text` assignment in `gui.ps1` has a matching `$window.FindName(...)` binding.
  - Fixed log line array flattening in `Invoke-GuiCliAction` where pipeline outputs were space-concatenated into a single horizontal line; output lines are now iterated and logged individually.
  - Added ANSI escape code stripping before feeding child process output to `Add-Log`, preventing raw terminal escape codes from rendering in the WPF log TextBox.
  - Wrapped `Process.Start()` and stream task acquisition in `try/catch` with immediate `Set-BusyState $false` fallback on failure.
  - Added structured exception handling inside `DispatcherTimer.Tick` to protect WPF UI thread against unhandled task faults.
  - Eliminated dead `$outFile` variable allocation.
- **Hardlink Write-Through (payload template corruption)**:
  - Root cause: live profiles are hardlinked to `templates/profiles/master_profile.ps1` by design, so a plain `Set-Content` in `Repair-PSManagerProfile` or `Copy-Item` in `Restore-PSManagerBackup` silently rewrote the tracked repo payload (this is how machine-specific blocks kept reappearing in the template).
  - Added `Set-DetachedFileContent` (write temp → delete target → rename) and `Test-FileHardLink` (`fsutil hardlink list`, with `LinkType` fallback); repair and restore now go through them, so only the target's directory entry changes and every other link holder stays byte-identical.
  - `Repair-PSManagerProfile` reports `Link Safety = FIXED` when it detaches a link; `Test-PSManagerProfile` adds a `Payload Link Safety` row describing the current state.
- **PS 5.1 operator detection false positives**:
  - Replaced raw-text regexes in the compatibility check with token-based `Get-ProfilePs7OnlyConstructs`, so `?` inside string literals (e.g. `'^--?model(=|$)'`) and the `?` Where-Object alias are no longer reported as ternary operators.
- **Ambiguous backup selection**:
  - `psmgr clean-backups` now requires each name token to resolve to exactly one archive; ambiguous tokens list their candidates and abort with exit `1` even when `-Force` is supplied.
- **Backup Restore Byte Fidelity (`modules/Sync/Backup.ps1`)**:
  - Restore read each archived file with `Get-Content -Raw -Encoding UTF8` and wrote it back as text, so a UTF-16 or ANSI profile came back corrupted and every restored profile gained a BOM. Restore now copies `[IO.File]::ReadAllBytes` through `Set-DetachedFileContent -Bytes`.
- **`Set-DetachedFileContent` Never Loses the Target**:
  - The old sequence deleted the target and then renamed a temp into place; a failed rename (AV scan, lock) left no file at all. The swap is now temp → rename target aside → rename temp into place → delete the aside copy, with rollback on failure, and the original file attributes are reapplied.
  - Added `Get-HardLinkPaths` so callers can name the peers of a shared inode; `Test-FileHardLink` returns `$null` (unknown) instead of `$false` when the host cannot report link state.
- **`Payload Link Safety` Audit Row Accuracy (`modules/Sync/ProfileAuditor.ps1`)**:
  - The row claimed every 2+-link file was "hardlinked to payload template" and always reported `PASS`, so `doctor` never surfaced it. It now lists the actual peers, stays `PASS` for a legitimate 5.1↔7 pair, and raises `WARN` with a `-Fix` hint only when a peer lives under `templates\profiles\`.
  - Profile scaffolding resolved its source from a hardcoded `$env:USERPROFILE\tools\ps-manager\...` path; it is now derived from the module root, and the always-true `-or $true` backup condition was removed.
- **`clean-backups` Empty-Selection Guard (`ps-manager.ps1`)**:
  - Dropping the `$selected.Count -eq 0` check let a delimiter-only selector (`,`) proceed with zero archives and exit `0`; a missing name also printed the ambiguity message. Both cases now abort with exit `1` and their own message.
- **Test Robustness**:
  - Hardlink cases skip (instead of failing the suite) on volumes without hardlink support; added coverage for byte-exact restore, `-Bytes` writes, peer listing, and the payload-link audit warning.
- **Guard Hooks Silently Disabled by CRLF (`.agents/hooks/`)**:
  - Four of the five hooks (`commit-msg`, `pre-commit`, `pre-push`, `block-dangerous-git.sh`) were stored with CRLF endings while `.agents/hooks/*` are parsed by `sh`, which treats `\r` as a literal character. The guards only appeared to work: `block-dangerous-git.sh` died on `for pattern ... do\r` and returned the wrong exit code for both blocked and allowed commands.
  - Normalized all hooks to LF and added `.gitattributes` (`* text=auto eol=lf`, explicit LF for hooks/scripts/PowerShell) so a Windows checkout cannot reintroduce CRLF.
- **Seven Test Suites Never Ran in Any Gate (`tests/harness.ps1`)**:
  - `test_backup`, `test_bootstrapper`, `test_linker`, `test_logger`, `test_manifest`, `test_provisioner` and `test_sync_engine` were not referenced by the harness, so pre-commit, pre-push and CI skipped them. They are now registered explicitly; the suite grows from 72 to 80 tests on both engines.
  - Added an "Automation invariants" harness test that fails when any hook contains CR or any `tests/test_*.ps1` is missing from the harness registration list.
- **CLI Error Signaling & Module-Scoped NoColor Theme (`ps-manager.ps1`, `Theme.ps1`)**:
  - Made `psmgr sync` exit with code `1` when synchronization fails (`-not $res.Success`), ensuring failures surface accurately to the GUI and calling scripts.
  - Implemented module-level theme mutators `Set-PSManagerTheme` and `Disable-PSManagerColor` (`modules/UI/Theme.ps1`) so that `Format-ColorText`, `Format-ColorBadge`, and `Show-PSManagerHelp` cleanly suppress all ANSI escapes when `-NoColor` is requested.
  - Added cross-version test assertion in `tests/harness.ps1` verifying `help -NoColor` emits zero ESC characters across both PS 5.1 and PS 7 engines.
- **TUI Key Prompt String Concatenation (`modules/Package/SourceManager.ps1`)**:
  - Wrapped all `Write-Host ("`n" + (Get-I18nText "press_key"))` calls in parentheses to eliminate stray literal `+` rendering.
- **Deterministic Log Chronology (`modules/Core/Logger.ps1`)**:
  - Sorted log files by `Name` ascending rather than `LastWriteTime`, ensuring consistent chronological ordering for ISO-dated log files.
- **Dual-Runtime Test Sandbox & CI Stability (`tests/test_e2e_sync.ps1`)**:
  - Replaced live-host sync with an isolated sandbox fixture manifest targeting temporary files with package checks disabled, eliminating CI runner hangs, network timeouts, and host profile mutations.
  - Dynamically resolved PowerShell engine executable instead of hardcoding `pwsh.exe`, ensuring clean test execution on Windows PowerShell 5.1-only hosts.
- **Winget Command Availability Guard (`ps-manager.ps1`)**:
  - Added explicit `Get-Command winget` validation and exit code propagation in CLI `sync-sources` branch, correctly signaling failure to GUI and automated callers.
- **CI Verification Mandate (`AGENTS.md`)**:
  - Mandated native `gh run watch --exit-status` verification after every push to ensure remote CI passes green before completing tasks.
- **Custom Update Icon (`BtnUpdate`)**: Redesigned the "Cập nhật PowerShell" icon with a bold, high-contrast clockwise circular sync loop and prominent upward upgrade arrow (`IconUpdate`, 15x15px, Fill `#38BDF8`), replacing the thin blurry rocket silhouette.
- Replaced hardcoded path in `Start-DesktopGUI` (`ShellSwitcher.ps1`) with dynamic repo resolution.
- Fixed root directory calculation in `Get-DefaultBackupRepo` to correctly traverse two levels up from `modules/Sync/`.
- Replaced fallback hardcoded path in `gui.ps1` with `$PSScriptRoot` / `$PWD`.
- Broadened commit flag regex in `guard-changelog-docs.sh` to match combined flags like `-am`.
- Hardened release URL parsing in `Publish-PSManagerCloudBackup` to explicitly match GitHub URLs.
- Added buffer size guard and dynamic flip index in backup tamper test.
---

## [1.4.0] - 2026-10-28

### Added
- **Backup Encryption Engine**:
  - `Protect-PSManagerBackup` and `Unprotect-PSManagerBackup` supporting **Encrypt-then-MAC** (`PSMGR2` format: AES-256-CBC + HMAC-SHA256, 100,000 PBKDF2-SHA256 rounds, constant-time verification).
  - Windows DPAPI mode (`PSMGRD` format via `System.Security.Cryptography.ProtectedData`) for machine-bound, zero-passphrase local snapshots.
  - Automatic encrypted archive detection and transparent in-memory decryption on restore.
- **Cloud Backup Integration**:
  - `Publish-PSManagerCloudBackup` cmdlet and `psmgr backup-cloud` CLI command uploading timestamped, optionally encrypted release assets to private GitHub repository via `gh release create`.
  - Dynamic GitHub repo resolver inspecting `git remote origin`, `gh repo view`, or `config.json` override.
- **Desktop WPF GUI Parity & Modernization**:
  - Full feature parity with CLI/TUI: Sync Now, Doctor Audit, Doctor Fix All, Adopt Current Profiles, Sync Winget Sources, View Logs, Backup Profiles, Restore Backup, and Backup to Cloud.
  - Native WPF Slate-dark Passphrase Dialog with `PasswordBox`, confirmation, keyboard accessibility (`IsDefault`, `IsCancel`, auto-focus).
  - Reverse profile adoption ("Adopt Current Profiles"): copies live user profiles into payload templates as the new source of truth.
  - Segmented buttons for update source and release channel selection.
  - Resizable output log viewer with Splitter, Copy to Clipboard, and Clear actions.
  - Live auto-refresh of status cards on window activation.
  - Full Unicode Vietnamese (`vi`) rendering in WPF, bypassing console-specific diacritic downgrades.
- **CI/CD Distribution Pipeline**:
  - Added `.github/workflows/dist.yml` building three distribution packages (`full`, `cli-tui`, `desktop`) with `SHA256SUMS.txt` on version tags and manual dispatches.
- **Automated Test Coverage**:
  - Test suite extended with 9 automated tests covering AES-256 + HMAC-SHA256 encryption, wrong passphrase rejection, DPAPI transparent round-trip, and ciphertext bit-flip tamper resistance.

### Fixed
- **TUI Column Alignment**: Fixed right-border misalignment caused by Vietnamese combining diacritics using Unicode grapheme cluster counting (`System.Globalization.StringInfo`) and NFC precomposition.
- **Windows Terminal Split-Screen**: Fixed broken command separator in `Start-QuickShell -Target 'Split'` using `new-tab ... ; split-pane ...`.
- **Doctor Audit False Warning**: Resolved `ripgrep` application check failure by adding `AppResolver.ps1` binary mapping (`ripgrep` -> `rg.exe`).
- **Missing Template Directory Trees**: Fixed doctor link repair failures by structuring `templates/profiles/` and `templates/configs/`.
- **Starship Prompt Timeouts**: Increased `scan_timeout` and `command_timeout` to 2000ms in template configs.
- **Memory Security**: Ensured all `SecureStringToBSTR` allocations in CLI and GUI are zero-freed via `[Marshal]::ZeroFreeBSTR`.
- **CI Matrix Bug**: Fixed GitHub Actions startup failure caused by invalid context expressions in `shell:` step properties.

---

## [1.3.0] - 2026-10-27

### Added
- **Core Engine & Architecture**:
  - Dual-runtime compatibility engine supporting both Windows PowerShell 5.1 (Desktop) and PowerShell 7.4+ (Core).
  - 1-Click Default Shell Switcher configuring Windows Terminal profiles, default terminal delegation, PATH shims, and context menus.
  - Multi-source package management supporting Winget Community, Microsoft Store, and GitHub Releases.
  - Automated cross-version test harness (`tests/Run-Tests.ps1`) with 53 automated checks.
  - Non-locking diagnostic file logger (`modules/Core/Logger.ps1`).
  - Adaptive multilingual internationalization engine (`i18n.json`) with auto-fallback.
- **Profile Synchronization & Provisioning**:
  - JSON schema manifest parser and validator (`manifest.json`).
  - Safe linking engine with atomic `.bak.<timestamp>` backups and volume-root hardlink/symlink/copy fallbacks.
  - Multi-package provisioning across Winget, Scoop, and PSGallery.
  - Environment Doctor audit and 1-click auto-repair engine (`psmgr doctor -Fix`).
  - Zero-state web bootstrapper (`boot.ps1`) for clean Windows machines.
