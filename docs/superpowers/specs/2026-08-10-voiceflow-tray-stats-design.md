# Wskaźnik dziennych statystyk mówienia w pasku GNOME

Data: 2026-08-10

## Cel

Voiceflow zbiera już w `history.jsonl` liczbę słów i długość audio każdego
dyktowania, ale te dane widać dopiero po otwarciu apki ustawień (zakładka
„Statystyki”). Celem jest wskaźnik w górnym pasku GNOME, widoczny cały czas,
pokazujący dzisiejszy czas mówienia i liczbę słów — bez otwierania niczego.

## Kontekst i precedens w kodzie

Demon Voiceflow (`src/voiceflow/daemon.py`) działa cały czas jako usługa
systemd (`systemd/voiceflow.service`) i to on jako jedyny zapisuje każdy
ukończony dyktowanie do historii (`History.append`), więc ma dane na żywo —
bez odpytywania plików.

Projekt ma już dokładnie ten sam problem rozwiązany dla okna podglądu:
`src/voiceflow/overlay.py` (klasa `Overlay`) uruchamia osobny proces
systemowym Pythonem (`/usr/bin/python3`), bo wirtualenv projektu (`uv`) nie
niesie PyGObject, i steruje nim jednokierunkowo przez JSON — jedna linia na
aktualizację — na `stdin` procesu potomnego. Skrypt potomny
(`scripts/voiceflow-overlay.py`) żyje, dopóki żyje demon, i ginie razem z nim.

Wskaźnik statystyk powtarza ten sam wzorzec, żeby nie wprowadzać drugiego
sposobu integracji z GTK do kodu.

## Architektura

- **`src/voiceflow/tray.py`** — nowa klasa `Tray`, budowa 1:1 na wzór
  `Overlay`: `start()` spawnuje proces, `update(payload)` wysyła JSON linią na
  stdin, `stop()` kończy proces przy zamykaniu demona. Best-effort: każdy błąd
  (brak binarki, brak GI, crash procesu) tylko loguje ostrzeżenie i nigdy nie
  przerywa dyktowania — identyczna zasada jak w `Overlay`.
- **`scripts/voiceflow-tray.py`** — nowy skrypt, uruchamiany systemowym
  Pythonem. Trzyma ikonę `AyatanaAppIndicator3` (GI namespace
  `AyatanaAppIndicator3`, wersja `0.1`), czyta JSON linia-po-linii ze stdin i
  aktualizuje etykietę + zawartość menu.
- **`src/voiceflow/daemon.py`** — po każdym `History.append(record)` demon
  przelicza statystyki i wywołuje `self.tray.update(...)`. Dodatkowo
  uruchamia lekki cykliczny timer (co ~5 minut) przeliczający i wysyłający te
  same dane, żeby licznik „dziś” realnie wyzerował się o północy nawet bez
  nowego dyktowania.

## Liczenie statystyk

Zero nowej logiki agregującej — `app/voiceflow_app/statlib.py` już ma
wszystko potrzebne:

- `record_date(record)` — lokalny dzień rekordu.
- `totals(records)` — sumy `words` / `audio_seconds` / `dictations` dla listy
  rekordów.
- `compact_number(value)` — zaokrąglone tysiące/miliony (`1,6 k`, `999 k`,
  `1,2 mln`).
- `format_duration(seconds)` — czas jako `„2 godz. 15 min”` / `„12 min”`.

Nowa funkcja pomocnicza w `statlib.py`, `period_bounds(period, *, today=None)`,
zwraca datę początku okresu (`"day" | "week" | "month" | "year"`; tydzień
liczony od poniedziałku, ISO). Demon filtruje pełną listę rekordów po tej
granicy i wywołuje `totals()` — cztery razy (dzień, tydzień, miesiąc, rok),
przy każdej aktualizacji.

`statlib.py` żyje dziś pod `app/voiceflow_app/`, czyli w pakiecie apki GTK, a
importować go musi też `src/voiceflow/daemon.py`. Ponieważ moduł jest bez
zależności od GTK (same `datetime`/`collections`), przenosimy go do
`src/voiceflow/statlib.py` i w `app/voiceflow_app/statlib.py` zostawiamy
`from voiceflow.statlib import *`-reeksport dla wstecznej zgodności importów
w apce ustawień.

## Co widać w pasku

- **Etykieta na stałe:** `„12 min · 340 słów”` — zawsze dzisiejsze liczby,
  czas i słowa zaokrąglone jak wyżej.
- **Menu po kliknięciu** (natywne menu `AyatanaAppIndicator3`, systemowy
  styl GTK — nie custom-rysowany panel kart jak w Astra Monitor, patrz niżej):
  - „Ten tydzień: X min · Y słów”
  - „Ten miesiąc: X min · Y słów”
  - „Ten rok: X min · Y słów”

Zamierzona różnica względem Astra Monitor: to rozszerzenie GNOME Shell z
pełną kontrolą nad rysowaniem (karty, wykresy), nasz wskaźnik to osobny
proces przez AppIndicator i dostaje zwykłe, natywne menu GTK. Interakcja
(klik → rozwinięcie z dodatkowymi danymi) jest ta sama, wygląd — prostszy.
Pixel-perfect dopasowanie do Astra Monitor jest świadomie poza zakresem.

## Instalacja i błędy

- `install.sh` dostaje krok analogiczny do istniejącego kroku `ydotool`:
  sprawdza czy zainstalowany jest pakiet `gir1.2-ayatanaappindicator3-0.1`,
  jeśli nie — pyta o sudo i instaluje (`apt install`).
- Jeśli pakietu mimo wszystko brakuje, albo import `AyatanaAppIndicator3` w
  `scripts/voiceflow-tray.py` się nie powiedzie — skrypt kończy się cicho,
  `Tray.start()` loguje ostrzeżenie i demon działa dalej normalnie. Zero
  wpływu na dyktowanie, identycznie jak przy braku okna podglądu.

## Konfiguracja

Nowa sekcja `TrayConfig` w `src/voiceflow/config.py`, wzorem
`OverlayConfig`: pole `enabled: bool = True`. Wyłączenie w configu pomija
spawn procesu całkowicie.

## Testowanie

- Jednostkowe dla `statlib.period_bounds()` — granice dnia/tygodnia (ISO,
  od poniedziałku)/miesiąca/roku wokół przełomów (koniec roku, przestępny
  luty).
- Jednostkowe dla `Tray` na wzór istniejących testów `Overlay` (mock
  procesu potomnego, sprawdzenie wysyłanego JSON, best-effort przy braku
  binarki/pliku skryptu).
- `scripts/voiceflow-tray.py` nie jest pokryty testami jednostkowymi (tak
  samo jak `voiceflow-overlay.py` — wymaga PyGObject i realnego env
  graficznego); weryfikacja ręczna po zainstalowaniu paczki apt.

## Poza zakresem

- Wizualne dopasowanie 1:1 do stylu Astra Monitor (karty, wykresy).
- Statystyki historyczne inne niż dzień/tydzień/miesiąc/rok (np. wykres,
  streak) — to już ma apka ustawień, nie duplikujemy w tray.
- Windows — cała funkcja jest Linux-only (GNOME/AppIndicator), tak jak
  overlay już rozróżnia platformy przez `winplat/`.
