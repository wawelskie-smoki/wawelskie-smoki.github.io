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
$head = '<!doctype html><html lang="pl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="robots" content="noindex,nofollow">' +
  '<link rel="manifest" href="manifest.webmanifest"><meta name="theme-color" content="#12224d">' +
  '<link rel="icon" type="image/png" sizes="48x48" href="favicon-48.png"><link rel="icon" type="image/png" sizes="192x192" href="icon-192.png">' +
  '<link rel="apple-touch-icon" href="apple-touch-icon.png"><meta name="apple-mobile-web-app-capable" content="yes">' +
  '<meta name="mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-title" content="Smoki"><meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">' +
  '</head><body>'
$sw = '<script>if("serviceWorker" in navigator&&location.protocol==="https:"){navigator.serviceWorker.register("sw.js").catch(function(){});}</script>'
[IO.File]::WriteAllText((Join-Path $dist 'index.html'), $head + $body + $sw + '</body></html>', $Utf8)
# ikony, manifest i service worker (aplikacja na telefonie)
$static = Join-Path $Root 'static'
if (Test-Path $static) { Copy-Item -Path (Join-Path $static '*') -Destination $dist -Recurse -Force }
[IO.File]::WriteAllText((Join-Path $dist 'artifact.html'), $body, $Utf8)
Write-Host "Zbudowano dist/index.html i dist/artifact.html"
exit 0
