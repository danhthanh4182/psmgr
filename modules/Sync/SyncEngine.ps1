#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager End-to-End Profile Sync & Doctor Engine
.DESCRIPTION
    Orchestrates the entire hybrid synchronization lifecycle:
    parsing manifest, backing up profiles, provisioning packages,
    linking dotfiles, exporting env vars, and auditing environment health.
#>

function Resolve-SyncManifestPath {
    [CmdletBinding()]
    param(
        [string]$ManifestPath
    )

    if (-not [string]::IsNullOrEmpty($ManifestPath)) {
        return (Resolve-NormalizedPath -Path $ManifestPath)
    }

    $userDotfiles = Resolve-NormalizedPath -Path "~/.dotfiles/manifest.json"
    if (Test-Path -LiteralPath $userDotfiles) {
        return $userDotfiles
    }

    $baseDir = if ($PSScriptRoot) {
        Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    } else {
        Join-Path $env:USERPROFILE "tools\ps-manager"
    }
    return (Join-Path $baseDir "templates\manifest.default.json")
}

function Invoke-PSManagerSync {
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [string]$BasePayloadDir,
        [switch]$SkipPackages,
        [switch]$DryRun
    )

    $resolvedManifestPath = Resolve-SyncManifestPath -ManifestPath $ManifestPath

    if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
        return [pscustomobject]@{
            Success           = $false
            LinksProcessed    = 0
            PackagesProcessed = 0
            BackupFile        = $null
            Message           = "Manifest file not found: $resolvedManifestPath"
        }
    }

    $manifest = Read-SyncManifest -ManifestPath $resolvedManifestPath
    $validation = Test-SyncManifest -Manifest $manifest
    if (-not $validation.IsValid) {
        return [pscustomobject]@{
            Success           = $false
            LinksProcessed    = 0
            PackagesProcessed = 0
            BackupFile        = $null
            Message           = "Manifest schema validation failed: $($validation.Errors -join '; ')"
        }
    }

    $payloadDir = if (-not [string]::IsNullOrEmpty($BasePayloadDir)) {
        Resolve-NormalizedPath -Path $BasePayloadDir
    } else {
        Split-Path -Parent $resolvedManifestPath
    }

    # Step 1: Automatic Backup
    if (Get-Command Write-PSManagerLog -ErrorAction SilentlyContinue) {
        Write-PSManagerLog -Message "Starting PSManager Sync (Manifest: $resolvedManifestPath, DryRun: $DryRun)" -Level "INFO"
    }
    $backupZip = $null
    if (-not $DryRun) {
        try {
            $backupZip = Backup-PSManagerProfiles
        } catch {
            Write-Warning "Profile backup encountered warning: $($_.Exception.Message)"
        }
    }

    # Step 2: Multi-Package Provisioning
    $packagesCount = 0
    if (-not $SkipPackages) {
        if ($manifest.packages.winget -and ($manifest.packages.winget.Count -gt 0)) {
            $wRes = Install-WingetBatch -Packages $manifest.packages.winget -DryRun:$DryRun
            $packagesCount += $wRes.Total
        }
        if ($manifest.packages.scoop -and $manifest.packages.scoop.apps -and ($manifest.packages.scoop.apps.Count -gt 0)) {
            $sRes = Install-ScoopBatch -Buckets $manifest.packages.scoop.buckets -Apps $manifest.packages.scoop.apps -DryRun:$DryRun
            $packagesCount += $sRes.AppsTotal
        }
        if ($manifest.packages.psgallery -and ($manifest.packages.psgallery.Count -gt 0)) {
            $pRes = Install-PSGalleryBatch -Modules $manifest.packages.psgallery -DryRun:$DryRun
            $packagesCount += $pRes.Total
        }
    }

    # Step 3: Link Processing
    $linksCount = 0
    $linkFailures = [System.Collections.Generic.List[string]]::new()

    if ($manifest.links) {
        # Pre-flight: refuse to touch targets when a payload source is missing.
        $missingSources = @($manifest.links | Where-Object {
            $srcRelative = $_.source
            $srcFull = if ([System.IO.Path]::IsPathRooted($srcRelative)) { $srcRelative } else { Join-Path $payloadDir $srcRelative }
            -not (Test-Path -LiteralPath $srcFull -PathType Leaf)
        })
        if (-not $DryRun -and $missingSources.Count -gt 0) {
            $missingList = ($missingSources | ForEach-Object { $_.source }) -join ', '
            if (Get-Command Write-PSManagerLog -ErrorAction SilentlyContinue) {
                Write-PSManagerLog -Message "Sync aborted: missing payload sources: $missingList" -Level "ERROR"
            }
            return [pscustomobject]@{
                Success           = $false
                LinksProcessed    = 0
                PackagesProcessed = $packagesCount
                BackupFile        = $backupZip
                Message           = "Aborted before linking: payload source file(s) missing: $missingList (payload dir: $payloadDir)"
            }
        }

        foreach ($linkEntry in $manifest.links) {
            $srcRelative = $linkEntry.source
            $srcFull = if ([System.IO.Path]::IsPathRooted($srcRelative)) {
                $srcRelative
            } else {
                Join-Path $payloadDir $srcRelative
            }

            $linkType = if ($linkEntry.type) { $linkEntry.type } else { "hardlink" }

            foreach ($targetRaw in $linkEntry.targets) {
                $targetFull = Resolve-NormalizedPath -Path $targetRaw

                if ($DryRun) {
                    $linksCount++
                } else {
                    $linkRes = New-SafeLink -SourcePath $srcFull -TargetPath $targetFull -LinkType $linkType
                    if ($linkRes.Success) {
                        $linksCount++
                    } else {
                        $linkFailures.Add("$($srcFull) -> $($targetFull): $($linkRes.Message)")
                    }
                }
            }
        }
    }

    # Step 4: Environment Variables
    if ($manifest.env) {
        foreach ($prop in $manifest.env.PSObject.Properties) {
            $k = $prop.Name
            $rawVal = "$($prop.Value)"
            $v = if ($rawVal.StartsWith("~") -or $rawVal.StartsWith(".\") -or $rawVal.Contains("/") -or $rawVal.Contains("\")) {
                Resolve-NormalizedPath -Path $rawVal
            } else {
                [System.Environment]::ExpandEnvironmentVariables($rawVal)
            }

            [System.Environment]::SetEnvironmentVariable($k, $v, [System.EnvironmentVariableTarget]::Process)
            if (-not $DryRun) {
                [System.Environment]::SetEnvironmentVariable($k, $v, [System.EnvironmentVariableTarget]::User)
            }
        }
    }

    $allSuccess = ($linkFailures.Count -eq 0)
    $msg = if ($DryRun) {
        "Dry-run sync completed: $linksCount links planned, $packagesCount packages checked"
    } elseif ($allSuccess) {
        "Sync completed successfully: $linksCount links created/verified, $packagesCount packages processed"
    } else {
        "Sync completed with link warnings: $($linkFailures -join ' | ')"
    }

    if (Get-Command Write-PSManagerLog -ErrorAction SilentlyContinue) {
        $logLvl = if ($allSuccess) { "INFO" } else { "WARN" }
        Write-PSManagerLog -Message "Finished PSManager Sync: $msg" -Level $logLvl
    }

    return [pscustomobject]@{
        Success           = $allSuccess
        LinksProcessed    = $linksCount
        PackagesProcessed = $packagesCount
        BackupFile        = $backupZip
        Message           = $msg
    }
}

function Import-PSManagerProfiles {
    # Reverse adoption: copies live user profiles/configs into the payload sources
    # so they become the new source of truth, then re-synchronizes the remaining targets.
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string]$ManifestPath,
        [string]$BasePayloadDir
    )

    $resolvedManifestPath = Resolve-SyncManifestPath -ManifestPath $ManifestPath
    if (-not (Test-Path -LiteralPath $resolvedManifestPath -PathType Leaf)) {
        return [pscustomobject]@{
            Success = $false
            Adopted = 0
            AnyDiff = $false
            Message = "Manifest not found: $resolvedManifestPath"
            Details = @()
        }
    }

    $payloadDir = if (-not [string]::IsNullOrEmpty($BasePayloadDir)) {
        Resolve-NormalizedPath -Path $BasePayloadDir
    } else {
        Split-Path -Parent $resolvedManifestPath
    }

    $manifest = Read-SyncManifest -ManifestPath $resolvedManifestPath
    if (-not $manifest -or -not $manifest.links) {
        return [pscustomobject]@{
            Success = $false
            Adopted = 0
            AnyDiff = $false
            Message = "No links defined in manifest"
            Details = @()
        }
    }

    $adopted = 0
    $anyDiff = $false
    $details = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $manifest.links) {
        $srcFull = if ([System.IO.Path]::IsPathRooted($entry.source)) {
            $entry.source
        } else {
            Join-Path $payloadDir $entry.source
        }

        $primaryTarget = Resolve-NormalizedPath -Path $entry.targets[0]
        if (-not (Test-Path -LiteralPath $primaryTarget -PathType Leaf)) {
            $details.Add("Target missing: $primaryTarget (skipped)")
            continue
        }

        if ((Test-Path -LiteralPath $srcFull -PathType Leaf) -and
            (Test-FileIdentical -PathA $primaryTarget -PathB $srcFull)) {
            continue
        }

        $anyDiff = $true
        if (Test-Path -LiteralPath $srcFull -PathType Leaf) {
            $backupPath = "$srcFull.bak." + (Get-Date).ToString('yyyyMMdd_HHmmss')
            Copy-Item -LiteralPath $srcFull -Destination $backupPath -Force
            $details.Add("Backup created: $backupPath")
        }

        $srcDir = Split-Path -Parent $srcFull
        if (-not (Test-Path -LiteralPath $srcDir)) {
            New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
        }

        Copy-Item -LiteralPath $primaryTarget -Destination $srcFull -Force
        $details.Add("Adopted: $primaryTarget -> $srcFull")
        $adopted++
    }

    if ($anyDiff) {
        $syncRes = Invoke-PSManagerSync -ManifestPath $resolvedManifestPath -BasePayloadDir $payloadDir -SkipPackages
        return [pscustomobject]@{
            Success = $true
            Adopted = $adopted
            AnyDiff = $true
            Message = "Successfully adopted $adopted profile(s) into payload. Relink: $($syncRes.Message)"
            Details = $details.ToArray()
        }
    } else {
        return [pscustomobject]@{
            Success = $true
            Adopted = 0
            AnyDiff = $false
            Message = "Nothing to adopt: live profiles are already identical to payload sources."
            Details = @()
        }
    }
}

New-Alias -Name 'Adopt-PSManagerProfiles' -Value 'Import-PSManagerProfiles' -Force -ErrorAction SilentlyContinue

function Invoke-PSManagerDoctor {
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [string]$BasePayloadDir,
        [switch]$Fix,
        [Alias('Resolve')]
        [switch]$AutoResolve
    )

    $doFix = ($Fix.IsPresent -or $AutoResolve.IsPresent)
    if (Get-Command Write-PSManagerLog -ErrorAction SilentlyContinue) {
        Write-PSManagerLog -Message "Running PSManager Doctor (Fix: $doFix)" -Level "INFO"
    }
    $checks = [System.Collections.Generic.List[pscustomobject]]::new()

    # 1. Manifest Audit
    $resolvedManifestPath = Resolve-SyncManifestPath -ManifestPath $ManifestPath

    if (Test-Path -LiteralPath $resolvedManifestPath) {
        $manifest = Read-SyncManifest -ManifestPath $resolvedManifestPath
        $val = Test-SyncManifest -Manifest $manifest
        if ($val.IsValid) {
            $checks.Add([pscustomobject]@{
                Category       = "Manifest"
                Item           = "manifest.json"
                Status         = "PASS"
                Details        = "Valid schema (v$($manifest.version))"
                Recommendation = "None"
            })
        } else {
            $checks.Add([pscustomobject]@{
                Category       = "Manifest"
                Item           = "manifest.json"
                Status         = "FAIL"
                Details        = ($val.Errors -join "; ")
                Recommendation = "Check and fix manifest schema syntax"
            })
        }
    } else {
        $checks.Add([pscustomobject]@{
            Category       = "Manifest"
            Item           = "manifest.json"
            Status         = "WARN"
            Details        = "Manifest not found at $resolvedManifestPath"
            Recommendation = "Run 'psmgr sync' to scaffold default dotfiles"
        })
        $manifest = $null
    }

    # 2. Package Managers Audit
    $wingetAvailable = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    $checks.Add([pscustomobject]@{
        Category       = "PackageEngine"
        Item           = "Winget CLI"
        Status         = if ($wingetAvailable) { "PASS" } else { "WARN" }
        Details        = if ($wingetAvailable) { "Available in PATH" } else { "winget.exe not found" }
        Recommendation = if ($wingetAvailable) { "None" } else { "Install App Installer from Microsoft Store (https://aka.ms/getwinget)" }
    })

    $scoopShim = Join-Path $env:USERPROFILE "scoop\shims\scoop.cmd"
    $scoopAvailable = (Test-Path -LiteralPath $scoopShim) -or [bool](Get-Command scoop -ErrorAction SilentlyContinue)
    if (-not $scoopAvailable -and $doFix) {
        $scoopAvailable = Initialize-ScoopEnvironment -AutoInstall
    }
    $checks.Add([pscustomobject]@{
        Category       = "PackageEngine"
        Item           = "Scoop CLI"
        Status         = if ($scoopAvailable) { "PASS" } else { "WARN" }
        Details        = if ($scoopAvailable) { "Available at $scoopShim" } else { "Scoop not installed" }
        Recommendation = if ($scoopAvailable) { "None" } else { "Run 'irm get.scoop.io | iex' or 'psmgr doctor -Fix'" }
    })

    # 3. CLI Applications Scan (Scoop)
    if ($manifest -and $manifest.packages -and $manifest.packages.scoop -and $manifest.packages.scoop.apps) {
        foreach ($app in $manifest.packages.scoop.apps) {
            $isAppAvailable = Test-AppAvailable -App "$app"
            $appShims = (Get-AppShimPaths -App "$app") -join "; "

            if ($isAppAvailable) {
                $checks.Add([pscustomobject]@{
                    Category       = "App"
                    Item           = $app
                    Status         = "PASS"
                    Details        = "CLI application available in PATH"
                    Recommendation = "None"
                })
            } elseif ($doFix -and $scoopAvailable) {
                # Only install when the binary is truly absent; scoop list may
                # report the package yet the shim check above found nothing.
                $resInstall = Install-ScoopBatch -Apps @("$app")
                $nowAvailable = Test-AppAvailable -App "$app"
                $checks.Add([pscustomobject]@{
                    Category       = "App"
                    Item           = $app
                    Status         = if ($nowAvailable) { "FIXED" } else { "WARN" }
                    Details        = if ($nowAvailable) { "Installed/verified via Scoop ($app)" } else { "Installation attempt failed (scoop: $($resInstall.Message))" }
                    Recommendation = if ($nowAvailable) { "None" } else { "Run 'scoop install $app' manually" }
                })
            } else {
                $checks.Add([pscustomobject]@{
                    Category       = "App"
                    Item           = $app
                    Status         = "WARN"
                    Details        = "Application not installed on this machine"
                    Recommendation = "Run 'scoop install $app' or 'psmgr doctor -Fix'"
                })
            }
        }
    }

    # 4. PowerShell Modules Scan (PSGallery)
    if ($manifest -and $manifest.packages -and $manifest.packages.psgallery) {
        foreach ($modEntry in $manifest.packages.psgallery) {
            $modName = if ($modEntry -is [string]) { $modEntry } elseif ($modEntry.name) { $modEntry.name } else { "$modEntry" }
            $isModAvailable = [bool](Get-Module -ListAvailable -Name $modName -ErrorAction SilentlyContinue)

            if ($isModAvailable) {
                $checks.Add([pscustomobject]@{
                    Category       = "Module"
                    Item           = $modName
                    Status         = "PASS"
                    Details        = "PowerShell module installed"
                    Recommendation = "None"
                })
            } elseif ($doFix) {
                $resMod = Install-PSGalleryBatch -Modules @($modEntry)
                $nowMod = [bool](Get-Module -ListAvailable -Name $modName -ErrorAction SilentlyContinue)
                $checks.Add([pscustomobject]@{
                    Category       = "Module"
                    Item           = $modName
                    Status         = if ($nowMod) { "FIXED" } else { "WARN" }
                    Details        = if ($nowMod) { "Installed from PSGallery" } else { "Installation attempt failed" }
                    Recommendation = if ($nowMod) { "None" } else { "Run 'Install-Module -Name $modName -Scope CurrentUser' manually" }
                })
            } else {
                $checks.Add([pscustomobject]@{
                    Category       = "Module"
                    Item           = $modName
                    Status         = "WARN"
                    Details        = "PowerShell module missing from environment"
                    Recommendation = "Run 'Install-Module -Name $modName -Scope CurrentUser' or 'psmgr doctor -Fix'"
                })
            }
        }
    }

    # 5. Links Audit & Auto-Resolution
    if ($manifest -and $manifest.links) {
        $payloadDir = if (-not [string]::IsNullOrEmpty($BasePayloadDir)) {
            Resolve-NormalizedPath -Path $BasePayloadDir
        } else {
            Split-Path -Parent $resolvedManifestPath
        }

        # Pre-flight: every link source must exist before any target is touched.
        $missingSources = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $manifest.links) {
            $srcFull = if ([System.IO.Path]::IsPathRooted($entry.source)) {
                $entry.source
            } else {
                Join-Path $payloadDir $entry.source
            }
            if (-not (Test-Path -LiteralPath $srcFull -PathType Leaf)) {
                $missingSources.Add("$($entry.source) -> $srcFull")
                $checks.Add([pscustomobject]@{
                    Category       = "Link"
                    Item           = (Split-Path -Leaf $srcFull)
                    Status         = "FAIL"
                    Details        = "Link source missing from payload: $srcFull"
                    Recommendation = "Create the source file in your dotfiles (dir: $payloadDir) or run 'psmgr sync'"
                })
            }
        }
        $anySourceMissing = ($missingSources.Count -gt 0)

        foreach ($entry in $manifest.links) {
            $srcFull = if ([System.IO.Path]::IsPathRooted($entry.source)) {
                $entry.source
            } else {
                Join-Path $payloadDir $entry.source
            }
            if (-not (Test-Path -LiteralPath $srcFull -PathType Leaf)) { continue }

            $linkType = if ($entry.type) { $entry.type } else { "hardlink" }

            foreach ($targetRaw in $entry.targets) {
                $targetFull = Resolve-NormalizedPath -Path $targetRaw
                $targetExists = Test-Path -LiteralPath $targetFull
                $identical = if ($targetExists) { Test-FileIdentical -PathA $srcFull -PathB $targetFull } else { $false }

                if ($identical) {
                    $checks.Add([pscustomobject]@{
                        Category       = "Link"
                        Item           = (Split-Path -Leaf $targetFull)
                        Status         = "PASS"
                        Details        = "Linked and identical ($targetFull)"
                        Recommendation = "None"
                    })
                } elseif ($doFix) {
                    $fixLinkRes = New-SafeLink -SourcePath $srcFull -TargetPath $targetFull -LinkType $linkType
                    if ($fixLinkRes.Success) {
                        $checks.Add([pscustomobject]@{
                            Category       = "Link"
                            Item           = (Split-Path -Leaf $targetFull)
                            Status         = "FIXED"
                            Details        = "Repaired link via $($fixLinkRes.Method) ($targetFull)"
                            Recommendation = "None"
                        })
                    } else {
                        $checks.Add([pscustomobject]@{
                            Category       = "Link"
                            Item           = (Split-Path -Leaf $targetFull)
                            Status         = "FAIL"
                            Details        = "Failed to repair link: $($fixLinkRes.Message)"
                            Recommendation = "Check file lock or administrator permissions"
                        })
                    }
                } else {
                    $status = if ($targetExists) { "WARN" } else { "FAIL" }
                    $details = if ($targetExists) { "File exists but contents differ from profile" } else { "Profile target missing" }
                    $checks.Add([pscustomobject]@{
                        Category       = "Link"
                        Item           = (Split-Path -Leaf $targetFull)
                        Status         = $status
                        Details        = "$details ($targetFull)"
                        Recommendation = "Run 'psmgr doctor -Fix' or 'psmgr sync' to synchronize link"
                    })
                }
            }
        }
    }

    # 6. Shell Runtimes Audit
    $ps5Path = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $checks.Add([pscustomobject]@{
        Category       = "Shell"
        Item           = "Windows PowerShell 5.1"
        Status         = if (Test-Path $ps5Path) { "PASS" } else { "FAIL" }
        Details        = if (Test-Path $ps5Path) { "Installed (Desktop)" } else { "System32 powershell.exe not found" }
        Recommendation = "None"
    })

    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $checks.Add([pscustomobject]@{
        Category       = "Shell"
        Item           = "PowerShell 7 Core"
        Status         = if ($pwshCmd) { "PASS" } else { "WARN" }
        Details        = if ($pwshCmd) { "Installed ($($pwshCmd.Source))" } else { "pwsh.exe not found in PATH" }
        Recommendation = if ($pwshCmd) { "None" } else { "Run 'winget install Microsoft.PowerShell' or 'psmgr install'" }
    })

    # 7. Git Guardrails & Universal Hooks Audit (protects all AI agents and contributors)
    $repoDir = if ($PSScriptRoot) {
        Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    } else {
        Join-Path $env:USERPROFILE "tools\ps-manager"
    }
    if ((Test-Path (Join-Path $repoDir ".git")) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $hooksPath = & git -C $repoDir config --get core.hooksPath 2>$null
        $isConfigured = ($hooksPath -eq ".agents/hooks")
        if (-not $isConfigured -and $doFix) {
            & git -C $repoDir config core.hooksPath .agents/hooks 2>$null
            $hooksPath = & git -C $repoDir config --get core.hooksPath 2>$null
            $isConfigured = ($hooksPath -eq ".agents/hooks")
            $status = if ($isConfigured) { "FIXED" } else { "WARN" }
        } else {
            $status = if ($isConfigured) { "PASS" } else { "WARN" }
        }
        $checks.Add([pscustomobject]@{
            Category       = "Guardrails"
            Item           = "Git Hooks (core.hooksPath)"
            Status         = $status
            Details        = if ($isConfigured) { "Configured to .agents/hooks (universal for all agents)" } else { "Not configured (expected .agents/hooks)" }
            Recommendation = if ($isConfigured) { "None" } else { "Run 'git config core.hooksPath .agents/hooks' or 'psmgr doctor -Fix'" }
        })
    }

    # 8. Profile Compatibility & Ordering Audit (PS 5.1 & PS 7)
    if (Get-Command Test-PSManagerProfile -ErrorAction SilentlyContinue) {
        if ($doFix -and (Get-Command Repair-PSManagerProfile -ErrorAction SilentlyContinue)) {
            $profRepairs = Repair-PSManagerProfile
            foreach ($r in $profRepairs) {
                if ($r.Status -ne "PASS") {
                    $checks.Add($r)
                }
            }
        }
        $profChecks = Test-PSManagerProfile
        foreach ($pc in $profChecks) {
            $checks.Add($pc)
        }
    }

    return $checks.ToArray()
}
