# Pokoje — kamień milowy 1: żywy pokój Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dwie osoby w jednym pokoju widzą, kto mówi, nie mogą mówić naraz, ich głośniki ściszają się nawzajem, a tablet obok pokazuje ranking sesji na żywo.

**Architecture:** Jedna usługa Node (`rooms/`) serwująca REST, WebSocket i statyczną stronę rankingu, z Postgresem na istniejącym serwerze Coolify. Logika pokoju jest czystą funkcją stanu — bez bazy i bez gniazd — więc testuje się ją bez uruchamiania czegokolwiek. Po stronie demona Linux dochodzi `RoomClient` wstrzykiwany jak każdy inny współpracownik.

**Tech Stack:** Node 22 (`ws`, `pg`, wbudowany `node:test`), Postgres, Python 3.13 po stronie klienta, Docker/Coolify.

## Global Constraints

- Treść dyktowania i audio **nigdy** nie opuszczają urządzenia. Na serwer idą wyłącznie zdarzenia obecności oraz liczby (`words`, `seconds`).
- Tabela `dictations` nie ma kolumny na tekst — dodanie jej wymaga świadomej zmiany schematu.
- Blokada jest twarda: brak ręcznego przejęcia. Jedyne automatyczne zdjęcie to wygaśnięcie pulsu po **10 sekundach**.
- Puls klienta co **3 sekundy**.
- Kod pokoju: **6 znaków**, alfabet bez znaków mylących (`23456789ABCDEFGHJKLMNPQRSTUVWXYZ`).
- Utrata połączenia z serwerem **odblokowuje** klienta — voiceflow wraca do trybu lokalnego.
- Baza `voiceflow`, użytkownik `voiceflow` jako właściciel, połączenie po adresie wewnętrznym ze zmiennej `DATABASE_URL`. Sekrety wyłącznie w panelu Coolify; w repo `.env.example` z pustymi wartościami.
- Zasób w Coolify typu **Dockerfile**, nie docker-compose.
- Testy Pythona uruchamiane przez `uv run pytest`, testy Node przez `node --test`.

---

## Struktura plików

| plik | odpowiedzialność |
|---|---|
| `rooms/src/roomState.js` | czysta logika: kto może mówić, wygaszanie pulsu, rozliczanie sesji |
| `rooms/src/store.js` | zapytania do Postgresa, jedyne miejsce z SQL |
| `rooms/src/httpApi.js` | REST: rejestracja urządzenia, pokój, ranking |
| `rooms/src/wsHub.js` | połączenia WebSocket, rozgłaszanie stanu |
| `rooms/server.js` | spięcie powyższych, odczyt env |
| `rooms/migrations/001_init.sql` | schemat |
| `rooms/public/index.html` | strona rankingu (jeden ekran, WS) |
| `src/voiceflow/room.py` | `RoomClient` — klient po stronie demona |
| `src/voiceflow/daemon.py` | trzy punkty styku: blokada, raport, zdalne ściszanie |
| `src/voiceflow/config.py` | sekcja `room:` |

---

### Task 1: Logika pokoju jako czysta funkcja

**Files:**
- Create: `rooms/src/roomState.js`
- Test: `rooms/test/roomState.test.js`
- Create: `rooms/package.json`

**Interfaces:**
- Produces: `createRoomState()`, `join(state, deviceId, name)`, `startSpeaking(state, deviceId, now)`, `stopSpeaking(state, deviceId, now, {words, seconds})`, `heartbeat(state, deviceId, now)`, `expire(state, now)`. Wszystkie zwracają **nowy** stan; `startSpeaking` zwraca `{state, accepted, blockedBy}`.

- [ ] **Step 1: Utwórz `rooms/package.json`**

```json
{
  "name": "voiceflow-rooms",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test test/",
    "start": "node server.js"
  },
  "dependencies": {
    "pg": "^8.13.0",
    "ws": "^8.18.0"
  },
  "engines": { "node": ">=22" }
}
```

- [ ] **Step 2: Napisz testy, które mają nie przejść**

```javascript
// rooms/test/roomState.test.js
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRoomState, join, startSpeaking, stopSpeaking, heartbeat, expire } from '../src/roomState.js';

const HEARTBEAT_TIMEOUT_MS = 10_000;

test('pierwszy chętny dostaje głos', () => {
  let state = join(createRoomState(), 'filip', 'Filip');
  const result = startSpeaking(state, 'filip', 1000);
  assert.equal(result.accepted, true);
  assert.equal(result.state.speaking.deviceId, 'filip');
});

test('drugi dostaje odmowę z nazwą mówiącego', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000).state;
  const result = startSpeaking(state, 'wojtek', 1200);
  assert.equal(result.accepted, false);
  assert.equal(result.blockedBy, 'Filip');
  assert.equal(result.state.speaking.deviceId, 'filip', 'odmowa nie zmienia mówiącego');
});

test('nie ma przejęcia — powtórna próba też odpada', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000).state;
  state = startSpeaking(state, 'wojtek', 1200).state;
  const second = startSpeaking(state, 'wojtek', 1400);
  assert.equal(second.accepted, false, 'twarda blokada: drugie naciśnięcie nie przejmuje');
});

test('po zakończeniu mówienia głos jest wolny i liczby są zapamiętane', () => {
  let state = join(createRoomState(), 'filip', 'Filip');
  state = startSpeaking(state, 'filip', 1000).state;
  state = stopSpeaking(state, 'filip', 5000, { words: 12, seconds: 4 });
  assert.equal(state.speaking, null);
  assert.deepEqual(state.pending, [{ deviceId: 'filip', words: 12, seconds: 4, at: 5000 }]);
});

test('mówiący bez pulsu przez 10 s przestaje blokować', () => {
  let state = join(join(createRoomState(), 'filip', 'Filip'), 'wojtek', 'Wojtek');
  state = startSpeaking(state, 'filip', 1000).state;
  state = expire(state, 1000 + HEARTBEAT_TIMEOUT_MS + 1);
  assert.equal(state.speaking, null, 'zawieszony klient nie blokuje pokoju bezterminowo');
  assert.equal(startSpeaking(state, 'wojtek', 12_000).accepted, true);
});

test('puls przedłuża blokadę', () => {
  let state = join(createRoomState(), 'filip', 'Filip');
  state = startSpeaking(state, 'filip', 1000).state;
  state = heartbeat(state, 'filip', 9000);
  state = expire(state, 12_000);
  assert.equal(state.speaking?.deviceId, 'filip', 'puls w trakcie utrzymuje blokadę');
});

test('mówienie bez dołączenia jest odrzucane', () => {
  const result = startSpeaking(createRoomState(), 'obcy', 1000);
  assert.equal(result.accepted, false);
});
```

- [ ] **Step 3: Uruchom testy i potwierdź, że nie przechodzą**

Run: `cd rooms && node --test test/roomState.test.js`
Expected: FAIL — `Cannot find module '../src/roomState.js'`

- [ ] **Step 4: Napisz implementację**

```javascript
// rooms/src/roomState.js

/** Po tylu milisekundach bez pulsu uznajemy, że klient zniknął i przestał mówić.
 *  To nie jest obejście twardej blokady — to definicja końca mówienia dla
 *  klienta, którego już nie ma. Bez tego jeden zawieszony laptop blokuje
 *  pokój wszystkim bezterminowo. */
export const HEARTBEAT_TIMEOUT_MS = 10_000;

export function createRoomState() {
  return { members: {}, speaking: null, pending: [] };
}

export function join(state, deviceId, name) {
  return { ...state, members: { ...state.members, [deviceId]: { name } } };
}

export function leave(state, deviceId) {
  const members = { ...state.members };
  delete members[deviceId];
  const speaking = state.speaking?.deviceId === deviceId ? null : state.speaking;
  return { ...state, members, speaking };
}

export function startSpeaking(state, deviceId, now) {
  if (!state.members[deviceId]) {
    return { state, accepted: false, blockedBy: null };
  }
  if (state.speaking && state.speaking.deviceId !== deviceId) {
    const blockedBy = state.members[state.speaking.deviceId]?.name ?? null;
    return { state, accepted: false, blockedBy };
  }
  return {
    state: { ...state, speaking: { deviceId, since: now, lastSeen: now } },
    accepted: true,
    blockedBy: null,
  };
}

export function stopSpeaking(state, deviceId, now, { words, seconds }) {
  if (state.speaking?.deviceId !== deviceId) return state;
  return {
    ...state,
    speaking: null,
    pending: [...state.pending, { deviceId, words, seconds, at: now }],
  };
}

export function heartbeat(state, deviceId, now) {
  if (state.speaking?.deviceId !== deviceId) return state;
  return { ...state, speaking: { ...state.speaking, lastSeen: now } };
}

/** Zdejmuje blokadę po mówiącym, który przestał dawać znaki życia. */
export function expire(state, now) {
  if (!state.speaking) return state;
  if (now - state.speaking.lastSeen <= HEARTBEAT_TIMEOUT_MS) return state;
  return { ...state, speaking: null };
}

/** Zdarzenia gotowe do zapisania w bazie; wywołujący czyści je po zapisie. */
export function drainPending(state) {
  return [{ ...state, pending: [] }, state.pending];
}
```

- [ ] **Step 5: Uruchom testy i potwierdź, że przechodzą**

Run: `cd rooms && node --test test/roomState.test.js`
Expected: PASS, 7 testów

- [ ] **Step 6: Commit**

```bash
git add rooms/package.json rooms/src/roomState.js rooms/test/roomState.test.js
git commit -m "rooms: room state as a pure function

The speaking lock, the heartbeat expiry and the session accounting live in one
module with no database and no sockets, so the rules that decide who may talk
are testable without starting anything."
```

---

### Task 2: Schemat bazy i warstwa zapytań

**Files:**
- Create: `rooms/migrations/001_init.sql`
- Create: `rooms/src/store.js`
- Test: `rooms/test/store.test.js`

**Interfaces:**
- Consumes: nic z wcześniejszych zadań.
- Produces: `createStore(pool)` zwracające `{ registerDevice, createRoom, joinRoom, roomByCode, startSession, endSession, recordDictation, ranking }`. `ranking(roomId, sessionId)` zwraca `[{ deviceId, name, words, seconds, dictations }]` posortowane malejąco po `words`.

- [ ] **Step 1: Napisz migrację**

```sql
-- rooms/migrations/001_init.sql
CREATE TABLE IF NOT EXISTS devices (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  token_hash  TEXT NOT NULL,
  platform    TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen   TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS rooms (
  id          BIGSERIAL PRIMARY KEY,
  code        TEXT NOT NULL UNIQUE,
  name        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS room_members (
  room_id     BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  device_id   TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, device_id)
);

CREATE TABLE IF NOT EXISTS sessions (
  id          BIGSERIAL PRIMARY KEY,
  room_id     BIGINT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  name        TEXT,
  started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at    TIMESTAMPTZ
);

-- Liczby i tylko liczby. Kolumny na treść dyktowania tu NIE MA i jej brak jest
-- częścią kontraktu prywatności — dodanie jej wymaga świadomej migracji.
CREATE TABLE IF NOT EXISTS dictations (
  id          BIGSERIAL PRIMARY KEY,
  session_id  BIGINT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  device_id   TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  at          TIMESTAMPTZ NOT NULL,
  seconds     REAL NOT NULL,
  words       INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS dictations_session_idx ON dictations(session_id);
```

- [ ] **Step 2: Napisz test rankingu na podstawionym poolu**

```javascript
// rooms/test/store.test.js
import test from 'node:test';
import assert from 'node:assert/strict';
import { rankingRows } from '../src/store.js';

test('ranking sumuje słowa i sekundy per urządzenie i sortuje malejąco', () => {
  const rows = [
    { device_id: 'w', name: 'Wojtek', words: 40, seconds: 30, dictations: 2 },
    { device_id: 'f', name: 'Filip', words: 120, seconds: 90, dictations: 5 },
  ];
  const result = rankingRows(rows);
  assert.deepEqual(result.map((r) => r.name), ['Filip', 'Wojtek']);
  assert.equal(result[0].averageWords, 24, '120 słów / 5 dyktowań');
});

test('ranking bez dyktowań nie dzieli przez zero', () => {
  const result = rankingRows([{ device_id: 'f', name: 'Filip', words: 0, seconds: 0, dictations: 0 }]);
  assert.equal(result[0].averageWords, 0);
});
```

- [ ] **Step 3: Uruchom i potwierdź porażkę**

Run: `cd rooms && node --test test/store.test.js`
Expected: FAIL — brak eksportu `rankingRows`

- [ ] **Step 4: Napisz `store.js`**

```javascript
// rooms/src/store.js
import { randomUUID, randomBytes, createHash } from 'node:crypto';

const CODE_ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

export function generateCode() {
  const bytes = randomBytes(6);
  return Array.from(bytes, (b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join('');
}

export function hashToken(token) {
  return createHash('sha256').update(token).digest('hex');
}

/** Czysta część rankingu: przeliczenie wierszy z SQL na to, co widzi strona. */
export function rankingRows(rows) {
  return rows
    .map((row) => ({
      deviceId: row.device_id,
      name: row.name,
      words: Number(row.words),
      seconds: Number(row.seconds),
      dictations: Number(row.dictations),
      averageWords: Number(row.dictations) > 0
        ? Math.round(Number(row.words) / Number(row.dictations))
        : 0,
    }))
    .sort((a, b) => b.words - a.words);
}

export function createStore(pool) {
  return {
    async registerDevice(name, platform) {
      const id = randomUUID();
      const token = randomBytes(32).toString('base64url');
      await pool.query(
        'INSERT INTO devices (id, name, token_hash, platform) VALUES ($1, $2, $3, $4)',
        [id, name, hashToken(token), platform ?? null],
      );
      return { id, token };
    },

    async deviceByToken(token) {
      const { rows } = await pool.query(
        'SELECT id, name FROM devices WHERE token_hash = $1',
        [hashToken(token)],
      );
      return rows[0] ?? null;
    },

    async createRoom(name) {
      const code = generateCode();
      const { rows } = await pool.query(
        'INSERT INTO rooms (code, name) VALUES ($1, $2) RETURNING id, code',
        [code, name ?? null],
      );
      return rows[0];
    },

    async roomByCode(code) {
      const { rows } = await pool.query(
        'SELECT id, code, name FROM rooms WHERE code = $1',
        [code.toUpperCase()],
      );
      return rows[0] ?? null;
    },

    async joinRoom(roomId, deviceId) {
      await pool.query(
        `INSERT INTO room_members (room_id, device_id) VALUES ($1, $2)
         ON CONFLICT DO NOTHING`,
        [roomId, deviceId],
      );
    },

    async startSession(roomId, name) {
      const { rows } = await pool.query(
        'INSERT INTO sessions (room_id, name) VALUES ($1, $2) RETURNING id, name, started_at',
        [roomId, name ?? null],
      );
      return rows[0];
    },

    async activeSession(roomId) {
      const { rows } = await pool.query(
        `SELECT id, name, started_at FROM sessions
         WHERE room_id = $1 AND ended_at IS NULL
         ORDER BY started_at DESC LIMIT 1`,
        [roomId],
      );
      return rows[0] ?? null;
    },

    async endSession(sessionId) {
      await pool.query('UPDATE sessions SET ended_at = now() WHERE id = $1', [sessionId]);
    },

    async recordDictation(sessionId, deviceId, at, seconds, words) {
      await pool.query(
        'INSERT INTO dictations (session_id, device_id, at, seconds, words) VALUES ($1, $2, $3, $4, $5)',
        [sessionId, deviceId, new Date(at), seconds, words],
      );
    },

    async ranking(sessionId) {
      const { rows } = await pool.query(
        `SELECT d.device_id, dev.name,
                COALESCE(SUM(d.words), 0)   AS words,
                COALESCE(SUM(d.seconds), 0) AS seconds,
                COUNT(*)                    AS dictations
         FROM dictations d
         JOIN devices dev ON dev.id = d.device_id
         WHERE d.session_id = $1
         GROUP BY d.device_id, dev.name`,
        [sessionId],
      );
      return rankingRows(rows);
    },
  };
}
```

- [ ] **Step 5: Uruchom testy**

Run: `cd rooms && node --test test/store.test.js`
Expected: PASS, 2 testy

- [ ] **Step 6: Commit**

```bash
git add rooms/migrations rooms/src/store.js rooms/test/store.test.js
git commit -m "rooms: schema and queries

The dictations table carries seconds and words and has no column for the text
of a dictation. That absence is the privacy contract expressed in DDL: writing
transcripts here would take a migration somebody has to approve."
```

---

### Task 3: REST — rejestracja urządzenia, pokój, ranking

**Files:**
- Create: `rooms/src/httpApi.js`
- Test: `rooms/test/httpApi.test.js`

**Interfaces:**
- Consumes: `createStore(pool)` z Task 2.
- Produces: `createHttpApi({ store, rooms })` zwracające `handle(req, res)` obsługujące: `POST /api/devices`, `POST /api/rooms`, `POST /api/rooms/:code/join`, `POST /api/rooms/:code/session/end`, `GET /api/rooms/:code/ranking`, `GET /health`.

- [ ] **Step 1: Napisz testy z podstawionym store**

```javascript
// rooms/test/httpApi.test.js
import test from 'node:test';
import assert from 'node:assert/strict';
import { routeFor } from '../src/httpApi.js';

test('rozpoznaje trasy z kodem pokoju', () => {
  assert.deepEqual(routeFor('POST', '/api/rooms/AB23CD/join'), { name: 'join', code: 'AB23CD' });
  assert.deepEqual(routeFor('GET', '/api/rooms/AB23CD/ranking'), { name: 'ranking', code: 'AB23CD' });
  assert.deepEqual(routeFor('POST', '/api/rooms'), { name: 'createRoom', code: null });
  assert.deepEqual(routeFor('GET', '/health'), { name: 'health', code: null });
});

test('nieznana trasa to null, nie wyjątek', () => {
  assert.equal(routeFor('GET', '/api/nie-ma'), null);
});

test('kod pokoju jest normalizowany do wielkich liter', () => {
  assert.equal(routeFor('GET', '/api/rooms/ab23cd/ranking').code, 'AB23CD');
});
```

- [ ] **Step 2: Uruchom i potwierdź porażkę**

Run: `cd rooms && node --test test/httpApi.test.js`
Expected: FAIL — brak `routeFor`

- [ ] **Step 3: Napisz `httpApi.js`**

```javascript
// rooms/src/httpApi.js
const ROOM_PATH = /^\/api\/rooms\/([^/]+)(\/join|\/ranking|\/session\/end)?$/;

export function routeFor(method, url) {
  if (method === 'GET' && url === '/health') return { name: 'health', code: null };
  if (method === 'POST' && url === '/api/devices') return { name: 'registerDevice', code: null };
  if (method === 'POST' && url === '/api/rooms') return { name: 'createRoom', code: null };

  const match = ROOM_PATH.exec(url);
  if (!match) return null;
  const code = match[1].toUpperCase();
  const tail = match[2] ?? '';
  if (method === 'POST' && tail === '/join') return { name: 'join', code };
  if (method === 'GET' && tail === '/ranking') return { name: 'ranking', code };
  if (method === 'POST' && tail === '/session/end') return { name: 'endSession', code };
  return null;
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  res.end(payload);
}

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    return null;
  }
}

export function createHttpApi({ store }) {
  return async function handle(req, res) {
    const route = routeFor(req.method, req.url.split('?')[0]);
    if (!route) return sendJson(res, 404, { error: 'not_found' });

    if (route.name === 'health') return sendJson(res, 200, { status: 'ok', service: 'voiceflow-rooms' });

    if (route.name === 'registerDevice') {
      const body = await readJson(req);
      if (!body?.name) return sendJson(res, 400, { error: 'name_required' });
      const device = await store.registerDevice(body.name, body.platform);
      return sendJson(res, 201, device);
    }

    if (route.name === 'createRoom') {
      const body = await readJson(req);
      const room = await store.createRoom(body?.name);
      // Utworzenie pokoju JEST początkiem sesji — nikt nie tworzy pokoju,
      // żeby siedzieć w nim sam.
      const session = await store.startSession(room.id, body?.sessionName);
      return sendJson(res, 201, { ...room, session });
    }

    const room = await store.roomByCode(route.code);
    if (!room) return sendJson(res, 404, { error: 'room_not_found' });

    if (route.name === 'join') {
      const body = await readJson(req);
      const device = body?.token ? await store.deviceByToken(body.token) : null;
      if (!device) return sendJson(res, 401, { error: 'unknown_device' });
      await store.joinRoom(room.id, device.id);
      return sendJson(res, 200, { room, device: { id: device.id, name: device.name } });
    }

    if (route.name === 'endSession') {
      const active = await store.activeSession(room.id);
      if (active) await store.endSession(active.id);
      const next = await store.startSession(room.id, null);
      return sendJson(res, 200, { ended: active?.id ?? null, session: next });
    }

    if (route.name === 'ranking') {
      const active = await store.activeSession(room.id);
      const rows = active ? await store.ranking(active.id) : [];
      return sendJson(res, 200, { room, session: active, ranking: rows });
    }

    return sendJson(res, 404, { error: 'not_found' });
  };
}
```

- [ ] **Step 4: Uruchom testy**

Run: `cd rooms && node --test test/httpApi.test.js`
Expected: PASS, 3 testy

- [ ] **Step 5: Commit**

```bash
git add rooms/src/httpApi.js rooms/test/httpApi.test.js
git commit -m "rooms: REST for devices, rooms and ranking

Creating a room also starts its first session, because nobody creates a room to
sit in it alone."
```

---

### Task 4: WebSocket — obecność, blokada, rozgłaszanie

**Files:**
- Create: `rooms/src/wsHub.js`
- Test: `rooms/test/wsHub.test.js`

**Interfaces:**
- Consumes: `roomState.js` (Task 1), `store` (Task 2).
- Produces: `createHub({ store, now })` z `handleMessage(connection, message)` i `tick(now)`. `connection` to `{ send(obj), roomCode, deviceId }`.

- [ ] **Step 1: Napisz testy na sztucznych połączeniach**

```javascript
// rooms/test/wsHub.test.js
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHub } from '../src/wsHub.js';

function fakeConnection(deviceId, name) {
  return { deviceId, name, roomCode: 'ROOM01', sent: [], send(obj) { this.sent.push(obj); } };
}

const noopStore = {
  async activeSession() { return { id: 1 }; },
  async recordDictation() {},
};

test('drugi mówiący dostaje odmowę z nazwą blokującego', async () => {
  const hub = createHub({ store: noopStore });
  const filip = fakeConnection('f', 'Filip');
  const wojtek = fakeConnection('w', 'Wojtek');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(wojtek, { type: 'hello' });

  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);
  await hub.handleMessage(wojtek, { type: 'speaking_started' }, 1100);

  const denial = wojtek.sent.find((m) => m.type === 'speaking_denied');
  assert.ok(denial, 'odmowa musi trafić do odrzuconego');
  assert.equal(denial.blockedBy, 'Filip');
});

test('start mówienia rozgłasza się do pozostałych, ale nie do mówiącego', async () => {
  const hub = createHub({ store: noopStore });
  const filip = fakeConnection('f', 'Filip');
  const wojtek = fakeConnection('w', 'Wojtek');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(wojtek, { type: 'hello' });

  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);

  const toWojtek = wojtek.sent.filter((m) => m.type === 'speaker_changed');
  assert.equal(toWojtek.at(-1).speaking.name, 'Filip');
  assert.equal(
    filip.sent.filter((m) => m.type === 'speaker_changed').length, 0,
    'mówiący nie ścisza sobie dźwięku tym kanałem — robi to jego własny skrót',
  );
});

test('koniec mówienia zapisuje liczby do bazy', async () => {
  const recorded = [];
  const store = {
    async activeSession() { return { id: 7 }; },
    async recordDictation(sessionId, deviceId, at, seconds, words) {
      recorded.push({ sessionId, deviceId, seconds, words });
    },
  };
  const hub = createHub({ store });
  const filip = fakeConnection('f', 'Filip');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);
  await hub.handleMessage(filip, { type: 'speaking_ended', words: 9, seconds: 3.5 }, 4500);

  assert.deepEqual(recorded, [{ sessionId: 7, deviceId: 'f', seconds: 3.5, words: 9 }]);
});

test('tick zdejmuje blokadę po martwym mówiącym i powiadamia pokój', async () => {
  const hub = createHub({ store: noopStore });
  const filip = fakeConnection('f', 'Filip');
  const wojtek = fakeConnection('w', 'Wojtek');
  await hub.handleMessage(filip, { type: 'hello' });
  await hub.handleMessage(wojtek, { type: 'hello' });
  await hub.handleMessage(filip, { type: 'speaking_started' }, 1000);

  hub.tick(1000 + 10_001);

  const last = wojtek.sent.filter((m) => m.type === 'speaker_changed').at(-1);
  assert.equal(last.speaking, null, 'pokój dowiaduje się, że można znów mówić');
});
```

- [ ] **Step 2: Uruchom i potwierdź porażkę**

Run: `cd rooms && node --test test/wsHub.test.js`
Expected: FAIL — brak `createHub`

- [ ] **Step 3: Napisz `wsHub.js`**

```javascript
// rooms/src/wsHub.js
import {
  createRoomState, join, leave, startSpeaking, stopSpeaking, heartbeat, expire,
} from './roomState.js';

export function createHub({ store }) {
  /** kod pokoju -> { state, connections:Set } */
  const rooms = new Map();

  function room(code) {
    if (!rooms.has(code)) rooms.set(code, { state: createRoomState(), connections: new Set() });
    return rooms.get(code);
  }

  function speakerPayload(entry) {
    const speaking = entry.state.speaking;
    if (!speaking) return null;
    return {
      deviceId: speaking.deviceId,
      name: entry.state.members[speaking.deviceId]?.name ?? null,
      since: speaking.since,
    };
  }

  /** Mówiący celowo pomijany: jego dźwięk ścisza własny skrót, a podwójne
   *  ściszenie zapisałoby już ściszoną głośność jako "oryginalną". */
  function broadcastSpeaker(code, exceptDeviceId) {
    const entry = room(code);
    const payload = { type: 'speaker_changed', speaking: speakerPayload(entry) };
    for (const connection of entry.connections) {
      if (connection.deviceId === exceptDeviceId) continue;
      connection.send(payload);
    }
  }

  return {
    async handleMessage(connection, message, now = Date.now()) {
      const entry = room(connection.roomCode);

      if (message.type === 'hello') {
        entry.connections.add(connection);
        entry.state = join(entry.state, connection.deviceId, connection.name);
        connection.send({ type: 'room_state', speaking: speakerPayload(entry) });
        return;
      }

      if (message.type === 'heartbeat') {
        entry.state = heartbeat(entry.state, connection.deviceId, now);
        return;
      }

      if (message.type === 'speaking_started') {
        const result = startSpeaking(entry.state, connection.deviceId, now);
        entry.state = result.state;
        if (!result.accepted) {
          connection.send({ type: 'speaking_denied', blockedBy: result.blockedBy });
          return;
        }
        broadcastSpeaker(connection.roomCode, connection.deviceId);
        return;
      }

      if (message.type === 'speaking_ended') {
        entry.state = stopSpeaking(entry.state, connection.deviceId, now, {
          words: message.words ?? 0,
          seconds: message.seconds ?? 0,
        });
        broadcastSpeaker(connection.roomCode, connection.deviceId);
        const session = await store.activeSession(entry.roomId ?? null);
        if (session) {
          // Nieudany zapis liczb nie może przerwać dyktowania nikomu —
          // statystyka jest mniej ważna niż działający pokój.
          try {
            await store.recordDictation(
              session.id, connection.deviceId, now,
              message.seconds ?? 0, message.words ?? 0,
            );
          } catch (error) {
            console.error('[rooms] nie zapisano dyktowania:', error.message);
          }
        }
        entry.state = { ...entry.state, pending: [] };
        return;
      }
    },

    disconnect(connection) {
      const entry = room(connection.roomCode);
      entry.connections.delete(connection);
      const wasSpeaking = entry.state.speaking?.deviceId === connection.deviceId;
      entry.state = leave(entry.state, connection.deviceId);
      if (wasSpeaking) broadcastSpeaker(connection.roomCode, null);
    },

    tick(now = Date.now()) {
      for (const [code, entry] of rooms) {
        const before = entry.state.speaking?.deviceId ?? null;
        entry.state = expire(entry.state, now);
        const after = entry.state.speaking?.deviceId ?? null;
        if (before !== after) broadcastSpeaker(code, null);
      }
    },
  };
}
```

- [ ] **Step 4: Uruchom testy**

Run: `cd rooms && node --test test/wsHub.test.js`
Expected: PASS, 4 testy

- [ ] **Step 5: Commit**

```bash
git add rooms/src/wsHub.js rooms/test/wsHub.test.js
git commit -m "rooms: presence over WebSocket

The speaker is deliberately left out of its own broadcast: their audio is
ducked by their own hotkey, and ducking twice would record the already-ducked
volume as the original one to restore."
```

---

### Task 5: Spięcie serwera, Dockerfile, wdrożenie

**Files:**
- Create: `rooms/server.js`
- Create: `rooms/Dockerfile`
- Create: `rooms/.env.example`
- Create: `rooms/README.md`

**Interfaces:**
- Consumes: `createHttpApi` (Task 3), `createHub` (Task 4), `createStore` (Task 2).
- Produces: proces nasłuchujący na `PORT` (domyślnie 3000), obsługujący `/api/*`, `/ws`, `/health` i pliki z `public/`.

- [ ] **Step 1: Napisz `server.js`**

```javascript
// rooms/server.js
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join as joinPath, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { WebSocketServer } from 'ws';
import { createStore } from './src/store.js';
import { createHttpApi } from './src/httpApi.js';
import { createHub } from './src/wsHub.js';

const here = dirname(fileURLToPath(import.meta.url));
const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) {
  console.error('[rooms] DATABASE_URL nie jest ustawiony — odmawiam startu.');
  process.exit(1);
}

const pool = new pg.Pool({ connectionString: databaseUrl });
await pool.query(await readFile(joinPath(here, 'migrations/001_init.sql'), 'utf8'));

const store = createStore(pool);
const api = createHttpApi({ store });
const hub = createHub({ store });

const server = createServer(async (req, res) => {
  const path = req.url.split('?')[0];
  if (path.startsWith('/api/') || path === '/health') return api(req, res);
  const file = path === '/' || path.startsWith('/room/') ? 'index.html' : path.slice(1);
  try {
    const body = await readFile(joinPath(here, 'public', file));
    const type = file.endsWith('.html') ? 'text/html; charset=utf-8' : 'text/plain';
    res.writeHead(200, { 'content-type': type });
    res.end(body);
  } catch {
    res.writeHead(404).end('not found');
  }
});

const wss = new WebSocketServer({ server, path: '/ws' });
wss.on('connection', async (socket, req) => {
  const url = new URL(req.url, 'http://localhost');
  const device = await store.deviceByToken(url.searchParams.get('token') ?? '');
  const roomCode = (url.searchParams.get('room') ?? '').toUpperCase();
  if (!device || !roomCode) return socket.close(4001, 'unauthorized');

  const connection = {
    deviceId: device.id,
    name: device.name,
    roomCode,
    send(obj) { if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(obj)); },
  };
  socket.on('message', async (raw) => {
    let message;
    try { message = JSON.parse(raw.toString()); } catch { return; }
    await hub.handleMessage(connection, message);
  });
  socket.on('close', () => hub.disconnect(connection));
  await hub.handleMessage(connection, { type: 'hello' });
});

setInterval(() => hub.tick(), 2000).unref();

const port = Number(process.env.PORT ?? 3000);
server.listen(port, () => console.log(`[rooms] nasłuch na :${port}`));
```

- [ ] **Step 2: Napisz `Dockerfile`**

```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY . .
EXPOSE 3000
CMD ["node", "server.js"]
```

- [ ] **Step 3: Napisz `.env.example`**

```bash
# Adres WEWNĘTRZNY wspólnego Postgresa z sekcji Infrastructure w Coolify.
# Wartość wpisujesz w panelu Coolify, nie tutaj.
DATABASE_URL=
PORT=3000
```

- [ ] **Step 4: Uruchom cały zestaw testów Node**

Run: `cd rooms && node --test test/`
Expected: PASS, 16 testów

- [ ] **Step 5: Commit**

```bash
git add rooms/server.js rooms/Dockerfile rooms/.env.example rooms/README.md
git commit -m "rooms: wire the service and its container

Refuses to start without DATABASE_URL, the same way the relay refuses to start
without ADMIN_SECRET: a service that comes up half-configured fails later, in a
place that does not point at the cause."
```

- [ ] **Step 6: Wyklikaj bazę i zasób w Coolify**

W Coolify: Infrastructure → wspólny Postgres → utwórz bazę `voiceflow` i użytkownika `voiceflow`, ustaw go właścicielem tej bazy. Następnie w projekcie `apps` dodaj zasób typu **Dockerfile** wskazujący na `AveJaPl/voiceflow`, katalog bazowy `/rooms`, port 3000, domena `rooms.pbdevs.com`, źródło: GitHub App `coolify-pbdevs-vps`. W zmiennych środowiskowych ustaw `DATABASE_URL` po adresie wewnętrznym. Sprawdź `GET https://rooms.pbdevs.com/health`.

---

### Task 6: Klient — `RoomClient`

**Files:**
- Create: `src/voiceflow/room.py`
- Test: `tests/test_room.py`

**Interfaces:**
- Produces: `RoomClient(config, on_remote_speaking, on_remote_silence)` z `may_start() -> tuple[bool, str | None]`, `report_started()`, `report_finished(words, seconds)`, `start()`, `stop()`. `may_start()` zwraca `(True, None)` gdy wolno mówić, `(False, "Wojtek")` gdy blokuje ktoś inny.

- [ ] **Step 1: Napisz testy z podstawionym transportem**

```python
# tests/test_room.py
"""Tests for the room client without a network."""

from __future__ import annotations

from voiceflow.config import RoomConfig
from voiceflow.room import RoomClient


class _Transport:
    """Records what was sent and lets a test push server messages in."""

    def __init__(self) -> None:
        self.sent: list[dict] = []
        self.connected = True
        self._on_message = None

    def send(self, payload: dict) -> None:
        self.sent.append(payload)

    def on_message(self, callback) -> None:
        self._on_message = callback

    def deliver(self, payload: dict) -> None:
        assert self._on_message is not None
        self._on_message(payload)


def _client(**kwargs):
    transport = _Transport()
    ducked: list[str] = []
    client = RoomClient(
        RoomConfig(enabled=True, server="wss://example", code="ROOM01", **kwargs),
        on_remote_speaking=lambda name: ducked.append(name),
        on_remote_silence=lambda: ducked.append("<cisza>"),
        transport=transport,
    )
    return client, transport, ducked


def test_free_room_allows_dictation() -> None:
    client, _transport, _ducked = _client()

    assert client.may_start() == (True, None)


def test_someone_else_speaking_blocks_with_their_name() -> None:
    client, transport, _ducked = _client()

    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek", "deviceId": "w"}})

    assert client.may_start() == (False, "Wojtek")


def test_remote_speaker_ducks_local_audio() -> None:
    client, transport, ducked = _client()

    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek", "deviceId": "w"}})
    transport.deliver({"type": "speaker_changed", "speaking": None})

    assert ducked == ["Wojtek", "<cisza>"]


def test_ducking_can_be_switched_off_locally() -> None:
    client, transport, ducked = _client(duck_for_others=False)

    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek", "deviceId": "w"}})

    assert ducked == [], "wyciszanie przez innych jest uprawnieniem, nie obowiązkiem"
    assert client.may_start() == (False, "Wojtek"), "blokada działa niezależnie od ściszania"


def test_lost_connection_unblocks_rather_than_traps() -> None:
    """A room the client cannot reach must not take dictation away."""
    client, transport, _ducked = _client()
    transport.deliver({"type": "speaker_changed", "speaking": {"name": "Wojtek", "deviceId": "w"}})

    client.on_disconnected()

    assert client.may_start() == (True, None)


def test_finished_dictation_reports_only_numbers() -> None:
    client, transport, _ducked = _client()

    client.report_started()
    client.report_finished(words=12, seconds=4.25)

    assert transport.sent[-2] == {"type": "speaking_started"}
    assert transport.sent[-1] == {"type": "speaking_ended", "words": 12, "seconds": 4.25}
    assert all("text" not in message for message in transport.sent), "treść nigdy nie wychodzi"


def test_disabled_room_never_blocks() -> None:
    transport = _Transport()
    client = RoomClient(
        RoomConfig(enabled=False),
        on_remote_speaking=lambda name: None,
        on_remote_silence=lambda: None,
        transport=transport,
    )

    assert client.may_start() == (True, None)
```

- [ ] **Step 2: Uruchom i potwierdź porażkę**

Run: `uv run pytest tests/test_room.py -v`
Expected: FAIL — `ModuleNotFoundError: voiceflow.room`

- [ ] **Step 3: Napisz `room.py`**

```python
"""Client side of a shared dictation room.

Holds no audio and no text. It publishes two facts — "I started speaking" and
"I finished, N words in M seconds" — and consumes one: who, if anyone, is
speaking right now. Everything else the daemon already knows how to do.
"""

from __future__ import annotations

import logging
from collections.abc import Callable

from voiceflow.config import RoomConfig

LOGGER = logging.getLogger(__name__)


class RoomClient:
    """Tracks who is speaking in the room and gates the local hotkey."""

    def __init__(
        self,
        config: RoomConfig,
        *,
        on_remote_speaking: Callable[[str], None],
        on_remote_silence: Callable[[], None],
        transport: object | None = None,
    ) -> None:
        self.config = config
        self._on_remote_speaking = on_remote_speaking
        self._on_remote_silence = on_remote_silence
        self._transport = transport
        self._remote_speaker: str | None = None
        if transport is not None and hasattr(transport, "on_message"):
            transport.on_message(self._handle)

    def may_start(self) -> tuple[bool, str | None]:
        """Whether the local hotkey may begin recording, and who blocks it."""
        if not self.config.enabled:
            return True, None
        if self._remote_speaker is None:
            return True, None
        return False, self._remote_speaker

    def report_started(self) -> None:
        self._send({"type": "speaking_started"})

    def report_finished(self, *, words: int, seconds: float) -> None:
        self._send({"type": "speaking_ended", "words": words, "seconds": seconds})

    def on_disconnected(self) -> None:
        """Server unreachable: forget the room rather than hold the lock.

        A room we cannot see is a room we cannot be blocked by. Losing the
        network must never take dictation away — that is the whole tool.
        """
        if self._remote_speaker is not None:
            self._remote_speaker = None
            self._on_remote_silence()
        LOGGER.info("Pokój niedostępny; dyktowanie działa lokalnie")

    # -- plumbing ----------------------------------------------------------

    def _send(self, payload: dict) -> None:
        if not self.config.enabled or self._transport is None:
            return
        try:
            self._transport.send(payload)
        except Exception:
            LOGGER.exception("Nie udało się wysłać zdarzenia pokoju")

    def _handle(self, payload: dict) -> None:
        if payload.get("type") not in ("speaker_changed", "room_state"):
            return
        speaking = payload.get("speaking")
        name = speaking.get("name") if isinstance(speaking, dict) else None
        if name == self._remote_speaker:
            return
        self._remote_speaker = name
        if name is None:
            self._on_remote_silence()
        elif self.config.duck_for_others:
            self._on_remote_speaking(name)
```

- [ ] **Step 4: Uruchom testy**

Run: `uv run pytest tests/test_room.py -v`
Expected: PASS, 7 testów

- [ ] **Step 5: Commit**

```bash
git add src/voiceflow/room.py tests/test_room.py
git commit -m "room: client that gates the hotkey and never sends text

Losing the server unblocks the client rather than trapping it: a room we cannot
see is a room we cannot be blocked by, and a network failure must never take
dictation away."
```

---

### Task 7: Konfiguracja — sekcja `room:`

**Files:**
- Modify: `src/voiceflow/config.py`
- Test: `tests/test_config.py`

**Interfaces:**
- Produces: `RoomConfig(enabled: bool = False, server: str = "", code: str = "", token: str = "", duck_for_others: bool = True)` dostępne jako `Config.room`.

- [ ] **Step 1: Napisz testy**

```python
def test_room_is_off_by_default() -> None:
    config = parse_config({})

    assert config.room.enabled is False
    assert config.room.duck_for_others is True


def test_room_section_is_parsed() -> None:
    config = parse_config({
        "room": {
            "enabled": True,
            "server": "wss://rooms.pbdevs.com",
            "code": "ab23cd",
            "duck_for_others": False,
        }
    })

    assert config.room.enabled is True
    assert config.room.code == "AB23CD", "kod pokoju jest niewrażliwy na wielkość liter"
    assert config.room.duck_for_others is False
```

- [ ] **Step 2: Uruchom i potwierdź porażkę**

Run: `uv run pytest tests/test_config.py -k room -v`
Expected: FAIL — `Config` nie ma atrybutu `room`

- [ ] **Step 3: Dodaj `RoomConfig` do `config.py`**

```python
@dataclass(frozen=True, slots=True)
class RoomConfig:
    """Shared dictation room. Off unless explicitly joined.

    This is the only feature that sends anything off the machine, so it is
    opt-in and says so in the generated config file.
    """

    enabled: bool = False
    server: str = ""
    code: str = ""
    token: str = ""
    #: Whether somebody else speaking may quieten audio here. A permission,
    #: not a side effect of being in the room.
    duck_for_others: bool = True
```

Dopisz do `Config`: `room: RoomConfig = field(default_factory=RoomConfig)`, do `_SCHEMA`: `"room": {"enabled", "server", "code", "token", "duck_for_others"}`, oraz do `parse_config`:

```python
        room=RoomConfig(
            enabled=_boolean(room.get("enabled", False), False, "room.enabled"),
            server=str(room.get("server", "") or ""),
            code=str(room.get("code", "") or "").upper(),
            token=str(room.get("token", "") or ""),
            duck_for_others=_boolean(
                room.get("duck_for_others", True), True, "room.duck_for_others"
            ),
        ),
```

- [ ] **Step 4: Uruchom testy**

Run: `uv run pytest tests/test_config.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/voiceflow/config.py tests/test_config.py
git commit -m "config: the room section, off by default

It is the one feature that sends anything off the machine, so it stays opt-in."
```

---

### Task 8: Demon — trzy punkty styku

**Files:**
- Modify: `src/voiceflow/daemon.py`
- Test: `tests/test_daemon.py`

**Interfaces:**
- Consumes: `RoomClient` (Task 6), `RoomConfig` (Task 7).
- Produces: `VoiceflowDaemon(..., room: RoomClient | None = None)`.

- [ ] **Step 1: Napisz test blokady**

```python
class _Room:
    def __init__(self, blocked_by: str | None = None) -> None:
        self.blocked_by = blocked_by
        self.reports: list[tuple] = []

    def may_start(self):
        return (self.blocked_by is None, self.blocked_by)

    def report_started(self):
        self.reports.append(("started",))

    def report_finished(self, *, words, seconds):
        self.reports.append(("finished", words, seconds))


def test_room_blocks_recording_and_says_who(tmp_path: Path) -> None:
    overlay = _Overlay()
    recorder = _Recorder(tmp_path / "recording.wav")
    daemon = VoiceflowDaemon(
        Config(),
        recorder=recorder,
        transcriber=_BlockingTranscriber(),
        injector=_Injector(),  # type: ignore[arg-type]
        notifier=_Notifier(),  # type: ignore[arg-type]
        overlay=overlay,  # type: ignore[arg-type]
        history=History(HistoryConfig(), tmp_path / "history.jsonl"),
        room=_Room(blocked_by="Wojtek"),  # type: ignore[arg-type]
    )

    response = daemon.handle_command("start")

    assert response["ok"] is False
    assert "Wojtek" in response["message"]
    assert daemon.state is State.IDLE
    assert not recorder.path.exists(), "zablokowane dyktowanie nie dotyka mikrofonu"
    assert any(call[0] == "notice" and "Wojtek" in (call[2] or "") for call in overlay.calls)
```

- [ ] **Step 2: Uruchom i potwierdź porażkę**

Run: `uv run pytest tests/test_daemon.py -k room -v`
Expected: FAIL — `VoiceflowDaemon` nie przyjmuje `room`

- [ ] **Step 3: Wprowadź trzy zmiany w `daemon.py`**

W `__init__` dodaj parametr `room: RoomClient | None = None` i:

```python
        self.room = room or RoomClient(
            config.room,
            on_remote_speaking=lambda name: self.micmuter.mute(),
            on_remote_silence=self.micmuter.unmute,
        )
```

Na początku `_start()`, przed wyciszeniem mikrofonu:

```python
            allowed, blocked_by = self.room.may_start()
            if not allowed:
                # Cudze dyktowanie trwa. Karta mówi kto, bo "nie działa" bez
                # powodu jest gorsze niż brak funkcji.
                message = f"{blocked_by} teraz dyktuje"
                self.overlay.notice(message)
                return {"ok": False, "message": message, "state": self.state.value}
```

Po `state = State.RECORDING` dodaj `self.room.report_started()`, a w `_transcribe_and_inject`, w tym samym miejscu gdzie powstaje wpis historii:

```python
                self.room.report_finished(
                    words=len(result.text.split()), seconds=result.audio_seconds
                )
```

- [ ] **Step 4: Uruchom cały zestaw**

Run: `uv run pytest -q`
Expected: PASS, wszystkie testy

- [ ] **Step 5: Commit**

```bash
git add src/voiceflow/daemon.py tests/test_daemon.py
git commit -m "daemon: honour the room lock and duck for remote speakers

Remote ducking reuses MicMuter untouched — the same code the local hotkey runs,
triggered by somebody else's event. The hard part of this feature, restoring
volumes faithfully around streams that vanish, was already written and tested."
```

---

### Task 9: Strona rankingu

**Files:**
- Create: `rooms/public/index.html`

**Interfaces:**
- Consumes: `GET /api/rooms/:code/ranking` (Task 3), zdarzenia `speaker_changed` z `/ws` (Task 4).

- [ ] **Step 1: Napisz stronę**

Jeden plik, bez frameworka i bez budowania: paleta i typografia przeniesione z aplikacji linuksowej (`#0d0d0f` tło, `#131316` karty, `#f5f5f7` tekst, `#ff453a` wyłącznie dla nagrywania), odczyt kodu pokoju ze ścieżki `/room/<KOD>`, odpytanie `/api/rooms/<KOD>/ranking` co 5 sekund i nasłuch WebSocketu dla natychmiastowej zmiany mówiącego. Kolumny: **słowa**, **czas mówienia**, **średnia długość**. Nagłówek pokazuje nazwę sesji i czas jej trwania.

- [ ] **Step 2: Sprawdź lokalnie**

Run: `cd rooms && DATABASE_URL=... node server.js`, otwórz `http://localhost:3000/room/ABC123`
Expected: strona pokazuje pusty ranking i status połączenia; po zdarzeniu `speaker_changed` nazwa mówiącego pojawia się natychmiast.

- [ ] **Step 3: Commit**

```bash
git add rooms/public/index.html
git commit -m "rooms: the ranking screen

One file, no framework and no build step, because it is one screen. Palette and
type come from the Linux application so the three surfaces look like one product."
```

---

### Task 10: Dokumentacja i zmiana obietnicy na landingu

**Files:**
- Modify: `README.md`
- Modify: `site/en/index.html`, `site/pl/index.html`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Popraw obietnicę**

Wszędzie, gdzie stoi „no audio ever leaving your machine" / „nic nie opuszcza Twojej maszyny", zmień na sformułowanie, które zostaje prawdziwe po dołączeniu do pokoju: **„nagranie i tekst nigdy nie opuszczają Twojej maszyny"**. Dopisz akapit o pokoju: co dokładnie wychodzi (zdarzenia obecności i liczby), że jest wyłączony domyślnie i że bez niego nic się nie zmienia.

- [ ] **Step 2: Uruchom testy i wypchnij**

Run: `uv run pytest -q && cd rooms && node --test test/`
Expected: PASS po obu stronach

- [ ] **Step 3: Commit**

```bash
git add README.md site CHANGELOG.md
git commit -m "Say what rooms send, on the page that promises they do not

The claim that nothing leaves the machine stops being true the moment somebody
joins a room. It becomes: the recording and the text never leave. Weaker on
paper, and true, which the previous one would not have been."
```

---

## Samoprzegląd planu

**Pokrycie specyfikacji:** kontrakt prywatności → Task 2 (brak kolumny) + Task 6 (test „treść nigdy nie wychodzi") + Task 10 (landing). Pokój=sesja → Task 3. Twarda blokada i wygaszanie pulsu → Task 1, 4, 6, 8. Ściszanie krzyżowe jako uprawnienie → Task 6, 7, 8. Ranking bez „jakości" → Task 2, 9. Sytuacje awaryjne → Task 1 (puls), 4 (błąd zapisu), 6 (utrata połączenia). Wdrożenie → Task 5.

**Świadomie poza planem:** logowanie linkiem magicznym i synchronizacja historii — kamień milowy 2. Pokój działa bez kont: urządzenie rejestruje się nazwą, dostaje token, wchodzi kodem.

**Spójność nazw:** `may_start()`, `report_started()`, `report_finished(words, seconds)`, `on_disconnected()` w Task 6 = użycia w Task 8. `startSpeaking/stopSpeaking/heartbeat/expire` w Task 1 = wywołania w Task 4. `activeSession/recordDictation/ranking` w Task 2 = użycia w Task 3 i 4.
