#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Builder - reusable app/packaging builder with launcher and single-file bundle modes.
.DESCRIPTION
    Compiles Windows launchers with embedded icon and full version metadata, packages the release
    variants, verifies the produced binaries, and generates the application icon. Only Windows
    components are used: csc.exe from the .NET Framework and System.Drawing.
#>

$Script:BuilderRoot = Split-Path -Parent $PSScriptRoot
$Script:BuildInfoCache = @{}

function Get-PSManagerBuildInfo {
    <#
    .SYNOPSIS
        Returns repository, version and default metadata used by every build.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Root = $Script:BuilderRoot)

    $resolvedRoot = if (Test-Path -LiteralPath $Root) {
        (Resolve-Path -LiteralPath $Root).Path
    } else {
        [System.IO.Path]::GetFullPath($Root)
    }
    if ($Script:BuildInfoCache.ContainsKey($resolvedRoot)) {
        return $Script:BuildInfoCache[$resolvedRoot]
    }

    $manifestPath = Join-Path $resolvedRoot 'PSManager.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "PSManager.psd1 not found under $Root"
    }
    $manifest = Test-ModuleManifest -Path $manifestPath
    $repositoryUrl = 'https://github.com/danhthanh4182/psmgr'
    try {
        $remote = & git -C $resolvedRoot remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and $remote) {
            $repositoryUrl = ($remote -replace '^git@github\.com:', 'https://github.com/' -replace '\.git$', '')
        }
    } catch { }

    $info = [pscustomobject]@{
        Root          = $resolvedRoot
        Name          = 'PSManager'
        Version       = $manifest.Version.ToString()
        Author        = 'Danh Thanh'
        Company       = 'Danh Thanh'
        Product       = 'PSManager'
        Copyright     = '(c) 2025-2026 Thanh. MIT License.'
        Description   = 'PowerShell version manager: CLI, TUI and desktop app'
        RepositoryUrl = $repositoryUrl
        IconPath      = (Join-Path $resolvedRoot 'assets\psmgr.ico')
    }
    $Script:BuildInfoCache[$resolvedRoot] = $info
    return $info
}

function Resolve-BuilderCompiler {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $frameworkRoots = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework')
    )
    foreach ($root in $frameworkRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $candidates = Get-ChildItem -LiteralPath $root -Directory -Filter 'v4.*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
        foreach ($candidate in $candidates) {
            $csc = Join-Path $candidate.FullName 'csc.exe'
            if (Test-Path -LiteralPath $csc) { return $csc }
        }
    }
    throw 'csc.exe (.NET Framework 4.x) was not found; Windows ships it under %WINDIR%\Microsoft.NET.'
}

function ConvertTo-BuilderMetadata {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [pscustomobject]$Metadata,
        [string]$Version,
        [string]$Title,
        [string]$Description,
        [string]$Company,
        [string]$Copyright,
        [string]$RepositoryUrl,
        [string]$Root = $Script:BuilderRoot
    )

    $info = Get-PSManagerBuildInfo -Root $Root
    $resolved = [pscustomobject]@{
        Title         = if ($Title) { $Title } elseif ($Metadata -and $Metadata.Title) { $Metadata.Title } else { $info.Product }
        Description   = if ($Description) { $Description } elseif ($Metadata -and $Metadata.Description) { $Metadata.Description } else { $info.Description }
        Company       = if ($Company) { $Company } elseif ($Metadata -and $Metadata.Company) { $Metadata.Company } else { $info.Company }
        Product       = if ($Metadata -and $Metadata.Product) { $Metadata.Product } else { $info.Product }
        Copyright     = if ($Copyright) { $Copyright } elseif ($Metadata -and $Metadata.Copyright) { $Metadata.Copyright } else { $info.Copyright }
        Version       = if ($Version) { $Version } elseif ($Metadata -and $Metadata.Version) { $Metadata.Version } else { $info.Version }
        RepositoryUrl = if ($RepositoryUrl) { $RepositoryUrl } elseif ($Metadata -and $Metadata.RepositoryUrl) { $Metadata.RepositoryUrl } else { $info.RepositoryUrl }
    }
    if ($resolved.Version -notmatch '^\d+\.\d+\.\d+') {
        throw "Version must be semantic (x.y.z), got '$($resolved.Version)'"
    }
    return $resolved
}

function Get-BuilderAssemblyVersion {
    param([string]$Version)
    $parts = @($Version.Split('.') | ForEach-Object { [int]($_ -replace '\D.*$', '') })
    while ($parts.Count -lt 4) { $parts += 0 }
    return ($parts[0..3] -join '.')
}

function Resolve-BuilderIconPath {
    param([string]$Explicit, [string]$RootIconPath)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "Icon not found: $Explicit" }
        return $Explicit
    }
    if ($RootIconPath -and (Test-Path -LiteralPath $RootIconPath)) { return $RootIconPath }
    # A -Root tree without assets still builds, but the caller should know which icon it gets.
    $fallback = Join-Path $Script:BuilderRoot 'assets\psmgr.ico'
    if (Test-Path -LiteralPath $fallback) {
        Write-Warning ("No icon under {0}; using the builder icon {1}" -f $RootIconPath, $fallback)
        return $fallback
    }
    return ''
}

function New-BuilderLauncherSource {
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Metadata,
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string]$ExtraArguments = '',
        [switch]$StaThread,
        [string]$PayloadHash = '',
        [string[]]$PayloadEntries = @()
    )

    $escaped = {
        param([string]$Text)
        return $Text.Replace('\', '\\').Replace('"', '\"')
    }

    $assemblyVersion = Get-BuilderAssemblyVersion -Version $Metadata.Version

    $payloadFields = ''
    $ensureExtracted = 'return null;'
    if ($PayloadHash) {
        $payloadFields = @"
    internal const string Hash = "$PayloadHash";
    internal static readonly string[] Files = new string[] {
$([string]::Join(",`r`n", @($PayloadEntries | ForEach-Object { '        "' + (($_ -replace '\\','/') -replace '"','\"') + '"' })))
    };
"@
        $ensureExtracted = @'
        string root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PSManager", "runtime", Payload.Hash);
        string marker = Path.Combine(root, ".complete");
        if (!File.Exists(marker))
        {
        int expected = Payload.Files.Length / 2;
        // A launcher compiled without a payload has no scripts to extract; never mark an empty
        // runtime directory as complete, or every later run would reuse it and fail.
        if (expected <= 0) { return null; }
        string staging = root + ".tmp-" + Process.GetCurrentProcess().Id;
        if (Directory.Exists(staging)) { Directory.Delete(staging, true); }
        Directory.CreateDirectory(staging);
        int written = 0;
        for (int i = 0; i + 1 < Payload.Files.Length; i += 2)
        {
            string target = Path.Combine(staging, Payload.Files[i].Replace('/', Path.DirectorySeparatorChar));
            string parent = Path.GetDirectoryName(target);
            if (!string.IsNullOrEmpty(parent)) { Directory.CreateDirectory(parent); }
            File.WriteAllBytes(target, Convert.FromBase64String(Payload.Files[i + 1]));
            written++;
        }
        if (written != expected)
        {
            // Incomplete payload: leave no marker so the next run retries instead of reusing it.
            try { Directory.Delete(staging, true); } catch { }
        }
        else
        {
            try
            {
                // A leftover directory with fewer files than the payload is repaired, not reused:
                // an earlier failed extraction must not poison this payload hash forever.
                int existing = Directory.Exists(root) ? Directory.GetFiles(root, "*", SearchOption.AllDirectories).Length : -1;
                if (existing >= expected) { Directory.Delete(staging, true); }
                else
                {
                    if (existing >= 0) { Directory.Delete(root, true); }
                    Directory.Move(staging, root);
                }
            }
            catch
            {
                try { if (Directory.Exists(staging)) { Directory.Delete(staging, true); } } catch { }
            }
            // Mark complete only when the runtime directory really holds the payload; a failed
            // move must not leave a marker over an empty directory.
            int present = Directory.Exists(root) ? Directory.GetFiles(root, "*", SearchOption.AllDirectories).Length : 0;
            if (present >= expected) { File.WriteAllText(marker, Payload.Hash); }
        }
        }
        return root;
'@
    }

    $staAttribute = if ($StaThread) { '    [STAThread]' } else { '' }

    return @"
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

[assembly: AssemblyTitle("$(& $escaped $Metadata.Title)")]
[assembly: AssemblyDescription("$(& $escaped $Metadata.Description) - $(& $escaped $Metadata.RepositoryUrl)")]
[assembly: AssemblyCompany("$(& $escaped $Metadata.Company)")]
[assembly: AssemblyProduct("$(& $escaped $Metadata.Product)")]
[assembly: AssemblyCopyright("$(& $escaped $Metadata.Copyright)")]
[assembly: AssemblyTrademark("PSManager")]
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
[assembly: AssemblyInformationalVersion("$($Metadata.Version)")]
[assembly: AssemblyMetadata("RepositoryUrl", "$(& $escaped $Metadata.RepositoryUrl)")]
[assembly: ComVisible(false)]

internal static class Payload
{
$payloadFields
}

internal static class Launcher
{
    private static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value)) return "\"\"";
        string escaped = Regex.Replace(value, @"(\\*)""", @"`$1`$1\""");
        escaped = Regex.Replace(escaped, @"(\\+)$", @"`$1`$1");
        return "\"" + escaped + "\"";
    }

    private static string PayloadRoot()
    {
$ensureExtracted
    }

    internal static int Run(string scriptName, string extraArguments)
    {
        string root = PayloadRoot();
        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(root ?? exeDir, scriptName);
        if (!File.Exists(script))
        {
            Console.Error.WriteLine(scriptName + " was not found next to this launcher: " + exeDir);
            return 1;
        }

        string host = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\powershell.exe");
        try
        {
            foreach (string dir in (Environment.GetEnvironmentVariable("PATH") ?? string.Empty).Split(';'))
            {
                if (dir.Length == 0) { continue; }
                string candidate = Path.Combine(dir.Trim(), "pwsh.exe");
                if (File.Exists(candidate)) { host = candidate; break; }
            }
        }
        catch { }

        var builder = new StringBuilder();
        builder.Append("-NoProfile -ExecutionPolicy Bypass ").Append("$extraArguments");
        builder.Append(" -File ").Append(Quote(script));
        string[] cmdArgs = Environment.GetCommandLineArgs();
        for (int i = 1; i < cmdArgs.Length; i++)
        {
            builder.Append(' ').Append(Quote(cmdArgs[i]));
        }

        bool hideConsole = !string.IsNullOrEmpty("$extraArguments") &&
            "$extraArguments".IndexOf("-WindowStyle Hidden", StringComparison.OrdinalIgnoreCase) >= 0;

        var startInfo = new ProcessStartInfo
        {
            FileName = host,
            Arguments = builder.ToString(),
            UseShellExecute = false,
            CreateNoWindow = hideConsole,
            WindowStyle = hideConsole ? ProcessWindowStyle.Hidden : ProcessWindowStyle.Normal,
            WorkingDirectory = root ?? exeDir
        };
        using (Process process = Process.Start(startInfo))
        {
            if (process == null) { return 1; }
            process.WaitForExit();
            return process.ExitCode;
        }
    }
}

internal static class Program
{
$staAttribute
    private static int Main(string[] args)
    {
        return Launcher.Run("$ScriptName", "$extraArguments");
    }
}
"@
}

function Invoke-PSManagerCodeSign {
    <#
    .SYNOPSIS
        Signs artifacts with signtool, from a .pfx file or an installed certificate thumbprint.
    .DESCRIPTION
        Signs each path with SHA-256 and an RFC 3161 timestamp. A no-op when no certificate is
        supplied. Signing failures throw so a release cannot ship half-signed artifacts.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'The certificate password is forwarded to signtool.exe /p')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        [string]$CertificatePath,
        [string]$CertificatePassword,
        [string]$CertificateThumbprint,
        [switch]$MachineStore,
        [string]$Description = 'PSManager',
        [string]$Url = 'https://github.com/danhthanh4182/psmgr',
        [string]$TimestampUrl = 'http://timestamp.digicert.com'
    )

    if (-not $CertificatePath -and -not $CertificateThumbprint) {
        Write-Verbose 'Code signing skipped (no certificate).'
        return
    }
    if ($CertificatePath -and -not (Test-Path -LiteralPath $CertificatePath)) {
        throw "Certificate not found: $CertificatePath"
    }

    $signTool = Get-Command signtool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $signTool) {
        $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
        if (Test-Path -LiteralPath $kits) {
            $candidate = Get-ChildItem -LiteralPath $kits -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1
            if ($candidate) { $signTool = $candidate }
        }
    }
    if (-not $signTool) {
        throw 'signtool.exe was not found. Install the Windows SDK or omit the certificate.'
    }
    $signToolPath = if ($signTool -is [System.Management.Automation.ApplicationInfo]) {
        $signTool.Source
    } elseif ($signTool -is [System.IO.FileInfo]) {
        $signTool.FullName
    } else {
        [string]$signTool
    }

    $signed = New-Object System.Collections.Generic.List[string]
    foreach ($file in $Path) {
        if (-not (Test-Path -LiteralPath $file)) {
            throw "Cannot sign a missing artifact: $file"
        }
        $arguments = @('sign', '/fd', 'sha256', '/d', $Description, '/du', $Url)
        if ($CertificatePath) {
            $arguments += @('/f', $CertificatePath)
            if ($CertificatePassword) { $arguments += @('/p', $CertificatePassword) }
        } else {
            $arguments += @('/sha1', $CertificateThumbprint)
            if ($MachineStore) { $arguments += '/sm' }
        }
        if ($TimestampUrl) { $arguments += @('/tr', $TimestampUrl, '/td', 'sha256') }
        $arguments += $file

        # Capture output: signtool writes to the console, which would corrupt the MCP JSON-RPC stream.
        $output = & $signToolPath @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("signtool failed for {0} (exit {1}):{2}{3}" -f $file, $LASTEXITCODE, [Environment]::NewLine, ($output -join [Environment]::NewLine))
        }
        $signed.Add($file)
    }
    return [pscustomobject]@{ Signed = $signed.ToArray(); Count = $signed.Count }
}
function Test-PSManagerSignature {
    <#
    .SYNOPSIS
        Verifies an Authenticode signature cryptographically, with optional signer pinning.
    .DESCRIPTION
        Calls WinVerifyTrust, which validates the signature digest over the file bytes and the
        certificate chain. A chain that ends in an untrusted self-signed root is reported as
        SignatureValid = $true / ChainTrusted = $false, while a modified file is reported as
        SignatureValid = $false (TRUST_E_BAD_DIGEST). Comparing only the embedded certificate
        would not catch tampering, so both checks are returned separately.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedThumbprint
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot verify a missing file: $Path"
    }
    $full = (Resolve-Path -LiteralPath $Path).Path

    if (-not ('PSManager.SignatureVerifier' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace PSManager
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal class WINTRUST_FILE_INFO
    {
        public uint cbStruct = (uint)Marshal.SizeOf(typeof(WINTRUST_FILE_INFO));
        public string pcwszFilePath;
        public IntPtr hFile = IntPtr.Zero;
        public IntPtr pgKnownSubject = IntPtr.Zero;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal class WINTRUST_DATA
    {
        public uint cbStruct = (uint)Marshal.SizeOf(typeof(WINTRUST_DATA));
        public IntPtr pPolicyCallbackData = IntPtr.Zero;
        public IntPtr pSIPClientData = IntPtr.Zero;
        public uint dwUIChoice = 2;          // WTD_UI_NONE
        public uint fdwRevocationChecks = 0; // WTD_REVOKE_NONE
        public uint dwUnionChoice = 1;       // WTD_CHOICE_FILE
        public IntPtr pFile = IntPtr.Zero;
        public uint dwStateAction = 1;       // WTD_STATEACTION_VERIFY
        public IntPtr hWVTStateData = IntPtr.Zero;
        public IntPtr pwszURLReference = IntPtr.Zero;
        public uint dwProvFlags = 0x10 | 0x1000; // WTD_REVOCATION_CHECK_NONE | WTD_CACHE_ONLY_URL_RETRIEVAL
        public uint dwUIContext = 0;
    }

    public static class SignatureVerifier
    {
        [DllImport("wintrust.dll", PreserveSig = true, SetLastError = false)]
        private static extern uint WinVerifyTrust(IntPtr hwnd, [MarshalAs(UnmanagedType.LPStruct)] Guid actionId, IntPtr data);

        public static uint Verify(string path)
        {
            Guid action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
            WINTRUST_FILE_INFO fileInfo = new WINTRUST_FILE_INFO();
            fileInfo.pcwszFilePath = path;
            WINTRUST_DATA data = new WINTRUST_DATA();
            IntPtr filePtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WINTRUST_FILE_INFO)));
            IntPtr dataPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WINTRUST_DATA)));
            try
            {
                Marshal.StructureToPtr(fileInfo, filePtr, false);
                data.pFile = filePtr;
                Marshal.StructureToPtr(data, dataPtr, false);
                uint result = WinVerifyTrust(IntPtr.Zero, action, dataPtr);
                // Release the state data allocated by the verify call.
                Marshal.PtrToStructure(dataPtr, data);
                data.dwStateAction = 2; // WTD_STATEACTION_CLOSE
                Marshal.StructureToPtr(data, dataPtr, false);
                WinVerifyTrust(IntPtr.Zero, action, dataPtr);
                return result;
            }
            finally
            {
                Marshal.FreeHGlobal(filePtr);
                Marshal.FreeHGlobal(dataPtr);
            }
        }
    }
}
'@
    }

    $code = [uint32][PSManager.SignatureVerifier]::Verify($full)
    $thumbprint = ''
    $subject = ''
    try {
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($full)
        $thumbprint = $cert.GetCertHashString()
        $subject = $cert.Subject
    } catch {
        $thumbprint = ''
    }

    # Compare as hex text: PowerShell parses 0x800B0109 as a negative Int32, so numeric
    # comparison against a [uint32] would never match.
    $codeHex = '0x' + $code.ToString('X8')
    $chainTrusted = ($codeHex -eq '0x00000000')
    $signatureValid = ($codeHex -eq '0x00000000' -or $codeHex -eq '0x800B0109')

    $thumbprintMatches = if ($ExpectedThumbprint) {
        ($thumbprint -ne '' -and $thumbprint -eq $ExpectedThumbprint)
    } else {
        ($thumbprint -ne '')
    }

    $reason = switch ($codeHex) {
        '0x00000000' { 'valid and the certificate chain is trusted' }
        '0x800B0109' { 'valid but the certificate chain ends in an untrusted root' }
        '0x80096010' { 'signature digest does not match the file (modified after signing)' }
        '0xC000A000' { 'signature structure is invalid (file modified after signing)' }
        '0x800B0100' { 'no signature found' }
        default { ('WinVerifyTrust returned ' + $codeHex) }
    }

    return [pscustomobject]@{
        Path              = $full
        SignatureValid    = $signatureValid
        ChainTrusted      = $chainTrusted
        Thumbprint        = $thumbprint
        Subject           = $subject
        ThumbprintMatches = $thumbprintMatches
        Reason            = $reason
        Passed            = ($signatureValid -and $thumbprintMatches)
    }
}


function New-PSManagerLauncher {
    <#
    .SYNOPSIS
        Compiles one launcher executable with metadata, icon and optional embedded payload.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'The certificate password is forwarded to signtool.exe /p')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [ValidateSet('Console', 'Windows')][string]$Kind = 'Console',
        [string]$ExtraArguments = '',
        [switch]$StaThread,
        [switch]$RequireAdmin,
        [string]$IconPath,
        [pscustomobject]$Metadata,
        [string[]]$PayloadFiles = @(),
        [string]$CertificatePath,
        [string]$CertificatePassword,
        [string]$CertificateThumbprint,
        [string]$Root = $Script:BuilderRoot
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $destinationPath = (Resolve-Path -LiteralPath $Destination).Path
    $info = Get-PSManagerBuildInfo -Root $Root
    $resolvedMetadata = ConvertTo-BuilderMetadata -Metadata $Metadata -Root $Root
    $IconPath = Resolve-BuilderIconPath -Explicit $IconPath -RootIconPath $info.IconPath

    $payloadEntries = @()
    $payloadHash = ''
    if ($PayloadFiles.Count -gt 0) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        # Overlapping -PayloadFiles (a directory plus a file inside it) would otherwise embed the
        # same relative path twice: the launcher writes N entries but yields fewer files, so its
        # completeness check never passes and every run re-extracts.
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        try {
            $all = New-Object System.IO.MemoryStream
            foreach ($file in $PayloadFiles) {
                $full = Join-Path $info.Root $file
                if (-not (Test-Path -LiteralPath $full)) {
                    throw ("Payload file not found under {0}: {1}" -f $info.Root, $file)
                }
                $files = @()
                if (Test-Path -LiteralPath $full -PathType Container) {
                    $files = @(Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object {
                        @{ Relative = $_.FullName.Substring($info.Root.Length + 1); Full = $_.FullName }
                    })
                } else {
                    $files = @(@{ Relative = ($file -replace '\\', '/'); Full = $full })
                }
                foreach ($entry in $files) {
                    $relative = ($entry.Relative -replace '\\', '/')
                    if (-not $seen.Add($relative)) { continue }
                    $bytes = [System.IO.File]::ReadAllBytes($entry.Full)
                    $payloadEntries += $relative
                    $payloadEntries += [System.Convert]::ToBase64String($bytes)
                    $all.Write($bytes, 0, $bytes.Length)
                }
            }
            if ($payloadEntries.Count -eq 0) {
                throw ("Bundle payload resolved to zero files under {0}; refusing to build an empty bundle." -f $info.Root)
            }
            $payloadHash = ([System.BitConverter]::ToString($sha.ComputeHash($all.ToArray()))).Replace('-', '').Substring(0, 16)
        } finally {
            $sha.Dispose()
        }
    }

    $source = New-BuilderLauncherSource -Metadata $resolvedMetadata -ScriptName $ScriptName `
        -ExtraArguments $ExtraArguments -StaThread:$StaThread -PayloadHash $payloadHash -PayloadEntries $payloadEntries

    $csc = Resolve-BuilderCompiler
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('psmgr-build-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $sourcePath = Join-Path $work 'launcher.cs'
    $manifestPath = Join-Path $work 'app.manifest'
    $outputPath = Join-Path $destinationPath $Name

    try {
        [System.IO.File]::WriteAllText($sourcePath, $source, (New-Object System.Text.UTF8Encoding($false)))
        $level = if ($RequireAdmin) { 'requireAdministrator' } else { 'asInvoker' }
        $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2">
    <security>
      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
        <requestedExecutionLevel level="$level" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}" />
    </application>
  </compatibility>
</assembly>
"@
        [System.IO.File]::WriteAllText($manifestPath, $manifest, (New-Object System.Text.UTF8Encoding($false)))

        $target = if ($Kind -eq 'Windows') { 'winexe' } else { 'exe' }
        $arguments = @(
            '/nologo',
            ('/target:' + $target),
            '/optimize+',
            '/platform:anycpu',
            ('/out:' + $outputPath),
            ('/win32manifest:' + $manifestPath)
        )
        if ($IconPath) { $arguments += ('/win32icon:' + (Resolve-Path -LiteralPath $IconPath).Path) }
        $arguments += $sourcePath

        $output = & $csc @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("csc failed with exit code {0}:{1}{2}" -f $LASTEXITCODE, [Environment]::NewLine, ($output -join [Environment]::NewLine))
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($CertificatePath -or $CertificateThumbprint) {
        $null = Invoke-PSManagerCodeSign -Path @($outputPath) -CertificatePath $CertificatePath -CertificatePassword $CertificatePassword -CertificateThumbprint $CertificateThumbprint
    }

    return $outputPath
}

function New-PSManagerBuildIcon {
    <#
    .SYNOPSIS
        Generates the multi-size application icon (or converts an image to ICO).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$OutputPath,
        [string]$SourceImage
    )

    if (-not $OutputPath) { $OutputPath = (Join-Path $Script:BuilderRoot 'assets\psmgr.ico') }
    $iconScript = Join-Path $Script:BuilderRoot 'tools\New-PSManagerIcon.ps1'
    if (-not (Test-Path -LiteralPath $iconScript)) { throw "Icon generator missing: $iconScript" }
    # Capture every stream: this runs inside the MCP server, where stray host output corrupts stdout.
    & $iconScript -OutputPath $OutputPath 6>&1 | Out-Null
    return $OutputPath
}

function Test-PSManagerBuild {
    <#
    .SYNOPSIS
        Verifies an executable's version metadata, embedded icon and (optionally) a smoke run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedVersion,
        [switch]$SmokeRun
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Executable not found: $Path" }
    $item = Get-Item -LiteralPath $Path
    $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName)

    $iconOk = $false
    try {
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($item.FullName)
        $iconOk = ($null -ne $icon)
        if ($icon) { $icon.Dispose() }
    } catch { $iconOk = $false }

    $smokeExit = $null
    if ($SmokeRun) {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $item.FullName help -NoColor > $null 2>&1
            $smokeExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
    }

    $problems = New-Object System.Collections.Generic.List[string]
    if (-not $versionInfo.FileVersion) { $problems.Add('FileVersion metadata missing') }
    if (-not $versionInfo.CompanyName) { $problems.Add('CompanyName metadata missing') }
    if (-not $versionInfo.ProductName) { $problems.Add('ProductName metadata missing') }
    if (-not $versionInfo.LegalCopyright) { $problems.Add('LegalCopyright metadata missing') }
    if (-not $iconOk) { $problems.Add('Embedded icon could not be read') }
    if ($ExpectedVersion -and $versionInfo.FileVersion -notlike ($ExpectedVersion + '*')) {
        $problems.Add("FileVersion '$($versionInfo.FileVersion)' does not match '$ExpectedVersion'")
    }
    if ($SmokeRun -and $smokeExit -ne 0) {
        $problems.Add("Smoke run exited $smokeExit")
    }

    return [pscustomobject]@{
        Path            = $item.FullName
        SizeBytes       = $item.Length
        FileVersion     = $versionInfo.FileVersion
        ProductVersion  = $versionInfo.ProductVersion
        CompanyName     = $versionInfo.CompanyName
        ProductName     = $versionInfo.ProductName
        FileDescription = $versionInfo.FileDescription
        LegalCopyright  = $versionInfo.LegalCopyright
        Comments        = $versionInfo.Comments
        HasIcon         = $iconOk
        SmokeExitCode   = $smokeExit
        Problems        = @($problems)
        Passed          = ($problems.Count -eq 0)
    }
}
function New-PSManagerChecksumFile {
    <#
    .SYNOPSIS
        Writes SHA256SUMS.txt for every release artifact in a directory.
    .DESCRIPTION
        Enumerates the given patterns (archives and executables by default), sorts by file name,
        and writes lowercase SHA256 digests with LF endings and no BOM so sha256sum -c works.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [string[]]$Include = @('*.zip', '*.exe')
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        throw "Checksum destination not found: $Destination"
    }
    $destinationPath = (Resolve-Path -LiteralPath $Destination).Path

    $selected = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($file in @(Get-ChildItem -LiteralPath $destinationPath -File)) {
        if ($file.Name -eq 'SHA256SUMS.txt') { continue }
        foreach ($pattern in $Include) {
            if ($file.Name -like $pattern) { $selected.Add($file); break }
        }
    }
    $sorted = @($selected | Sort-Object Name)
    if ($sorted.Count -eq 0) {
        throw ("No artifacts matched {0} under {1}" -f ($Include -join ', '), $destinationPath)
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $lines = foreach ($file in $sorted) {
            $stream = [System.IO.File]::OpenRead($file.FullName)
            try {
                $hash = [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
            } finally {
                $stream.Dispose()
            }
            "$hash  $($file.Name)"
        }
    } finally {
        $sha.Dispose()
    }

    $sumsPath = Join-Path $destinationPath 'SHA256SUMS.txt'
    [System.IO.File]::WriteAllText($sumsPath, (($lines -join "`n") + "`n"), [System.Text.Encoding]::ASCII)
    return $sumsPath
}


function New-PSManagerBuildPackage {
    <#
    .SYNOPSIS
        Builds the release packages (full, desktop, cli-tui) with launchers and checksums.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'The certificate password is forwarded to signtool.exe /p')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Version,
        [ValidateSet('Launcher', 'Bundle')][string]$Mode = 'Launcher',
        [string]$IconPath,
        [string]$CertificatePath,
        [string]$CertificatePassword,
        [string]$CertificateThumbprint,
        [string]$Root = $Script:BuilderRoot
    )

    $info = Get-PSManagerBuildInfo -Root $Root
    if (-not $Version) { $Version = $info.Version }
    $metadata = ConvertTo-BuilderMetadata -Version $Version -Root $Root
    $IconPath = Resolve-BuilderIconPath -Explicit $IconPath -RootIconPath $info.IconPath
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $destinationPath = (Resolve-Path -LiteralPath $Destination).Path
    $stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('psmgr-stage-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

    $includeFull = @(
        'PSManager.psd1', 'PSManager.psm1', 'ps-manager.ps1', 'gui.ps1', 'boot.ps1',
        'config.json', 'i18n.json', 'README.md', 'CHANGELOG.md', 'PSScriptAnalyzerSettings.psd1',
        'modules', 'templates', 'ui'
    )
    $includeCli = @(
        'PSManager.psd1', 'PSManager.psm1', 'ps-manager.ps1', 'boot.ps1',
        'config.json', 'i18n.json', 'README.md', 'CHANGELOG.md',
        'modules', 'templates'
    )

    $includePortable = @(
        'PSManager.psd1', 'PSManager.psm1', 'ps-manager.ps1', 'gui.ps1', 'boot.ps1',
        'config.json', 'i18n.json', 'README.md',
        'assets', 'modules', 'templates', 'ui'
    )

    function Copy-Stage {
        param([string]$Name, [string[]]$Items)
        $stage = Join-Path $stageRoot $Name
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        foreach ($item in $Items) {
            $src = Join-Path $info.Root $item
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination $stage -Recurse -Force
            }
        }
        return $stage
    }

    function Assert-CleanStage {
        param([string]$Stage)
        $extensions = @('.ps1', '.psm1', '.psd1', '.json', '.xaml')
        $files = Get-ChildItem -LiteralPath $Stage -Recurse -File |
            Where-Object { $extensions -contains $_.Extension }
        foreach ($file in $files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            if ($text -match 'C:\\Users\\[A-Za-z0-9._-]+') {
                throw ("Refusing to package {0}: it contains a hard-coded developer path" -f $file.FullName)
            }
        }
    }

    function Get-PayloadFiles {
        param([string[]]$Items)
        $payload = @()
        foreach ($item in $Items) {
            $path = Join-Path $info.Root $item
            if (Test-Path -LiteralPath $path -PathType Container) {
                $payload += @(Get-ChildItem -LiteralPath $path -Recurse -File | ForEach-Object { $_.FullName.Substring($info.Root.Length + 1) })
            } elseif (Test-Path -LiteralPath $path) {
                $payload += $item
            }
        }
        return $payload
    }

    $results = New-Object System.Collections.Generic.List[object]
    try {
        $full = Copy-Stage -Name 'full' -Items $includeFull
        $desktop = Copy-Stage -Name 'desktop' -Items $includeFull
        $cli = Copy-Stage -Name 'cli' -Items $includeCli
        $portable = Copy-Stage -Name 'portable' -Items $includePortable
        $bundle = Copy-Stage -Name 'bundle' -Items @('README.md', 'config.json', 'i18n.json')

        $payloadFull = Get-PayloadFiles -Items $includeFull
        $payloadPortable = Get-PayloadFiles -Items $includePortable

        $signArgs = @{}
        if ($CertificatePath) { $signArgs['CertificatePath'] = $CertificatePath }
        if ($CertificatePassword) { $signArgs['CertificatePassword'] = $CertificatePassword }
        if ($CertificateThumbprint) { $signArgs['CertificateThumbprint'] = $CertificateThumbprint }

        if ($Mode -eq 'Bundle') {
            $bundleFullConsole = New-PSManagerLauncher -Destination (Join-Path $stageRoot '_built_full_console') -Name 'psmgr.exe' -ScriptName 'ps-manager.ps1' -Kind Console -Metadata $metadata -IconPath $IconPath -PayloadFiles $payloadFull -Root $Root @signArgs
            $bundleFullGui = New-PSManagerLauncher -Destination (Join-Path $stageRoot '_built_full_gui') -Name 'psmgr-gui.exe' -ScriptName 'gui.ps1' -Kind Windows -ExtraArguments '' -StaThread -Metadata $metadata -IconPath $IconPath -PayloadFiles $payloadFull -Root $Root @signArgs
            foreach ($stage in @($full, $desktop)) {
                Copy-Item -LiteralPath $bundleFullConsole -Destination (Join-Path $stage 'psmgr.exe') -Force
                Copy-Item -LiteralPath $bundleFullGui -Destination (Join-Path $stage 'psmgr-gui.exe') -Force
            }
            $null = New-PSManagerLauncher -Destination $cli -Name 'psmgr.exe' -ScriptName 'ps-manager.ps1' -Kind Console -Metadata $metadata -IconPath $IconPath -PayloadFiles (Get-PayloadFiles -Items $includeCli) -Root $Root @signArgs
        } else {
            $looseConsole = New-PSManagerLauncher -Destination (Join-Path $stageRoot '_built_loose_console') -Name 'psmgr.exe' -ScriptName 'ps-manager.ps1' -Kind Console -Metadata $metadata -IconPath $IconPath -Root $Root @signArgs
            foreach ($stage in @($full, $cli, $desktop, $portable)) {
                Copy-Item -LiteralPath $looseConsole -Destination (Join-Path $stage 'psmgr.exe') -Force
            }
            $looseGui = New-PSManagerLauncher -Destination (Join-Path $stageRoot '_built_loose_gui') -Name 'psmgr-gui.exe' -ScriptName 'gui.ps1' -Kind Windows -ExtraArguments '' -StaThread -Metadata $metadata -IconPath $IconPath -Root $Root @signArgs
            foreach ($stage in @($full, $desktop, $portable)) {
                Copy-Item -LiteralPath $looseGui -Destination (Join-Path $stage 'psmgr-gui.exe') -Force
            }
        }

        # Single-file bundle is always produced, independently of the launcher layout mode.
        $null = New-PSManagerLauncher -Destination $bundle -Name 'psmgr.exe' -ScriptName 'ps-manager.ps1' -Kind Console -Metadata $metadata -IconPath $IconPath -PayloadFiles $payloadPortable -Root $Root @signArgs
        $null = New-PSManagerLauncher -Destination $bundle -Name 'psmgr-gui.exe' -ScriptName 'gui.ps1' -Kind Windows -ExtraArguments '' -StaThread -Metadata $metadata -IconPath $IconPath -PayloadFiles $payloadPortable -Root $Root @signArgs

        $cmdShim = @"
@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ps-manager.ps1" %*
exit /b %ERRORLEVEL%
"@
        $guiShim = @"
@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui.ps1" %*
exit /b %ERRORLEVEL%
"@
        foreach ($stage in @($full, $cli, $desktop, $portable)) {
            [System.IO.File]::WriteAllText((Join-Path $stage 'psmgr.cmd'), ($cmdShim -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)
        }
        foreach ($stage in @($full, $desktop, $portable)) {
            [System.IO.File]::WriteAllText((Join-Path $stage 'psmgr-gui.cmd'), ($guiShim -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)
            [System.IO.File]::WriteAllText((Join-Path $stage 'PSManager-GUI.cmd'), ("@echo off`r`nstart powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0gui.ps1`"`r`n"), [System.Text.Encoding]::ASCII)
        }

        foreach ($stage in @($full, $cli, $desktop, $portable)) { Assert-CleanStage -Stage $stage }

        $zips = @(
            @{ Stage = $full;     Name = "psmgr-$Version-windows-full.zip" },
            @{ Stage = $cli;      Name = "psmgr-$Version-windows-cli-tui.zip" },
            @{ Stage = $desktop;  Name = "psmgr-$Version-windows-desktop.zip" },
            @{ Stage = $portable; Name = "psmgr-$Version-windows-portable.zip" },
            @{ Stage = $bundle;   Name = "psmgr-$Version-windows-bundle.zip" }
        )
        foreach ($zip in $zips) {
            $zipPath = Join-Path $destinationPath $zip.Name
            if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
            Compress-Archive -Path (Join-Path $zip.Stage '*') -DestinationPath $zipPath -CompressionLevel Optimal
            $results.Add([pscustomobject]@{ Path = $zipPath; SizeBytes = (Get-Item -LiteralPath $zipPath).Length })
        }

        $null = New-PSManagerChecksumFile -Destination $destinationPath
    } finally {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $results.ToArray()
}

function Resolve-BuilderInnoCompiler {
    <#
    .SYNOPSIS
        Locates ISCC.exe (Inno Setup 6) or returns $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$CompilerPath)

    if ($CompilerPath) {
        if (Test-Path -LiteralPath $CompilerPath) { return (Resolve-Path -LiteralPath $CompilerPath).Path }
        return $null
    }
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs'),
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles
    )
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $candidate = Join-Path $root 'Inno Setup 6\ISCC.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function New-PSManagerInstaller {
    <#
    .SYNOPSIS
        Builds PSManager-<version>-Setup.exe with Inno Setup 6.
    .DESCRIPTION
        Stages the launcher layout, generates a bilingual Inno script (per-user by default,
        /AllUsers override, shortcuts, PATH entry, uninstall registration) and compiles it.
        Throws with an actionable message when ISCC.exe is unavailable, unless -SkipIfMissing.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'The certificate password is forwarded to signtool.exe /p')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Version,
        [string]$IconPath,
        [string]$CompilerPath,
        [pscustomobject]$Metadata,
        [string]$CertificatePath,
        [string]$CertificatePassword,
        [string]$CertificateThumbprint,
        [string]$Root = $Script:BuilderRoot,
        [switch]$SkipIfMissing
    )

    $info = Get-PSManagerBuildInfo -Root $Root
    if (-not $Version) { $Version = $info.Version }
    $resolved = ConvertTo-BuilderMetadata -Metadata $Metadata -Version $Version -Root $Root
    $IconPath = Resolve-BuilderIconPath -Explicit $IconPath -RootIconPath $info.IconPath
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $destinationPath = (Resolve-Path -LiteralPath $Destination).Path

    $iscc = Resolve-BuilderInnoCompiler -CompilerPath $CompilerPath
    if (-not $iscc) {
        $message = 'Inno Setup 6 (ISCC.exe) was not found. Install it with "winget install JRSoftware.InnoSetup" or pass -CompilerPath.'
        if ($SkipIfMissing) {
            Write-Warning $message
            return $null
        }
        throw $message
    }

    $stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('psmgr-inno-' + [guid]::NewGuid().ToString('N'))
    $stage = Join-Path $stageRoot 'app'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $include = @(
        'PSManager.psd1', 'PSManager.psm1', 'ps-manager.ps1', 'gui.ps1', 'boot.ps1',
        'config.json', 'i18n.json', 'README.md', 'CHANGELOG.md', 'PSScriptAnalyzerSettings.psd1',
        'assets', 'modules', 'templates', 'ui'
    )

    try {
        foreach ($item in $include) {
            $src = Join-Path $info.Root $item
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination $stage -Recurse -Force
            }
        }
        $signArgs = @{}
        if ($CertificatePath) { $signArgs['CertificatePath'] = $CertificatePath }
        if ($CertificatePassword) { $signArgs['CertificatePassword'] = $CertificatePassword }
        if ($CertificateThumbprint) { $signArgs['CertificateThumbprint'] = $CertificateThumbprint }
        $null = New-PSManagerLauncher -Destination $stage -Name 'psmgr.exe' -ScriptName 'ps-manager.ps1' -Kind Console -Metadata $resolved -IconPath $IconPath -Root $Root @signArgs
        $null = New-PSManagerLauncher -Destination $stage -Name 'psmgr-gui.exe' -ScriptName 'gui.ps1' -Kind Windows -ExtraArguments '' -StaThread -Metadata $resolved -IconPath $IconPath -Root $Root @signArgs

        $cmdShim = "@echo off`r`nsetlocal`r`nchcp 65001 >nul`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0ps-manager.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
        $guiShim = "@echo off`r`nsetlocal`r`nchcp 65001 >nul`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0gui.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
        [System.IO.File]::WriteAllText((Join-Path $stage 'psmgr.cmd'), $cmdShim, [System.Text.Encoding]::ASCII)
        [System.IO.File]::WriteAllText((Join-Path $stage 'psmgr-gui.cmd'), $guiShim, [System.Text.Encoding]::ASCII)

        $compilerDir = Split-Path -Parent $iscc
        $vietnamese = Join-Path $compilerDir 'Languages\Vietnamese.isl'
        $languages = 'Name: "english"; MessagesFile: "compiler:Default.isl"'
        if (Test-Path -LiteralPath $vietnamese) {
            $languages += "`r`nName: ""vietnamese""; MessagesFile: ""compiler:Languages\Vietnamese.isl"""
        }

        $versionInfo = Get-BuilderAssemblyVersion -Version $resolved.Version
        $iss = @"
#define MyAppName "$($resolved.Product)"
#define MyAppVersion "$($resolved.Version)"
#define MyAppPublisher "$($resolved.Company)"
#define MyAppURL "$($resolved.RepositoryUrl)"
#define MyAppExeName "psmgr-gui.exe"

[Setup]
AppId={{A7B8E1F2-9C3D-4E5F-A6B7-8C9D0E1F2A3B}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\PSManager
DefaultGroupName=PSManager
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline dialog
OutputDir=$destinationPath
OutputBaseFilename=PSManager-$($resolved.Version)-Setup
SetupIconFile=$IconPath
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
VersionInfoVersion=$versionInfo
VersionInfoCompany=$($resolved.Company)
VersionInfoDescription=$($resolved.Description)
VersionInfoCopyright=$($resolved.Copyright)
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
ChangesEnvironment=yes

[Languages]
$languages

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
Name: "addtopath"; Description: "Add PSManager to PATH"; GroupDescription: "Integration"; Flags: checkedonce

[Files]
Source: "$stage\*"; DestDir: "{app}"; Excludes: "config.json"; Flags: ignoreversion recursesubdirs createallsubdirs
; User configuration survives upgrades and uninstalls.
Source: "$stage\config.json"; DestDir: "{app}"; Flags: onlyifdoesntexist uninsneveruninstall

[Icons]
; AppUserModelID ties the Start Menu shortcut to the window identity (gui.ps1 sets the same
; id on the WPF HWND) so the taskbar shows the PSManager name and icon, and toasts resolve.
Name: "{autoprograms}\PSManager"; Filename: "{app}\{#MyAppExeName}"; AppUserModelID: "PSManager.Desktop"
Name: "{autoprograms}\PSManager TUI"; Filename: "{app}\psmgr.exe"; AppUserModelID: "PSManager.TUI"
Name: "{autodesktop}\PSManager"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon; AppUserModelID: "PSManager.Desktop"

[Registry]
Root: HKCU; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; Tasks: addtopath; Check: (not IsAdminInstallMode) and NeedsAddPath(ExpandConstant('{app}'))
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; Tasks: addtopath; Check: IsAdminInstallMode and NeedsAddPath(ExpandConstant('{app}'))

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch PSManager"; Flags: nowait postinstall skipifsilent; Check: ShouldLaunchApp

[UninstallDelete]
Type: filesandordirs; Name: "{app}\logs"

[Code]
{ Automation reads PSMGR_NOLAUNCH: Inno rejects unknown command-line switches, so an
  unattended install signals "do not launch" through the environment instead. }
function ShouldLaunchApp(): Boolean;
begin
  Result := GetEnv('PSMGR_NOLAUNCH') = '';
end;

function GetEnvRootKey(): Integer;
begin
  if IsAdminInstallMode then
    Result := HKEY_LOCAL_MACHINE
  else
    Result := HKEY_CURRENT_USER;
end;

function GetEnvSubkey(): string;
begin
  if IsAdminInstallMode then
    Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  else
    Result := 'Environment';
end;

function NeedsAddPath(Param: string): boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(GetEnvRootKey(), GetEnvSubkey(), 'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  Result := Pos(';' + Uppercase(Param) + ';', ';' + Uppercase(OrigPath) + ';') = 0;
end;

procedure RemoveFromPath(AppDir: string);
var
  RootKey: Integer;
  Subkey, Path, NewPath: string;
begin
  RootKey := GetEnvRootKey();
  Subkey := GetEnvSubkey();
  if RegQueryStringValue(RootKey, Subkey, 'Path', Path) then
  begin
    NewPath := Path;
    StringChangeEx(NewPath, ';' + AppDir, '', True);
    StringChangeEx(NewPath, AppDir + ';', '', True);
    if NewPath <> Path then
      RegWriteExpandStringValue(RootKey, Subkey, 'Path', NewPath);
  end;
  { Also clean HKCU in case a previous per-user install existed }
  if IsAdminInstallMode and RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path) then
  begin
    NewPath := Path;
    StringChangeEx(NewPath, ';' + AppDir, '', True);
    StringChangeEx(NewPath, AppDir + ';', '', True);
    if NewPath <> Path then
      RegWriteExpandStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', NewPath);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    RemoveFromPath(ExpandConstant('{app}'));
end;
"@
        $issPath = Join-Path $stageRoot 'psmgr.iss'
        [System.IO.File]::WriteAllText($issPath, $iss, (New-Object System.Text.UTF8Encoding($false)))
        $output = & $iscc '/Qp' $issPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("ISCC failed with exit code {0}:{1}{2}" -f $LASTEXITCODE, [Environment]::NewLine, ($output -join [Environment]::NewLine))
        }

        $setupPath = Join-Path $destinationPath ("PSManager-" + $resolved.Version + "-Setup.exe")
        if (-not (Test-Path -LiteralPath $setupPath)) {
            throw "ISCC reported success but $setupPath is missing."
        }
        if ($CertificatePath -or $CertificateThumbprint) {
            $null = Invoke-PSManagerCodeSign -Path @($setupPath) -CertificatePath $CertificatePath -CertificatePassword $CertificatePassword -CertificateThumbprint $CertificateThumbprint
        }
        return $setupPath
    } finally {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @(
    'Get-PSManagerBuildInfo',
    'ConvertTo-BuilderMetadata',
    'Resolve-BuilderCompiler',
    'New-PSManagerLauncher',
    'New-PSManagerBuildIcon',
    'Test-PSManagerBuild',
    'New-PSManagerBuildPackage',
    'New-PSManagerChecksumFile',
    'New-PSManagerInstaller',
    'Resolve-BuilderInnoCompiler',
    'Invoke-PSManagerCodeSign',
    'Test-PSManagerSignature'
)
