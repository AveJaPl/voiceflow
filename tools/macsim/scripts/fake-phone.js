#!/usr/bin/env node
import { WebSocket } from 'ws';

const [relay, token] = process.argv.slice(2);
if (!relay || !token) {
  console.error('Użycie: node tools/macsim/scripts/fake-phone.js ws://127.0.0.1:8091 <token>');
  process.exit(1);
}

const url = new URL(`${relay.replace(/\/$/, '')}/ws`);
url.searchParams.set('role', 'phone');
url.searchParams.set('token', token);
const ws = new WebSocket(url);
let generation = null;
let target = null;
let sentStart = false;
let requestedFocus = false;

ws.on('open', () => ws.send(JSON.stringify({ type: 'hello', protocol: 1, device: 'fake-phone' })));
ws.on('message', (data, isBinary) => {
  if (isBinary) {
    console.log(`[fake-phone] ← screenshot bytes: ${data.length}`);
    return;
  }
  const frame = JSON.parse(data.toString());
  console.log('[fake-phone] ←', frame);
  if (frame.type === 'hello') ws.send(JSON.stringify({ type: 'subscribe', windows: true, screenshot: true, terminal: null }));
  if (frame.type === 'windows' && !requestedFocus) {
    generation = frame.generation;
    target = frame.windows.find((window) => window.kind === 'terminal')?.id;
    requestedFocus = true;
    ws.send(JSON.stringify({ type: 'focusWindow', id: target, generation }));
    return;
  }
  if (frame.type === 'focus' && !sentStart) {
    sentStart = true;
    ws.send(JSON.stringify({ type: 'start', target, generation }));
    return;
  }
  if (frame.type === 'started') {
    ws.send(Buffer.from([0, 1, 2, 3]), { binary: true });
    setTimeout(() => ws.send(JSON.stringify({ type: 'end' })), 800);
  }
  if (frame.type === 'injected' || frame.type === 'error') ws.close();
});

ws.on('close', () => process.exit(0));
ws.on('error', (error) => {
  console.error('[fake-phone]', error.message);
  process.exit(1);
});
