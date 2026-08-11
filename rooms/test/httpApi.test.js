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
