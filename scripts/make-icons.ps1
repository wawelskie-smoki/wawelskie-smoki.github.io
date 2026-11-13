# Generuje ikony aplikacji do katalogu static/ (uruchamiane raz, na Windows - System.Drawing).
# Wzor: biala gwiazda ("Biala Gwiazda") i napis U15 na czerwonym tle.
#   powershell -ExecutionPolicy Bypass -File scripts\make-icons.ps1
Add-Type -AssemblyName System.Drawing
$Root = Split-Path -Parent $PSScriptRoot
$Out = Join-Path $Root 'static'
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out | Out-Null }

function Draw-Icon([int]$size, [double]$scale, [string]$file) {
  $bmp = New-Object System.Drawing.Bitmap $size, $size
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.Clear([System.Drawing.Color]::FromArgb(211, 16, 42))
  $u = $size / 512.0
  $cx = 256.0; $cy = 256.0
  function P([double]$x, [double]$y) { New-Object System.Drawing.PointF ([float](($cx + ($x - $cx) * $scale) * $u)), ([float](($cy + ($y - $cy) * $scale) * $u)) }
  # gwiazda: srodek (256,205), promien 150 / 60
  $pts = @()
  for ($i = 0; $i -lt 10; $i++) {
    $r = if ($i % 2 -eq 0) { 150 } else { 60 }
    $a = -[Math]::PI / 2 + $i * [Math]::PI / 5
    $pts += P (256 + $r * [Math]::Cos($a)) (205 + $r * [Math]::Sin($a))
  }
  $g.FillPolygon([System.Drawing.Brushes]::White, [System.Drawing.PointF[]]$pts)
  # napis U15
  $font = New-Object System.Drawing.Font 'Arial Black', ([float](104 * $scale * $u)), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
  $pc = P 256 418
  $g.DrawString('U15', $font, [System.Drawing.Brushes]::White, $pc, $fmt)
  $g.Dispose()
  $bmp.Save((Join-Path $Out $file), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host "static/$file"
}

Draw-Icon 512 1.0 'icon-512.png'
Draw-Icon 192 1.0 'icon-192.png'
Draw-Icon 180 0.92 'apple-touch-icon.png'
Draw-Icon 48 1.0 'favicon-48.png'
Draw-Icon 512 0.72 'icon-maskable-512.png'
