# Diagrams: Runtime Flows

**Doc ID**: DIAGRAMS-001  
Companion to `docs/ARCHITECTURE.md` (static topology) — this file holds the
**behavioural** diagrams. All diagrams are Mermaid and render in GitHub/VS Code.

---

## 1. Tri-Interface Parity Enforcement

```mermaid
flowchart TD
    AR[ActionRegistry.ps1<br/>single source of truth<br/>23 capabilities] --> P{tests/test_interface_parity.ps1}
    CLI[ps-manager.ps1<br/>ValidateSet + switch] --> P
    TUI[TuiEngine.ps1<br/>menuItems + switch] --> P
    GUI[gui.ps1<br/>x:Name + Add_Click] --> P
    P -->|all present| OK[PASS]
    P -->|any missing| FAIL[FAIL<br/>commit blocked]
```

Rule: a capability is real only when it exists in all three drivers **and** the
registry, in one commit.

---

## 2. Action Execution Engine (`Invoke-PSManagerAction`)

```mermaid
sequenceDiagram
    participant UI as GUI / CLI
    participant AE as ActionEngine
    participant P as child pwsh
    participant T as DispatcherTimer

    UI->>AE: Invoke-PSManagerAction -Action sync -Async
    AE->>P: Start (redirected stdout/stderr, UTF-8)
    AE->>P: ReadLineAsync (both streams, immediately)
    AE-->>UI: handle ($Script:ActiveActionHandle)

    loop every 100 ms
        T->>AE: tick
        AE->>P: drain completed lines
        AE->>UI: OnOutput(line)  (ANSI stripped)
    end

    P-->>AE: HasExited
    AE->>P: ReadToEnd (flush remaining tail)
    AE->>UI: OnCompleted(result)
    AE->>AE: Remove from ACTIVE_ACTION_PROCESSES
```

Cancellation path: `BtnCancelAction` → `Stop-PSManagerAction` → `Process.Kill()`
→ state cleared → `OnCompleted` never fires.

---

## 3. Sync Flow (with sandboxed test variant)

```mermaid
flowchart TD
    A[psmgr sync] --> B[Resolve manifest<br/>~/.dotfiles/manifest.json<br/>else templates/manifest.default.json]
    B --> C[Validate schema]
    C -->|invalid| X[fail]
    C --> D[Backup profiles]
    D --> E{SkipPackages?}
    E -->|no| F[Provision winget / scoop / psgallery]
    E -->|yes| G
    F --> G[Preflight: all link sources exist?]
    G -->|missing| Y[abort before touching targets]
    G --> H[Link each target<br/>hardlink → symlink → copy]
    H --> I[Apply env vars<br/>Process + User]
    I --> J[Write Finished log line]
```

Tests use a temporary manifest with `type: copy`, temp targets, empty package
lists, and `PSMGR_E2E_TEST` instead of `STARSHIP_CONFIG`.

---

## 4. Profile Audit & Repair

```mermaid
flowchart TD
    T[Test-PSManagerProfile] --> E1[File exists?]
    T --> E2[AST parses?]
    T --> E3[5.1 operators<br/>token scan: Get-ProfilePs7OnlyConstructs]
    T --> E4[posh-git before starship?]
    T --> E5[5.1: Terminal-Icons inside PS7 guard?]
    T --> E6[PSReadLine prediction inside try?]
    T --> E7[STARSHIP_CONFIG target exists?]
    T --> E8[Payload link safety<br/>Get-HardLinkPaths peers]

    E4 --> B{brace balance<br/>Test-ProfileBlockEnclosing}
    E5 --> B
    E6 --> B
    B --> R{issues?}
    R -->|yes| W[WARN / FAIL rows]
    R -->|no| OK[PASS]
    W --> F[Repair-PSManagerProfile]
    F --> BAK[.bak.timestamp]
    F --> FX1[reorder posh-git]
    F --> FX2[guard Terminal-Icons]
    F --> FX3[wrap prediction in try/catch]
    F --> FX4[restore STARSHIP_CONFIG]
    F --> FX5[scaffold missing profile]
    F --> W2[Set-DetachedFileContent]
    W2 --> LS{Peer under templates\profiles?}
    LS -->|yes| DETACH[rename aside, swap in temp<br/>payload template untouched<br/>Link Safety = FIXED]
    LS -->|no| PLAIN[independent replace]
```

---

## 4b. Hardlink Write-Through Hazard

```mermaid
flowchart LR
    subgraph WRONG["Unsafe: Set-Content / Copy-Item"]
        A1[payload template] --- H1[(same inode)]
        H1 --- B1[live profile]
        B1 -->|write| MUT[payload silently mutated]
    end

    subgraph SAFE["Safe: Set-DetachedFileContent"]
        A2[payload template] -.->|link dropped, bytes untouched| X2[other holder kept]
        B2[live profile] -->|1. write sibling temp| T2[temp file]
        T2 -->|2. rename target aside| O2[aside copy]
        O2 -->|3. rename temp into place| NEW[independent file]
        NEW -->|4. delete aside copy| NEW
    end
```

---

## 5. Destructive Backup Cleanup

```mermaid
flowchart TD
    A[clean-backups / X / BtnDeleteBackups] --> B[List backups<br/>Get-PSManagerBackups]
    B -->|none| N[nothing to do]
    B --> C[Select: names | numbers | all]
    C --> D[Show destructive banner<br/>+ resolved file list]
    D --> E{interactive?}
    E -->|no and no -Force| REF[refuse, exit 1]
    E -->|yes| G{typed DELETE?}
    G -->|no| AB[abort, delete nothing]
    G -->|yes| H[Remove-PSManagerBackup]
    E -->|-Force| H
    H --> CG{path inside<br/>backups dir?}
    CG -->|no| SK1[skip + error]
    CG -->|yes| SP{matches<br/>profile_backup_*.zip?}
    SP -->|no| SK1
    SP -->|yes| DEL[Delete]
    DEL --> LOG[WARN: Backup cleanup: deleted=N]
```

---

## 6. Dual-Runtime Selection

```mermaid
flowchart LR
    L{Get-EffectiveLanguage} -->|stored en| ENL[en<br/>English]
    L -->|stored vi| VIM[vi<br/>full Unicode]
    L -->|stored vi-ascii| VIA[vi-ascii<br/>no diacritics]
    L -->|missing / unknown| FB{engine}
    FB -->|PS 5.1| VIA
    FB -->|PS 7| VIM
    G{Get-GuiLanguage<br/>WPF only} -->|stored mode| GM[same mode<br/>rendered as Unicode]
    TC{Terminal-Icons} -->|PS 5.1| SKIP[skipped]
    TC -->|PS 7| IMP[imported]
    PR{Set-PSReadLineOption -Prediction} -->|stdout redirected| SKIP2[skipped]
    PR -->|interactive| EN[enabled]
```

---

## 7. Windows Terminal Launch Path

```mermaid
flowchart TD
    WT[Windows Terminal opens defaultProfile] --> G{SET profile GUID}
    G -->|has commandline| RUN[run commandline<br/>pwsh.exe]
    G -->|no commandline<br/>Store install| BAD[falls back to cmd.exe<br/>prompt looks wrong]
    RUN --> PROF[$PROFILE loads]
    PROF --> ORDER[posh-git → starship]
    ORDER --> RENDER[Starship renders with<br/>Nerd Font glyphs]
```

This is the exact failure mode that motivated `commandline: pwsh.exe` plus the
posh-git/starship ordering rule.
