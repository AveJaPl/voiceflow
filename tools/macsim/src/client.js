import { WebSocket } from 'ws';
import { MacSimSession } from './session.js';

const RECONNECT_MIN_MS = 1000;
const RECONNECT_MAX_MS = 30_000;

export class RelayMacSimClient {
  constructor({ relay, token, scenario = 'happy', log = formatLog }) {
    this.relay = relay.replace(/\/$/, '');
    this.token = token;
    this.scenario = scenario;
    this.log = log;
    this.backoff = RECONNECT_MIN_MS;
    this.stopped = false;
    this.ws = null;
    this.session = null;
    this.reconnectTimer = null;
  }

  start() {
    this.stopped = false;
    this.connect();
  }

  stop() {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    this.session?.dispose();
    this.session = null;
    this.ws?.close(1000, 'macsim-stopped');
    this.ws = null;
  }

  connect() {
    if (this.stopped) return;
    const url = new URL(`${this.relay}/ws`);
    url.searchParams.set('role', 'mac');
    url.searchParams.set('token', this.token);
    this.log('↔', 'connect', url.toString().replace(this.token, '<token>'));
    const ws = new WebSocket(url);
    this.ws = ws;

    ws.on('open', () => {
      this.backoff = RECONNECT_MIN_MS;
      this.log('↔', 'connected', 'relay accepted mac');
      this.session = new MacSimSession({
        scenario: this.scenario,
        sendText: (text) => ws.readyState === WebSocket.OPEN && ws.send(text),
        sendBinary: (data) => ws.readyState === WebSocket.OPEN && ws.send(data, { binary: true }),
        close: (code, reason) => ws.close(code, reason),
        log: this.log,
      });
    });

    ws.on('message', (data, isBinary) => {
      if (!this.session) return;
      if (isBinary) this.session.receiveBinary(data);
      else this.session.receiveText(data.toString());
    });

    ws.on('error', (error) => this.log('↔', 'socket-error', error.message));
    ws.on('close', (code, reason) => {
      this.log('↔', 'closed', `${code} ${reason.toString()}`.trim());
      this.session?.dispose();
      this.session = null;
      if (this.ws === ws) this.ws = null;
      this.scheduleReconnect();
    });
  }

  scheduleReconnect() {
    if (this.stopped || this.reconnectTimer) return;
    const delay = this.backoff;
    this.backoff = Math.min(this.backoff * 2, RECONNECT_MAX_MS);
    this.log('↔', 'reconnect', `za ${delay} ms`);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }
}

export function formatLog(direction, type, payload = '') {
  const timestamp = new Date().toISOString();
  console.log(`[macsim] ${timestamp} ${direction} ${type}${payload ? ` ${payload}` : ''}`);
}
