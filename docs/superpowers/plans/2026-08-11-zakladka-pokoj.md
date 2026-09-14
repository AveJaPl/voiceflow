# Zakładka „Pokój" — plan wdrożenia (część 1 z 2)

Realizuje punkty 1–4 specyfikacji
[2026-08-11-zakladka-pokoj-design.md](../specs/2026-08-11-zakladka-pokoj-design.md).
Kafelek muzyki (punkt 5) jest osobnym planem, robionym po tym.

**Cel:** pokój zakłada się, dołącza i ogląda z okna aplikacji, bez terminala.

**Architektura:** akcje przez CLI `voiceflow room …` (granica środowisk Pythona),
stan mówienia przez plik `room.json` obok `stats.json`, ranking przez odpytywanie
HTTP. mDNS po stronie aplikacji, przez `Gio` i D-Bus do Avahi.

## Ograniczenia globalne

- Aplikacja GTK **nie może** importować pakietu `voiceflow` — osobne środowiska.
- Środowisko demona **nie ma** `gi` — żadnego GLib/D-Bus po stronie demona.
- Żadnych nowych zależności: `gdbus`, `busctl`, Avahi są w systemie, `Gio` w aplikacji.
- Komentarze i teksty interfejsu po polsku, docstringi po angielsku — jak w repo.
- **Bez emotek w interfejsie** — ikony z zestawu symbolicznego GNOME.
- Token urządzenia nie opuszcza `config.yaml`: ani do TXT, ani do logu, ani do UI.

## Struktura plików

| Plik | Odpowiedzialność |
|---|---|
| `src/voiceflow/roomstate.py` (nowy) | Zapis/odczyt `room.json`; czysta serializacja |
| `src/voiceflow/paths.py` (zmiana) | `room_state_file()` |
| `src/voiceflow/room.py` (zmiana) | `RoomClient` melduje zmiany stanu do `roomstate` |
| `rooms/src/httpApi.js` (zmiana) | `POST /api/rooms/:code/session` — nowa nazwana sesja |
| `app/voiceflow_app/roomdata.py` (nowy) | Czyste przeliczenia tablicy + odczyt `room.json` + odpytywanie HTTP |
| `app/voiceflow_app/discovery.py` (nowy) | Avahi: rozgłaszanie i przeglądanie `_voiceflow._tcp` |
| `app/voiceflow_app/pages/room.py` (nowy) | Strona „Pokój" |
| `app/voiceflow_app/main.py` (zmiana) | Rejestracja strony w nawigacji |
| `app/voiceflow_app/style.py` (zmiana) | Style tablicy |

Podział trzyma tę samą zasadę co reszta repo: reguły osobno od okna i od sieci,
żeby dało się je przetestować bez jednego i drugiego.

## Zadanie 1 — demon zapisuje `room.json`

**Pliki:** `src/voiceflow/roomstate.py`, `src/voiceflow/paths.py`,
`src/voiceflow/room.py`, `tests/test_roomstate.py`

Dokument: `{"code", "name", "connected", "speaking", "updated_at"}`, gdzie
`speaking` to imię mówiącego albo `null`. Zapis atomowy przez plik tymczasowy i
`os.replace`, błędy logowane a nie podnoszone — dokładnie jak `write_stats`,
z tego samego powodu: aplikacja może czytać w dowolnej chwili, a utrata zapisu
nie może zakłócić dyktowania.

`RoomClient` woła zapis w trzech miejscach, w których i tak już zmienia stan:
`_set_remote_speaker`, `report_started` i `on_disconnected`.

**Testy:** zapis i odczyt w obie strony; brak pliku daje pusty stan a nie wyjątek;
uszkodzony JSON daje pusty stan; katalog bez prawa zapisu nie podnosi wyjątku.

## Zadanie 2 — rozpoczęcie nazwanej sesji w usłudze

**Pliki:** `rooms/src/httpApi.js`, `rooms/test/httpApi.test.js`

`POST /api/rooms/:code/session` z `{name}` zamyka otwartą sesję i otwiera nową.
Trasa dochodzi do `ROOM_PATH`. Dwie otwarte sesje w jednym pokoju rozjechałyby
ranking, więc zamknięcie poprzedniej jest częścią tej operacji, nie osobnym krokiem.

**Testy:** `routeFor` rozpoznaje nową trasę; nieznany kod daje 404; rozpoczęcie
nowej sesji kończy poprzednią.

## Zadanie 3 — dane tablicy w aplikacji

**Pliki:** `app/voiceflow_app/roomdata.py`, `tests/test_roomdata.py`

Czyste funkcje, bez okna i bez sieci:

- `board_rows(ranking)` → wiersze z pozycją, udziałem procentowym i dystansem
  do lidera; lider ma dystans `0`.
- `format_duration(seconds)` → „1 godz. 23 min", zgodnie ze stroną webową.
- `session_elapsed(started_at, now)` → `HH:MM:SS`.
- `read_room_state(path)` → stan z `room.json`, odporny na brak i uszkodzenie.
- `fetch_ranking(server, code)` → `urllib`, zwraca dokument albo podnosi
  `RoomDataError`; wołane z wątku roboczego.

**Testy:** udziały sumują się do 100 przy równym podziale; pusty ranking daje
pustą listę a nie dzielenie przez zero; dystans lidera to zero; formatowanie
czasu dla 0 s, 59 s, 1 h; `read_room_state` na braku pliku i na śmieciach.

## Zadanie 4 — wykrywanie pokoi w sieci

**Pliki:** `app/voiceflow_app/discovery.py`, `tests/test_discovery.py`

Rozgłaszanie i przeglądanie `_voiceflow._tcp` przez `org.freedesktop.Avahi`.
Część czysta, testowalna bez magistrali:

- `encode_txt({...})` / `decode_txt([[byte,…], …])` — Avahi podaje TXT jako
  tablice bajtów, nie napisy.
- `room_from_txt(txt)` → `DiscoveredRoom | None`; brak `code` odrzuca wpis.
- `visible_rooms(found, own_code)` → lista bez własnego pokoju i bez duplikatów.

Część nieczysta (`publish`, `browse`) siedzi za wąskim interfejsem i jest
pomijana w testach; brak Avahi nie jest błędem, tylko pustą listą.

**Testy:** TXT w obie strony, w tym znaki spoza ASCII w nazwie pokoju; wpis bez
kodu odrzucony; własny pokój nie pojawia się na liście; ten sam kod z dwóch
interfejsów sieciowych daje jeden wpis.

## Zadanie 5 — strona „Pokój"

**Pliki:** `app/voiceflow_app/pages/room.py`, `app/voiceflow_app/main.py`,
`app/voiceflow_app/style.py`

Dwa stany zgodnie ze specyfikacją. Akcje wołają
`~/.local/bin/voiceflow room create|join|leave` przez `subprocess` w wątku
roboczym, potem `services.run_systemctl("restart")`, potem odświeżenie.
Po utworzeniu — `Gtk.UriLauncher` na `/room/KOD`.

Nawigacja: wpis `("room", "system-users-symbolic", "Pokój")` między
„Statystyki" a „Słownik", plus tytuł w `_on_navigation`.

**Testy:** logika tej strony mieszka w `roomdata.py` i `discovery.py`, które są
pokryte; sama strona jest sprawdzana ręcznie przez uruchomienie aplikacji.

## Kolejność i weryfikacja

Zadania 1–4 są niezależne i każde kończy się zielonym `pytest` / `node --test`.
Zadanie 5 spina je i wymaga uruchomienia aplikacji. Na końcu pełny zestaw:
`uv run pytest` oraz `node --test test/*.test.js` w `rooms/`.
