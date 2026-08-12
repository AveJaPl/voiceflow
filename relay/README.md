# Szept — relay (telefon ↔ Mac)

WebSocket relay dla zdalnego mikrofonu (`docs/plans/remote-mic-relay.md`). Łączy
DOKŁADNIE JEDNĄ sparowaną parę urządzeń: "mac" (trwały odbiorca) i "phone"
(nadawca audio). Każda ramka od phone leci 1:1 do mac — **czysty pass-through,
zero buforowania, zero dekodowania, zero zapisu audio na dysk.** Jedyne, co
relay trzyma na dysku, to token parowania (nie treść audio).

## Uruchomienie lokalne

```bash
npm install
ADMIN_SECRET=dowolny-sekret node server.js
```

Serwer bez `ADMIN_SECRET` **odmawia startu** — celowo, żeby nie dało się
przypadkiem wdrożyć z otwartym `/pair` (patrz sekcja Bezpieczeństwo w planie,
§3: "Bez autoryzacji to otwarta furtka").

## Endpointy

- `GET /health` — health-check, zwraca `{"status":"ok","service":"szept-relay"}`.
- `POST /pair` — generuje nowy token parowania (32 losowe bajty, base64url),
  **unieważnia poprzedni**. Wymaga nagłówka `Authorization: Bearer <ADMIN_SECRET>`
  (to jest osobny sekret administracyjny, NIE token parowania — bez niego
  ktokolwiek mógłby wygenerować sobie token i podpiąć się jako "phone" zamiast
  Wojtka). Zwraca `{"token": "...", "createdAt": "..."}`.
- `POST /register` — zakłada konto. Body `{"email": "...", "password": "..."}`,
  wymaga `Authorization: Bearer <ADMIN_SECRET>` (to prywatna usługa Wojtka, nie
  otwarta rejestracja). Zwraca `{"pairToken": "..."}` — **stały** token
  parowania konta, nigdy nie rotowany. `409` przy zajętym mailu.
- `POST /login` — `{"email", "password"}` → `{"pairToken": "..."}` (ten sam
  token co przy rejestracji, żeby telefon i Mac mogły go zapisać raz na zawsze).
  `401` przy złym mailu/haśle.
- `GET /sessions?limit=50` — ostatnie wpisy logu sesji (`limit` 1–500, domyślnie
  50), wymaga `Authorization: Bearer <ADMIN_SECRET>`.
- `wss://.../ws?role=mac&token=<token>` — trwałe połączenie Maca.
- `wss://.../ws?role=phone&token=<token>` — połączenie telefonu, wysyła binarne
  ramki audio.

`token` w `/ws` to **albo** token z `POST /pair` (stary, ręczny mechanizm —
działa dalej bez zmian), **albo** `pairToken` konta. Połączenia po koncie są
logowane do `session_log` (connect/disconnect, rola, nazwa urządzenia z ramki
`hello`); ręczne parowanie nie ma konta, do którego można by je przypisać, więc
nie trafia do logu.

Token jest wspólny dla obu ról (jedna para urządzeń, zgodnie z planem — YAGNI).
Nowe połączenie pod daną rolą zamyka poprzednie (reconnect/restart apki).
Jeśli "mac" nie jest połączony, "phone" dostaje natychmiast wiadomość
`{"type":"error","code":"mac_offline","message":"..."}` — nie ciche milczenie.

## Zmienne środowiskowe

| Zmienna | Wymagana | Domyślnie | Opis |
|---|---|---|---|
| `ADMIN_SECRET` | tak | — (start przerywa się bez niej) | Sekret do `POST /pair`. Wygeneruj losowy string, np. `openssl rand -base64 32`. |
| `PORT` | nie | `8080` | Port HTTP/WS. |
| `PAIRING_STORE_PATH` | nie | `./data/pairing.json` | Gdzie trzymany jest aktywny token. Musi być na trwałym wolumenie (patrz niżej), inaczej token parowania ginie przy każdym redeployu. |
| `DB_PATH` | nie | `./data/relay.db` | Baza SQLite z kontami i logiem sesji. Trwały wolumen jest tu **obowiązkowy** — bez niego konta znikają przy redeployu. |

## Baza (SQLite, `better-sqlite3`)

Schemat tworzy się sam przy starcie (`CREATE TABLE IF NOT EXISTS`):

- `accounts` — `id`, `email` (UNIQUE, lowercase), `password_hash` (bcrypt,
  `bcryptjs`, 10 rund), `pair_token` (UNIQUE, 32 losowe bajty base64url),
  `created_at`.
- `session_log` — `id`, `account_id` → `accounts(id)`, `role` (`mac`/`phone`),
  `device` (nazwa z ramki `hello`, NULL dopóki nie doszła), `event`
  (`connected`/`disconnected`), `at`.

## Testy

```bash
npm test
```

33 testy (`node --test`): pass-through phone→mac 1:1, wielokrotne ramki bez
buforowania, błąd `mac_offline` (przy rejestracji i przy próbie wysyłki),
zamiana starego połączenia przez nowe pod tą samą rolą, generacja/unieważnianie
tokenu (w tym przetrwanie restartu procesu), odrzucenie WS bez ważnego tokenu /
bez tokenu / z nieznaną rolą, `/health`, `/pair` z i bez poprawnego sekretu,
oraz konta: rejestracja i logowanie zwracają ten sam stały token, złe hasło =
401, duplikat maila = 409, para mac↔phone łączy się tokenem konta i przekazuje
ramki, wpisy connect/disconnect z nazwą urządzenia lądują w `session_log`,
`GET /sessions` gated sekretem admina, hasła trzymane jako hash bcrypt.
Zero prawdziwej sieci poza testami integracyjnymi w `test/server.test.js`,
które celowo używają realnego `http.Server` + klienta `ws`, ale wyłącznie na
loopbacku (`127.0.0.1`, port efemeryczny) — bez internetu, deterministyczne.

## Deployment na Coolify (VM Contabo)

**Nie wdrażaj sam — main session robi to po review.** Instrukcja dla main
session / Wojtka:

1. Coolify → nowa aplikacja → źródło: to repo (`szept`), **root directory:
   `services/relay`** (Coolify buduje tylko z tego podkatalogu).
2. Build pack: **Dockerfile** (jest w `services/relay/Dockerfile`) — nie
   Nixpacks, bo to nie jest projekt Next.js i nie ma czego autodetekcji
   zgadywać poprawnie dla WebSocketów.
3. Port: `8080` (albo ustaw `PORT` w env i dopasuj port w Coolify).
4. Zmienne środowiskowe w panelu Coolify:
   - `ADMIN_SECRET` — wygeneruj raz (`openssl rand -base64 32`), zapisz też
     lokalnie u siebie (potrzebny do każdego wywołania `POST /pair`, czyli do
     sparowania telefonu z Makiem).
   - opcjonalnie `PAIRING_STORE_PATH=/data/pairing.json` i `DB_PATH=/data/relay.db`,
     jeśli wolumen zamontowany pod `/data`.
5. **Trwały wolumen pod `PAIRING_STORE_PATH` i `DB_PATH`** (oba domyślnie w `/app/data`) —
   Coolify → Storage → dodaj persistent volume zamontowany np. na `/app/data`.
   Dla `DB_PATH` to warunek konieczny — bez wolumenu konta i log sesji giną przy
   każdym redeployu. Bez tego token parowania znika po każdym redeployu
   (kontener wraca do stanu "brak aktywnego tokenu", trzeba by parować od nowa — nieszkodliwe, ale
   niewygodne). Nie jest to krytyczne dla bezpieczeństwa (bez tokenu WS i tak
   nikt się nie połączy), tylko dla wygody.
6. Domena/TLS: Traefik w Coolify ogarnia `wss://` automatycznie tak samo jak
   dla innych projektów Wojtka (self-host stack na tym samym VM) — wystarczy
   podpiąć subdomenę w panelu.
7. Po wdrożeniu zweryfikuj: `curl https://<subdomena>/health` → `200
   {"status":"ok",...}`.
8. Sparowanie: `curl -X POST https://<subdomena>/pair -H "authorization:
   Bearer <ADMIN_SECRET>"` → zwraca token, który wpisuje się w Macu
   (`RemoteMicClient`, osobne zadanie) i w apce iOS (osobne zadanie, faza
   późniejsza).

## Jak main session ma to zweryfikować end-to-end LOKALNIE (przed jakimkolwiek deployem)

```bash
cd services/relay
npm install
npm test                                          # oczekiwane: "# pass 20", "# fail 0"

# Terminal A — odpal serwer:
ADMIN_SECRET=local-dev-secret PORT=8091 node server.js
# oczekiwane w logu: "[relay] nasłuch na :8091 (...)"

# Terminal B — sanity check przez curl:
curl -i http://127.0.0.1:8091/health
# oczekiwane: HTTP/1.1 200 OK, body {"status":"ok","service":"szept-relay"}

curl -i -X POST http://127.0.0.1:8091/pair -H "authorization: Bearer zle"
# oczekiwane: HTTP/1.1 401 Unauthorized

curl -i -X POST http://127.0.0.1:8091/pair -H "authorization: Bearer local-dev-secret"
# oczekiwane: HTTP/1.1 201 Created, body zawiera "token" i "createdAt"
```

Do pełnego testu pass-through (phone→mac przez prawdziwy WS na loopbacku) użyj
skryptu `node --test test/server.test.js` — test `end-to-end: phone wysyła
binarną ramkę audio, mac ją odbiera 1:1` robi dokładnie to, ręcznie, z dwoma
klientami `ws` i asercją na identyczność bajtów.
