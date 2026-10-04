$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$sourceIcon = [Drawing.Icon]::new((Join-Path $PSScriptRoot 'logo-rounded.ico'))
$sourceBitmap = $sourceIcon.ToBitmap()
$frames = @()
try {
    foreach ($size in @(16, 32, 48, 64)) {
        $bitmap = [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $stream = [IO.MemoryStream]::new()
        try {
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($sourceBitmap, 0, 0, $size, $size)
            $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
            $frames += [pscustomobject]@{Size=$size; Bytes=$stream.ToArray()}
        } finally { $stream.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
    }
    $output = [IO.File]::Create((Join-Path $PSScriptRoot 'usb-CybersecurityMonitor.ico'))
    $writer = [IO.BinaryWriter]::new($output)
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
        $offset = 6 + 16 * $frames.Count
        foreach ($frame in $frames) {
            $writer.Write([byte]$frame.Size); $writer.Write([byte]$frame.Size)
            $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([uint16]1); $writer.Write([uint16]32)
            $writer.Write([uint32]$frame.Bytes.Length); $writer.Write([uint32]$offset)
            $offset += $frame.Bytes.Length
        }
        foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
    } finally { $writer.Dispose() }
} finally { $sourceBitmap.Dispose(); $sourceIcon.Dispose() }
