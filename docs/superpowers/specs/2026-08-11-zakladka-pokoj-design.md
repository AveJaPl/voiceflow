# Zakładka „Pokój" w aplikacji desktopowej

Uzupełnienie [pokoi i sesji](2026-08-11-pokoje-i-sesje-design.md). Tamten
dokument zbudował usługę i klienta w demonie; ten wyprowadza je z terminala do
okna aplikacji i dokłada widżet „co teraz gra".

## Cel

Dziś pokój zakłada się komendą `voiceflow room create --as Filip`, a potem
ręcznie restartuje demona. To jest bariera nie do przyjęcia dla funkcji, która
ma być używana codziennie przez dwie osoby siedzące obok siebie.

Po tej zmianie: otwierasz aplikację, klikasz **Utwórz pokój**, dostajesz link i
otwartą przeglądarkę, a druga osoba w tej samej sieci widzi Twój pokój na liście
i wchodzi jednym kliknięciem. Terminal przestaje być potrzebny.

## Zakres

1. Nowa strona „Pokój" w aplikacji GTK — tworzenie, dołączanie, wyjście.
2. Wykrywanie pokoi w sieci lokalnej (mDNS) i dołączanie kliknięciem.
3. Natywna tablica w aplikacji: kto mówi, ranking, zegar sesji.
4. Nazwane sesje — pole nazwy i zakończenie sesji, plus brakujący endpoint.
5. Widżet „co teraz gra" na tablicy webowej i w aplikacji.

Poza zakresem: zaproszenia imienne między osobami, pokój w aplikacji na macOS
(Wojtek ma tam ustawienia pokoju, ale nie tablicę), logowanie kontem.

**To są dwa plany wdrożeniowe, nie jeden.** Punkty 1–4 ruszają aplikację i
jedno wejście w usłudze; punkt 5 przecina demona, usługę, stronę webową i
aplikację naraz. Każdy z nich daje działające oprogramowanie osobno, więc
powstaną jako dwa kolejne plany — najpierw zakładka, potem muzyka. Kolejność
ma znaczenie: kafelek muzyki potrzebuje miejsca, w którym ma się wyświetlić.

## Granice środowisk — to przesądza o architekturze

Trzy fakty ustalone w rozpoznaniu, nie do obejścia:

- **Aplikacja GTK i demon to dwa osobne środowiska Pythona.** Aplikacja chodzi
  na systemowym Pythonie i nie importuje pakietu `voiceflow`; demon chodzi w
  środowisku uv i nie ma `gi`. Żadna strona nie może wołać drugiej przez import.
- **`~/.local/bin/voiceflow` jest na PATH** — tego samego pliku używa jednostka
  systemd. Aplikacja może go wywołać tak, jak dziś wywołuje `systemctl`.
- **`gdbus`, `busctl` i Avahi są w systemie**, a `Gio` jest w aplikacji.
  Ani mDNS, ani MPRIS nie wymagają nowej zależności.

## Skąd aplikacja bierze dane

Trzy źródła, każde dobrane do tego, w czym jest dobre. To jest główna decyzja
projektowa tego dokumentu.

| Co | Skąd | Uzasadnienie |
|---|---|---|
| Utwórz / dołącz / wyjdź | `subprocess` → `voiceflow room create\|join\|leave` | Logika jest napisana i pokryta testami w `roomsetup.py`. Wywołanie CLI omija granicę środowisk bez dublowania kodu |
| Kto **teraz** mówi | demon pisze `room.json`, aplikacja obserwuje plik | Natychmiast, bez sieci. Demon trzyma WebSocket i wie pierwszy. Ten sam wzorzec, którym karmi rozszerzenie GNOME przez `stats.json` |
| Ranking i sesja | odpytywanie `/api/rooms/KOD/ranking` co 5 s | Liczby nie muszą być natychmiastowe; strona robi dokładnie to samo |

Konsekwencja, którą trzeba przyjąć: **utworzenie lub dołączenie do pokoju
restartuje demona.** Demon czyta konfigurację przy starcie. Aplikacja robi ten
restart sama i mówi o nim w komunikacie — użytkownik nie ma powodu wiedzieć,
że coś takiego jest potrzebne.

## Strona „Pokój"

Dwa stany, bez trzeciego. Strona nigdy nie udaje, że wie więcej, niż wie.

**Nie jesteś w pokoju.** Lista „W twojej sieci" z pokojami znalezionymi przez
mDNS (nazwa pokoju, kto go rozgłasza, przycisk *Dołącz*), pod nią *Utwórz pokój*
z polem nazwy i *Dołącz kodem*. Pusta sieć to zwykły pusty stan, nie błąd.

**Jesteś w pokoju.** Nagłówek z nazwą, kodem i linkiem plus *Kopiuj link* i
*Otwórz w przeglądarce*; karta „kto teraz mówi"; tablica rankingu z numerami
pozycji, paskami udziału i dystansem do lidera; zegar sesji; *Wyjdź z pokoju*.

Treść tablicy jest ta sama co na stronie webowej, ale rysowana natywnie w GTK,
stylami z `style.py`. **WebKitGTK nie jest instalowany** — osadzona przeglądarka
byłaby obcą wyspą w aplikacji i wymagałaby systemowej paczki tylko po to, żeby
pokazać to, co aplikacja umie narysować sama.

Po utworzeniu pokoju aplikacja otwiera przeglądarkę na `/room/KOD`
(`Gtk.UriLauncher`), żeby link był od razu pod ręką na tablet albo telewizor.

## Wykrywanie w sieci lokalnej

Aplikacja rozgłasza przez Avahi usługę `_voiceflow._tcp` z rekordami TXT:
`code`, `room`, `host`. Ta sama aplikacja przegląda ten typ usługi i buduje
listę. Wszystko przez `Gio` i D-Bus, bez `python-zeroconf`.

Dwa ograniczenia wpisane świadomie:

- **Pokój jest widoczny tylko, gdy gospodarz ma otwarte okno aplikacji.**
  Rozgłaszać mógłby demon, ale jego środowisko nie ma `gi`, a ciągnięcie tam
  biblioteki D-Bus wyłącznie dla rozgłaszania w tle nie jest tego warte. Poza
  otwartym oknem — i poza wspólną siecią — zostaje kod i link, czyli stan dzisiejszy.
- **Rozgłoszony kod oznacza, że każdy w tej sieci może wejść do pokoju.**
  W domu to wygoda, w kawiarni dziura. Stąd przełącznik *Rozgłaszaj ten pokój
  w sieci lokalnej*, domyślnie włączony. To jest świadoma zamiana bezpieczeństwa
  na jedno kliknięcie, a nie przeoczenie.

W TXT nie ma tokenu urządzenia. Token jest sekretem i nie opuszcza `config.yaml`.

## Nazwane sesje

Tablica pokazuje dziś „Sesja bez nazwy", bo nazwać jej nie ma gdzie — mimo że
przy projektowaniu pokoi sesje miały się nazywać („coding session"). Strona
dostaje pole nazwy i przycisk zakończenia sesji.

Po stronie usługi brakuje jednego wejścia: `POST /api/rooms/:code/session`
rozpoczyna nową nazwaną sesję (`POST /session/end` już istnieje). Rozpoczęcie
nowej sesji zamyka poprzednią — dwie otwarte sesje w jednym pokoju nie mają
sensu i rozjechałyby ranking.

## Widżet „co teraz gra"

Mały kafelek w stylu odtwarzacza: okładka, tytuł, wykonawca i nazwa aplikacji,
z której leci dźwięk. Na tablicy webowej i w aplikacji.

**Odczyt.** Na Linuksie przez MPRIS: `gdbus` pyta magistralę sesji o nazwy
`org.mpris.MediaPlayer2.*` i czyta `Metadata` oraz `PlaybackStatus`. Demon woła
`gdbus` tak samo, jak dziś woła `wpctl` — bez nowej zależności.

**Wybór odtwarzacza ma regułę**, bo kandydatów bywa kilku: na magistrali potrafi
siedzieć głośnik Bluetooth wystawiający MPRIS przez AVRCP obok właściwej
aplikacji. Reguła, w tej kolejności:

1. kandydat ma `PlaybackStatus` = `Playing` **i** niepusty `xesam:title`;
2. przy kilku kandydatach wygrywa ten z `mpris:artUrl` — prawdziwe aplikacje
   podają okładkę, pośredniki AVRCP zwykle nie;
3. przy dalszym remisie — pierwszy po posortowaniu nazwy magistrali, żeby wybór
   był powtarzalny i dał się zapisać w teście.

Sprawdzone na maszynie Filipa: obok `org.mpris.MediaPlayer2.spotify` wisi
`org.mpris.MediaPlayer2.JBL_Clip_5__S__awek_`, który **nie wystawia `Metadata`
w ogóle** i raportuje `Stopped` — odpada już na kroku 1. Brak kandydata to brak
kafelka, a nie pusty kafelek.

**Przesył.** Utwór jedzie tym samym WebSocketem co obecność, jako zdarzenie
`now_playing` z polami `title`, `artist`, `player`, `artUrl`. Serwer rozsyła je
do pokoju i **nigdzie nie zapisuje** — nie ma dla nich tabeli ani kolumny.
Zamknięcie sesji nie zostawia śladu tego, czego kto słuchał. To ta sama zasada,
dla której `dictations` nie ma kolumny na tekst.

**Czyja muzyka.** Każde urządzenie zgłasza swoją. Zwykle gra jedna osoba i
kafelek jest jeden; gdy gra dwoje, tablica pokazuje oba z imieniem właściciela.
Nie ma pojęcia „gospodarza muzyki" — byłby to stan do zsynchronizowania, który
niczego nie ułatwia.

**Zgoda.** Ustawienie *Pokazuj w pokoju, czego słucham*, domyślnie włączone po
wejściu do pokoju, wyłączalne bez wychodzenia z niego. Okładka to publiczny
adres z CDN wydawcy (`i.scdn.co` dla Spotify), więc przeglądarka pobiera ją
wprost — nic nie przechodzi przez naszą usługę.

**macOS.** MPRIS na macOS nie istnieje; odpowiednikiem jest AppleScript do
`Spotify.app` i `Music.app`. Poza zakresem tej iteracji — kafelek pojawi się
najpierw na Linuksie, a strona webowa pokaże go każdemu, kto na tablicę patrzy,
niezależnie od tego, na czym siedzi.

## Model danych

Bez zmian w schemacie. Jedyne nowe wejście to `POST /api/rooms/:code/session`,
piszące do istniejącej tabeli `sessions`. `now_playing` nie dotyka bazy.

Nowy plik lokalny `room.json` w katalogu danych, obok `stats.json`: kto mówi,
czy jest połączenie z usługą, kod i nazwa pokoju. Pisany atomowo, tak jak
`stats.json`.

## Sytuacje awaryjne

- **Usługa nieosiągalna** — strona pokazuje ostatni znany ranking i informację
  o braku łączności. Dyktowanie działa dalej, lokalnie; to zasada z poprzedniego
  dokumentu i nic jej tu nie zmienia.
- **Avahi nieaktywne** — lista „W twojej sieci" znika w całości, zostaje kod i
  link. Brak mDNS nie jest błędem do pokazania.
- **Restart demona nie powiódł się** — aplikacja mówi wprost, że pokój zacznie
  działać po restarcie, i pokazuje komendę. Nie udaje, że dołączenie się udało.
- **`gdbus` zwraca śmieci albo nic** — brak kafelka. Odczyt muzyki nigdy nie
  może opóźnić ani przerwać dyktowania; działa poza ścieżką skrótu.

## Testy

Czysta logika w osobnych modułach, żeby dała się przetestować bez okna, sieci i
magistrali — tak jak `shortcuts.py` i `statlib.py`, które już mają testy:

- `discovery.py` — składanie i parsowanie rekordów TXT, odrzucanie wpisów bez
  kodu, pomijanie własnego pokoju na liście.
- `nowplaying.py` — wybór odtwarzacza z kilku kandydatów (grający wygrywa z
  zatrzymanym, tytuł wygrywa z pustym, głośnik Bluetooth przegrywa z aplikacją),
  parsowanie odpowiedzi `gdbus`, zachowanie przy braku odtwarzaczy.
- `roomdata.py` — przeliczanie rankingu na wiersze, dystans do lidera, udział.
- `roomstate.py` w demonie — zapis i odczyt `room.json`.
- Po stronie usługi: nowy endpoint sesji i to, że `now_playing` jest rozsyłane,
  a nie zapisywane.

## Odłożone świadomie

- Rozgłaszanie pokoju przez demona (wymagałoby D-Bus w jego środowisku).
- Kafelek muzyki na macOS przez AppleScript.
- Zaproszenia imienne zamiast rozgłaszania pokoju.
- Sterowanie odtwarzaniem z tablicy — kafelek pokazuje, nie steruje.
