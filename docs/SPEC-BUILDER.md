# SPEC — Reusable app builder, installer and release assets

**Doc ID**: SPEC-BUILDER-001
**Status**: approved (decisions locked 2026-10-30)
**Reference**: [PSEBuilder](https://github.com/durgesh0505/PSEBuilder) — GUI-only script→EXE builder.
This specification keeps its zero-dependency `csc.exe` compilation model and adds a PowerShell module
API, a CLI, an MCP server, single-file bundles, an Inno Setup installer, optional code signing and a
verification gate.

---

## 1. Purpose

One builder turns the PSManager project (and any PowerShell project) into runnable Windows
artifacts with professional metadata, an icon, launchers, portable archives, a per-user installer
and a verification report — callable from PowerShell, from CI, or from an MCP client.

## 2. Interfaces

| Interface | Entry point | Audience |
|---|---|---|
| PowerShell module | `build/PSManager.Builder.psm1` | scripts, tests, other modules |
| CLI | `build/build.ps1 -Action <info\|icon\|build\|package\|installer\|sign\|verify\|all>` | humans, CI |
| MCP | `build/mcp-server.ps1` (stdio JSON-RPC 2.0) | agents and MCP hosts |

## 3. Functional requirements

### Module API

- **FR-B-1.1** `Get-PSManagerBuildInfo` returns root, version (manifest), author/company, product,
  copyright, description, repository URL and icon path. The URL comes from
  `git remote get-url origin` when available, otherwise the canonical GitHub URL.
- **FR-B-1.2** `New-PSManagerLauncher` compiles one executable and returns its absolute path.
  Parameters: `-Destination`, `-Name`, `-ScriptName`, `-Kind Console|Windows`,
  `-ExtraArguments`, `-StaThread`, `-RequireAdmin`, `-IconPath`, `-Metadata`, `-PayloadFiles`,
  `-CertificatePath`, `-CertificatePassword`, `-CertificateThumbprint`, `-Root`. `-Root` supplies
  the payload, default icon and metadata source. A requested payload path that does not exist, or
  a payload that resolves to zero files, is an error.
- **FR-B-1.3** `New-PSManagerBuildIcon` writes a multi-size ICO (16-256 px) and writes nothing to
  the host stream, so it is safe inside the MCP server.
- **FR-B-1.4** `Test-PSManagerBuild` returns `Passed`, `Problems`, version fields and `HasIcon`.
- **FR-B-1.5** `New-PSManagerBuildPackage` builds the release archives and returns each path and
  size; `-Root` selects the staged tree.
- **FR-B-1.6** `New-PSManagerInstaller` generates and compiles the Inno Setup installer.
- **FR-B-1.7** `Invoke-PSManagerCodeSign` signs artifacts with `signtool.exe` by `.pfx`
  (`-CertificatePath`/`-CertificatePassword`) or by store thumbprint (`-CertificateThumbprint`,
  `-MachineStore`), always with an RFC 3161 timestamp, and returns `Signed`/`Count`. It is a no-op
  without a certificate and throws when signing fails.
- **FR-B-1.8** `New-PSManagerChecksumFile` writes `SHA256SUMS.txt` for the requested patterns
  (`*.zip`, `*.exe` by default) and returns its path.
- **FR-B-1.9** `Test-PSManagerSignature` verifies an Authenticode signature through
  `WinVerifyTrust` and returns `SignatureValid`, `ChainTrusted`, `Thumbprint`,
  `ThumbprintMatches`, `Reason` and `Passed`. A modified file reports `SignatureValid = $false`
  (`TRUST_E_BAD_DIGEST`); a valid signature over an untrusted self-signed root reports
  `SignatureValid = $true` with `ChainTrusted = $false`, so pinning a thumbprint alone never
  stands in for cryptographic verification.
- **FR-B-1.10** Every function is exported, uses approved verbs, and works on PowerShell 5.1 and 7.

### Metadata

- **FR-B-2.1** Binaries carry `AssemblyTitle`, `AssemblyDescription`, `AssemblyCompany`,
  `AssemblyProduct`, `AssemblyCopyright`, `AssemblyTrademark`, `AssemblyVersion`,
  `AssemblyFileVersion`, `AssemblyInformationalVersion` and `AssemblyMetadata("RepositoryUrl")`.
- **FR-B-2.2** Assembly/file versions are padded to four numeric parts; the informational version
  keeps the semantic version.
- **FR-B-2.3** The description includes the repository URL so Explorer shows author, link and
  copyright without opening the app.

### Launcher behaviour

- **FR-B-3.1** Launcher mode resolves the target script next to itself.
- **FR-B-3.2** The launcher prefers `pwsh.exe` on `PATH`; otherwise it uses
  `%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe` by absolute path. A stripped `PATH`
  MUST NOT break it.
- **FR-B-3.3** Arguments are forwarded verbatim and the child exit code is returned unchanged.
- **FR-B-3.4** The Windows launcher runs without a console window and is `[STAThread]`.
- **FR-B-3.5** The manifest declares `asInvoker` by default and `requireAdministrator` with
  `-RequireAdmin`, plus Windows 10/11 `supportedOS`.

### Bundle mode

- **FR-B-4.1** Bundle mode embeds every payload file (Base64) and needs no sibling scripts.
- **FR-B-4.2** First run extracts to `%LOCALAPPDATA%\PSManager\runtime\<payload-hash>` and writes a
  `.complete` marker; later runs reuse it. The marker is written only when the directory actually
  holds the payload, so a failed move never marks an empty directory as complete.
- **FR-B-4.3** Extraction is atomic (staging directory then move) and leaves no staging directory.
  An incomplete staging tree leaves no marker and is retried on the next run, and a leftover
  directory holding fewer files than the payload is replaced rather than reused.
- **FR-B-4.4** The hash is content-derived: identical content reuses one directory, changed content
  gets a new one. Overlapping `-PayloadFiles` entries are de-duplicated by relative path so the
  entry count always matches the extracted file count.
- **FR-B-4.5** A launcher compiled with an empty payload refuses to create or mark a runtime
  directory, and the builder refuses to produce such a bundle at all.

### Packages

- **FR-B-5.1** Archives: `psmgr-<ver>-windows-full.zip` (CLI+TUI+GUI+module),
  `psmgr-<ver>-windows-desktop.zip`, `psmgr-<ver>-windows-cli-tui.zip` (no GUI),
  `psmgr-<ver>-windows-portable.zip` (launcher layout, portable config) and
  `psmgr-<ver>-windows-bundle.zip` (single-file `psmgr.exe` + `psmgr-gui.exe`).
- **FR-B-5.2** Every archive contains `psmgr.exe`, `psmgr.cmd` and, where the GUI is present,
  `psmgr-gui.exe`, `psmgr-gui.cmd`, `PSManager-GUI.cmd`.
- **FR-B-5.3** `SHA256SUMS.txt` is lowercase SHA-256, LF endings, ASCII without BOM, sorted by name,
  and covers every published artifact (`*.zip` and `*.exe`), including the installer.
- **FR-B-5.4** Staging directories are removed afterwards; nothing is written outside the
  destination.
- **FR-B-5.5** Packaging MUST fail when a staged source contains a hard-coded developer path
  (`C:\Users\<name>`), so a non-portable build cannot ship.

### Installer (Inno Setup 6)

- **FR-B-6.1** `New-PSManagerInstaller` writes a generated `.iss` and compiles it with `ISCC.exe`
  located via `-CompilerPath`, `PATH`, `%ProgramFiles(x86)%\Inno Setup 6`, or
  `%ProgramFiles%\Inno Setup 6`.
- **FR-B-6.2** Installer name: `PSManager-<ver>-Setup.exe`; publisher/author, product name,
  copyright, version and support URL come from the build metadata; the icon is `assets/psmgr.ico`.
- **FR-B-6.3** Per-user install to `%LOCALAPPDATA%\Programs\PSManager` by default, no elevation.
  `PrivilegesRequired=lowest` with `PrivilegesRequiredOverridesAllowed=commandline` and
  `Dialog`; `/AllUsers` installs to `{commonpf}\PSManager` with elevation.
- **FR-B-6.4** Components/tasks: Desktop shortcut, Start Menu shortcut, `psmgr` on the user `PATH`,
  and Add/Remove Programs registration with `unins000.exe`.
- **FR-B-6.5** Config stays with the installation (`config.json` beside the scripts); the installer
  MUST NOT write into the user profile other than shortcuts, PATH and registry entries.
- **FR-B-6.6** The installer ships the launcher layout (not the bundle), so users can inspect and
  patch scripts.
- **FR-B-6.7** Uninstall removes files, shortcuts, PATH entry and registry keys; it leaves user
  profiles and backups untouched. PATH cleanup is mode-aware: `/AllUsers` removes the
  `HKLM` machine entry, a per-user install removes the `HKCU` entry, and an admin uninstall also
  clears a stale `HKCU` entry left by an earlier per-user install.
- **FR-B-6.8** The build fails with an actionable message when Inno Setup is absent; `-SkipInstaller`
  (CLI `-SkipInstaller`) builds the other assets.
- **FR-B-6.9** `config.json` is installed with `onlyifdoesntexist uninsneveruninstall`, so upgrades
  and reinstalls keep the user's source, channel and language. `PSMGR_NOLAUNCH` in the environment
  suppresses the post-install launch; unknown command-line switches are not accepted by Inno.

### Code signing

- **FR-B-7.1** When a certificate is supplied (`.pfx` path or store thumbprint), `signtool.exe`
  signs every produced `.exe` — the loose launchers, the launchers embedded in each archive, and
  the installer — with `/fd sha256 /tr <timestamp-url> /td sha256`.
- **FR-B-7.2** Without a certificate the builder logs `unsigned` and continues; documentation states
  the SmartScreen consequence.
- **FR-B-7.3** Signing failures are fatal for the build (never ship a half-signed set silently).
- **FR-B-7.4** A release gate verifies every published executable with
  `Test-PSManagerSignature` and the release thumbprint pinned, and fails the run otherwise.

### Verification

- **FR-B-8.1** `Test-PSManagerBuild` fails when file version, company, product, copyright or icon is
  missing, when the expected version does not match, or when the optional smoke run exits non-zero.
- **FR-B-8.2** The smoke run executes `help -NoColor` and MUST exit 0.

### CLI

- **FR-B-9.1** `build/build.ps1` actions: `info|icon|build|package|installer|sign|verify|all`, with
  `-Root`, `-Destination`, `-Version`, `-Mode`, `-IconPath`, `-Metadata`, `-RequireAdmin`,
  `-SkipInstaller`, `-CertificatePath`, `-CertificatePassword`, `-CertificateThumbprint`,
  `-MachineStore`, `-SmokeRun`. `-Root` is threaded through launchers, packages, the installer and
  the metadata defaults. `all` builds, packages, installs and signs in one pass and writes the
  digests last, so there is no separate sign step to remember.
- **FR-B-9.2** Exit code 0 on success, 1 on the first failure, with the reason printed.
- **FR-B-9.3** `all` runs icon → launchers → packages → installer → digests → verify and stops at
  the first failure. Signing happens while each launcher and the installer are produced, so the
  archives contain signed binaries and the digests cover the final bytes.

### MCP server

- **FR-B-10.1** `build/mcp-server.ps1` speaks line-delimited JSON-RPC 2.0 on stdin/stdout:
  `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`, `shutdown`, `exit`.
- **FR-B-10.2** Tools: `build_info`, `build_icon`, `build_launcher`, `build_app`, `package_release`,
  `build_installer`, `sign_artifacts`, `verify_build`, each with an input JSON schema.
- **FR-B-10.3** stdout carries protocol messages only; diagnostics go to stderr.
- **FR-B-10.4** Invalid params return `-32602`, build failures `-32603`; the server stays alive after
  a tool error.

## 4. Non-functional requirements

- **NFR-B-1** Windows-only, PowerShell 5.1+, .NET Framework 4.x; no module installs, no NuGet.
  Inno Setup 6 is the only optional external tool and only for the installer step.
- **NFR-B-2** Compilation uses `csc.exe` directly (no `Add-Type` assembly loading, no file locks).
- **NFR-B-3** All temporary directories are removed in `finally` blocks.
- **NFR-B-4** No secrets or machine paths are embedded in produced binaries or scripts.
- **NFR-B-5** The builder passes PSScriptAnalyzer with zero findings.

## 5. Decisions (locked)

| # | Decision | Rationale |
|---|---|---|
| D1 | Builder scope = module + CLI + MCP + bundle + tests | User selected the complete option |
| D2 | MCP implemented in pure PowerShell (stdio JSON-RPC) | No extra runtime; repo stays PowerShell-only |
| D3 | Installer engine = Inno Setup 6 | User selected; standard UI, silent install, PATH/registry support |
| D4 | Install scope = per-user default, `/AllUsers` override | Works without admin by default, still deployable machine-wide |
| D5 | Installer features: shortcuts, PATH, Add/Remove + uninstall, config stays in install dir | User selected all four |
| D6 | Release assets: setup.exe, portable zip, bundle zip, cli-tui zip (+ full/desktop) | User selected the complete set |
| D7 | Signing via `signtool` with a `.pfx` or a store thumbprint; a self-signed certificate ships for local use | A commercial certificate is not available; the self-signed path removes the unsigned-binary signal and can be trusted per machine |
| D8 | Release line: v1.6.0 (builder), v1.6.1 (installer + signing), v1.6.2 (hardening) | Each release was produced by the tagged distribution workflow |

## 6. Non-goals

- Obfuscation, antivirus-evasion, MSIX/Store packaging.
- Embedding arbitrary runtime assets beyond the declared payload list.
- A GUI front end for the builder itself.
- Rewriting PowerShell into IL.

## 7. Acceptance criteria

| id | Criterion |
|---|---|
| AC-B-1 | `Import-Module build/PSManager.Builder.psm1` exports every listed function on 5.1 and 7. |
| AC-B-2 | A launcher reports FileVersion, CompanyName, ProductName, FileDescription, LegalCopyright and exposes an icon (`Test-PSManagerBuild -Passed`). |
| AC-B-3 | Running that launcher with `help -NoColor` prints `PSManager v<version>` and exits 0. |
| AC-B-4 | A bundle executable runs with no sibling scripts and reuses its extraction directory. |
| AC-B-5 | Packages contain the five archives (full, desktop, cli-tui, portable, bundle) and a sorted, lowercase, BOM-free checksum file; launchers are present in each. |
| AC-B-6 | Packaging fails when a staged source contains `C:\Users\<name>`. |
| AC-B-7 | `New-PSManagerInstaller` produces `PSManager-<ver>-Setup.exe` with metadata and icon; the generated `.iss` declares per-user default, `/AllUsers` override, shortcuts, PATH and uninstall registration. |
| AC-B-8 | Signing with a certificate signs every exe; without one the build logs `unsigned` and succeeds. |
| AC-B-9 | The MCP server answers `initialize`, `tools/list` and `tools/call build_info`; stdout stays one JSON object per line. |
| AC-B-10 | `build/build.ps1 -Action all` exits 0 (with `-SkipInstaller` when Inno is absent) and leaves no staging directory. |
| AC-B-11 | `tests/test_builder.ps1` passes on both engines and is registered in `tests/harness.ps1`. |
| AC-B-12 | A tagged `v*.*.*` run publishes `PSManager-<ver>-Setup.exe`, the five archives and a checksum file covering both; every executable verifies against the release certificate; a downloaded installer installs and uninstalls cleanly. |
