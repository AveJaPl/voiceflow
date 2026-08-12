import { createServer as createHttpServer } from 'node:http';
import { WebSocketServer } from 'ws';
import { RelayHub } from './relayHub.js';

const WS_PATH = '/ws';
const ROLES = new Set(['mac', 'phone']);
const MAX_BODY_BYTES = 8 * 1024;

function sendJson(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

function readJsonBody(req) {
  return new Promise((resolve) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > MAX_BODY_BYTES) {
        raw = '';
        req.destroy();
        resolve(null);
      }
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(raw || '{}'));
      } catch {
        resolve(null);
      }
    });
    req.on('error', () => resolve(null));
  });
}

function isAdmin(req, adminSecret) {
  const auth = req.headers['authorization'] || '';
  const provided = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  return provided === adminSecret;
}

/** Wyciąga nazwę urządzenia z ramki `hello` (phone: `device`, mac: `mac`). */
function deviceNameFromHello(data) {
  try {
    const frame = JSON.parse(data.toString());
    if (frame?.type !== 'hello') return null;
    return frame.device || frame.mac || null;
  } catch {
    return null;
  }
}

/**
 * Buduje `http.Server` z endpointami /health, /pair, /register, /login,
 * /sessions i upgrade'em WS na /ws.
 * `relayHub` jest injectowalny, żeby testy mogły podejrzeć stan bez realnej sieci.
 */
export function createRelayServer({ adminSecret, pairingStore, accountStore, relayHub = new RelayHub() }) {
  if (!adminSecret) {
    throw new Error('adminSecret jest wymagany — bez niego /pair byłoby otwarte dla każdego.');
  }
  if (!accountStore) {
    throw new Error('accountStore jest wymagany — bez niego nie ma kont ani logu sesji.');
  }

  const wss = new WebSocketServer({ noServer: true });

  const httpServer = createHttpServer(async (req, res) => {
    const url = new URL(req.url, 'http://relay.local');

    if (req.method === 'GET' && url.pathname === '/health') {
      sendJson(res, 200, { status: 'ok', service: 'voiceflow-relay' });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/pair') {
      if (!isAdmin(req, adminSecret)) {
        sendJson(res, 401, { error: 'unauthorized' });
        return;
      }
      const { token, createdAt } = pairingStore.generate();
      sendJson(res, 201, { token, createdAt });
      return;
    }

    // Prywatna usługa — konta zakłada tylko admin, nie ma otwartej rejestracji.
    if (req.method === 'POST' && url.pathname === '/register') {
      if (!isAdmin(req, adminSecret)) {
        sendJson(res, 401, { error: 'unauthorized' });
        return;
      }
      const body = await readJsonBody(req);
      const email = typeof body?.email === 'string' ? body.email.trim() : '';
      const password = typeof body?.password === 'string' ? body.password : '';
      if (!email || !password) {
        sendJson(res, 400, { error: 'invalid_body' });
        return;
      }
      try {
        const account = accountStore.register(email, password);
        console.log(`[relay] nowe konto: ${email}`);
        sendJson(res, 201, { pairToken: account.pairToken });
      } catch (err) {
        if (err.message === 'email_taken') {
          sendJson(res, 409, { error: 'email_taken' });
          return;
        }
        throw err;
      }
      return;
    }

    if (req.method === 'POST' && url.pathname === '/login') {
      const body = await readJsonBody(req);
      const pairToken = accountStore.login(body?.email ?? '', body?.password ?? '');
      if (!pairToken) {
        sendJson(res, 401, { error: 'invalid_credentials' });
        return;
      }
      sendJson(res, 200, { pairToken });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/sessions') {
      if (!isAdmin(req, adminSecret)) {
        sendJson(res, 401, { error: 'unauthorized' });
        return;
      }
      const requested = Number(url.searchParams.get('limit') || 50);
      const limit = Number.isFinite(requested) ? Math.min(Math.max(Math.trunc(requested), 1), 500) : 50;
      sendJson(res, 200, { sessions: accountStore.recentSessions(limit) });
      return;
    }

    sendJson(res, 404, { error: 'not_found' });
  });

  httpServer.on('upgrade', (req, socket, head) => {
    let url;
    try {
      url = new URL(req.url, 'http://relay.local');
    } catch {
      socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
      socket.destroy();
      return;
    }

    if (url.pathname !== WS_PATH) {
      socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
      socket.destroy();
      return;
    }

    const role = url.searchParams.get('role');
    const token = url.searchParams.get('token');

    if (!ROLES.has(role)) {
      socket.write('HTTP/1.1 400 Bad Request\r\n\r\n');
      socket.destroy();
      return;
    }

    // Token z ręcznego parowania (stary mechanizm) ALBO stały token konta.
    const account = accountStore.findByPairToken(token);
    if (!account && !pairingStore.isValid(token)) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      socket.destroy();
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      relayHub.register(role, ws);

      // Log sesji tylko dla połączeń „po koncie" — ręczne parowanie nie ma do czego przypisać wpisu.
      const sessionLogId = account
        ? accountStore.logEvent({ accountId: account.id, role, event: 'connected' })
        : null;
      let device = null;

      ws.on('message', (data, isBinary) => {
        if (sessionLogId && !device && !isBinary) {
          device = deviceNameFromHello(data);
          if (device) accountStore.setDevice(sessionLogId, device);
        }
        relayHub.route(role, data, isBinary);
      });

      ws.on('close', () => {
        relayHub.unregister(role, ws);
        if (account) {
          accountStore.logEvent({ accountId: account.id, role, event: 'disconnected', device });
        }
      });
    });
  });

  // Wystawione dla testów/diagnostyki — nie jest częścią publicznego API relaya.
  httpServer.relayHub = relayHub;

  return httpServer;
}
