<#
    Builds dist\ThunderbirdMailFix.exe - one self-contained file with the whole tool inside.
    Uses the C# compiler that ships with Windows (.NET Framework 4), nothing to install.

      powershell -ExecutionPolicy Bypass -File .\build.ps1
#>
param(
    [string]$Script = "$PSScriptRoot\Thunderbird-Fix-Tool.ps1",
    [string]$Out    = "$PSScriptRoot\dist\ThunderbirdMailFix.exe",
    [ValidateSet('highestAvailable', 'requireAdministrator', 'asInvoker')]
    [string]$Level  = 'highestAvailable',
    [switch]$NewIcon
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$buildDir = "$PSScriptRoot\build"
$icon     = "$buildDir\app.ico"

function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath; $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); $p
}

# App icon: blue tile, white envelope, green check badge - packed as a multi-size PNG .ico
function New-AppIcon($path) {
    $images = foreach ($s in 256, 128, 64, 48, 32, 24, 16) {
        $k = $s / 256.0
        $bmp = New-Object Drawing.Bitmap($s, $s)
        $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
        $tile = New-RoundRect (8 * $k) (8 * $k) (240 * $k) (240 * $k) (52 * $k)
        $grad = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.RectangleF(0, 0, $s, $s)),
            [Drawing.ColorTranslator]::FromHtml('#3B82F6'), [Drawing.ColorTranslator]::FromHtml('#0B2559'), [single]60)
        $g.FillPath($grad, $tile)
        $g.FillPath([Drawing.Brushes]::White, (New-RoundRect (44 * $k) (70 * $k) (156 * $k) (112 * $k) (14 * $k)))
        $pen = New-Object Drawing.Pen([Drawing.ColorTranslator]::FromHtml('#2563EB'), [single][math]::Max(1.5, 11 * $k))
        $pen.LineJoin = 'Round'; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $g.DrawLines($pen, [Drawing.PointF[]]@((New-Object Drawing.PointF((58 * $k), (86 * $k))),
            (New-Object Drawing.PointF((122 * $k), (134 * $k))), (New-Object Drawing.PointF((186 * $k), (86 * $k)))))
        $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#0B2559'))), (150 * $k), (142 * $k), (100 * $k), (100 * $k))
        $g.FillEllipse((New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#22C55E'))), (158 * $k), (150 * $k), (84 * $k), (84 * $k))
        $chk = New-Object Drawing.Pen([Drawing.Color]::White, [single][math]::Max(1.5, 13 * $k))
        $chk.StartCap = 'Round'; $chk.EndCap = 'Round'; $chk.LineJoin = 'Round'
        $g.DrawLines($chk, [Drawing.PointF[]]@((New-Object Drawing.PointF((178 * $k), (193 * $k))),
            (New-Object Drawing.PointF((194 * $k), (209 * $k))), (New-Object Drawing.PointF((222 * $k), (176 * $k)))))
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        if ($s -ge 256) { $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png) }
        else {
            # classic 32-bit DIB entry (bottom-up BGRA + empty AND mask) - readable by every Windows API
            $bw = New-Object IO.BinaryWriter($ms)
            $maskRow = [int][math]::Ceiling($s / 32) * 4
            $bw.Write([int]40); $bw.Write([int]$s); $bw.Write([int]($s * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
            $bw.Write([int]0); $bw.Write([int]($s * $s * 4 + $maskRow * $s)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
            $data = $bmp.LockBits((New-Object Drawing.Rectangle(0, 0, $s, $s)), 'ReadOnly', [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $row = New-Object byte[] ($s * 4)
            for ($y = $s - 1; $y -ge 0; $y--) {
                [Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $row, 0, $s * 4)
                $bw.Write($row)
            }
            $bmp.UnlockBits($data)
            $bw.Write((New-Object byte[] ($maskRow * $s)))
            $bw.Flush()
        }
        $bmp.Dispose()
        , @($s, $ms.ToArray())
    }
    $fs = [IO.File]::Create($path); $w = New-Object IO.BinaryWriter($fs)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($img in $images) {
        $dim = if ($img[0] -ge 256) { 0 } else { $img[0] }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$img[1].Length); $w.Write([uint32]$offset)
        $offset += $img[1].Length
    }
    foreach ($img in $images) { $w.Write([byte[]]$img[1]) }
    $w.Close()
}

if ($NewIcon -or -not (Test-Path $icon)) { New-AppIcon $icon; "icon:     $icon" }

$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
$sma = [PSObject].Assembly.Location
$manifest = Join-Path $env:TEMP "tbfix-$Level.manifest"
(Get-Content "$buildDir\app.manifest" -Raw) -replace '__LEVEL__', $Level | Set-Content $manifest -Encoding UTF8
New-Item -ItemType Directory -Force (Split-Path $Out -Parent) | Out-Null

& $csc /nologo /optimize+ /codepage:65001 /target:winexe /platform:anycpu "/out:$Out" "/win32icon:$icon" "/win32manifest:$manifest" `
    "/reference:$sma" /reference:System.Windows.Forms.dll "/resource:$Script,tool.ps1" "$buildDir\Launcher.cs"
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Remove-Item $manifest
"built:    $Out  ($([math]::Round((Get-Item $Out).Length / 1KB)) KB, $Level)"
