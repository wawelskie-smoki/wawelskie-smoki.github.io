# Decyduje, czy cogodzinne uruchomienie ma robic pelna aktualizacje.
# Tak, gdy jakis mecz ligi zaczal sie 2-3 godziny temu, albo 4-5 godzin temu
# i nadal nie ma wyniku lub protokolu z punktami zawodnikow.
# Nie wysyla zapytan do kozkosz.pl - czyta tylko data/liga.json.
# Wynik: wypisuje "true"/"false" i (w GitHub Actions) zapisuje run=... do GITHUB_OUTPUT.
# Test lokalny:  powershell -File scripts\should-run.ps1 -Now '2026-10-21T20:30:00+02:00'

param([string]$Now)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Utf8 = New-Object System.Text.UTF8Encoding $false
$data = [IO.File]::ReadAllText((Join-Path (Join-Path $Root 'data') 'liga.json'), $Utf8) | ConvertFrom-Json

$tz = $null
foreach ($id in @('Europe/Warsaw', 'Central European Standard Time')) {
  try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch {}
}
if (-not $tz) { throw 'Brak strefy czasowej Europe/Warsaw' }

$nowUtc = if ($Now) { ([DateTimeOffset]::Parse($Now)).UtcDateTime } else { [DateTime]::UtcNow }

$run = $false
$reasons = @()
foreach ($m in $data.matches) {
  if (-not $m.date -or -not $m.time) { continue }
  $local = [DateTime]::ParseExact("$($m.date) $($m.time)", 'yyyy-MM-dd H:mm', [Globalization.CultureInfo]::InvariantCulture)
  $startUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($local, 'Unspecified'), $tz)
  $hours = ($nowUtc - $startUtc).TotalHours
  $rows = @($m.box.home).Count + @($m.box.away).Count
  $missing = (-not $m.played) -or ($rows -eq 0)
  $label = "$($m.date) $($m.time) $($data.teams.($m.home).short) - $($data.teams.($m.away).short)"
  if ($hours -ge 2 -and $hours -lt 3) { $run = $true; $reasons += "2 h po meczu: $label" }
  elseif ($hours -ge 4 -and $hours -lt 5 -and $missing) { $run = $true; $reasons += "ponowienie 4 h po meczu: $label" }
}

if ($reasons.Count) { $reasons | ForEach-Object { Write-Host $_ } } else { Write-Host 'Brak meczow 2 h temu - pomijam aktualizacje.' }
$out = if ($run) { 'true' } else { 'false' }
if ($env:GITHUB_OUTPUT) { [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "run=$out`n", $Utf8) }
Write-Output $out
