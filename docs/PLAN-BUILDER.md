# PLAN — Reusable app builder (PowerShell · CLI · MCP)

Implements `docs/SPEC-BUILDER.md`.

**Goal:** one builder that compiles metadata-rich launchers, single-file bundles, packages and
verification reports, driven from PowerShell, a CLI, or an MCP host.

**Files**

| Path | Responsibility |
|---|---|
| `build/PSManager.Builder.psm1` | module API: metadata, csc compilation, icon, packages, verification |
| `build/build.ps1` | CLI wrapper with `-Action` dispatch |
| `build/mcp-server.ps1` | stdio JSON-RPC server exposing the builder as MCP tools |
| `build/mcp.example.json` | copy-paste MCP client configuration |
| `tools/New-PSManagerIcon.ps1` | multi-size ICO generator (called by the module) |
| `tests/test_builder.ps1` | contract tests for the module, CLI and MCP server |
| `.github/workflows/dist.yml` | tagged releases built through the module |

---

## Task 1 — Module core (metadata, compiler, launcher)

- [x] `Get-PSManagerBuildInfo`: manifest version, git remote URL, defaults.
- [x] `ConvertTo-BuilderMetadata`: explicit overrides win over defaults; semantic version enforced.
- [x] `Resolve-BuilderCompiler`: newest `Framework64\v4.*\csc.exe`, fallback `Framework`.
- [x] `New-BuilderLauncherSource`: assembly attributes, manifest, host selection, argument quoting,
      exit-code forwarding, optional STA and payload extraction.
- [x] `New-PSManagerLauncher`: temp source + manifest, `csc /win32icon /win32manifest`, cleanup in
      `finally`.
- [x] Verify: build a launcher in `%TEMP%`, read `VersionInfo`, confirm icon and metadata.

## Task 2 — Icon

- [x] `tools/New-PSManagerIcon.ps1` writes a 9-size ICO with classic DIB frames (Explorer, .NET and
      csc all read it).
- [x] `New-PSManagerBuildIcon` wraps it.
- [x] Verify: header check (`00 00 01 00`), `[System.Drawing.Icon]` round-trip, file size > 2 KB.

## Task 3 — Bundle mode

- [x] `-PayloadFiles` embeds Base64 entries plus a content hash.
- [x] Launcher extracts to `%LOCALAPPDATA%\PSManager\runtime\<hash>` once, atomically.
- [x] Verify: run a bundle from a directory without scripts; second run reuses the extraction.

## Task 4 — Packages

- [x] `New-PSManagerBuildPackage`: full/desktop/cli-tui stages, launchers, `.cmd` shims, CRLF
      shims, sorted lowercase checksums, staging cleanup.
- [x] Verify: five zips, checksum file parses, launchers present in each zip, CLI zip has no GUI.

## Task 5 — Verification API

- [x] `Test-PSManagerBuild`: metadata fields, icon readability, version match, optional smoke run.
- [x] Verify: an executable built with `-Metadata` overrides reports the overrides; a deliberately
      wrong `-ExpectedVersion` reports `Passed = $false`.

## Task 6 — CLI

- [x] `build/build.ps1 -Action info|icon|build|package|verify|all` with `-Root`, `-Destination`,
      `-Version`, `-Mode`, `-IconPath`, `-SmokeRun`; exit 1 on failure with the reason.
- [x] Verify: `-Action all` in a temp destination exits 0.

## Task 7 — MCP server

- [x] Line-delimited JSON-RPC 2.0 on stdin/stdout: `initialize`, `notifications/initialized`,
      `ping`, `tools/list`, `tools/call`, `shutdown`, `exit`.
- [x] Tools: `build_info`, `build_icon`, `build_launcher`, `build_app`, `package_release`,
      `build_installer`, `sign_artifacts`, `verify_build` with JSON schemas.
- [x] Errors: `-32602` invalid params, `-32603` build failure; server keeps running.
- [x] Verify: pipe four requests through the process and assert one JSON object per line.

## Task 8 — Tests

- [x] `tests/test_builder.ps1` covering AC-B-1..AC-B-10, registered in `tests/harness.ps1`.
- [x] Verify: `tests/Run-Tests.ps1` green on 5.1 and 7; PSScriptAnalyzer silent.

## Task 9 — CI and release

- [x] `dist.yml` calls the builder CLI and installs Inno Setup 6 in CI.
- [x] Tag `v1.6.1` on main, trigger the distribution workflow.
- [x] Verify: tagged workflow publishes `PSManager-<ver>-Setup.exe` plus five archives, every
      executable is signed by the release certificate, and a downloaded installer installs and
      uninstalls cleanly.

## Task 10 — Docs

- [x] `README.md` (launchers, builder CLI, MCP config), `CONTEXT.md` (tree), `CHANGELOG.md`
      (`[1.6.0]`), `docs/SDLC.md` (builder gates), `docs/SPEC-BUILDER.md`,
      `docs/PLAN-BUILDER.md`.
---

## Verification matrix

| AC | Command |
|---|---|
| AC-B-1 | `Import-Module build/PSManager.Builder.psm1; Get-Command -Module PSManager.Builder` |
| AC-B-2 | `tests/test_builder.ps1` (metadata + icon assertions) |
| AC-B-3 | `tests/test_builder.ps1` (smoke run prints `PSManager v<ver>`, exit 0) |
| AC-B-4 | `tests/test_builder.ps1` (bundle run without siblings; extraction reuse) |
| AC-B-5 | `tests/test_builder.ps1` (zips, checksum format, launcher presence) |
| AC-B-6 | `tests/test_builder.ps1` (MCP stdio round-trip) |
| AC-B-7 | `build/build.ps1 -Action all -Destination <temp>` |
| AC-B-8 | `tests/Run-Tests.ps1` on 5.1 and 7 |
| AC-B-9 | `gh run watch <dist run> --exit-status` |

## Rollback

The builder is additive: it writes only to the destination passed by the caller. If a release built
through it misbehaves, re-run the previous workflow (tag move is not required) and delete the
published assets with `gh release delete-asset`; no repository state is mutated by a build.
