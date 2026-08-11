/**
 * REST: rejestracja urządzenia, pokój, sesja, ranking.
 *
 * Routing jest wydzielony do `routeFor`, czystej funkcji — dzięki temu tablicę
 * tras testuje się bez podnoszenia serwera, a `createHttpApi` zajmuje się już
 * tylko tym, co która trasa robi.
 */

import { historyTotals } from './store.js';

// `/session/end` stoi przed `/session`, bo alternatywa jest uporządkowana —
// odwrotna kolejność zjadałaby dłuższą trasę krótszym wariantem.
const ROOM_PATH = /^\/api\/rooms\/([^/]+)(\/join|\/ranking|\/history|\/session\/end|\/session)?$/;

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
  if (method === 'GET' && tail === '/history') return { name: 'history', code };
  if (method === 'POST' && tail === '/session/end') return { name: 'endSession', code };
  if (method === 'POST' && tail === '/session') return { name: 'startSession', code };
  return null;
}

function sendJson(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
}

/** Zwraca `null` przy niepoprawnym JSON-ie — wywołujący odpowiada 400. */
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

    if (route.name === 'health') {
      return sendJson(res, 200, { status: 'ok', service: 'voiceflow-rooms' });
    }

    if (route.name === 'registerDevice') {
      const body = await readJson(req);
      if (body === null) return sendJson(res, 400, { error: 'invalid_json' });
      if (!body.name) return sendJson(res, 400, { error: 'name_required' });
      const device = await store.registerDevice(body.name, body.platform);
      return sendJson(res, 201, device);
    }

    if (route.name === 'createRoom') {
      const body = await readJson(req);
      if (body === null) return sendJson(res, 400, { error: 'invalid_json' });
      const room = await store.createRoom(body.name);
      // Utworzenie pokoju JEST początkiem sesji.
      const session = await store.startSession(room.id, body.sessionName);
      return sendJson(res, 201, { ...room, session });
    }

    const room = await store.roomByCode(route.code);
    if (!room) return sendJson(res, 404, { error: 'room_not_found' });

    if (route.name === 'join') {
      const body = await readJson(req);
      if (body === null) return sendJson(res, 400, { error: 'invalid_json' });
      const device = await store.deviceByToken(body.token);
      if (!device) return sendJson(res, 401, { error: 'unknown_device' });
      await store.joinRoom(room.id, device.id);
      const session = (await store.activeSession(room.id)) ?? (await store.startSession(room.id, null));
      return sendJson(res, 200, { room, session, device: { id: device.id, name: device.name } });
    }

    if (route.name === 'endSession') {
      const active = await store.activeSession(room.id);
      if (active) await store.endSession(active.id);
      // Pokój żyje dalej — kolejną sesję zaczyna się bez ponownego zapraszania.
      const next = await store.startSession(room.id, null);
      return sendJson(res, 200, { ended: active?.id ?? null, session: next });
    }

    if (route.name === 'startSession') {
      const body = await readJson(req);
      if (body === null) return sendJson(res, 400, { error: 'invalid_json' });
      // Zamknięcie poprzedniej jest CZĘŚCIĄ tej operacji, nie osobnym krokiem:
      // dwie otwarte sesje w jednym pokoju rozjechałyby ranking, bo `ranking`
      // liczy zawsze jedną aktywną.
      const active = await store.activeSession(room.id);
      if (active) await store.endSession(active.id);
      const session = await store.startSession(room.id, body.name || null);
      return sendJson(res, 201, { ended: active?.id ?? null, session });
    }

    if (route.name === 'history') {
      // Historia i sumy jadą jednym wejściem, bo strona i tak rysuje je razem,
      // a dwa odpytania dawałyby widok, w którym sumy nie zgadzają się z listą.
      const [sessions, people] = await Promise.all([
        store.sessionHistory(room.id),
        store.roomSummary(room.id),
      ]);
      return sendJson(res, 200, {
        room,
        sessions,
        people,
        totals: historyTotals(sessions, people),
      });
    }

    if (route.name === 'ranking') {
      const active = await store.activeSession(room.id);
      const [ranking, members] = await Promise.all([
        active ? store.ranking(active.id) : Promise.resolve([]),
        store.members(room.id),
      ]);
      return sendJson(res, 200, { room, session: active, members, ranking });
    }

    return sendJson(res, 404, { error: 'not_found' });
  };
}
