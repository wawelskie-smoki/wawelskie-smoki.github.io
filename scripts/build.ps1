# Buduje dashboard: wstawia data/liga.json do szablonu i zapisuje:
#   dist/index.html    - pelna strona do hostingu (GitHub Pages, Netlify, serwer www)
#   dist/artifact.html - ta sama strona bez naglowka dokumentu (podglad jako Artifact w Claude)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Utf8 = New-Object System.Text.UTF8Encoding $false

$json = [IO.File]::ReadAllText((Join-Path (Join-Path $Root 'data') 'liga.json'), $Utf8)
$json = $json.Replace('</', '<\/')
$tpl = [IO.File]::ReadAllText((Join-Path (Join-Path $Root 'template') 'dashboard.html'), $Utf8)
$marker = 'window.SMOKI_DATA = null;'
if ($tpl.IndexOf($marker) -lt 0) { Write-Host 'Brak znacznika danych w szablonie.'; exit 1 }
$body = $tpl.Replace($marker, 'window.SMOKI_DATA = ' + $json + ';')

$dist = Join-Path $Root 'dist'
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }
$head = '<!doctype html><html lang="pl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="robots" content="noindex,nofollow"></head><body>'
[IO.File]::WriteAllText((Join-Path $dist 'index.html'), $head + $body + '</body></html>', $Utf8)
[IO.File]::WriteAllText((Join-Path $dist 'artifact.html'), $body, $Utf8)
Write-Host "Zbudowano dist/index.html i dist/artifact.html"
exit 0
