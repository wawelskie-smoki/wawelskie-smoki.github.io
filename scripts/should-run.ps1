# Decyduje, czy cogodzinne uruchomienie ma robic pelna aktualizacje.
# Tak, gdy jakis mecz ligi zaczal sie 2-12 godzin temu i:
#  - nie ma jeszcze wyniku lub protokolu z punktami zawodnikow, albo
#  - dane nie byly odswiezane od 2 h po rozpoczeciu meczu.
# Szerokie okno, bo GitHub czesto pomija zaplanowane uruchomienia (cron) - waskie okno 2-3 h bylo przegapiane.
# Nie wysyla zapytan do kozkosz.pl - czyta tylko data/liga.json.
# Wynik: wypisuje "true"/"false" i (w GitHub Actions) zapisuje run=... do GITHUB_OUTPUT.
# Test lokalny:  powershell -File scripts\should-run.ps1 -Now '2026-10-21T20:30:00+02:00'

param([string]$Now)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Config = [IO.File]::ReadAllText((Join-Path $Root 'config.json'), $Utf8) | ConvertFrom-Json

$tz = $null
foreach ($id in @('Europe/Warsaw', 'Central European Standard Time')) {
  try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch {}
}
if (-not $tz) { throw 'Brak strefy czasowej Europe/Warsaw' }

$nowUtc = if ($Now) { ([DateTimeOffset]::Parse($Now)).UtcDateTime } else { [DateTime]::UtcNow }

$run = $false
$reasons = @()
foreach ($lg in $Config.leagues) {
 $df = Join-Path (Join-Path $Root 'data') $lg.file
 if (-not (Test-Path $df)) { $run = $true; $reasons += "brak danych rocznika $($lg.label)"; continue }
 $data = [IO.File]::ReadAllText($df, $Utf8) | ConvertFrom-Json
 $genUtc = $null
 try { $genUtc = ([DateTimeOffset]::Parse([string]$data.generatedAt)).UtcDateTime } catch {}
 foreach ($m in $data.matches) {
  if (-not $m.date -or -not $m.time) { continue }
  $local = [DateTime]::ParseExact("$($m.date) $($m.time)", 'yyyy-MM-dd H:mm', [Globalization.CultureInfo]::InvariantCulture)
  $startUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($local, 'Unspecified'), $tz)
  $hours = ($nowUtc - $startUtc).TotalHours
  $rows = @($m.box.home).Count + @($m.box.away).Count
  $missing = (-not $m.played) -or ($rows -eq 0)
  $label = "$($lg.label) $($m.date) $($m.time) $($data.teams.($m.home).short) - $($data.teams.($m.away).short)"
  if ($hours -lt 2 -or $hours -ge 12) { continue }
  $stale = (-not $genUtc) -or ($genUtc -lt $startUtc.AddHours(2))
  if ($missing) { $run = $true; $reasons += "brak wyniku/protokolu ($([math]::Round($hours,1)) h po meczu): $label" }
  elseif ($stale) { $run = $true; $reasons += "dane sprzed konca meczu: $label" }
 }
}

if ($reasons.Count) { $reasons | ForEach-Object { Write-Host $_ } } else { Write-Host 'Brak meczow czekajacych na wynik - pomijam aktualizacje.' }
$out = if ($run) { 'true' } else { 'false' }
if ($env:GITHUB_OUTPUT) { [IO.File]::AppendAllText($env:GITHUB_OUTPUT, "run=$out`n", $Utf8) }
Write-Output $out
