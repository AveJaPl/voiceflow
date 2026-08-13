import test from 'node:test';
import assert from 'node:assert/strict';
import { routeFor, createHttpApi } from '../src/httpApi.js';

test('rozpoznaje trasy z kodem pokoju', () => {
  assert.deepEqual(routeFor('POST', '/api/rooms/AB23CD/join'), { name: 'join', code: 'AB23CD' });
  assert.deepEqual(routeFor('GET', '/api/rooms/AB23CD/ranking'), { name: 'ranking', code: 'AB23CD' });
  assert.deepEqual(routeFor('POST', '/api/rooms'), { name: 'createRoom', code: null });
  assert.deepEqual(routeFor('GET', '/health'), { name: 'health', code: null });
});

test('nieznana trasa to null, nie wyjątek', () => {
  assert.equal(routeFor('GET', '/api/nie-ma'), null);
  assert.equal(routeFor('DELETE', '/api/rooms/AB23CD/join'), null);
});

test('kod pokoju jest normalizowany do wielkich liter', () => {
  assert.equal(routeFor('GET', '/api/rooms/ab23cd/ranking').code, 'AB23CD');
});

// --- zachowanie API na podstawionym store ---------------------------------

function fakeStore(overrides = {}) {
  return {
    async registerDevice(name) { return { id: 'dev-1', token: 'tok', name }; },
    async deviceByToken(token) { return token === 'tok' ? { id: 'dev-1', name: 'Filip' } : null; },
    async createRoom(name) { return { id: 1, code: 'AB23CD', name }; },
    async roomByCode(code) { return code === 'AB23CD' ? { id: 1, code, name: null } : null; },
    async joinRoom() {},
    async members() { return [{ id: 'dev-1', name: 'Filip' }]; },
    async startSession(roomId, name) { return { id: 7, name, started_at: '2026-08-11T12:00:00Z' }; },
    async activeSession() { return { id: 7, name: null, started_at: '2026-08-11T12:00:00Z' }; },
    async endSession() {},
    async ranking() { return [{ deviceId: 'dev-1', name: 'Filip', words: 10, seconds: 5, dictations: 1, averageWords: 10 }]; },
    async sessionHistory() { return []; },
    async sessionCount() { return 0; },
    async roomSummary() { return []; },
    async hourlyActivity() { return []; },
    ...overrides,
  };
}

function fakeExchange(method, url, body) {
  const req = {
    method,
    url,
    async *[Symbol.asyncIterator]() {
      if (body !== undefined) yield Buffer.from(JSON.stringify(body));
    },
  };
  const res = {
    statusCode: null,
    headers: null,
    body: null,
    writeHead(status, headers) { this.statusCode = status; this.headers = headers; return this; },
    end(payload) { this.body = payload ? JSON.parse(payload) : null; },
  };
  return { req, res };
}

test('utworzenie pokoju od razu otwiera sesję', async () => {
  const handle = createHttpApi({ store: fakeStore() });
  const { req, res } = fakeExchange('POST', '/api/rooms', { name: 'Salon' });

  await handle(req, res);

  assert.equal(res.statusCode, 201);
  assert.equal(res.body.code, 'AB23CD');
  assert.equal(res.body.session.id, 7, 'nikt nie tworzy pokoju, żeby siedzieć w nim sam');
});

test('dołączenie bez znanego tokenu jest odrzucane', async () => {
  const handle = createHttpApi({ store: fakeStore() });
  const { req, res } = fakeExchange('POST', '/api/rooms/AB23CD/join', { token: 'obcy' });

  await handle(req, res);

  assert.equal(res.statusCode, 401);
});

test('nieistniejący pokój to 404, nie awaria', async () => {
  const handle = createHttpApi({ store: fakeStore() });
  const { req, res } = fakeExchange('GET', '/api/rooms/ZZZZZZ/ranking');

  await handle(req, res);

  assert.equal(res.statusCode, 404);
  assert.equal(res.body.error, 'room_not_found');
});

test('zakończenie sesji od razu otwiera następną w tym samym pokoju', async () => {
  const ended = [];
  const store = fakeStore({ async endSession(id) { ended.push(id); } });
  const handle = createHttpApi({ store });
  const { req, res } = fakeExchange('POST', '/api/rooms/AB23CD/session/end');

  await handle(req, res);

  assert.deepEqual(ended, [7]);
  assert.equal(res.body.session.id, 7, 'pokój żyje dalej, zaczyna się kolejna sesja');
});

test('uszkodzony JSON nie wywraca serwera', async () => {
  const handle = createHttpApi({ store: fakeStore() });
  const req = {
    method: 'POST',
    url: '/api/devices',
    async *[Symbol.asyncIterator]() { yield Buffer.from('{to nie jest json'); },
  };
  const res = {
    statusCode: null, body: null,
    writeHead(status) { this.statusCode = status; return this; },
    end(payload) { this.body = payload ? JSON.parse(payload) : null; },
  };

  await handle(req, res);

  assert.equal(res.statusCode, 400);
});

test('nazwana sesja ma własną trasę, odrębną od jej zakończenia', () => {
  assert.deepEqual(routeFor('POST', '/api/rooms/AB23CD/session'), {
    name: 'startSession',
    code: 'AB23CD',
  });
  assert.deepEqual(routeFor('POST', '/api/rooms/AB23CD/session/end'), {
    name: 'endSession',
    code: 'AB23CD',
  });
});

test('rozpoczęcie nazwanej sesji zamyka poprzednią', async () => {
  // Dwie otwarte sesje w jednym pokoju rozjechałyby ranking, bo liczy się
  // zawsze jedna aktywna.
  const ended = [];
  const started = [];
  const store = fakeStore({
    async endSession(id) { ended.push(id); },
    async startSession(roomId, name) { started.push(name); return { id: 8, name, started_at: 'x' }; },
  });
  const handle = createHttpApi({ store });
  const { req, res } = fakeExchange('POST', '/api/rooms/AB23CD/session', { name: 'coding session' });

  await handle(req, res);

  assert.equal(res.statusCode, 201);
  assert.deepEqual(ended, [7]);
  assert.deepEqual(started, ['coding session']);
  assert.equal(res.body.session.name, 'coding session');
});

test('sesja bez nazwy zapisuje null, a nie pusty napis', async () => {
  const started = [];
  const store = fakeStore({
    async startSession(roomId, name) { started.push(name); return { id: 8, name, started_at: 'x' }; },
  });
  const handle = createHttpApi({ store });
  const { req, res } = fakeExchange('POST', '/api/rooms/AB23CD/session', { name: '' });

  await handle(req, res);

  assert.deepEqual(started, [null], 'pusta nazwa to brak nazwy, nie nazwa ""');
});

test('nazwana sesja w nieistniejącym pokoju to 404', async () => {
  const handle = createHttpApi({ store: fakeStore() });
  const { req, res } = fakeExchange('POST', '/api/rooms/ZZZZZZ/session', { name: 'x' });

  await handle(req, res);

  assert.equal(res.statusCode, 404);
});

test('historia pokoju ma własną trasę', () => {
  assert.deepEqual(routeFor('GET', '/api/rooms/AB23CD/history'), {
    name: 'history',
    code: 'AB23CD',
  });
});

test('historia zwraca sesje, osoby i zgodne z nimi sumy', async () => {
  const store = fakeStore({
    async sessionHistory() {
      return [
        { id: 9, name: 'coding session', startedAt: 'b', endedAt: null,
          words: 40, seconds: 20, dictations: 1, speakers: 1, averageWords: 40 },
        { id: 7, name: null, startedAt: 'a', endedAt: 'a2',
          words: 60, seconds: 30, dictations: 2, speakers: 1, averageWords: 30 },
      ];
    },
    async sessionCount() { return 2; },
    async roomSummary() {
      return [
        { deviceId: 'dev-1', name: 'Filip', sessions: 2, words: 100,
          seconds: 50, dictations: 3, averageWords: 33 },
      ];
    },
  });
  const handle = createHttpApi({ store });
  const { req, res } = fakeExchange('GET', '/api/rooms/AB23CD/history');

  await handle(req, res);

  assert.equal(res.statusCode, 200);
  assert.equal(res.body.sessions.length, 2);
  assert.equal(res.body.sessions[0].name, 'coding session', 'najnowsza sesja pierwsza');
  assert.equal(res.body.totals.sessions, 2, 'liczba sesji pokoju, nie długość strony');
  assert.equal(res.body.totals.words, 100, 'sumy zgadzają się z listą osób');
  assert.equal(res.body.totals.people, 1);
});

test('historia nieistniejącego pokoju to 404', async () => {
  const handle = createHttpApi({ store: fakeStore() });
  const { req, res } = fakeExchange('GET', '/api/rooms/ZZZZZZ/history');

  await handle(req, res);

  assert.equal(res.statusCode, 404);
});

test('historia oddaje stronę i mówi, czy jest coś dalej', async () => {
  // Store zwraca o jeden wiersz za dużo — to jego sposób na „jest więcej".
  const store = fakeStore({
    async sessionHistory(roomId, limit) {
      return Array.from({ length: limit + 1 }, (_unused, index) => ({
        id: index, name: null, startedAt: 'a', endedAt: 'b',
        words: 1, seconds: 1, dictations: 1, speakers: 1, averageWords: 1,
      }));
    },
    async sessionCount() { return 99; },
  });
  const handle = createHttpApi({ store });
  const { req, res } = fakeExchange('GET', '/api/rooms/AB23CD/history?limit=5');

  await handle(req, res);

  assert.equal(res.body.sessions.length, 5, 'nadmiarowy wiersz nie jedzie do klienta');
  assert.equal(res.body.hasMore, true);
  assert.equal(res.body.totals.sessions, 99, 'sumy dotyczą pokoju, nie strony');
});

test('ostatnia strona nie kłamie, że jest następna', async () => {
  const store = fakeStore({
    async sessionHistory() {
      return [{ id: 1, name: null, startedAt: 'a', endedAt: 'b',
        words: 1, seconds: 1, dictations: 1, speakers: 1, averageWords: 1 }];
    },
    async sessionCount() { return 1; },
  });
  const handle = createHttpApi({ store });
  const { req, res } = fakeExchange('GET', '/api/rooms/AB23CD/history?limit=20');

  await handle(req, res);

  assert.equal(res.body.hasMore, false);
});

test('bzdurny limit w adresie nie każe bazie liczyć wszystkiego', async () => {
  const seen = [];
  const store = fakeStore({
    async sessionHistory(roomId, limit, offset) { seen.push([limit, offset]); return []; },
    async sessionCount() { return 0; },
  });
  const handle = createHttpApi({ store });
  for (const query of ['?limit=99999', '?limit=abc', '?limit=-5', '?offset=-3']) {
    const { req, res } = fakeExchange('GET', `/api/rooms/AB23CD/history${query}`);
    await handle(req, res);
  }

  assert.deepEqual(seen, [[100, 0], [20, 0], [20, 0], [20, 0]]);
});
