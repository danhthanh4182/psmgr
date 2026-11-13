#Requires -Version 5.1
<#
.SYNOPSIS
    Generates assets/psmgr.ico, the icon embedded in the release launchers.
.DESCRIPTION
    Draws a dark rounded tile with the PSManager accent chevron and "PS" monogram at every icon
    size Windows asks for (16-256 px), then writes a multi-image ICO container. No external
    tooling: System.Drawing is part of the .NET Framework that ships with Windows.
.PARAMETER OutputPath
    Target .ico file. Defaults to assets/psmgr.ico next to the repository root.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = ''
)

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\psmgr.ico'
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$background = [System.Drawing.Color]::FromArgb(255, 15, 23, 42)
$accent = [System.Drawing.Color]::FromArgb(255, 56, 189, 248)
$foreground = [System.Drawing.Color]::FromArgb(255, 226, 232, 240)

function New-IconFrame {
    param([Parameter(Mandatory = $true)][int]$Size)

    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $radius = [Math]::Max(2, [int]($Size * 0.22))
        $rect = New-Object System.Drawing.RectangleF(0, 0, $Size, $Size)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $diameter = $radius * 2
        $path.AddArc(0, 0, $diameter, $diameter, 180, 90)
        $path.AddArc($Size - $diameter, 0, $diameter, $diameter, 270, 90)
        $path.AddArc($Size - $diameter, $Size - $diameter, $diameter, $diameter, 0, 90)
        $path.AddArc(0, $Size - $diameter, $diameter, $diameter, 90, 90)
        $path.CloseFigure()

        $backgroundBrush = New-Object System.Drawing.SolidBrush($background)
        $graphics.FillPath($backgroundBrush, $path)

        # Accent chevron along the left edge.
        $penWidth = [Math]::Max(1.0, $Size * 0.075)
        $pen = New-Object System.Drawing.Pen($accent, $penWidth)
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $points = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF(($Size * 0.20), ($Size * 0.30))),
            (New-Object System.Drawing.PointF(($Size * 0.38), ($Size * 0.50))),
            (New-Object System.Drawing.PointF(($Size * 0.20), ($Size * 0.70)))
        )
        $graphics.DrawLines($pen, $points)

        # Monogram.
        $fontSize = [Math]::Max(5.0, $Size * 0.40)
        $font = New-Object System.Drawing.Font('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $format = New-Object System.Drawing.StringFormat
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $textBrush = New-Object System.Drawing.SolidBrush($foreground)
        $textRect = New-Object System.Drawing.RectangleF(($Size * 0.30), 0, ($Size * 0.62), $Size)
        $graphics.DrawString('PS', $font, $textBrush, $textRect, $format)

        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$frames = @()
foreach ($size in $sizes) {
    $frames += [pscustomobject]@{ Size = $size; Bytes = (New-IconFrame -Size $size) }
}

$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$file = [System.IO.File]::Create($OutputPath)
try {
    $writer = New-Object System.IO.BinaryWriter($file)
    # ICONDIR
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$frames.Count)

    # ICONDIRENTRY per image; offset is relative to the start of the file.
    $offset = 6 + (16 * $frames.Count)
    foreach ($frame in $frames) {
        $dimension = if ($frame.Size -ge 256) { 0 } else { $frame.Size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$frame.Bytes.Length)
        $writer.Write([uint32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) {
        $writer.Write($frame.Bytes)
    }
    $writer.Flush()
} finally {
    $file.Dispose()
}

# Verbose, not Write-Host: this script runs inside the MCP server, where host output would corrupt
# the JSON-RPC stream on stdout.
Write-Verbose ("Icon written: " + $OutputPath + " (" + (Get-Item -LiteralPath $OutputPath).Length + " bytes, " + $frames.Count + " sizes)")
