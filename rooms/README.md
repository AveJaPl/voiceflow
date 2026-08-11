# voiceflow — pokoje

Usługa wspólnych sesji dyktowania: kto teraz mówi, twarda blokada dla
pozostałych, ściszanie dźwięku u wszystkich w pokoju i ranking sesji.
Specyfikacja: `docs/superpowers/specs/2026-08-11-pokoje-i-sesje-design.md`.

## Co przechodzi przez tę usługę

Zdarzenia obecności („zaczynam mówić", „skończyłem") oraz liczby: słowa i
sekundy. **Audio i treść dyktowania nigdy.** Tabela `dictations` nie ma kolumny
na tekst i to jest celowe — dopisanie jej wymaga migracji, którą ktoś musi
świadomie zatwierdzić.

## Uruchomienie lokalne

```bash
npm install
DATABASE_URL=postgres://voiceflow:haslo@localhost:5432/voiceflow node server.js
```

Bez `DATABASE_URL` serwer odmawia startu — celowo, żeby nie dało się wdrożyć
usługi, która wstaje i dopiero potem okazuje się bezużyteczna.

## Testy

```bash
npm test
```

Cała logika pokoju (`src/roomState.js`) to czyste funkcje — testy nie
potrzebują bazy ani gniazd.

## Endpointy

| metoda | ścieżka | do czego |
|---|---|---|
| `GET` | `/health` | health-check |
| `POST` | `/api/devices` | rejestracja urządzenia, zwraca token |
| `POST` | `/api/rooms` | utworzenie pokoju **i pierwszej sesji** |
| `POST` | `/api/rooms/:kod/join` | dołączenie urządzenia do pokoju |
| `POST` | `/api/rooms/:kod/session/end` | zamknięcie sesji i otwarcie następnej |
| `GET` | `/api/rooms/:kod/ranking` | skład, bieżąca sesja i wynik |
| `WS` | `/ws?room=KOD&token=…` | obecność na żywo |
| `GET` | `/room/KOD` | strona rankingu (tablet, telewizor) |
