#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createRelayServer } from './src/createServer.js';
import { PairingStore } from './src/pairingStore.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

const adminSecret = process.env.ADMIN_SECRET;
if (!adminSecret) {
  console.error(
    '[relay] ADMIN_SECRET nie jest ustawiony — odmawiam startu (bez niego POST /pair byłby otwarty dla każdego).'
  );
  process.exit(1);
}

const pairingStorePath = process.env.PAIRING_STORE_PATH || join(__dirname, 'data', 'pairing.json');
const port = Number(process.env.PORT || 8080);

const pairingStore = new PairingStore(pairingStorePath);
const server = createRelayServer({ adminSecret, pairingStore });

server.listen(port, () => {
  console.log(`[relay] nasłuch na :${port} (pairing store: ${pairingStorePath})`);
});

process.on('SIGTERM', () => {
  console.log('[relay] SIGTERM — zamykam serwer');
  server.close(() => process.exit(0));
});
