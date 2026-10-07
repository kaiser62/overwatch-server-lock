# Regenerates assets/icon.ico (crosshair target on dark tile). PNG-compressed ICO, 16-256 px.
Add-Type -AssemblyName System.Drawing
$out   = Join-Path $PSScriptRoot 'icon.ico'
$sizes = 16, 24, 32, 48, 64, 128, 256

function New-IconPng([int]$s) {
    $bmp = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)

    # rounded dark tile
    $r = [math]::Max(2, [int]($s * 0.22))
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $r * 2, $r * 2, 180, 90)
    $path.AddArc($s - $r * 2 - 1, 0, $r * 2, $r * 2, 270, 90)
    $path.AddArc($s - $r * 2 - 1, $s - $r * 2 - 1, $r * 2, $r * 2, 0, 90)
    $path.AddArc(0, $s - $r * 2 - 1, $r * 2, $r * 2, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(24, 26, 32))), $path)

    # orange ring + crosshair ticks + center dot
    $orange = [Drawing.Color]::FromArgb(249, 158, 26)
    $w = [math]::Max(1.5, $s * 0.085)
    $pen = New-Object Drawing.Pen $orange, $w
    $m = $s * 0.24
    $g.DrawEllipse($pen, $m, $m, $s - 2 * $m, $s - 2 * $m)
    $c = $s / 2
    $tick = $s * 0.13
    $g.DrawLine($pen, $c, $m - $tick * 0.6, $c, $m + $tick)
    $g.DrawLine($pen, $c, $s - $m + $tick * 0.6, $c, $s - $m - $tick)
    $g.DrawLine($pen, $m - $tick * 0.6, $c, $m + $tick, $c)
    $g.DrawLine($pen, $s - $m + $tick * 0.6, $c, $s - $m - $tick, $c)
    $d = $s * 0.12
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::White)), $c - $d / 2, $c - $d / 2, $d, $d)
    $g.Dispose()

    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    , $ms.ToArray()
}

$pngs = foreach ($s in $sizes) { , (New-IconPng $s) }
$fs = [IO.File]::Create($out)
$bw = New-Object IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256))   # 256 is stored as 0
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Dispose()
Write-Host "Wrote $out"
