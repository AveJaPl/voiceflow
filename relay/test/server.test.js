import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WebSocket } from 'ws';
import { createRelayServer } from '../src/createServer.js';
import { PairingStore } from '../src/pairingStore.js';

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
  const server = createRelayServer({ adminSecret: ADMIN_SECRET, pairingStore });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  const baseUrl = `http://127.0.0.1:${port}`;
  const wsUrl = `ws://127.0.0.1:${port}/ws`;

  try {
    await fn({ baseUrl, wsUrl, pairingStore });
  } finally {
    await new Promise((resolve) => server.close(resolve));
    rmSync(dir, { recursive: true, force: true });
  }
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
