#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Profile Compatibility Auditor & Repair Engine
.DESCRIPTION
    Validates, audits, and repairs PowerShell profiles for version-specific
    compatibility across Windows PowerShell 5.1 (Desktop) and PowerShell 7+ (Core).
#>

function Get-PSManagerProfileTargets {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[pscustomobject]])]
    param(
        [ValidateSet('5.1', '7', 'All')]
        [string]$TargetVersion = 'All'
    )

    $docs = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments)
    $targets = [System.Collections.Generic.List[pscustomobject]]::new()

    if ($TargetVersion -in @('5.1', 'All')) {
        $ps5Path = Join-Path $docs "WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
        $targets.Add([pscustomobject]@{
            Version = '5.1'
            Name    = 'Windows PowerShell 5.1'
            Path    = $ps5Path
        })
    }

    if ($TargetVersion -in @('7', 'All')) {
        $ps7Path = Join-Path $docs "PowerShell\Microsoft.PowerShell_profile.ps1"
        $targets.Add([pscustomobject]@{
            Version = '7'
            Name    = 'PowerShell 7 (Core)'
            Path    = $ps7Path
        })
    }

    return $targets
}

function Test-ProfileBlockEnclosing {
    <#
    .SYNOPSIS
        Brace-aware check: is the anchor lexically inside a block opened by OpenPattern?
    .DESCRIPTION
        Naive [^}]* regexes break on nested braces. This walks the text between the
        nearest preceding opener and the anchor, counting braces so nesting is honoured.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$AnchorPattern,
        [Parameter(Mandatory = $true)][string]$OpenPattern,
        [int]$MaxLookback = 2000
    )

    $anchor = [regex]::Match($Content, $AnchorPattern)
    if (-not $anchor.Success -or $anchor.Index -eq 0) { return $false }

    $prefix = $Content.Substring(0, $anchor.Index)
    $openers = [regex]::Matches($prefix, $OpenPattern)
    if ($openers.Count -eq 0) { return $false }

    $opener = $openers[$openers.Count - 1]
    $segmentStart = $opener.Index + $opener.Length
    if (($anchor.Index - $segmentStart) -gt $MaxLookback) { return $false }

    $segment = $Content.Substring($segmentStart, $anchor.Index - $segmentStart)
    # Walk braces; the block closes (and the anchor is outside it) the moment
    # the running balance drops below zero.
    $balance = 1
    foreach ($ch in $segment.ToCharArray()) {
        if ($ch -eq '{') { $balance++ }
        elseif ($ch -eq '}') { $balance--; if ($balance -lt 0) { return $false } }
    }
    return $true
}

function Get-ProfilePs7OnlyConstructs {
    <#
    .SYNOPSIS
        Lists PowerShell 7-only operators present in a profile body.
    .DESCRIPTION
        Uses the tokenizer so '?' characters inside string literals or comments are
        never mistaken for operators. On Windows PowerShell 5.1 these constructs do
        not tokenize at all and instead surface as AST parse errors.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $found = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Content)) { return $found.ToArray() }

    $tokens = $null
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errs) | Out-Null
    if (-not $tokens) { return $found.ToArray() }

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $kind = $tokens[$i].Kind.ToString()
        switch ($kind) {
            'QuestionQuestion'       { $found.Add('null-coalescing (??)'); break }
            'QuestionQuestionEquals' { $found.Add('null-coalescing assignment (??=)'); break }
            'QuestionMark'           { $found.Add('ternary conditional (?:)'); break }
            'AndAnd'                 { $found.Add('pipeline chain (&&)'); break }
            'OrOr'                   { $found.Add('pipeline chain (||)'); break }
            'Variable' {
                # '$obj?.Prop' tokenizes as Variable '$obj?' followed by Dot.
                if ($tokens[$i].Text.EndsWith('?') -and ($i + 1) -lt $tokens.Count -and
                    $tokens[$i + 1].Kind.ToString() -eq 'Dot') {
                    $found.Add('null-conditional (?.)')
                }
                break
            }
        }
    }

    return @($found | Sort-Object -Unique)
}

function Test-PSManagerProfile {
    <#
    .SYNOPSIS
        Audits PowerShell profiles for syntax, module ordering, and version compatibility.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [ValidateSet('5.1', '7', 'All')]
        [string]$TargetVersion = 'All',

        [string]$ProfilePath
    )

    $checks = [System.Collections.Generic.List[pscustomobject]]::new()
    $targets = if ($ProfilePath) {
        @([pscustomobject]@{
            Version = if ($TargetVersion -eq 'All') { '5.1' } else { $TargetVersion }
            Name    = "Target ($ProfilePath)"
            Path    = Resolve-NormalizedPath -Path $ProfilePath
        })
    } else {
        Get-PSManagerProfileTargets -TargetVersion $TargetVersion
    }

    foreach ($t in $targets) {
        $ver = $t.Version
        $name = $t.Name
        $path = $t.Path

        # Check 1: Existence
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $checks.Add([pscustomobject]@{
                Category       = "Profile ($ver)"
                Item           = "File Existence"
                Status         = "WARN"
                Details        = "Profile does not exist: $path"
                Recommendation = "Run 'psmgr sync' to scaffold profile"
            })
            continue
        }

        $checks.Add([pscustomobject]@{
            Category       = "Profile ($ver)"
            Item           = "File Existence"
            Status         = "PASS"
            Details        = "Found at $path"
            Recommendation = "None"
        })

        # Check 2: AST Syntax Parsing
        $tokens = $null
        $errs = $null
        $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errs) | Out-Null

        if ($errs -and $errs.Count -gt 0) {
            $errMsg = ($errs | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join "; "
            $checks.Add([pscustomobject]@{
                Category       = "Profile ($ver)"
                Item           = "AST Syntax"
                Status         = "FAIL"
                Details        = "Syntax error(s): $errMsg"
                Recommendation = "Fix syntax error or run 'psmgr audit-profile -Fix'"
            })
        } else {
            $checks.Add([pscustomobject]@{
                Category       = "Profile ($ver)"
                Item           = "AST Syntax"
                Status         = "PASS"
                Details        = "Valid PowerShell syntax"
                Recommendation = "None"
            })
        }

        # Check 3: Prohibited PS7 operators on PS 5.1 target.
        # Token-based, not regex-based: a regex over raw text false-positives on
        # '?' inside string literals (e.g. '^--?model(=|$)').
        if ($ver -eq '5.1') {
            $disallowedFound = @(Get-ProfilePs7OnlyConstructs -Content $content)
            if ($disallowedFound.Count -gt 0) {
                $checks.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "PS 5.1 Syntax Compatibility"
                    Status         = "FAIL"
                    Details        = "Contains PS7-only operators: $($disallowedFound -join ', ')"
                    Recommendation = "Replace PS7 operators with if/else or run 'psmgr audit-profile -Fix'"
                })
            } else {
                $checks.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "PS 5.1 Syntax Compatibility"
                    Status         = "PASS"
                    Details        = "No prohibited PS7-only operators detected"
                    Recommendation = "None"
                })
            }
        }

        # Check 4: Module Load Ordering (posh-git must load before starship)
        $hasPosh = ($content -match 'Import-Module\s+posh-git')
        $hasStarship = ($content -match 'starship\s+init')
        if ($hasPosh -and $hasStarship) {
            $poshIdx = $content.IndexOf("posh-git")
            $starshipIdx = $content.IndexOf("starship init")
            if ($poshIdx -gt $starshipIdx) {
                $checks.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "Module Load Order"
                    Status         = "FAIL"
                    Details        = "posh-git is imported after starship, overwriting starship's prompt function"
                    Recommendation = "Import posh-git before invoking starship init, or run 'psmgr audit-profile -Fix'"
                })
            } else {
                $checks.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "Module Load Order"
                    Status         = "PASS"
                    Details        = "posh-git correctly imported before starship prompt initialization"
                    Recommendation = "None"
                })
            }
        }

        # Check 5: Terminal-Icons Compatibility Guard on PS 5.1
        if ($ver -eq '5.1' -and ($content -match 'Import-Module\s+Terminal-Icons')) {
            $isGuarded = Test-ProfileBlockEnclosing -Content $content `
                -AnchorPattern 'Import-Module\s+Terminal-Icons' `
                -OpenPattern 'if\s*\(\s*\$PSVersionTable\.PSVersion\.Major\s+-ge\s+7[^\r\n{]*\{'
            if (-not $isGuarded) {
                $checks.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "Terminal-Icons Guard"
                    Status         = "FAIL"
                    Details        = "Terminal-Icons imported without PS7 runtime guard; crashes on PS 5.1"
                    Recommendation = "Wrap Import-Module Terminal-Icons in PSVersion check or run 'psmgr audit-profile -Fix'"
                })
            } else {
                $checks.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "Terminal-Icons Guard"
                    Status         = "PASS"
                    Details        = "Terminal-Icons safely guarded with PS7 version check"
                    Recommendation = "None"
                })
            }
        }

        # Check 6: PSReadLine Prediction Crash Guard
        if ($content -match 'Set-PSReadLineOption\s+-Prediction') {
            $isProtected = Test-ProfileBlockEnclosing -Content $content `
                -AnchorPattern 'Set-PSReadLineOption\s+-Prediction' `
                -OpenPattern 'try\s*\{'
            if (-not $isProtected) {
                $checks.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "PSReadLine Prediction Guard"
                    Status         = "WARN"
                    Details        = "Set-PSReadLineOption -Prediction not enclosed in try/catch; throws in non-interactive sessions"
                    Recommendation = "Enclose prediction options in try/catch or run 'psmgr audit-profile -Fix'"
                })
            } else {
                $checks.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "PSReadLine Prediction Guard"
                    Status         = "PASS"
                    Details        = "PSReadLine prediction options enclosed in error guard"
                    Recommendation = "None"
                })
            }
        }
        # Check 7: STARSHIP_CONFIG Environment Variable Target
        $userStarshipCfg = [System.Environment]::GetEnvironmentVariable('STARSHIP_CONFIG', [System.EnvironmentVariableTarget]::User)
        if ($userStarshipCfg) {
            $cfgExists = Test-Path -LiteralPath $userStarshipCfg -PathType Leaf
            if (-not $cfgExists) {
                $checks.Add([pscustomobject]@{
                    Category       = "Environment"
                    Item           = "STARSHIP_CONFIG (User)"
                    Status         = "FAIL"
                    Details        = "Points to non-existent file: $userStarshipCfg"
                    Recommendation = "Run 'psmgr audit-profile -Fix' to restore to ~/.config/starship.toml"
                })
            } else {
                $checks.Add([pscustomobject]@{
                    Category       = "Environment"
                    Item           = "STARSHIP_CONFIG (User)"
                    Status         = "PASS"
                    Details        = "Valid file ($userStarshipCfg)"
                    Recommendation = "None"
                })
            }
        }

        # Check 8: Payload Link Safety. A live profile may share an inode with
        # the repo payload template; any editor save would then rewrite the
        # tracked file too. Report the real peers instead of guessing.
        $repoRoot = if ($PSScriptRoot) {
            Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        } else {
            Join-Path $env:USERPROFILE "tools\ps-manager"
        }
        $payloadRoot = $repoRoot
        $linkStatus = 'PASS'
        $linkDetails = 'Independent file (no shared hard link)'
        $linkRecommendation = 'None'
        $peers = @()
        if (Get-Command Get-HardLinkPaths -ErrorAction SilentlyContinue) {
            $peers = @(Get-HardLinkPaths -Path $path)
        }

        if ($peers.Count -eq 0) {
            $linkDetails = 'Link state unknown (fsutil unavailable on this host)'
        } elseif ($peers.Count -gt 1) {
            # fsutil prints volume-relative paths ("\Users\..."), so compare with
            # the drive letter stripped instead of matching on the leaf name.
            $selfNorm = (([System.IO.Path]::GetFullPath($path)) -replace '^[A-Za-z]:', '').Replace('/', '\').ToLowerInvariant()
            $others = @($peers | Where-Object { $_.Replace('/', '\').ToLowerInvariant() -ne $selfNorm })
            if ($others.Count -eq 0) { $others = @($peers) }
            $touchesPayload = @($peers | Where-Object { $_.Replace('/', '\') -like '*\templates\profiles\*' }).Count -gt 0

            $linkDetails = "Shares a hard link with: " + ($others -join ', ')
            if ($touchesPayload) {
                $linkStatus = 'WARN'
                $linkRecommendation = ("Editing this profile also rewrites the repo payload under " +
                    "$payloadRoot\templates\profiles. Run 'psmgr audit-profile -Fix' to detach it.")
            } else {
                $linkRecommendation = 'None'
            }
        }
        $checks.Add([pscustomobject]@{
            Category       = "Profile ($ver)"
            Item           = "Payload Link Safety"
            Status         = $linkStatus
            Details        = $linkDetails
            Recommendation = $linkRecommendation
        })

    }

    return $checks.ToArray()
}

function Repair-PSManagerProfile {
    <#
    .SYNOPSIS
        Repairs PowerShell profile files to ensure dual-runtime compatibility across PS 5.1 and PS 7.
    #>
    [CmdletBinding()]
    [OutputType([array])]
    param(
        [ValidateSet('5.1', '7', 'All')]
        [string]$TargetVersion = 'All',

        [string]$ProfilePath,

        [switch]$Backup
    )

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $targets = if ($ProfilePath) {
        @([pscustomobject]@{
            Version = if ($TargetVersion -eq 'All') { '5.1' } else { $TargetVersion }
            Name    = "Target ($ProfilePath)"
            Path    = Resolve-NormalizedPath -Path $ProfilePath
        })
    } else {
        Get-PSManagerProfileTargets -TargetVersion $TargetVersion
    }

    # 1. Fix broken STARSHIP_CONFIG User environment variable if pointing to invalid file
    $userStarshipCfg = [System.Environment]::GetEnvironmentVariable('STARSHIP_CONFIG', [System.EnvironmentVariableTarget]::User)
    if ($userStarshipCfg -and -not (Test-Path -LiteralPath $userStarshipCfg -PathType Leaf)) {
        $realCfg = Join-Path $env:USERPROFILE ".config\starship.toml"
        [System.Environment]::SetEnvironmentVariable('STARSHIP_CONFIG', $realCfg, [System.EnvironmentVariableTarget]::User)
        [System.Environment]::SetEnvironmentVariable('STARSHIP_CONFIG', $realCfg, [System.EnvironmentVariableTarget]::Process)
        $results.Add([pscustomobject]@{
            Category       = "Environment"
            Item           = "STARSHIP_CONFIG"
            Status         = "FIXED"
            Details        = "Restored invalid path to $realCfg"
            Recommendation = "None"
        })
    }

    foreach ($t in $targets) {
        $ver = $t.Version
        $name = $t.Name
        $path = $t.Path

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $dir = Split-Path -Parent $path
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            # Scaffold the canonical master profile from the repo payload,
            # resolved relative to this module rather than a hardcoded path.
            $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $canonicalSrc = Join-Path $repoRoot "templates\profiles\master_profile.ps1"
            if (Test-Path -LiteralPath $canonicalSrc) {
                Copy-Item -LiteralPath $canonicalSrc -Destination $path -Force
                $results.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "Scaffold Profile"
                    Status         = "FIXED"
                    Details        = "Created clean profile from master template"
                    Recommendation = "None"
                })
            }
            continue
        }

        # Always back up before mutation (mandatory per repo policy; -Backup is
        # accepted for callers that document intent explicitly).
        $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
        $bakPath = "$path.bak.$timestamp"
        Copy-Item -LiteralPath $path -Destination $bakPath -Force

        $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $modified = $false

        # Fix 1: Module ordering (ensure posh-git imports before starship init)
        $hasPosh = ($content -match 'Import-Module\s+posh-git')
        $hasStarship = ($content -match 'starship\s+init')
        if ($hasPosh -and $hasStarship) {
            $poshIdx = $content.IndexOf("posh-git")
            $starshipIdx = $content.IndexOf("starship init")
            if ($poshIdx -gt $starshipIdx) {
                # Extract posh-git block and reinsert before starship
                $content = $content -replace '(?ms)^#*\s*-*\s*#*\s*posh-git.*?Import-Module\s+posh-git.*?\r?\n\}?\r?\n?', ''
                $poshBlock = "`r`n# -----------------------------`r`n# posh-git (Must load before Starship)`r`n# -----------------------------`r`nif (Get-Module -ListAvailable posh-git) {`r`n    Import-Module posh-git -ErrorAction SilentlyContinue`r`n}`r`n"
                $starshipAnchor = "(?m)^(#*\s*-*\s*#*\s*Starship)"
                if ($content -match $starshipAnchor) {
                    $content = $content -replace $starshipAnchor, ($poshBlock + '$1')
                } else {
                    $content = $poshBlock + $content
                }
                $modified = $true
                $results.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "Module Load Order"
                    Status         = "FIXED"
                    Details        = "Reordered posh-git to load before starship prompt"
                    Recommendation = "None"
                })
            }
        }

        # Fix 2: Guard Terminal-Icons with PS7 check on PS 5.1
        if ($ver -eq '5.1' -and ($content -match 'Import-Module\s+Terminal-Icons')) {
            $isGuarded = Test-ProfileBlockEnclosing -Content $content `
                -AnchorPattern 'Import-Module\s+Terminal-Icons' `
                -OpenPattern 'if\s*\(\s*\$PSVersionTable\.PSVersion\.Major\s+-ge\s+7[^\r\n{]*\{'
            if (-not $isGuarded) {
                $guardedBlock = 'if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Module -ListAvailable Terminal-Icons)) { Import-Module Terminal-Icons -ErrorAction SilentlyContinue }'
                $content = $content -replace '(?m)^\s*Import-Module\s+Terminal-Icons.*$', $guardedBlock
                $modified = $true
                $results.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "Terminal-Icons Guard"
                    Status         = "FIXED"
                    Details        = "Enclosed Terminal-Icons in PS7 version check"
                    Recommendation = "None"
                })
            }
        }

        # Fix 3: Enclose Set-PSReadLineOption prediction in try/catch
        if ($content -match 'Set-PSReadLineOption\s+-Prediction') {
            $isProtected = Test-ProfileBlockEnclosing -Content $content `
                -AnchorPattern 'Set-PSReadLineOption\s+-Prediction' `
                -OpenPattern 'try\s*\{'
            if (-not $isProtected) {
                $content = $content -replace '(?m)^\s*(Set-PSReadLineOption\s+-PredictionSource\s+[^\r\n]+)', 'try { if (-not [Console]::IsOutputRedirected) { $1 } } catch {}'
                $content = $content -replace '(?m)^\s*(Set-PSReadLineOption\s+-PredictionViewStyle\s+[^\r\n]+)', 'try { if (-not [Console]::IsOutputRedirected) { $1 } } catch {}'
                $modified = $true
                $results.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "PSReadLine Prediction Guard"
                    Status         = "FIXED"
                    Details        = "Wrapped prediction options in error & redirect guard"
                    Recommendation = "None"
                })
            }
        }

        $peers = @()
        if (Get-Command Get-HardLinkPaths -ErrorAction SilentlyContinue) {
            $peers = @(Get-HardLinkPaths -Path $path)
        }
        $touchesPayload = @($peers | Where-Object { $_.Replace('/', '\') -like '*\templates\profiles\*' }).Count -gt 0

        if ($modified -or $touchesPayload) {
            $writeRes = Set-DetachedFileContent -Path $path -Content $content -Utf8Bom
            if ($writeRes.DetachedFromLink) {
                $results.Add([pscustomobject]@{
                    Category       = "Profile ($ver)"
                    Item           = "Link Safety"
                    Status         = "FIXED"
                    Details        = "Detached hardlink before writing so the payload template was not mutated"
                    Recommendation = "Re-run 'psmgr sync' to re-link if the change should be shared"
                })
            }
        }
    }

    if ($results.Count -eq 0) {
        $results.Add([pscustomobject]@{
            Category       = "Profile"
            Item           = "Profile Verification"
            Status         = "PASS"
            Details        = "All profiles are already compliant; no repairs needed"
            Recommendation = "None"
        })
    }

    return $results.ToArray()
}
