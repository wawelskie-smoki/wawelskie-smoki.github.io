# Wawelskie Smoki U15 - pobiera dane ligi z kozkosz.pl i buduje dashboard.
# Uzycie:  powershell -ExecutionPolicy Bypass -File scripts\update.ps1
# Dziala w Windows PowerShell 5.1 i PowerShell 7 (GitHub Actions). Plik celowo bez polskich znakow.

param([switch]$SkipBuild)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Utf8 = New-Object System.Text.UTF8Encoding $false
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Config = [IO.File]::ReadAllText((Join-Path $Root 'config.json'), $Utf8) | ConvertFrom-Json
$Base = $Config.baseUrl
$L = $Config.leagueId
$UA = 'WawelskieSmokiStats/1.0 (prywatny dashboard statystyk U15)'
$script:Requests = 0
$Warnings = New-Object System.Collections.ArrayList

$DataDir = Join-Path $Root 'data'
$HistDir = Join-Path $DataDir 'history'
$LogDir = Join-Path $Root 'logs'
foreach ($d in @($DataDir, $HistDir, $LogDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
$LogFile = Join-Path $LogDir 'update.log'

function Log($msg) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $msg
  Write-Host $line
  [IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $Utf8)
}

function Get-Page([string]$path) {
  for ($a = 1; $a -le 3; $a++) {
    try {
      if ($script:Requests -gt 0) { Start-Sleep -Milliseconds ([int]$Config.requestDelayMs) }
      $wc = New-Object System.Net.WebClient
      $wc.Encoding = [System.Text.Encoding]::UTF8
      $wc.Headers.Add('User-Agent', $UA)
      $html = $wc.DownloadString($Base + $path)
      $script:Requests++
      return ($html -replace '(?s)<!--.*?-->', '')
    } catch {
      if ($a -eq 3) { throw "Nie udalo sie pobrac $path : $($_.Exception.Message)" }
      Start-Sleep -Seconds (5 * $a)
    }
  }
}

function Clean([string]$s) {
  if ($null -eq $s) { return '' }
  $t = [System.Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', ' '))
  return ($t -replace '\s+', ' ').Trim()
}

function ToInt($s) {
  $c = Clean $s
  if ($c -match '^-?\d+$') { return [int]$c }
  return 0
}

function IsoDate([string]$d) {
  if ($d -match '(\d{2})\.(\d{2})\.(\d{4})') { return "$($Matches[3])-$($Matches[2])-$($Matches[1])" }
  return $null
}

function Pair([string]$s) {
  if ((Clean $s) -match '(-?\d+)\s*-\s*(-?\d+)') { return @([int]$Matches[1], [int]$Matches[2]) }
  return @(0, 0)
}

Log "Start aktualizacji (liga $L)"

# ---- poprzednie dane (cache i wykrywanie zmian terminow) ----
$DataFile = Join-Path $DataDir 'liga.json'
$Prev = $null
$PrevMatches = @{}
if (Test-Path $DataFile) {
  try {
    $Prev = [IO.File]::ReadAllText($DataFile, $Utf8) | ConvertFrom-Json
    foreach ($m in $Prev.matches) { $PrevMatches[[string]$m.id] = $m }
  } catch { [void]$Warnings.Add('Nie udalo sie wczytac poprzednich danych; pelne pobranie.') }
}

try {
  # ---- grupy ----
  $html = Get-Page "/liga/$L/terminarz_i_wyniki.html"
  $groups = New-Object System.Collections.ArrayList
  $seen = @{}
  foreach ($m in [regex]::Matches($html, 'href="(/liga/\d+/terminarz_i_wyniki/1-(\d+)/[^"]+)"[^>]*>([^<]+)</a>')) {
    $gid = $m.Groups[2].Value
    if ($seen.ContainsKey($gid)) { continue }
    $seen[$gid] = 1
    $name = Clean $m.Groups[3].Value
    $letter = if ($name -match 'gr\.\s*(\w+)') { $Matches[1] } else { $name }
    [void]$groups.Add([ordered]@{ id = $gid; name = $name; letter = $letter; path = $m.Groups[1].Value; teamIds = @() })
  }
  if ($groups.Count -eq 0) { throw 'Nie znaleziono grup w terminarzu - mozliwa zmiana struktury strony.' }

  # ---- terminarz kazdej grupy ----
  $teams = [ordered]@{}
  $games = New-Object System.Collections.ArrayList
  foreach ($g in $groups) {
    $gh = Get-Page $g.path
    $start = $gh.IndexOf('timetable')
    if ($start -lt 0) { throw "Brak tabeli terminarza dla grupy $($g.name)" }
    $body = $gh.Substring($start)
    $end = $body.IndexOf('</table>')
    if ($end -gt 0) { $body = $body.Substring(0, $end) }
    $round = ''
    $tids = New-Object System.Collections.ArrayList
    foreach ($row in ($body -split '<tr')) {
      if ($row -match '<h3>([\s\S]*?)</h3>') { $round = Clean $Matches[1]; continue }
      if ($row -notmatch '^\s*class="box') { continue }
      $tm = [regex]::Matches($row, '/druzyna/d/(\d+)/([^"]*)">([^<]*)</a>')
      $mm = [regex]::Match($row, '/mecz/(\d+)/[^"]*">([\s\S]*?)</a>')
      if ($tm.Count -lt 2 -or -not $mm.Success) { continue }
      $dm = [regex]::Match($row, '<td>\s*(\d{2}\.\d{2}\.\d{4})(?:\s+(\d{1,2}:\d{2}))?\s*</td>')
      foreach ($t in $tm) {
        $id = $t.Groups[1].Value
        if (-not $teams.Contains($id)) {
          $short = $Config.shortNames.$id
          $full = Clean $t.Groups[3].Value
          $teams[$id] = [ordered]@{ id = $id; name = $full; short = $(if ($short) { $short } else { $full }); group = $g.id; slug = $t.Groups[2].Value }
        }
        if (-not $tids.Contains($id)) { [void]$tids.Add($id) }
      }
      $score = Clean $mm.Groups[2].Value
      $played = $score -match '^(\d+):(\d+)$'
      [void]$games.Add([ordered]@{
        id = $mm.Groups[1].Value
        path = ([regex]::Match($row, '(/mecz/\d+/[^"]+)')).Groups[1].Value
        group = $g.id
        round = $round
        date = $(if ($dm.Success) { IsoDate $dm.Groups[1].Value } else { $null })
        time = $(if ($dm.Success -and $dm.Groups[2].Success) { $dm.Groups[2].Value } else { $null })
        home = $tm[0].Groups[1].Value
        away = $tm[1].Groups[1].Value
        sh = $(if ($played) { [int]$Matches[1] } else { $null })
        sa = $(if ($played) { [int]$Matches[2] } else { $null })
        played = [bool]$played
        moved = [bool]($row -match '^\s*class="box moved')
        hall = $null; quarters = $null; verified = $false; box = $null; sumOk = $null
      })
    }
    $g.teamIds = @($tids)
    $g.Remove('path')
  }
  Log "Grupy: $($groups.Count), druzyny: $($teams.Count), mecze: $($games.Count)"

  # ---- strony meczow: box score + hala ----
  $tracked = [string]$Config.trackedTeamId
  $today = (Get-Date).Date
  $fetched = 0
  foreach ($m in $games) {
    $p = $PrevMatches[[string]$m.id]
    $isTracked = ($m.home -eq $tracked -or $m.away -eq $tracked)
    $recent = $false
    if ($m.date) { $recent = (($today - [datetime]$m.date).TotalDays -le 14) }
    $needFetch = $false
    if ($m.played) {
      if (-not $p -or -not $p.box -or $p.sh -ne $m.sh -or $p.sa -ne $m.sa) { $needFetch = $true }
      elseif (-not $p.verified -and $recent) { $needFetch = $true }
      elseif ((@($p.box.home).Count + @($p.box.away).Count) -eq 0) { $needFetch = $true }
    } elseif ($isTracked) { $needFetch = $true }

    if (-not $needFetch -and $p) {
      $m.hall = $p.hall; $m.quarters = $p.quarters; $m.verified = [bool]$p.verified; $m.box = $p.box; $m.sumOk = $p.sumOk
      continue
    }
    if (-not $needFetch) { continue }

    $mh = Get-Page $m.path
    $fetched++
    $mi = $mh.IndexOf('<div id="mecz">')
    if ($mi -lt 0) { throw "Brak sekcji meczu na stronie $($m.path) - mozliwa zmiana struktury strony." }
    $mh = $mh.Substring($mi)
    $dates = [regex]::Matches($mh, '<p class="date">([\s\S]*?)</p>')
    if ($dates.Count -ge 2) { $m.hall = Clean $dates[1].Groups[1].Value }
    $q = [regex]::Match($mh, '<p class="quaters">\s*\(([^)]*)\)')
    if ($q.Success) { $m.quarters = Clean $q.Groups[1].Value }
    $m.verified = -not ($mh -match 'niezweryfikowane')
    if ($m.played) {
      $parts = $mh -split '<table class="game-table">'
      $heads = [regex]::Matches($mh, '<div class="header">\s*<h1><a href="/liga/\d+/druzyna/d/(\d+)/')
      $box = [ordered]@{ home = @(); away = @() }
      for ($i = 1; $i -lt $parts.Count -and $i -le 2; $i++) {
        $seg = $parts[$i]
        $cut = $seg.IndexOf('</table>')
        if ($cut -gt 0) { $seg = $seg.Substring(0, $cut) }
        $side = if ($i -eq 1) { 'home' } else { 'away' }
        if ($heads.Count -ge $i) {
          $hid = $heads[$i - 1].Groups[1].Value
          if ($hid -eq $m.away) { $side = 'away' } elseif ($hid -eq $m.home) { $side = 'home' }
        }
        $rows = New-Object System.Collections.ArrayList
        foreach ($r in [regex]::Matches($seg, '<tr class="c">([\s\S]*?)</tr>')) {
          $tds = [regex]::Matches($r.Groups[1].Value, '<td[^>]*>([\s\S]*?)</td>')
          if ($tds.Count -lt 5) { continue }
          $pl = [regex]::Match($tds[1].Groups[1].Value, '/zawodnicy/p/(\d+)/')
          [void]$rows.Add([ordered]@{
            pid = $(if ($pl.Success) { $pl.Groups[1].Value } else { 'x' + (Clean $tds[1].Groups[1].Value) })
            name = Clean $tds[1].Groups[1].Value
            nr = Clean $tds[0].Groups[1].Value
            pts = ToInt $tds[2].Groups[1].Value
            p3 = ToInt $tds[3].Groups[1].Value
            f = ToInt $tds[4].Groups[1].Value
          })
        }
        $box[$side] = @($rows)
      }
      $m.box = $box
      $hs = 0; foreach ($r in $box.home) { $hs += $r.pts }
      $as = 0; foreach ($r in $box.away) { $as += $r.pts }
      $m.sumOk = (($box.home.Count -eq 0 -and $box.away.Count -eq 0) -or ($hs -eq $m.sh -and $as -eq $m.sa))
      if ($box.home.Count -eq 0 -and $box.away.Count -eq 0) { [void]$Warnings.Add("Mecz $($m.id) ($($teams[$m.home].short) - $($teams[$m.away].short) $($m.sh):$($m.sa)) nie ma jeszcze protokolu z punktami zawodnikow.") }
      if (-not $m.sumOk) { [void]$Warnings.Add("Mecz $($m.id): suma punktow zawodnikow (${hs}:${as}) rozni sie od wyniku ($($m.sh):$($m.sa)).") }
    }
  }
  Log "Pobrane strony meczow: $fetched"

  # ---- wykrywanie zmian terminow i hal ----
  $changes = New-Object System.Collections.ArrayList
  if ($Prev -and $Prev.changes) {
    foreach ($c in $Prev.changes) { if (([datetime]::Now - [datetime]$c.at).TotalDays -le 30) { [void]$changes.Add($c) } }
  }
  $nowIso = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
  foreach ($m in $games) {
    $p = $PrevMatches[[string]$m.id]
    if (-not $p -or $m.played) { continue }
    foreach ($fld in @('date', 'time', 'hall')) {
      $old = $p.$fld; $new = $m.$fld
      if ($fld -eq 'hall' -and -not $new) { continue }
      if ($old -and $old -ne $new) {
        [void]$changes.Add([ordered]@{ matchId = $m.id; field = $fld; from = $old; to = $new; at = $nowIso })
        Log "Zmiana: mecz $($m.id) $fld '$old' -> '$new'"
      }
    }
  }

  # ---- tabele grup ----
  $standings = [ordered]@{}
  $th = Get-Page "/liga/$L/tabela.html"
  $lc = $th.IndexOf('league-content')
  if ($lc -gt 0) { $th = $th.Substring($lc) }
  foreach ($tb in [regex]::Matches($th, '<tbody>([\s\S]*?)</tbody>')) {
    $rows = New-Object System.Collections.ArrayList
    foreach ($r in [regex]::Matches($tb.Groups[1].Value, '<tr>([\s\S]*?)</tr>')) {
      $tds = [regex]::Matches($r.Groups[1].Value, '<td[^>]*>([\s\S]*?)</td>')
      if ($tds.Count -lt 10) { continue }
      $idm = [regex]::Match($tds[1].Groups[1].Value, '/d/(\d+)/')
      if (-not $idm.Success) { continue }
      $wl = Pair $tds[4].Groups[1].Value; $hm = Pair $tds[5].Groups[1].Value; $aw = Pair $tds[6].Groups[1].Value; $pp = Pair $tds[7].Groups[1].Value
      [void]$rows.Add([ordered]@{
        teamId = $idm.Groups[1].Value; rank = ToInt $tds[0].Groups[1].Value; pts = ToInt $tds[2].Groups[1].Value; g = ToInt $tds[3].Groups[1].Value
        w = $wl[0]; l = $wl[1]; hw = $hm[0]; hl = $hm[1]; aw = $aw[0]; al = $aw[1]; pf = $pp[0]; pa = $pp[1]; diff = ($pp[0] - $pp[1])
      })
    }
    if ($rows.Count -eq 0) { continue }
    $first = $rows[0].teamId
    $grp = $null
    foreach ($g in $groups) { if ($g.teamIds -contains $first) { $grp = $g.id } }
    if ($grp) { $standings[$grp] = @($rows) } else { [void]$Warnings.Add("Tabela z druzyna $first nie pasuje do zadnej grupy.") }
  }

  # ---- sklad sledzonej druzyny ----
  $roster = [ordered]@{}
  $rh = Get-Page "/liga/$L/d/$tracked/$($teams[$tracked].slug)"
  $ri = $rh.IndexOf('league-content')
  if ($ri -gt 0) { $rh = $rh.Substring($ri) }
  $rl = New-Object System.Collections.ArrayList
  $rs = @{}
  # Celowo bez daty urodzenia (dane niepelnoletnich) - tylko imie, wzrost, pozycja.
  foreach ($pm in [regex]::Matches($rh, '/zawodnicy/p/(\d+)/[^"]+">([\s\S]*?)</a>')) {
    $id = $pm.Groups[1].Value
    if ($rs.ContainsKey($id)) { continue }
    $card = $pm.Groups[2].Value
    $nm = [regex]::Match($card, '<h1>([\s\S]*?)</h1>')
    $name = if ($nm.Success) { Clean $nm.Groups[1].Value } else { Clean $card }
    if (-not $name) { continue }
    $rs[$id] = 1
    $hgt = [regex]::Match($card, 'Wzrost:\s*<span>\s*([^<]*)')
    $pos = [regex]::Match($card, 'Pozycja:\s*<span>\s*([^<]*)')
    [void]$rl.Add([ordered]@{ id = $id; name = $name; height = $(if ($hgt.Success) { Clean $hgt.Groups[1].Value } else { '' }); position = $(if ($pos.Success) { Clean $pos.Groups[1].Value } else { '' }) })
  }
  $roster[$tracked] = @($rl)

  # ---- profile sledzonych zawodnikow ----
  $profiles = [ordered]@{}
  foreach ($plId in $Config.trackedPlayerIds) {
    $ph = Get-Page "/liga/$L/zawodnicy/p/$plId/zawodnik.html"
    $prof = [ordered]@{ id = [string]$plId; born = $null; height = $null; position = $null; number = $null; history = @() }
    if ($ph -match 'Rocznik:\s*<span>\s*(\d+)') { $prof.born = $Matches[1] }
    if ($ph -match 'Wzrost:\s*<span>\s*([^<]+)') { $prof.height = Clean $Matches[1] }
    if ($ph -match 'Pozycja:\s*<span>\s*([^<]+)') { $prof.position = Clean $Matches[1] }
    if ($ph -match '<div id="number">\s*#?(\d+)') { $prof.number = $Matches[1] }
    $st = [regex]::Match($ph, '<table class="statystyki">[\s\S]*?<tbody>([\s\S]*?)</tbody>')
    $hist = New-Object System.Collections.ArrayList
    if ($st.Success) {
      foreach ($r in [regex]::Matches($st.Groups[1].Value, '<tr>([\s\S]*?)</tr>')) {
        $tds = [regex]::Matches($r.Groups[1].Value, '<td[^>]*>([\s\S]*?)</td>')
        if ($tds.Count -lt 9) { continue }
        [void]$hist.Add([ordered]@{ season = Clean $tds[0].Groups[1].Value; team = Clean $tds[1].Groups[1].Value; games = ToInt $tds[2].Groups[1].Value; pts = ToInt $tds[3].Groups[1].Value; fouls = ToInt $tds[8].Groups[1].Value })
      }
    }
    $prof.history = @($hist)
    $profiles[[string]$plId] = $prof
  }

  # ---- zapis ----
  $data = [ordered]@{
    generatedAt = $nowIso
    league = [ordered]@{ id = $L; name = $Config.leagueName; season = $Config.season; source = "$Base/liga/$L.html" }
    trackedTeamId = $tracked
    trackedPlayerIds = @($Config.trackedPlayerIds | ForEach-Object { [string]$_ })
    groups = @($groups)
    teams = $teams
    matches = @($games)
    standings = $standings
    roster = $roster
    profiles = $profiles
    changes = @($changes)
    warnings = @($Warnings)
    requests = $script:Requests
  }
  $json = ConvertTo-Json -InputObject $data -Depth 12 -Compress
  [IO.File]::WriteAllText($DataFile, $json, $Utf8)
  [IO.File]::WriteAllText((Join-Path $HistDir ((Get-Date -Format 'yyyy-MM-dd') + '.json')), $json, $Utf8)
  Log "Zapisano dane: zapytan $($script:Requests), ostrzezen $($Warnings.Count)"
} catch {
  Log "BLAD: $($_.Exception.Message) - poprzednie dane pozostaja bez zmian."
  exit 1
}

if (-not $SkipBuild) {
  & (Join-Path $PSScriptRoot 'build.ps1')
  if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
Log 'Koniec aktualizacji'
exit 0
