/**
 * Spięcie usługi pokoi: REST, WebSocket i statyczna strona rankingu na jednym
 * porcie, jeden kontener, jedna baza.
 *
 * Odmawia startu bez `DATABASE_URL` — tak samo jak relay odmawia bez
 * `ADMIN_SECRET`. Usługa, która wstaje w połowie skonfigurowana, psuje się
 * później i w miejscu, które nie wskazuje na przyczynę.
 */

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join as joinPath, dirname, normalize } from 'node:path';
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
console.log('[rooms] schemat gotowy');

const store = createStore(pool);
const api = createHttpApi({ store });
const hub = createHub({ store });

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
};

const server = createServer(async (req, res) => {
  const path = req.url.split('?')[0];
  if (path.startsWith('/api/') || path === '/health') return api(req, res);

  // /room/<KOD> to ta sama strona — kod czyta z adresu już przeglądarka.
  const wanted = path === '/' || path.startsWith('/room/') ? 'index.html' : path.slice(1);
  // normalize + odrzucenie ".." — bez tego GET /../server.js wyniósłby kod źródłowy.
  const safe = normalize(wanted);
  if (safe.startsWith('..') || safe.startsWith('/')) {
    res.writeHead(403).end('forbidden');
    return;
  }
  try {
    const body = await readFile(joinPath(here, 'public', safe));
    const extension = safe.slice(safe.lastIndexOf('.'));
    res.writeHead(200, { 'content-type': CONTENT_TYPES[extension] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404).end('not found');
  }
});

const wss = new WebSocketServer({ server, path: '/ws' });

wss.on('connection', async (socket, req) => {
  const url = new URL(req.url, 'http://localhost');
  const roomCode = (url.searchParams.get('room') ?? '').toUpperCase();
  const isViewer = url.searchParams.get('view') === '1';
  const device = await store.deviceByToken(url.searchParams.get('token') ?? '');
  if (!roomCode || (!device && !isViewer)) {
    socket.close(4001, 'unauthorized');
    return;
  }
  const room = await store.roomByCode(roomCode);
  if (!room) {
    socket.close(4004, 'room_not_found');
    return;
  }

  const connection = {
    deviceId: device?.id ?? `viewer-${Math.random().toString(36).slice(2)}`,
    name: device?.name ?? null,
    viewer: !device,
    roomCode,
    roomId: room.id,
    send(obj) {
      if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(obj));
    },
  };

  socket.on('message', async (raw) => {
    let message;
    try {
      message = JSON.parse(raw.toString());
    } catch {
      return; // śmieć w kanale nie może zdjąć połączenia
    }
    try {
      await hub.handleMessage(connection, message);
    } catch (error) {
      console.error('[rooms] błąd obsługi komunikatu:', error.message);
    }
  });
  socket.on('close', () => hub.disconnect(connection));
  socket.on('error', () => hub.disconnect(connection));

  await hub.handleMessage(connection, { type: 'hello' });
  if (device) store.touchDevice(device.id).catch(() => {});
});

// Sprzątanie po klientach, którzy zniknęli w trakcie mówienia. Częściej niż
// timeout pulsu, żeby blokada schodziła w okolicach 10 s, a nie 20.
setInterval(() => hub.tick(), 2000).unref();

const port = Number(process.env.PORT ?? 3000);
server.listen(port, () => console.log(`[rooms] nasłuch na :${port}`));
