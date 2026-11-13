#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Builder contract tests - launchers, bundle, packages, installer, MCP server.
.DESCRIPTION
    Exercises build/PSManager.Builder.psm1, build/build.ps1 and build/mcp-server.ps1 against a
    temporary directory. The installer test skips itself when Inno Setup 6 is not installed.
    Set PSMGR_SKIP_BUILDER_TESTS=1 to skip the suite (used by the pre-commit hook).
#>
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir
$BuilderModule = Join-Path $RootDir 'build\PSManager.Builder.psm1'
$McpServer = Join-Path $RootDir 'build\mcp-server.ps1'

if ($env:PSMGR_SKIP_BUILDER_TESTS -eq '1') {
    Write-Host '  [SKIP] Builder tests disabled by PSMGR_SKIP_BUILDER_TESTS'
    exit 0
}
if (-not (Test-Path -LiteralPath $BuilderModule)) { throw "Builder module missing: $BuilderModule" }
Import-Module $BuilderModule -Force

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

function Get-Sha256Hex {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try { return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Expand-TestArchive {
    # Expand-Archive -Force calls the 3-argument ZipFile.ExtractToDirectory overload, which does
    # not exist on Windows PowerShell 5.1's .NET Framework. Extract into a clean directory instead.
    param([string]$Path, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $Destination)
}

function Test-EmbeddedString {
    # Compiled C# string literals live in the metadata heap as UTF-16LE, so a plain ASCII scan
    # never matches. Search the raw bytes for both encodings, alignment-free.
    param([string]$Path, [string]$Needle)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $haystack = $latin1.GetString($bytes)
    foreach ($encoding in @([System.Text.Encoding]::ASCII, [System.Text.Encoding]::Unicode)) {
        $pattern = $latin1.GetString($encoding.GetBytes($Needle))
        if ($haystack.Contains($pattern)) { return $true }
    }
    return $false
}


$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('psmgr_builder_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    Assert-Check -Name "Builder module exports the public API" -TestBlock {
        $expected = @(
            'Get-PSManagerBuildInfo', 'ConvertTo-BuilderMetadata', 'Resolve-BuilderCompiler',
            'New-PSManagerLauncher', 'New-PSManagerBuildIcon', 'Test-PSManagerBuild',
            'New-PSManagerBuildPackage', 'New-PSManagerChecksumFile', 'New-PSManagerInstaller',
            'Resolve-BuilderInnoCompiler', 'Invoke-PSManagerCodeSign', 'Test-PSManagerSignature'
        )
        $module = Get-Module PSManager.Builder
        foreach ($name in $expected) {
            if (-not $module.ExportedFunctions.ContainsKey($name)) { throw "Missing export: $name" }
        }
    }

    Assert-Check -Name "Icon is a valid multi-size ICO" -TestBlock {
        $iconPath = Join-Path $tempRoot 'icon.ico'
        $null = New-PSManagerBuildIcon -OutputPath $iconPath
        $bytes = [System.IO.File]::ReadAllBytes($iconPath)
        if ($bytes.Length -lt 2000) { throw "Icon is too small: $($bytes.Length) bytes" }
        if ($bytes[0] -ne 0 -or $bytes[1] -ne 0 -or $bytes[2] -ne 1 -or $bytes[3] -ne 0) {
            throw 'ICO header is not 00 00 01 00'
        }
        $count = [BitConverter]::ToUInt16($bytes, 4)
        if ($count -lt 4) { throw "Expected several icon sizes, got $count" }
        Add-Type -AssemblyName System.Drawing
        $icon = New-Object System.Drawing.Icon($iconPath, 32, 32)
        try { if ($icon.Width -ne 32) { throw "Icon width $($icon.Width)" } } finally { $icon.Dispose() }
    }

    $appDir = Join-Path $tempRoot 'app'
    $launcherPath = $null
    Assert-Check -Name "Launcher carries metadata, icon and exit code" -TestBlock {
        $script:launcherPath = New-PSManagerLauncher -Destination $appDir -Name 'psmgr.exe' -ScriptName 'ps-manager.ps1' -Kind Console
        $report = Test-PSManagerBuild -Path $script:launcherPath -ExpectedVersion (Get-PSManagerBuildInfo).Version
        if (-not $report.Passed) { throw ("Problems: " + ($report.Problems -join '; ')) }
        if ($report.CompanyName -ne (Get-PSManagerBuildInfo -Root $RootDir).Company) { throw "CompanyName: $($report.CompanyName)" }
        if ($report.FileDescription -notmatch 'PSManager') { throw "FileDescription: $($report.FileDescription)" }
        if ($report.Comments -notmatch 'PowerShell version manager') { throw "Comments: $($report.Comments)" }
        if ($report.LegalCopyright -notmatch 'MIT') { throw "LegalCopyright: $($report.LegalCopyright)" }
    }

    Assert-Check -Name "Launcher runs the script and prints the version" -TestBlock {
        Copy-Item -LiteralPath (Join-Path $RootDir 'ps-manager.ps1') -Destination $appDir -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'PSManager.psd1') -Destination $appDir -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'PSManager.psm1') -Destination $appDir -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'modules') -Destination $appDir -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'templates') -Destination $appDir -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'ui') -Destination $appDir -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'config.json') -Destination $appDir -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'i18n.json') -Destination $appDir -Force
        $output = & $script:launcherPath help -NoColor 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Launcher exited $LASTEXITCODE" }
        $version = (Get-PSManagerBuildInfo).Version
        if ($output -notmatch ('PSManager v' + [regex]::Escape($version))) {
            throw "Version banner missing from: $($output.Substring(0, [Math]::Min(200, $output.Length)))"
        }
    }
    Assert-Check -Name "Launcher forwards arguments with trailing backslashes without corruption" -TestBlock {
        $echoScript = Join-Path $appDir 'echo_args.ps1'
        [System.IO.File]::WriteAllText($echoScript, @'
param($Directory, $Other)
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'echo_out.txt'), ($Directory + '|' + $Other))
'@)
        $echoExe = New-PSManagerLauncher -Destination $appDir -Name 'echo_test.exe' -ScriptName 'echo_args.ps1'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $echoExe
        $psi.Arguments = '-Directory "C:\test dir\\" -Other second'
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit(15000)) { $proc.Kill(); throw 'Launcher timed out' }
        $outPath = Join-Path $appDir 'echo_out.txt'
        if (-not (Test-Path -LiteralPath $outPath)) { throw 'echo_out.txt was not created' }
        $received = (Get-Content -LiteralPath $outPath -Raw).Trim()
        if ($received -ne 'C:\test dir\|second') {
            throw "Expected 'C:\test dir\|second', got '$received'"
        }
    }

    Assert-Check -Name "Bundle runs without sibling scripts and reuses extraction" -TestBlock {
        $bundleDir = Join-Path $tempRoot 'bundle'
        $isolated = Join-Path $tempRoot 'isolated'
        New-Item -ItemType Directory -Path $isolated -Force | Out-Null
        $payload = @('PSManager.psd1', 'PSManager.psm1', 'ps-manager.ps1', 'config.json', 'i18n.json', 'modules', 'templates', 'ui')
        $bundleExe = New-PSManagerLauncher -Destination $bundleDir -Name 'psmgr.exe' -ScriptName 'ps-manager.ps1' -Kind Console -PayloadFiles $payload
        Copy-Item -LiteralPath $bundleExe -Destination $isolated -Force
        $target = Join-Path $isolated 'psmgr.exe'
        $first = & $target help -NoColor 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Bundle exited $LASTEXITCODE" }
        if ($first -notmatch 'PSManager v') { throw 'Bundle did not run the embedded script' }
        $runtimeRoot = Join-Path $env:LOCALAPPDATA 'PSManager\runtime'
        $before = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue).Count
        $second = & $target help -NoColor 2>&1 | Out-String
        $after = @(Get-ChildItem -LiteralPath $runtimeRoot -Directory -ErrorAction SilentlyContinue).Count
        if ($second -notmatch 'PSManager v') { throw 'Second bundle run failed' }
        if ($after -ne $before) { throw "Second run created another extraction ($before -> $after)" }
    }
    Assert-Check -Name "Bundle refuses a missing payload file and an empty payload" -TestBlock {
        $dir = Join-Path $tempRoot 'payload-guard'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $threw = $false
        try {
            $null = New-PSManagerLauncher -Destination $dir -Name 'bad.exe' -ScriptName 'ps-manager.ps1' -Kind Console -PayloadFiles @('does-not-exist.ps1')
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw 'A missing payload file was silently skipped' }
        if (Test-Path -LiteralPath (Join-Path $dir 'bad.exe')) { throw 'A broken bundle was still produced' }
    }

    Assert-Check -Name "Launcher -Root resolves the payload from the given tree" -TestBlock {
        $fakeRoot = Join-Path $tempRoot 'rooted'
        New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $RootDir 'PSManager.psd1') -Destination $fakeRoot -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'PSManager.psm1') -Destination $fakeRoot -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'ps-manager.ps1') -Destination $fakeRoot -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'config.json') -Destination $fakeRoot -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'i18n.json') -Destination $fakeRoot -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'modules') -Destination $fakeRoot -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'assets') -Destination $fakeRoot -Recurse -Force
        # Only this tree carries the marker, so its name appearing in the executable proves the
        # payload came from -Root.
        Set-Content -LiteralPath (Join-Path $fakeRoot 'modules\rooted-marker.txt') -Value 'from-root' -Encoding ASCII
        $out = Join-Path $tempRoot 'rooted-out'
        New-Item -ItemType Directory -Path $out -Force | Out-Null
        $exe = New-PSManagerLauncher -Destination $out -Name 'rooted.exe' -ScriptName 'ps-manager.ps1' -Kind Console `
            -Root $fakeRoot -PayloadFiles @('ps-manager.ps1', 'modules')
        if (-not (Test-EmbeddedString -Path $exe -Needle 'modules/rooted-marker.txt')) {
            throw 'Launcher payload did not come from -Root (marker path missing from the executable)'
        }
    }
    Assert-Check -Name "Package -Mode Bundle embeds the payload from -Root" -TestBlock {
        $fakeRoot = Join-Path $tempRoot 'rooted-pkg'
        New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
        foreach ($item in @('PSManager.psd1', 'PSManager.psm1', 'ps-manager.ps1', 'gui.ps1', 'boot.ps1', 'config.json', 'i18n.json', 'README.md', 'CHANGELOG.md', 'PSScriptAnalyzerSettings.psd1')) {
            $source = Join-Path $RootDir $item
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $fakeRoot -Force }
        }
        foreach ($dir in @('modules', 'templates', 'ui', 'assets')) {
            $source = Join-Path $RootDir $dir
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $fakeRoot -Recurse -Force }
        }
        # A marker file proves the payload really came from the fake root, not from the module tree.
        Set-Content -LiteralPath (Join-Path $fakeRoot 'modules\rooted-marker.txt') -Value 'from-root' -Encoding ASCII
        $packages = Join-Path $tempRoot 'rooted-packages'
        $null = New-PSManagerBuildPackage -Destination $packages -Root $fakeRoot -Mode Bundle -Version '9.9.9'
        $bundleZip = Join-Path $packages 'psmgr-9.9.9-windows-bundle.zip'
        if (-not (Test-Path -LiteralPath $bundleZip)) { throw 'Bundle archive was not produced' }
        $inspect = Join-Path $tempRoot 'rooted-inspect'
        Expand-TestArchive -Path $bundleZip -Destination $inspect
        $bundleExe = Join-Path $inspect 'psmgr.exe'
        $bytes = [System.IO.File]::ReadAllBytes($bundleExe)
        if ($bytes.Length -lt 200000) { throw 'Bundled launcher did not embed the -Root payload' }
        if (-not (Test-EmbeddedString -Path $bundleExe -Needle 'modules/rooted-marker.txt')) {
            throw 'Packaged bundle payload did not come from -Root (marker path missing)'
        }
    }


    Assert-Check -Name "Icon generation writes nothing to the host stream" -TestBlock {
        $iconPath = Join-Path $tempRoot 'quiet.ico'
        $captured = & { New-PSManagerBuildIcon -OutputPath $iconPath } 6>&1
        $text = @($captured | ForEach-Object { [string]$_ }) -join "`n"
        if ($text -match 'Icon written') { throw "Icon generator leaked host output: $text" }
        if (-not (Test-Path -LiteralPath $iconPath)) { throw 'Icon was not generated' }
    }


    Assert-Check -Name "Packages contain five archives, launchers and sorted checksums" -TestBlock {
        $packages = Join-Path $tempRoot 'packages'
        $archives = @(New-PSManagerBuildPackage -Destination $packages -Root $RootDir)
        if ($archives.Count -ne 5) { throw "Expected 5 archives, got $($archives.Count)" }
        $names = @($archives | ForEach-Object { Split-Path -Leaf $_.Path })
        foreach ($suffix in @('full', 'desktop', 'cli-tui', 'portable', 'bundle')) {
            if (-not ($names | Where-Object { $_ -like "*$suffix.zip" })) { throw "Missing $suffix archive" }
        }
        $sumsPath = Join-Path $packages 'SHA256SUMS.txt'
        $sums = Get-Content -LiteralPath $sumsPath -Raw -Encoding ASCII
        if ($sums -match "`r") { throw 'Checksums must use LF endings' }
        $lines = @($sums.TrimEnd("`n") -split "`n")
        if ($lines.Count -ne 5) { throw "Expected 5 checksum lines, got $($lines.Count)" }
        foreach ($line in $lines) {
            if ($line -notmatch '^[0-9a-f]{64}\s\s\S+') {
                throw "Malformed checksum line: $line"
            }
        }
        $sorted = @($lines | Sort-Object { ($_ -split '\s\s')[1] })
        if (($lines -join "`n") -ne ($sorted -join "`n")) { throw 'Checksums are not sorted by file name' }
        $portableZip = Join-Path $packages ($names | Where-Object { $_ -like '*portable.zip' } | Select-Object -First 1)
        $inspect = Join-Path $tempRoot 'inspect'
        Expand-TestArchive -Path $portableZip -Destination $inspect
        foreach ($file in @('psmgr.exe', 'psmgr.cmd', 'psmgr-gui.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $inspect $file))) { throw "Portable archive is missing $file" }
        }
    }

    Assert-Check -Name "Checksum file covers archives and executables, sorted and LF-only" -TestBlock {
        $dir = Join-Path $tempRoot 'sums'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'zeta.zip') -Value 'zip payload' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $dir 'alpha.exe') -Value 'exe payload' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $dir 'notes.txt') -Value 'ignored' -Encoding ASCII
        $sumsPath = New-PSManagerChecksumFile -Destination $dir
        $raw = Get-Content -LiteralPath $sumsPath -Raw -Encoding ASCII
        if ($raw -match "`r") { throw 'Checksums must use LF endings' }
        $lines = @($raw.TrimEnd("`n") -split "`n")
        if ($lines.Count -ne 2) { throw "Expected 2 checksum lines, got $($lines.Count): $raw" }
        $names = @($lines | ForEach-Object { ($_ -split '\s\s')[1] })
        if (($names -join ',') -ne 'alpha.exe,zeta.zip') { throw "Wrong artifact set or order: $($names -join ',')" }
        foreach ($line in $lines) {
            if ($line -notmatch '^[0-9a-f]{64}\s\s\S+$') { throw "Malformed checksum line: $line" }
        }
    }

    Assert-Check -Name "Packaging refuses a staged developer path" -TestBlock {
        $fakeRoot = Join-Path $tempRoot 'fakeroot'
        New-Item -ItemType Directory -Path (Join-Path $fakeRoot 'modules') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $RootDir 'PSManager.psd1') -Destination $fakeRoot -Force
        Copy-Item -LiteralPath (Join-Path $RootDir 'PSManager.psm1') -Destination $fakeRoot -Force
        if (Test-Path -LiteralPath (Join-Path $RootDir 'assets')) {
            Copy-Item -LiteralPath (Join-Path $RootDir 'assets') -Destination $fakeRoot -Recurse -Force
        }
        Set-Content -LiteralPath (Join-Path $fakeRoot 'ps-manager.ps1') -Value 'param()' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $fakeRoot 'modules\Bad.psm1') -Value '$path = "C:\Users\Someone\secret"' -Encoding UTF8
        $threw = $false
        try {
            $null = New-PSManagerBuildPackage -Destination (Join-Path $tempRoot 'badpackages') -Root $fakeRoot
        } catch {
            $threw = $true
        }
        if (-not $threw) { throw 'Packaging accepted a tree containing a developer path' }
    }

    Assert-Check -Name "Installer builds with metadata (skipped when Inno is absent)" -TestBlock {
        $iscc = Resolve-BuilderInnoCompiler
        if (-not $iscc) {
            Write-Host '        (Inno Setup 6 not installed; installer assertion skipped)'
            return
        }
        $setupDir = Join-Path $tempRoot 'setup'
        $setup = New-PSManagerInstaller -Destination $setupDir -Root $RootDir
        if (-not (Test-Path -LiteralPath $setup)) { throw "Installer missing: $setup" }
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($setup)
        if ($info.ProductName -notmatch 'PSManager') { throw "Installer ProductName: $($info.ProductName)" }
        if ((Get-Item -LiteralPath $setup).Length -lt 100000) { throw 'Installer is suspiciously small' }
        # Smoke install and uninstall
        $installDir = Join-Path $setupDir 'installed'
        $p = Start-Process -FilePath $setup -ArgumentList ("/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=`"" + $installDir + "`"") -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Installer exited with code $($p.ExitCode)" }
        $installedExe = Join-Path $installDir 'psmgr.exe'
        if (-not (Test-Path -LiteralPath $installedExe)) { throw "Installed psmgr.exe missing from $installDir" }
        $uninstaller = Get-ChildItem -LiteralPath $installDir -Filter "unins*.exe" | Select-Object -First 1
        if (-not $uninstaller) { throw "Uninstaller missing from $installDir" }
        $u = Start-Process -FilePath $uninstaller.FullName -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -Wait -PassThru
        Start-Sleep -Seconds 2
        if ($u.ExitCode -ne 0) { throw "Uninstaller exited with code $($u.ExitCode)" }
        if (Test-Path -LiteralPath $installedExe) { throw "psmgr.exe was not cleaned up after uninstall" }
    }
    Assert-Check -Name "Code signing produces a verifiable Authenticode signature (skipped without signtool)" -TestBlock {
        $signtool = Get-ChildItem -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if (-not $signtool) {
            Write-Host '        (signtool.exe not installed; signing assertion skipped)'
            return
        }
        $signDir = Join-Path $tempRoot 'signing'
        New-Item -ItemType Directory -Path $signDir -Force | Out-Null
        $pfx = Join-Path $signDir 'test.pfx'
        $password = 'psmgr-test-signing'
        $null = & (Join-Path $RootDir 'tools\New-PSManagerSigningCertificate.ps1') -PfxPath $pfx -Password $password -Force
        $exe = New-PSManagerLauncher -Destination $signDir -Name 'signed.exe' -ScriptName 'ps-manager.ps1' -Kind Console
        $null = Invoke-PSManagerCodeSign -Path @($exe) -CertificatePath $pfx -CertificatePassword $password
        # Verify cryptographically (WinVerifyTrust) with the signer pinned: the throwaway
        # certificate is untrusted here, which must not hide a bad signature.
        $result = Test-PSManagerSignature -Path $exe
        if (-not $result.SignatureValid) { throw "Signature is not cryptographically valid: $($result.Reason)" }
        if (-not $result.Passed) { throw "Signed launcher did not pass verification: $($result.Reason)" }
        $pinned = Test-PSManagerSignature -Path $exe -ExpectedThumbprint $result.Thumbprint
        if (-not $pinned.Passed) { throw 'Pinned signer did not verify' }
        $wrongPin = Test-PSManagerSignature -Path $exe -ExpectedThumbprint 'DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF'
        if ($wrongPin.Passed) { throw 'A wrong pinned thumbprint was accepted' }

        # Negative test: modifying a byte after signing must fail, even though the certificate
        # stays embedded. This is what thumbprint-only checking would miss.
        $tampered = Join-Path $signDir 'tampered.exe'
        $bytes = [System.IO.File]::ReadAllBytes($exe)
        $middle = [int]($bytes.Length / 3)
        $bytes[$middle] = $bytes[$middle] -bxor 0xFF
        [System.IO.File]::WriteAllBytes($tampered, $bytes)
        $tamperedResult = Test-PSManagerSignature -Path $tampered -ExpectedThumbprint $result.Thumbprint
        if ($tamperedResult.SignatureValid) { throw "A modified executable still reported a valid signature: $($tamperedResult.Reason)" }
        if ($tamperedResult.Passed) { throw 'A modified executable passed verification' }

        $unsigned = New-PSManagerLauncher -Destination $signDir -Name 'unsigned.exe' -ScriptName 'ps-manager.ps1' -Kind Console
        $unsignedResult = Test-PSManagerSignature -Path $unsigned
        if ($unsignedResult.SignatureValid) { throw 'An unsigned launcher reported a valid signature' }
        if ($unsignedResult.Passed) { throw 'An unsigned launcher passed verification' }
    }


    Assert-Check -Name "MCP server answers initialize, tools/list and tools/call" -TestBlock {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$McpServer`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $proc = [System.Diagnostics.Process]::Start($psi)
        try {
            $requests = @(
                '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
                '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
                '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"build_info","arguments":{}}}',
                '{"jsonrpc":"2.0","id":4,"method":"exit"}'
            )
            foreach ($request in $requests) { $proc.StandardInput.WriteLine($request) }
            $proc.StandardInput.Close()
            $stdout = $proc.StandardOutput.ReadToEnd()
            if (-not $proc.WaitForExit(60000)) { throw 'MCP server did not exit' }
            $lines = @($stdout -split "`r?`n" | Where-Object { $_.Trim() })
            if ($lines.Count -lt 3) { throw "Expected at least 3 responses, got $($lines.Count)" }
            $responses = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
            $init = $responses | Where-Object { $_.id -eq 1 }
            if ($init.result.serverInfo.name -ne 'psmgr-builder') { throw 'initialize response is wrong' }
            $tools = $responses | Where-Object { $_.id -eq 2 }
            if (@($tools.result.tools).Count -lt 6) { throw 'tools/list returned too few tools' }
            $call = $responses | Where-Object { $_.id -eq 3 }
            if ($call.result.isError) { throw "tools/call failed: $($call.result.content[0].text)" }
            if ($call.result.content[0].text -notmatch 'PSManager') { throw 'build_info payload is empty' }
        } finally {
            if (-not $proc.HasExited) { $proc.Kill() }
            $proc.Dispose()
        }
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ("`n[FAIL] test_builder.ps1 had " + $failures.Count + " failure(s)") -ForegroundColor Red
    exit 1
}
Write-Host "`n[PASS] test_builder.ps1 passed all checks" -ForegroundColor Green
exit 0
