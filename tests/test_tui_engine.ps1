#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Contract Tests - TUI Engine (screen lifecycle, key conversion, guards)
.DESCRIPTION
    Verifies the terminal-facing shell without touching a real console or running any
    PSManager action:
      - Invoke-TuiScreen enters the alternate screen and always restores cursor,
        colours and the main screen, including when the body throws (AC-T6).
      - Convert-TuiKeyToString maps arrows, paging, Enter/Esc/Backspace/Tab/Shift+Tab.
      - Non-TTY invocations print help and never enter the interactive loop (AC-T10).
      - PSMGR_PLAIN routes to the linear plain mode, which never enters the
        alternate screen and dispatches the numbered action (AC-T10).
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
    Justification = 'Test doubles must mirror the production parameter names (Passphrase).')]
param()

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

Import-Module (Join-Path $RootDir "PSManager.psd1") -Force
. (Join-Path $RootDir "modules/UI/TuiCapabilities.ps1")
. (Join-Path $RootDir "modules/UI/TuiCatalog.ps1")
. (Join-Path $RootDir "modules/UI/TuiRender.ps1")
. (Join-Path $RootDir "modules/UI/TuiState.ps1")
. (Join-Path $RootDir "modules/UI/TuiEngine.ps1")

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Check {
    param([string]$Name, [scriptblock]$TestBlock)
    try {
        & $TestBlock
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $Name - $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add("$Name :: $($_.Exception.Message)")
    }
}

# ----------------------------------------------------------------------------
# Screen lifecycle
# ----------------------------------------------------------------------------
Assert-Check -Name "Alternate screen is restored after a normal body" -TestBlock {
    $esc = [char]27
    $log = [System.Collections.Generic.List[string]]::new()
    $writer = { param([string]$chunk) $log.Add($chunk) }.GetNewClosure()

    Invoke-TuiScreen -Writer $writer -Body { }

    $joined = $log -join ''
    if ($joined -notmatch [regex]::Escape("$esc[?1049h")) { throw 'Did not enter the alternate screen' }
    if ($joined -notmatch [regex]::Escape("$esc[?1049l")) { throw 'Did not leave the alternate screen' }
    if ($joined -notmatch [regex]::Escape("$esc[?25l")) { throw 'Cursor was not hidden on entry' }
    if ($joined -notmatch [regex]::Escape("$esc[?25h")) { throw 'Cursor was not restored on exit' }
    if ($joined -notmatch [regex]::Escape("$esc[0m")) { throw 'Colours were not reset on exit' }
    if ($log[$log.Count - 1] -ne "$esc[?1049l") { throw 'Alternate screen must be the last operation' }
}

Assert-Check -Name "Alternate screen is restored when the body throws (AC-T6)" -TestBlock {
    $esc = [char]27
    $log = [System.Collections.Generic.List[string]]::new()
    $writer = { param([string]$chunk) $log.Add($chunk) }.GetNewClosure()
    $threw = $false

    try {
        Invoke-TuiScreen -Writer $writer -Body { throw 'simulated failure' }
    } catch {
        $threw = $true
    }

    if (-not $threw) { throw 'Fixture did not throw' }
    $joined = $log -join ''
    if ($joined -notmatch [regex]::Escape("$esc[?1049l")) { throw 'Main screen was not restored after an exception' }
    if ($joined -notmatch [regex]::Escape("$esc[?25h")) { throw 'Cursor was not restored after an exception' }
    if ($joined -notmatch [regex]::Escape("$esc[0m")) { throw 'Colours were not reset after an exception' }
}

# ----------------------------------------------------------------------------
# Key conversion
# ----------------------------------------------------------------------------
Assert-Check -Name "Convert-TuiKeyToString maps navigation and editing keys" -TestBlock {
    $cases = @(
        @{ Key = [ConsoleKey]::UpArrow;    Char = [char]0; Expected = 'Up' }
        @{ Key = [ConsoleKey]::DownArrow;  Char = [char]0; Expected = 'Down' }
        @{ Key = [ConsoleKey]::PageUp;     Char = [char]0; Expected = 'PgUp' }
        @{ Key = [ConsoleKey]::PageDown;   Char = [char]0; Expected = 'PgDn' }
        @{ Key = [ConsoleKey]::Home;       Char = [char]0; Expected = 'Home' }
        @{ Key = [ConsoleKey]::End;        Char = [char]0; Expected = 'End' }
        @{ Key = [ConsoleKey]::Enter;      Char = [char]13; Expected = 'Enter' }
        @{ Key = [ConsoleKey]::Escape;     Char = [char]27; Expected = 'Esc' }
        @{ Key = [ConsoleKey]::Backspace;  Char = [char]8; Expected = 'Backspace' }
        @{ Key = [ConsoleKey]::A;          Char = 'a'; Expected = 'a' }
        @{ Key = [ConsoleKey]::D0;         Char = '0'; Expected = '0' }
        @{ Key = [ConsoleKey]::Oem2; Char = '?'; Expected = '?' }
    )

    foreach ($case in $cases) {
        $info = [ConsoleKeyInfo]::new([char]$case.Char, [ConsoleKey]$case.Key, $false, $false, $false)
        $actual = Convert-TuiKeyToString -KeyInfo $info
        if ($actual -ne $case.Expected) {
            throw ("{0} mapped to '{1}', expected '{2}'" -f $case.Key, $actual, $case.Expected)
        }
    }

    $plainTab = [ConsoleKeyInfo]::new([char]9, [ConsoleKey]::Tab, $false, $false, $false)
    if ((Convert-TuiKeyToString -KeyInfo $plainTab) -ne 'Tab') { throw 'Tab did not map to Tab' }

    $shiftTab = [ConsoleKeyInfo]::new([char]9, [ConsoleKey]::Tab, $true, $false, $false)
    if ((Convert-TuiKeyToString -KeyInfo $shiftTab) -ne 'ShiftTab') { throw 'Shift+Tab did not map to ShiftTab' }
}

# ----------------------------------------------------------------------------
# Guards: non-TTY and plain mode
# ----------------------------------------------------------------------------
Assert-Check -Name "Non-TTY Show-TUI prints help and never enters the interactive loop" -TestBlock {
    $script:helpCalled = $false
    $script:actionCalled = $false

    function Get-TuiCapabilities {
        param([hashtable]$Override = @{})
        return @{ IsTty = $false; PlainMode = $false; HasUnicode = $false; HasColor = $false; Width = 80; Height = 24; Symbols = @{ HLine = '-' }; Colors = @{ Cyan = '' } }
    }
    function Show-PSManagerHelp { $script:helpCalled = $true }
    function Invoke-TuiActionById { param($Id, $Language) $script:actionCalled = $true; return @{ Ok = $true; Errors = @() } }

    $null = Show-TUI 6>&1

    if (-not $script:helpCalled) { throw 'Help was not printed for a non-TTY invocation' }
    if ($script:actionCalled) { throw 'An action ran without a TTY' }
}

Assert-Check -Name "Console without VT falls back to plain mode" -TestBlock {
    $script:plainFallbackCalled = $false
    $script:actionCalled = $false

    function Get-TuiCapabilities {
        param([hashtable]$Override = @{})
        return @{ IsTty = $true; PlainMode = $false; HasVt = $false; HasUnicode = $false; HasColor = $false; Width = 80; Height = 24; Symbols = @{ HLine = '-' }; Colors = @{ Cyan = '' } }
    }
    function Show-TuiPlain { param([hashtable]$Caps) $script:plainFallbackCalled = $true }
    function Invoke-TuiActionById { param($Id, $Language) $script:actionCalled = $true; return @{ Ok = $true; Errors = @() } }

    $null = Show-TUI 6>&1

    if (-not $script:plainFallbackCalled) { throw 'Show-TUI did not fall back to plain mode without VT' }
    if ($script:actionCalled) { throw 'An action ran on a console without VT' }
}

# Stubs are dot-sourced inside each check so the definitions land in that check's
# scope (functions defined inside a helper function disappear when it returns).
$script:PlainStubBlock = {
    $script:plainActions = [System.Collections.Generic.List[string]]::new()
    $script:answers = [System.Collections.Generic.Queue[string]]::new()
    foreach ($a in $script:plainAnswerList) { $script:answers.Enqueue($a) }

    function Get-TuiCapabilities {
        param([hashtable]$Override = @{})
        return @{ IsTty = $true; PlainMode = $true; HasUnicode = $false; HasColor = $false; Width = 80; Height = 24; Symbols = @{ HLine = '-' }; Colors = @{ Cyan = '' } }
    }
    function Invoke-TuiActionById { param($Id, $Language) $script:plainActions.Add($Id); return @{ Ok = $true; Errors = @() } }
    function Read-TuiInput {
        param([string]$Prompt, [switch]$AsSecureString)
        if ($script:answers.Count -eq 0) { return $null }
        return $script:answers.Dequeue()
    }
}

Assert-Check -Name "PSMGR_PLAIN previews reversible actions and cancels by default" -TestBlock {
    $script:plainAnswerList = @('1', '', 'q')
    . $script:PlainStubBlock
    $null = Show-TUI 6>&1
    if ($script:plainActions.Count -ne 0) {
        throw ("Undoable action ran without a 'y' answer: {0}" -f ($script:plainActions -join ','))
    }
}

Assert-Check -Name "PSMGR_PLAIN applies a reversible action after an explicit y" -TestBlock {
    $script:plainAnswerList = @('1', 'y', 'q')
    . $script:PlainStubBlock
    $null = Show-TUI 6>&1
    if ($script:plainActions.Count -ne 1) { throw ("Expected 1 dispatched action, got {0}" -f $script:plainActions.Count) }
    $expectedFirst = (Get-TuiCatalog -Language (Get-EffectiveLanguage))[0].Id
    if ($script:plainActions[0] -ne $expectedFirst) {
        throw ("Dispatched '{0}', expected '{1}'" -f $script:plainActions[0], $expectedFirst)
    }
}

Assert-Check -Name "PSMGR_PLAIN destructive action needs y (declined first)" -TestBlock {
    # Plain numbering follows the catalog order; derive it so a new action cannot stale the test.
    $catalogIds = @((Get-TuiCatalog -Language 'en').Id)
    $cleanBackupsIndex = [array]::IndexOf($catalogIds, 'clean-backups') + 1
    if ($cleanBackupsIndex -lt 1) { throw 'clean-backups is missing from the TUI catalog' }
    $script:plainAnswerList = @([string]$cleanBackupsIndex, 'n', 'q')
    . $script:PlainStubBlock
    $null = Show-TUI 6>&1
    if ($script:plainActions.Count -ne 0) { throw 'Destructive action ran after a declined confirmation' }

    $script:plainAnswerList = @([string]$cleanBackupsIndex, 'y', 'q')
    . $script:PlainStubBlock
    $null = Show-TUI 6>&1
    if ($script:plainActions.Count -ne 1 -or $script:plainActions[0] -ne 'clean-backups') {
        throw ("Expected clean-backups after y, got: {0}" -f ($script:plainActions -join ','))
    }
}

# ----------------------------------------------------------------------------
# Encryption safety: a mismatched confirmation must never produce plaintext
# ----------------------------------------------------------------------------
function New-TestSecureString {
    param([string]$Text)
    $ss = [System.Security.SecureString]::new()
    foreach ($ch in $Text.ToCharArray()) { $ss.AppendChar($ch) }
    return $ss
}

Assert-Check -Name "Passphrase helper is exported by the module (engine can resolve it)" -TestBlock {
    $cmd = Get-Command Test-PSManagerPassphrase -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'Test-PSManagerPassphrase is not resolvable, so encrypted backup would throw' }
    $same1 = New-TestSecureString 'secret'
    $same2 = New-TestSecureString 'secret'
    $typo = New-TestSecureString 'secreT'
    if (-not (Test-PSManagerPassphrase -First $same1 -Second $same2)) { throw 'identical passphrases did not match' }
    if (Test-PSManagerPassphrase -First $same1 -Second $typo) { throw 'mismatched passphrases matched' }
}

Assert-Check -Name "Encrypted profile backup aborts on mismatch (no plaintext archive)" -TestBlock {
    $script:backupCalls = 0
    $script:lastPassphrase = $null
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue('y')
    $queue.Enqueue((New-TestSecureString 'pw-one'))
    $queue.Enqueue((New-TestSecureString 'pw-two'))

    function Read-TuiInput {
        param([string]$Prompt, [switch]$AsSecureString)
        if ($queue.Count -eq 0) { return $null }
        return $queue.Dequeue()
    }
    function Backup-PSManagerProfiles {
        param($Passphrase)
        $script:backupCalls++
        $script:lastPassphrase = $Passphrase
        return 'archive.zip'
    }

    $r = Invoke-TuiActionById -Id 'backup' -Language 'en'
    if ($script:backupCalls -ne 0) { throw ("Backup ran {0} time(s) despite the mismatch" -f $script:backupCalls) }
    if ($r.Ok) { throw 'Mismatch was reported as success' }
}

Assert-Check -Name "Encrypted profile backup proceeds with the real passphrase on match" -TestBlock {
    $script:backupCalls = 0
    $script:lastPassphrase = $null
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue('y')
    $queue.Enqueue((New-TestSecureString 'same'))
    $queue.Enqueue((New-TestSecureString 'same'))

    function Read-TuiInput {
        param([string]$Prompt, [switch]$AsSecureString)
        if ($queue.Count -eq 0) { return $null }
        return $queue.Dequeue()
    }
    function Backup-PSManagerProfiles {
        param($Passphrase)
        $script:backupCalls++
        $script:lastPassphrase = $Passphrase
        return 'archive.zip'
    }

    $r = Invoke-TuiActionById -Id 'backup' -Language 'en'
    if ($script:backupCalls -ne 1) { throw ("Expected exactly 1 backup call, got {0}" -f $script:backupCalls) }
    if ($null -eq $script:lastPassphrase) { throw 'Backup received a null passphrase despite a confirmed match' }
    if (-not $r.Ok) { throw 'Matched passphrase was reported as failure' }
}

Assert-Check -Name "Cloud backup aborts on mismatch (no plaintext upload)" -TestBlock {
    $script:cloudCalls = 0
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue('')                       # default = encrypt
    $queue.Enqueue((New-TestSecureString 'pw-one'))
    $queue.Enqueue((New-TestSecureString 'pw-two'))

    function Read-TuiInput {
        param([string]$Prompt, [switch]$AsSecureString)
        if ($queue.Count -eq 0) { return $null }
        return $queue.Dequeue()
    }
    function Publish-PSManagerCloudBackup {
        param($Passphrase)
        $script:cloudCalls++
        return [pscustomobject]@{ Tag = 't'; Url = 'u'; Encrypted = $true }
    }

    $r = Invoke-TuiActionById -Id 'backup-cloud' -Language 'en'
    if ($script:cloudCalls -ne 0) { throw ("Publish ran {0} time(s) despite the mismatch" -f $script:cloudCalls) }
    if ($r.Ok) { throw 'Mismatch was reported as success' }
}

Assert-Check -Name "Encrypted backup aborts when the passphrase is empty" -TestBlock {
    $script:backupCalls = 0
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue('y')
    $queue.Enqueue((New-TestSecureString ''))
    $queue.Enqueue((New-TestSecureString ''))

    function Read-TuiInput {
        param([string]$Prompt, [switch]$AsSecureString)
        if ($queue.Count -eq 0) { return $null }
        return $queue.Dequeue()
    }
    function Backup-PSManagerProfiles {
        param($Passphrase)
        $script:backupCalls++
        return 'archive.zip'
    }

    $r = Invoke-TuiActionById -Id 'backup' -Language 'en'
    if ($script:backupCalls -ne 0) { throw 'Backup ran with an empty passphrase after encryption was requested' }
    if ($r.Ok) { throw 'Empty passphrase was reported as success' }
}

# ----------------------------------------------------------------------------
# Language cycling: explicit en -> vi-ascii -> vi -> en
# ----------------------------------------------------------------------------
Assert-Check -Name "TUI language cycle is en -> vi-ascii -> vi -> en" -TestBlock {
    $cases = @(
        @{ Current = 'en';       Expected = 'vi-ascii' }
        @{ Current = 'vi-ascii'; Expected = 'vi' }
        @{ Current = 'vi';       Expected = 'en' }
    )

    foreach ($case in $cases) {
        $actual = Get-TuiNextLanguage -Language $case.Current
        if ($actual -ne $case.Expected) {
            throw ("'{0}' cycled to '{1}', expected '{2}'" -f $case.Current, $actual, $case.Expected)
        }
    }
}

Assert-Check -Name "Language cycle persists every mode and refreshes with the effective language" -TestBlock {
    $script:persistedLanguage = 'en'
    $script:setLanguages = [System.Collections.Generic.List[string]]::new()
    $script:groupLanguages = [System.Collections.Generic.List[string]]::new()
    $script:catalogLanguages = [System.Collections.Generic.List[string]]::new()

    function Set-PSManagerConfig {
        param([string]$Language)
        $script:setLanguages.Add($Language)
        $script:persistedLanguage = $Language
        return [pscustomobject]@{ language = $Language }
    }
    function Get-PSManagerConfig {
        return [pscustomobject]@{ updateSource = 'winget'; channel = 'stable'; language = $script:persistedLanguage }
    }
    function Get-EffectiveLanguage {
        # Simulate a runtime whose rendering mode differs from the stored preference.
        if ($script:persistedLanguage -eq 'vi') { return 'vi-ascii' }
        return $script:persistedLanguage
    }
    function Get-TuiGroups {
        param([string]$Language)
        $script:groupLanguages.Add($Language)
        return @()
    }
    function Get-TuiCatalog {
        param([string]$Language)
        $script:catalogLanguages.Add($Language)
        return @()
    }

    $state = @{
        Config   = [pscustomobject]@{ language = 'en' }
        Language = 'en'
        Groups   = @()
        Catalog  = @()
    }

    $steps = @(
        @{ Persisted = 'vi-ascii'; Effective = 'vi-ascii' }
        @{ Persisted = 'vi';       Effective = 'vi-ascii' }
        @{ Persisted = 'en';       Effective = 'en' }
    )
    foreach ($step in $steps) {
        $state = Update-TuiLanguageCycle -State $state
        if ($script:persistedLanguage -ne $step.Persisted) {
            throw ("Persisted language '{0}', expected '{1}'" -f $script:persistedLanguage, $step.Persisted)
        }
        if ($state.Language -ne $step.Effective) {
            throw ("Screen language '{0}', expected '{1}'" -f $state.Language, $step.Effective)
        }
        if ($script:groupLanguages[$script:groupLanguages.Count - 1] -ne $step.Effective) {
            throw ("Groups were refreshed for '{0}', expected '{1}'" -f $script:groupLanguages[$script:groupLanguages.Count - 1], $step.Effective)
        }
        if ($script:catalogLanguages[$script:catalogLanguages.Count - 1] -ne $step.Effective) {
            throw ("Catalog was refreshed for '{0}', expected '{1}'" -f $script:catalogLanguages[$script:catalogLanguages.Count - 1], $step.Effective)
        }
    }

    if (($script:setLanguages -join ',') -ne 'vi-ascii,vi,en') {
        throw ("Cycled '{0}', expected 'vi-ascii,vi,en'" -f ($script:setLanguages -join ','))
    }
}

if ($failures.Count -gt 0) {
    Write-Host ("`n[FAIL] TUI engine tests failed with " + $failures.Count + " failure(s).") -ForegroundColor Red
    exit 1
}

Write-Host "`n[PASS] test_tui_engine.ps1 passed all checks" -ForegroundColor Green
exit 0
