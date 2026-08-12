import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WebSocket } from 'ws';
import { createRelayServer } from '../src/createServer.js';
import { PairingStore } from '../src/pairingStore.js';
import { AccountStore } from '../src/accountStore.js';

const ADMIN_SECRET = 'test-admin-secret';

/**
 * Integracyjne testy end-to-end tego modułu: prawdziwy http.Server + prawdziwy
 * klient `ws`, ale wyłącznie na loopbacku (127.0.0.1, port efemeryczny) —
 * bez żadnej prawdziwej sieci/internetu, deterministyczne i szybkie.
 * Logika routingu jest już pokryta bez sieci w relayHub.test.js.
 */
async function withServer(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'voiceflow-relay-server-test-'));
  const pairingStore = new PairingStore(join(dir, 'pairing.json'));
  const accountStore = new AccountStore(join(dir, 'relay.db'));
  const server = createRelayServer({ adminSecret: ADMIN_SECRET, pairingStore, accountStore });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  const baseUrl = `http://127.0.0.1:${port}`;
  const wsUrl = `ws://127.0.0.1:${port}/ws`;

  try {
    await fn({ baseUrl, wsUrl, pairingStore, accountStore });
  } finally {
    await new Promise((resolve) => server.close(resolve));
    // Serwerowe `close` na socketach (a więc i wpis "disconnected") potrafi
    // dojść tuż po zamknięciu serwera — bazę zamykamy dopiero po nim.
    await new Promise((resolve) => setTimeout(resolve, 50));
    accountStore.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

function postJson(url, body, headers = {}) {
  return fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
  });
}

/** Zakłada konto przez /register i zwraca jego stały pairToken. */
async function registerAccount(baseUrl, email = 'wojtek@programo.pl', password = 'haslo-testowe') {
  const res = await postJson(
    `${baseUrl}/register`,
    { email, password },
    { authorization: `Bearer ${ADMIN_SECRET}` }
  );
  assert.equal(res.status, 201);
  const { pairToken } = await res.json();
  return pairToken;
}

function waitUntil(predicate, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const tick = () => {
      if (predicate()) return resolve();
      if (Date.now() - started > timeoutMs) return reject(new Error('warunek nie zaszedł w czasie'));
      setTimeout(tick, 10);
    };
    tick();
  });
}

function openSocket(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

function waitForClose(ws) {
  return new Promise((resolve) => {
    ws.once('close', (code, reason) => resolve({ code, reason: reason.toString() }));
    ws.once('unexpected-response', (req, res) => resolve({ statusCode: res.statusCode }));
  });
}

function waitForMessage(ws) {
  return new Promise((resolve) => {
    ws.once('message', (data, isBinary) => resolve({ data, isBinary }));
  });
}

test('GET /health odpowiada 200 z statusem ok', async () => {
  await withServer(async ({ baseUrl }) => {
    const res = await fetch(`${baseUrl}/health`);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.status, 'ok');
  });
});

test('POST /pair bez sekretu admina jest odrzucany', async () => {
  await withServer(async ({ baseUrl }) => {
    const res = await fetch(`${baseUrl}/pair`, { method: 'POST' });
    assert.equal(res.status, 401);
  });
});

test('POST /pair z poprawnym sekretem generuje token i unieważnia poprzedni', async () => {
  await withServer(async ({ baseUrl, pairingStore }) => {
    const res1 = await fetch(`${baseUrl}/pair`, {
      method: 'POST',
      headers: { authorization: `Bearer ${ADMIN_SECRET}` },
    });
    assert.equal(res1.status, 201);
    const body1 = await res1.json();
    assert.ok(body1.token);
    assert.equal(pairingStore.isValid(body1.token), true);

    const res2 = await fetch(`${baseUrl}/pair`, {
      method: 'POST',
      headers: { authorization: `Bearer ${ADMIN_SECRET}` },
    });
    const body2 = await res2.json();

    assert.notEqual(body1.token, body2.token);
    assert.equal(pairingStore.isValid(body1.token), false, 'stary token musi zostać unieważniony');
    assert.equal(pairingStore.isValid(body2.token), true);
  });
});

test('połączenie WS bez ważnego tokenu jest odrzucane', async () => {
  await withServer(async ({ wsUrl }) => {
    const ws = new WebSocket(`${wsUrl}?role=mac&token=nieprawidlowy`);
    const result = await waitForClose(ws);
    // ws-client zgłasza handshake 401 jako 'unexpected-response' zanim doszłoby do 'open'
    assert.ok(result.statusCode === 401 || result.code !== undefined);
  });
});

test('połączenie WS bez tokenu w ogóle jest odrzucane', async () => {
  await withServer(async ({ wsUrl }) => {
    const ws = new WebSocket(`${wsUrl}?role=phone`);
    const result = await waitForClose(ws);
    assert.ok(result.statusCode === 401 || result.code !== undefined);
  });
});

test('połączenie WS z nieznaną rolą jest odrzucane nawet z ważnym tokenem', async () => {
  await withServer(async ({ baseUrl, wsUrl }) => {
    const pairRes = await fetch(`${baseUrl}/pair`, {
      method: 'POST',
      headers: { authorization: `Bearer ${ADMIN_SECRET}` },
    });
    const { token } = await pairRes.json();

    const ws = new WebSocket(`${wsUrl}?role=tablet&token=${token}`);
    const result = await waitForClose(ws);
    assert.ok(result.statusCode === 400 || result.code !== undefined);
  });
});

test('end-to-end: phone wysyła binarną ramkę audio, mac ją odbiera 1:1', async () => {
  await withServer(async ({ baseUrl, wsUrl }) => {
    const pairRes = await fetch(`${baseUrl}/pair`, {
      method: 'POST',
      headers: { authorization: `Bearer ${ADMIN_SECRET}` },
    });
    const { token } = await pairRes.json();

    const mac = await openSocket(`${wsUrl}?role=mac&token=${token}`);
    const phone = await openSocket(`${wsUrl}?role=phone&token=${token}`);

    const audioChunk = Buffer.from([10, 20, 30, 40]);
    const received = waitForMessage(mac);
    phone.send(audioChunk, { binary: true });

    const { data, isBinary } = await received;
    assert.equal(isBinary, true);
    assert.deepEqual([...data], [...audioChunk]);

    mac.close();
    phone.close();
  });
});

test('end-to-end: phone bez połączonego mac dostaje błąd, nie ciszę', async () => {
  await withServer(async ({ baseUrl, wsUrl }) => {
    const pairRes = await fetch(`${baseUrl}/pair`, {
      method: 'POST',
      headers: { authorization: `Bearer ${ADMIN_SECRET}` },
    });
    const { token } = await pairRes.json();

    const phone = await openSocket(`${wsUrl}?role=phone&token=${token}`);
    const { data } = await waitForMessage(phone);
    const message = JSON.parse(data.toString());

    assert.equal(message.type, 'error');
    assert.equal(message.code, 'mac_offline');

    phone.close();
  });
});

test('POST /register bez sekretu admina jest odrzucany', async () => {
  await withServer(async ({ baseUrl }) => {
    const res = await postJson(`${baseUrl}/register`, {
      email: 'obcy@example.com',
      password: 'x',
    });
    assert.equal(res.status, 401);
  });
});

test('rejestracja i logowanie zwracają ten sam, stały token parowania', async () => {
  await withServer(async ({ baseUrl }) => {
    const pairToken = await registerAccount(baseUrl);

    const first = await postJson(`${baseUrl}/login`, {
      email: 'wojtek@programo.pl',
      password: 'haslo-testowe',
    });
    assert.equal(first.status, 200);
    assert.equal((await first.json()).pairToken, pairToken);

    // Drugie logowanie nie rotuje tokenu — urządzenia mogą go trzymać na stałe.
    const second = await postJson(`${baseUrl}/login`, {
      email: 'wojtek@programo.pl',
      password: 'haslo-testowe',
    });
    assert.equal((await second.json()).pairToken, pairToken);
  });
});

test('logowanie ze złym hasłem daje 401 i nie zdradza tokenu', async () => {
  await withServer(async ({ baseUrl }) => {
    await registerAccount(baseUrl);

    const res = await postJson(`${baseUrl}/login`, {
      email: 'wojtek@programo.pl',
      password: 'zle-haslo',
    });
    assert.equal(res.status, 401);
    const body = await res.json();
    assert.equal(body.pairToken, undefined);

    const unknown = await postJson(`${baseUrl}/login`, {
      email: 'nikt@example.com',
      password: 'haslo-testowe',
    });
    assert.equal(unknown.status, 401);
  });
});

test('rejestracja tego samego maila drugi raz daje 409', async () => {
  await withServer(async ({ baseUrl }) => {
    await registerAccount(baseUrl);
    const res = await postJson(
      `${baseUrl}/register`,
      { email: 'wojtek@programo.pl', password: 'inne-haslo' },
      { authorization: `Bearer ${ADMIN_SECRET}` }
    );
    assert.equal(res.status, 409);
  });
});

test('end-to-end: para mac↔phone łączy się tokenem konta i przekazuje ramki', async () => {
  await withServer(async ({ baseUrl, wsUrl }) => {
    const pairToken = await registerAccount(baseUrl);

    const mac = await openSocket(`${wsUrl}?role=mac&token=${pairToken}`);
    const phone = await openSocket(`${wsUrl}?role=phone&token=${pairToken}`);

    const audioChunk = Buffer.from([1, 2, 3, 4, 5]);
    const received = waitForMessage(mac);
    phone.send(audioChunk, { binary: true });

    const { data, isBinary } = await received;
    assert.equal(isBinary, true);
    assert.deepEqual([...data], [...audioChunk]);

    mac.close();
    phone.close();
  });
});

test('token z ręcznego /pair nadal działa obok kont (zgodność wsteczna)', async () => {
  await withServer(async ({ baseUrl, wsUrl, accountStore }) => {
    await registerAccount(baseUrl);
    const pairRes = await fetch(`${baseUrl}/pair`, {
      method: 'POST',
      headers: { authorization: `Bearer ${ADMIN_SECRET}` },
    });
    const { token } = await pairRes.json();

    const mac = await openSocket(`${wsUrl}?role=mac&token=${token}`);
    mac.close();
    await waitForClose(mac);

    // Ręczne parowanie nie jest przypisane do konta — nie może trafić do logu sesji.
    assert.equal(accountStore.recentSessions(50).length, 0);
  });
});

test('połączenia po koncie trafiają do session_log wraz z nazwą urządzenia', async () => {
  await withServer(async ({ baseUrl, wsUrl, accountStore }) => {
    const pairToken = await registerAccount(baseUrl);

    const phone = await openSocket(`${wsUrl}?role=phone&token=${pairToken}`);
    phone.send(JSON.stringify({ type: 'hello', protocol: 1, device: 'iPhone Wojtka' }));
    await waitUntil(() => accountStore.recentSessions(50).some((s) => s.device === 'iPhone Wojtka'));

    phone.close();
    await waitUntil(() => accountStore.recentSessions(50).some((s) => s.event === 'disconnected'));

    const sessions = accountStore.recentSessions(50);
    const connected = sessions.find((s) => s.event === 'connected');
    const disconnected = sessions.find((s) => s.event === 'disconnected');
    assert.equal(connected.role, 'phone');
    assert.equal(connected.email, 'wojtek@programo.pl');
    assert.equal(connected.device, 'iPhone Wojtka');
    assert.equal(disconnected.device, 'iPhone Wojtka');
  });
});

test('GET /sessions wymaga sekretu admina i zwraca ostatnie wpisy', async () => {
  await withServer(async ({ baseUrl, wsUrl, accountStore }) => {
    const pairToken = await registerAccount(baseUrl);
    const mac = await openSocket(`${wsUrl}?role=mac&token=${pairToken}`);
    await waitUntil(() => accountStore.recentSessions(50).length > 0);

    const denied = await fetch(`${baseUrl}/sessions`);
    assert.equal(denied.status, 401);

    const res = await fetch(`${baseUrl}/sessions?limit=10`, {
      headers: { authorization: `Bearer ${ADMIN_SECRET}` },
    });
    assert.equal(res.status, 200);
    const { sessions } = await res.json();
    assert.equal(sessions.length, 1);
    assert.equal(sessions[0].role, 'mac');
    assert.equal(sessions[0].event, 'connected');

    mac.close();
  });
});
