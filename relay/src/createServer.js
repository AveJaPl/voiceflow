import { createServer as createHttpServer } from 'node:http';
import { WebSocketServer } from 'ws';
import { RelayHub } from './relayHub.js';

const WS_PATH = '/ws';
const ROLES = new Set(['mac', 'phone']);

function sendJson(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

/**
 * Buduje `http.Server` z endpointami /health, /pair i upgrade'em WS na /ws.
 * `relayHub` jest injectowalny, żeby testy mogły podejrzeć stan bez realnej sieci.
 */
export function createRelayServer({ adminSecret, pairingStore, relayHub = new RelayHub() }) {
  if (!adminSecret) {
    throw new Error('adminSecret jest wymagany — bez niego /pair byłoby otwarte dla każdego.');
  }

  const wss = new WebSocketServer({ noServer: true });

  const httpServer = createHttpServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') {
      sendJson(res, 200, { status: 'ok', service: 'voiceflow-relay' });
      return;
    }

    if (req.method === 'POST' && req.url === '/pair') {
      const auth = req.headers['authorization'] || '';
      const provided = auth.startsWith('Bearer ') ? auth.slice(7) : '';
      if (provided !== adminSecret) {
        sendJson(res, 401, { error: 'unauthorized' });
        return;
      }
      const { token, createdAt } = pairingStore.generate();
      sendJson(res, 201, { token, createdAt });
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

    if (!pairingStore.isValid(token)) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      socket.destroy();
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      relayHub.register(role, ws);

      ws.on('message', (data, isBinary) => {
        relayHub.route(role, data, isBinary);
      });

      ws.on('close', () => {
        relayHub.unregister(role, ws);
      });
    });
  });

  // Wystawione dla testów/diagnostyki — nie jest częścią publicznego API relaya.
  httpServer.relayHub = relayHub;

  return httpServer;
}
