# Wawelskie Smoki U15 · Smoczy Box Score

Dashboard statystyk ligi **Kadeci U-15 M** (KOZKosz, sezon 2026/2027) z naciskiem na **TS Wisła Kraków** i **#6 Mikołaja Leśniaka**.
Dane pochodzą z https://www.kozkosz.pl/liga/189.html.

## Co jest w środku

| Plik | Do czego służy |
|---|---|
| `config.json` | liga, śledzona drużyna (`8385` = Wisła), śledzeni zawodnicy (`103358` = Leśniak), krótkie nazwy drużyn |
| `scripts/update.ps1` | pobiera dane z kozkosz.pl, zapisuje `data/liga.json` i zrzut dnia w `data/history/`, potem buduje stronę |
| `scripts/build.ps1` | samo budowanie strony z istniejących danych (bez pobierania) |
| `template/dashboard.html` | wygląd i logika dashboardu |
| `dist/index.html` | **gotowa strona** – jeden plik, działa offline i na dowolnym hostingu |
| `dist/artifact.html` | ta sama strona do podglądu jako Artifact w Claude |
| `scripts/install-task.ps1` | rejestruje automatyczną aktualizację w Harmonogramie zadań Windows |
| `.github/workflows/update.yml` | automatyczna aktualizacja i publikacja, jeśli wybierzemy GitHub Pages |
| `logs/update.log` | dziennik każdej aktualizacji |

Nic nie trzeba instalować: wszystko działa w Windows PowerShell 5.1, który jest w systemie.

## Odświeżenie ręczne

```powershell
powershell -ExecutionPolicy Bypass -File scripts\update.ps1
```

Trwa ok. 30 sekund. Można też poprosić Claude: „odśwież dane Smoków”.

## Automatyczna aktualizacja

Harmonogram: **codziennie 06:00**, w **soboty i niedziele także 22:00**.

* **Na tym komputerze:** jednorazowo uruchom `scripts\install-task.ps1`. Jeśli komputer był wyłączony, zadanie wykona się po włączeniu. Przy błędzie ponawia po 2 godzinach.
* **Na GitHub Pages:** workflow `.github/workflows/update.yml` robi to samo w chmurze, bez włączonego komputera.

## Jak działa pobieranie

1. Terminarz trzech grup (A, B, C) → wszystkie mecze z datą, godziną i oznaczeniem „przełożony”.
2. Strony meczów: box score (punkty, celne za 3, faule), kwarty, hala. Pobierane są tylko mecze nowe lub zmienione oraz nadchodzące mecze Wisły.
3. Tabele grup, skład Wisły, profil Leśniaka (rocznik, wzrost, pozycja, historia sezonów).
4. Porównanie z poprzednimi danymi: zmiana daty, godziny lub hali jest zapisywana i oznaczana na dashboardzie.
5. Kontrola: suma punktów zawodników musi się równać wynikowi meczu.

Między zapytaniami jest 1 s przerwy. Pełne pobranie to ok. 20–25 stron.

## Zmiany konfiguracji

* **Inny śledzony zawodnik:** dopisz jego id (z adresu `.../zawodnicy/p/<id>/...`) do `trackedPlayerIds`.
* **Nowy sezon:** zmień `season`; numer ligi (`leagueId`) zwykle się nie zmienia.
* **Krótka nazwa drużyny:** `shortNames` w `config.json`.

## Ograniczenia danych

* Protokoły U-15 na kozkosz.pl zawierają tylko punkty, celne za 3 i faule. Minut, zbiórek i asyst nie ma.
* Mecz bez wpisanego protokołu liczy się do tabeli, ale nie do statystyk zawodników. Dashboard to oznacza.
* Celowo **nie zapisujemy dat urodzenia** ani danych kontaktowych zawodników (to dzieci). Strona ma znacznik `noindex`.
