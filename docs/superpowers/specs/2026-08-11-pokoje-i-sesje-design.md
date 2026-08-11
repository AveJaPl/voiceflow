# Pokoje: wspólne sesje dyktowania

Data: 2026-08-11

## Cel

Dwie osoby dyktujące w jednym pomieszczeniu przeszkadzają sobie w dwóch
konkretnych momentach: kiedy zaczynają mówić naraz (oba mikrofony łapią oba
głosy i obie transkrypcje wychodzą popsute) oraz kiedy z czyjegoś głośnika leci
muzyka (przeszkadza mówiącemu tak samo, niezależnie od tego, czyj to głośnik).

Pokój rozwiązuje jedno i drugie: sygnalizuje, kto właśnie mówi, blokuje resztę
na ten czas i ścisza dźwięk **na wszystkich urządzeniach w pokoju**, nie tylko
u mówiącego. Przy okazji liczy, ile kto dyktował — bo skoro dane i tak
przechodzą, ranking jest niemal darmowy, a rywalizacja jest tu wprost
zamierzona.

## Kontrakt prywatności

Cały projekt stoi na obietnicy „nic nie opuszcza Twojej maszyny". Pokój tę
obietnicę zmienia i musi to być decyzją, nie skutkiem ubocznym.

**Nigdy nie opuszcza urządzenia:** nagranie audio, treść dyktowania, historia
lokalna.

**Opuszcza urządzenie, ale tylko po dołączeniu do pokoju:** zdarzenia
„zaczynam mówić" i „skończyłem", liczba słów i sekund każdego dyktowania,
nazwa wyświetlana i adres e-mail konta.

Konsekwencje, które trzeba wykonać razem z funkcją:

- Bez konta i bez pokoju voiceflow działa dokładnie jak dziś — w pełni
  lokalnie. Pokój jest wyłączony domyślnie.
- Tabela `dictations` **nie ma kolumny na tekst**. Nie dlatego, że jej nie
  dodano, tylko żeby nie dało się jej wypełnić bez zmiany schematu, którą ktoś
  musiałby świadomie zatwierdzić.
- Hasło na landingu zmienia się z „nic nie wychodzi" na „nagranie i tekst
  nigdy nie wychodzą". Nadal mocne i, co ważniejsze, prawdziwe.

## Zakres v1

**Wchodzi:** konto (opcjonalne), tworzenie pokoju i dołączanie kodem, blokada z
sygnalizacją kto mówi, ściszanie dźwięku u pozostałych, sesje z pomiarem czasu i
słów, strona rankingu na żywo do otwarcia na tablecie lub telewizorze, klient
Linux.

**Nie wchodzi:** synchronizacja historii dyktowań między urządzeniami jednej
osoby (osobny kawałek), klienci macOS i Windows, automatyczne wykrywanie po
WiFi, mierzenie „jakości" promptów.

## Pokój i sesja to jedno

Nie ma osobnego kroku „rozpocznij sesję". Utworzenie pokoju **jest** początkiem
sesji — nikt nie tworzy pokoju, żeby siedzieć w nim sam.

- **Pokój** trwa: ma kod, nazwę i skład. Wraca się do niego jutro tym samym
  kodem.
- **Sesja** to mierzony odcinek pracy w pokoju. Pierwsza startuje razem z
  pokojem. Zakończenie sesji nie kasuje pokoju — kolejną zaczyna się jednym
  przyciskiem, w tym samym składzie.
- Nazwa sesji jest opcjonalna; domyślnie „Sesja 11.08, 14:30", można ją nadać
  lub zmienić w trakcie („coding session").

Mierzymy: długość sesji, a w niej dla każdego uczestnika czas obecności, czas
mówienia i liczbę słów.

## Architektura

Jedna nowa usługa `rooms/` — Next.js z własnym serwerem obsługującym naraz
stronę, API i WebSocket na jednym porcie. Jeden Dockerfile, jeden zasób w
Coolify, jedna baza. Next.js, bo ranking ma być oglądany na tablecie i
telewizorze, a to jest stack, w którym pracujemy.

```
demon Linux (Filip)   ──WSS──┐
demon Linux (Wojtek)  ──WSS──┼──→  rooms  ──→  Postgres (baza: voiceflow)
tablet / TV           ──HTTP─┘
```

### Po stronie klienta

Nowy moduł `src/voiceflow/room.py` z klasą `RoomClient`, wstrzykiwaną do demona
jak każdy inny współpracownik (`Recorder`, `MicMuter`, `Overlay`) — czyli
testowalną bez sieci.

Punkty styku z istniejącym kodem są dokładnie trzy:

1. `daemon._start()` pyta `RoomClient.may_start()`. Odmowa oznacza kartę „Wojtek
   dyktuje…" zamiast nagrywania (mechanizm karty już istnieje — `overlay.notice`
   dodany przy okazji komunikatu o braku mowy).
2. Po zakończeniu dyktowania demon wysyła liczby, które **już liczy** dla
   `history.jsonl` — `Record` ma `words` i `audio_seconds`. Zero nowej
   matematyki.
3. Zdalne „ktoś zaczął mówić" woła `MicMuter.mute()`, a „skończył" —
   `MicMuter.unmute()`. To ten sam kod, którego używa własny skrót, tylko
   wyzwolony cudzym zdarzeniem. Cała obsługa znikających strumieni i
   przywracania głośności działa bez zmian.

Punkt 3 jest powodem, dla którego ta funkcja jest wykonalna małym kosztem:
najtrudniejsza jej część — ściszanie i wierne przywracanie dźwięku — jest już
napisana i przetestowana.

## Protokół WebSocket

Klient → serwer:

| komunikat | kiedy | ładunek |
|---|---|---|
| `hello` | po połączeniu | token urządzenia |
| `speaking_started` | naciśnięcie skrótu | — |
| `speaking_ended` | koniec dyktowania | `words`, `seconds` |
| `heartbeat` | co 3 s | — |

Serwer → klient:

| komunikat | znaczenie |
|---|---|
| `room_state` | skład, kto teraz mówi i od kiedy |
| `speaker_changed` | ktoś zaczął lub skończył — sygnał do ściszenia/przywrócenia |
| `session_changed` | sesja zakończona lub rozpoczęta |

## Blokada

Twarda: kiedy ktoś inny mówi, skrót nie startuje nagrywania i nie ma ręcznego
przejęcia. Karta pokazuje, kto mówi i od jak dawna.

Jedyne automatyczne zdjęcie blokady to **wygaśnięcie pulsu**: jeśli serwer nie
dostanie `heartbeat` od mówiącego przez 10 sekund, uznaje, że skończył. To nie
jest obejście blokady, tylko definicja końca mówienia dla klienta, którego już
nie ma — bez tego jeden zawieszony laptop blokuje pokój wszystkim bezterminowo.

Utrata połączenia z serwerem **odblokowuje** klienta: bez wiedzy o pokoju
voiceflow wraca do trybu lokalnego i dyktuje normalnie. Awaria sieci nie może
odbierać podstawowej funkcji narzędzia.

## Ściszanie krzyżowe

Jest uprawnieniem, nie efektem ubocznym obecności w pokoju:

- działa tylko wobec osób w tym samym pokoju,
- każdy może je u siebie wyłączyć (`room.duck_for_others: false`),
- ścisza wyłącznie odtwarzanie, nigdy nie dotyka cudzego mikrofonu.

## Model danych

Postgres, baza `voiceflow`, user `voiceflow` jako właściciel — zgodnie z
konwencją pozostałych aplikacji na tym serwerze.

| tabela | zawartość |
|---|---|
| `users` | id, e-mail, nazwa wyświetlana, data utworzenia |
| `devices` | id, user_id, nazwa, hash tokenu, platforma, ostatni kontakt |
| `rooms` | id, kod (6 znaków), nazwa, właściciel, data utworzenia |
| `room_members` | pokój, użytkownik, data dołączenia |
| `sessions` | id, pokój, nazwa, start, koniec |
| `session_participants` | sesja, użytkownik, wejście, wyjście |
| `dictations` | sesja, użytkownik, moment, sekundy, słowa |

Ranking to zapytanie po `dictations` w obrębie sesji lub dnia. Kolumny na treść
dyktowania nie ma nigdzie.

## Logowanie

Link magiczny wysyłany przez `mail.pbdevs.com`, który już mamy. Bez haseł — nie
ma czego wykraść ani resetować. Po kliknięciu urządzenie dostaje długoterminowy
token, więc logowanie zdarza się raz na urządzenie.

Do pokoju dołącza się kodem sześcioznakowym albo linkiem.

## Ranking

Strona `/room/<kod>`, przeznaczona na tablet stojący obok albo telewizor:
kto jest w pokoju, kto właśnie mówi, wynik dnia i bieżącej sesji.

Kolumny: **słowa**, **czas mówienia**, **średnia długość dyktowania**.

Świadomie nie ma kolumny „jakość". Jakości promptu nie da się zmierzyć żadną z
tych liczb, a nazwanie tak którejkolwiek z nich byłoby udawaniem pomiaru.
Średnia długość dyktowania jest najbliższym uczciwym przybliżeniem „przemyślany
prompt kontra rzucone półsłówko" i jest opisana właśnie jako długość.

## Sytuacje awaryjne

| co się psuje | co się dzieje |
|---|---|
| serwer nieosiągalny | klient dyktuje lokalnie, bez blokady i ściszania; karta mówi, że pokój jest offline |
| mówiący traci połączenie | po 10 s bez pulsu blokada znika, dźwięk wraca |
| ściszenie nie dochodzi do kogoś | jego dźwięk gra dalej; nie blokuje to dyktowania nikomu |
| baza nieosiągalna | pokój działa na żywo, liczby z tego okresu przepadają — dyktowanie jest ważniejsze niż statystyka |

## Testy

Klient: `RoomClient` z podstawionym transportem — blokada, wygaśnięcie pulsu,
utrata połączenia, wywołania ściszania. Bez sieci, jak reszta zestawu.

Serwer: reguły przejść (kto może zacząć mówić, kiedy blokada wygasa, jak
zamyka się sesja) jako czyste funkcje, testowane bez bazy i bez WebSocketu.

Zapytania rankingowe: na przygotowanych danych, z asercją na konkretne liczby —
te same reguły liczenia słów co `statlib`.

## Wdrożenie

Zasób w Coolify typu Dockerfile (nie compose), baza i user `voiceflow` na
istniejącym serwerze Postgres w sekcji Infrastructure, połączenie po adresie
wewnętrznym w zmiennej środowiskowej. Sekrety wyłącznie w panelu, w repo tylko
`.env.example` z pustymi kluczami.

## Odłożone świadomie

Synchronizacja historii dyktowań między urządzeniami jednej osoby — to inny
problem (trwałe dane osobiste, konflikty, rozmiar) niż koordynacja na żywo i
zasługuje na własną specyfikację. Klienci macOS i Windows dostaną `RoomClient`
po tym, jak protokół sprawdzi się w praktyce na Linuksie. Wykrywanie po WiFi
jako wygoda przy dołączaniu — dopiero gdy dołączanie kodem zacznie uwierać.
