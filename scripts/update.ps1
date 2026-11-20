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

# ---- nowa strona kozkosz.pl (od 2026-11-20, Next.js): dane sa w ladunku self.__next_f jako JSON ----
function Get-Rsc([string]$html) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($m in [regex]::Matches($html, 'self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)')) {
    [void]$sb.Append(($m.Groups[1].Value | ConvertFrom-Json))
  }
  return $sb.ToString()
}

# Zwraca obiekt/tablice JSON zapisana pod kluczem "key" (pierwsze wystapienie od pozycji $from).
function Get-JsonAt([string]$txt, [string]$key, [int]$from = 0) {
  $i = $txt.IndexOf('"' + $key + '":', $from)
  if ($i -lt 0) { return $null }
  $st = $i + $key.Length + 3
  $c0 = $txt[$st]
  if ($c0 -ne '[' -and $c0 -ne '{') { return $null }
  $d = 0; $ins = $false; $j = $st
  for (; $j -lt $txt.Length; $j++) {
    $c = $txt[$j]
    if ($ins) { if ($c -eq '\') { $j++ } elseif ($c -eq '"') { $ins = $false }; continue }
    if ($c -eq '"') { $ins = $true }
    elseif ($c -eq '[' -or $c -eq '{') { $d++ }
    elseif ($c -eq ']' -or $c -eq '}') { $d--; if ($d -eq 0) { $j++; break } }
  }
  return ($txt.Substring($st, $j - $st) | ConvertFrom-Json)
}

function Trim2($s) { if ($null -eq $s) { return '' }; return ([string]$s).Trim() }

try {
  # ---- terminarz calej ligi (jedna strona) ----
  $html = Get-Page "/centrum-meczow/liga?leagueId=$L&tab=schedule"
  $rsc = Get-Rsc $html
  $sched = Get-JsonAt $rsc 'schedule'
  if (-not $sched) { throw 'Nie znaleziono terminarza (schedule) na stronie ligi - mozliwa zmiana struktury strony.' }
  $paths = @{}
  foreach ($a in [regex]::Matches($html, 'href="(/mecz/(\d+)/[^"]+)"')) { if (-not $paths.ContainsKey($a.Groups[2].Value)) { $paths[$a.Groups[2].Value] = $a.Groups[1].Value } }

  $teams = [ordered]@{}
  $games = New-Object System.Collections.ArrayList
  $grpMap = @{}
  $seasonId = $null
  foreach ($lg in @($sched)) {
    if ([string]$lg.id -ne [string]$L) { continue }
    foreach ($rd in @($lg.rounds)) {
      foreach ($q in @($rd.queues)) {
        foreach ($g in @($q.games)) {
          if (-not $seasonId -and $g.seasonId) { $seasonId = [string]$g.seasonId }
          $gid = [string]$g.group.id
          if (-not $grpMap.ContainsKey($gid)) { $grpMap[$gid] = [ordered]@{ id = $gid; name = "$($rd.name): gr. $($g.group.name)"; letter = [string]$g.group.name; teamIds = (New-Object System.Collections.ArrayList) } }
          foreach ($t in @($g.homeTeam, $g.guestTeam)) {
            $id = [string]$t.id
            if (-not $teams.Contains($id)) {
              $short = $Config.shortNames.$id
              $full = Trim2 $t.name
              $teams[$id] = [ordered]@{ id = $id; name = $full; short = $(if ($short) { $short } else { $full }); group = $gid; slug = [string]$t.slug; logo = [string]$t.logoUrl }
            }
            if (-not $grpMap[$gid].teamIds.Contains($id)) { [void]$grpMap[$gid].teamIds.Add($id) }
          }
          $dl = [string]$g.dateLocal
          $date = $null; $time = $null
          if ($dl -match '^(\d{4}-\d{2}-\d{2})(?:\s+(\d{1,2}):(\d{2}))?') {
            $date = $Matches[1]
            if ($Matches[2] -and -not ($Matches[2] -eq '00' -and $Matches[3] -eq '00')) { $time = "$([int]$Matches[2]):$($Matches[3])" }
          }
          $played = [bool]$g.isFinished -and ($null -ne $g.resultHome) -and (($g.resultHome + $g.resultGuest) -gt 0)
          $id = [string]$g.id
          $path = $paths[$id]
          if (-not $path) { $path = "/mecz/$id/$($g.slug)"; [void]$Warnings.Add("Brak linku do meczu $id na stronie terminarza.") }
          [void]$games.Add([ordered]@{
            id = $id
            path = $path
            group = $gid
            round = [string]$q.name
            date = $date
            time = $time
            home = [string]$g.homeTeam.id
            away = [string]$g.guestTeam.id
            sh = $(if ($played) { [int]$g.resultHome } else { $null })
            sa = $(if ($played) { [int]$g.resultGuest } else { $null })
            played = $played
            moved = $false
            hall = $null
            quarters = $(if ($played -and @($g.quarters).Count) { (@($g.quarters) -join ', ') } else { $null })
            verified = $false; box = $null; sumOk = $null
          })
        }
      }
    }
  }
  if ($games.Count -eq 0) { throw 'Terminarz ligi jest pusty - mozliwa zmiana struktury strony.' }
  $groups = New-Object System.Collections.ArrayList
  foreach ($k in ($grpMap.Keys | Sort-Object { $grpMap[$_].letter })) { $grpMap[$k].teamIds = @($grpMap[$k].teamIds); [void]$groups.Add($grpMap[$k]) }
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
      $m.hall = $p.hall; $m.verified = [bool]$p.verified; $m.box = $p.box; $m.sumOk = $p.sumOk
      if (-not $m.quarters) { $m.quarters = $p.quarters }
      continue
    }
    if (-not $needFetch) { continue }

    $mr = Get-Rsc (Get-Page $m.path)
    $fetched++
    $gm = Get-JsonAt $mr 'game'
    if (-not $gm -or [string]$gm.id -ne $m.id) { throw "Brak danych meczu na stronie $($m.path) - mozliwa zmiana struktury strony." }
    if ($gm.venue -and $gm.venue.name) {
      $m.hall = ((@((Trim2 $gm.venue.name), (Trim2 $gm.venue.city), (Trim2 $gm.venue.address)) | Where-Object { $_ }) -join ', ')
    } elseif ($p) { $m.hall = $p.hall }
    if ($gm.quarters -and @($gm.quarters).Count -and $m.played) { $m.quarters = (@($gm.quarters) -join ', ') }
    $m.verified = [bool]$gm.hasPDFReport
    if ($m.played) {
      $box = [ordered]@{ home = @(); away = @() }
      foreach ($side in @('home', 'away')) {
        $tm = if ($side -eq 'home') { $gm.homeTeam } else { $gm.guestTeam }
        $info = @{}
        foreach ($pl in @($tm.players)) { if ($pl) { $info[[string]$pl.id] = $pl } }
        $rows = New-Object System.Collections.ArrayList
        foreach ($s in @($tm.gameStatistics.playersStatistics)) {
          if (-not $s -or -not $s.playerId) { continue }
          $plid = [string]$s.playerId
          $pi = $info[$plid]
          [void]$rows.Add([ordered]@{
            pid = $plid
            name = $(if ($pi) { (Trim2 "$($pi.firstName) $($pi.lastName)") } else { "Zawodnik $plid" })
            nr = $(if ($pi) { [string]$pi.shirtNumber } else { '' })
            pts = [int]$s.points
            p3 = [int]$s.madeThreePts
            f = [int]$s.foulsPersonal
          })
        }
        $sorted = @($rows | Sort-Object @{ Expression = { if ($_.nr -match '^\d+$') { [int]$_.nr } else { 999 } } })
        $box[$side] = $sorted
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
      if ($fld -eq 'hall' -and $old -and (($old -replace '\s+,', ',') -eq $new)) { continue }
      if ($old -and $old -ne $new) {
        [void]$changes.Add([ordered]@{ matchId = $m.id; field = $fld; from = $old; to = $new; at = $nowIso })
        Log "Zmiana: mecz $($m.id) $fld '$old' -> '$new'"
      }
    }
  }

  # ---- tabele grup ----
  $standings = [ordered]@{}
  $tr = Get-Rsc (Get-Page "/centrum-meczow/liga?leagueId=$L&tab=tables")
  $tables = Get-JsonAt $tr 'tables'
  if (-not $tables) { [void]$Warnings.Add('Nie znaleziono tabel grup na stronie ligi.') }
  foreach ($tb in @($tables)) {
    if (-not $tb) { continue }
    $rows = New-Object System.Collections.ArrayList
    foreach ($e in @($tb.entries)) {
      $pf = [int]$e.pointsGained; $pa = [int]$e.pointsLost
      [void]$rows.Add([ordered]@{
        teamId = [string]$e.teamId; rank = [int]$e.position; pts = [int]$e.points; g = [int]$e.games
        w = [int]$e.wins; l = [int]$e.losses; hw = [int]$e.winsHome; hl = [int]$e.lossesHome; aw = [int]$e.winsAway; al = [int]$e.lossesAway
        pf = $pf; pa = $pa; diff = ($pf - $pa)
      })
    }
    if ($rows.Count -eq 0) { continue }
    $grp = [string]$tb.groupId
    if ($grpMap.ContainsKey($grp)) { $standings[$grp] = @($rows) } else { [void]$Warnings.Add("Tabela grupy $grp nie pasuje do zadnej grupy.") }
  }

  # ---- sklad sledzonej druzyny ----
  # Celowo bez daty urodzenia (dane niepelnoletnich) - tylko imie, numer, wzrost, pozycja.
  $roster = [ordered]@{}
  $rr = Get-Rsc (Get-Page "/liga/$L/sezon/$seasonId/d/$tracked/$($teams[$tracked].slug)")
  $rp = Get-JsonAt $rr 'players'
  $rl = New-Object System.Collections.ArrayList
  $numbers = @{}; $pslug = @{}
  foreach ($pl in @($rp)) {
    if (-not $pl -or -not $pl.id) { continue }
    $numbers[[string]$pl.id] = [string]$pl.shirtNumber; $pslug[[string]$pl.id] = [string]$pl.slug
    [void]$rl.Add([ordered]@{
      id = [string]$pl.id
      name = (Trim2 "$($pl.firstName) $($pl.lastName)")
      height = $(if ($pl.height) { "$($pl.height) cm" } else { '' })
      position = (@($pl.positions) -join ' / ')
    })
  }
  if ($rl.Count -eq 0) { [void]$Warnings.Add('Nie znaleziono skladu sledzonej druzyny.') }
  $roster[$tracked] = @($rl)

  # ---- profile sledzonych zawodnikow (rocznik tylko jako rok, bez pelnej daty urodzenia) ----
  $profiles = [ordered]@{}
  foreach ($plId in $Config.trackedPlayerIds) {
    $pr = Get-Rsc (Get-Page "/liga/$L/sezon/$seasonId/zawodnicy/p/$plId/$(if ($pslug[[string]$plId]) { $pslug[[string]$plId] } else { 'zawodnik' })")
    $prof = [ordered]@{ id = [string]$plId; born = $null; height = $null; position = $null; number = $numbers[[string]$plId]; history = @() }
    $pj = Get-JsonAt $pr 'player'
    if ($pj) {
      if ($pj.birthDate -and ([string]$pj.birthDate) -match '^(\d{4})') { $prof.born = $Matches[1] }
      if ($pj.height) { $prof.height = "$($pj.height) cm" }
      if ($pj.positions) { $prof.position = (@($pj.positions) -join ' / ') }
    }
    $career = Get-JsonAt $pr 'career'
    $tname = @{}
    foreach ($c in @($career)) { if ($c) { $tname["$($c.teamId)/$($c.seasonId)"] = Trim2 $c.teamName } }
    $sum = Get-JsonAt $pr 'statisticsSum'
    $hist = New-Object System.Collections.ArrayList
    foreach ($lgs in @($sum)) {
      if (-not $lgs -or [string]$lgs.league.id -ne [string]$L) { continue }
      foreach ($s in @($lgs.statistics)) {
        if (-not $s) { continue }
        $tn = $tname["$($s.teamId)/$($s.season.id)"]
        if (-not $tn -and $teams.Contains([string]$s.teamId)) { $tn = $teams[[string]$s.teamId].name }
        [void]$hist.Add([ordered]@{ season = [string]$s.season.name; team = $tn; games = [int]$s.matchCount; pts = [int]$s.points; fouls = [int]$s.foulsPersonal })
      }
    }
    $prof.history = @($hist | Sort-Object { $_.season } -Descending)
    $profiles[[string]$plId] = $prof
  }

  # ---- zapis ----
  $data = [ordered]@{
    generatedAt = $nowIso
    league = [ordered]@{ id = $L; name = $Config.leagueName; season = $Config.season; source = "$Base/centrum-meczow/liga?leagueId=$L&tab=schedule" }
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
