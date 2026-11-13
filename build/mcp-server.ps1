#Requires -Version 5.1
<#
.SYNOPSIS
    PSManager Builder MCP server - exposes the builder over stdio JSON-RPC 2.0.
.DESCRIPTION
    Line-delimited JSON-RPC on stdin/stdout. stdout carries protocol messages only; diagnostics go
    to stderr. Tools: build_info, build_icon, build_launcher, build_app, package_release,
    verify_build. Run it from an MCP client with:
        pwsh -NoProfile -File build/mcp-server.ps1
#>
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$builderModule = Join-Path $PSScriptRoot 'PSManager.Builder.psm1'
Import-Module $builderModule -Force -WarningAction SilentlyContinue
$script:Root = Split-Path -Parent $PSScriptRoot

function Write-McpServerLog {
    param([string]$Message)
    try { [Console]::Error.WriteLine("[psmgr-builder] " + $Message) } catch { }
}

function Send-Message {
    param([Parameter(Mandatory = $true)][hashtable]$Message)
    $json = $Message | ConvertTo-Json -Depth 20 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Send-Result {
    param($Id, $Result)
    Send-Message @{ jsonrpc = '2.0'; id = $Id; result = $Result }
}

function Send-Error {
    param($Id, [int]$Code, [string]$Message, $Data)
    $errorObject = @{ code = $Code; message = $Message }
    if ($null -ne $Data) { $errorObject.data = $Data }
    Send-Message @{ jsonrpc = '2.0'; id = $Id; error = $errorObject }
}

function Get-ArgumentValue {
    param($Arguments, [string]$Name, $Default = $null)
    if ($null -eq $Arguments) { return $Default }
    $property = $Arguments.PSObject.Properties[$Name]
    if ($null -ne $property -and $null -ne $property.Value -and "$($property.Value)" -ne '') {
        return $property.Value
    }
    return $Default
}

$script:Info = Get-PSManagerBuildInfo -Root $script:Root

$script:Tools = @(
    @{
        name        = 'build_info'
        description = 'Repository, version and default metadata used by every build.'
        inputSchema = @{ type = 'object'; properties = @{}; additionalProperties = $false }
    }
    @{
        name        = 'build_icon'
        description = 'Generate the multi-size application icon (ICO).'
        inputSchema = @{
            type       = 'object'
            properties = @{ outputPath = @{ type = 'string'; description = 'Target .ico path' } }
            additionalProperties = $false
        }
    }
    @{
        name        = 'build_launcher'
        description = 'Compile one launcher executable with metadata, icon and optional embedded payload.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                destination  = @{ type = 'string' }
                name         = @{ type = 'string' }
                scriptName   = @{ type = 'string' }
                kind         = @{ type = 'string'; enum = @('Console', 'Windows') }
                extraArguments = @{ type = 'string' }
                staThread    = @{ type = 'boolean' }
                requireAdmin = @{ type = 'boolean' }
                iconPath     = @{ type = 'string' }
            }
            required   = @('destination', 'name', 'scriptName')
            additionalProperties = $false
        }
    }
    @{
        name        = 'build_app'
        description = 'Build psmgr.exe and psmgr-gui.exe into a destination directory.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                destination  = @{ type = 'string' }
                version      = @{ type = 'string' }
                iconPath     = @{ type = 'string' }
                requireAdmin = @{ type = 'boolean' }
            }
            required   = @('destination')
            additionalProperties = $false
        }
    }
    @{
        name        = 'package_release'
        description = 'Build the full, desktop and CLI/TUI archives with launchers and SHA256SUMS.txt.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                destination = @{ type = 'string' }
                version     = @{ type = 'string' }
                mode        = @{ type = 'string'; enum = @('Launcher', 'Bundle') }
                iconPath    = @{ type = 'string' }
            }
            required   = @('destination')
            additionalProperties = $false
        }
    }
    @{
        name        = 'verify_build'
        description = 'Check version metadata, embedded icon and (optionally) a smoke run.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                path            = @{ type = 'string' }
                expectedVersion = @{ type = 'string' }
                smokeRun        = @{ type = 'boolean' }
            }
            required   = @('path')
            additionalProperties = $false
        }
    }
    @{
        name        = 'build_installer'
        description = 'Build PSManager-<version>-Setup.exe with Inno Setup 6.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                destination  = @{ type = 'string' }
                version      = @{ type = 'string' }
                iconPath     = @{ type = 'string' }
                compilerPath = @{ type = 'string' }
            }
            required   = @('destination')
            additionalProperties = $false
        }
    }
    @{
        name        = 'sign_artifacts'
        description = 'Sign executables with signtool and a supplied certificate.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                paths               = @{ type = 'array'; items = @{ type = 'string' } }
                destination         = @{ type = 'string' }
                certificatePath     = @{ type = 'string' }
                certificatePassword = @{ type = 'string' }
            }
            required   = @('certificatePath')
            additionalProperties = $false
        }
    }
)

function Invoke-Tool {
    param([string]$Name, $Arguments)

    switch ($Name) {
        'build_info' {
            return $script:Info
        }
        'build_icon' {
            $outputPath = Get-ArgumentValue $Arguments 'outputPath'
            return @{ path = (New-PSManagerBuildIcon -OutputPath $outputPath) }
        }
        'build_launcher' {
            $kind = [string](Get-ArgumentValue $Arguments 'kind' 'Console')
            $path = New-PSManagerLauncher `
                -Destination ([string](Get-ArgumentValue $Arguments 'destination')) `
                -Name ([string](Get-ArgumentValue $Arguments 'name')) `
                -ScriptName ([string](Get-ArgumentValue $Arguments 'scriptName')) `
                -Kind $kind `
                -ExtraArguments ([string](Get-ArgumentValue $Arguments 'extraArguments' '')) `
                -StaThread:([bool](Get-ArgumentValue $Arguments 'staThread' $false)) `
                -RequireAdmin:([bool](Get-ArgumentValue $Arguments 'requireAdmin' $false)) `
                -IconPath ([string](Get-ArgumentValue $Arguments 'iconPath' ''))
            return @{ path = $path }
        }
        'build_app' {
            $destination = [string](Get-ArgumentValue $Arguments 'destination')
            $version = [string](Get-ArgumentValue $Arguments 'version' '')
            $iconPath = [string](Get-ArgumentValue $Arguments 'iconPath' '')
            $requireAdmin = [bool](Get-ArgumentValue $Arguments 'requireAdmin' $false)
            $metadata = ConvertTo-BuilderMetadata -Version $version
            $console = New-PSManagerLauncher -Destination $destination -Name 'psmgr.exe' -ScriptName 'ps-manager.ps1' `
                -Kind Console -Metadata $metadata -IconPath $iconPath -RequireAdmin:$requireAdmin
            $gui = New-PSManagerLauncher -Destination $destination -Name 'psmgr-gui.exe' -ScriptName 'gui.ps1' `
                -Kind Windows -ExtraArguments '' -StaThread -Metadata $metadata -IconPath $iconPath
            return @{ launchers = @($console, $gui) }
        }
        'package_release' {
            $archives = New-PSManagerBuildPackage `
                -Destination ([string](Get-ArgumentValue $Arguments 'destination')) `
                -Version ([string](Get-ArgumentValue $Arguments 'version' '')) `
                -Mode ([string](Get-ArgumentValue $Arguments 'mode' 'Launcher')) `
                -IconPath ([string](Get-ArgumentValue $Arguments 'iconPath' ''))
            return @{ archives = @($archives | ForEach-Object { @{ path = $_.Path; sizeBytes = $_.SizeBytes } }) }
        }
        'build_installer' {
            $setup = New-PSManagerInstaller `
                -Destination ([string](Get-ArgumentValue $Arguments 'destination')) `
                -Version ([string](Get-ArgumentValue $Arguments 'version' '')) `
                -IconPath ([string](Get-ArgumentValue $Arguments 'iconPath' '')) `
                -CompilerPath ([string](Get-ArgumentValue $Arguments 'compilerPath' ''))
            return @{ path = $setup }
        }
        'sign_artifacts' {
            $paths = @()
            $explicit = Get-ArgumentValue $Arguments 'paths'
            if ($explicit) { $paths = @($explicit) }
            else {
                $destination = [string](Get-ArgumentValue $Arguments 'destination' '')
                if ($destination) {
                    $paths = @(Get-ChildItem -LiteralPath $destination -Filter '*.exe' | ForEach-Object { $_.FullName })
                }
            }
            if ($paths.Count -eq 0) { throw 'No executables to sign.' }
            Invoke-PSManagerCodeSign -Path $paths `
                -CertificatePath ([string](Get-ArgumentValue $Arguments 'certificatePath')) `
                -CertificatePassword ([string](Get-ArgumentValue $Arguments 'certificatePassword' ''))
            return @{ signed = $paths }
        }
        'verify_build' {
            $report = Test-PSManagerBuild `
                -Path ([string](Get-ArgumentValue $Arguments 'path')) `
                -ExpectedVersion ([string](Get-ArgumentValue $Arguments 'expectedVersion' '')) `
                -SmokeRun:([bool](Get-ArgumentValue $Arguments 'smokeRun' $false))
            return $report
        }
        default {
            throw "Unknown tool: $Name"
        }
    }
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if (-not $line) { continue }

    $request = $null
    try {
        $request = $line | ConvertFrom-Json
    } catch {
        Send-Error $null -32700 'Parse error'
        continue
    }

    $id = $request.id
    $method = [string]$request.method
    Write-McpServerLog ("request: " + $method)

    try {
        switch ($method) {
            'initialize' {
                Send-Result $id @{
                    protocolVersion = '2024-11-05'
                    capabilities    = @{ tools = @{ listChanged = $false } }
                    serverInfo      = @{ name = 'psmgr-builder'; version = [string]$script:Info.Version }
                }
            }
            'notifications/initialized' { }
            'ping' { Send-Result $id @{} }
            'tools/list' { Send-Result $id @{ tools = $script:Tools } }
            'tools/call' {
                $toolName = [string]$request.params.name
                $toolArgs = $request.params.arguments
                try {
                    $payload = Invoke-Tool -Name $toolName -Arguments $toolArgs
                    $text = $payload | ConvertTo-Json -Depth 10 -Compress
                    Send-Result $id @{ content = @(@{ type = 'text'; text = $text }); isError = $false }
                } catch {
                    $message = $_.Exception.Message
                    Write-McpServerLog ("tool error: " + $message)
                    Send-Result $id @{
                        content = @(@{ type = 'text'; text = $message })
                        isError = $true
                    }
                }
            }
            'shutdown' { Send-Result $id @{} }
            'exit' { break }
            default {
                Send-Error $id -32601 ("Method not found: " + $method)
            }
        }
    } catch {
        Send-Error $id -32603 $_.Exception.Message
    }

    if ($method -eq 'exit') { break }
}
