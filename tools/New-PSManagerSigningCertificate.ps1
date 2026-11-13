#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a self-signed code-signing certificate for PSManager artifacts.
.DESCRIPTION
    Generates a Code Signing certificate (EKU 1.3.6.1.5.5.7.3.3, Digital Signature key usage,
    SHA-256) in the current user's personal store, exports it as a password-protected .pfx plus a
    public .cer, and can trust it on this machine.

    A self-signed certificate removes the "unsigned binary" signal that antivirus heuristics and
    SmartScreen react to, and shows a publisher name. It does NOT buy SmartScreen reputation:
    machines that have not trusted the certificate still warn on first run. For distribution
    without warnings, use a commercial OV/EV certificate, or deploy this .cer to
    Trusted Root + Trusted Publishers (for example through Group Policy).
.PARAMETER Subject
    Certificate subject. Defaults to CN=PSManager Self-Signed Code Signing.
.PARAMETER PfxPath
    Destination .pfx file. Defaults to <repo>\certs\psmgr-codesign.pfx.
.PARAMETER Password
    .pfx password. Defaults to PSMGR_CERT_PASSWORD or a generated password echoed once.
.PARAMETER CerPath
    Destination public .cer file. Defaults next to the .pfx.
.PARAMETER Years
    Validity in years (1-10). Defaults to 3.
.PARAMETER Trust
    Install the .cer into CurrentUser\TrustedPublisher (silent) and print the command for the
    Trusted Root store.
.PARAMETER TrustRoot
    Also import the .cer into CurrentUser\Root. Windows shows a security confirmation dialog, so
    this is opt-in and unsuitable for unattended runs.
.PARAMETER Force
    Overwrite existing certificate files.
.EXAMPLE
    .\tools\New-PSManagerSigningCertificate.ps1 -Trust
.EXAMPLE
    $cert = .\tools\New-PSManagerSigningCertificate.ps1 -Password 'p@ss' -Force
    .\build\build.ps1 -Action all -Destination C:\temp\dist -CertificatePath $cert.PfxPath -CertificatePassword $cert.Password
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
    Justification = 'The .pfx password is required to export the signing key')]
param(
    [string]$Subject = 'CN=PSManager Self-Signed Code Signing',
    [string]$PfxPath = '',
    [string]$Password = $env:PSMGR_CERT_PASSWORD,
    [string]$CerPath = '',
    [ValidateRange(1, 10)]
    [int]$Years = 3,
    [switch]$Trust,
    [switch]$TrustRoot,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $PfxPath) { $PfxPath = Join-Path $repoRoot 'certs\psmgr-codesign.pfx' }
if (-not $CerPath) { $CerPath = [System.IO.Path]::ChangeExtension($PfxPath, '.cer') }

if ((Test-Path -LiteralPath $PfxPath) -and -not $Force) {
    throw ("Certificate already exists: {0}. Pass -Force to replace it." -f $PfxPath)
}

$generated = $false
if (-not $Password) {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $Password = [Convert]::ToBase64String($bytes).Replace('/', 'a').Replace('+', 'b').Replace('=', '')
    $generated = $true
}

# Build the certificate through the .NET API: the Cert: provider is not available in every
# PowerShell host, while CertificateRequest works on both Windows PowerShell 5.1 and 7.

$rsa = [System.Security.Cryptography.RSA]::Create(3072)
try {
    $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest(
        (New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName($Subject)),
        $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

    $ekuOids = New-Object System.Security.Cryptography.OidCollection
    $null = $ekuOids.Add((New-Object System.Security.Cryptography.Oid('1.3.6.1.5.5.7.3.3', 'Code Signing')))
    $request.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension($ekuOids, $false)))
    $request.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509KeyUsageExtension(
        [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true)))
    $request.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($false, $false, 0, $true)))
    $request.CertificateExtensions.Add((New-Object System.Security.Cryptography.X509Certificates.X509SubjectKeyIdentifierExtension($request.PublicKey, $false)))

    $cert = $request.CreateSelfSigned(
        [DateTimeOffset]::Now.AddDays(-1),
        [DateTimeOffset]::Now.AddYears($Years))
} finally {
    $rsa.Dispose()
}

$pfxDir = Split-Path -Parent $PfxPath
if ($pfxDir -and -not (Test-Path -LiteralPath $pfxDir)) {
    New-Item -ItemType Directory -Path $pfxDir -Force | Out-Null
}
$cerDir = Split-Path -Parent $CerPath
if ($cerDir -and -not (Test-Path -LiteralPath $cerDir)) {
    New-Item -ItemType Directory -Path $cerDir -Force | Out-Null
}

[System.IO.File]::WriteAllBytes($PfxPath, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $Password))
[System.IO.File]::WriteAllBytes($CerPath, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))

# Register the public certificate for the current user. The private key stays in the .pfx; import
# it with certmgr.msc if you prefer signing by thumbprint instead of by file.
$keyed = $cert
$personal = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'CurrentUser')
try {
    $personal.Open('ReadWrite')
    $personal.Add($cert)
} finally {
    $personal.Close()
}

# TrustedPublisher accepts a programmatic install. The Root store raises a Windows security
# confirmation dialog, which blocks any unattended run, so it is opt-in via -TrustRoot.
$rootTrusted = $false
if ($Trust -or $TrustRoot) {
    $publisher = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'CurrentUser')
    try {
        $publisher.Open('ReadWrite')
        $publisher.Add($keyed)
    } finally {
        $publisher.Close()
    }
}

if ($TrustRoot) {
    $certutil = Join-Path $env:WINDIR 'System32\certutil.exe'
    & $certutil -user -f -addstore Root $CerPath | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $rootTrusted = $true
    } else {
        Write-Warning ('Root store import failed (exit {0}). Import {1} manually with certmgr.msc.' -f $LASTEXITCODE, $CerPath)
    }
} elseif ($Trust) {
    Write-Host ''
    Write-Host 'Trusted Publisher installed. To make the certificate chain valid on this machine, add it to' -ForegroundColor Yellow
    Write-Host 'the Trusted Root store once (Windows shows a confirmation dialog):' -ForegroundColor Yellow
    Write-Host ('  certutil -user -f -addstore Root "' + $CerPath + '"') -ForegroundColor Yellow
    Write-Host 'Or re-run this script with -TrustRoot and confirm the dialog.' -ForegroundColor Yellow
}

if ($generated) {
    Write-Warning ('Generated .pfx password (store it; it cannot be recovered): ' + $Password)
}

return [pscustomobject]@{
    Subject      = $keyed.Subject
    Thumbprint   = $keyed.Thumbprint
    NotAfter     = $keyed.NotAfter
    PfxPath      = $PfxPath
    CerPath      = $CerPath
    Password     = $Password
    Trusted      = [bool]$Trust
    StorePath    = ('Cert:\CurrentUser\My\' + $keyed.Thumbprint)
}
